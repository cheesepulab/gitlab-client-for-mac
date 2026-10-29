import SwiftUI
import GitLabClientCore

/// Comments and history from GitLab's discussions, oldest first, with a comment box.
struct ActivityView: View {
    enum Filter: String, CaseIterable, Identifiable {
        case all = "All", comments = "Comments", history = "History"
        var id: String { rawValue }
    }

    let repo: RepoModel
    let detail: MRDetailModel
    @Environment(AppModel.self) private var model
    @AppStorage("activityFilter") private var filter: Filter = .all
    @State private var draft = ""

    private var canWrite: Bool { model.accounts[repo.domain.key]?.canWrite ?? true }
    private var links: LinkResolver { LinkResolver(baseURL: repo.domain.baseURL, projectPath: repo.project.pathWithNamespace) }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Activity").font(.title3.bold())
                Spacer()
                Picker("Show", selection: $filter) {
                    ForEach(Filter.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
            }
            if let discussions = detail.discussions {
                let shown = discussions.filter(matches)
                if shown.isEmpty {
                    Text(filter == .comments ? "No comments yet." : "Nothing here yet.").foregroundStyle(.secondary)
                }
                ForEach(shown) { discussion in
                    if discussion.isSystem {
                        HistoryRow(note: discussion.notes[0], links: links)
                    } else {
                        ThreadCard(repo: repo, detail: detail, discussion: discussion, links: links, canWrite: canWrite)
                    }
                }
            } else if let error = detail.activityError {
                ErrorText(message: error)
            } else {
                ProgressView().frame(maxWidth: .infinity)
            }
            if canWrite { composer }
        }
    }

    private func matches(_ discussion: Discussion) -> Bool {
        switch filter {
        case .all: return true
        case .comments: return !discussion.isSystem
        case .history: return discussion.isSystem
        }
    }

    private var composer: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Add a comment").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            CommentEditor(text: $draft, placeholder: "Write a comment. Paste a link or type !\(detail.mr.iid), #12 or @name.")
            HStack {
                Text("Markdown. Links and references become clickable.").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button {
                    Task { if await detail.comment(draft, api: repo.api) { draft = "" } }
                } label: {
                    if detail.working == .comment { ProgressView().controlSize(.small) } else { Text("Comment") }
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || detail.working != nil)
            }
        }
    }
}

/// Multi-line text box with a placeholder.
struct CommentEditor: View {
    @Binding var text: String
    let placeholder: String
    var minHeight: CGFloat = 64

    var body: some View {
        ZStack(alignment: .topLeading) {
            TextEditor(text: $text)
                .font(.body)
                .scrollContentBackground(.hidden)
                .padding(6)
                .frame(minHeight: minHeight)
            if text.isEmpty {
                Text(placeholder).foregroundStyle(.tertiary).padding(.horizontal, 11).padding(.vertical, 6).allowsHitTesting(false)
            }
        }
        .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color(nsColor: .separatorColor)))
    }
}

/// A system event: "Minh Tran approved this merge request · 40 minutes ago".
struct HistoryRow: View {
    let note: Note
    let links: LinkResolver

    var body: some View {
        let parsed = SystemNote.parse(note.body)
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon(for: parsed.text))
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(color(for: parsed.text))
                .frame(width: 26, height: 26)
                .background(Color.secondary.opacity(0.1), in: Circle())
            VStack(alignment: .leading, spacing: 6) {
                (Text(note.author.name).fontWeight(.semibold).foregroundColor(.primary)
                    + Text(" ") + Text(RichText.inline(parsed.text, resolver: links))
                    + Text(" · \(relative(note.createdDate))"))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if !parsed.items.isEmpty {
                    VStack(alignment: .leading, spacing: 3) {
                        ForEach(Array(parsed.items.enumerated()), id: \.offset) { _, item in commitLine(item) }
                    }
                    .padding(.horizontal, 10).padding(.vertical, 8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.secondary.opacity(0.05), in: RoundedRectangle(cornerRadius: 8))
                }
            }
            .padding(.top, 3)
        }
        .padding(.horizontal, 4)
        .textSelection(.enabled)
    }

    /// "3f2a91c - Title" → monospaced SHA, then the title.
    private func commitLine(_ item: String) -> some View {
        let parts = item.split(separator: " - ", maxSplits: 1).map(String.init)
        return HStack(alignment: .firstTextBaseline, spacing: 10) {
            if parts.count == 2 {
                Text(parts[0]).font(.caption.monospaced()).foregroundStyle(Color.accentColor)
                Text(parts[1]).font(.caption)
            } else {
                Text(item).font(.caption)
            }
        }
    }

    private func icon(for text: String) -> String {
        let lower = text.lowercased()
        if lower.hasPrefix("approved") { return "checkmark" }
        if lower.hasPrefix("unapproved") || lower.contains("revoked") { return "arrow.uturn.backward" }
        if lower.contains("commit") { return "smallcircle.filled.circle" }
        if lower.contains("merge") && (lower.contains("auto") || lower.contains("automatic") || lower.contains("pipeline succeeds")) { return "arrow.triangle.merge" }
        if lower.hasPrefix("merged") { return "arrow.triangle.merge" }
        if lower.contains("review") || lower.contains("assigned") { return "person" }
        if lower.hasPrefix("closed") { return "xmark" }
        if lower.hasPrefix("reopened") { return "arrow.clockwise" }
        if lower.contains("draft") || lower.contains("ready") || lower.contains("changed") { return "pencil" }
        if lower.contains("resolved") { return "checkmark.bubble" }
        return "circle.fill"
    }

    private func color(for text: String) -> Color {
        let lower = text.lowercased()
        if lower.hasPrefix("approved") { return .green }
        if lower.hasPrefix("merged") { return .purple }
        if lower.contains("auto") && lower.contains("merge") { return .accentColor }
        return .secondary
    }
}

/// A comment and its replies, with Reply and Resolve.
struct ThreadCard: View {
    let repo: RepoModel
    let detail: MRDetailModel
    let discussion: Discussion
    let links: LinkResolver
    let canWrite: Bool
    @State private var replying = false
    @State private var reply = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(discussion.notes.enumerated()), id: \.element.id) { index, note in
                if index > 0 { Divider() }
                NoteRow(note: note, links: links)
                    .padding(.horizontal, 14).padding(.vertical, 12)
                    .background(index > 0 ? Color.secondary.opacity(0.04) : .clear)
            }
            if replying {
                Divider()
                VStack(alignment: .trailing, spacing: 8) {
                    CommentEditor(text: $reply, placeholder: "Reply", minHeight: 48)
                    HStack {
                        Button("Cancel") { replying = false; reply = "" }
                        Button {
                            Task { if await detail.reply(reply, to: discussion, api: repo.api) { reply = ""; replying = false } }
                        } label: {
                            if detail.working == .reply(discussion.id) { ProgressView().controlSize(.small) } else { Text("Reply") }
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(reply.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || detail.working != nil)
                    }
                }
                .padding(12)
            }
            if discussion.isResolvable || canWrite {
                Divider()
                HStack(spacing: 10) {
                    if discussion.isResolved {
                        Label("Resolved by \(discussion.resolvedBy?.name ?? "someone")", systemImage: "checkmark.circle")
                            .font(.caption).foregroundStyle(.green)
                    }
                    Spacer()
                    if canWrite {
                        if !replying { Button("Reply") { replying = true }.controlSize(.small) }
                        if discussion.isResolvable {
                            Button(discussion.isResolved ? "Unresolve thread" : "Resolve thread") {
                                Task { await detail.setResolved(!discussion.isResolved, discussion, api: repo.api) }
                            }
                            .controlSize(.small)
                            .disabled(detail.working != nil)
                        }
                    }
                }
                .padding(.horizontal, 14).padding(.vertical, 8)
                .background(Color.secondary.opacity(0.04))
            }
        }
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color(nsColor: .separatorColor)))
    }
}

struct NoteRow: View {
    let note: Note
    let links: LinkResolver

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            InitialsAvatar(initials: note.author.initials, size: 26, tint: note.author.tint)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 4) {
                    Text(note.author.name).fontWeight(.semibold)
                    Text("· \(relative(note.createdDate))").foregroundStyle(.secondary)
                    if let location = note.location {
                        Text("on").foregroundStyle(.secondary)
                        Text(location).font(.caption.monospaced()).foregroundStyle(.secondary).lineLimit(1).truncationMode(.head)
                    }
                }
                .font(.caption)
                MarkdownView(text: note.body, links: links)
            }
        }
    }
}
