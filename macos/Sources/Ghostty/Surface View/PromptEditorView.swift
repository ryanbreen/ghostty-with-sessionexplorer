import AppKit
import Combine
import GhosttyKit

extension Ghostty {
    /// Native CoreText prompt-editor pinned to the bottom of a SurfaceView.
    /// Composed of a 1-row header bar (centered prompt info — user@host
    /// and pwd — plus a 1px hairline at its bottom edge) sitting on top of
    /// an NSTextView that grows vertically as the user types more lines.
    /// The header bar visually covers the shell's empty prompt row in the
    /// terminal grid, so the prompt only ever lives within the editor.
    final class PromptEditorView: NSView {
        weak var owner: SurfaceView?

        let scrollView: NSScrollView
        let textView: PromptEditorTextView

        /// 1-row-tall header strip at the top of the editor. Carries the
        /// prompt label centered horizontally + a 1px separator at its
        /// bottom edge.
        let headerView: PromptHeaderView

        /// Cached row count (header + input) we last reported to libghostty.
        /// Kept in sync so we only fire `set_editor_rows` when it changes.
        private var reportedRows: Int = 0

        /// Combine subscription for owner's pwd changes.
        private var pwdCancellable: AnyCancellable?

        init(owner: SurfaceView) {
            self.owner = owner
            self.scrollView = NSScrollView(frame: .zero)
            self.textView = PromptEditorTextView(frame: .zero)
            self.headerView = PromptHeaderView(frame: .zero)
            super.init(frame: .zero)

            addSubview(headerView)

            scrollView.hasVerticalScroller = false
            scrollView.hasHorizontalScroller = false
            scrollView.borderType = .noBorder
            scrollView.drawsBackground = true
            scrollView.autohidesScrollers = true

            textView.isRichText = false
            textView.allowsUndo = true
            textView.usesFindBar = false
            textView.isAutomaticQuoteSubstitutionEnabled = false
            textView.isAutomaticDashSubstitutionEnabled = false
            textView.isAutomaticTextReplacementEnabled = false
            textView.isAutomaticSpellingCorrectionEnabled = false
            textView.smartInsertDeleteEnabled = false
            textView.textContainerInset = NSSize(width: 4, height: 0)

            scrollView.documentView = textView
            addSubview(scrollView)

            textView.owner = owner
            textView.commitHandler = { [weak self] in self?.commit() }
            textView.contentDidChangeHandler = { [weak self] in
                self?.syncHeightToContent()
            }

            // Re-pull pwd-derived header text whenever the owning surface's
            // pwd publishes a new value (shell ran `cd`, etc.).
            pwdCancellable = owner.$pwd.sink { [weak self] _ in
                DispatchQueue.main.async { self?.refreshHeaderText() }
            }
        }

        required init?(coder: NSCoder) {
            fatalError("init(coder:) is not supported")
        }

        override func layout() {
            super.layout()
            guard let owner else { return }
            let cellHeight = owner.cellSize.height > 0 ? owner.cellSize.height : 17
            let h = bounds.height
            let w = bounds.width
            // Header is the topmost cellHeight; scroll view fills below it.
            let headerH = cellHeight
            headerView.frame = NSRect(x: 0, y: h - headerH, width: w, height: headerH)
            scrollView.frame = NSRect(x: 0, y: 0, width: w, height: max(0, h - headerH))
        }

        /// Show the bar. Computes initial layout (1 header row + 1 input row),
        /// pushes the row count to libghostty, and grabs first responder.
        func activate(rows: UInt32) {
            guard let owner else { return }
            isHidden = false
            applyTheme()
            refreshHeaderText()
            syncHeightToContent()
            owner.window?.makeFirstResponder(textView)
        }

        func deactivate() {
            isHidden = true
            textView.string = ""
            reportedRows = 0
            yieldFocusToTerminal()
        }

        /// Pull theme colors and the terminal's primary font from the
        /// owning surface and push them into the NSTextView and the
        /// header. Also force the editor's line height to match the
        /// terminal's cell height so the row math always rounds cleanly.
        func applyTheme() {
            guard let owner else { return }
            let bg = NSColor(owner.derivedConfig.backgroundColor)
            let fg = NSColor(owner.derivedConfig.foregroundColor)
            let caret = NSColor(owner.derivedConfig.cursorColor)
            textView.backgroundColor = bg
            textView.textColor = fg
            textView.insertionPointColor = caret
            scrollView.backgroundColor = bg

            let font = loadTerminalFont(for: owner)
            textView.font = font

            let cellHeight = owner.cellSize.height > 0 ? owner.cellSize.height : 17
            let para = NSMutableParagraphStyle()
            para.minimumLineHeight = cellHeight
            para.maximumLineHeight = cellHeight
            textView.defaultParagraphStyle = para
            textView.typingAttributes = [
                .font: font,
                .foregroundColor: fg,
                .paragraphStyle: para,
            ]
            if let storage = textView.textStorage, storage.length > 0 {
                storage.addAttribute(
                    .paragraphStyle,
                    value: para,
                    range: NSRange(location: 0, length: storage.length))
            }

            headerView.applyTheme(bg: bg, fg: fg, accent: caret, font: font)
            // Re-layout so the header height tracks the new cellHeight.
            needsLayout = true
        }

        /// Borrow a CTFont from libghostty for the terminal's primary
        /// face and bridge to NSFont. The C function returns a +1 retain
        /// (it ran copyWithAttributes); we balance with `release()`.
        private func loadTerminalFont(for owner: SurfaceView) -> NSFont {
            let fallback = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
            guard let cSurface = owner.surface else { return fallback }
            guard let raw = ghostty_surface_quicklook_font(cSurface) else { return fallback }
            let unmanaged = Unmanaged<CTFont>.fromOpaque(raw)
            let ctFont = unmanaged.takeUnretainedValue()
            unmanaged.release()
            return ctFont as NSFont
        }

        /// Recompute the editor's row count from the NSTextView's laid-
        /// out content height and resize/report if it changed. Total
        /// reported rows = 1 (header) + lineCount (input).
        func syncHeightToContent() {
            guard let owner else { return }
            let cellHeight = owner.cellSize.height > 0 ? owner.cellSize.height : 17
            let inputRows = currentLineCount(cellHeight: cellHeight)
            let totalRows = 1 + inputRows
            let desiredHeight = CGFloat(totalRows) * cellHeight
            if abs(frame.height - desiredHeight) > 0.5 {
                layoutAtBottom(in: owner, height: desiredHeight)
            }
            if totalRows != reportedRows {
                reportedRows = totalRows
                if let cSurface = owner.surface {
                    ghostty_surface_set_editor_rows(cSurface, UInt32(totalRows))
                }
            }
        }

        private func currentLineCount(cellHeight: CGFloat) -> Int {
            guard let lm = textView.layoutManager,
                let tc = textView.textContainer else { return 1 }
            lm.ensureLayout(for: tc)
            let used = lm.usedRect(for: tc).height
            if used <= 0 { return 1 }
            return max(1, Int(ceil(used / cellHeight)))
        }

        /// Build the header label from owner.pwd + system info. Format:
        /// "user@host pwd" — the same shape as a typical shell prompt.
        func refreshHeaderText() {
            let user = NSUserName()
            let rawHost = Host.current().localizedName ?? ProcessInfo.processInfo.hostName
            let host = rawHost
                .replacingOccurrences(of: ".local", with: "")
                .replacingOccurrences(of: ".lan", with: "")
            let pwd = abbreviatePath(owner?.pwd)
            let composed: String
            if pwd.isEmpty {
                composed = "\(user)@\(host)"
            } else {
                composed = "\(user)@\(host) \(pwd)"
            }
            headerView.setText(composed)
        }

        private func abbreviatePath(_ path: String?) -> String {
            guard let path, !path.isEmpty else { return "" }
            let home = NSHomeDirectory()
            if path == home { return "~" }
            if path.hasPrefix(home + "/") {
                return "~" + path.dropFirst(home.count)
            }
            return path
        }

        /// Insert pasted text at the current selection. Called from
        /// libghostty's editor_paste callback when the editor is visible.
        func insertPasted(_ data: String) {
            guard !data.isEmpty else { return }
            let range = textView.selectedRange()
            if textView.shouldChangeText(in: range, replacementString: data) {
                textView.replaceCharacters(in: range, with: data)
                textView.didChangeText()
            }
        }

        func commit() {
            guard let owner, let cSurface = owner.surface else { return }
            let payload = textView.string
            payload.withCString { cstr in
                let len = strlen(cstr)
                ghostty_surface_editor_commit(cSurface, cstr, UInt(len))
            }
            textView.string = ""
            syncHeightToContent()
        }

        func yieldFocusToTerminal() {
            guard let owner, let window = owner.window else { return }
            if window.firstResponder === textView {
                window.makeFirstResponder(owner)
            }
        }

        private func layoutAtBottom(in parent: NSView, height: CGFloat) {
            autoresizingMask = [.width]
            frame = NSRect(
                x: 0,
                y: 0,
                width: parent.bounds.width,
                height: height
            )
        }
    }

    /// 1-row-tall header strip at the top of the prompt editor. Draws the
    /// terminal's background, a centered text label (user@host pwd), and a
    /// 1px hairline at its bottom edge separating the header from the
    /// input area.
    final class PromptHeaderView: NSView {
        private let label: NSTextField
        private var separatorColor: NSColor = .separatorColor

        override init(frame frameRect: NSRect) {
            self.label = NSTextField(labelWithString: "")
            super.init(frame: frameRect)
            label.alignment = .center
            label.lineBreakMode = .byTruncatingMiddle
            label.usesSingleLineMode = true
            label.maximumNumberOfLines = 1
            label.isEditable = false
            label.isSelectable = false
            label.isBezeled = false
            label.isBordered = false
            label.drawsBackground = false
            label.backgroundColor = .clear
            label.translatesAutoresizingMaskIntoConstraints = false
            addSubview(label)
            NSLayoutConstraint.activate([
                label.centerXAnchor.constraint(equalTo: centerXAnchor),
                label.centerYAnchor.constraint(equalTo: centerYAnchor),
                label.leadingAnchor.constraint(
                    greaterThanOrEqualTo: leadingAnchor, constant: 8),
                label.trailingAnchor.constraint(
                    lessThanOrEqualTo: trailingAnchor, constant: -8),
            ])
            wantsLayer = true
        }

        required init?(coder: NSCoder) {
            fatalError("init(coder:) is not supported")
        }

        func setText(_ s: String) {
            label.stringValue = s
        }

        func applyTheme(bg: NSColor, fg: NSColor, accent: NSColor, font: NSFont) {
            layer?.backgroundColor = bg.cgColor
            // Slightly dimmer foreground for the header — it's metadata,
            // not user content. Falls back to fg if mixing fails.
            label.textColor = fg.withAlphaComponent(0.65)
            // Match the terminal font but a touch smaller so the header
            // reads as a label rather than another line of input.
            let size = max(10, font.pointSize - 1)
            label.font = NSFont(descriptor: font.fontDescriptor, size: size) ?? font
            // The hairline at the bottom edge picks up the cursor color
            // at moderate alpha for visual continuity with the caret.
            separatorColor = accent.withAlphaComponent(0.5)
            needsDisplay = true
        }

        override func draw(_ dirtyRect: NSRect) {
            super.draw(dirtyRect)
            // 1px hairline along the bottom edge.
            separatorColor.setFill()
            let line = NSRect(x: 0, y: 0, width: bounds.width, height: 1)
            line.fill()
        }
    }

    /// NSTextView subclass that captures Enter (commit) and routes Cmd+C
    /// through the terminal's selection when one exists.
    final class PromptEditorTextView: NSTextView {
        weak var owner: SurfaceView?
        var commitHandler: (() -> Void)?
        var contentDidChangeHandler: (() -> Void)?

        override func keyDown(with event: NSEvent) {
            if event.keyCode == 36 &&
                event.modifierFlags.intersection(
                    [.shift, .command, .option, .control]
                ).isEmpty {
                commitHandler?()
                return
            }
            super.keyDown(with: event)
        }

        override func didChangeText() {
            super.didChangeText()
            contentDidChangeHandler?()
        }

        override func copy(_ sender: Any?) {
            if let cSurface = owner?.surface,
                ghostty_surface_has_selection(cSurface)
            {
                let action = "copy_to_clipboard"
                _ = ghostty_surface_binding_action(
                    cSurface,
                    action,
                    UInt(action.lengthOfBytes(using: .utf8))
                )
                return
            }
            super.copy(sender)
        }
    }
}
