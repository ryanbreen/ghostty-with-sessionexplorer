import Foundation

protocol StartupResolver {
    func resolve(pwd: String, params: [String: String]) -> String
}

struct StartupResolverRegistry {
    static let shared = StartupResolverRegistry()

    let resolvers: [String: any StartupResolver]

    init(resolvers: [String: any StartupResolver] = [
        "claudeResumeLatest": ClaudeResumeLatestResolver(),
        "claudeResumeNth": ClaudeResumeNthResolver(),
        "codexResumeLast": CodexResumeLastResolver(),
    ]) {
        self.resolvers = resolvers
    }

    func resolve(resolver name: String, pwd: String, params: [String: String]) -> String {
        guard let resolver = resolvers[name] else {
            return Self.failureCommand(
                resolver: name,
                reason: "unknown resolver"
            )
        }

        return resolver.resolve(pwd: pwd, params: params)
    }

    static func failureCommand(resolver name: String, reason: String) -> String {
        let escapedName = shellEscaped(name)
        let escapedReason = shellEscaped(reason)
        return "echo \"resolver '\(escapedName)' failed: \(escapedReason)\""
    }

    private static func shellEscaped(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }
}

private struct ClaudeResumeLatestResolver: StartupResolver {
    func resolve(pwd: String, params: [String: String]) -> String {
        ClaudeSessionResolver.resolve(pwd: pwd, nth: 0, resolverName: "claudeResumeLatest")
    }
}

private struct ClaudeResumeNthResolver: StartupResolver {
    func resolve(pwd: String, params: [String: String]) -> String {
        guard let rawValue = params["n"], let nth = Int(rawValue), nth >= 0 else {
            return StartupResolverRegistry.failureCommand(
                resolver: "claudeResumeNth",
                reason: "missing or invalid 'n' parameter"
            )
        }

        return ClaudeSessionResolver.resolve(pwd: pwd, nth: nth, resolverName: "claudeResumeNth")
    }
}

private enum ClaudeSessionResolver {
    static func resolve(pwd: String, nth: Int, resolverName: String) -> String {
        let encodedPath = pwd.replacingOccurrences(of: "/", with: "-")
        let directory = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude")
            .appendingPathComponent("projects")
            .appendingPathComponent(encodedPath)

        guard let urls = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else {
            return StartupResolverRegistry.failureCommand(
                resolver: resolverName,
                reason: "no sessions found for \(pwd)"
            )
        }

        let candidates = urls
            .filter { $0.pathExtension == "jsonl" }
            .sorted { lhs, rhs in
                let lhsDate = (try? lhs.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
                let rhsDate = (try? rhs.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
                return lhsDate > rhsDate
            }

        guard candidates.indices.contains(nth) else {
            return StartupResolverRegistry.failureCommand(
                resolver: resolverName,
                reason: "requested session \(nth) but found only \(candidates.count) session(s) for \(pwd)"
            )
        }

        let sessionID = candidates[nth].deletingPathExtension().lastPathComponent
        return "claude --resume \(sessionID)"
    }
}

private struct CodexResumeLastResolver: StartupResolver {
    func resolve(pwd: String, params: [String: String]) -> String {
        let sessionsRoot = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".codex")
            .appendingPathComponent("sessions")

        guard let enumerator = FileManager.default.enumerator(
            at: sessionsRoot,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            return StartupResolverRegistry.failureCommand(
                resolver: "codexResumeLast",
                reason: "no Codex session storage found"
            )
        }

        var candidates: [CodexSessionCandidate] = []

        for case let url as URL in enumerator {
            guard url.pathExtension == "jsonl" else { continue }
            guard let metadata = readMetadata(from: url) else { continue }
            guard metadata.cwd == pwd else { continue }
            candidates.append(metadata)
        }

        guard let session = candidates.sorted(by: { $0.updatedAt > $1.updatedAt }).first else {
            return StartupResolverRegistry.failureCommand(
                resolver: "codexResumeLast",
                reason: "no sessions found for \(pwd)"
            )
        }

        return "codex resume \(session.id)"
    }

    private func readMetadata(from url: URL) -> CodexSessionCandidate? {
        guard
            let handle = try? FileHandle(forReadingFrom: url),
            let data = try? handle.read(upToCount: 4096),
            let contents = String(data: data, encoding: .utf8)
        else {
            return nil
        }

        let firstLine = contents.split(whereSeparator: \.isNewline).first.map(String.init)
        guard let firstLine, let lineData = firstLine.data(using: .utf8) else {
            return nil
        }

        guard let metadata = try? JSONDecoder().decode(CodexSessionMetaLine.self, from: lineData) else {
            return nil
        }

        guard metadata.type == "session_meta" else { return nil }
        guard
            let updatedAt = SessionStore.parsedTimestampFormatter.date(from: metadata.payload.timestamp)
                ?? SessionStore.parsedTimestampFormatterNoFraction.date(from: metadata.payload.timestamp)
        else {
            return nil
        }

        return CodexSessionCandidate(
            id: metadata.payload.id,
            cwd: metadata.payload.cwd,
            updatedAt: updatedAt
        )
    }
}

private struct CodexSessionCandidate {
    let id: String
    let cwd: String
    let updatedAt: Date
}

private struct CodexSessionMetaLine: Decodable {
    let type: String
    let payload: Payload

    struct Payload: Decodable {
        let id: String
        let timestamp: String
        let cwd: String
    }
}
