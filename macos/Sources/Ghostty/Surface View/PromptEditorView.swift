import AppKit
import Combine
import GhosttyKit

extension Ghostty {
    /// Native CoreText prompt editor anchored to the bottom of a
    /// SurfaceView. The view's TOP edge sits at the shell's current
    /// cursor row (the prompt) and extends down through the viewport's
    /// bottom edge (including the renderer's bottom padding). The
    /// editor is composed of a 1-row header strip showing the actual
    /// shell prompt text + a hairline, and below that an NSTextView for
    /// input. The header bar visually covers the shell's empty prompt
    /// row in the terminal grid, so the prompt only ever lives within
    /// the editor.
    final class PromptEditorView: NSView {
        weak var owner: SurfaceView?

        let scrollView: NSScrollView
        let textView: PromptEditorTextView
        let headerView: PromptHeaderView

        /// Minimum input rows so the editor never collapses below
        /// usable. Total floor for the editor is 1 header + this =
        /// 3 rows.
        private static let minInputRows: Int = 2

        /// Cached row count we last reported to libghostty.
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
            // Match horizontal padding of the header so the typed
            // text lines up with the prompt label on the left edge.
            textView.textContainerInset = NSSize(width: 4, height: 0)

            scrollView.documentView = textView
            addSubview(scrollView)

            textView.owner = owner
            textView.commitHandler = { [weak self] in self?.commit() }
            textView.contentDidChangeHandler = { [weak self] in
                self?.syncHeightToContent()
            }

            pwdCancellable = owner.$pwd.sink { [weak self] _ in
                DispatchQueue.main.async { self?.refreshHeaderText() }
            }
        }

        required init?(coder: NSCoder) {
            fatalError("init(coter:) is not supported")
        }

        override func layout() {
            super.layout()
            guard let owner else { return }
            let cellHeight = owner.cellSize.height > 0 ? owner.cellSize.height : 17
            let h = bounds.height
            let w = bounds.width
            // Bottom padding (in points) we extend down through so the
            // editor visually meets the window's bottom edge with no
            // gap. macOS coordinate system is y-up.
            let bottomPad = currentBottomPaddingPoints()
            // Header is the topmost cellHeight; scroll fills below it
            // and through the bottom padding region.
            let headerY = h - cellHeight
            headerView.frame = NSRect(x: 0, y: headerY, width: w, height: cellHeight)
            scrollView.frame = NSRect(x: 0, y: 0, width: w, height: max(0, headerY))
            // Mark the bottom padding region (within the scrollView)
            // so it draws the editor background, not exposed terminal.
            // (NSScrollView draws bg if drawsBackground is true.)
            _ = bottomPad // height already includes it
        }

        /// Show the bar. Computes initial layout using the available
        /// space below the cursor + the content size, pushes the row
        /// count to libghostty, refreshes the prompt text, and grabs
        /// first responder.
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
        /// header.
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
            needsLayout = true
        }

        private func loadTerminalFont(for owner: SurfaceView) -> NSFont {
            let fallback = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
            guard let cSurface = owner.surface else { return fallback }
            guard let raw = ghostty_surface_quicklook_font(cSurface) else { return fallback }
            let unmanaged = Unmanaged<CTFont>.fromOpaque(raw)
            let ctFont = unmanaged.takeUnretainedValue()
            unmanaged.release()
            return ctFont as NSFont
        }

        /// Recompute the editor's view height and tell libghostty how
        /// much CONTENT we have (header + typed input lines). The
        /// renderer applies its own `max(content, T - cursor.y, 3)`
        /// each frame, so we never report the inflated total — that
        /// would carry across the commit gap and make the renderer
        /// over-reserve once the shell prints output and lands the
        /// next prompt at a higher row.
        func syncHeightToContent() {
            guard let owner else { return }
            let cellHeight = owner.cellSize.height > 0 ? owner.cellSize.height : 17
            let inputRows = currentLineCount(cellHeight: cellHeight)
            let geom = currentGeometry()
            let availRows = max(3, Int(geom.avail_rows))
            let bottomPadPoints = currentBottomPaddingPoints()

            // Local size = max(content+header, available below cursor,
            // floor). Same formula the renderer applies — they
            // converge each frame.
            let totalRows = max(max(inputRows + 1, availRows), 3)
            let desiredHeight = CGFloat(totalRows) * cellHeight + bottomPadPoints

            if abs(frame.height - desiredHeight) > 0.5 {
                layoutAtBottom(in: owner, height: desiredHeight)
            }
            // Report ONLY content rows (1 header + N input lines) to
            // the renderer — never the inflated total. The renderer
            // takes the live cursor row into account separately.
            let contentRows = inputRows + 1
            if contentRows != reportedRows {
                reportedRows = contentRows
                if let cSurface = owner.surface {
                    ghostty_surface_set_editor_rows(cSurface, UInt32(contentRows))
                }
            }
        }

        private func currentLineCount(cellHeight: CGFloat) -> Int {
            guard let lm = textView.layoutManager,
                let tc = textView.textContainer else { return Self.minInputRows }
            lm.ensureLayout(for: tc)
            let used = lm.usedRect(for: tc).height
            if used <= 0 { return Self.minInputRows }
            return max(Self.minInputRows, Int(ceil(used / cellHeight)))
        }

        private func currentGeometry() -> ghostty_editor_geometry_s {
            guard let cSurface = owner?.surface else {
                return ghostty_editor_geometry_s(
                    avail_rows: 3,
                    bottom_padding_px: 0,
                    cols: 80
                )
            }
            return ghostty_surface_editor_geometry(cSurface)
        }

        /// Bottom padding in POINTS. libghostty reports it in pixels;
        /// divide by the screen's backing scale factor to get points.
        private func currentBottomPaddingPoints() -> CGFloat {
            let geom = currentGeometry()
            let scale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
            return CGFloat(geom.bottom_padding_px) / scale
        }

        /// Pull the shell's actual prompt text out of the terminal cells
        /// and display it in the header. Falls back to derived
        /// `user@host pwd` if the read fails.
        func refreshHeaderText() {
            if let composed = readShellPromptFromTerminal(), !composed.isEmpty {
                headerView.setText(composed)
                return
            }
            headerView.setText(derivedPromptText())
        }

        private func readShellPromptFromTerminal() -> String? {
            guard let owner, let cSurface = owner.surface else { return nil }
            var raw = ghostty_text_s()
            guard ghostty_surface_read_prompt(cSurface, &raw) else { return nil }
            defer { ghostty_surface_free_text(cSurface, &raw) }
            guard let cstr = raw.text else { return nil }
            let s = String(cString: cstr)
            let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }

        private func derivedPromptText() -> String {
            let user = NSUserName()
            let rawHost = Host.current().localizedName ?? ProcessInfo.processInfo.hostName
            let host = rawHost
                .replacingOccurrences(of: ".local", with: "")
                .replacingOccurrences(of: ".lan", with: "")
            let pwd = abbreviatePath(owner?.pwd)
            if pwd.isEmpty {
                return "\(user)@\(host)"
            } else {
                return "\(user)@\(host) \(pwd)"
            }
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

            // Block separator: write a styled horizontal rule with the
            // command name + timestamp into the terminal cells before
            // we ship the command to the PTY. The shell's echo of the
            // command lands on the line below the separator, then the
            // command's output flows. When the user scrolls back
            // through history, the separator marks where each command
            // started — restoring the prompt-context that the bare
            // shell-echo of `ls` (without our editor's prompt header)
            // otherwise lacks.
            let sep = buildBlockSeparator(command: payload, owner: owner)
            sep.withCString { cstr in
                ghostty_surface_inject_output(cSurface, cstr, UInt(strlen(cstr)))
            }

            payload.withCString { cstr in
                let len = strlen(cstr)
                ghostty_surface_editor_commit(cSurface, cstr, UInt(len))
            }
            textView.string = ""
            syncHeightToContent()
        }

        /// Build the per-command block separator that gets written to
        /// the terminal cells on commit. Format:
        ///
        ///     ─── ls ─────────────────────────────────── 14:59 ───
        ///
        /// Styled dim cyan via ANSI. Width is computed to fit the
        /// current grid column count exactly so the line spans the
        /// viewport edge-to-edge.
        private func buildBlockSeparator(
            command: String,
            owner: SurfaceView
        ) -> String {
            let geom = currentGeometry()
            let cols = max(20, Int(geom.cols))

            // Match the macOS menu-bar date/time format:
            //   "Sun May 3 4:54 a.m."
            // - EEE / MMM / d → no leading zeros
            // - h:mm → 12-hour, hour without leading zero
            // - amSymbol / pmSymbol overrides default "AM"/"PM" → "a.m."/"p.m."
            let formatter = DateFormatter()
            formatter.dateFormat = "EEE MMM d h:mm a"
            formatter.amSymbol = "a.m."
            formatter.pmSymbol = "p.m."
            let stamp = formatter.string(from: Date())

            // The label inside the separator is the captured shell
            // prompt (e.g. "wrb@Mac ghostty %") + the typed command —
            // exactly what a normal terminal entry looks like. Falls
            // back to derived `user@host pwd %` when no prompt is
            // cached yet.
            let oneLineCmd = command
                .replacingOccurrences(of: "\n", with: " ")
                .trimmingCharacters(in: .whitespaces)
            let promptText = readShellPromptFromTerminal() ?? derivedPromptText()
            let labelRaw = promptText.isEmpty
                ? oneLineCmd
                : "\(promptText) \(oneLineCmd)"
            let label = String(labelRaw.prefix(160))

            // Heavier glyph (U+2501 ━) + bold + cyan = visible without
            // shouting. Two cells of padding around the label so the
            // text breathes inside the rule.
            let prefix = "━━━  \(label)  "
            let suffix = "  \(stamp) ━━━"
            // -1 from cols to give one column of slack so a perfectly-
            // cols-wide line doesn't trigger implicit wrap.
            let dashes = max(3, (cols - 1) - prefix.count - suffix.count)
            let middle = String(repeating: "━", count: dashes)
            let body = prefix + middle + suffix

            // Leading \r\n → leave one blank row above the separator
            //   for breathing room (the \r resets cursor X in case it
            //   was parked at the editor's input column on commit).
            // \x1b[1;36m → bold + cyan.
            // Trailing \r\n\r\n → advance cursor TWO rows past the
            //   separator. The first \r\n is the row the shell's echo
            //   will land on (stream handler erases it); the second
            //   \r\n is a blank padding row that survives the erase
            //   and sits between the separator and the first line of
            //   real output.
            return "\r\n\u{1B}[1;36m\(body)\u{1B}[0m\r\n\r\n"
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

    /// Header strip at the top of the prompt editor. Draws the shell's
    /// prompt label flush-left + a hairline that extends from the end
    /// of the label out to the right edge — the line never cuts
    /// through the text. Vertically the label and hairline share a
    /// baseline (the line sits just below the text baseline).
    final class PromptHeaderView: NSView {
        private var text: String = ""
        private var labelFont: NSFont = .monospacedSystemFont(ofSize: 13, weight: .regular)
        private var labelColor: NSColor = .labelColor
        private var bgColor: NSColor = .windowBackgroundColor
        private var lineColor: NSColor = .separatorColor

        /// Horizontal pad on the left edge before the prompt text.
        private static let leftPad: CGFloat = 4
        /// Gap between the end of the prompt text and the start of the
        /// hairline.
        private static let textLineGap: CGFloat = 8
        /// Horizontal pad on the right edge after the hairline.
        private static let rightPad: CGFloat = 8

        override init(frame frameRect: NSRect) {
            super.init(frame: frameRect)
            wantsLayer = true
        }

        required init?(coder: NSCoder) {
            fatalError("init(coder:) is not supported")
        }

        func setText(_ s: String) {
            text = s
            needsDisplay = true
        }

        func applyTheme(bg: NSColor, fg: NSColor, accent: NSColor, font: NSFont) {
            bgColor = bg
            labelColor = fg
            // Match the terminal font exactly so the prompt in the
            // header reads as a continuation of the prompt that would
            // otherwise show on the bottom row.
            labelFont = font
            // Hairline color: cursor accent at moderate alpha for
            // visual continuity with the caret.
            lineColor = accent.withAlphaComponent(0.5)
            layer?.backgroundColor = bg.cgColor
            needsDisplay = true
        }

        override var isFlipped: Bool { false }

        override func draw(_ dirtyRect: NSRect) {
            super.draw(dirtyRect)

            // Background fill.
            bgColor.setFill()
            bounds.fill()

            // Compute text size + draw position.
            let attrs: [NSAttributedString.Key: Any] = [
                .font: labelFont,
                .foregroundColor: labelColor,
            ]
            let attr = NSAttributedString(string: text, attributes: attrs)
            let size = attr.size()
            let textX: CGFloat = Self.leftPad
            // Vertical baseline: center the text in the row. macOS
            // y-up; the .draw(at:) origin is the bottom-left of the
            // text box.
            let textY: CGFloat = (bounds.height - size.height) / 2
            attr.draw(at: NSPoint(x: textX, y: textY))

            // Hairline from end of text to right edge, baseline-aligned
            // (just below the text baseline so the line visually
            // connects with the bottom of the glyphs).
            let lineStartX = textX + ceil(size.width) + Self.textLineGap
            let lineEndX = bounds.width - Self.rightPad
            if lineEndX > lineStartX {
                lineColor.setFill()
                // Place the hairline at the visual baseline of the
                // text — typically (font.descender is negative) at
                // textY + |descender| from the bottom of the text box.
                // For a clean look we use the geometric center of the
                // text vertical extent.
                let lineY = textY + size.height * 0.18
                let line = NSRect(
                    x: lineStartX,
                    y: lineY,
                    width: lineEndX - lineStartX,
                    height: 1)
                line.fill()
            }
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
            // Cmd+Shift+C → copy the previous command's output to
            // the clipboard. Bubbles up to SurfaceView's handler so
            // the editor-focused and terminal-focused paths share
            // implementation.
            if isCopyPreviousChord(event) {
                owner?.copyPreviousCommandOutput()
                return
            }
            super.keyDown(with: event)
        }

        private func isCopyPreviousChord(_ event: NSEvent) -> Bool {
            let mods = event.modifierFlags.intersection(
                [.command, .shift, .option, .control])
            guard mods == [.command, .shift] else { return false }
            // `c` (lowercase) ignoring modifiers — Cmd+Shift+C reports
            // as uppercase `C` in `characters` because Shift is held,
            // but `charactersIgnoringModifiers` returns lowercase.
            return event.charactersIgnoringModifiers?.lowercased() == "c"
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
