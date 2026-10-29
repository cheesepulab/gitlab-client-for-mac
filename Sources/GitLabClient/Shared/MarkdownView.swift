import SwiftUI
import GitLabClientCore

/// Renders the Markdown GitLab descriptions and READMEs mostly use: headings, paragraphs,
/// lists, task lists, quotes and fenced code. Inline styles and links use AttributedString;
/// bare URLs become links, and with a resolver so do `!12`, `#34` and `@name`.
struct MarkdownView: View {
    let text: String
    var links: LinkResolver? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(Array(MarkdownBlock.parse(text).enumerated()), id: \.offset) { _, block in
                view(for: block)
            }
        }
        .textSelection(.enabled)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func view(for block: MarkdownBlock) -> some View {
        switch block {
        case .heading(let level, let text):
            Text(inline(text)).font(level == 1 ? .title2.bold() : level == 2 ? .title3.bold() : .headline)
                .padding(.top, level <= 2 ? 6 : 2)
        case .paragraph(let text):
            Text(inline(text)).fixedSize(horizontal: false, vertical: true)
        case .bullet(let items):
            VStack(alignment: .leading, spacing: 4) {
                ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text("•").foregroundStyle(.secondary)
                        Text(inline(item)).fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        case .ordered(let items):
            VStack(alignment: .leading, spacing: 4) {
                ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text("\(index + 1).").foregroundStyle(.secondary).monospacedDigit()
                        Text(inline(item)).fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        case .tasks(let items):
            VStack(alignment: .leading, spacing: 4) {
                ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                    Label {
                        Text(inline(item.text))
                    } icon: {
                        Image(systemName: item.done ? "checkmark.square" : "square").foregroundStyle(item.done ? .green : .secondary)
                    }
                }
            }
        case .quote(let text):
            Text(inline(text)).foregroundStyle(.secondary)
                .padding(.leading, 10)
                .overlay(alignment: .leading) { Rectangle().fill(.quaternary).frame(width: 3) }
        case .code(let code):
            ScrollView(.horizontal) {
                Text(code).font(.system(.callout, design: .monospaced)).padding(10)
            }
            .background(Color(nsColor: .textBackgroundColor).opacity(0.6), in: RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color(nsColor: .separatorColor)))
        case .rule:
            Divider()
        }
    }

    private func inline(_ text: String) -> AttributedString {
        RichText.inline(text, resolver: links)
    }
}

enum MarkdownBlock: Equatable {
    struct Task: Equatable { var done: Bool; var text: String }

    case heading(Int, String)
    case paragraph(String)
    case bullet([String])
    case ordered([String])
    case tasks([Task])
    case quote(String)
    case code(String)
    case rule

    static func parse(_ text: String) -> [MarkdownBlock] {
        var blocks: [MarkdownBlock] = []
        var paragraph: [String] = []
        var code: [String]?

        func flush() {
            if !paragraph.isEmpty { blocks.append(.paragraph(paragraph.joined(separator: " "))) }
            paragraph = []
        }

        func append(list line: String) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if let task = trimmed.firstMatch(of: #/^[-*] \[([ xX])\] (.*)$/#) {
                let item = Task(done: task.1 != " ", text: String(task.2))
                if case .tasks(var items) = blocks.last { items.append(item); blocks[blocks.count - 1] = .tasks(items) } else { blocks.append(.tasks([item])) }
            } else if let bullet = trimmed.firstMatch(of: #/^[-*+] (.*)$/#) {
                if case .bullet(var items) = blocks.last { items.append(String(bullet.1)); blocks[blocks.count - 1] = .bullet(items) } else { blocks.append(.bullet([String(bullet.1)])) }
            } else if let number = trimmed.firstMatch(of: #/^\d+[.)] (.*)$/#) {
                if case .ordered(var items) = blocks.last { items.append(String(number.1)); blocks[blocks.count - 1] = .ordered(items) } else { blocks.append(.ordered([String(number.1)])) }
            }
        }

        for line in text.replacingOccurrences(of: "\r\n", with: "\n").split(separator: "\n", omittingEmptySubsequences: false).map(String.init) {
            if line.hasPrefix("```") || line.hasPrefix("~~~") {
                if let lines = code {
                    blocks.append(.code(lines.joined(separator: "\n")))
                    code = nil
                } else {
                    flush()
                    code = []
                }
                continue
            }
            if code != nil { code?.append(line); continue }

            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { flush(); continue }
            if let heading = trimmed.firstMatch(of: #/^(#{1,6}) (.*)$/#) {
                flush()
                blocks.append(.heading(heading.1.count, String(heading.2)))
            } else if trimmed == "---" || trimmed == "***" {
                flush()
                blocks.append(.rule)
            } else if trimmed.hasPrefix(">") {
                flush()
                blocks.append(.quote(String(trimmed.dropFirst()).trimmingCharacters(in: .whitespaces)))
            } else if trimmed.firstMatch(of: #/^([-*+] |\d+[.)] )/#) != nil {
                flush()
                append(list: trimmed)
            } else {
                paragraph.append(trimmed)
            }
        }
        if let lines = code { blocks.append(.code(lines.joined(separator: "\n"))) }
        flush()
        return blocks
    }
}
