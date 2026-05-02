import AppKit
import GhosttyKit

extension Ghostty {
    /// Native CoreText prompt-editor bar pinned to the bottom of a SurfaceView.
    /// Wraps an NSTextView in an NSScrollView so the editor can scroll its own
    /// contents independently of the terminal grid. Grows vertically as the
    /// user types more lines, pushing the terminal output up.
    final class PromptEditorView: NSView {
        weak var owner: SurfaceView?
        let scrollView: NSScrollView
        let textView: PromptEditorTextView
        /// 1px hairline at the top of the bar that visually separates the
        /// editor from the terminal output above. Drawn INSIDE the bar's
        /// row reservation so the editor and terminal stack pixel-perfect.
        let separator: NSBox

        /// Cached row count we last reported to libghostty. Kept in sync
        /// so we only fire `set_editor_rows` when the value changes.
        private var reportedRows: Int = 0

        /// Height of the top separator in points. Lives INSIDE the
        /// row-aligned editor area, so it eats one px from the topmost
        /// text row rather than adding height beyond the row count.
        private static let separatorHeight: CGFloat = 1

        init(owner: SurfaceView) {
            self.owner = owner
            self.scrollView = NSScrollView(frame: .zero)
            self.textView = PromptEditorTextView(frame: .zero)
            self.separator = NSBox(frame: .zero)
            super.init(frame: .zero)

            separator.boxType = .separator
            addSubview(separator)

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
            // Zero vertical inset so text sits flush beneath the
            // separator; small horizontal inset for readability.
            textView.textContainerInset = NSSize(width: 4, height: 0)

            scrollView.documentView = textView
            addSubview(scrollView)

            textView.owner = owner
            textView.commitHandler = { [weak self] in self?.commit() }
            textView.contentDidChangeHandler = { [weak self] in
                self?.syncHeightToContent()
            }
        }

        required init?(coder: NSCoder) {
            fatalError("init(coder:) is not supported")
        }

        override func layout() {
            super.layout()
            let h = bounds.height
            let w = bounds.width
            let sepH = Self.separatorHeight
            // macOS coordinates: y=0 is the bottom. Separator pins to
            // the very top, scrollView fills everything below it.
            separator.frame = NSRect(x: 0, y: h - sepH, width: w, height: sepH)
            scrollView.frame = NSRect(x: 0, y: 0, width: w, height: max(0, h - sepH))
        }

        /// Show the bar. The initial row count is computed from the
        /// (empty) buffer — typically 1 row — and pushed to libghostty
        /// so the renderer scrolls the terminal up by exactly that many
        /// rows. The NSTextView grabs first responder so the user can
        /// type without clicking.
        func activate(rows: UInt32) {
            guard let owner else { return }
            isHidden = false
            applyTheme()
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
        /// owning surface and push them into the NSTextView. Also force
        /// the editor's line height to match the terminal's cell height
        /// so `usedRect.height / cellHeight` always rounds cleanly to
        /// the editor's line count.
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

            // Match terminal cell height so the editor's row math
            // mirrors the terminal grid's row math exactly.
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
            // Re-apply paragraph style to existing text (if any) so a
            // theme reload mid-edit picks up the new metrics.
            if let storage = textView.textStorage, storage.length > 0 {
                storage.addAttribute(
                    .paragraphStyle,
                    value: para,
                    range: NSRange(location: 0, length: storage.length))
            }
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
        /// out content height and resize/report if it changed. Called on
        /// every text change AND on activation.
        func syncHeightToContent() {
            guard let owner else { return }
            let cellHeight = owner.cellSize.height > 0 ? owner.cellSize.height : 17
            let neededRows = currentLineCount(cellHeight: cellHeight)
            let desiredHeight = CGFloat(neededRows) * cellHeight
            if abs(frame.height - desiredHeight) > 0.5 {
                layoutAtBottom(in: owner, height: desiredHeight)
            }
            if neededRows != reportedRows {
                reportedRows = neededRows
                if let cSurface = owner.surface {
                    ghostty_surface_set_editor_rows(cSurface, UInt32(neededRows))
                }
            }
        }

        /// Visual line count of the current text. Empty buffer counts as
        /// one row so the bar never collapses to zero height. Wrapping
        /// is honored — a long unbroken line that wraps twice counts as
        /// three rows.
        private func currentLineCount(cellHeight: CGFloat) -> Int {
            guard let lm = textView.layoutManager,
                let tc = textView.textContainer else { return 1 }
            lm.ensureLayout(for: tc)
            let used = lm.usedRect(for: tc).height
            if used <= 0 { return 1 }
            return max(1, Int(ceil(used / cellHeight)))
        }

        /// Insert pasted text at the current selection. Called from
        /// libghostty's editor_paste callback when the editor is
        /// visible — covers drag-and-drop onto the terminal area,
        /// right-click paste, and any other path that wasn't already
        /// going through NSTextView's native Cmd+V.
        func insertPasted(_ data: String) {
            guard !data.isEmpty else { return }
            let range = textView.selectedRange()
            if textView.shouldChangeText(in: range, replacementString: data) {
                textView.replaceCharacters(in: range, with: data)
                textView.didChangeText()
            }
        }

        /// Commit the current buffer to the PTY (text + CR). Called when
        /// the user presses Enter inside the text view.
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

        /// Move first responder back to the terminal SurfaceView. Called
        /// on deactivate so the user can drive vim / etc. once the
        /// editor is hidden.
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

    /// NSTextView subclass that captures Enter (commit). All other keys
    /// fall through to NSTextView's default editing behavior. Cmd+C is
    /// overridden so it copies the terminal selection (when present)
    /// instead of the always-empty editor selection — the editor owns
    /// typing focus, so Cmd+C from the user's hands needs to do the
    /// thing the user expects.
    final class PromptEditorTextView: NSTextView {
        weak var owner: SurfaceView?
        var commitHandler: (() -> Void)?
        var contentDidChangeHandler: (() -> Void)?

        override func keyDown(with event: NSEvent) {
            // Plain Return (no modifiers) → commit the buffer.
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
            // didChangeText fires for every mutation — typing, paste,
            // delete — making it the most reliable hook for content-
            // size changes. NSText.didChangeNotification covers the
            // same ground; this is a belt-and-suspenders.
            contentDidChangeHandler?()
        }

        override func copy(_ sender: Any?) {
            // If the terminal has a selection, copy that — the user
            // can't focus the terminal while the editor is up, so a
            // Cmd+C with terminal text selected must mean "copy the
            // terminal text". If no terminal selection, fall through to
            // NSTextView's default (copies the editor's own selection).
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
