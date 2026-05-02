import AppKit
import GhosttyKit

extension Ghostty {
    /// Native CoreText prompt-editor bar pinned to the bottom of a SurfaceView.
    /// Wraps an NSTextView in an NSScrollView so the editor can scroll its own
    /// contents independently of the terminal grid.
    final class PromptEditorView: NSView {
        weak var owner: SurfaceView?
        let scrollView: NSScrollView
        let textView: PromptEditorTextView
        /// 1px hairline at the top of the bar that visually separates the
        /// editor from the terminal output above it.
        let separator: NSBox

        /// Height of the top separator in points.
        private static let separatorHeight: CGFloat = 1

        init(owner: SurfaceView) {
            self.owner = owner
            self.scrollView = NSScrollView(frame: .zero)
            self.textView = PromptEditorTextView(frame: .zero)
            self.separator = NSBox(frame: .zero)
            super.init(frame: .zero)

            separator.boxType = .separator
            addSubview(separator)

            scrollView.hasVerticalScroller = true
            scrollView.hasHorizontalScroller = false
            scrollView.borderType = .noBorder
            scrollView.drawsBackground = true

            textView.isRichText = false
            textView.allowsUndo = true
            textView.usesFindBar = false
            textView.isAutomaticQuoteSubstitutionEnabled = false
            textView.isAutomaticDashSubstitutionEnabled = false
            textView.isAutomaticTextReplacementEnabled = false
            textView.isAutomaticSpellingCorrectionEnabled = false
            textView.smartInsertDeleteEnabled = false
            // Zero vertical inset so the first text glyph sits flush
            // beneath the separator — the user wants the edit area
            // immediately below the bottom of the terminal results.
            textView.textContainerInset = NSSize(width: 4, height: 0)

            scrollView.documentView = textView
            addSubview(scrollView)

            textView.owner = owner
            textView.commitHandler = { [weak self] in self?.commit() }
        }

        required init?(coder: NSCoder) {
            fatalError("init(coder:) is not supported")
        }

        override func layout() {
            super.layout()
            let h = bounds.height
            let w = bounds.width
            let sepH = Self.separatorHeight
            // macOS coordinates: y=0 is bottom. Separator pins to top,
            // scrollView fills everything below.
            separator.frame = NSRect(x: 0, y: h - sepH, width: w, height: sepH)
            scrollView.frame = NSRect(x: 0, y: 0, width: w, height: max(0, h - sepH))
        }

        /// Show the bar at the given desired height (rows × cellHeight). Pins
        /// to the bottom of the parent SurfaceView and grabs first responder
        /// so the user can immediately type.
        func activate(rows: UInt32) {
            guard let owner else { return }
            let cellHeight = owner.cellSize.height > 0 ? owner.cellSize.height : 17
            let desiredRows = max(2, CGFloat(rows))
            // Add the separator's height to the natural row-based height
            // so the visible text area stays exactly `desiredRows` tall
            // and the separator sits one px above it.
            let desiredHeight = desiredRows * cellHeight + Self.separatorHeight
            layoutAtBottom(in: owner, height: desiredHeight)
            isHidden = false
            owner.window?.makeFirstResponder(textView)
        }

        func deactivate() {
            isHidden = true
            textView.string = ""
            yieldFocusToTerminal()
        }

        /// Pull theme colors and the terminal's primary font from the
        /// owning surface and push them into the NSTextView. Called on
        /// activate and on derivedConfig changes.
        func applyTheme() {
            guard let owner else { return }
            let bg = NSColor(owner.derivedConfig.backgroundColor)
            let fg = NSColor(owner.derivedConfig.foregroundColor)
            let caret = NSColor(owner.derivedConfig.cursorColor)
            textView.backgroundColor = bg
            textView.textColor = fg
            textView.insertionPointColor = caret
            scrollView.backgroundColor = bg

            // Pull the terminal's exact CoreText primary font (already
            // scaled for display points) from libghostty so the editor
            // reads as the same surface as the rest of the terminal.
            // Falls back to the system mono if the surface isn't ready
            // or libghostty isn't using CoreText.
            let font = loadTerminalFont(for: owner)
            textView.font = font

            textView.typingAttributes = [
                .font: font,
                .foregroundColor: fg,
            ]
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
        }

        /// Move first responder back to the terminal SurfaceView. Called on
        /// deactivate so the user can drive vim / etc. once the editor
        /// is hidden.
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
