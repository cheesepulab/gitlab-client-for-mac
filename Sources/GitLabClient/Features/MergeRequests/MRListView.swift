import SwiftUI
import GitLabClientCore

@MainActor
@Observable
final class MRListModel {
    private(set) var items: [MergeRequest] = []
    private(set) var details: [Int: MergeRequest] = [:]
    private(set) var approvals: [Int: Approvals] = [:]
    private(set) var isLoading = false
    private(set) var error: String?

    func load(api: GitLabAPIClient, projectID: Int, state: String) async {
        isLoading = true
        defer { isLoading = false }
        do {
            items = try await api.mergeRequests(projectID: projectID, state: state)
            error = nil
        } catch is CancellationError {
        } catch {
            self.error = error.localizedDescription
        }
    }

    /// The list endpoint has no pipeline, so open rows fetch their detail and approvals lazily.
    func loadExtras(api: GitLabAPIClient, mr: MergeRequest) async {
        guard details[mr.iid] == nil else { return }
        async let detail = try? api.mergeRequest(projectID: mr.projectId, iid: mr.iid)
        async let approval = try? api.approvals(projectID: mr.projectId, iid: mr.iid)
        if let detail = await detail { details[mr.iid] = detail }
        if let approval = await approval { approvals[mr.iid] = approval }
    }
}

/// Pushes screens onto the merge request stack: another MR (from a `!12` link) or the Edit page.
struct MRNavigator {
    var openMergeRequest: @MainActor (Int) -> Void = { _ in }
    var edit: @MainActor (MRDetailModel) -> Void = { _ in }
    var back: @MainActor () -> Void = {}
}

extension EnvironmentValues {
    @Entry var mrNavigator = MRNavigator()
}

/// Edit page route; the detail model is shared so a save shows up when going back.
struct MREditRoute: Hashable {
    let detail: MRDetailModel

    static func == (lhs: MREditRoute, rhs: MREditRoute) -> Bool { lhs.detail === rhs.detail }
    func hash(into hasher: inout Hasher) { hasher.combine(ObjectIdentifier(detail)) }
}

struct MRListView: View {
    let repo: RepoModel
    @Environment(AppSettings.self) private var settings
    @State private var list = MRListModel()
    @State private var state = "opened"
    @State private var search = ""
    @State private var path = NavigationPath()
    @State private var openError: String?

    var body: some View {
        NavigationStack(path: $path) {
            VStack(spacing: 0) {
                HStack(spacing: 12) {
                    Picker("State", selection: $state) {
                        Text("Open").tag("opened")
                        Text("Merged").tag("merged")
                        Text("Closed").tag("closed")
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .fixedSize()
                    TextField("Search merge requests", text: $search)
                        .textFieldStyle(.roundedBorder)
                        .frame(maxWidth: 260)
                    Spacer()
                    if list.isLoading { ProgressView().controlSize(.small) }
                    Button {
                        Task { await list.load(api: repo.api, projectID: repo.project.id, state: state) }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .help("Refresh")
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                Divider()
                List(filtered) { mr in
                    NavigationLink(value: mr) {
                        MRRow(mr: list.details[mr.iid] ?? mr, approvals: list.approvals[mr.iid])
                    }
                    .task { if mr.state == "opened" { await list.loadExtras(api: repo.api, mr: mr) } }
                }
                .listStyle(.inset)
                .overlay {
                    if list.items.isEmpty && !list.isLoading {
                        if let error = list.error {
                            ContentUnavailableView {
                                Label("Couldn't load merge requests", systemImage: "exclamationmark.triangle")
                            } description: { Text(error) }
                        } else {
                            ContentUnavailableView("No \(state == "opened" ? "open" : state) merge requests", systemImage: "arrow.triangle.pull")
                        }
                    }
                }
            }
            // Set on each destination: pushed screens don't see environment values set on the stack.
            .navigationDestination(for: MergeRequest.self) { mr in
                MRDetailView(repo: repo, initial: list.details[mr.iid] ?? mr)
                    .environment(\.mrNavigator, navigator)
            }
            .navigationDestination(for: MREditRoute.self) { route in
                MREditView(repo: repo, detail: route.detail)
                    .environment(\.mrNavigator, navigator)
            }
        }
        .alert("Couldn't open the merge request", isPresented: Binding(get: { openError != nil }, set: { if !$0 { openError = nil } })) {
            Button("OK") { openError = nil }
        } message: {
            Text(openError ?? "")
        }
        .task(id: state) {
            await list.load(api: repo.api, projectID: repo.project.id, state: state)
            #if DEBUG
            if path.isEmpty, let iid = Int(DebugSnapshot.value("GLC_DEBUG_MR") ?? ""), let mr = list.items.first(where: { $0.iid == iid }) {
                path.append(mr)
            }
            #endif
        }
        .onAppear { state = settings.defaultMRState }
    }

    private var navigator: MRNavigator {
        MRNavigator(
            openMergeRequest: { iid in
                if let mr = list.details[iid] ?? list.items.first(where: { $0.iid == iid }) {
                    path.append(mr)
                    return
                }
                Task {
                    do {
                        path.append(try await repo.api.mergeRequest(projectID: repo.project.id, iid: iid))
                    } catch {
                        openError = "!\(iid): \(error.localizedDescription)"
                    }
                }
            },
            edit: { detail in path.append(MREditRoute(detail: detail)) },
            back: { if !path.isEmpty { path.removeLast() } }
        )
    }

    private var filtered: [MergeRequest] {
        guard !search.isEmpty else { return list.items }
        return list.items.filter {
            $0.title.localizedCaseInsensitiveContains(search) || "!\($0.iid)".contains(search)
                || $0.author.name.localizedCaseInsensitiveContains(search) || $0.sourceBranch.localizedCaseInsensitiveContains(search)
        }
    }
}

struct MRRow: View {
    let mr: MergeRequest
    let approvals: Approvals?

    var body: some View {
        HStack(spacing: 14) {
            PipelineIcon(status: mr.pipelineStatus)
            VStack(alignment: .leading, spacing: 3) {
                Text(mr.title).fontWeight(.semibold).lineLimit(1)
                HStack(spacing: 4) {
                    Text("!\(String(mr.iid)) ·")
                    Text("\(mr.sourceBranch) → \(mr.targetBranch)").font(.caption.monospaced())
                    Text("· \(mr.author.name) · \(relative(mr.updatedDate))")
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            }
            Spacer(minLength: 8)
            if let approvals {
                Label(approvals.summary, systemImage: "person.crop.circle.badge.checkmark")
                    .font(.caption).foregroundStyle(.secondary)
                    .help("Approvals")
            }
            Pill(text: MergeStatusMapper.label(for: mr.detailedMergeStatus, state: mr.state), tone: tone)
                .frame(minWidth: 110, alignment: .trailing)
        }
        .padding(.vertical, 5)
    }

    private var tone: Tone {
        switch MergeStatusMapper.action(for: mr.detailedMergeStatus, state: mr.state) {
        case .merge: return .green
        case .rebase: return .orange
        case .resolveWithAI: return .red
        case .waitForPipeline: return .blue
        case .closed: return mr.state == "merged" ? .purple : .gray
        case .needsApproval, .blocked, .checking: return .gray
        }
    }
}

struct PipelineIcon: View {
    let status: String?

    var body: some View {
        Group {
            switch status {
            case "success": Image(systemName: "checkmark.circle").foregroundStyle(.green)
            case "failed": Image(systemName: "xmark.circle").foregroundStyle(.red)
            case "running", "pending", "preparing", "created", "waiting_for_resource": ProgressView().controlSize(.small)
            case "canceled", "skipped": Image(systemName: "slash.circle").foregroundStyle(.secondary)
            case "manual": Image(systemName: "hand.raised.circle").foregroundStyle(.secondary)
            case nil: Image(systemName: "circle.dotted").foregroundStyle(.tertiary)
            default: Image(systemName: "circle").foregroundStyle(.secondary)
            }
        }
        .font(.system(size: 17))
        .frame(width: 20)
        .help(status.map { "Pipeline \($0)" } ?? "No pipeline")
        .accessibilityLabel(status.map { "Pipeline \($0)" } ?? "No pipeline")
    }
}
