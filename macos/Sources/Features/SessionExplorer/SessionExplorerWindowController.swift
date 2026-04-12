import AppKit
import SwiftUI

@MainActor
final class SessionExplorerWindowController: NSWindowController, NSWindowDelegate {
    var onClose: (() -> Void)?

    private let assertController: SessionAssertController

    convenience init() {
        guard let appDelegate = NSApp.delegate as? AppDelegate else {
            preconditionFailure("Session Explorer requires the Ghostty app delegate.")
        }

        self.init(assertController: SessionAssertController(ghostty: appDelegate.ghostty))
    }

    init(assertController: SessionAssertController) {
        self.assertController = assertController

        let window = SessionExplorerWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1020, height: 700),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Session Explorer"
        window.center()
        window.tabbingMode = .disallowed

        window.contentView = NSHostingView(
            rootView: SessionExplorerView(
                refreshLiveState: {
                    explorerDebugLog("refreshLiveState requested")
                    let json = await MainActor.run {
                        SurfaceListSnapshotter.snapshot()
                    }

                    do {
                        let snapshot = try ExplorerSnapshot.fromSurfaceListSnapshot(json)
                        explorerDebugLog(
                            "refreshLiveState succeeded: windows=\(snapshot.windows.count)"
                        )
                        return snapshot
                    } catch {
                        explorerDebugLog("refreshLiveState failed: error=\(error)")
                        return nil
                    }
                },
                computeDiff: { session, liveState in
                    guard let live = liveState else {
                        explorerDebugLog(
                            "computeDiff skipped: session_id=\(session.id) live_state=nil"
                        )
                        return nil
                    }

                    let diff = SessionDiff.diff(session: session.snapshot, live: live)
                    explorerDebugLog(
                        "computeDiff completed: session_id=\(session.id) windows=\(diff.windows.count) missing=\(diff.missingCount) partial=\(diff.partialCount) match=\(diff.matchCount)"
                        )
                    return diff
                },
                onSnapshotCurrent: { [weak assertController] in
                    explorerDebugLog("onSnapshotCurrent invoked")
                    assertController?.snapshotCurrent()
                },
                onAssertSnapshot: { [weak assertController] snapshot in
                    explorerDebugLog(
                        "onAssertSnapshot closure fired: windows=\(snapshot.windows.count)"
                    )
                    guard let ac = assertController else {
                        explorerDebugLog("onAssertSnapshot aborted: assertController released")
                        return
                    }
                    Task { @MainActor in await ac.assertAll(snapshot) }
                },
                onAssertWindow: { [weak assertController] window in
                    explorerDebugLog(
                        "onAssertWindow closure fired: window_id=\(window.id) title=\(window.displayTitle)"
                    )
                    guard let ac = assertController else {
                        explorerDebugLog("onAssertWindow aborted: assertController released")
                        return
                    }
                    Task { @MainActor in await ac.assertWindow(window) }
                },
                onAssertTemplate: { [weak assertController] template in
                    explorerDebugLog(
                        "onAssertTemplate closure fired: template_id=\(template.id) windows=\(template.windows.count)"
                    )
                    guard let ac = assertController else {
                        explorerDebugLog("onAssertTemplate aborted: assertController released")
                        return
                    }
                    Task { @MainActor in await ac.assertTemplate(template) }
                }
            )
        )

        super.init(window: window)

        window.delegate = self
        window.isReleasedWhenClosed = false
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func windowWillClose(_ notification: Notification) {
        onClose?()
    }

    @objc func performClose(_ sender: Any?) {
        window?.close()
    }
}

/// Custom window that intercepts standard keyboard shortcuts before Ghostty's
/// terminal-oriented event handlers can eat them. Non-terminal windows need
/// standard AppKit text editing behavior (paste, copy, cut, undo, select-all).
final class SessionExplorerWindow: NSWindow {
    /// Standard edit actions that text fields and text views handle natively.
    /// We forward these to the first responder before the menu system or
    /// Ghostty's local event monitor can consume them.
    private static let editShortcuts: Set<String> = ["v", "c", "x", "a", "z"]

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard event.modifierFlags.contains(.command),
              !event.modifierFlags.contains(.option),
              let chars = event.charactersIgnoringModifiers else {
            return super.performKeyEquivalent(with: event)
        }

        // ⌘W → close window
        if chars == "w" && !event.modifierFlags.contains(.shift) {
            close()
            return true
        }

        // ⌘V/C/X/A/Z (and ⇧⌘Z for redo) → forward to first responder so
        // NSTextField / NSTextView handle paste, copy, cut, select-all, undo
        // before Ghostty's terminal paste action steals the event.
        if Self.editShortcuts.contains(chars) {
            if let responder = firstResponder {
                let action: Selector = switch chars {
                case "v": #selector(NSText.paste(_:))
                case "c": #selector(NSText.copy(_:))
                case "x": #selector(NSText.cut(_:))
                case "a": #selector(NSText.selectAll(_:))
                case "z": event.modifierFlags.contains(.shift)
                    ? #selector(UndoManager.redo)
                    : #selector(UndoManager.undo)
                default: #selector(NSText.paste(_:))
                }
                if responder.responds(to: action) {
                    responder.doCommand(by: action)
                    return true
                }
            }
        }

        return super.performKeyEquivalent(with: event)
    }
}
