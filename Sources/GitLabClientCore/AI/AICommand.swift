import Foundation

/// A command-line AI the app can drive. The template is split into arguments like a shell
/// would, then placeholders are filled in per argument, so no shell ever sees the prompt.
public struct AIPreset: Identifiable, Hashable, Sendable {
    public let id: String
    public let name: String
    public let binaryName: String?
    public let defaultTemplate: String
    public let summary: String

    public static let claude = AIPreset(
        id: "claude", name: "Claude Code", binaryName: "claude",
        defaultTemplate: #"claude -p "{prompt}" --permission-mode acceptEdits"#,
        summary: "Anthropic's coding agent in the terminal.")
    public static let codex = AIPreset(
        id: "codex", name: "Codex CLI", binaryName: "codex",
        defaultTemplate: #"codex exec --full-auto "{prompt}""#,
        summary: "OpenAI's coding agent in the terminal.")
    public static let gemini = AIPreset(
        id: "gemini", name: "Gemini CLI", binaryName: "gemini",
        defaultTemplate: #"gemini --yolo -p "{prompt}""#,
        summary: "Google's coding agent in the terminal.")
    public static let aider = AIPreset(
        id: "aider", name: "Aider", binaryName: "aider",
        defaultTemplate: #"aider --yes --no-auto-commits --message "{prompt}" {conflicted_files}"#,
        summary: "Open-source pair programmer for git repos.")
    public static let custom = AIPreset(
        id: "custom", name: "Custom", binaryName: nil,
        defaultTemplate: #"/path/to/your-ai --cwd {worktree} "{prompt}""#,
        summary: "Your own command, with any of the placeholders.")

    public static let all: [AIPreset] = [.claude, .codex, .gemini, .aider, .custom]

    public static func with(id: String) -> AIPreset { all.first { $0.id == id } ?? .claude }
}

public enum AITask: String, CaseIterable, Codable, Sendable, Identifiable {
    case rebaseOntoTarget
    case resolveMergeConflicts

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .rebaseOntoTarget: return "Rebase onto target"
        case .resolveMergeConflicts: return "Resolve merge conflicts"
        }
    }

    public var defaultPrompt: String {
        switch self {
        case .rebaseOntoTarget:
            return """
            You are in a temporary git worktree at {worktree}, on a copy of branch {branch}.
            Rebasing it onto {target} stopped with conflicts in:
            {conflicted_files}

            Edit those files so every conflict is resolved and both sides keep working.
            Remove every conflict marker. Don't change unrelated code.
            Don't run git commit, git rebase or git merge: the app continues the rebase when you finish.
            """
        case .resolveMergeConflicts:
            return """
            You are in a temporary git worktree at {worktree}, on a copy of branch {branch}.
            Merging {target} into it stopped with conflicts in:
            {conflicted_files}

            Edit those files so every conflict is resolved and both sides keep working.
            Remove every conflict marker. Don't change unrelated code.
            Don't run git commit or git merge: the app commits the merge when you finish.
            """
        }
    }
}

public enum AIPrompt {
    /// Appended to every prompt; users can't edit it away.
    public static let safetyRules = "Never run git push. Never change files outside {worktree}."

    public static func render(_ template: String, values: [String: String], files: [String]) -> String {
        let body = CommandTemplate.fill(template, values: values, lists: ["conflicted_files": files], listSeparator: "\n")
        let rules = CommandTemplate.fill(safetyRules, values: values, lists: [:], listSeparator: "\n")
        return body.trimmingCharacters(in: .whitespacesAndNewlines) + "\n\n" + rules
    }
}

public enum CommandTemplate {
    public static let placeholders = ["prompt", "worktree", "branch", "target", "conflicted_files"]

    public enum ParseError: Error, LocalizedError, Equatable {
        case empty
        case unbalancedQuote
        case missingPrompt

        public var errorDescription: String? {
            switch self {
            case .empty: return "The command template is empty."
            case .unbalancedQuote: return "The command template has an unclosed quote."
            case .missingPrompt: return "The command template must contain {prompt}."
            }
        }
    }

    /// Splits like a POSIX shell: single quotes are literal, double quotes allow \" and \\,
    /// a backslash outside quotes escapes the next character.
    public static func tokenize(_ template: String) throws -> [String] {
        var tokens: [String] = []
        var current = ""
        var inToken = false
        var quote: Character?
        var escaping = false
        for character in template {
            if escaping {
                current.append(character)
                escaping = false
                inToken = true
                continue
            }
            switch (quote, character) {
            case ("'", "'"), ("\"", "\""):
                quote = nil
            case ("'", _):
                current.append(character)
            case ("\"", "\\"), (nil, "\\"):
                escaping = true
            case ("\"", _):
                current.append(character)
            case (nil, "'"), (nil, "\""):
                quote = character
                inToken = true
            case (nil, _) where character.isWhitespace:
                if inToken { tokens.append(current) }
                current = ""
                inToken = false
            default:
                current.append(character)
                inToken = true
            }
        }
        guard quote == nil, !escaping else { throw ParseError.unbalancedQuote }
        if inToken { tokens.append(current) }
        guard !tokens.isEmpty else { throw ParseError.empty }
        return tokens
    }

    /// Fills placeholders in one pass, so a value that itself contains "{worktree}" stays as is.
    /// An argument that is exactly a list placeholder expands to one argument per item.
    public static func render(_ tokens: [String], values: [String: String], lists: [String: [String]]) -> [String] {
        tokens.flatMap { token -> [String] in
            for (key, items) in lists where token == "{\(key)}" { return items }
            return [fill(token, values: values, lists: lists, listSeparator: " ")]
        }
    }

    public static func fill(_ text: String, values: [String: String], lists: [String: [String]], listSeparator: String) -> String {
        text.replacing(#/\{([a-z_]+)\}/#) { match in
            let key = String(match.1)
            if let value = values[key] { return value }
            if let items = lists[key] { return items.joined(separator: listSeparator) }
            return String(match.0)
        }
    }

    public static func validate(_ template: String) throws {
        let tokens = try tokenize(template)
        guard tokens.contains(where: { $0.contains("{prompt}") }) else { throw ParseError.missingPrompt }
    }
}
