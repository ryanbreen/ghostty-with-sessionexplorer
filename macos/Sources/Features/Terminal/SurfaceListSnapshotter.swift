import AppKit
import Darwin
import GhosttyKit

/// Captures all currently open terminal surfaces as a flat JSON array.
@MainActor
enum SurfaceListSnapshotter {
    static func snapshot() -> String {
        let focusedSurface = (NSApp.keyWindow?.windowController as? BaseTerminalController)?.focusedSurface
        let controllers = NSApp.orderedWindows.compactMap { $0.windowController as? BaseTerminalController }

        let document: [[String: Any]] = controllers.flatMap { controller in
            snapshot(controller: controller, focusedSurface: focusedSurface)
        }

        return encode(document)
    }

    static func snapshotWindow(controller: BaseTerminalController) -> String {
        let focusedSurface = controller.focusedSurface
        let tabControllers: [BaseTerminalController]
        if let tabGroup = controller.window?.tabGroup {
            tabControllers = tabGroup.windows.compactMap { $0.windowController as? BaseTerminalController }
        } else {
            tabControllers = [controller]
        }

        let document: [[String: Any]] = tabControllers.flatMap { controller in
            snapshot(controller: controller, focusedSurface: focusedSurface)
        }

        return encode(document)
    }

    private static func encode(_ document: [[String: Any]]) -> String {
        guard let data = try? JSONSerialization.data(
            withJSONObject: document,
            options: [.prettyPrinted, .sortedKeys]
        ), let json = String(data: data, encoding: .utf8) else {
            return "[]"
        }

        return json
    }

    private static func snapshot(
        controller: BaseTerminalController,
        focusedSurface: Ghostty.SurfaceView?
    ) -> [[String: Any]] {
        guard let window = controller.window else { return [] }
        guard let root = controller.surfaceTree.root else { return [] }

        let tabControllers: [BaseTerminalController]
        if let tabGroup = window.tabGroup {
            tabControllers = tabGroup.windows.compactMap { $0.windowController as? BaseTerminalController }
        } else {
            tabControllers = [controller]
        }

        let tabIndex = tabControllers.firstIndex(where: { $0 === controller }) ?? 0
        let tabTitle = controller.titleOverride ?? window.title

        // In AppKit's tabbed-window model every tab is its own NSWindow with a
        // distinct `windowNumber`. Grouping the flat snapshot back into windows
        // requires a stable ID shared by all tabs in the same tab group, so we
        // use the windowNumber of the first (primary) tab here. Fall back to
        // this tab's own windowNumber for single-window controllers.
        let primaryTabWindow = window.tabGroup?.windows.first ?? window
        let primaryController = primaryTabWindow.windowController as? BaseTerminalController
        let groupWindowID = primaryTabWindow.windowNumber
        let groupWindowTitle = primaryTabWindow.title
        let groupStateWindowID = controller.stateWindowID
            ?? primaryController?.stateWindowID
            ?? tabControllers.compactMap(\.stateWindowID).first
        let tabStateID = controller.stateTabID

        // Capture the yabai workspace for the primary tab's NSWindow so it
        // survives through to ExplorerWindow.workspace. Without this, every
        // saved window comes back with workspace=nil and lands on whatever
        // space yabai puts new windows on.
        let workspaceValue: Any = YabaiHelper.space(for: primaryTabWindow) ?? NSNull()

        return root.leaves().map { view in
            let workingDirectory: Any = view.pwd ?? NSNull()
            let (path, directions) = splitPathAndDirections(for: view, in: root)
            var surface: [String: Any] = [
                "surface_id": view.id.uuidString,
                "state_id": view.stateID ?? NSNull(),
                "window_state_id": groupStateWindowID ?? NSNull(),
                "tab_state_id": tabStateID ?? NSNull(),
                "window_id": groupWindowID,
                "window_title": groupWindowTitle,
                "window_workspace": workspaceValue,
                "tab_index": tabIndex,
                "tab_title": tabTitle,
                "split_path": path,
                "split_directions": directions,
                "pty_pid": NSNull(),
                "shell_pid": NSNull(),
                "foreground_pid": NSNull(),
                "foreground_process": NSNull(),
                "working_directory": workingDirectory,
                "is_focused": focusedSurface === view,
            ]

            if let cSurface = view.surface {
                let shellPid = ghostty_surface_child_pid(cSurface)
                if shellPid > 0 {
                    surface["shell_pid"] = shellPid
                }

                // Capture the foreground process so save paths can infer
                // a startup command (e.g. "lazygit running" → save lazygit
                // as the pane's command). Without this, brand-new windows
                // saved for the first time come back blank.
                let fgPid = ghostty_surface_foreground_pid(cSurface)
                if fgPid > 0 {
                    surface["foreground_pid"] = fgPid
                    if let name = processName(pid: pid_t(fgPid)) {
                        surface["foreground_process"] = name
                    }
                }
            }

            return surface
        }
    }

    /// Look up the executable name for a PID via libproc.
    private static func processName(pid: pid_t) -> String? {
        var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN))
        let result = proc_name(pid, &buffer, UInt32(buffer.count))
        guard result > 0 else { return nil }
        return String(cString: buffer)
    }

    private static func splitPath(
        for view: Ghostty.SurfaceView,
        in root: SplitTree<Ghostty.SurfaceView>.Node
    ) -> [Int] {
        splitPathAndDirections(for: view, in: root).0
    }

    /// Walks the path from `root` to the given view, returning both the
    /// branch indices (0=left, 1=right) and the direction string for each
    /// split node along the way ("horizontal" / "vertical"). The directions
    /// are required to reconstruct the tree losslessly — without them every
    /// vertical split silently becomes horizontal on rebuild.
    private static func splitPathAndDirections(
        for view: Ghostty.SurfaceView,
        in root: SplitTree<Ghostty.SurfaceView>.Node
    ) -> ([Int], [String]) {
        guard let treePath = root.path(to: .leaf(view: view)) else { return ([], []) }

        var indices: [Int] = []
        var directions: [String] = []
        var current: SplitTree<Ghostty.SurfaceView>.Node = root

        for component in treePath.path {
            guard case .split(let split) = current else { break }
            directions.append(split.direction == .horizontal ? "horizontal" : "vertical")
            switch component {
            case .left:
                indices.append(0)
                current = split.left
            case .right:
                indices.append(1)
                current = split.right
            }
        }

        return (indices, directions)
    }
}
