import Foundation

/// Mirrors the cleanup at https://tools.simonwillison.net/cleanup-claude-code-paste.
///
/// Claude Code prints prose with hard newlines at the terminal width
/// boundary, sometimes prefixed with `❯ ` and followed by leading
/// indentation on continuation rows. Selecting + copying that into any
/// editor pastes a column of fragments instead of a paragraph.
///
/// Algorithm:
/// 1. Strip a leading `❯ ` prompt marker on each line.
/// 2. Group consecutive non-blank lines into paragraphs; a blank line
///    is the paragraph break.
/// 3. Trim each line, join paragraph lines with a single space.
/// 4. Collapse any run of whitespace inside a paragraph to one space.
/// 5. Re-emit paragraphs separated by a blank line.
///
/// Tradeoff: code-block indentation is destroyed (every non-blank line
/// becomes a single space-joined paragraph). The macOS binding for this
/// is intentionally Cmd-Opt-C so plain Cmd-C still produces a verbatim
/// copy when you need raw code.
enum ClaudePasteCleaner {
    static func clean(_ text: String) -> String {
        let stripped = text.replacingOccurrences(
            of: #"(?m)^❯\s*"#,
            with: "",
            options: .regularExpression
        )

        var paragraphs: [[String]] = []
        var current: [String] = []
        for raw in stripped.split(separator: "\n", omittingEmptySubsequences: false) {
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty {
                if !current.isEmpty {
                    paragraphs.append(current)
                    current = []
                }
            } else {
                current.append(trimmed)
            }
        }
        if !current.isEmpty {
            paragraphs.append(current)
        }

        return paragraphs
            .map { lines in
                lines.joined(separator: " ").replacingOccurrences(
                    of: #"\s{2,}"#,
                    with: " ",
                    options: .regularExpression
                )
            }
            .joined(separator: "\n\n")
    }
}
