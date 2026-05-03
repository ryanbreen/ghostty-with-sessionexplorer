import Foundation

/// Completion source for the prompt editor. Phase 1: filesystem
/// (paths) + executables on $PATH + a small set of shell builtins.
/// Phases 2/3 will layer popover-aware multi-candidate handling and
/// history-based frecency on top of this.
final class CompletionEngine {
    /// A completion candidate.
    struct Completion {
        /// The full text of the candidate (NOT the suffix). e.g. for
        /// input `ls -l Doc` and the candidate `Documents`, `text` is
        /// `Documents`.
        let text: String
        let kind: Kind

        enum Kind {
            case file
            case directory
            case executable
            case builtin
        }

        /// The suffix-only completion: what to insert after the
        /// existing partial word. e.g. for word=`Doc` and text=`Documents`,
        /// `suffix` is `uments`.
        func suffix(after partial: String) -> String {
            guard text.hasPrefix(partial) else { return "" }
            return String(text.dropFirst(partial.count))
        }
    }

    /// Result of parsing the input line.
    private struct Parsed {
        /// The word currently under the cursor (everything from the
        /// last whitespace boundary up to the cursor).
        let currentWord: String
        /// Index in the line where currentWord starts.
        let wordStart: Int
        /// True if currentWord is the FIRST word on the line (so
        /// command completion applies).
        let isCommandPosition: Bool
        /// The first word of the line (the command being run), if any.
        /// Used for context-aware completion (e.g. `cd` → directories
        /// only).
        let commandWord: String?

        var isDirectoryContext: Bool {
            guard let cmd = commandWord else { return false }
            return ["cd", "pushd", "rmdir"].contains(cmd)
        }
    }

    /// Cached executable list, refreshed when $PATH changes or every
    /// `cacheTTL` seconds.
    private var executableCache: Set<String> = []
    private var executableCacheBuiltAt: Date = .distantPast
    private var executableCacheBuiltFor: String = ""
    private let cacheTTL: TimeInterval = 30

    /// Builtins for the common shells. Hardcoded list — these don't
    /// appear on $PATH.
    private static let builtins: Set<String> = [
        "alias", "bg", "bind", "break", "builtin", "case", "cd", "command",
        "compgen", "complete", "continue", "declare", "dirs", "disown",
        "echo", "enable", "eval", "exec", "exit", "export", "fc", "fg",
        "for", "function", "getopts", "hash", "help", "history", "if",
        "jobs", "kill", "let", "local", "logout", "popd", "printf",
        "pushd", "pwd", "read", "readonly", "return", "select", "set",
        "shift", "shopt", "source", "suspend", "test", "times", "trap",
        "type", "typeset", "ulimit", "umask", "unalias", "unset", "until",
        "wait", "which", "while",
    ]

    /// Commands that take only directory arguments.
    private static let directoryOnly: Set<String> = ["cd", "pushd", "rmdir"]

    /// Commands known to take file/path arguments. The inline ghost
    /// shows for these even when the typed word doesn't look path-like.
    /// Other commands (ssh, kubectl, git, etc.) don't get ghost
    /// suggestions for their arguments — Tab still works there, the
    /// user just isn't pestered with random pwd-file suggestions.
    private static let fileTakingCommands: Set<String> = [
        "cat", "cd", "chmod", "chown", "code", "cp", "diff", "du",
        "emacs", "file", "head", "less", "ln", "ls", "mkdir", "more",
        "mv", "nano", "open", "popd", "pushd", "rm", "rmdir", "source",
        "stat", "subl", "tail", "touch", "vi", "vim", "which", "zip",
    ]

    // MARK: - Public API

    /// Returns the best inline completion candidate for the given
    /// input, or nil if nothing matches OR if the context isn't
    /// confident enough to suggest. Conservative on purpose: we only
    /// show a ghost for path-like words, command-position completion,
    /// or when the command is a known file-taker. The user's Tab key
    /// always works (via `tabComplete`), so being silent here is fine.
    func bestInlineCompletion(line: String, cursor: Int, pwd: String) -> Completion? {
        let parsed = parse(line: line, cursor: cursor)
        guard shouldShowInlineGhost(parsed: parsed) else { return nil }
        return rankedMatches(parsed: parsed, pwd: pwd).first
    }

    /// Compute completions for the user's Tab key press. Returns the
    /// suffix to insert (longest common prefix of all matches, minus
    /// the partial the user already typed). Empty string means "no
    /// applicable completion". Always permissive — Tab works in any
    /// context where there are matching files/executables.
    func tabComplete(line: String, cursor: Int, pwd: String) -> String {
        let parsed = parse(line: line, cursor: cursor)
        let matches = rankedMatches(parsed: parsed, pwd: pwd)
        guard !matches.isEmpty else { return "" }

        if matches.count == 1 {
            return matches[0].suffix(after: parsed.currentWord)
        }

        // Multiple matches: complete to the longest common prefix.
        let lcp = longestCommonPrefix(matches.map(\.text))
        guard lcp.count > parsed.currentWord.count else { return "" }
        return String(lcp.dropFirst(parsed.currentWord.count))
    }

    private func rankedMatches(parsed: Parsed, pwd: String) -> [Completion] {
        return candidates(parsed: parsed, pwd: pwd)
            .filter { $0.text.hasPrefix(parsed.currentWord) && $0.text != parsed.currentWord }
            .sorted { lhs, rhs in
                if (lhs.kind == .directory) != (rhs.kind == .directory) {
                    return lhs.kind == .directory
                }
                return lhs.text.localizedCaseInsensitiveCompare(rhs.text) == .orderedAscending
            }
    }

    private func shouldShowInlineGhost(parsed: Parsed) -> Bool {
        // Always show ghost for command-position completion.
        if parsed.isCommandPosition { return true }
        // Always show for path-like words (contain /, start with ~ or .).
        let w = parsed.currentWord
        if w.contains("/") || w.hasPrefix("~") || w.hasPrefix(".") { return true }
        // Show for arguments only when the command is a known
        // file-taker. Skips noisy ghosts for `ssh foo`, `git foo`, etc.
        if let cmd = parsed.commandWord,
            Self.fileTakingCommands.contains(cmd)
        {
            return true
        }
        return false
    }

    private func longestCommonPrefix(_ strings: [String]) -> String {
        guard let first = strings.first else { return "" }
        var prefix = first
        for s in strings.dropFirst() {
            while !s.hasPrefix(prefix) {
                prefix = String(prefix.dropLast())
                if prefix.isEmpty { return "" }
            }
        }
        return prefix
    }

    // MARK: - Parsing

    private func parse(line: String, cursor: Int) -> Parsed {
        // Defensive clamping.
        let cursor = max(0, min(cursor, line.count))

        // Walk back from cursor to find the word start.
        let chars = Array(line)
        var wordStart = cursor
        while wordStart > 0 && !isWordBreak(chars[wordStart - 1]) {
            wordStart -= 1
        }
        let currentWord = String(chars[wordStart..<cursor])

        // Find the first non-whitespace token in the line — that's
        // the command being run.
        let trimmed = line.drop(while: { $0.isWhitespace })
        let firstWordEnd = trimmed.firstIndex(where: { $0.isWhitespace }) ?? trimmed.endIndex
        let commandWord = String(trimmed[trimmed.startIndex..<firstWordEnd])

        // We're at the command position iff the cursor's word starts
        // before / at the first non-whitespace char of the line.
        let firstNonWS = line.firstIndex(where: { !$0.isWhitespace }).map { line.distance(from: line.startIndex, to: $0) } ?? line.count
        let isCommandPosition = wordStart <= firstNonWS

        return Parsed(
            currentWord: currentWord,
            wordStart: wordStart,
            isCommandPosition: isCommandPosition,
            commandWord: commandWord.isEmpty ? nil : commandWord)
    }

    private func isWordBreak(_ c: Character) -> Bool {
        // Whitespace and shell metacharacters break words. Forward
        // slash does NOT break — it's part of paths.
        if c.isWhitespace { return true }
        switch c {
        case ";", "|", "&", "(", ")", "<", ">", "`":
            return true
        default:
            return false
        }
    }

    // MARK: - Candidates

    private func candidates(parsed: Parsed, pwd: String) -> [Completion] {
        // If the word looks like a path (contains a slash, starts
        // with `~`, or starts with `.`), do filesystem completion
        // regardless of position.
        let word = parsed.currentWord
        if word.contains("/") || word.hasPrefix("~") || word.hasPrefix(".") {
            return filesystemCandidates(
                word: word,
                pwd: pwd,
                directoriesOnly: parsed.isDirectoryContext)
        }

        if parsed.isCommandPosition {
            return executableCandidates(prefix: word)
        }

        // Otherwise: filesystem completion in pwd (most common
        // argument shape — a file in the current directory).
        return filesystemCandidates(
            word: word,
            pwd: pwd,
            directoriesOnly: parsed.isDirectoryContext)
    }

    // MARK: - Filesystem source

    private func filesystemCandidates(
        word: String,
        pwd: String,
        directoriesOnly: Bool
    ) -> [Completion] {
        // Split the word into "directory part" + "name prefix to
        // match". e.g. `src/foo` → searchDir=`src`, prefix=`foo`.
        let expanded = expandTilde(word)
        let (searchDir, prefix) = splitPathPrefix(expanded, pwd: pwd)

        guard let entries = try? FileManager.default.contentsOfDirectory(atPath: searchDir)
        else { return [] }

        var results: [Completion] = []
        for name in entries {
            // Hide dotfiles unless the prefix starts with `.`.
            if name.hasPrefix(".") && !prefix.hasPrefix(".") { continue }
            guard name.lowercased().hasPrefix(prefix.lowercased()) else { continue }

            let fullPath = (searchDir as NSString).appendingPathComponent(name)
            var isDir: ObjCBool = false
            FileManager.default.fileExists(atPath: fullPath, isDirectory: &isDir)
            if directoriesOnly && !isDir.boolValue { continue }

            // Reconstruct the candidate as the user-visible string —
            // preserve their typed prefix shape (relative vs absolute
            // vs ~/) and append the matched name.
            let directoryPart = String(word.dropLast(prefix.count))
            let displayed = directoryPart + name + (isDir.boolValue ? "/" : "")

            results.append(.init(
                text: displayed,
                kind: isDir.boolValue ? .directory : .file))
        }
        return results
    }

    private func expandTilde(_ s: String) -> String {
        guard s.hasPrefix("~") else { return s }
        return (s as NSString).expandingTildeInPath
    }

    /// Split a partial path into the directory to search and the
    /// prefix to match against entries in that directory.
    private func splitPathPrefix(_ word: String, pwd: String) -> (String, String) {
        let expanded = expandTilde(word)
        if let slashRange = expanded.range(of: "/", options: .backwards) {
            let dirPart = String(expanded[..<slashRange.upperBound])
            let prefix = String(expanded[slashRange.upperBound...])
            let searchDir = (dirPart as NSString).standardizingPath
            return (searchDir.isEmpty ? "/" : searchDir, prefix)
        }
        // No slash: search the pwd, prefix is the whole word.
        return (pwd, expanded)
    }

    // MARK: - Executable source

    private func executableCandidates(prefix: String) -> [Completion] {
        refreshExecutableCacheIfNeeded()
        var results: [Completion] = []
        for name in Self.builtins where name.hasPrefix(prefix) {
            results.append(.init(text: name, kind: .builtin))
        }
        for name in executableCache where name.hasPrefix(prefix) {
            results.append(.init(text: name, kind: .executable))
        }
        return results
    }

    private func refreshExecutableCacheIfNeeded() {
        let path = ProcessInfo.processInfo.environment["PATH"] ?? ""
        let now = Date()
        if path == executableCacheBuiltFor &&
            now.timeIntervalSince(executableCacheBuiltAt) < cacheTTL
        {
            return
        }

        var found: Set<String> = []
        for dir in path.split(separator: ":") {
            let dirStr = String(dir)
            guard let entries = try? FileManager.default.contentsOfDirectory(
                atPath: dirStr
            ) else { continue }
            for name in entries {
                let full = (dirStr as NSString).appendingPathComponent(name)
                if FileManager.default.isExecutableFile(atPath: full) {
                    found.insert(name)
                }
            }
        }
        executableCache = found
        executableCacheBuiltFor = path
        executableCacheBuiltAt = now
    }
}

