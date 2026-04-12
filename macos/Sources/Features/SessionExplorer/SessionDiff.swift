import Foundation

struct SessionDiff {
    let windows: [WindowDiff]

    var matchCount: Int { windows.filter { $0.status == .match }.count }
    var missingCount: Int { windows.filter { $0.status == .missing }.count }
    var partialCount: Int { windows.filter { $0.status == .partial }.count }

    static func diff(session: ExplorerSnapshot, live: ExplorerSnapshot) -> SessionDiff {
        var remainingLiveWindows = live.windows
        var diffs: [WindowDiff] = []

        for (windowIndex, sessionWindow) in session.windows.enumerated() {
            if let liveIndex = bestWindowMatchIndex(for: sessionWindow, in: remainingLiveWindows) {
                let liveWindow = remainingLiveWindows.remove(at: liveIndex)
                diffs.append(compareWindow(sessionWindow, to: liveWindow, index: windowIndex))
            } else {
                let missingTabs = sessionWindow.tabs.enumerated().map { tabIndex, tab in
                    TabDiff(
                        id: tabDiffID(windowID: sessionWindow.id, tabIndex: tabIndex),
                        sessionTab: tab,
                        status: .missing,
                        panes: tab.surfaceTree.root.flattenedPanes().enumerated().map { paneIndex, pane in
                            PaneDiff(
                                id: paneDiffID(windowID: sessionWindow.id, tabIndex: tabIndex, paneIndex: paneIndex),
                                sessionView: pane.view,
                                position: pane.position,
                                status: .missing
                            )
                        }
                    )
                }

                diffs.append(
                    WindowDiff(
                        id: sessionWindow.id,
                        sessionWindow: sessionWindow,
                        status: .missing,
                        tabs: missingTabs
                    )
                )
            }
        }

        for (extraIndex, extraWindow) in remainingLiveWindows.enumerated() {
            diffs.append(extraWindowDiff(for: extraWindow, index: extraIndex))
        }

        return SessionDiff(windows: diffs)
    }

    private static func bestWindowMatchIndex(for sessionWindow: ExplorerWindow, in liveWindows: [ExplorerWindow]) -> Int? {
        if let titleMatchIndex = liveWindows.firstIndex(where: {
            $0.normalizedTitle == sessionWindow.normalizedTitle
        }) {
            return titleMatchIndex
        }

        return liveWindows.firstIndex(where: {
            $0.tabDirectorySignatureSet == sessionWindow.tabDirectorySignatureSet
        })
    }

    private static func compareWindow(_ sessionWindow: ExplorerWindow, to liveWindow: ExplorerWindow, index: Int) -> WindowDiff {
        var remainingLiveTabs = liveWindow.tabs
        var tabDiffs: [TabDiff] = []
        var matchedTabs = 0

        for (tabIndex, sessionTab) in sessionWindow.tabs.enumerated() {
            if let liveTabIndex = bestTabMatchIndex(for: sessionTab, in: remainingLiveTabs) {
                let liveTab = remainingLiveTabs.remove(at: liveTabIndex)
                let diff = compareTab(
                    sessionTab,
                    to: liveTab,
                    windowID: sessionWindow.id,
                    tabIndex: tabIndex
                )
                if diff.status == .match {
                    matchedTabs += 1
                }
                tabDiffs.append(diff)
            } else {
                tabDiffs.append(
                    TabDiff(
                        id: tabDiffID(windowID: sessionWindow.id, tabIndex: tabIndex),
                        sessionTab: sessionTab,
                        status: .missing,
                        panes: sessionTab.surfaceTree.root.flattenedPanes().enumerated().map { paneIndex, pane in
                            PaneDiff(
                                id: paneDiffID(windowID: sessionWindow.id, tabIndex: tabIndex, paneIndex: paneIndex),
                                sessionView: pane.view,
                                position: pane.position,
                                status: .missing
                            )
                        }
                    )
                )
            }
        }

        for (extraTabIndex, extraTab) in remainingLiveTabs.enumerated() {
            tabDiffs.append(extraTabDiff(for: extraTab, windowID: sessionWindow.id, tabIndex: sessionWindow.tabs.count + extraTabIndex))
        }

        let hasExtraTabs = tabDiffs.contains(where: { $0.status == .extra })
        let allHistoricalTabsMatch = matchedTabs == sessionWindow.tabs.count && !hasExtraTabs
        let status: DiffStatus
        if allHistoricalTabsMatch {
            status = .match
        } else if matchedTabs == 0 && tabDiffs.allSatisfy({ $0.status == .missing || $0.status == .extra }) {
            status = .partial
        } else {
            status = .partial
        }

        return WindowDiff(
            id: sessionWindow.id,
            sessionWindow: sessionWindow,
            status: status,
            tabs: tabDiffs
        )
    }

    private static func bestTabMatchIndex(for sessionTab: ExplorerTab, in liveTabs: [ExplorerTab]) -> Int? {
        if let directMatch = liveTabs.firstIndex(where: {
            $0.workingDirectorySignature == sessionTab.workingDirectorySignature
        }) {
            return directMatch
        }

        let sessionDirectories = Set(sessionTab.workingDirectories.map(\.normalizedForMatching))
        return liveTabs.firstIndex(where: {
            Set($0.workingDirectories.map(\.normalizedForMatching)) == sessionDirectories
        })
    }

    private static func compareTab(
        _ sessionTab: ExplorerTab,
        to liveTab: ExplorerTab,
        windowID: String,
        tabIndex: Int
    ) -> TabDiff {
        let sessionPanes = sessionTab.surfaceTree.root.flattenedPanes()
        var remainingLivePanes = liveTab.surfaceTree.root.flattenedPanes()
        var paneDiffs: [PaneDiff] = []
        var exactMatches = 0

        for (paneIndex, sessionPane) in sessionPanes.enumerated() {
            if let exactMatchIndex = remainingLivePanes.firstIndex(where: {
                sameWorkingDirectory($0.view.pwd, sessionPane.view.pwd)
                    && $0.path == sessionPane.path
            }) {
                let livePane = remainingLivePanes.remove(at: exactMatchIndex)
                paneDiffs.append(
                    PaneDiff(
                        id: paneDiffID(windowID: windowID, tabIndex: tabIndex, paneIndex: paneIndex),
                        sessionView: sessionPane.view,
                        position: sessionPane.position,
                        status: .match
                    )
                )
                exactMatches += 1
                _ = livePane
                continue
            }

            if let fuzzyMatchIndex = remainingLivePanes.firstIndex(where: {
                sameWorkingDirectory($0.view.pwd, sessionPane.view.pwd)
            }) {
                _ = remainingLivePanes.remove(at: fuzzyMatchIndex)
                paneDiffs.append(
                    PaneDiff(
                        id: paneDiffID(windowID: windowID, tabIndex: tabIndex, paneIndex: paneIndex),
                        sessionView: sessionPane.view,
                        position: sessionPane.position,
                        status: .partial
                    )
                )
            } else {
                paneDiffs.append(
                    PaneDiff(
                        id: paneDiffID(windowID: windowID, tabIndex: tabIndex, paneIndex: paneIndex),
                        sessionView: sessionPane.view,
                        position: sessionPane.position,
                        status: .missing
                    )
                )
            }
        }

        for (extraPaneIndex, extraPane) in remainingLivePanes.enumerated() {
            paneDiffs.append(
                PaneDiff(
                    id: paneDiffID(windowID: windowID, tabIndex: tabIndex, paneIndex: sessionPanes.count + extraPaneIndex),
                    sessionView: extraPane.view,
                    position: extraPane.position,
                    status: .extra
                )
            )
        }

        let hasExtraPanes = paneDiffs.contains(where: { $0.status == .extra })
        let hasPartialPanes = paneDiffs.contains(where: { $0.status == .partial })
        let hasMissingPanes = paneDiffs.contains(where: { $0.status == .missing })
        let splitMatches = sessionTab.splitSignature == liveTab.splitSignature

        let status: DiffStatus
        if exactMatches == sessionPanes.count && !hasExtraPanes && splitMatches {
            status = .match
        } else if !hasMissingPanes || exactMatches > 0 || hasPartialPanes || hasExtraPanes {
            status = .partial
        } else {
            status = .missing
        }

        return TabDiff(
            id: tabDiffID(windowID: windowID, tabIndex: tabIndex),
            sessionTab: sessionTab,
            status: status,
            panes: paneDiffs
        )
    }

    private static func extraWindowDiff(for liveWindow: ExplorerWindow, index: Int) -> WindowDiff {
        let tabs = liveWindow.tabs.enumerated().map { tabIndex, tab in
            extraTabDiff(for: tab, windowID: liveWindow.id, tabIndex: tabIndex)
        }

        return WindowDiff(
            id: "extra-\(index)-\(liveWindow.id)",
            sessionWindow: liveWindow,
            status: .extra,
            tabs: tabs
        )
    }

    private static func extraTabDiff(for liveTab: ExplorerTab, windowID: String, tabIndex: Int) -> TabDiff {
        let panes = liveTab.surfaceTree.root.flattenedPanes().enumerated().map { paneIndex, pane in
            PaneDiff(
                id: paneDiffID(windowID: windowID, tabIndex: tabIndex, paneIndex: paneIndex),
                sessionView: pane.view,
                position: pane.position,
                status: .extra
            )
        }

        return TabDiff(
            id: tabDiffID(windowID: windowID, tabIndex: tabIndex),
            sessionTab: liveTab,
            status: .extra,
            panes: panes
        )
    }
}

struct WindowDiff: Identifiable {
    let id: String
    let sessionWindow: ExplorerWindow
    let status: DiffStatus
    let tabs: [TabDiff]

    var title: String { sessionWindow.title ?? sessionWindow.id }
    var workspace: Int? { sessionWindow.workspace }
    var tabDiffs: [TabDiff] { tabs }
}

struct TabDiff: Identifiable {
    let id: String
    let sessionTab: ExplorerTab
    let status: DiffStatus
    let panes: [PaneDiff]

    var title: String { sessionTab.title ?? "Untitled" }
    var layoutDescription: String {
        let count = panes.count
        return count <= 1 ? "" : "\(count) panes"
    }
    var paneDiffs: [PaneDiff] { panes }
}

struct PaneDiff: Identifiable {
    let id: String
    let sessionView: ExplorerSurfaceView
    let position: String
    let status: DiffStatus

    var positionLabel: String { position }
    var workingDirectory: String { sessionView.pwd ?? "unknown" }
    var processName: String { sessionView.foregroundProcess ?? "" }

    var startupCommand: String? {
        sessionView.command?.summary
    }
}

enum DiffStatus: Equatable {
    case match
    case missing
    case partial
    case extra
}

private func sameWorkingDirectory(_ lhs: String?, _ rhs: String?) -> Bool {
    lhs?.normalizedForMatching == rhs?.normalizedForMatching
}

private func tabDiffID(windowID: String, tabIndex: Int) -> String {
    "\(windowID)-tab-\(tabIndex)"
}

private func paneDiffID(windowID: String, tabIndex: Int, paneIndex: Int) -> String {
    "\(windowID)-tab-\(tabIndex)-pane-\(paneIndex)"
}
