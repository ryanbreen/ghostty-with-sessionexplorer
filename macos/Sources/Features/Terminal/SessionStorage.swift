import Foundation

/// Writes session JSON to ~/.config/ghostty/sessions/ with a timestamped filename
/// and updates ~/.config/ghostty/sessions/latest.json as a symlink to the most
/// recent snapshot. Both manual Save Session and the periodic auto-save go
/// through this path, so Restore Session always picks up the newest layout
/// regardless of which one wrote it.
///
/// We live under Ghostty's XDG-style config dir on purpose: it keeps all
/// user-facing Ghostty state in one well-known place.
enum SessionStorage {
    static let baseDir = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".config")
        .appendingPathComponent("ghostty")
    static let sessionsDir = baseDir.appendingPathComponent("sessions")
    static let symlinkPath = sessionsDir.appendingPathComponent("latest.json")

    /// Save a JSON string and update the symlink. Returns the timestamped path.
    @discardableResult
    static func save(json: String) throws -> URL {
        let fm = FileManager.default
        try fm.createDirectory(at: sessionsDir, withIntermediateDirectories: true)

        let timestamp = ISO8601DateFormatter().string(from: Date())
            .replacingOccurrences(of: ":", with: "-")
        let filename = "session-\(timestamp).json"
        let dest = sessionsDir.appendingPathComponent(filename)

        guard let data = json.data(using: .utf8) else {
            throw CocoaError(.fileWriteUnknown)
        }
        try data.write(to: dest)

        // Atomically update the "latest" symlink to point at this snapshot.
        try? fm.removeItem(at: symlinkPath)
        try fm.createSymbolicLink(at: symlinkPath, withDestinationURL: dest)

        return dest
    }
}
