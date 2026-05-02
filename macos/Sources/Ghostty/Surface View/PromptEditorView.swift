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

        init(owner: SurfaceView) {
            self.owner = owner
            self.scrollView = NSScrollView(frame: .zero)
            self.textView = PromptEditorTextView(frame: .zero)
            super.init(frame: .zero)

            scrollView.autoresizingMask = [.width, .height]
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
            textView.font = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
            textView.textContainerInset = NSSize(width: 4, height: 2)

            scrollView.documentView = textView
            addSubview(scrollView)
            scrollView.frame = bounds

            textView.owner = owner
            textView.commitHandler = { [weak self] in self?.commit() }
        }

        required init?(coder: NSCoder) {
            fatalError("init(coder:) is not supported")
        }

        /// Show the bar at the given desired height (rows × cellHeight). Pins
        /// to the bottom of the parent SurfaceView and grabs first responder
        /// so the user can immediately type.
        func activate(rows: UInt32) {
            guard let owner else { return }
            let cellHeight = owner.cellSize.height > 0 ? owner.cellSize.height : 17
            let desiredRows = max(2, CGFloat(rows))
            let desiredHeight = desiredRows * cellHeight
            layoutAtBottom(in: owner, height: desiredHeight)
            isHidden = false
            owner.window?.makeFirstResponder(textView)
        }

        func deactivate() {
            isHidden = true
            textView.string = ""
            yieldFocusToTerminal()
        }

        /// Pull theme colors from the owning surface and push them into the
        /// NSTextView. Called on activate and on derivedConfig changes.
        func applyTheme() {
            guard let owner else { return }
            let bg = NSColor(owner.derivedConfig.backgroundColor)
            let fg = NSColor(owner.derivedConfig.foregroundColor)
            let caret = NSColor(owner.derivedConfig.cursorColor)
            textView.backgroundColor = bg
            textView.textColor = fg
            textView.insertionPointColor = caret
            scrollView.backgroundColor = bg
            // Re-apply the typing attributes so any next-typed character
            // picks up the new color even if the buffer is empty.
            textView.typingAttributes = [
                .font: textView.font ?? NSFont.monospacedSystemFont(ofSize: 13, weight: .regular),
                .foregroundColor: fg,
            ]
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
        /// Option-Up while the editor has focus, and on deactivate.
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
