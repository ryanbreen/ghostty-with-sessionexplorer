import AppKit
import GhosttyKit

/// Opens the focused tab as a full agent-layout tab: a 3-column, 5-pane split
/// where every surface lands in the same working directory and AI agents are
/// launched in the left column.
///
///   claude (top-left)  |  middle  |  right-top
///   codex  (bot-left)  |          |  right-bottom
///
/// The action adds a new tab with the agent layout, then closes the original
/// single-pane tab so the user ends up with the expanded view.

@MainActor
enum AgentLayout {

    /// Open the agent layout for the focused tab of `controller`.
    /// The directory is taken from the focused surface's pwd.
    static func openForFocused(controller: BaseTerminalController, ghostty: Ghostty.App) {
        guard let pwd = controller.focusedSurface?.pwd, !pwd.isEmpty else {
            Ghostty.logger.warning("agent layout: no pwd available from focused surface")
            return
        }
        open(directory: pwd, controller: controller, ghostty: ghostty)
    }

    /// Open the agent layout using an explicit directory.
    static func open(directory: String, controller: BaseTerminalController, ghostty: Ghostty.App) {
        let dir = (directory as NSString).expandingTildeInPath

        guard let tree = buildLayoutTree(directory: dir) else {
            Ghostty.logger.error("agent layout: failed to build split tree for '\(dir)'")
            return
        }

        let tabController = TerminalController(ghostty, withSurfaceTree: tree)
        let tabTitle = URL(fileURLWithPath: dir).lastPathComponent
        tabController.titleOverride = tabTitle

        guard let existingWindow = controller.window,
              let tabWindow = tabController.window else { return }

        existingWindow.addTabbedWindowSafely(tabWindow, ordered: .above)
        tabWindow.makeKeyAndOrderFront(nil)

        // Close the original tab (single-pane) if it had only one surface.
        let originalLeafCount = leafCount(controller.surfaceTree.root)
        if originalLeafCount <= 1 {
            existingWindow.close()
        }

        Ghostty.logger.info("agent layout: created tab '\(tabTitle)' at '\(dir)'")
    }

    // MARK: - Build the Layout Tree

    /// Build a 5-pane agent layout as a SplitTree decoded from JSON.
    /// Using JSON as the construction path lets us reuse the exact same
    /// surface initialisation path as session restore.
    ///
    ///   left-top (claude)    (0.33) | middle + right (0.67)
    ///   left-bottom (codex)         | middle (0.5) | right-top + right-bottom (0.5)
    ///                                                right-top (0.5)
    ///                                                right-bottom
    private static func buildLayoutTree(directory: String) -> SplitTree<Ghostty.SurfaceView>? {
        func surface(_ dir: String, command: String? = nil) -> [String: Any] {
            let shellEscaped = "'" + dir.replacingOccurrences(of: "'", with: "'\\''") + "'"
            var input = "cd -- \(shellEscaped)\n"
            if let command = command {
                input += command + "\n"
            }
            return [
                "pwd": dir,
                "initialInput": input
            ]
        }

        let s = surface(directory)

        let leftColumn: [String: Any] = [
            "split": [
                "direction": ["vertical": [:]],
                "ratio": 0.5,
                "left": ["view": surface(directory, command: "claude")],
                "right": ["view": surface(directory, command: "codex")]
            ]
        ]

        let rightColumn: [String: Any] = [
            "split": [
                "direction": ["vertical": [:]],
                "ratio": 0.5,
                "left": ["view": s],
                "right": ["view": s]
            ]
        ]

        let middleAndRight: [String: Any] = [
            "split": [
                "direction": ["horizontal": [:]],
                "ratio": 0.5,
                "left": ["view": s],
                "right": rightColumn
            ]
        ]

        let root: [String: Any] = [
            "split": [
                "direction": ["horizontal": [:]],
                "ratio": 0.33,
                "left": leftColumn,
                "right": middleAndRight
            ]
        ]

        guard let data = try? JSONSerialization.data(withJSONObject: ["root": root]),
              let treeWrapper = try? JSONDecoder().decode(SessionSurfaceTree.self, from: data) else {
            return nil
        }

        return SplitTree<Ghostty.SurfaceView>(root: treeWrapper.root, zoomed: nil)
    }

    // MARK: - Helpers

    private static func leafCount(_ node: SplitTree<Ghostty.SurfaceView>.Node?) -> Int {
        guard let node else { return 0 }
        switch node {
        case .leaf: return 1
        case .split(let s): return leafCount(s.left) + leafCount(s.right)
        }
    }
}
