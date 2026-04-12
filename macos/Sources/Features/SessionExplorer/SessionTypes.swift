import Foundation

struct ExplorerSnapshot: Codable, Equatable {
    var version: Int
    var windows: [ExplorerWindow]

    static let currentVersion = 1

    init(version: Int = Self.currentVersion, windows: [ExplorerWindow]) {
        self.version = version
        self.windows = windows
    }

    static func fromSurfaceListSnapshot(_ json: String) throws -> ExplorerSnapshot {
        let data = Data(json.utf8)
        let surfaces = try JSONDecoder().decode([LiveSurfaceRecord].self, from: data)
        return fromSurfaceListSnapshot(surfaces)
    }

    static func fromSurfaceListSnapshot(_ surfaces: [LiveSurfaceRecord]) -> ExplorerSnapshot {
        let groupedWindows = Dictionary(grouping: surfaces, by: \.windowID)

        let windows = groupedWindows.keys.sorted().compactMap { windowID -> ExplorerWindow? in
            guard let windowSurfaces = groupedWindows[windowID], !windowSurfaces.isEmpty else {
                return nil
            }

            let groupedTabs = Dictionary(grouping: windowSurfaces, by: \.tabIndex)
            let tabs = groupedTabs.keys.sorted().compactMap { tabIndex -> ExplorerTab? in
                guard let tabSurfaces = groupedTabs[tabIndex], !tabSurfaces.isEmpty else {
                    return nil
                }

                let title = tabSurfaces.compactMap(\.tabTitle).first(where: { !$0.isEmpty })
                let root = buildNode(from: tabSurfaces.map(LivePane.init))
                let surfaceTree = ExplorerSurfaceTree(root: root)
                return ExplorerTab(title: title, surfaceTree: surfaceTree)
            }

            let title = windowSurfaces.compactMap(\.windowTitle).first(where: { !$0.isEmpty })
            return ExplorerWindow(id: String(windowID), title: title, workspace: nil, tabs: tabs)
        }

        return ExplorerSnapshot(windows: windows)
    }

    private static func buildNode(from panes: [LivePane]) -> ExplorerSurfaceNode {
        guard !panes.isEmpty else {
            return .view(ExplorerSurfaceView())
        }

        if panes.count == 1, panes[0].path.isEmpty {
            return .view(panes[0].view)
        }

        let leftPanes = panes.compactMap { pane -> LivePane? in
            guard pane.path.first == 0 else { return nil }
            return pane.droppingFirstPathComponent()
        }
        let rightPanes = panes.compactMap { pane -> LivePane? in
            guard pane.path.first == 1 else { return nil }
            return pane.droppingFirstPathComponent()
        }

        if leftPanes.isEmpty, rightPanes.isEmpty {
            return .view(panes[0].view)
        }
        if leftPanes.isEmpty {
            return buildNode(from: rightPanes)
        }
        if rightPanes.isEmpty {
            return buildNode(from: leftPanes)
        }

        return .split(
            ExplorerSurfaceSplit(
                direction: "horizontal",
                ratio: 0.5,
                left: buildNode(from: leftPanes),
                right: buildNode(from: rightPanes)
            )
        )
    }
}

struct ExplorerWindow: Codable, Identifiable, Equatable {
    var id: String
    var title: String?
    var workspace: Int?
    var tabs: [ExplorerTab]

    private enum CodingKeys: String, CodingKey {
        case id
        case title
        case workspace
        case space
        case tabs
    }

    init(id: String, title: String? = nil, workspace: Int? = nil, tabs: [ExplorerTab]) {
        self.id = id
        self.title = title
        self.workspace = workspace
        self.tabs = tabs
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        title = try container.decodeIfPresent(String.self, forKey: .title)
        tabs = try container.decode([ExplorerTab].self, forKey: .tabs)
        workspace = try Self.decodeWorkspace(from: container)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encodeIfPresent(title, forKey: .title)
        try container.encodeIfPresent(workspace, forKey: .workspace)
        try container.encode(tabs, forKey: .tabs)
    }

    private static func decodeWorkspace(
        from container: KeyedDecodingContainer<CodingKeys>
    ) throws -> Int? {
        func decodeWorkspace(for key: CodingKeys) throws -> Int? {
            if let intValue = try? container.decode(Int.self, forKey: key) {
                return intValue
            }

            if let stringValue = try? container.decode(String.self, forKey: key) {
                return Int(stringValue.trimmingCharacters(in: .whitespacesAndNewlines))
            }

            if let doubleValue = try? container.decode(Double.self, forKey: key) {
                return Int(doubleValue)
            }

            return nil
        }

        if let workspace = try decodeWorkspace(for: .workspace) {
            return workspace
        }

        return try decodeWorkspace(for: .space)
    }
}

struct ExplorerTab: Codable, Equatable {
    var title: String?
    var surfaceTree: ExplorerSurfaceTree

    init(title: String? = nil, surfaceTree: ExplorerSurfaceTree) {
        self.title = title
        self.surfaceTree = surfaceTree
    }
}

struct ExplorerSurfaceTree: Codable, Equatable {
    var root: ExplorerSurfaceNode

    init(root: ExplorerSurfaceNode) {
        self.root = root
    }
}

indirect enum ExplorerSurfaceNode: Codable, Equatable {
    case view(ExplorerSurfaceView)
    case split(ExplorerSurfaceSplit)

    private enum CodingKeys: String, CodingKey {
        case view
        case split
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)

        if container.contains(.split) {
            self = .split(try container.decode(ExplorerSurfaceSplit.self, forKey: .split))
            return
        }

        if container.contains(.view) {
            self = .view(try container.decode(ExplorerSurfaceView.self, forKey: .view))
            return
        }

        throw DecodingError.dataCorruptedError(
            forKey: .view,
            in: container,
            debugDescription: "ExplorerSurfaceNode must contain either a view or split payload."
        )
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .view(let view):
            try container.encode(view, forKey: .view)
        case .split(let split):
            try container.encode(split, forKey: .split)
        }
    }
}

struct ExplorerSurfaceView: Codable, Equatable {
    var id: String?
    var pwd: String?
    var title: String?
    var foregroundPid: Int?
    var foregroundProcess: String?
    var processExited: Bool?
    var command: TemplateCommand?

    private enum CodingKeys: String, CodingKey {
        case id
        case pwd
        case title
        case foregroundPid
        case foregroundProcess
        case processExited
        case command
        case initialInput
    }

    init(
        id: String? = nil,
        pwd: String? = nil,
        title: String? = nil,
        foregroundPid: Int? = nil,
        foregroundProcess: String? = nil,
        processExited: Bool? = nil,
        command: TemplateCommand? = nil
    ) {
        self.id = id
        self.pwd = pwd
        self.title = title
        self.foregroundPid = foregroundPid
        self.foregroundProcess = foregroundProcess
        self.processExited = processExited
        self.command = command
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(String.self, forKey: .id)
        pwd = try container.decodeIfPresent(String.self, forKey: .pwd)
        title = try container.decodeIfPresent(String.self, forKey: .title)
        foregroundPid = try container.decodeIfPresent(Int.self, forKey: .foregroundPid)
        foregroundProcess = try container.decodeIfPresent(String.self, forKey: .foregroundProcess)
        processExited = try container.decodeIfPresent(Bool.self, forKey: .processExited)

        if let decodedCommand = try? container.decode(TemplateCommand.self, forKey: .command) {
            command = decodedCommand
        } else if let legacyCommand = try container.decodeIfPresent(String.self, forKey: .command) {
            command = TemplateCommand.literal(fromCommands: [legacyCommand])
        } else if let initialInput = try container.decodeIfPresent(String.self, forKey: .initialInput) {
            command = TemplateCommand.literal(fromLegacyInitialInput: initialInput)
        } else {
            command = nil
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(id, forKey: .id)
        try container.encodeIfPresent(pwd, forKey: .pwd)
        try container.encodeIfPresent(title, forKey: .title)
        try container.encodeIfPresent(foregroundPid, forKey: .foregroundPid)
        try container.encodeIfPresent(foregroundProcess, forKey: .foregroundProcess)
        try container.encodeIfPresent(processExited, forKey: .processExited)
        try container.encodeIfPresent(command, forKey: .command)
    }
}

struct ExplorerSurfaceSplit: Codable, Equatable {
    var direction: String
    var ratio: Double
    var left: ExplorerSurfaceNode
    var right: ExplorerSurfaceNode

    private enum CodingKeys: String, CodingKey {
        case direction
        case ratio
        case left
        case right
    }

    init(direction: String, ratio: Double, left: ExplorerSurfaceNode, right: ExplorerSurfaceNode) {
        self.direction = direction
        self.ratio = ratio
        self.left = left
        self.right = right
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        // SplitTree.Direction is encoded by Swift's synthesized Codable as a
        // tagged dict (e.g. {"horizontal": {}}). Older snapshots wrote a plain
        // string. Accept either form and normalize to a lowercased string.
        if let str = try? container.decode(String.self, forKey: .direction) {
            self.direction = str
        } else if let dict = try? container.decode([String: AnyCodable].self, forKey: .direction),
                  let key = dict.keys.first {
            self.direction = key
        } else {
            throw DecodingError.dataCorruptedError(
                forKey: .direction,
                in: container,
                debugDescription: "direction must be a string or tagged dict"
            )
        }
        self.ratio = try container.decode(Double.self, forKey: .ratio)
        self.left = try container.decode(ExplorerSurfaceNode.self, forKey: .left)
        self.right = try container.decode(ExplorerSurfaceNode.self, forKey: .right)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(direction, forKey: .direction)
        try container.encode(ratio, forKey: .ratio)
        try container.encode(left, forKey: .left)
        try container.encode(right, forKey: .right)
    }
}

/// Minimal Codable wrapper that lets us decode arbitrary JSON values when we
/// only need to peek at keys (used by ExplorerSurfaceSplit's tolerant
/// direction decoder).
private struct AnyCodable: Codable {
    init(from decoder: Decoder) throws {
        _ = try decoder.singleValueContainer()
    }
    func encode(to encoder: Encoder) throws {}
}

extension ExplorerWindow {
    var displayTitle: String {
        firstNonEmpty(title, tabs.first?.title, id) ?? id
    }

    var normalizedTitle: String {
        displayTitle.normalizedForMatching
    }

    var tabDirectorySignatureSet: Set<String> {
        Set(tabs.map(\.workingDirectorySignature))
    }
}

extension ExplorerTab {
    var displayTitle: String {
        firstNonEmpty(title, workingDirectories.first, "Untitled Tab") ?? "Untitled Tab"
    }

    var workingDirectories: [String] {
        surfaceTree.root.flattenedPanes().compactMap(\.view.pwd)
    }

    var workingDirectorySignature: String {
        let directories = surfaceTree.root.flattenedPanes()
            .compactMap(\.view.pwd)
            .map(\.normalizedForMatching)
            .filter { !$0.isEmpty }
            .sorted()
        return directories.joined(separator: "|")
    }

    var splitSignature: [String] {
        surfaceTree.root.flattenedPanes()
            .map { $0.path.map(String.init).joined(separator: ".") }
            .sorted()
    }

    var paneCount: Int {
        surfaceTree.root.flattenedPanes().count
    }
}

extension ExplorerSurfaceNode {
    struct FlattenedPane {
        let view: ExplorerSurfaceView
        let position: String
        let path: [Int]
    }

    func flattenedPanes(prefix: String = "", path: [Int] = []) -> [FlattenedPane] {
        switch self {
        case .view(let view):
            let label = prefix.isEmpty ? "root" : prefix
                .replacingOccurrences(of: "right-left", with: "center")
            return [FlattenedPane(view: view, position: label, path: path)]
        case .split(let split):
            let leftLabel = split.direction == "vertical" ? "top" : "left"
            let rightLabel = split.direction == "vertical" ? "bottom" : "right"
            let leftPrefix = prefix.isEmpty ? leftLabel : "\(prefix)-\(leftLabel)"
            let rightPrefix = prefix.isEmpty ? rightLabel : "\(prefix)-\(rightLabel)"
            return split.left.flattenedPanes(prefix: leftPrefix, path: path + [0])
                + split.right.flattenedPanes(prefix: rightPrefix, path: path + [1])
        }
    }

    /// Remove the pane at the given path. When a pane is removed from a split,
    /// its sibling takes over the split's position in the tree. Returns nil if
    /// the removed pane was the root (can't remove the last pane).
    mutating func removingPane(at path: [Int]) -> ExplorerSurfaceNode? {
        guard !path.isEmpty else { return nil }

        if path.count == 1 {
            guard case .split(let split) = self else { return nil }
            return path[0] == 0 ? split.right : split.left
        }

        guard case .split(var split) = self else { return nil }
        let tail = Array(path.dropFirst())
        if path[0] == 0 {
            if let replacement = split.left.removingPane(at: tail) {
                split.left = replacement
                self = .split(split)
                return self
            }
        } else {
            if let replacement = split.right.removingPane(at: tail) {
                split.right = replacement
                self = .split(split)
                return self
            }
        }
        return nil
    }

    func view(at path: [Int]) -> ExplorerSurfaceView? {
        switch self {
        case .view(let view):
            return path.isEmpty ? view : nil
        case .split(let split):
            guard let head = path.first else { return nil }
            let tail = Array(path.dropFirst())
            return head == 0 ? split.left.view(at: tail) : split.right.view(at: tail)
        }
    }

    mutating func updateView(at path: [Int], transform: (inout ExplorerSurfaceView) -> Void) {
        switch self {
        case .view(var view):
            guard path.isEmpty else { return }
            transform(&view)
            self = .view(view)

        case .split(var split):
            guard let head = path.first else { return }
            let tail = Array(path.dropFirst())
            if head == 0 {
                split.left.updateView(at: tail, transform: transform)
            } else {
                split.right.updateView(at: tail, transform: transform)
            }
            self = .split(split)
        }
    }
}

extension ExplorerSurfaceTree {
    func view(at path: [Int]) -> ExplorerSurfaceView? {
        root.view(at: path)
    }

    mutating func updateView(at path: [Int], transform: (inout ExplorerSurfaceView) -> Void) {
        root.updateView(at: path, transform: transform)
    }

    /// Remove the pane at the given path. Returns false if the pane is the
    /// last one (root view with no splits) — can't remove the only pane.
    @discardableResult
    mutating func removePane(at path: [Int]) -> Bool {
        if let newRoot = root.removingPane(at: path) {
            root = newRoot
            return true
        }
        return false
    }
}

struct LiveSurfaceRecord: Decodable {
    let surfaceID: String
    let windowID: Int
    let windowTitle: String?
    let tabIndex: Int
    let tabTitle: String?
    let splitPath: [Int]
    let shellPid: Int?
    let workingDirectory: String?

    private enum CodingKeys: String, CodingKey {
        case surfaceID = "surface_id"
        case windowID = "window_id"
        case windowTitle = "window_title"
        case tabIndex = "tab_index"
        case tabTitle = "tab_title"
        case splitPath = "split_path"
        case shellPid = "shell_pid"
        case workingDirectory = "working_directory"
    }
}

private struct LivePane {
    let path: [Int]
    let view: ExplorerSurfaceView

    init(record: LiveSurfaceRecord) {
        path = record.splitPath
        view = ExplorerSurfaceView(
            id: record.surfaceID,
            pwd: record.workingDirectory,
            title: record.tabTitle,
            foregroundPid: record.shellPid,
            foregroundProcess: nil,
            processExited: nil
        )
    }

    func droppingFirstPathComponent() -> LivePane {
        LivePane(path: Array(path.dropFirst()), view: view)
    }

    private init(path: [Int], view: ExplorerSurfaceView) {
        self.path = path
        self.view = view
    }
}

private func firstNonEmpty(_ values: String?...) -> String? {
    values.first(where: {
        guard let value = $0 else { return false }
        return !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }) ?? nil
}

extension String {
    var normalizedForMatching: String {
        trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }
}
