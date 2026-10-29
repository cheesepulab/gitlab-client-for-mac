import SwiftUI
import GitLabClientCore

struct RefOption: Hashable, Identifiable {
    enum Kind: Hashable { case branch, tag }
    var name: String
    var kind: Kind

    var id: String { "\(kind)-\(name)" }
    /// Ref in the local bare clone, where branches live under refs/remotes/origin.
    var localRef: String { kind == .branch ? "refs/remotes/origin/\(name)" : "refs/tags/\(name)" }
}

/// One project's local mirror: clones once over SSH, then reads from it. Until the clone is
/// ready, file browsing falls back to the REST API.
@MainActor
@Observable
final class RepoModel {
    enum CloneState: Equatable {
        case idle
        case cloning(String)
        case ready(URL)
        case failed(String)
    }

    let domain: GitLabDomain
    let project: Project
    let api: GitLabAPIClient
    private(set) var git: GitService?
    private(set) var clone: CloneState = .idle
    private(set) var branches: [GitRef] = []
    private(set) var tags: [GitRef] = []
    private(set) var apiBranches: [String] = []

    init(domain: GitLabDomain, project: Project, api: GitLabAPIClient) {
        self.domain = domain
        self.project = project
        self.api = api
    }

    var repoURL: URL? { if case .ready(let url) = clone { return url } else { return nil } }
    var isLocal: Bool { repoURL != nil }
    var defaultBranch: RefOption { RefOption(name: project.defaultBranch ?? branches.first?.name ?? apiBranches.first ?? "main", kind: .branch) }

    var refOptions: [RefOption] {
        let names = branches.isEmpty ? apiBranches : branches.map(\.name)
        return names.map { RefOption(name: $0, kind: .branch) } + tags.map { RefOption(name: $0.name, kind: .tag) }
    }

    func prepare(model: AppModel, fetch: Bool = true) async {
        if case .cloning = clone { return }
        guard project.emptyRepo != true else { clone = .failed("This repository is empty."); return }
        guard let git = await model.git() else {
            clone = .failed(model.gitProblem ?? GitError.gitNotFound.localizedDescription)
            await loadAPIBranches()
            return
        }
        self.git = git
        let firstClone = await !git.isCloned(domain: domain, projectID: project.id)
        clone = .cloning(firstClone ? "Cloning over SSH…" : "Fetching…")
        if firstClone { await loadAPIBranches() }
        do {
            let url = try await git.prepare(domain: domain, project: project, fetch: fetch) { [weak self] line in
                Task { @MainActor in
                    guard let self, case .cloning = self.clone else { return }
                    self.clone = .cloning(line.trimmingCharacters(in: .whitespaces))
                }
            }
            branches = (try? await git.branches(repo: url)) ?? []
            tags = (try? await git.tags(repo: url)) ?? []
            clone = .ready(url)
        } catch {
            clone = .failed(error.localizedDescription)
            if apiBranches.isEmpty { await loadAPIBranches() }
        }
    }

    private func loadAPIBranches() async {
        apiBranches = ((try? await api.branches(projectID: project.id)) ?? []).map(\.name)
    }

    func entries(ref: RefOption, path: String) async throws -> [TreeEntry] {
        if let git, let url = repoURL {
            return try await git.tree(repo: url, ref: ref.localRef, path: path)
        }
        return try await api.tree(projectID: project.id, ref: ref.name, path: path)
            .map { TreeEntry(kind: $0.type == "tree" ? .tree : .blob, path: $0.path, sha: $0.id) }
            .sorted { lhs, rhs in
                lhs.isDirectory != rhs.isDirectory ? lhs.isDirectory : lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
            }
    }

    func fileData(ref: RefOption, path: String) async throws -> Data {
        if let git, let url = repoURL {
            return try await git.file(repo: url, ref: ref.localRef, path: path)
        }
        return try await api.rawFile(projectID: project.id, path: path, ref: ref.name)
    }
}

struct RepoView: View {
    enum Tab: String, CaseIterable, Identifiable {
        case code = "Code", history = "History", mergeRequests = "Merge requests"
        var id: String { rawValue }
    }

    let domain: GitLabDomain
    let project: Project
    @Environment(AppModel.self) private var model
    @State private var repo: RepoModel
    @State private var tab: Tab = .mergeRequests

    init(domain: GitLabDomain, project: Project) {
        self.domain = domain
        self.project = project
        _repo = State(initialValue: RepoModel(domain: domain, project: project, api: AppModel.shared.api(for: domain)))
        #if DEBUG
        if let tab = DebugSnapshot.value("GLC_DEBUG_TAB").flatMap(Tab.init(rawValue:)) { _tab = State(initialValue: tab) }
        #endif
    }

    var body: some View {
        VStack(spacing: 0) {
            if case .failed(let message) = repo.clone {
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle").foregroundStyle(.orange)
                    Text("Local clone unavailable: \(message) Browsing uses the API; history and AI resolve need SSH.")
                        .font(.caption).lineLimit(2)
                    Spacer()
                    Button("Try again") { Task { await repo.prepare(model: model) } }.controlSize(.small)
                }
                .padding(.horizontal, 16).padding(.vertical, 7)
                .background(Color.orange.opacity(0.1))
                Divider()
            }
            switch tab {
            case .code: CodeView(repo: repo)
            case .history: HistoryView(repo: repo)
            case .mergeRequests: MRListView(repo: repo)
            }
        }
        .navigationTitle(project.name)
        .navigationSubtitle("\(project.groupPath) · \(domain.key)")
        .toolbar {
            ToolbarItem(placement: .principal) {
                Picker("View", selection: $tab) {
                    ForEach(Tab.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }
            ToolbarItem {
                Button {
                    Task { await repo.prepare(model: model) }
                } label: {
                    if case .cloning = repo.clone { ProgressView().controlSize(.small) } else { Label("Fetch", systemImage: "arrow.triangle.2.circlepath") }
                }
                .help("Fetch from \(domain.sshHost)")
            }
        }
        .task { await repo.prepare(model: model) }
    }
}

/// Clone progress line, shown while the first clone runs.
struct CloneStatus: View {
    let repo: RepoModel

    var body: some View {
        if case .cloning(let line) = repo.clone {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text(line).font(.caption.monospaced()).foregroundStyle(.secondary).lineLimit(1)
            }
        }
    }
}
