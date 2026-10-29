import Foundation

/// A comment or a system event ("approved this merge request") on a merge request.
public struct Note: Codable, Sendable, Hashable, Identifiable {
    public struct Position: Codable, Sendable, Hashable {
        public var newPath: String?
        public var oldPath: String?
        public var newLine: Int?
        public var oldLine: Int?
    }

    public var id: Int
    public var body: String
    public var author: GitLabPerson
    public var createdAt: String
    public var system: Bool
    public var resolvable: Bool?
    public var resolved: Bool?
    public var resolvedBy: GitLabPerson?
    public var type: String?
    public var position: Position?

    public init(id: Int, body: String, author: GitLabPerson, createdAt: String, system: Bool = false,
                resolvable: Bool? = nil, resolved: Bool? = nil) {
        self.id = id
        self.body = body
        self.author = author
        self.createdAt = createdAt
        self.system = system
        self.resolvable = resolvable
        self.resolved = resolved
    }

    public var createdDate: Date? { GitLabDate.parse(createdAt) }

    /// "Sources/App.swift:48" for a comment on a diff line.
    public var location: String? {
        guard let position, let path = position.newPath ?? position.oldPath else { return nil }
        if let line = position.newLine ?? position.oldLine { return "\(path):\(line)" }
        return path
    }
}

/// A thread: one note, or a comment with its replies.
public struct Discussion: Codable, Sendable, Hashable, Identifiable {
    public var id: String
    public var individualNote: Bool
    public var notes: [Note]

    public init(id: String, individualNote: Bool, notes: [Note]) {
        self.id = id
        self.individualNote = individualNote
        self.notes = notes
    }

    public var isSystem: Bool { notes.first?.system == true }
    public var isResolvable: Bool { notes.contains { $0.resolvable == true } }
    public var isResolved: Bool { isResolvable && notes.allSatisfy { $0.resolvable != true || $0.resolved == true } }
    public var resolvedBy: GitLabPerson? { notes.compactMap(\.resolvedBy).last }
    public var createdDate: Date? { notes.first?.createdDate }
}

/// System notes carry a little HTML: "added 2 commits\n\n<ul><li>3f2a91c - Title</li></ul>
/// \n\n[Compare with previous version](/…)". This splits them into a sentence and list items.
public enum SystemNote {
    public static func parse(_ body: String) -> (text: String, items: [String]) {
        let items = body.matches(of: #/<li>(.*?)</li>/#.dotMatchesNewlines()).map { clean(String($0.1)) }.filter { !$0.isEmpty }
        var text = body
        if let list = text.firstRange(of: #/<ul>.*</ul>/#.dotMatchesNewlines()) { text.removeSubrange(list) }
        text = text.replacing(#/\[Compare with previous version\]\([^)]*\)/#, with: "")
        return (clean(text), items)
    }

    private static func clean(_ text: String) -> String {
        text.replacing(#/<[^>]+>/#, with: "")
            .replacingOccurrences(of: "**", with: "")
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&#39;", with: "'")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            .joined(separator: " ")
    }
}
