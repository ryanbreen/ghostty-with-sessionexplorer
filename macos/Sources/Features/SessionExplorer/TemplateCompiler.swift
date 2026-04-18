import Foundation

enum TemplateCompiler {
    static func compile(template: SessionTemplate) throws -> SessionDocument {
        try decodeDocument(from: serializedDocument(windows: template.windows))
    }

    static func compile(snapshot: ExplorerSnapshot) throws -> SessionDocument {
        try decodeDocument(from: serializedDocument(windows: snapshot.windows))
    }

    static func compile(window: ExplorerWindow) throws -> SessionDocument {
        try decodeDocument(from: serializedDocument(windows: [window]))
    }

    static func serializedDocument(template: SessionTemplate) throws -> Data {
        try serializedDocument(windows: template.windows)
    }

    static func serializedDocument(snapshot: ExplorerSnapshot) throws -> Data {
        try serializedDocument(windows: snapshot.windows)
    }

    static func serializedDocument(window: ExplorerWindow) throws -> Data {
        try serializedDocument(windows: [window])
    }

    static func serializedDocument(windows: [ExplorerWindow]) throws -> Data {
        var normalizedWindows = windows.map(normalizeClaudeResumeOffsets(in:))
        for index in normalizedWindows.indices {
            _ = normalizedWindows[index].ensureAllStateIDs()
        }
        let records = try normalizedWindows.map(makeWindowRecord)
        let document: [String: Any] = [
            "version": SessionDocument.currentVersion,
            "windows": records,
        ]

        return try JSONSerialization.data(
            withJSONObject: document,
            options: [.prettyPrinted, .sortedKeys]
        )
    }

    private static func decodeDocument(from data: Data) throws -> SessionDocument {
        try JSONDecoder().decode(SessionDocument.self, from: data)
    }

    private static func makeWindowRecord(_ window: ExplorerWindow) throws -> [String: Any] {
        var record: [String: Any] = [
            "id": window.id,
            "tabs": try window.tabs.map(makeTabRecord),
        ]

        if let title = nonEmpty(window.title) {
            record["title"] = title
        }

        if let workspace = window.workspace {
            record["workspace"] = workspace
        }

        return record
    }

    private static func makeTabRecord(_ tab: ExplorerTab) throws -> [String: Any] {
        var record: [String: Any] = [
            "surfaceTree": [
                "root": try encodeSurfaceNode(tab.surfaceTree.root),
            ],
        ]

        if let id = nonEmpty(tab.id) {
            record["id"] = id
        }

        if let title = nonEmpty(tab.title) {
            record["title"] = title
        }

        return record
    }

    private static func encodeSurfaceNode(_ node: ExplorerSurfaceNode) throws -> [String: Any] {
        switch node {
        case .view(let view):
            return ["view": try encodeSurfaceView(view)]
        case .split(let split):
            let direction: [String: Any] = switch split.direction.lowercased() {
            case "vertical":
                ["vertical": [:] as [String: Any]]
            default:
                ["horizontal": [:] as [String: Any]]
            }

            return [
                "split": [
                    "direction": direction,
                    "ratio": split.ratio,
                    "left": try encodeSurfaceNode(split.left),
                    "right": try encodeSurfaceNode(split.right),
                ],
            ]
        }
    }

    private static func encodeSurfaceView(_ view: ExplorerSurfaceView) throws -> [String: Any] {
        var record: [String: Any] = [:]

        if let stateID = nonEmpty(view.stateID) {
            record["stateID"] = stateID
        }

        if let pwd = nonEmpty(view.pwd) {
            record["pwd"] = expandTilde(in: pwd)
        }

        if let title = nonEmpty(view.title) {
            record["title"] = title
        }

        if let initialInput = compiledInitialInput(for: view), !initialInput.isEmpty {
            record["initialInput"] = initialInput
        }

        return record
    }

    private static func normalizeClaudeResumeOffsets(in window: ExplorerWindow) -> ExplorerWindow {
        var normalized = window
        normalized.tabs = normalized.tabs.map { normalizeClaudeResumeOffsets(in: $0) }
        return normalized
    }

    private static func normalizeClaudeResumeOffsets(in tab: ExplorerTab) -> ExplorerTab {
        var normalized = tab
        var offsetsByPwd: [String: Int] = [:]

        for pane in normalized.surfaceTree.root.flattenedPanes() {
            guard case .dynamic(let resolver, var params) = pane.view.command else { continue }
            guard resolver == "claudeResumeLatest" else { continue }

            let pwdKey = pane.view.pwd?.normalizedForMatching ?? ""
            let offset = offsetsByPwd[pwdKey, default: 0]
            offsetsByPwd[pwdKey] = offset + 1

            params["n"] = "\(offset)"
            normalized.surfaceTree.updateView(at: pane.path) { view in
                view.command = .dynamic(resolver: "claudeResumeNth", params: params)
            }
        }

        return normalized
    }

    private static func compiledInitialInput(for view: ExplorerSurfaceView) -> String? {
        guard let command = view.command else { return nil }

        switch command {
        case .literal:
            return command.initialInput
        case .dynamic(let resolver, let params):
            let expandedPwd = expandTilde(in: view.pwd ?? FileManager.default.homeDirectoryForCurrentUser.path)
            let resolved = StartupResolverRegistry.shared.resolve(
                resolver: resolver,
                pwd: expandedPwd,
                params: params
            )
            return ensureTrailingNewline(resolved)
        }
    }

    private static func expandTilde(in path: String) -> String {
        (path as NSString).expandingTildeInPath
    }

    private static func ensureTrailingNewline(_ value: String) -> String {
        value.hasSuffix("\n") ? value : "\(value)\n"
    }

    private static func nonEmpty(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
