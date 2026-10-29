import SwiftUI
import GitLabClientCore

/// A user-facing failure message from a merge request action.
struct ActionMessage: Error, LocalizedError {
    let text: String
    var errorDescription: String? { text }
}

@MainActor
@Observable
final class MRDetailModel {
    enum Work: Equatable {
        case merge, autoMerge, cancelAutoMerge, approve, unapprove, comment, assignees, reviewers
        case reply(String), resolve(String)
    }

    var mr: MergeRequest
    let project: Project
    private(set) var approvals: Approvals?
    private(set) var commits: [MergeRequestCommit]?
    private(set) var diff: [DiffFile]?
    private(set) var diffSource = ""
    private(set) var discussions: [Discussion]?
    private(set) var limits: PeopleLimits = .single
    private(set) var version: ServerVersion?
    private(set) var error: String?
    private(set) var activityError: String?
    private(set) var isRebasing = false
    private(set) var working: Work?
    var actionError: String?
    var squash = false
    var deleteSourceBranch = true
    private var choseOptions = false
    private var loadedExtras = false

    init(mr: MergeRequest, project: Project) {
        self.mr = mr
        self.project = project
    }

    var squashPolicy: SquashPolicy { SquashPolicy(projectOption: project.squashOption) }
    var isAutoMergeSet: Bool { mr.state == "opened" && mr.mergeWhenPipelineSucceeds == true }
    var headPipeline: PipelineRef? { mr.headPipeline ?? mr.pipeline }
    var pipelineIsActive: Bool { headPipeline.map { CIStatus($0.status).isActive } ?? false }

    /// The merge box's checkboxes start from the project (or Settings → Git) once per visit.
    func chooseMergeOptions(settings: AppSettings) {
        guard !choseOptions else { return }
        choseOptions = true
        squash = squashPolicy.forcedValue ?? settings.squashDefault.resolve(projectDefault: project.squashByDefault || mr.squash == true)
        deleteSourceBranch = settings.deleteSourceDefault.resolve(projectDefault: mr.forceRemoveSourceBranch ?? project.removeSourceBranchAfterMerge ?? true)
    }

    func refresh(api: GitLabAPIClient) async {
        do {
            mr = try await api.mergeRequest(projectID: mr.projectId, iid: mr.iid, includeRebaseInProgress: true)
            approvals = try? await api.approvals(projectID: mr.projectId, iid: mr.iid)
            error = nil
        } catch is CancellationError {
            return
        } catch {
            self.error = error.localizedDescription
        }
        guard !loadedExtras else { return }
        loadedExtras = true
        var limits = await api.peopleLimits(projectPath: project.pathWithNamespace, iid: mr.iid)
        // A server that already shows several people allows several, whatever GraphQL said.
        if (mr.assignees?.count ?? 0) > 1 { limits.multipleAssignees = true }
        if (mr.reviewers?.count ?? 0) > 1 { limits.multipleReviewers = true }
        self.limits = limits
        version = try? await api.version()
        if commits == nil { commits = try? await api.mergeRequestCommits(projectID: mr.projectId, iid: mr.iid) }
    }

    func loadCommits(api: GitLabAPIClient) async {
        guard commits == nil else { return }
        commits = (try? await api.mergeRequestCommits(projectID: mr.projectId, iid: mr.iid)) ?? []
    }

    func loadDiscussions(api: GitLabAPIClient) async {
        do {
            discussions = try await api.discussions(projectID: mr.projectId, iid: mr.iid)
            activityError = nil
        } catch is CancellationError {
        } catch {
            activityError = error.localizedDescription
        }
    }

    /// Diff from the local MR ref (refs/mr/<iid>), falling back to GitLab's /diffs.
    func loadDiff(repo: RepoModel, model: AppModel) async {
        guard diff == nil else { return }
        if repo.repoURL == nil { await repo.prepare(model: model) }
        if let git = repo.git, let url = repo.repoURL,
           let files = try? await git.mergeRequestDiff(repo: url, targetBranch: mr.targetBranch, iid: mr.iid) {
            diff = files
            diffSource = "local git diff --patience"
            return
        }
        do {
            diff = DiffParser.files(fromAPI: try await repo.api.mergeRequestDiffs(projectID: mr.projectId, iid: mr.iid))
            diffSource = "GitLab API"
        } catch {
            diff = []
            self.error = error.localizedDescription
        }
    }

    // MARK: Actions

    /// Runs one action at a time; a thrown error becomes `actionError`.
    private func perform(_ work: Work, _ body: () async throws -> Void) async {
        guard working == nil else { return }
        working = work
        actionError = nil
        defer { working = nil }
        do {
            try await body()
        } catch is CancellationError {
        } catch {
            actionError = error.localizedDescription
        }
    }

    /// Passes the reviewed SHA, so a push in the meantime makes GitLab refuse (409).
    func merge(api: GitLabAPIClient) async {
        await perform(.merge) {
            do {
                mr = try await api.merge(projectID: mr.projectId, iid: mr.iid, sha: mr.sha, squash: squash, removeSourceBranch: deleteSourceBranch)
            } catch GitLabAPIError.conflict {
                await refresh(api: api)
                throw ActionMessage(text: "Someone pushed to \(mr.sourceBranch) after you loaded it. The merge request is refreshed; check the changes, then merge again.")
            }
            await loadDiscussions(api: api)
        }
    }

    func setAutoMerge(api: GitLabAPIClient) async {
        await perform(.autoMerge) {
            do {
                mr = try await api.setAutoMerge(projectID: mr.projectId, iid: mr.iid, sha: mr.sha, squash: squash, removeSourceBranch: deleteSourceBranch)
            } catch GitLabAPIError.conflict {
                await refresh(api: api)
                throw ActionMessage(text: "New commits arrived on \(mr.sourceBranch). The merge request is refreshed; set auto-merge again if you still want it.")
            }
            await loadDiscussions(api: api)
        }
    }

    func cancelAutoMerge(api: GitLabAPIClient) async {
        await perform(.cancelAutoMerge) {
            mr = try await api.cancelAutoMerge(projectID: mr.projectId, iid: mr.iid)
            await loadDiscussions(api: api)
        }
    }

    /// Returns true when GitLab wants the user's password before approving: the project asks
    /// for it when the approve call gets a 401 while the token itself still works.
    func approve(api: GitLabAPIClient, password: String? = nil) async -> Bool {
        var needsPassword = false
        await perform(.approve) {
            do {
                approvals = try await api.approve(projectID: mr.projectId, iid: mr.iid, sha: mr.sha, password: password)
            } catch GitLabAPIError.unauthorized {
                guard (try? await api.currentUser()) != nil else { throw GitLabAPIError.unauthorized }
                needsPassword = true
                if password != nil { throw ActionMessage(text: "GitLab didn't accept that password.") }
                return
            } catch GitLabAPIError.conflict {
                await refresh(api: api)
                throw ActionMessage(text: "New commits arrived after you loaded this. Check the changes, then approve again.")
            }
            await loadDiscussions(api: api)
        }
        return needsPassword
    }

    func unapprove(api: GitLabAPIClient) async {
        await perform(.unapprove) {
            try await api.unapprove(projectID: mr.projectId, iid: mr.iid)
            approvals = try? await api.approvals(projectID: mr.projectId, iid: mr.iid)
            await loadDiscussions(api: api)
        }
    }

    func setAssignees(_ people: [GitLabPerson], api: GitLabAPIClient) async {
        await perform(.assignees) {
            mr = try await api.setAssignees(projectID: mr.projectId, iid: mr.iid, userIDs: people.compactMap(\.id))
            await loadDiscussions(api: api)
        }
    }

    func setReviewers(_ people: [GitLabPerson], api: GitLabAPIClient) async {
        await perform(.reviewers) {
            mr = try await api.setReviewers(projectID: mr.projectId, iid: mr.iid, userIDs: people.compactMap(\.id))
            await loadDiscussions(api: api)
        }
    }

    /// Returns true once the comment is on GitLab.
    func comment(_ text: String, api: GitLabAPIClient) async -> Bool {
        var posted = false
        await perform(.comment) {
            _ = try await api.addComment(projectID: mr.projectId, iid: mr.iid, body: text)
            posted = true
            await loadDiscussions(api: api)
        }
        return posted
    }

    func reply(_ text: String, to discussion: Discussion, api: GitLabAPIClient) async -> Bool {
        var posted = false
        await perform(.reply(discussion.id)) {
            _ = try await api.reply(projectID: mr.projectId, iid: mr.iid, discussionID: discussion.id, body: text)
            posted = true
            await loadDiscussions(api: api)
        }
        return posted
    }

    func setResolved(_ resolved: Bool, _ discussion: Discussion, api: GitLabAPIClient) async {
        await perform(.resolve(discussion.id)) {
            let updated = try await api.resolveDiscussion(projectID: mr.projectId, iid: mr.iid, discussionID: discussion.id, resolved: resolved)
            if let index = discussions?.firstIndex(where: { $0.id == updated.id }) { discussions?[index] = updated }
            mr = (try? await api.mergeRequest(projectID: mr.projectId, iid: mr.iid)) ?? mr
        }
    }

    /// Saves the Edit page; throws so the page can show the error and stay open.
    func save(_ edit: MergeRequestEdit, original: MergeRequestEdit, api: GitLabAPIClient) async throws {
        mr = try await api.updateMergeRequest(projectID: mr.projectId, iid: mr.iid, edit: edit, original: original)
        diff = nil
        commits = nil
        await loadDiscussions(api: api)
    }

    /// PUT /rebase, then poll every 2 s until GitLab reports the rebase finished.
    func rebase(api: GitLabAPIClient) async {
        isRebasing = true
        actionError = nil
        defer { isRebasing = false }
        do {
            try await api.rebase(projectID: mr.projectId, iid: mr.iid)
            repeat {
                try await Task.sleep(for: .seconds(2))
                mr = try await api.mergeRequest(projectID: mr.projectId, iid: mr.iid, includeRebaseInProgress: true)
            } while mr.rebaseInProgress == true
            if let mergeError = mr.mergeError, !mergeError.isEmpty {
                actionError = "GitLab couldn't rebase: \(mergeError)"
            }
            diff = nil
            commits = nil
        } catch is CancellationError {
        } catch {
            actionError = error.localizedDescription
        }
    }
}

struct MRDetailView: View {
    enum Tab: String, CaseIterable, Identifiable {
        case overview = "Overview", commits = "Commits", pipelines = "Pipelines", changes = "Changes"
        var id: String { rawValue }
    }

    let repo: RepoModel
    @Environment(AppModel.self) private var model
    @Environment(AppSettings.self) private var settings
    @Environment(\.controlActiveState) private var activeState
    @Environment(\.mrNavigator) private var navigator
    @State private var detail: MRDetailModel
    @State private var pipelines = PipelinesModel()
    @State private var tab: Tab = .overview
    @State private var showResolve = false
    @AppStorage("mrDetailsShown") private var showDetails = true

    init(repo: RepoModel, initial: MergeRequest) {
        self.repo = repo
        _detail = State(initialValue: MRDetailModel(mr: initial, project: repo.project))
    }

    private var mr: MergeRequest { detail.mr }
    private var canWrite: Bool { model.accounts[repo.domain.key]?.canWrite ?? true }
    private var links: LinkResolver { LinkResolver(baseURL: repo.domain.baseURL, projectPath: repo.project.pathWithNamespace) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            switch tab {
            case .overview: overview
            case .commits: commitsTab
            case .pipelines: MRPipelinesView(repo: repo, detail: detail, model: pipelines)
            case .changes: changesTab
            }
        }
        .navigationTitle("!\(String(mr.iid))")
        .inspector(isPresented: $showDetails) {
            MRDetailsInspector(repo: repo, detail: detail)
                .inspectorColumnWidth(min: 240, ideal: 280, max: 380)
        }
        .toolbar {
            ToolbarItem {
                Button { navigator.edit(detail) } label: { Label("Edit", systemImage: "pencil") }
                    .help(canWrite ? "Edit the title, description, branches and people" : "Editing needs a token with the api scope")
                    .disabled(!canWrite || mr.state != "opened")
            }
            ToolbarItem {
                Button { showDetails.toggle() } label: { Label(showDetails ? "Hide Details" : "Show Details", systemImage: "sidebar.trailing") }
                    .help(showDetails ? "Hide details" : "Show assignees and reviewers")
            }
        }
        .routesLinks { iid in if iid != mr.iid { navigator.openMergeRequest(iid) } }
        .task {
            await detail.refresh(api: repo.api)
            detail.chooseMergeOptions(settings: settings)
            await detail.loadDiscussions(api: repo.api)
            #if DEBUG
            if DebugSnapshot.value("GLC_DEBUG_RESOLVE") != nil { showResolve = true }
            if let raw = DebugSnapshot.value("GLC_DEBUG_MR_TAB"), let debugTab = Tab(rawValue: raw) { tab = debugTab }
            if DebugSnapshot.value("GLC_DEBUG_MR_EDIT") != nil { try? await Task.sleep(for: .seconds(1)); navigator.edit(detail) }
            if let script = DebugSnapshot.value("GLC_DEBUG_ACTIONS") { await runDebugActions(script) }
            #endif
        }
        .task(id: activeState == .key) {
            // Auto-refresh while this window is focused.
            guard activeState == .key else { return }
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(max(settings.autoRefreshSeconds, 10)))
                if Task.isCancelled || detail.isRebasing || detail.working != nil { continue }
                await detail.refresh(api: repo.api)
                if tab == .overview { await detail.loadDiscussions(api: repo.api) }
            }
        }
        .sheet(isPresented: $showResolve, onDismiss: { Task { await detail.refresh(api: repo.api) } }) {
            AIResolveView(repo: repo, mr: mr)
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(mr.title).font(.title2.bold()).textSelection(.enabled)
            }
            HStack(spacing: 8) {
                Pill(text: stateLabel, tone: stateTone)
                Text("**\(mr.author.name)** wants to merge ")
                    + Text(mr.sourceBranch).font(.callout.monospaced())
                    + Text(" into ")
                    + Text(mr.targetBranch).font(.callout.monospaced())
                    + Text(" · updated \(relative(mr.updatedDate))")
            }
            .font(.callout)
            .foregroundStyle(.secondary)
            Picker("Section", selection: $tab) {
                ForEach(Tab.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 16)
    }

    #if DEBUG
    /// GLC_DEBUG_ACTIONS="approve;automerge;comment:Hi;reviewer:lan;unresolve" presses the real
    /// buttons' code against a mock server, so a snapshot shows the result.
    private func runDebugActions(_ script: String) async {
        for step in script.split(separator: ";") {
            let parts = step.split(separator: ":", maxSplits: 1).map(String.init)
            let argument = parts.count > 1 ? parts[1] : ""
            switch parts[0] {
            case "approve": _ = await detail.approve(api: repo.api)
            case "unapprove": await detail.unapprove(api: repo.api)
            case "automerge": await detail.setAutoMerge(api: repo.api)
            case "cancelautomerge": await detail.cancelAutoMerge(api: repo.api)
            case "comment": _ = await detail.comment(argument, api: repo.api)
            case "reviewer":
                if let member = try? await repo.api.members(projectID: repo.project.id, search: argument).first {
                    await detail.setReviewers((mr.reviewers ?? []) + [member.person], api: repo.api)
                }
            case "unresolve":
                if let thread = detail.discussions?.first(where: \.isResolvable) { await detail.setResolved(false, thread, api: repo.api) }
            default: break
            }
        }
    }
    #endif

    private var stateLabel: String {
        if mr.state == "opened" { return mr.draft == true ? "Draft" : "Open" }
        return mr.state.capitalized
    }

    private var stateTone: Tone {
        switch mr.state {
        case "opened": return mr.draft == true ? .gray : .green
        case "merged": return .purple
        default: return .gray
        }
    }

    private var overview: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 28) {
                    VStack(alignment: .leading, spacing: 12) {
                        if let description = mr.description, !description.isEmpty {
                            MarkdownView(text: description, links: links)
                        } else {
                            Text("No description.").foregroundStyle(.secondary)
                        }
                        if let error = detail.error { ErrorText(message: error) }
                    }
                    MergeBox(repo: repo, detail: detail, onResolve: { showResolve = true }, onShowPipelines: { tab = .pipelines })
                        .id("merge")
                    ActivityView(repo: repo, detail: detail)
                        .id("activity")
                }
                .frame(maxWidth: 780, alignment: .leading)
                .padding(24)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            #if DEBUG
            .task(id: detail.discussions?.count) {
                // GLC_DEBUG_SCROLL=merge|activity scrolls there for a snapshot.
                guard let target = DebugSnapshot.value("GLC_DEBUG_SCROLL"), detail.discussions != nil else { return }
                try? await Task.sleep(for: .milliseconds(300))
                proxy.scrollTo(target, anchor: target == "activity" ? .bottom : .top)
            }
            #endif
        }
    }

    private var commitsTab: some View {
        ZStack {
            if let commits = detail.commits {
                List(commits) { commit in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(commit.title).lineLimit(1)
                        Text("\(commit.authorName) · \(relative(commit.createdAt.flatMap(GitLabDate.parse))) · \(commit.shortId)")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 3)
                }
                .listStyle(.inset)
            } else {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .task { await detail.loadCommits(api: repo.api) }
    }

    private var changesTab: some View {
        VStack(spacing: 0) {
            if let diff = detail.diff {
                DiffView(files: diff)
                Divider()
                HStack {
                    Text("\(diff.count) files · from \(detail.diffSource)").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                }
                .padding(.horizontal, 14).padding(.vertical, 5)
            } else {
                VStack(spacing: 10) {
                    ProgressView()
                    CloneStatus(repo: repo)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .task { await detail.loadDiff(repo: repo, model: model) }
    }
}
