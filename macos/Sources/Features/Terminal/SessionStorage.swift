import Foundation

/// Writes session JSON to ~/.claude-pods/sessions/ with a timestamped filename
/// and updates ~/.claude-pods/ghostty-session.json as a symlink to the latest.
/// This is the same convention used by Hive's Save Session button so the two
/// tools share a single session history.
enum SessionStorage {
    static let baseDir = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".claude-pods")
    static let sessionsDir = baseDir.appendingPathComponent("sessions")
    static let symlinkPath = baseDir.appendingPathComponent("ghostty-session.json")

    /// Save a JSON string and update the symlink. Returns the timestamped path.
    @discardableResult
    static func save(json: String) throws -> URL {
        let fm = FileManager.default
        try fm.createDirectory(at: sessionsDir, withIntermediateDirectories: true)

        let timestamp = ISO8601DateFormatter().string(from: Date())
            .replacingOccurrences(of: ":", with: "-")
        let filename = "ghostty-session-\(timestamp).json"
        let dest = sessionsDir.appendingPathComponent(filename)

        guard let data = json.data(using: .utf8) else {
            throw CocoaError(.fileWriteUnknown)
        }
        try data.write(to: dest)

        // Atomically update symlink
        try? fm.removeItem(at: symlinkPath)
        try fm.createSymbolicLink(at: symlinkPath, withDestinationURL: dest)

        return dest
    }
}
