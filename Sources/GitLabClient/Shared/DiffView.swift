import SwiftUI
import GitLabClientCore

/// File list beside a scrolling unified diff with line numbers and light syntax coloring.
struct DiffView: View {
    let files: [DiffFile]
    @State private var selection: DiffFile.ID?
    @State private var expanded: Set<DiffFile.ID> = []

    private let lineLimit = 2000

    var body: some View {
        if files.isEmpty {
            ContentUnavailableView("No changes", systemImage: "doc.text.magnifyingglass")
        } else {
            HSplitView {
                List(files, selection: $selection) { file in
                    HStack(spacing: 8) {
                        Image(systemName: icon(for: file.change)).foregroundStyle(color(for: file.change)).frame(width: 14)
                        VStack(alignment: .leading, spacing: 1) {
                            Text((file.path as NSString).lastPathComponent).font(.callout).lineLimit(1)
                            Text((file.path as NSString).deletingLastPathComponent).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                        Spacer(minLength: 4)
                        Text("+\(file.additions)").font(.caption.monospacedDigit()).foregroundStyle(.green)
                        Text("−\(file.deletions)").font(.caption.monospacedDigit()).foregroundStyle(.red)
                    }
                    .tag(file.id)
                }
                .frame(minWidth: 220, idealWidth: 270, maxWidth: 380)

                ScrollViewReader { proxy in
                    ScrollView([.vertical, .horizontal]) {
                        LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
                            ForEach(files) { file in
                                Section {
                                    fileBody(file)
                                } header: {
                                    fileHeader(file)
                                }
                                .id(file.id)
                            }
                        }
                        .padding(.bottom, 24)
                    }
                    .background(Color(nsColor: .textBackgroundColor))
                    .onChange(of: selection) { _, id in
                        if let id { withAnimation { proxy.scrollTo(id, anchor: .top) } }
                    }
                }
                .frame(minWidth: 420)
            }
        }
    }

    private func fileHeader(_ file: DiffFile) -> some View {
        HStack(spacing: 8) {
            Text(file.change == .renamed ? "\(file.oldPath ?? "") → \(file.newPath ?? "")" : file.path)
                .font(.system(.callout, design: .monospaced).weight(.semibold))
            if file.change != .modified { Pill(text: file.change.rawValue.capitalized, tone: file.change == .deleted ? .red : file.change == .added ? .green : .blue) }
            Spacer()
            Text("+\(file.additions) −\(file.deletions)").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .frame(minWidth: 600, maxWidth: .infinity, alignment: .leading)
        .background(.bar)
        .overlay(alignment: .bottom) { Divider() }
    }

    @ViewBuilder
    private func fileBody(_ file: DiffFile) -> some View {
        if file.isBinary {
            Text("Binary file").foregroundStyle(.secondary).padding(14)
        } else if file.hunks.isEmpty {
            Text(file.change == .renamed ? "Renamed without changes" : "No textual changes").foregroundStyle(.secondary).padding(14)
        } else {
            let total = file.hunks.reduce(0) { $0 + $1.lines.count }
            let showAll = expanded.contains(file.id) || total <= lineLimit
            let language = CodeLanguage(path: file.path)
            ForEach(Array(visibleHunks(file, limit: showAll ? Int.max : lineLimit).enumerated()), id: \.offset) { _, hunk in
                Text(hunk.header)
                    .font(.system(size: 11.5, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 3)
                    .frame(minWidth: 600, maxWidth: .infinity, alignment: .leading)
                    .background(Color.accentColor.opacity(0.08))
                ForEach(Array(hunk.lines.enumerated()), id: \.offset) { _, line in
                    DiffLineRow(line: line, language: language)
                }
            }
            if !showAll {
                Button("Show all \(total) lines") { expanded.insert(file.id) }
                    .buttonStyle(.link)
                    .padding(14)
            }
        }
    }

    /// Hunks cut off after `limit` lines in total, so a huge file doesn't stall the view.
    private func visibleHunks(_ file: DiffFile, limit: Int) -> [DiffHunk] {
        var remaining = limit
        var result: [DiffHunk] = []
        for hunk in file.hunks where remaining > 0 {
            var cut = hunk
            cut.lines = Array(hunk.lines.prefix(remaining))
            remaining -= cut.lines.count
            result.append(cut)
        }
        return result
    }

    private func icon(for change: DiffFile.Change) -> String {
        switch change {
        case .added: return "plus.square"
        case .deleted: return "minus.square"
        case .renamed: return "arrow.right.square"
        case .modified: return "pencil.line"
        }
    }

    private func color(for change: DiffFile.Change) -> Color {
        switch change {
        case .added: return .green
        case .deleted: return .red
        case .renamed: return .blue
        case .modified: return .secondary
        }
    }
}

struct DiffLineRow: View {
    let line: DiffLine
    let language: CodeLanguage

    var body: some View {
        HStack(spacing: 0) {
            number(line.oldLine)
            number(line.newLine)
            Text(marker).foregroundStyle(markerColor).frame(width: 16)
            Text(line.kind == .noNewline ? AttributedString(line.text) : SyntaxHighlighter.highlight(line.text, language: language))
                .foregroundStyle(line.kind == .noNewline ? .secondary : .primary)
                .fixedSize()
            Spacer(minLength: 0)
        }
        .font(.system(size: 12, design: .monospaced))
        .padding(.vertical, 1)
        .frame(minWidth: 600, maxWidth: .infinity, alignment: .leading)
        .background(background)
    }

    private func number(_ value: Int?) -> some View {
        Text(value.map(String.init) ?? "")
            .foregroundStyle(.tertiary)
            .frame(width: 44, alignment: .trailing)
            .padding(.trailing, 6)
    }

    private var marker: String {
        switch line.kind {
        case .added: return "+"
        case .removed: return "−"
        case .context, .noNewline: return " "
        }
    }

    private var markerColor: Color { line.kind == .added ? .green : line.kind == .removed ? .red : .secondary }

    private var background: Color {
        switch line.kind {
        case .added: return Color.green.opacity(0.13)
        case .removed: return Color.red.opacity(0.12)
        case .context, .noNewline: return .clear
        }
    }
}

enum CodeLanguage {
    case swift, kotlin, java, javascript, go, python, ruby, shell, other

    init(path: String) {
        switch (path as NSString).pathExtension.lowercased() {
        case "swift": self = .swift
        case "kt", "kts": self = .kotlin
        case "java", "gradle": self = .java
        case "js", "jsx", "ts", "tsx", "mjs": self = .javascript
        case "go": self = .go
        case "py": self = .python
        case "rb": self = .ruby
        case "sh", "bash", "zsh", "yml", "yaml": self = .shell
        default: self = .other
        }
    }

    var keywords: Set<String> {
        switch self {
        case .swift:
            return ["func", "let", "var", "if", "else", "guard", "return", "struct", "class", "enum", "protocol", "extension", "import", "self", "Self",
                    "try", "await", "async", "throws", "throw", "for", "in", "while", "switch", "case", "default", "private", "public", "internal",
                    "fileprivate", "static", "final", "init", "nil", "true", "false", "actor", "some", "any", "where", "do", "catch", "defer", "break", "continue"]
        case .kotlin:
            return ["fun", "val", "var", "if", "else", "when", "return", "class", "object", "interface", "import", "package", "this", "null", "true", "false",
                    "private", "public", "internal", "override", "suspend", "for", "in", "while", "try", "catch", "data", "sealed", "companion"]
        case .java:
            return ["public", "private", "protected", "class", "interface", "extends", "implements", "return", "if", "else", "for", "while", "new", "this",
                    "null", "true", "false", "static", "final", "void", "import", "package", "try", "catch", "throw", "throws"]
        case .javascript:
            return ["function", "const", "let", "var", "if", "else", "return", "class", "import", "export", "from", "default", "this", "null", "undefined",
                    "true", "false", "async", "await", "new", "for", "of", "in", "while", "try", "catch", "throw", "interface", "type"]
        case .go:
            return ["func", "var", "const", "if", "else", "return", "type", "struct", "interface", "package", "import", "for", "range", "nil", "true",
                    "false", "go", "defer", "switch", "case", "default", "map", "chan"]
        case .python:
            return ["def", "class", "if", "elif", "else", "return", "import", "from", "as", "self", "None", "True", "False", "for", "in", "while",
                    "try", "except", "raise", "with", "async", "await", "lambda", "pass"]
        case .ruby:
            return ["def", "class", "module", "if", "elsif", "else", "end", "return", "require", "self", "nil", "true", "false", "do", "unless", "while"]
        case .shell:
            return ["if", "then", "else", "fi", "for", "do", "done", "case", "esac", "function", "return", "export", "local", "true", "false"]
        case .other:
            return []
        }
    }

    var lineComment: String? {
        switch self {
        case .python, .ruby, .shell: return "#"
        case .other: return nil
        default: return "//"
        }
    }
}

enum SyntaxHighlighter {
    /// Colors keywords, strings, numbers and line comments. Good enough for reviewing diffs.
    static func highlight(_ text: String, language: CodeLanguage) -> AttributedString {
        var result = AttributedString(text)
        guard language != .other, !text.isEmpty, text.count < 600 else { return result }

        var commentStart: String.Index?
        if let marker = language.lineComment, let range = text.range(of: marker) {
            let before = text[..<range.lowerBound]
            if before.filter({ $0 == "\"" }).count % 2 == 0 { commentStart = range.lowerBound }
        }
        let code = commentStart.map { String(text[..<$0]) } ?? text

        for match in code.matches(of: #/"(?:[^"\\]|\\.)*"|'(?:[^'\\]|\\.)*'/#) {
            color(&result, text, match.range, .red)
        }
        for match in code.matches(of: #/\b\d+(\.\d+)?\b/#) {
            color(&result, text, match.range, .blue)
        }
        for match in code.matches(of: #/\b[A-Za-z_][A-Za-z0-9_]*\b/#) where language.keywords.contains(String(code[match.range])) {
            color(&result, text, match.range, .pink)
        }
        if let commentStart {
            color(&result, text, commentStart..<text.endIndex, .green)
        }
        return result
    }

    private static func color(_ attributed: inout AttributedString, _ text: String, _ range: Range<String.Index>, _ color: Color) {
        let start = text.distance(from: text.startIndex, to: range.lowerBound)
        let length = text.distance(from: range.lowerBound, to: range.upperBound)
        let lower = attributed.index(attributed.startIndex, offsetByCharacters: start)
        let upper = attributed.index(lower, offsetByCharacters: length)
        attributed[lower..<upper].foregroundColor = color
    }
}
