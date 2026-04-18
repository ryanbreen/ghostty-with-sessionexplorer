import Foundation

enum StateBackupManager {
    static let maxBackupCount = 50

    /// Per-variant backups directory so Dev backups don't pollute WRB backups.
    static var backupsDirectory: URL {
        StateStore.configDirectory.appendingPathComponent("state-backups")
    }

    @discardableResult
    static func createBackupIfNeeded(for stateURL: URL) throws -> URL? {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: stateURL.path) else { return nil }

        try fileManager.createDirectory(
            at: backupsDirectory,
            withIntermediateDirectories: true,
            attributes: nil
        )

        let backupURL = try uniqueBackupURL()
        try fileManager.copyItem(at: stateURL, to: backupURL)
        try pruneBackups()
        return backupURL
    }

    static func backupURLs() -> [URL] {
        let fileManager = FileManager.default
        guard let urls = try? fileManager.contentsOfDirectory(
            at: backupsDirectory,
            includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        return urls
            .filter { $0.pathExtension == "json" && $0.lastPathComponent.hasPrefix("state-") }
            .filter { url in
                let values = try? url.resourceValues(forKeys: [.isRegularFileKey])
                return values?.isRegularFile ?? false
            }
            .sorted { lhs, rhs in
                let lhsDate = modificationDate(for: lhs) ?? .distantPast
                let rhsDate = modificationDate(for: rhs) ?? .distantPast
                if lhsDate != rhsDate {
                    return lhsDate > rhsDate
                }
                return lhs.lastPathComponent.localizedStandardCompare(rhs.lastPathComponent) == .orderedDescending
            }
    }

    static func date(for backupURL: URL) -> Date {
        timestamp(from: backupURL)
            ?? modificationDate(for: backupURL)
            ?? .distantPast
    }

    private static func uniqueBackupURL() throws -> URL {
        let timestamp = backupTimestampFormatter.string(from: Date())
        var url = backupsDirectory.appendingPathComponent("state-\(timestamp).json")
        var counter = 1

        while FileManager.default.fileExists(atPath: url.path) {
            url = backupsDirectory.appendingPathComponent("state-\(timestamp)-\(counter).json")
            counter += 1
        }

        return url
    }

    private static func pruneBackups() throws {
        let backups = backupURLs()
        guard backups.count > maxBackupCount else { return }

        for url in backups.dropFirst(maxBackupCount) {
            try FileManager.default.removeItem(at: url)
        }
    }

    private static func timestamp(from url: URL) -> Date? {
        let filename = url.deletingPathExtension().lastPathComponent
        guard filename.hasPrefix("state-") else { return nil }

        let rawTimestamp = String(filename.dropFirst("state-".count))
        return backupTimestampFormatter.date(from: rawTimestamp)
    }

    private static func modificationDate(for url: URL) -> Date? {
        (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
    }

    private static let backupTimestampFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
}
