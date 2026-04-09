import AppKit
import GhosttyKit
import Darwin

/// Captures the full state of all Ghostty windows, tabs, and split panes
/// as a JSON document. This is the inverse of SessionRestore.

@MainActor
enum SessionSnapshotter {
    /// Capture the current state of all windows as a JSON string.
    static func snapshot() -> String {
        var windows: [[String: Any]] = []

        // Deduplicate by tab group (same logic as scriptWindows)
        var seen: Set<ObjectIdentifier> = []
        let controllers = NSApp.orderedWindows.compactMap {
            $0.windowController as? BaseTerminalController
        }

        for controller in controllers {
            guard let window = controller.window else { continue }

            // Find the primary controller for this tab group
            let primary: BaseTerminalController
            if let tabGroup = window.tabGroup,
               let first = tabGroup.windows.compactMap({ $0.windowController as? BaseTerminalController }).first {
                primary = first
            } else {
                primary = controller
            }

            let primaryID = ObjectIdentifier(primary)
            guard seen.insert(primaryID).inserted else { continue }

            // Get all controllers in this tab group
            let tabControllers: [BaseTerminalController]
            if let tabGroup = primary.window?.tabGroup {
                tabControllers = tabGroup.windows.compactMap {
                    $0.windowController as? BaseTerminalController
                }
            } else {
                tabControllers = [primary]
            }

            var tabs: [[String: Any]] = []
            for tabController in tabControllers {
                let tree = tabController.surfaceTree
                let treeDict = encodeNode(tree.root)
                var tabDict: [String: Any] = [
                    "surfaceTree": ["root": treeDict as Any]
                ]
                if let title = tabController.titleOverride {
                    tabDict["title"] = title
                } else if let windowTitle = tabController.window?.title, !windowTitle.isEmpty {
                    tabDict["title"] = windowTitle
                }
                tabs.append(tabDict)
            }

            let windowID = ScriptWindow.stableID(primaryController: primary)
            var windowDict: [String: Any] = [
                "id": windowID,
                "tabs": tabs
            ]
            if let title = primary.window?.title {
                windowDict["title"] = title
            }
            windows.append(windowDict)
        }

        let document: [String: Any] = [
            "version": 1,
            "windows": windows
        ]

        guard let data = try? JSONSerialization.data(withJSONObject: document, options: [.prettyPrinted, .sortedKeys]),
              let json = String(data: data, encoding: .utf8) else {
            return "{}"
        }
        return json
    }

    /// Recursively encode a SplitTree node to a dictionary.
    private static func encodeNode(_ node: SplitTree<Ghostty.SurfaceView>.Node?) -> [String: Any]? {
        guard let node else { return nil }

        switch node {
        case .leaf(let view):
            var surface: [String: Any] = [:]
            surface["id"] = view.id.uuidString
            if let pwd = view.pwd, !pwd.isEmpty {
                surface["pwd"] = pwd
            }
            surface["title"] = view.title
            surface["processExited"] = view.processExited

            // Get the foreground process info via the C API
            if let cSurface = view.surface {
                let pid = ghostty_surface_foreground_pid(cSurface)
                if pid > 0 {
                    surface["foregroundPid"] = pid
                    if let name = processName(pid: pid_t(pid)) {
                        surface["foregroundProcess"] = name
                    }
                }
            }

            return ["view": surface]

        case .split(let split):
            let direction: String = switch split.direction {
            case .horizontal: "horizontal"
            case .vertical: "vertical"
            }
            var splitDict: [String: Any] = [
                "direction": direction,
                "ratio": split.ratio
            ]
            if let left = encodeNode(split.left) {
                splitDict["left"] = left
            }
            if let right = encodeNode(split.right) {
                splitDict["right"] = right
            }
            return ["split": splitDict]
        }
    }

    /// Get the process name for a given PID using proc_name().
    private static func processName(pid: pid_t) -> String? {
        var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN))
        let result = proc_name(pid, &buffer, UInt32(buffer.count))
        guard result > 0 else { return nil }
        return String(cString: buffer)
    }
}
