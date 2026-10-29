import Foundation

public struct Commit: Sendable, Hashable, Identifiable {
    public var hash: String
    public var parents: [String]
    public var authorName: String
    public var authorEmail: String
    public var date: Date
    public var subject: String

    public init(hash: String, parents: [String], authorName: String, authorEmail: String, date: Date, subject: String) {
        self.hash = hash
        self.parents = parents
        self.authorName = authorName
        self.authorEmail = authorEmail
        self.date = date
        self.subject = subject
    }

    public var id: String { hash }
    public var shortHash: String { String(hash.prefix(8)) }
}

public struct GitRef: Sendable, Hashable, Identifiable {
    public var name: String
    public var sha: String
    public var date: Date?
    public var id: String { name }
}

public struct TreeEntry: Sendable, Hashable, Identifiable {
    public enum Kind: String, Sendable { case blob, tree, commit }
    public var kind: Kind
    public var path: String
    public var sha: String

    public init(kind: Kind, path: String, sha: String) {
        self.kind = kind
        self.path = path
        self.sha = sha
    }

    public var id: String { path }
    public var name: String { path.split(separator: "/").last.map(String.init) ?? path }
    public var isDirectory: Bool { kind == .tree }
}

public struct BlameLine: Sendable, Hashable, Identifiable {
    public var lineNumber: Int
    public var hash: String
    public var author: String
    public var content: String
    public var id: Int { lineNumber }
}

public struct DiffLine: Sendable, Hashable {
    public enum Kind: Sendable, Hashable { case context, added, removed, noNewline }
    public var kind: Kind
    public var text: String
    public var oldLine: Int?
    public var newLine: Int?
}

public struct DiffHunk: Sendable, Hashable {
    public var header: String
    public var oldStart: Int
    public var oldCount: Int
    public var newStart: Int
    public var newCount: Int
    public var lines: [DiffLine]
}

public struct DiffFile: Sendable, Hashable, Identifiable {
    public enum Change: String, Sendable { case modified, added, deleted, renamed }
    public var oldPath: String?
    public var newPath: String?
    public var change: Change
    public var isBinary: Bool
    public var hunks: [DiffHunk]

    public init(oldPath: String?, newPath: String?, change: Change = .modified, isBinary: Bool = false, hunks: [DiffHunk] = []) {
        self.oldPath = oldPath
        self.newPath = newPath
        self.change = change
        self.isBinary = isBinary
        self.hunks = hunks
    }

    public var id: String { "\(oldPath ?? "")→\(newPath ?? "")" }
    public var path: String { newPath ?? oldPath ?? "" }
    public var additions: Int { hunks.reduce(0) { $0 + $1.lines.filter { $0.kind == .added }.count } }
    public var deletions: Int { hunks.reduce(0) { $0 + $1.lines.filter { $0.kind == .removed }.count } }
}
