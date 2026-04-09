import AppKit
import GhosttyKit

/// Restores a complete Ghostty session (windows, tabs, splits) from a JSON file.
///
/// The JSON format mirrors Ghostty's internal model. Each window contains an
/// ordered list of tabs, each tab contains a split tree of surface descriptors.
/// The caller provides opaque window IDs that are echoed back in the result so
/// it can map created windows to external state (e.g. workspace assignment).

// MARK: - Session Document Model

struct SessionDocument: Decodable {
    static let currentVersion = 1

    let version: Int
    let windows: [SessionWindow]
}

struct SessionWindow: Decodable {
    /// Opaque ID provided by the caller, echoed back in the result mapping.
    let id: String
    let title: String?
    let tabs: [SessionTab]
}

struct SessionTab: Decodable {
    let title: String?
    let surfaceTree: SessionSurfaceTree
}

/// A lightweight tree that decodes into a SplitTree<SurfaceView> at restore time.
/// This mirrors SplitTree.Node but uses the extended SurfaceView Codable
/// (with command, initialInput, environmentVariables, etc.).
struct SessionSurfaceTree: Decodable {
    let root: SplitTree<Ghostty.SurfaceView>.Node?
}

// MARK: - Errors

enum SessionRestoreError: Error, LocalizedError {
    case unsupportedVersion(Int)
    case noWindows

    var errorDescription: String? {
        switch self {
        case .unsupportedVersion(let v):
            return "Unsupported session version \(v) (expected \(SessionDocument.currentVersion))."
        case .noWindows:
            return "Session file contains no windows."
        }
    }
}

// MARK: - Restore Summary

struct RestoreSummary {
    var windowsCreated: Int = 0
    var tabsAdded: Int = 0
    var tabsSkipped: Int = 0

    var isEmpty: Bool { windowsCreated == 0 && tabsAdded == 0 }

    var description: String {
        if isEmpty {
            return "Nothing to restore — all windows and tabs are already open."
        }
        var parts: [String] = []
        if windowsCreated > 0 {
            parts.append("\(windowsCreated) window\(windowsCreated == 1 ? "" : "s") created")
        }
        if tabsAdded > 0 {
            parts.append("\(tabsAdded) tab\(tabsAdded == 1 ? "" : "s") added")
        }
        if tabsSkipped > 0 {
            parts.append("\(tabsSkipped) tab\(tabsSkipped == 1 ? "" : "s") already open")
        }
        return parts.joined(separator: ", ")
    }
}

// MARK: - Restorer

@MainActor
enum SessionRestorer {
    /// Restore a session from a JSON file, upserting against the current window state.
    ///
    /// - Parameters:
    ///   - filePath: Absolute path to the session JSON file (may be a symlink).
    ///   - ghostty: The running Ghostty app instance.
    /// - Returns: A dictionary mapping each session window ID to the created
    ///   Ghostty ScriptWindow stable ID (only populated for newly created windows).
    @discardableResult
    static func restore(
        from filePath: String,
        ghostty: Ghostty.App
    ) throws -> [String: String] {
        let url = URL(fileURLWithPath: filePath).resolvingSymlinksInPath()
        let data = try Data(contentsOf: url)
        let session = try JSONDecoder().decode(SessionDocument.self, from: data)

        guard session.version == SessionDocument.currentVersion else {
            throw SessionRestoreError.unsupportedVersion(session.version)
        }
        guard !session.windows.isEmpty else {
            throw SessionRestoreError.noWindows
        }

        // Snapshot existing windows keyed by title.
        // Each entry holds: the primary controller and a set of existing tab titles.
        let existing = snapshotExistingWindows()

        var summary = RestoreSummary()
        var windowMap: [String: String] = [:]

        for sessionWindow in session.windows {
            let windowTitle = sessionWindow.title ?? sessionWindow.id

            if let match = existing[windowTitle] {
                // Window exists — upsert missing tabs only.
                let existingTabTitles = match.tabTitles
                var addedToThisWindow = 0

                for tab in sessionWindow.tabs {
                    let tabTitle = tab.title ?? windowTitle
                    if existingTabTitles.contains(tabTitle) {
                        summary.tabsSkipped += 1
                        continue
                    }
                    addTab(tab, to: match.primaryController, ghostty: ghostty)
                    summary.tabsAdded += 1
                    addedToThisWindow += 1
                }

                if addedToThisWindow > 0 {
                    Ghostty.logger.info(
                        "session restore: window '\(windowTitle)' — added \(addedToThisWindow) tab(s)"
                    )
                } else {
                    Ghostty.logger.info(
                        "session restore: window '\(windowTitle)' — all tabs already open, skipped"
                    )
                }

            } else {
                // Window doesn't exist — create it with all tabs.
                guard let firstTab = sessionWindow.tabs.first else { continue }

                let tree = SplitTree<Ghostty.SurfaceView>(
                    root: firstTab.surfaceTree.root,
                    zoomed: nil
                )
                let controller = TerminalController(ghostty, withSurfaceTree: tree)
                controller.showWindow(nil)

                if let title = firstTab.title ?? sessionWindow.title {
                    controller.titleOverride = title
                }

                guard let window = controller.window else { continue }

                for tab in sessionWindow.tabs.dropFirst() {
                    addTab(tab, to: controller, ghostty: ghostty)
                }

                window.makeKeyAndOrderFront(nil)

                let stableID = ScriptWindow.stableID(primaryController: controller)
                windowMap[sessionWindow.id] = stableID
                summary.windowsCreated += 1

                Ghostty.logger.info(
                    "session restore: created window '\(windowTitle)' with \(sessionWindow.tabs.count) tab(s)"
                )
            }
        }

        Ghostty.logger.info("session restore complete — \(summary.description)")
        return windowMap
    }

    // MARK: - Helpers

    /// Snapshot existing terminal windows, keyed by window title.
    private static func snapshotExistingWindows() -> [String: (primaryController: BaseTerminalController, tabTitles: Set<String>)] {
        var result: [String: (primaryController: BaseTerminalController, tabTitles: Set<String>)] = [:]
        var seen: Set<ObjectIdentifier> = []

        let controllers = NSApp.orderedWindows.compactMap {
            $0.windowController as? BaseTerminalController
        }

        for controller in controllers {
            guard let window = controller.window else { continue }

            let primary: BaseTerminalController
            if let tabGroup = window.tabGroup,
               let first = tabGroup.windows
                   .compactMap({ $0.windowController as? BaseTerminalController })
                   .first {
                primary = first
            } else {
                primary = controller
            }

            let primaryID = ObjectIdentifier(primary)
            guard seen.insert(primaryID).inserted else { continue }

            let tabControllers: [BaseTerminalController]
            if let tabGroup = primary.window?.tabGroup {
                tabControllers = tabGroup.windows.compactMap {
                    $0.windowController as? BaseTerminalController
                }
            } else {
                tabControllers = [primary]
            }

            // Collect tab titles (titleOverride takes priority, then window title)
            let tabTitles = Set(tabControllers.compactMap { tc -> String? in
                tc.titleOverride ?? tc.window?.title
            })

            let windowTitle = primary.titleOverride ?? primary.window?.title ?? ""
            result[windowTitle] = (primaryController: primary, tabTitles: tabTitles)
        }

        return result
    }

    /// Add a single session tab to an existing window.
    private static func addTab(
        _ tab: SessionTab,
        to primaryController: BaseTerminalController,
        ghostty: Ghostty.App
    ) {
        let tabTree = SplitTree<Ghostty.SurfaceView>(root: tab.surfaceTree.root, zoomed: nil)
        let tabController = TerminalController(ghostty, withSurfaceTree: tabTree)

        if let title = tab.title {
            tabController.titleOverride = title
        }

        guard let primaryWindow = primaryController.window,
              let tabWindow = tabController.window else { return }

        primaryWindow.addTabbedWindowSafely(tabWindow, ordered: .above)
    }
}
