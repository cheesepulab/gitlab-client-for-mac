import Foundation

public enum GitLogParser {
    /// Hash, parents, author name, author email, unix time, subject, split by unit and record separators.
    public static let format = "%H%x1f%P%x1f%an%x1f%ae%x1f%at%x1f%s%x1e"

    public static func parse(_ output: String) -> [Commit] {
        output.split(separator: "\u{1e}").compactMap { record in
            let trimmed = record.drop { $0 == "\n" || $0 == "\r" }
            let fields = trimmed.split(separator: "\u{1f}", omittingEmptySubsequences: false)
            guard fields.count >= 6, fields[0].count >= 7, let time = TimeInterval(fields[4]) else { return nil }
            return Commit(
                hash: String(fields[0]),
                parents: fields[1].split(separator: " ").map(String.init),
                authorName: String(fields[2]),
                authorEmail: String(fields[3]),
                date: Date(timeIntervalSince1970: time),
                subject: fields[5...].joined(separator: "\u{1f}")
            )
        }
    }
}

public enum DiffParser {
    /// Parses `git diff` / `git show` output into files and hunks.
    public static func parse(_ text: String) -> [DiffFile] {
        var files: [DiffFile] = []
        var current: DiffFile?
        var hunkParser = HunkParser()

        func finishFile() {
            if var file = current {
                file.hunks = hunkParser.finish()
                files.append(file)
            }
            current = nil
            hunkParser = HunkParser()
        }

        for raw in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = raw.hasSuffix("\r") ? raw.dropLast() : raw
            if line.hasPrefix("diff --git ") {
                finishFile()
                let paths = parseGitHeaderPaths(line.dropFirst("diff --git ".count))
                current = DiffFile(oldPath: paths.0, newPath: paths.1)
                continue
            }
            guard current != nil else { continue }
            if hunkParser.consume(line) { continue }
            if line.hasPrefix("@@ ") {
                hunkParser.start(line)
            } else if line.hasPrefix("new file mode") {
                current?.change = .added
            } else if line.hasPrefix("deleted file mode") {
                current?.change = .deleted
            } else if line.hasPrefix("rename from ") {
                current?.oldPath = String(line.dropFirst("rename from ".count))
                current?.change = .renamed
            } else if line.hasPrefix("rename to ") {
                current?.newPath = String(line.dropFirst("rename to ".count))
                current?.change = .renamed
            } else if line.hasPrefix("Binary files ") || line.hasPrefix("GIT binary patch") {
                current?.isBinary = true
            } else if line.hasPrefix("--- ") {
                let path = line.dropFirst(4)
                current?.oldPath = path == "/dev/null" ? nil : String(path.hasPrefix("a/") ? path.dropFirst(2) : path)
            } else if line.hasPrefix("+++ ") {
                let path = line.dropFirst(4)
                current?.newPath = path == "/dev/null" ? nil : String(path.hasPrefix("b/") ? path.dropFirst(2) : path)
            }
        }
        finishFile()
        return files
    }

    /// Parses only hunks, as in the `diff` field of GitLab's /diffs API.
    public static func parseHunks(_ text: String) -> [DiffHunk] {
        var parser = HunkParser()
        for raw in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = raw.hasSuffix("\r") ? raw.dropLast() : raw
            if parser.consume(line) { continue }
            if line.hasPrefix("@@ ") { parser.start(line) }
        }
        return parser.finish()
    }

    public static func files(fromAPI diffs: [APIDiff]) -> [DiffFile] {
        diffs.map { diff in
            let change: DiffFile.Change = diff.newFile == true ? .added : diff.deletedFile == true ? .deleted : diff.renamedFile == true ? .renamed : .modified
            let hunks = parseHunks(diff.diff)
            return DiffFile(oldPath: change == .added ? nil : diff.oldPath, newPath: change == .deleted ? nil : diff.newPath,
                            change: change, isBinary: hunks.isEmpty && diff.diff.contains("Binary"), hunks: hunks)
        }
    }

    /// "a/x b/y" → ("x", "y"). Only a fallback; ---/+++ and rename lines are more precise.
    static func parseGitHeaderPaths(_ text: Substring) -> (String?, String?) {
        guard text.hasPrefix("a/"), let range = text.range(of: " b/") else { return (nil, nil) }
        return (String(text[text.index(text.startIndex, offsetBy: 2)..<range.lowerBound]), String(text[range.upperBound...]))
    }

    /// "@@ -12,7 +12,9 @@ heading" → (12, 7, 12, 9, "heading"). A missing count means 1.
    static func parseHunkHeader(_ line: Substring) -> (Int, Int, Int, Int)? {
        guard line.hasPrefix("@@ -") else { return nil }
        let rest = line.dropFirst(4)
        guard let end = rest.range(of: " @@") else { return nil }
        let ranges = rest[..<end.lowerBound].split(separator: " ")
        guard ranges.count == 2, ranges[1].hasPrefix("+") else { return nil }
        func pair(_ text: Substring) -> (Int, Int)? {
            let parts = text.split(separator: ",")
            guard let start = parts.first.flatMap({ Int($0) }) else { return nil }
            return (start, parts.count > 1 ? Int(parts[1]) ?? 1 : 1)
        }
        guard let old = pair(ranges[0]), let new = pair(ranges[1].dropFirst()) else { return nil }
        return (old.0, old.1, new.0, new.1)
    }

    /// Collects hunk lines, counting down the header's line counts so that a removed line
    /// starting with "-- " isn't mistaken for a file header.
    struct HunkParser {
        private var hunks: [DiffHunk] = []
        private var current: DiffHunk?
        private var oldRemaining = 0
        private var newRemaining = 0
        private var oldLine = 0
        private var newLine = 0

        mutating func start(_ line: Substring) {
            closeHunk()
            guard let (oldStart, oldCount, newStart, newCount) = DiffParser.parseHunkHeader(line) else { return }
            current = DiffHunk(header: String(line), oldStart: oldStart, oldCount: oldCount, newStart: newStart, newCount: newCount, lines: [])
            oldRemaining = oldCount
            newRemaining = newCount
            oldLine = oldStart
            newLine = newStart
        }

        /// Returns true when the line belonged to the open hunk.
        mutating func consume(_ line: Substring) -> Bool {
            guard current != nil else { return false }
            if line.hasPrefix("\\") {
                current?.lines.append(DiffLine(kind: .noNewline, text: String(line.dropFirst(2)), oldLine: nil, newLine: nil))
                return true
            }
            guard oldRemaining > 0 || newRemaining > 0 else {
                closeHunk()
                return false
            }
            let body = String(line.dropFirst())
            switch line.first {
            case "+":
                current?.lines.append(DiffLine(kind: .added, text: body, oldLine: nil, newLine: newLine))
                newLine += 1
                newRemaining -= 1
            case "-":
                current?.lines.append(DiffLine(kind: .removed, text: body, oldLine: oldLine, newLine: nil))
                oldLine += 1
                oldRemaining -= 1
            case " ", nil:
                current?.lines.append(DiffLine(kind: .context, text: body, oldLine: oldLine, newLine: newLine))
                oldLine += 1
                newLine += 1
                oldRemaining -= 1
                newRemaining -= 1
            default:
                closeHunk()
                return false
            }
            return true
        }

        mutating func finish() -> [DiffHunk] {
            closeHunk()
            return hunks
        }

        private mutating func closeHunk() {
            if let hunk = current { hunks.append(hunk) }
            current = nil
            oldRemaining = 0
            newRemaining = 0
        }
    }
}

public enum LsTreeParser {
    /// Parses `git ls-tree -z`: "<mode> SP <type> SP <sha> TAB <path>" records separated by NUL.
    public static func parse(_ output: String) -> [TreeEntry] {
        output.split(separator: "\0").compactMap { record in
            guard let tab = record.firstIndex(of: "\t") else { return nil }
            let meta = record[..<tab].split(separator: " ")
            guard meta.count == 3, let kind = TreeEntry.Kind(rawValue: String(meta[1])) else { return nil }
            return TreeEntry(kind: kind, path: String(record[record.index(after: tab)...]), sha: String(meta[2]))
        }
        .sorted { lhs, rhs in
            if lhs.isDirectory != rhs.isDirectory { return lhs.isDirectory }
            return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
        }
    }
}

public enum BlameParser {
    /// Parses `git blame --porcelain`.
    public static func parse(_ output: String) -> [BlameLine] {
        var authors: [String: String] = [:]
        var lines: [BlameLine] = []
        var currentHash = ""
        var currentLine = 0
        for raw in output.split(separator: "\n", omittingEmptySubsequences: false) {
            if raw.hasPrefix("\t") {
                lines.append(BlameLine(lineNumber: currentLine, hash: currentHash, author: authors[currentHash] ?? "", content: String(raw.dropFirst())))
                continue
            }
            let parts = raw.split(separator: " ")
            if parts.count >= 3, parts[0].count == 40, parts[0].allSatisfy(\.isHexDigit), let final = Int(parts[2]) {
                currentHash = String(parts[0])
                currentLine = final
            } else if raw.hasPrefix("author "), authors[currentHash] == nil {
                authors[currentHash] = String(raw.dropFirst("author ".count))
            }
        }
        return lines
    }
}

public enum RefParser {
    /// Parses `git for-each-ref --format=%(refname)%x1f%(objectname)%x1f%(committerdate:unix)`.
    public static func parse(_ output: String, stripping prefix: String) -> [GitRef] {
        output.split(separator: "\n").compactMap { line in
            let fields = line.split(separator: "\u{1f}", omittingEmptySubsequences: false)
            guard fields.count >= 2 else { return nil }
            var name = String(fields[0])
            if name.hasPrefix(prefix) { name.removeFirst(prefix.count) }
            guard name != "HEAD" else { return nil }
            let date = fields.count > 2 ? TimeInterval(fields[2]).map { Date(timeIntervalSince1970: $0) } : nil
            return GitRef(name: name, sha: String(fields[1]), date: date)
        }
    }
}
