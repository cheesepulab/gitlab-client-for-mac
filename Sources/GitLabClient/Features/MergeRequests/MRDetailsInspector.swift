import SwiftUI
import GitLabClientCore

/// Right-hand column: assignees and reviewers (changed in place), reference and source branch.
struct MRDetailsInspector: View {
    enum Picking: Hashable { case assignees, reviewers }

    let repo: RepoModel
    let detail: MRDetailModel
    @Environment(AppModel.self) private var model
    @State private var picking: Picking?

    private var mr: MergeRequest { detail.mr }
    private var canWrite: Bool { (model.accounts[repo.domain.key]?.canWrite ?? true) && mr.state == "opened" }
    private var me: GitLabPerson? {
        model.accounts[repo.domain.key]?.user.map { GitLabPerson(id: $0.id, name: $0.name, username: $0.username) }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                section(title: (mr.assignees?.count ?? 0) > 1 ? "Assignees" : "Assignee", kind: .assignees) {
                    let people = mr.assignees ?? []
                    if people.isEmpty {
                        HStack(spacing: 4) {
                            Text("None").foregroundStyle(.secondary)
                            if canWrite, let me {
                                Text("·").foregroundStyle(.secondary)
                                Button("assign yourself") { Task { await detail.setAssignees([me], api: repo.api) } }.buttonStyle(.link)
                            }
                        }
                        .font(.callout)
                    }
                    ForEach(people, id: \.username) { person in
                        PersonRow(person: person, isMe: person.username == me?.username)
                    }
                }
                Divider()
                section(title: (mr.reviewers?.count ?? 0) == 1 ? "Reviewer" : "Reviewers", kind: .reviewers) {
                    let people = mr.reviewers ?? []
                    if people.isEmpty { Text("None").font(.callout).foregroundStyle(.secondary) }
                    ForEach(people, id: \.username) { person in
                        let approved = detail.approvals?.approvedBy?.contains { $0.user.username == person.username } == true
                        PersonRow(person: person, isMe: person.username == me?.username,
                                  state: approved ? "Approved" : "Review requested", approved: approved)
                    }
                }
                Divider()
                copyRow("Reference", mr.references?.full ?? "\(repo.project.pathWithNamespace)!\(mr.iid)")
                copyRow("Source branch", mr.sourceBranch)
                if let error = detail.actionError, detail.working == nil, picking != nil {
                    ErrorText(message: error).padding(16)
                }
            }
        }
        #if DEBUG
        .task {
            if DebugSnapshot.value("GLC_DEBUG_PICKER") == "reviewers" {
                try? await Task.sleep(for: .seconds(2))
                picking = .reviewers
            }
        }
        #endif
    }

    private func section<Content: View>(title: String, kind: Picking, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(title).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                Spacer()
                if detail.working == (kind == .assignees ? .assignees : .reviewers) { ProgressView().controlSize(.mini) }
                if canWrite {
                    Button("Edit") { picking = kind }
                        .buttonStyle(.link)
                        .font(.caption.weight(.semibold))
                        .popover(isPresented: Binding(get: { picking == kind }, set: { if !$0 { picking = nil } }), arrowEdge: .leading) {
                            picker(for: kind)
                        }
                }
            }
            content()
        }
        .padding(16)
    }

    @ViewBuilder private func picker(for kind: Picking) -> some View {
        let isAssignees = kind == .assignees
        let selected = (isAssignees ? mr.assignees : mr.reviewers) ?? []
        let multiple = isAssignees ? detail.limits.multipleAssignees : detail.limits.multipleReviewers
        PeoplePicker(
            api: repo.api, projectID: repo.project.id, selected: selected, allowsMultiple: multiple,
            note: multiple
                ? (isAssignees ? "This server allows several assignees. Changes save as you pick." : "This server allows several reviewers. Each one gets a review request.")
                : (isAssignees ? "GitLab Free allows one assignee. Picking someone replaces the current one." : "GitLab Free allows one reviewer. Picking someone replaces the current one.")
        ) { person in
            let next = PeoplePicker.toggled(person, in: selected, allowsMultiple: multiple)
            Task {
                if isAssignees { await detail.setAssignees(next, api: repo.api) } else { await detail.setReviewers(next, api: repo.api) }
            }
        }
    }

    private func copyRow(_ label: String, _ value: String) -> some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(label).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                Text(value).font(.callout.monospaced()).textSelection(.enabled).lineLimit(2)
            }
            Spacer()
            Button { Clipboard.copy(value) } label: { Image(systemName: "doc.on.doc") }
                .buttonStyle(.borderless)
                .help("Copy \(label.lowercased())")
                .accessibilityLabel("Copy \(label.lowercased())")
        }
        .padding(.horizontal, 16)
        .padding(.top, 12)
    }
}

struct PersonRow: View {
    let person: GitLabPerson
    var isMe = false
    var state: String?
    var approved = false

    var body: some View {
        HStack(spacing: 9) {
            InitialsAvatar(initials: person.initials, size: 26, tint: person.tint)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Text(person.name).font(.callout)
                    if isMe { Pill(text: "You") }
                }
                Text(state ?? "@\(person.username)").font(.caption).foregroundStyle(approved ? AnyShapeStyle(.green) : AnyShapeStyle(.secondary))
            }
            Spacer(minLength: 0)
            if state != nil {
                Image(systemName: approved ? "checkmark.circle" : "clock")
                    .foregroundStyle(approved ? AnyShapeStyle(.green) : AnyShapeStyle(.tertiary))
                    .accessibilityLabel(approved ? "Approved" : "Review requested")
            }
        }
    }
}

/// Searchable list of project members with checkmarks. One person at a time unless the
/// server allows several.
struct PeoplePicker: View {
    let api: GitLabAPIClient
    let projectID: Int
    let selected: [GitLabPerson]
    let allowsMultiple: Bool
    let note: String
    let onToggle: (GitLabPerson) -> Void
    @State private var search = ""
    @State private var members: [ProjectMember]?
    @State private var error: String?

    static func toggled(_ person: GitLabPerson, in list: [GitLabPerson], allowsMultiple: Bool) -> [GitLabPerson] {
        if list.contains(where: { $0.username == person.username }) { return list.filter { $0.username != person.username } }
        return allowsMultiple ? list + [person] : [person]
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            TextField("Search project members", text: $search)
                .textFieldStyle(.roundedBorder)
                .padding(10)
            Divider()
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    ForEach(rows, id: \.username) { person in
                        let isSelected = selected.contains { $0.username == person.username }
                        Button { onToggle(person) } label: {
                            HStack(spacing: 8) {
                                Image(systemName: "checkmark").font(.caption.weight(.bold)).foregroundStyle(Color.accentColor)
                                    .opacity(isSelected ? 1 : 0).frame(width: 14)
                                InitialsAvatar(initials: person.initials, size: 22, tint: person.tint)
                                Text(person.name)
                                Text("@\(person.username)").font(.caption).foregroundStyle(.secondary)
                                Spacer(minLength: 0)
                            }
                            .padding(.horizontal, 8).padding(.vertical, 5)
                            .contentShape(Rectangle())
                            .background(isSelected ? Color.accentColor.opacity(0.12) : .clear, in: RoundedRectangle(cornerRadius: 6))
                        }
                        .buttonStyle(.plain)
                        .accessibilityAddTraits(isSelected ? .isSelected : [])
                    }
                    if members != nil && rows.isEmpty {
                        Text("No project member matches.").font(.caption).foregroundStyle(.secondary).padding(8)
                    }
                    if let error { ErrorText(message: error).padding(8) }
                }
                .padding(4)
            }
            .frame(height: 250)
            .overlay { if members == nil && error == nil { ProgressView() } }
            Divider()
            Text(note).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true).padding(10)
        }
        .frame(width: 320)
        .task(id: search) {
            if !search.isEmpty { try? await Task.sleep(for: .milliseconds(300)) }
            guard !Task.isCancelled else { return }
            do {
                members = try await api.members(projectID: projectID, search: search)
                error = nil
            } catch is CancellationError {
            } catch {
                self.error = error.localizedDescription
            }
        }
    }

    /// Selected people first (they may not match the search), then the other members.
    private var rows: [GitLabPerson] {
        let found = (members ?? []).map(\.person)
        let query = search.lowercased()
        let pinned = selected.filter { query.isEmpty || $0.name.lowercased().contains(query) || $0.username.lowercased().contains(query) }
        return pinned + found.filter { person in !selected.contains { $0.username == person.username } }
    }
}
