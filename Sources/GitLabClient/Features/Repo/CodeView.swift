import SwiftUI
import GitLabClientCore

/// File tree, file viewer with blame, and the README, at any branch or tag.
struct CodeView: View {
    let repo: RepoModel
    @State private var ref: RefOption?
    @State private var selection: TreeEntry?

    var body: some View {
        let current = ref ?? repo.defaultBranch
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                RefPicker(options: repo.refOptions, selection: Binding(get: { current }, set: { ref = $0; selection = nil }))
                if let selection { Text(selection.path).font(.callout.monospaced()).foregroundStyle(.secondary).lineLimit(1).truncationMode(.head) }
                Spacer()
                CloneStatus(repo: repo)
                if !repo.isLocal { Pill(text: "via API", tone: .orange) }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            Divider()
            HSplitView {
                FileTree(repo: repo, ref: current, selection: $selection)
                    .frame(minWidth: 220, idealWidth: 280, maxWidth: 420)
                Group {
                    if let selection, !selection.isDirectory {
                        FileViewer(repo: repo, ref: current, entry: selection).id("\(current.id)/\(selection.path)")
                    } else {
                        ReadmeView(repo: repo, ref: current, folder: selection?.path ?? "").id("\(current.id)/\(selection?.path ?? "")")
                    }
                }
                .frame(minWidth: 400, maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }
}

struct RefPicker: View {
    let options: [RefOption]
    @Binding var selection: RefOption

    var body: some View {
        Menu {
            Section("Branches") {
                ForEach(options.filter { $0.kind == .branch }) { option in
                    Button(option.name) { selection = option }
                }
            }
            let tags = options.filter { $0.kind == .tag }
            if !tags.isEmpty {
                Section("Tags") {
                    ForEach(tags.prefix(50)) { option in
                        Button(option.name) { selection = option }
                    }
                }
            }
        } label: {
            Label(selection.name, systemImage: selection.kind == .branch ? "arrow.triangle.branch" : "tag")
        }
        .fixedSize()
    }
}

private struct FileTree: View {
    let repo: RepoModel
    let ref: RefOption
    @Binding var selection: TreeEntry?
    @State private var root: [TreeEntry]?
    @State private var error: String?

    var body: some View {
        List(selection: $selection) {
            if let root {
                ForEach(root) { TreeNode(repo: repo, ref: ref, entry: $0) }
            }
        }
        .listStyle(.sidebar)
        .overlay {
            if let error { ErrorText(message: error).padding() } else if root == nil { ProgressView() }
        }
        .task(id: "\(ref.id)-\(repo.isLocal)") {
            do {
                root = try await repo.entries(ref: ref, path: "")
                error = nil
            } catch {
                self.error = error.localizedDescription
            }
        }
    }
}

private struct TreeNode: View {
    let repo: RepoModel
    let ref: RefOption
    let entry: TreeEntry
    @State private var expanded = false
    @State private var children: [TreeEntry]?

    var body: some View {
        if entry.isDirectory {
            DisclosureGroup(isExpanded: $expanded) {
                if let children {
                    ForEach(children) { TreeNode(repo: repo, ref: ref, entry: $0) }
                } else {
                    ProgressView().controlSize(.small)
                }
            } label: {
                Label(entry.name, systemImage: "folder").tag(entry)
            }
            .onChange(of: expanded) { _, isOpen in
                if isOpen && children == nil {
                    Task { children = (try? await repo.entries(ref: ref, path: entry.path)) ?? [] }
                }
            }
        } else {
            Label(entry.name, systemImage: entry.kind == .commit ? "shippingbox" : "doc.text").tag(entry)
        }
    }
}

struct FileViewer: View {
    let repo: RepoModel
    let ref: RefOption
    let entry: TreeEntry
    @State private var lines: [String]?
    @State private var isBinary = false
    @State private var error: String?
    @State private var showBlame = false
    @State private var blame: [BlameLine]?
    @State private var renderMarkdown = true

    private var isMarkdown: Bool { ["md", "markdown"].contains((entry.path as NSString).pathExtension.lowercased()) }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "doc.text").foregroundStyle(.secondary)
                Text(entry.name).font(.callout.weight(.semibold))
                if let lines { Text("\(lines.count) lines").font(.caption).foregroundStyle(.secondary) }
                Spacer()
                if isMarkdown {
                    Picker("Show", selection: $renderMarkdown) {
                        Text("Preview").tag(true)
                        Text("Source").tag(false)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .fixedSize()
                }
                Toggle("Blame", isOn: $showBlame)
                    .toggleStyle(.button)
                    .disabled(!repo.isLocal || (isMarkdown && renderMarkdown))
                    .help(repo.isLocal ? "Show who last changed each line" : "Blame needs the local clone")
                Button { Clipboard.copy(entry.path) } label: { Image(systemName: "doc.on.doc") }
                    .buttonStyle(.borderless)
                    .help("Copy path")
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            Divider()
            content
        }
        .task(id: repo.isLocal) {
            do {
                let data = try await repo.fileData(ref: ref, path: entry.path)
                if data.prefix(8000).contains(0) {
                    isBinary = true
                } else {
                    lines = String(decoding: data, as: UTF8.self).split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
                    if lines?.last == "" { lines?.removeLast() }
                }
            } catch {
                self.error = error.localizedDescription
            }
        }
        .task(id: showBlame) {
            guard showBlame, blame == nil, let git = repo.git, let url = repo.repoURL else { return }
            blame = try? await git.blame(repo: url, ref: ref.localRef, path: entry.path)
        }
    }

    @ViewBuilder private var content: some View {
        if let error {
            ErrorText(message: error).padding().frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        } else if isBinary {
            ContentUnavailableView("Binary file", systemImage: "doc.zipper")
        } else if let lines {
            if isMarkdown && renderMarkdown {
                ScrollView { MarkdownView(text: lines.joined(separator: "\n")).padding(24) }
            } else {
                CodeLines(lines: lines, path: entry.path, blame: showBlame ? blame : nil)
            }
        } else {
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

struct CodeLines: View {
    let lines: [String]
    let path: String
    let blame: [BlameLine]?

    var body: some View {
        let language = CodeLanguage(path: path)
        let byLine = Dictionary((blame ?? []).map { ($0.lineNumber, $0) }, uniquingKeysWith: { first, _ in first })
        ScrollView([.vertical, .horizontal]) {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(Array(lines.prefix(20000).enumerated()), id: \.offset) { index, line in
                    HStack(spacing: 0) {
                        if blame != nil {
                            let info = byLine[index + 1]
                            let startsBlock = info?.hash != byLine[index]?.hash
                            HStack(spacing: 6) {
                                Text(startsBlock ? String(info?.hash.prefix(7) ?? "") : "").foregroundStyle(.secondary)
                                Text(startsBlock ? (info?.author ?? "") : "").lineLimit(1)
                            }
                            .font(.system(size: 11, design: .monospaced))
                            .frame(width: 190, alignment: .leading)
                            .padding(.horizontal, 8)
                            .background(Color.secondary.opacity(0.06))
                        }
                        Text("\(index + 1)")
                            .foregroundStyle(.tertiary)
                            .frame(width: 48, alignment: .trailing)
                            .padding(.trailing, 12)
                        Text(SyntaxHighlighter.highlight(line, language: language)).fixedSize()
                    }
                    .font(.system(size: 12, design: .monospaced))
                    .padding(.vertical, 1)
                }
            }
            .padding(.vertical, 8)
            .textSelection(.enabled)
        }
        .background(Color(nsColor: .textBackgroundColor))
    }
}

/// README of the selected folder, or of the repository root.
struct ReadmeView: View {
    let repo: RepoModel
    let ref: RefOption
    let folder: String
    @State private var text: String?
    @State private var loaded = false

    var body: some View {
        // A ZStack, not a Group: .task on a Group attaches to whichever child is showing, so
        // swapping the spinner for the text would cancel and restart the load forever.
        ZStack {
            if let text {
                ScrollView { MarkdownView(text: text).padding(28).frame(maxWidth: 860, alignment: .leading) }
            } else if loaded {
                ContentUnavailableView("No README", systemImage: "doc.richtext", description: Text("Pick a file in the tree."))
            } else {
                ProgressView()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // Look again once the local clone is ready; the API fallback may have failed before.
        .task(id: repo.isLocal) {
            text = nil
            loaded = false
            defer { loaded = true }
            guard let entries = try? await repo.entries(ref: ref, path: folder),
                  let readme = entries.first(where: { !$0.isDirectory && $0.name.lowercased().hasPrefix("readme") }),
                  let data = try? await repo.fileData(ref: ref, path: readme.path) else { return }
            text = String(decoding: data, as: UTF8.self)
        }
    }
}
