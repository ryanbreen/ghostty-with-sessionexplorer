import AppKit
import Foundation
import GhosttyKit

extension Notification.Name {
    static let terminalControllerCreated = Notification.Name("GhosttyTerminalControllerCreated")
}

@MainActor
final class AutoStateSaver {
    static let shared = AutoStateSaver()

    private let debounceInterval: TimeInterval = 0.5
    private var timer: Timer?
    private var pendingReason: String?
    private var suppressionDepth = 0
    private var noSaveBefore: Date?

    private init() {}

    func scheduleAutoSave(reason: String) {
        guard !isSuppressed else { return }

        pendingReason = reason
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: debounceInterval, repeats: false) { [weak self] _ in
            Task { @MainActor in
                self?.performAutoSave()
            }
        }
    }

    func beginSuppression(reason: String) {
        suppressionDepth += 1
        cancelPendingSave()
    }

    func endSuppression(after delay: TimeInterval = 0, reason: String) {
        suppressionDepth = max(0, suppressionDepth - 1)
        if delay > 0 {
            suppressAutoSave(until: Date().addingTimeInterval(delay), reason: reason)
        }
    }

    func suppressAutoSave(until deadline: Date, reason: String) {
        guard deadline > Date() else { return }
        if let current = noSaveBefore {
            noSaveBefore = max(current, deadline)
        } else {
            noSaveBefore = deadline
        }
        cancelPendingSave()
    }

    func withSuppression<T>(
        reason: String,
        deferFor delay: TimeInterval = 0,
        _ body: () throws -> T
    ) rethrows -> T {
        beginSuppression(reason: reason)
        defer { endSuppression(after: delay, reason: reason) }
        return try body()
    }

    private var isSuppressed: Bool {
        if suppressionDepth > 0 { return true }
        if let noSaveBefore {
            if noSaveBefore > Date() { return true }
            self.noSaveBefore = nil
        }
        return false
    }

    private func cancelPendingSave() {
        timer?.invalidate()
        timer = nil
        pendingReason = nil
    }

    private func performAutoSave() {
        timer?.invalidate()
        timer = nil

        guard !isSuppressed else {
            pendingReason = nil
            return
        }

        let reason = pendingReason ?? "unknown"
        pendingReason = nil

        do {
            let liveSnapshot = try ExplorerSnapshot.fromSurfaceListSnapshot(
                SurfaceListSnapshotter.snapshot()
            )
            let store = StateStore()
            try store.loadState()

            var template = store.state?.template ?? SessionTemplate(
                id: UUID().uuidString.lowercased(),
                name: "Ghostty State",
                windows: []
            )

            let mergedWindows = recapturedWindows(
                from: liveSnapshot,
                preservingStateWindowsFrom: template
            )
            guard mergedWindows != template.windows else { return }

            template.windows = mergedWindows
            let stored = try store.silentSave(template: template)
            stampLiveStateIDs(from: stored.template)
            explorerDebugLog(
                "AutoStateSaver: saved (reason: \(reason), windows=\(stored.template.windows.count))"
            )
        } catch {
            explorerDebugLog("AutoStateSaver: save failed (reason: \(reason), error=\(error))")
            Ghostty.logger.error("auto state save failed: \(String(describing: error))")
        }
    }

    private func recapturedWindows(
        from liveSnapshot: ExplorerSnapshot,
        preservingStateWindowsFrom template: SessionTemplate
    ) -> [ExplorerWindow] {
        var matchedLiveByStateIndex: [Int: ExplorerWindow] = [:]
        var consumedStateIndices = Set<Int>()
        var unmatchedLiveWindows: [ExplorerWindow] = []

        for liveWindow in liveSnapshot.windows {
            if let match = matchingStateWindowIndex(
                for: liveWindow,
                in: template.windows,
                excluding: consumedStateIndices
            ) {
                consumedStateIndices.insert(match)
                matchedLiveByStateIndex[match] = liveWindow
            } else {
                unmatchedLiveWindows.append(liveWindow)
            }
        }

        var windows: [ExplorerWindow] = []
        windows.reserveCapacity(liveSnapshot.windows.count)

        for index in template.windows.indices {
            guard let liveWindow = matchedLiveByStateIndex[index] else { continue }
            windows.append(
                StateWindowRecapturer.recapturedWindow(
                    from: liveWindow,
                    preservingCommandsFrom: template.windows[index]
                )
            )
        }

        windows.append(
            contentsOf: unmatchedLiveWindows.map { liveWindow in
                var newWindow = liveWindow.templateSanitized
                if Self.isTransientSnapshotWindowID(newWindow.id) {
                    newWindow.id = ""
                }
                return newWindow
            }
        )

        return windows
    }

    private func matchingStateWindowIndex(
        for liveWindow: ExplorerWindow,
        in stateWindows: [ExplorerWindow],
        excluding consumed: Set<Int>
    ) -> Int? {
        if let liveID = Self.normalizedPersistentStateID(liveWindow.id) {
            for index in stateWindows.indices where !consumed.contains(index) {
                if Self.normalizedPersistentStateID(stateWindows[index].id) == liveID {
                    return index
                }
            }
        }

        for index in stateWindows.indices where !consumed.contains(index) {
            if stateWindows[index].normalizedTitle == liveWindow.normalizedTitle {
                return index
            }
        }

        return nil
    }

    private func stampLiveStateIDs(from template: SessionTemplate) {
        // Use uniquingKeysWith because state.json can legitimately end up
        // with duplicate stateIDs (hand edits, prior buggy migrations,
        // recapture races). Trusting uniqueness here was crashing the app
        // with "Fatal error: Duplicate values for key" the moment a save
        // ran while two windows shared an ID.
        let stateWindowsByID = Dictionary(
            template.windows.map {
                (Self.normalizedPersistentStateID($0.id) ?? $0.id.normalizedForMatching, $0)
            },
            uniquingKeysWith: { first, _ in first }
        )
        let stateWindowsByTitle = Dictionary(
            template.windows.map { ($0.normalizedTitle, $0) },
            uniquingKeysWith: { first, _ in first }
        )

        var seenControllers = Set<ObjectIdentifier>()
        for nsWindow in NSApp.windows {
            guard let controller = nsWindow.windowController as? BaseTerminalController else {
                continue
            }

            let primaryController: BaseTerminalController
            if let tabGroup = nsWindow.tabGroup,
               let first = tabGroup.windows.compactMap({ $0.windowController as? BaseTerminalController }).first {
                primaryController = first
            } else {
                primaryController = controller
            }

            guard seenControllers.insert(ObjectIdentifier(primaryController)).inserted else {
                continue
            }

            stampLiveStateIDs(
                for: primaryController,
                stateWindowsByID: stateWindowsByID,
                stateWindowsByTitle: stateWindowsByTitle
            )
        }
    }

    private func stampLiveStateIDs(
        for primaryController: BaseTerminalController,
        stateWindowsByID: [String: ExplorerWindow],
        stateWindowsByTitle: [String: ExplorerWindow]
    ) {
        guard let window = primaryController.window else { return }
        let json = SurfaceListSnapshotter.snapshotWindow(controller: primaryController)
        guard let liveWindow = (try? ExplorerSnapshot.fromSurfaceListSnapshot(json))?.windows.first else {
            return
        }

        let stateWindow: ExplorerWindow?
        if let liveID = Self.normalizedPersistentStateID(liveWindow.id) {
            stateWindow = stateWindowsByID[liveID] ?? stateWindowsByTitle[liveWindow.normalizedTitle]
        } else {
            stateWindow = stateWindowsByTitle[liveWindow.normalizedTitle]
        }
        guard let stateWindow else { return }

        let tabControllers: [BaseTerminalController]
        if let tabGroup = window.tabGroup {
            tabControllers = tabGroup.windows.compactMap {
                $0.windowController as? BaseTerminalController
            }
        } else {
            tabControllers = [primaryController]
        }

        for (tabIndex, tabController) in tabControllers.enumerated() {
            guard tabIndex < stateWindow.tabs.count,
                  tabIndex < liveWindow.tabs.count else { continue }

            let stateTab = stateWindow.tabs[tabIndex]
            let liveTab = liveWindow.tabs[tabIndex]
            tabController.stateWindowID = stateWindow.id
            tabController.stateTabID = stateTab.id
            stampPaneStateIDs(
                controller: tabController,
                liveTab: liveTab,
                stateTab: stateTab
            )
        }
    }

    private func stampPaneStateIDs(
        controller: BaseTerminalController,
        liveTab: ExplorerTab,
        stateTab: ExplorerTab
    ) {
        guard let root = controller.surfaceTree.root else { return }
        let liveLeaves = root.leaves()
        let livePanes = liveTab.surfaceTree.root.flattenedPanes()
        let statePanes = stateTab.surfaceTree.root.flattenedPanes()
        var consumedStateIndices = Set<Int>()

        for (liveIndex, livePane) in livePanes.enumerated() {
            guard liveIndex < liveLeaves.count else { continue }
            guard let stateIndex = matchingPaneIndex(
                for: livePane,
                in: statePanes,
                excluding: consumedStateIndices
            ) else { continue }
            guard let stateID = statePanes[stateIndex].view.stateID,
                  !stateID.isEmpty else { continue }

            consumedStateIndices.insert(stateIndex)
            liveLeaves[liveIndex].stateID = stateID
        }
    }

    private func matchingPaneIndex(
        for livePane: ExplorerSurfaceNode.FlattenedPane,
        in statePanes: [ExplorerSurfaceNode.FlattenedPane],
        excluding consumed: Set<Int>
    ) -> Int? {
        for index in statePanes.indices where !consumed.contains(index) {
            if statePanes[index].path == livePane.path { return index }
        }

        if let liveStateID = Self.normalizedPersistentStateID(livePane.view.stateID) {
            for index in statePanes.indices where !consumed.contains(index) {
                if Self.normalizedPersistentStateID(statePanes[index].view.stateID) == liveStateID {
                    return index
                }
            }
        }

        if let pwd = livePane.view.pwd?.normalizedForMatching, !pwd.isEmpty {
            for index in statePanes.indices where !consumed.contains(index) {
                if statePanes[index].view.pwd?.normalizedForMatching == pwd {
                    return index
                }
            }
        }

        return nil
    }

    private static func normalizedPersistentStateID(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty,
              Int(trimmed) == nil else {
            return nil
        }
        return trimmed.lowercased()
    }

    private static func isTransientSnapshotWindowID(_ value: String) -> Bool {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return !trimmed.isEmpty && Int(trimmed) != nil
    }
}
