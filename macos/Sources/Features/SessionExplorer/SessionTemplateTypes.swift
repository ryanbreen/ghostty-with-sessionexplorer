import Foundation

struct SessionTemplate: Codable, Identifiable, Equatable {
    static let currentVersion = 1

    var kind: String
    var version: Int
    var id: String
    var name: String
    var createdAt: Date
    var updatedAt: Date
    var windows: [ExplorerWindow]

    init(
        kind: String = "template",
        version: Int = Self.currentVersion,
        id: String,
        name: String,
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        windows: [ExplorerWindow]
    ) {
        self.kind = kind
        self.version = version
        self.id = id
        self.name = name
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.windows = windows
    }
}

extension SessionTemplate {
    var asSnapshot: ExplorerSnapshot {
        ExplorerSnapshot(windows: windows)
    }

    static func promote(snapshot: ExplorerSnapshot, name: String) -> SessionTemplate {
        SessionTemplate(
            id: UUID().uuidString.lowercased(),
            name: name,
            windows: snapshot.windows.map(\.templateSanitized)
        )
    }
}

extension ExplorerWindow {
    var templateSanitized: ExplorerWindow {
        var copy = self
        copy.tabs = tabs.map(\.templateSanitized)
        return copy
    }
}

extension ExplorerTab {
    var templateSanitized: ExplorerTab {
        var copy = self
        copy.surfaceTree = surfaceTree.templateSanitized
        return copy
    }
}

extension ExplorerSurfaceTree {
    var templateSanitized: ExplorerSurfaceTree {
        var copy = self
        copy.root = root.templateSanitized
        return copy
    }
}

extension ExplorerSurfaceNode {
    var templateSanitized: ExplorerSurfaceNode {
        switch self {
        case .view(let view):
            return .view(view.templateSanitized)
        case .split(var split):
            split.left = split.left.templateSanitized
            split.right = split.right.templateSanitized
            return .split(split)
        }
    }
}

extension ExplorerSurfaceView {
    var templateSanitized: ExplorerSurfaceView {
        var copy = self
        copy.foregroundPid = nil
        copy.foregroundProcess = nil
        copy.processExited = nil
        return copy
    }
}

enum TemplateCommand: Codable, Equatable {
    case literal(commands: [String])
    case dynamic(resolver: String, params: [String: String])

    private enum CodingKeys: String, CodingKey {
        case type
        case commands
        case resolver
        case params
    }

    private enum CommandType: String, Codable {
        case literal
        case dynamic
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(CommandType.self, forKey: .type)

        switch type {
        case .literal:
            let commands = try container.decodeIfPresent([String].self, forKey: .commands) ?? []
            self = .literal(commands: commands)
        case .dynamic:
            let resolver = try container.decode(String.self, forKey: .resolver)
            let params = try container.decodeIfPresent([String: String].self, forKey: .params) ?? [:]
            self = .dynamic(resolver: resolver, params: params)
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)

        switch self {
        case .literal(let commands):
            try container.encode(CommandType.literal, forKey: .type)
            try container.encode(commands, forKey: .commands)
        case .dynamic(let resolver, let params):
            try container.encode(CommandType.dynamic, forKey: .type)
            try container.encode(resolver, forKey: .resolver)
            if !params.isEmpty {
                try container.encode(params, forKey: .params)
            }
        }
    }

    var commands: [String]? {
        guard case .literal(let commands) = self else { return nil }
        return commands
    }

    var resolverName: String? {
        guard case .dynamic(let resolver, _) = self else { return nil }
        return resolver
    }

    var params: [String: String] {
        guard case .dynamic(_, let params) = self else { return [:] }
        return params
    }

    var initialInput: String? {
        guard case .literal(let commands) = self, !commands.isEmpty else { return nil }
        return commands.joined(separator: "\n") + "\n"
    }

    var summary: String {
        switch self {
        case .literal(let commands):
            return commands.joined(separator: " ; ")
        case .dynamic(let resolver, let params):
            if params.isEmpty {
                return resolver
            }
            let renderedParams = params.keys.sorted().map { key in
                "\(key)=\(params[key] ?? "")"
            }.joined(separator: ", ")
            return "\(resolver) (\(renderedParams))"
        }
    }

    static func literal(fromCommands commands: [String]) -> TemplateCommand? {
        let normalized = commands
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard !normalized.isEmpty else { return nil }
        return .literal(commands: normalized)
    }

    static func literal(fromLegacyInitialInput initialInput: String) -> TemplateCommand? {
        let commands = initialInput
            .split(whereSeparator: \.isNewline)
            .map(String.init)
        return literal(fromCommands: commands)
    }
}
