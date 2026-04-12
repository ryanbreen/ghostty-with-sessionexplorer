import Foundation
import Combine

final class SessionStore: ObservableObject {
    var sessions: [StoredSession] { storedSessions }

    struct StoredSession: Identifiable {
        let id: String
        let path: String
        let date: Date
        let snapshot: ExplorerSnapshot
        let isLatest: Bool

        var windowCount: Int { snapshot.windows.count }
        var tabCount: Int { snapshot.windows.flatMap(\.tabs).count }
    }

    private var storedSessions: [StoredSession] = []
    private var changeObserver: NSObjectProtocol?
    private var suppressedNotificationPath: String?

    init() {
        explorerDebugLog("SessionStore init: registering ghosttySessionsDidChange observer")
        // Reload whenever anyone (manual Save Session, auto-save timer, or the
        // Session Explorer's Snapshot Current button) writes a snapshot to disk.
        changeObserver = NotificationCenter.default.addObserver(
            forName: .ghosttySessionsDidChange,
            object: nil,
            queue: .main
        ) { [weak self] note in
            guard let self else { return }
            explorerDebugLog("SessionStore received ghosttySessionsDidChange: object=\(String(describing: note.object))")
            if self.consumeSuppressedNotificationReload(note.object) {
                return
            }
            self.loadSessions()
        }
    }

    deinit {
        if let obs = changeObserver {
            NotificationCenter.default.removeObserver(obs)
        }
    }

    func loadSessions() {
        let fileManager = FileManager.default
        let latestTargetPath = Self.latestSnapshotTargetPath()

        guard let urls = try? fileManager.contentsOfDirectory(
            at: Self.sessionsDirectory,
            includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey, .contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else {
            replaceSessions([], notifyObservers: true)
            return
        }

        let loadedSessions = urls.compactMap { url -> StoredSession? in
            guard url.pathExtension == "json" else { return nil }
            guard url.lastPathComponent != "latest.json" else { return nil }

            let values = try? url.resourceValues(forKeys: [.isRegularFileKey])
            let isRegularFile = values?.isRegularFile ?? false
            guard isRegularFile else { return nil }

            guard
                let data = try? Data(contentsOf: url),
                let snapshot = try? JSONDecoder().decode(ExplorerSnapshot.self, from: data)
            else {
                return nil
            }

            let date = Self.timestamp(from: url) ?? Self.modificationDate(for: url) ?? .distantPast

            return StoredSession(
                id: url.lastPathComponent,
                path: url.path,
                date: date,
                snapshot: snapshot,
                isLatest: latestTargetPath == url.path
            )
        }

        replaceSessions(
            loadedSessions.sorted { lhs, rhs in
                if lhs.date != rhs.date {
                    return lhs.date > rhs.date
                }
                if lhs.isLatest != rhs.isLatest {
                    return lhs.isLatest && !rhs.isLatest
                }
                return lhs.id.localizedStandardCompare(rhs.id) == .orderedAscending
            },
            notifyObservers: true
        )
    }

    func saveSnapshot(_ json: String, prefix: String) {
        let fileManager = FileManager.default

        do {
            try fileManager.createDirectory(
                at: Self.sessionsDirectory,
                withIntermediateDirectories: true,
                attributes: nil
            )

            let timestamp = Self.fileTimestampFormatter.string(from: Date())
                .replacingOccurrences(of: ":", with: "-")
            let safePrefix = prefix.isEmpty ? "snapshot" : prefix
            let fileURL = Self.sessionsDirectory.appendingPathComponent("\(safePrefix)-\(timestamp).json")

            guard let data = json.data(using: .utf8) else {
                throw CocoaError(.fileWriteInapplicableStringEncoding)
            }

            try data.write(to: fileURL, options: [.atomic])
            loadSessions()
            suppressNextNotificationReload(for: fileURL)
            NotificationCenter.default.post(name: .ghosttySessionsDidChange, object: fileURL)
        } catch {
            assertionFailure("Failed to save session snapshot: \(error)")
        }
    }

    func delete(session: StoredSession) throws {
        let fileManager = FileManager.default
        let latestTargetPath = Self.latestSnapshotTargetPath()
        let sessionURL = URL(fileURLWithPath: session.path)

        if fileManager.fileExists(atPath: sessionURL.path) {
            try fileManager.removeItem(at: sessionURL)
        }

        if latestTargetPath == session.path, fileManager.fileExists(atPath: Self.latestSymlink.path) {
            try fileManager.removeItem(at: Self.latestSymlink)
        }

        removeSession(id: session.id, notifyObservers: true)
        suppressNextNotificationReload(for: sessionURL)
        NotificationCenter.default.post(name: .ghosttySessionsDidChange, object: sessionURL)
    }

    func updateSnapshot(session: StoredSession, snapshot: ExplorerSnapshot) throws {
        let url = URL(fileURLWithPath: session.path)
        let data = try Self.snapshotEncoder.encode(snapshot)
        try data.write(to: url, options: [.atomic])
        upsertSession(
            StoredSession(
                id: session.id,
                path: session.path,
                date: session.date,
                snapshot: snapshot,
                isLatest: session.isLatest
            ),
            notifyObservers: true
        )
        suppressNextNotificationReload(for: url)
        NotificationCenter.default.post(name: .ghosttySessionsDidChange, object: url)
    }

    /// Writes the snapshot to disk without posting a notification or reloading the store.
    /// Use this for debounced auto-save during editing to avoid the save→reload→re-render
    /// oscillation cycle.
    func silentUpdateSnapshot(session: StoredSession, snapshot: ExplorerSnapshot) throws {
        let url = URL(fileURLWithPath: session.path)
        let data = try Self.snapshotEncoder.encode(snapshot)
        try data.write(to: url, options: [.atomic])

        upsertSession(
            StoredSession(
                id: session.id,
                path: session.path,
                date: session.date,
                snapshot: snapshot,
                isLatest: session.isLatest
            ),
            notifyObservers: false
        )
    }

    private func replaceSessions(_ sessions: [StoredSession], notifyObservers: Bool) {
        if notifyObservers {
            objectWillChange.send()
        }
        storedSessions = sessions
    }

    private func upsertSession(_ session: StoredSession, notifyObservers: Bool) {
        var nextSessions = storedSessions
        if let idx = nextSessions.firstIndex(where: { $0.id == session.id }) {
            nextSessions[idx] = session
        } else {
            nextSessions.append(session)
        }
        nextSessions.sort { lhs, rhs in
            if lhs.date != rhs.date {
                return lhs.date > rhs.date
            }
            if lhs.isLatest != rhs.isLatest {
                return lhs.isLatest && !rhs.isLatest
            }
            return lhs.id.localizedStandardCompare(rhs.id) == .orderedAscending
        }
        replaceSessions(nextSessions, notifyObservers: notifyObservers)
    }

    private func removeSession(id: String, notifyObservers: Bool) {
        replaceSessions(
            storedSessions.filter { $0.id != id },
            notifyObservers: notifyObservers
        )
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

extension SessionStore {
    static let sessionsDirectory = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".config")
        .appendingPathComponent("ghostty")
        .appendingPathComponent("sessions")
    static let latestSymlink = sessionsDirectory.appendingPathComponent("latest.json")

    static let filenameTimestampRegex = try! NSRegularExpression(
        pattern: #"(\d{4}-\d{2}-\d{2}T\d{2}-\d{2}-\d{2}(?:\.\d+)?Z)"#
    )

    static let parsedTimestampFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    static let parsedTimestampFormatterNoFraction: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    static let fileTimestampFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    static let snapshotEncoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }()

    static func timestamp(from url: URL) -> Date? {
        let filename = url.lastPathComponent
        let range = NSRange(filename.startIndex..<filename.endIndex, in: filename)
        guard let match = filenameTimestampRegex.firstMatch(in: filename, range: range),
              let matchRange = Range(match.range(at: 1), in: filename) else {
            return nil
        }

        let timestamp = String(filename[matchRange])
        let isoTimestamp = timestamp.replacingOccurrences(
            of: #"T(\d{2})-(\d{2})-(\d{2})(\.\d+)?Z"#,
            with: "T$1:$2:$3$4Z",
            options: .regularExpression
        )

        return parsedTimestampFormatter.date(from: isoTimestamp)
            ?? parsedTimestampFormatterNoFraction.date(from: isoTimestamp)
    }

    static func modificationDate(for url: URL) -> Date? {
        (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
    }

    static func latestSnapshotTargetPath() -> String? {
        guard FileManager.default.fileExists(atPath: latestSymlink.path) else { return nil }
        return latestSymlink.resolvingSymlinksInPath().path
    }
}
