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
    /// Yabai space index recorded at snapshot time. Used to place the window
    /// on the correct space when restoring.
    let workspace: Int?
}

struct SessionTab: Decodable {
    let id: String?
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
        ghostty: Ghostty.App,
        mergeExistingWindows: Bool = true
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

        AutoStateSaver.shared.beginSuppression(reason: "session-restore")
        var latestScheduledDelay: TimeInterval = 0
        defer {
            AutoStateSaver.shared.endSuppression(
                after: latestScheduledDelay + 5,
                reason: "session-restore"
            )
        }

        let windowsToRestore = session.windows

        // Snapshot existing windows keyed by title.
        let existing = mergeExistingWindows ? snapshotExistingWindows() : [:]

        let ourPID = ProcessInfo.processInfo.processIdentifier

        // Each window opens its first tab after a delay, then its remaining tabs
        // are staggered within that window. This keeps the main thread free.
        //
        // Timing:
        //   window i opens at:          windowInterval * i
        //   tab j of window i opens at: windowInterval * i  +  tabInterval * j
        //   yabai placement at:         windowInterval * i  +  1.5
        let windowInterval = 6.0  // seconds between window creations
        let tabInterval    = 3.0  // seconds between tab additions within a window

        let windowMap: [String: String] = [:]

        Ghostty.logger.info("session restore: scheduling \(windowsToRestore.count) window(s)…")

        for (windowIndex, sessionWindow) in windowsToRestore.enumerated() {
            let windowTitle = sessionWindow.title ?? sessionWindow.id
            let windowDeadline = DispatchTime.now() + windowInterval * Double(windowIndex)

            if let match = existing[windowTitle] {
                match.primaryController.stateWindowID = sessionWindow.id
                // Window already open — stagger any missing tabs from where we are now.
                let existingTabTitles = match.tabTitles
                var tabOffset = 0
                for tab in sessionWindow.tabs {
                    let tabTitle = tab.title ?? windowTitle
                    guard !existingTabTitles.contains(tabTitle) else { continue }
                    tabOffset += 1
                    latestScheduledDelay = max(
                        latestScheduledDelay,
                        windowInterval * Double(windowIndex) + tabInterval * Double(tabOffset)
                    )
                    let tabDeadline = windowDeadline + tabInterval * Double(tabOffset)
                    let controller = match.primaryController
                    DispatchQueue.main.asyncAfter(deadline: tabDeadline) {
                        addTab(tab, to: controller, ghostty: ghostty)
                        Ghostty.logger.info("session restore: added missing tab '\(tabTitle)' to '\(windowTitle)'")
                    }
                }
                Ghostty.logger.info("session restore: window '\(windowTitle)' exists — \(tabOffset) tab(s) queued")

            } else {
                guard !sessionWindow.tabs.isEmpty else { continue }

                let windowDelay = windowInterval * Double(windowIndex)
                latestScheduledDelay = max(
                    latestScheduledDelay,
                    windowDelay + tabInterval * Double(max(0, sessionWindow.tabs.count - 1))
                )
                DispatchQueue.main.asyncAfter(deadline: windowDeadline) {
                    // Re-snapshot yabai IDs right before creating this window.
                    let idsBeforeCreate = Set(
                        YabaiHelper.queryWindows().filter { $0.pid == ourPID }.map(\.id)
                    )

                    let firstTab = sessionWindow.tabs[0]
                    let tree = SplitTree<Ghostty.SurfaceView>(root: firstTab.surfaceTree.root, zoomed: nil).equalized()
                    let controller = TerminalController(ghostty, withSurfaceTree: tree)
                    // Stamp the canonical state window ID on this controller
                    // so save flows match by identity, not by the focused
                    // tab's title (which may differ from the "window
                    // concept" name like "games" vs "breen-switch").
                    controller.stateWindowID = sessionWindow.id
                    controller.stateTabID = firstTab.id
                    controller.showWindow(nil)

                    if let title = firstTab.title ?? sessionWindow.title {
                        controller.titleOverride = title
                    }

                    if let window = controller.window, let screen = window.screen ?? NSScreen.main {
                        window.setFrame(screen.visibleFrame, display: true)
                    }

                    let spaceNote = sessionWindow.workspace.map { " → space \($0)" } ?? ""
                    Ghostty.logger.info(
                        "session restore: opened '\(windowTitle)'\(spaceNote) — staggering \(sessionWindow.tabs.count - 1) tab(s)"
                    )

                    // Stagger remaining tabs within this window.
                    for (tabIndex, tab) in sessionWindow.tabs.dropFirst().enumerated() {
                        let tabDeadline = DispatchTime.now() + tabInterval * Double(tabIndex + 1)
                        DispatchQueue.main.asyncAfter(deadline: tabDeadline) {
                            addTab(tab, to: controller, ghostty: ghostty)
                            Ghostty.logger.info(
                                "session restore: added tab \(tabIndex + 1)/\(sessionWindow.tabs.count - 1) to '\(windowTitle)'"
                            )
                        }
                    }

                    // Place window on correct yabai space shortly after it appears.
                    if let targetSpace = sessionWindow.workspace {
                        DispatchQueue.main.asyncAfter(deadline: DispatchTime.now() + 1.5) {
                            placeWindow(
                                ourPID: ourPID,
                                existingIDs: idsBeforeCreate,
                                targetSpace: targetSpace,
                                windowTitle: windowTitle
                            )
                        }
                    }
                }
            }
        }

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

    /// Find the newly created yabai window (not in existingIDs) and move it to targetSpace.
    private static func placeWindow(
        ourPID: Int32,
        existingIDs: Set<Int>,
        targetSpace: Int,
        windowTitle: String
    ) {
        let newWindows = YabaiHelper.queryWindows()
            .filter { $0.pid == ourPID && !existingIDs.contains($0.id) }

        guard let newWin = newWindows.max(by: { $0.id < $1.id }) else {
            Ghostty.logger.warning("session restore: could not find new yabai window for '\(windowTitle)'")
            return
        }

        if newWin.space != targetSpace {
            let ok = YabaiHelper.moveWindow(id: newWin.id, toSpace: targetSpace)
            Ghostty.logger.info(
                "session restore: moved yabai window \(newWin.id) to space \(targetSpace) — \(ok ? "ok" : "failed")"
            )
        }
    }

    /// Add a single session tab to an existing window.
    private static func addTab(
        _ tab: SessionTab,
        to primaryController: BaseTerminalController,
        ghostty: Ghostty.App
    ) {
        let tabTree = SplitTree<Ghostty.SurfaceView>(root: tab.surfaceTree.root, zoomed: nil).equalized()
        let tabController = TerminalController(ghostty, withSurfaceTree: tabTree)
        // Inherit the state window ID from the primary so all tabs in the
        // group share one identity for save matching.
        tabController.stateWindowID = primaryController.stateWindowID
        tabController.stateTabID = tab.id

        if let title = tab.title {
            tabController.titleOverride = title
        }

        guard let primaryWindow = primaryController.window,
              let tabWindow = tabController.window else { return }

        // Append the new tab at the END of the tab group so tabs come back in
        // the same order they were saved. `ordered: .above` inserts the new
        // window *after* the receiver in the tab strip, so we have to call it
        // on the current last window — calling it on `primaryWindow` would
        // insert each new tab right after the first, producing reverse order.
        let anchor = primaryWindow.tabGroup?.windows.last ?? primaryWindow
        anchor.addTabbedWindowSafely(tabWindow, ordered: .above)
    }
}
