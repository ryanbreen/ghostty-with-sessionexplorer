import Foundation

enum SessionExplorerSelection: Equatable {
    case state
    case backup(String)
}

enum PaneCommandMode: String, CaseIterable, Identifiable {
    case none = "None"
    case literal = "Shell Commands"
    case dynamic = "Dynamic Resolver"

    var id: String { rawValue }
}

enum BuiltinStartupResolver: String, CaseIterable, Identifiable {
    case claudeResumeLatest
    case claudeResumeNth
    case codexResumeLast

    var id: String { rawValue }

    var title: String { rawValue }
}

extension Array where Element == Int {
    var sessionExplorerPathKey: String {
        isEmpty ? "root" : map(String.init).joined(separator: ".")
    }
}
