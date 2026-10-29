import SwiftUI
import GitLabClientCore

/// The Overview's merge box: pipeline, approvals, merge checks, and the action that applies
/// now (merge, auto-merge, rebase or resolve), with the squash and delete-branch ticks.
struct MergeBox: View {
    let repo: RepoModel
    @Bindable var detail: MRDetailModel
    let onResolve: () -> Void
    let onShowPipelines: () -> Void
    @Environment(AppModel.self) private var model
    @Environment(AppSettings.self) private var settings
    @State private var askPassword = false

    private var mr: MergeRequest { detail.mr }
    private var action: MergeAction { MergeStatusMapper.action(for: mr.detailedMergeStatus, state: mr.state) }
    private var canWrite: Bool { model.accounts[repo.domain.key]?.canWrite ?? true }
    private var isOpen: Bool { mr.state == "opened" }
    private var me: GitLabUser? { model.accounts[repo.domain.key]?.user }

    /// Auto-merge needs something to wait for; with nothing pending GitLab would merge at once.
    private var canSetAutoMerge: Bool {
        guard canWrite, isOpen, detail.pipelineIsActive, mr.draft != true, !detail.isAutoMergeSet else { return false }
        switch action {
        case .rebase, .resolveWithAI, .closed, .checking: return false
        default: return true
        }
    }

    var body: some View {
        Card {
            pipelineRow
            if isOpen {
                Divider()
                approvalsRow
                Divider()
                checksRow
            }
            Divider()
            actionArea
            if !canWrite {
                Divider()
                Label("Read-only token: merging, approving and commenting need the api scope.", systemImage: "eye")
                    .font(.caption).foregroundStyle(.orange).padding(14)
            }
        }
        .sheet(isPresented: $askPassword) {
            ApprovalPasswordSheet(domain: repo.domain.key, detail: detail, api: repo.api)
        }
    }

    // MARK: Rows

    private var pipelineRow: some View {
        HStack(spacing: 12) {
            PipelineIcon(status: detail.headPipeline?.status)
            VStack(alignment: .leading, spacing: 2) {
                Text(pipelineTitle).font(.callout.weight(.semibold))
                if let updated = detail.headPipeline?.updatedAt.flatMap(GitLabDate.parse) {
                    Text("Updated \(relative(updated))").font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer()
            if detail.headPipeline != nil {
                Button("View pipeline", action: onShowPipelines).buttonStyle(.link)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private var pipelineTitle: String {
        guard let pipeline = detail.headPipeline else { return "No pipeline" }
        let phrase: String
        switch CIStatus(pipeline.status) {
        case .success: phrase = "passed"
        case .failed: phrase = "failed"
        case .running: phrase = "is running"
        case .pending, .created, .preparing, .waitingForResource: phrase = "is pending"
        case .canceling: phrase = "is being canceled"
        case .canceled: phrase = "was canceled"
        case .skipped: phrase = "was skipped"
        case .manual: phrase = "is waiting for a manual job"
        case .scheduled: phrase = "is scheduled"
        case .other(let raw): phrase = raw
        }
        return "Pipeline #\(pipeline.id) \(phrase)"
    }

    private var approvalsRow: some View {
        HStack(spacing: 12) {
            if approvalSatisfied {
                Image(systemName: "checkmark.circle").foregroundStyle(.green).font(.title3)
            } else {
                Image(systemName: "clock").foregroundStyle(.orange).font(.title3)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(approvalTitle).font(.callout.weight(.semibold))
                Text(approvalNote).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            HStack(spacing: -6) {
                ForEach(detail.approvals?.approvedBy ?? [], id: \.user.username) {
                    InitialsAvatar(initials: $0.user.initials, size: 24, tint: $0.user.tint).help($0.user.name)
                }
            }
            if canWrite { approveButton }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    @ViewBuilder private var approveButton: some View {
        let approvals = detail.approvals
        if approvals?.userHasApproved == true {
            Button("Revoke approval") { Task { await detail.unapprove(api: repo.api) } }
                .disabled(detail.working != nil)
        } else if approvals?.userCanApprove != false {
            Button {
                Task { if await detail.approve(api: repo.api) { askPassword = true } }
            } label: {
                if detail.working == .approve { ProgressView().controlSize(.small) } else { Label("Approve", systemImage: "hand.thumbsup") }
            }
            .disabled(detail.working != nil || approvals == nil)
        }
    }

    private var approvalSatisfied: Bool {
        guard let approvals = detail.approvals else { return false }
        return approvals.hasRequirement ? (approvals.approvalsLeft ?? 0) == 0 : true
    }

    private var approverNames: String {
        let names = (detail.approvals?.approvedBy ?? []).map { $0.user.username == me?.username ? "you" : $0.user.name }
        switch names.count {
        case 0: return ""
        case 1: return names[0]
        default: return names.dropLast().joined(separator: ", ") + " and " + names.last!
        }
    }

    private var approvalTitle: String {
        guard let approvals = detail.approvals else { return "Approvals" }
        if approvals.hasRequirement {
            let left = approvals.approvalsLeft ?? 0
            if left > 0 { return "Needs \(left) more approval\(left == 1 ? "" : "s")" }
            return "Approved · \(approvals.approvedCount) of \(approvals.approvalsRequired ?? approvals.approvedCount) required"
        }
        return approvals.approvedCount == 0 ? "No approvals yet" : "Approved by \(approverNames)"
    }

    private var approvalNote: String {
        guard let approvals = detail.approvals else { return "Loading…" }
        if approvals.hasRequirement {
            let rules = (approvals.approvalRulesLeft ?? []).map { "“\($0.name)”" }
            let waiting = rules.isEmpty ? "" : "Waiting on \(rules.joined(separator: ", ")). "
            return waiting + (approvals.approvedCount == 0 ? "No one has approved yet." : "Approved by \(approverNames).")
        }
        if approvals.userCanApprove == false && approvals.userHasApproved != true { return "Approval is optional. You can't approve this one." }
        return "Approval is optional on this project."
    }

    private var checksRow: some View {
        let conflicts = mr.hasConflicts == true
        let threadsOpen = mr.blockingDiscussionsResolved == false
        return HStack(spacing: 12) {
            Image(systemName: conflicts || threadsOpen ? "exclamationmark.circle" : "checkmark.circle")
                .foregroundStyle(conflicts ? .red : threadsOpen ? .orange : .green).font(.title3)
            Text((conflicts ? "Conflicts with \(mr.targetBranch)" : "No conflicts with \(mr.targetBranch)")
                 + " · " + (threadsOpen ? "unresolved threads" : "all threads resolved"))
                .font(.callout)
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    // MARK: Action area

    private var actionArea: some View {
        VStack(alignment: .leading, spacing: 12) {
            if detail.isAutoMergeSet {
                autoMergeSet
            } else {
                status
            }
            if let error = detail.actionError {
                ErrorText(message: error)
                if canWrite, action != .resolveWithAI, error.contains("rebase") { resolveButton }
            }
            Text("detailed_merge_status: \(mr.detailedMergeStatus ?? "unknown")").font(.caption.monospaced()).foregroundStyle(.tertiary)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.secondary.opacity(0.04))
        .task(id: action) {
            // "checking" settles quickly; look again after 2 s.
            if action == .checking {
                try? await Task.sleep(for: .seconds(2))
                await detail.refresh(api: repo.api)
            }
        }
    }

    @ViewBuilder private var status: some View {
        switch action {
        case .merge:
            if canWrite {
                optionTicks
                HStack(spacing: 10) {
                    if canSetAutoMerge {
                        autoMergeButton
                        Button("Merge now") { Task { await detail.merge(api: repo.api) } }
                            .controlSize(.large).disabled(detail.working != nil)
                    } else {
                        Button {
                            Task { await detail.merge(api: repo.api) }
                        } label: {
                            Label(detail.working == .merge ? "Merging…" : "Merge", systemImage: "arrow.triangle.merge")
                        }
                        .buttonStyle(.borderedProminent).controlSize(.large).disabled(detail.working != nil)
                    }
                }
                Text("Merges exactly \(String((mr.sha ?? "").prefix(8))). If someone pushes first, GitLab refuses and you can look again.")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                statusLine("checkmark.circle", .green, "Ready to merge", "All checks GitLab requires have passed.")
            }
        case .rebase:
            statusLine("arrow.triangle.branch", .orange, "Needs a rebase", "\(mr.targetBranch) moved on. GitLab can rebase this on the server.")
            if canWrite {
                Button {
                    Task { await detail.rebase(api: repo.api) }
                } label: {
                    if detail.isRebasing {
                        HStack { ProgressView().controlSize(.small); Text("Rebasing on GitLab…") }
                    } else {
                        Text("Rebase")
                    }
                }
                .buttonStyle(.borderedProminent).controlSize(.large)
                .disabled(detail.isRebasing)
            }
        case .resolveWithAI:
            statusLine("xmark.circle", .red, "Merge blocked: conflicts", "\(mr.targetBranch) changed the same lines. A server-side rebase can't fix this.")
            if canWrite { resolveButton }
        case .waitForPipeline(let reason):
            statusLine("clock", .blue, "Waiting for the pipeline", reason)
            autoMergeOffer
        case .needsApproval:
            statusLine("person.crop.circle.badge.exclamationmark", .orange, "Needs approval", "GitLab needs more approvals before this can merge.")
            autoMergeOffer
        case .blocked(let reason):
            statusLine("hand.raised", .secondary, "Can't merge yet", reason)
            autoMergeOffer
        case .checking:
            HStack(spacing: 8) { ProgressView().controlSize(.small); Text("GitLab is checking mergeability…").font(.callout) }
        case .closed(let reason):
            statusLine(mr.state == "merged" ? "arrow.triangle.merge" : "xmark.circle", mr.state == "merged" ? .purple : .secondary, mr.state.capitalized, reason)
        }
    }

    @ViewBuilder private var autoMergeOffer: some View {
        if canSetAutoMerge {
            optionTicks
            HStack(alignment: .center, spacing: 14) {
                autoMergeButton
                Text(waitText).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var autoMergeButton: some View {
        Button {
            Task { await detail.setAutoMerge(api: repo.api) }
        } label: {
            if detail.working == .autoMerge {
                HStack { ProgressView().controlSize(.small); Text("Setting auto-merge…") }
            } else {
                Label("Set to auto-merge", systemImage: "arrow.triangle.merge")
            }
        }
        .buttonStyle(.borderedProminent).controlSize(.large)
        .disabled(detail.working != nil)
    }

    /// GitLab 17.0+ waits for every merge check; older servers only wait for the pipeline.
    private var waitText: String {
        let waits = detail.version.map { $0.atLeast(17, 0) } ?? false
            ? "Waits for the pipeline and every other merge check, then merges."
            : "Merges when the pipeline succeeds."
        return waits + " " + branchText
    }

    private var branchText: String {
        let count = detail.commits?.count
        let squashText = detail.squash
            ? (count.map { $0 > 1 ? "Squashes \($0) commits into 1" : "Squashes the commits" } ?? "Squashes the commits")
            : "Keeps every commit"
        return squashText + (detail.deleteSourceBranch ? " and deletes \(mr.sourceBranch)." : " and keeps \(mr.sourceBranch).")
    }

    private var autoMergeSet: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "arrow.triangle.merge").foregroundStyle(Color.accentColor).font(.title3)
            VStack(alignment: .leading, spacing: 3) {
                Text("Set to auto-merge by \(mr.mergeUser.map { $0.username == me?.username ? "you" : $0.name } ?? "someone")").font(.headline)
                Text(detail.pipelineIsActive ? "Merges once the pipeline passes and every merge check is met." : "Merges as soon as every merge check is met.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if canWrite {
                Button {
                    Task { await detail.cancelAutoMerge(api: repo.api) }
                } label: {
                    if detail.working == .cancelAutoMerge { ProgressView().controlSize(.small) } else { Text("Cancel auto-merge") }
                }
                .disabled(detail.working != nil)
            }
        }
    }

    private var optionTicks: some View {
        HStack(spacing: 20) {
            Toggle(isOn: Binding(get: { detail.squashPolicy.forcedValue ?? detail.squash }, set: { detail.squash = $0 })) {
                Text("Squash commits") + Text(commitCountText).foregroundStyle(.secondary)
            }
            .disabled(detail.squashPolicy.isLocked)
            .help(detail.squashPolicy.lockedReason ?? "Combine the commits into one when merging")
            Toggle("Delete source branch", isOn: $detail.deleteSourceBranch)
        }
        .toggleStyle(.checkbox)
    }

    private var commitCountText: String {
        guard let count = detail.commits?.count, count > 1 else { return "" }
        return " (\(count) into 1)"
    }

    private var resolveButton: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button(action: onResolve) {
                Label("Resolve with \(settings.aiPreset.name)", systemImage: "sparkles")
            }
            .buttonStyle(.borderedProminent).tint(.purple).controlSize(.large)
            Text("Runs in a temporary worktree. Nothing is pushed until you approve the diff. Change the CLI in Settings → AI CLI.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }

    private func statusLine(_ icon: String, _ color: Color, _ title: String, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon).foregroundStyle(color).font(.title3)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.headline)
                Text(text).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

/// Shown when the project asks for the user's password before each approval. The password goes
/// to GitLab in that one request and is never stored.
struct ApprovalPasswordSheet: View {
    let domain: String
    let detail: MRDetailModel
    let api: GitLabAPIClient
    @Environment(\.dismiss) private var dismiss
    @State private var password = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Approve !\(String(detail.mr.iid))").font(.title3.bold())
            Text("This project asks for your GitLab password before each approval. It goes to \(domain) with this approval only and isn't saved.")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            SecureField("GitLab password", text: $password)
                .textFieldStyle(.roundedBorder)
            Text("Accounts that sign in only through SSO have no GitLab password; approve those in the browser.")
                .font(.caption).foregroundStyle(.secondary)
            if let error = detail.actionError { ErrorText(message: error) }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button {
                    Task {
                        let stillNeeds = await detail.approve(api: api, password: password)
                        password = ""
                        if !stillNeeds && detail.actionError == nil { dismiss() }
                    }
                } label: {
                    if detail.working == .approve { ProgressView().controlSize(.small) } else { Text("Approve") }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(password.isEmpty || detail.working != nil)
            }
        }
        .padding(24)
        .frame(width: 440)
    }
}
