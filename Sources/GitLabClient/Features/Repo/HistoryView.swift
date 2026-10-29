import SwiftUI
import GitLabClientCore

@MainActor
@Observable
final class HistoryModel {
    private(set) var commits: [Commit] = []
    private(set) var rows: [GraphRow] = []
    private(set) var isLoading = false
    private(set) var reachedEnd = false
    private(set) var error: String?
    private var builder = GraphLaneBuilder()
    private var ref: String?

    static let pageSize = 200

    var maxLanes: Int { min(rows.map(\.laneCount).max() ?? 1, 12) }

    func load(git: GitService, repo: URL, ref: String) async {
        if self.ref != ref {
            self.ref = ref
            commits = []
            rows = []
            builder = GraphLaneBuilder()
            reachedEnd = false
        }
        await loadMore(git: git, repo: repo)
    }

    func loadMore(git: GitService, repo: URL) async {
        guard !isLoading, !reachedEnd, let ref else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            let page = try await git.log(repo: repo, ref: ref, skip: commits.count, limit: Self.pageSize)
            commits += page
            rows += builder.rows(for: page)
            reachedEnd = page.count < Self.pageSize
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }
}

/// Paginated history with a lane graph, and the selected commit's diff.
struct HistoryView: View {
    let repo: RepoModel
    @State private var history = HistoryModel()
    @State private var ref: RefOption?
    @State private var selection: Commit.ID?

    var body: some View {
        let current = ref ?? repo.defaultBranch
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                RefPicker(options: repo.refOptions, selection: Binding(get: { current }, set: { ref = $0; selection = nil }))
                Text("\(history.commits.count)\(history.reachedEnd ? "" : "+") commits").font(.caption).foregroundStyle(.secondary)
                Spacer()
                CloneStatus(repo: repo)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            Divider()
            if let url = repo.repoURL, let git = repo.git {
                HSplitView {
                    commitList(git: git, url: url)
                        .frame(minWidth: 380, idealWidth: 520)
                    Group {
                        if let selection, let commit = history.commits.first(where: { $0.id == selection }) {
                            CommitDetail(git: git, repo: url, commit: commit).id(commit.id)
                        } else {
                            ContentUnavailableView("Pick a commit", systemImage: "clock.arrow.circlepath")
                        }
                    }
                    .frame(minWidth: 420, maxWidth: .infinity, maxHeight: .infinity)
                }
                .task(id: current) { await history.load(git: git, repo: url, ref: current.localRef) }
            } else if case .failed(let message) = repo.clone {
                ContentUnavailableView("History needs the local clone", systemImage: "externaldrive.badge.xmark", description: Text(message))
            } else {
                ProgressView("Cloning over SSH…").frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    private func commitList(git: GitService, url: URL) -> some View {
        List(selection: $selection) {
            ForEach(Array(history.commits.enumerated()), id: \.element.id) { index, commit in
                HStack(spacing: 8) {
                    if index < history.rows.count {
                        GraphCell(row: history.rows[index])
                            .frame(width: CGFloat(history.maxLanes) * 14 + 12, height: 40)
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        Text(commit.subject).lineLimit(1)
                        HStack(spacing: 6) {
                            Text(commit.authorName)
                            Text("·")
                            Text(commit.date, format: .relative(presentation: .named))
                            Text("·")
                            Text(commit.shortHash).monospaced()
                        }
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    }
                    Spacer(minLength: 0)
                }
                .listRowInsets(EdgeInsets(top: 0, leading: 4, bottom: 0, trailing: 8))
                .tag(commit.id)
                .onAppear {
                    if index == history.commits.count - 1 { Task { await history.loadMore(git: git, repo: url) } }
                }
            }
            if history.isLoading { ProgressView().frame(maxWidth: .infinity) }
            if let error = history.error { ErrorText(message: error) }
        }
        .listStyle(.plain)
        .environment(\.defaultMinListRowHeight, 40)
    }
}

/// Draws one row of the lane graph: lines in from the top, the dot, lines out to the bottom.
struct GraphCell: View {
    let row: GraphRow

    nonisolated static let palette: [Color] = [.blue, .orange, .purple, .green, .pink, .teal, .red, .indigo]

    var body: some View {
        Canvas { context, size in
            let mid = size.height / 2
            func x(_ lane: Int) -> CGFloat { 9 + CGFloat(min(lane, 11)) * 14 }
            func color(_ index: Int) -> Color { Self.palette[index % Self.palette.count] }

            for edge in row.top {
                var path = Path()
                path.move(to: CGPoint(x: x(edge.from), y: 0))
                if edge.from == edge.to {
                    path.addLine(to: CGPoint(x: x(edge.to), y: mid))
                } else {
                    path.addQuadCurve(to: CGPoint(x: x(edge.to), y: mid), control: CGPoint(x: x(edge.from), y: mid))
                }
                context.stroke(path, with: .color(color(edge.color)), lineWidth: 2)
            }
            for edge in row.bottom {
                var path = Path()
                path.move(to: CGPoint(x: x(edge.from), y: mid))
                if edge.from == edge.to {
                    path.addLine(to: CGPoint(x: x(edge.to), y: size.height))
                } else {
                    path.addQuadCurve(to: CGPoint(x: x(edge.to), y: size.height), control: CGPoint(x: x(edge.to), y: mid))
                }
                context.stroke(path, with: .color(color(edge.color)), lineWidth: 2)
            }
            let dot = CGRect(x: x(row.lane) - 4.5, y: mid - 4.5, width: 9, height: 9)
            context.fill(Path(ellipseIn: dot), with: .color(color(row.color)))
            context.stroke(Path(ellipseIn: dot), with: .color(Color(nsColor: .textBackgroundColor)), lineWidth: 1.5)
        }
        .accessibilityHidden(true)
    }
}

struct CommitDetail: View {
    let git: GitService
    let repo: URL
    let commit: Commit
    @State private var message: String?
    @State private var files: [DiffFile] = []
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 6) {
                Text(commit.subject).font(.headline).textSelection(.enabled)
                if let message, message != commit.subject {
                    let body = message.dropFirst(commit.subject.count).trimmingCharacters(in: .whitespacesAndNewlines)
                    if !body.isEmpty { Text(body).font(.callout).foregroundStyle(.secondary).textSelection(.enabled).lineLimit(8) }
                }
                HStack(spacing: 6) {
                    Text(commit.authorName).fontWeight(.medium)
                    Text("<\(commit.authorEmail)>").foregroundStyle(.secondary)
                    Text("· \(commit.date.formatted(date: .abbreviated, time: .shortened))").foregroundStyle(.secondary)
                    Spacer()
                    Text(commit.shortHash).monospaced()
                    Button { Clipboard.copy(commit.hash) } label: { Image(systemName: "doc.on.doc") }
                        .buttonStyle(.borderless)
                        .help("Copy full hash")
                }
                .font(.caption)
                if commit.parents.count > 1 {
                    Text("Merge of \(commit.parents.map { String($0.prefix(8)) }.joined(separator: " and "))").font(.caption).foregroundStyle(.secondary)
                }
            }
            .padding(14)
            Divider()
            if let error {
                ErrorText(message: error).padding()
            } else if message == nil {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                DiffView(files: files)
            }
        }
        .task {
            do {
                let shown = try await git.showCommit(repo: repo, hash: commit.hash)
                message = shown.message
                files = shown.files
            } catch {
                self.error = error.localizedDescription
            }
        }
    }
}
