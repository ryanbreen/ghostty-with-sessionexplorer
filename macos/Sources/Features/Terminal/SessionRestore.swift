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
    case windowCreationFailed(String)

    var errorDescription: String? {
        switch self {
        case .unsupportedVersion(let v):
            return "Unsupported session version \(v) (expected \(SessionDocument.currentVersion))."
        case .noWindows:
            return "Session file contains no windows."
        case .windowCreationFailed(let id):
            return "Failed to create window for session entry '\(id)'."
        }
    }
}

// MARK: - Restorer

@MainActor
enum SessionRestorer {
    /// Restore a session from a JSON file.
    ///
    /// - Parameters:
    ///   - filePath: Absolute path to the session JSON file.
    ///   - ghostty: The running Ghostty app instance.
    /// - Returns: A dictionary mapping each session window ID to the created
    ///   Ghostty ScriptWindow stable ID.
    static func restore(
        from filePath: String,
        ghostty: Ghostty.App
    ) throws -> [String: String] {
        let url = URL(fileURLWithPath: filePath)
        let data = try Data(contentsOf: url)
        let session = try JSONDecoder().decode(SessionDocument.self, from: data)

        guard session.version == SessionDocument.currentVersion else {
            throw SessionRestoreError.unsupportedVersion(session.version)
        }

        guard !session.windows.isEmpty else {
            throw SessionRestoreError.noWindows
        }

        var windowMap: [String: String] = [:]

        for sessionWindow in session.windows {
            guard let firstTab = sessionWindow.tabs.first else { continue }

            // Build the split tree for the first tab (creates the window)
            let tree = SplitTree<Ghostty.SurfaceView>(
                root: firstTab.surfaceTree.root,
                zoomed: nil
            )
            let controller = TerminalController(
                ghostty,
                withSurfaceTree: tree
            )
            controller.showWindow(nil)

            if let title = firstTab.title ?? sessionWindow.title {
                controller.titleOverride = title
            }

            guard let window = controller.window else {
                continue
            }

            // Add remaining tabs to this window
            for tab in sessionWindow.tabs.dropFirst() {
                let tabTree = SplitTree<Ghostty.SurfaceView>(
                    root: tab.surfaceTree.root,
                    zoomed: nil
                )
                let tabController = TerminalController(
                    ghostty,
                    withSurfaceTree: tabTree
                )

                if let title = tab.title {
                    tabController.titleOverride = title
                }

                guard let tabWindow = tabController.window else { continue }
                window.addTabbedWindowSafely(tabWindow, ordered: .above)
            }

            // Select the first tab
            window.makeKeyAndOrderFront(nil)

            // Record the mapping from caller's ID to Ghostty's stable window ID
            let stableID = ScriptWindow.stableID(primaryController: controller)
            windowMap[sessionWindow.id] = stableID
        }

        return windowMap
    }
}
