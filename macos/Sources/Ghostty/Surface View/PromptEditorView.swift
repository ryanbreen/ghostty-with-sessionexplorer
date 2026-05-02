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
        }

        required init?(coder: NSCoder) {
            fatalError("init(coder:) is not supported")
        }

        /// Show the bar at the given desired height (rows × cellHeight). Pins
        /// to the bottom of the parent SurfaceView.
        func activate(rows: UInt32) {
            guard let owner else { return }
            let cellHeight = owner.cellSize.height > 0 ? owner.cellSize.height : 17
            let desiredRows = max(2, CGFloat(rows))
            let desiredHeight = desiredRows * cellHeight
            layoutAtBottom(in: owner, height: desiredHeight)
            isHidden = false
        }

        func deactivate() {
            isHidden = true
            textView.string = ""
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

    /// NSTextView subclass for the prompt editor. Currently a stub —
    /// commit / hotkey behavior lands in a follow-up commit.
    final class PromptEditorTextView: NSTextView {
        // Stub for now. Commit-on-Enter and Option-Up arrive in Commit 2.
    }
}
