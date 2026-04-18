import Combine
import Foundation

extension Notification.Name {
    static let ghosttyStateDidChange = Notification.Name("GhosttyStateDidChange")
}

final class StateStore: ObservableObject {
    struct StoredState: Identifiable, Equatable {
        let path: String
        let template: SessionTemplate

        var id: String { "canonical-state" }
        var name: String { template.name }
        var updatedAt: Date { template.updatedAt }
        var windowCount: Int { template.windows.count }
        var tabCount: Int { template.windows.flatMap(\.tabs).count }
    }

    struct StoredBackup: Identifiable, Equatable {
        let path: String
        let date: Date
        let template: SessionTemplate

        var id: String { path }
        var name: String { URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent }
        var windowCount: Int { template.windows.count }
        var tabCount: Int { template.windows.flatMap(\.tabs).count }
    }

    var state: StoredState? { storedState }
    var backups: [StoredBackup] { storedBackups }

    private var storedState: StoredState?
    private var storedBackups: [StoredBackup] = []
    private var changeObserver: NSObjectProtocol?
    private var suppressedNotificationPath: String?

    init() {
        changeObserver = NotificationCenter.default.addObserver(
            forName: .ghosttyStateDidChange,
            object: nil,
            queue: .main
        ) { [weak self] note in
            guard let self else { return }
            if self.consumeSuppressedNotificationReload(note.object) {
                return
            }
            do {
                try self.loadState()
            } catch {
                explorerDebugLog("StateStore reload failed: error=\(error)")
            }
        }
    }

    deinit {
        if let changeObserver {
            NotificationCenter.default.removeObserver(changeObserver)
        }
    }

    func loadState() throws {
        try Self.migrateTemplateIfNeeded()

        let nextState: StoredState?
        if FileManager.default.fileExists(atPath: Self.stateURL.path) {
            let data = try Data(contentsOf: Self.stateURL)
            var template = try TemplateStore.jsonDecoder.decode(SessionTemplate.self, from: data)
            if template.ensureAllStateIDs() {
                let migratedData = try TemplateStore.jsonEncoder.encode(template)
                try migratedData.write(to: Self.stateURL, options: [.atomic])
                explorerDebugLog("StateStore assigned missing window/tab/pane state IDs in \(Self.stateURL.path)")
            }
            nextState = StoredState(path: Self.stateURL.path, template: template)
        } else {
            nextState = nil
        }

        let nextBackups = loadBackups()
        replace(state: nextState, backups: nextBackups, notifyObservers: true)
    }

    @discardableResult
    func save(template: SessionTemplate) throws -> StoredState {
        try save(template: template, notifyObservers: true, postNotification: true)
    }

    @discardableResult
    func silentSave(template: SessionTemplate) throws -> StoredState {
        try save(template: template, notifyObservers: false, postNotification: false)
    }

    @discardableResult
    func restore(backup: StoredBackup) throws -> StoredState {
        try save(template: backup.template, notifyObservers: true, postNotification: true)
    }

    private func save(
        template: SessionTemplate,
        notifyObservers: Bool,
        postNotification: Bool
    ) throws -> StoredState {
        let fileManager = FileManager.default
        try fileManager.createDirectory(
            at: Self.configDirectory,
            withIntermediateDirectories: true,
            attributes: nil
        )

        try StateBackupManager.createBackupIfNeeded(for: Self.stateURL)

        let now = Date()
        var writableTemplate = template
        writableTemplate.kind = "template"
        writableTemplate.version = SessionTemplate.currentVersion
        writableTemplate.createdAt = storedState?.template.createdAt ?? template.createdAt
        writableTemplate.updatedAt = now
        _ = writableTemplate.ensureAllStateIDs()

        let data = try TemplateStore.jsonEncoder.encode(writableTemplate)
        try data.write(to: Self.stateURL, options: [.atomic])

        let stored = StoredState(path: Self.stateURL.path, template: writableTemplate)
        replace(state: stored, backups: loadBackups(), notifyObservers: notifyObservers)

        if postNotification {
            suppressNextNotificationReload(for: Self.stateURL)
            NotificationCenter.default.post(name: .ghosttyStateDidChange, object: Self.stateURL)
        }

        return stored
    }

    private func loadBackups() -> [StoredBackup] {
        StateBackupManager.backupURLs().compactMap { url in
            guard
                let data = try? Data(contentsOf: url),
                let template = try? TemplateStore.jsonDecoder.decode(SessionTemplate.self, from: data)
            else {
                return nil
            }

            return StoredBackup(
                path: url.path,
                date: StateBackupManager.date(for: url),
                template: template
            )
        }
    }

    static func migrateTemplateIfNeeded() throws {
        let fileManager = FileManager.default
        guard !fileManager.fileExists(atPath: stateURL.path) else {
            explorerDebugLog("StateStore migration skipped: state.json already exists for variant=\(variant)")
            return
        }

        try fileManager.createDirectory(
            at: configDirectory,
            withIntermediateDirectories: true,
            attributes: nil
        )

        // Bootstrap order: peer variant's state (e.g. WRB → Dev), then legacy
        // template from ~/.config/ghostty/templates/, then nothing.
        if let peerURL = peerStateURL,
           fileManager.fileExists(atPath: peerURL.path) {
            try fileManager.copyItem(at: peerURL, to: stateURL)
            explorerDebugLog(
                "StateStore bootstrapped variant=\(variant) from peer \(peerURL.path)"
            )
            return
        }

        guard let sourceURL = mostRecentlyUpdatedTemplateURL() else {
            explorerDebugLog("StateStore migration skipped: no templates found for variant=\(variant)")
            return
        }

        try fileManager.copyItem(at: sourceURL, to: stateURL)
        explorerDebugLog("StateStore migrated template \(sourceURL.path) to \(stateURL.path)")
    }

    private static func mostRecentlyUpdatedTemplateURL() -> URL? {
        let fileManager = FileManager.default
        guard let urls = try? fileManager.contentsOfDirectory(
            at: TemplateStore.templatesDirectory,
            includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            return nil
        }

        return urls
            .filter { $0.pathExtension == "json" }
            .compactMap { url -> (URL, Date)? in
                let values = try? url.resourceValues(forKeys: [.isRegularFileKey])
                guard values?.isRegularFile ?? false else { return nil }

                let templateUpdatedAt: Date?
                if let data = try? Data(contentsOf: url),
                   let template = try? TemplateStore.jsonDecoder.decode(SessionTemplate.self, from: data) {
                    templateUpdatedAt = template.updatedAt
                } else {
                    templateUpdatedAt = nil
                }

                let modifiedAt = SessionStore.modificationDate(for: url)
                guard let date = templateUpdatedAt ?? modifiedAt else { return nil }
                return (url, date)
            }
            .sorted { lhs, rhs in
                if lhs.1 != rhs.1 {
                    return lhs.1 > rhs.1
                }
                return lhs.0.lastPathComponent.localizedStandardCompare(rhs.0.lastPathComponent) == .orderedAscending
            }
            .first?
            .0
    }

    private func replace(
        state: StoredState?,
        backups: [StoredBackup],
        notifyObservers: Bool
    ) {
        if notifyObservers {
            objectWillChange.send()
        }
        storedState = state
        storedBackups = backups
    }

    private func suppressNextNotificationReload(for url: URL) {
        suppressedNotificationPath = url.path
    }

    private func consumeSuppressedNotificationReload(_ object: Any?) -> Bool {
        guard let suppressedNotificationPath else { return false }
        guard let url = object as? URL, url.path == suppressedNotificationPath else {
            return false
        }
        self.suppressedNotificationPath = nil
        return true
    }
}

extension StateStore {
    /// The bundle identifier suffix used to scope state to a specific app
    /// variant. Ghostty WRB and Ghostty Dev have distinct bundle IDs and must
    /// keep their state files separate so testing in Dev cannot corrupt the
    /// daily-driver state in WRB.
    static var variant: String {
        let bundleID = Bundle.main.bundleIdentifier ?? "com.mitchellh.ghostty.wrb"
        if bundleID.hasSuffix(".dev") {
            return "dev"
        }
        return "wrb"
    }

    static var configDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config")
            .appendingPathComponent("ghostty")
            .appendingPathComponent(variant)
    }

    static var stateURL: URL {
        configDirectory.appendingPathComponent("state.json")
    }

    /// The peer variant's state path — used for one-time bootstrap of Dev
    /// state from WRB state on first launch.
    static var peerStateURL: URL? {
        let peerVariant: String
        switch variant {
        case "dev": peerVariant = "wrb"
        case "wrb": peerVariant = "dev"
        default: return nil
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config")
            .appendingPathComponent("ghostty")
            .appendingPathComponent(peerVariant)
            .appendingPathComponent("state.json")
    }
}

enum StateWindowRecapturer {
    static func recapturedWindow(
        from liveWindow: ExplorerWindow,
        preservingCommandsFrom stateWindow: ExplorerWindow
    ) -> ExplorerWindow {
        var recaptured = stateWindow
        var newTabs: [ExplorerTab] = []
        newTabs.reserveCapacity(liveWindow.tabs.count)

        for (tabIndex, liveTab) in liveWindow.tabs.enumerated() {
            let matchingOldTab = matchingStateTab(
                for: liveTab,
                at: tabIndex,
                in: stateWindow
            )
            let mergedTree = mergeTreePreservingCommands(
                liveTree: liveTab.surfaceTree,
                stateTree: matchingOldTab?.surfaceTree
            )

            newTabs.append(
                ExplorerTab(
                    id: liveTab.id ?? matchingOldTab?.id,
                    title: liveTab.title ?? matchingOldTab?.title,
                    surfaceTree: mergedTree
                )
            )
        }

        recaptured.tabs = newTabs
        return recaptured
    }

    private static func matchingStateTab(
        for liveTab: ExplorerTab,
        at tabIndex: Int,
        in stateWindow: ExplorerWindow
    ) -> ExplorerTab? {
        if let liveTabID = normalizedID(liveTab.id),
           let match = stateWindow.tabs.first(where: { normalizedID($0.id) == liveTabID }) {
            return match
        }

        if stateWindow.tabs.indices.contains(tabIndex) {
            return stateWindow.tabs[tabIndex]
        }

        return stateWindow.tabs.first(where: {
            $0.workingDirectorySignature == liveTab.workingDirectorySignature
        })
    }

    private static func mergeTreePreservingCommands(
        liveTree: ExplorerSurfaceTree,
        stateTree: ExplorerSurfaceTree?
    ) -> ExplorerSurfaceTree {
        var merged = liveTree
        let livePanes = liveTree.root.flattenedPanes()
        let statePanes = stateTree?.root.flattenedPanes() ?? []

        // Strategy: match each live pane to a state pane by durable stateID
        // first, then fall back to the older heuristics. State panes can only
        // be matched once so multiple live panes with the same pwd get distinct
        // matches in order.
        var consumedStateIndices: Set<Int> = []

        func findStateMatch(for livePane: ExplorerSurfaceNode.FlattenedPane) -> Int? {
            // 1. Same durable pane identity.
            if let liveStateID = normalizedStateID(livePane.view) {
                for i in statePanes.indices {
                    guard !consumedStateIndices.contains(i) else { continue }
                    if normalizedStateID(statePanes[i].view) == liveStateID { return i }
                }
            }

            // 2. Same path.
            for i in statePanes.indices {
                guard !consumedStateIndices.contains(i) else { continue }
                if statePanes[i].path == livePane.path { return i }
            }

            // 3. Same pwd (handles pane removal restructuring).
            if let pwd = livePane.view.pwd?.normalizedForMatching, !pwd.isEmpty {
                for i in statePanes.indices {
                    guard !consumedStateIndices.contains(i) else { continue }
                    if statePanes[i].view.pwd?.normalizedForMatching == pwd { return i }
                }
            }
            return nil
        }

        for livePane in livePanes {
            if let stateIndex = findStateMatch(for: livePane) {
                consumedStateIndices.insert(stateIndex)
                let statePane = statePanes[stateIndex]
                merged.updateView(at: livePane.path) { view in
                    view.stateID = statePane.view.stateID ?? view.stateID
                    if let command = statePane.view.command {
                        view.command = command
                    }
                }
                continue
            }

            if shouldDefaultLeftColumnCommand(path: livePane.path, tree: liveTree) {
                merged.updateView(at: livePane.path) { view in
                    view.command = .dynamic(resolver: "claudeResumeLatest", params: [:])
                }
            }
        }

        // Strip volatile per-instance fields (PID, surface UUID, exited flag,
        // foreground process name) from every leaf so the saved state stays
        // a clean template rather than a runtime snapshot.
        for livePane in liveTree.root.flattenedPanes() {
            merged.updateView(at: livePane.path) { view in
                view.id = nil
                view.foregroundPid = nil
                view.foregroundProcess = nil
                view.processExited = nil
            }
        }

        return merged
    }

    private static func shouldDefaultLeftColumnCommand(path: [Int], tree: ExplorerSurfaceTree) -> Bool {
        guard path.count > 0 else { return false }
        guard case .split(let split) = tree.root else { return false }
        return split.direction.lowercased() == "horizontal" && path.first == 0
    }

    private static func normalizedStateID(_ view: ExplorerSurfaceView) -> String? {
        normalizedID(view.stateID)
    }

    private static func normalizedID(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty else {
            return nil
        }
        return trimmed.lowercased()
    }
}
