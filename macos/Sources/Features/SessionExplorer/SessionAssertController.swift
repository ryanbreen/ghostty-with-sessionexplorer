import AppKit
import Foundation
import GhosttyKit

private let explorerDebugLogPath = "/tmp/ghostty-explorer-debug.log"

func explorerDebugLog(_ message: String) {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    let line = "[explorer] \(formatter.string(from: Date())) \(message)\n"
    let path = explorerDebugLogPath
    let fm = FileManager.default

    if !fm.fileExists(atPath: path) {
        fm.createFile(atPath: path, contents: nil)
    }

    guard let data = line.data(using: .utf8),
          let handle = FileHandle(forWritingAtPath: path) else {
        NSLog("[SessionExplorer] failed to open debug log at \(path)")
        return
    }

    handle.seekToEndOfFile()
    handle.write(data)
    handle.closeFile()
}

@MainActor
final class SessionAssertController {
    private let ghostty: Ghostty.App
    private var hasCapturedPreAssertSnapshot = false

    init(ghostty: Ghostty.App) {
        self.ghostty = ghostty
    }

    func assertWindow(_ window: ExplorerWindow) async {
        explorerDebugLog(
            "assertWindow called: window_id=\(window.id) title=\(window.displayTitle) tabs=\(window.tabs.count)"
        )
        capturePreAssertSnapshotIfNeeded()

        do {
            let sessionPath = try writeTemporarySessionDocument(for: window)
            explorerDebugLog("assertWindow wrote temporary session file: \(sessionPath)")
            defer {
                do {
                    try FileManager.default.removeItem(atPath: sessionPath)
                    explorerDebugLog("assertWindow removed temporary session file: \(sessionPath)")
                } catch {
                    explorerDebugLog(
                        "assertWindow failed to remove temporary session file: \(sessionPath) error=\(error)"
                    )
                }
            }

            let createdWindowMap = try SessionRestorer.restore(
                from: sessionPath,
                ghostty: ghostty,
                mergeExistingWindows: false
            )
            explorerDebugLog(
                "assertWindow restore scheduled successfully: window_id=\(window.id) created_window_map=\(createdWindowMap)"
            )
        } catch {
            explorerDebugLog("assertWindow failed: window_id=\(window.id) error=\(error)")
            Ghostty.logger.error("session explorer assertWindow failed: \(String(describing: error))")
        }
    }

    func assertTemplateWindow(_ window: ExplorerWindow) async {
        explorerDebugLog(
            "assertTemplateWindow called: window_id=\(window.id) title=\(window.displayTitle) tabs=\(window.tabs.count)"
        )
        capturePreAssertSnapshotIfNeeded()

        do {
            let sessionPath = try writeTemporarySessionDocument(for: window)
            explorerDebugLog("assertTemplateWindow wrote temporary session file: \(sessionPath)")
            defer {
                try? FileManager.default.removeItem(atPath: sessionPath)
            }

            _ = try SessionRestorer.restore(
                from: sessionPath,
                ghostty: ghostty,
                mergeExistingWindows: false
            )
            explorerDebugLog("assertTemplateWindow restore scheduled: window_id=\(window.id)")
        } catch {
            explorerDebugLog("assertTemplateWindow failed: window_id=\(window.id) error=\(error)")
            Ghostty.logger.error("session explorer assertTemplateWindow failed: \(String(describing: error))")
        }
    }

    func assertTemplate(_ template: SessionTemplate) async {
        explorerDebugLog(
            "assertTemplate called: template_id=\(template.id) name=\(template.name) windows=\(template.windows.count)"
        )
        capturePreAssertSnapshotIfNeeded()

        do {
            let sessionPath = try writeTemporarySessionDocument(template: template)
            explorerDebugLog("assertTemplate wrote temporary session file: \(sessionPath)")
            defer {
                do {
                    try FileManager.default.removeItem(atPath: sessionPath)
                    explorerDebugLog("assertTemplate removed temporary session file: \(sessionPath)")
                } catch {
                    explorerDebugLog(
                        "assertTemplate failed to remove temporary session file: \(sessionPath) error=\(error)"
                    )
                }
            }

            _ = try SessionRestorer.restore(
                from: sessionPath,
                ghostty: ghostty,
                mergeExistingWindows: false
            )
            explorerDebugLog("assertTemplate restore scheduled successfully: template_id=\(template.id)")
        } catch {
            explorerDebugLog("assertTemplate failed: template_id=\(template.id) error=\(error)")
            Ghostty.logger.error("session explorer assertTemplate failed: \(String(describing: error))")
        }
    }

    func assertAll(_ snapshot: ExplorerSnapshot) async {
        explorerDebugLog("assertAll called: windows=\(snapshot.windows.count)")
        capturePreAssertSnapshotIfNeeded()
        for (index, window) in snapshot.windows.enumerated() {
            explorerDebugLog(
                "assertAll asserting window \(index + 1)/\(snapshot.windows.count): window_id=\(window.id) title=\(window.displayTitle)"
            )
            await assertWindow(window)
        }
        explorerDebugLog("assertAll finished")
    }

    @discardableResult
    func snapshotCurrent() -> String? {
        let rawJson = SurfaceListSnapshotter.snapshot()
        let dir = SessionStore.sessionsDirectory
        let fm = FileManager.default

        if !fm.fileExists(atPath: dir.path) {
            try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        }

        // Convert the flat surface-list format into the ExplorerSnapshot format
        // that SessionStore expects ({"version": 1, "windows": [...]}) so the
        // new snapshot actually appears in the sidebar after write.
        let snapshot: ExplorerSnapshot
        do {
            snapshot = try ExplorerSnapshot.fromSurfaceListSnapshot(rawJson)
        } catch {
            explorerDebugLog("snapshotCurrent failed to convert live snapshot: error=\(error)")
            return nil
        }

        guard let data = try? JSONEncoder().encode(snapshot) else {
            explorerDebugLog("snapshotCurrent failed to encode ExplorerSnapshot")
            return nil
        }

        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        let stamp = formatter.string(from: Date())
            .replacingOccurrences(of: ":", with: "-")
        let filename = "snapshot-\(stamp).json"
        let path = dir.appendingPathComponent(filename).path

        do {
            try data.write(to: URL(fileURLWithPath: path), options: .atomic)
            explorerDebugLog("snapshotCurrent saved snapshot: \(path)")
            NotificationCenter.default.post(
                name: .ghosttySessionsDidChange,
                object: URL(fileURLWithPath: path)
            )
            return path
        } catch {
            explorerDebugLog("snapshotCurrent failed to save snapshot: error=\(error)")
            return nil
        }
    }

    private func capturePreAssertSnapshotIfNeeded() {
        guard !hasCapturedPreAssertSnapshot else {
            explorerDebugLog("capturePreAssertSnapshotIfNeeded skipped: snapshot already captured")
            return
        }
        hasCapturedPreAssertSnapshot = true
        explorerDebugLog("capturePreAssertSnapshotIfNeeded capturing snapshot")
        snapshotCurrent()
    }

    private func writeTemporarySessionDocument(for window: ExplorerWindow) throws -> String {
        let document = try TemplateCompiler.serializedDocument(window: window)
        let path = "/tmp/ghostty-explorer-assert-\(UUID().uuidString).json"
        try document.write(to: URL(fileURLWithPath: path), options: [.atomic])
        return path
    }

    private func writeTemporarySessionDocument(template: SessionTemplate) throws -> String {
        let document = try TemplateCompiler.serializedDocument(template: template)
        let path = "/tmp/ghostty-explorer-assert-\(UUID().uuidString).json"
        try document.write(to: URL(fileURLWithPath: path), options: [.atomic])
        return path
    }
}
