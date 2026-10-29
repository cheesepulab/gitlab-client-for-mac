import SwiftUI
import GitLabClientCore

/// Edit title, draft, description, target branch, people and merge options. Only changed
/// fields are sent.
struct MREditView: View {
    enum Mode: String, CaseIterable, Identifiable {
        case write = "Write", preview = "Preview"
        var id: String { rawValue }
    }

    enum Picking: Hashable { case assignees, reviewers }

    let repo: RepoModel
    let detail: MRDetailModel
    @Environment(\.mrNavigator) private var navigator
    @State private var original: MergeRequestEdit
    @State private var edit: MergeRequestEdit
    @State private var assignees: [GitLabPerson]
    @State private var reviewers: [GitLabPerson]
    @State private var mode: Mode = .write
    @State private var picking: Picking?
    @State private var pickingBranch = false
    @State private var saving = false
    @State private var error: String?
    @State private var confirmDiscard = false
    @State private var editor = EditorController()

    init(repo: RepoModel, detail: MRDetailModel) {
        self.repo = repo
        self.detail = detail
        // A project that always or never squashes overrides the MR's own flag; don't count that as an edit.
        var start = MergeRequestEdit(detail.mr)
        if let forced = SquashPolicy(projectOption: repo.project.squashOption).forcedValue { start.squash = forced }
        _original = State(initialValue: start)
        _edit = State(initialValue: start)
        _assignees = State(initialValue: detail.mr.assignees ?? [])
        _reviewers = State(initialValue: detail.mr.reviewers ?? [])
    }

    private var mr: MergeRequest { detail.mr }
    private var links: LinkResolver { LinkResolver(baseURL: repo.domain.baseURL, projectPath: repo.project.pathWithNamespace) }
    private var squashPolicy: SquashPolicy { SquashPolicy(projectOption: repo.project.squashOption) }
    private var changes: [MergeRequestEdit.Field] { edit.changes(from: original) }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 26) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Edit merge request").font(.title2.bold())
                        Text("!\(String(mr.iid)) in \(repo.project.pathWithNamespace) · changes save to GitLab when you press Save")
                            .font(.callout).foregroundStyle(.secondary)
                    }
                    titleSection
                    descriptionSection
                    targetSection
                    HStack(alignment: .top, spacing: 20) {
                        peopleField(.assignees)
                        peopleField(.reviewers)
                    }
                    optionsSection
                }
                .frame(maxWidth: 840, alignment: .leading)
                .padding(28)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            Divider()
            footer
        }
        .navigationTitle("Edit !\(String(mr.iid))")
        .routesLinks { iid in navigator.openMergeRequest(iid) }
        #if DEBUG
        .task {
            // GLC_DEBUG_EDIT="draft;target:main;preview;branches;save" edits like a user would.
            guard let script = DebugSnapshot.value("GLC_DEBUG_EDIT") else { return }
            try? await Task.sleep(for: .milliseconds(500))
            for step in script.split(separator: ";") {
                let parts = step.split(separator: ":", maxSplits: 1).map(String.init)
                switch parts[0] {
                case "draft": edit.draft = true
                case "target": edit.targetBranch = parts.last ?? edit.targetBranch
                case "preview": mode = .preview
                case "branches": pickingBranch = true
                case "people": picking = .reviewers
                case "append": edit.description += parts.last ?? ""
                case "save": await save()
                default: break
                }
            }
        }
        #endif
        .confirmationDialog("Discard your changes?", isPresented: $confirmDiscard) {
            Button("Discard Changes", role: .destructive) { navigator.back() }
        } message: {
            Text("You changed the \(sentence(changes.map(\.label))). They aren't saved to GitLab.")
        }
    }

    // MARK: Sections

    private var titleSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Title").font(.headline)
            TextField("Title", text: Binding(get: { edit.title }, set: { value in
                // Typing GitLab's own prefix ticks the box instead of staying in the title.
                let split = DraftTitle.split(value)
                if split.draft { edit.draft = true }
                edit.title = split.title
            }))
            .textFieldStyle(.roundedBorder)
            .font(.title3)
            Toggle("Mark as draft", isOn: $edit.draft).toggleStyle(.checkbox)
            Text(edit.draft
                 ? "Saved on GitLab as “\(edit.fullTitle)”. Drafts can’t be merged until you mark them ready."
                 : "Drafts can’t be merged. GitLab stores this as a “Draft:” prefix on the title; typing the prefix ticks this box.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }

    private var descriptionSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Description").font(.headline)
                Spacer()
                Picker("View", selection: $mode) {
                    ForEach(Mode.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented).labelsHidden().fixedSize()
            }
            VStack(spacing: 0) {
                if mode == .write {
                    HStack(spacing: 2) {
                        formatButton("bold", "Bold") { editor.wrap("**", "**", placeholder: "bold text") }
                        formatButton("italic", "Italic") { editor.wrap("_", "_", placeholder: "italic text") }
                        formatButton("chevron.left.forwardslash.chevron.right", "Code") { editor.wrap("`", "`", placeholder: "code") }
                        formatButton("link", "Link") { editor.wrap("[", "](https://)", placeholder: "link text") }
                        formatButton("checklist", "Task list item") { editor.insert("\n- [ ] ") }
                        Spacer()
                    }
                    .padding(.horizontal, 6).padding(.vertical, 4)
                    Divider()
                    LinkHighlightingEditor(text: $edit.description, resolver: links, controller: editor)
                        .frame(minHeight: 300)
                } else {
                    ScrollView {
                        MarkdownView(text: edit.description.isEmpty ? "_No description._" : edit.description, links: links)
                            .padding(16)
                    }
                    .frame(minHeight: 336)
                }
                Divider()
                foundLinks
            }
            .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color(nsColor: .separatorColor)))
            Text("Markdown. Links, !merge requests, #issues and @mentions are found as you type. In Preview and on the Overview they’re clickable: merge requests of this project open in the app, everything else in your browser.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }

    private func formatButton(_ icon: String, _ label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) { Image(systemName: icon).frame(width: 22, height: 20) }
            .buttonStyle(.borderless)
            .help(label)
            .accessibilityLabel(label)
    }

    /// Everything the detector found, as clickable chips.
    private var foundLinks: some View {
        let code = edit.description.ranges(of: #/`[^`\n]+`/#)
        var seen = Set<String>()
        let found = LinkDetector.matches(in: edit.description)
            .filter { match in !code.contains { $0.overlaps(match.range) } && seen.insert(match.text).inserted }
            .compactMap { match in RichText.target(for: match, resolver: links).map { (match, $0) } }
        return ScrollView(.horizontal) {
            HStack(spacing: 6) {
                Text(found.isEmpty ? "No links found yet" : "Found \(found.count):").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                ForEach(Array(found.enumerated()), id: \.offset) { _, item in
                    let (match, target) = item
                    Link(destination: target.url) {
                        Text(match.text.replacingOccurrences(of: #"^https?://"#, with: "", options: .regularExpression))
                            .font(.caption).lineLimit(1).frame(maxWidth: 260)
                    }
                    .padding(.horizontal, 8).padding(.vertical, 3)
                    .background(Color.accentColor.opacity(0.1), in: Capsule())
                    .help(target.helpText)
                }
            }
            .padding(.horizontal, 12).padding(.vertical, 7)
        }
    }

    private var targetSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Merge into").font(.headline)
            HStack(spacing: 10) {
                Label(mr.sourceBranch, systemImage: "arrow.triangle.branch")
                    .font(.callout.monospaced()).foregroundStyle(.secondary)
                    .padding(.horizontal, 10).padding(.vertical, 6)
                    .background(Color.secondary.opacity(0.1), in: RoundedRectangle(cornerRadius: 7))
                    .help("The source branch can’t change once the merge request exists.")
                Image(systemName: "arrow.right").foregroundStyle(.secondary)
                Button { pickingBranch = true } label: {
                    HStack(spacing: 6) {
                        Text(edit.targetBranch).font(.callout.monospaced())
                        Image(systemName: "chevron.down").font(.caption)
                    }
                }
                .popover(isPresented: $pickingBranch, arrowEdge: .bottom) {
                    BranchPicker(api: repo.api, projectID: repo.project.id, selected: edit.targetBranch, excluded: mr.sourceBranch) { branch in
                        edit.targetBranch = branch
                        pickingBranch = false
                    }
                }
                .accessibilityLabel("Target branch: \(edit.targetBranch)")
            }
            Text(edit.targetBranch != original.targetBranch
                 ? "Commits, changes and pipelines are recalculated against \(edit.targetBranch) when you save."
                 : "The source branch can’t change once the merge request exists, the same as on GitLab.")
                .font(.caption)
                .foregroundStyle(edit.targetBranch != original.targetBranch ? AnyShapeStyle(.orange) : AnyShapeStyle(.secondary))
        }
    }

    private func peopleField(_ kind: Picking) -> some View {
        let isAssignees = kind == .assignees
        let people = isAssignees ? assignees : reviewers
        let multiple = isAssignees ? detail.limits.multipleAssignees : detail.limits.multipleReviewers
        return VStack(alignment: .leading, spacing: 8) {
            Text(isAssignees ? (multiple ? "Assignees" : "Assignee") : (multiple ? "Reviewers" : "Reviewer")).font(.headline)
            HStack(spacing: 6) {
                if people.isEmpty { Text("None").font(.callout).foregroundStyle(.tertiary).padding(.leading, 4) }
                ForEach(people, id: \.username) { person in
                    HStack(spacing: 5) {
                        InitialsAvatar(initials: person.initials, size: 20, tint: person.tint)
                        Text(person.name).font(.callout)
                        Button { set(kind, people.filter { $0.username != person.username }) } label: { Image(systemName: "xmark").font(.caption2.weight(.bold)) }
                            .buttonStyle(.borderless)
                            .help("Remove \(person.name)")
                            .accessibilityLabel("Remove \(person.name)")
                    }
                    .padding(.leading, 3).padding(.trailing, 7).padding(.vertical, 3)
                    .background(Color.secondary.opacity(0.12), in: Capsule())
                }
                Spacer(minLength: 0)
                Button(multiple || people.isEmpty ? "Add" : "Change") { picking = kind }
                    .buttonStyle(.link)
                    .popover(isPresented: Binding(get: { picking == kind }, set: { if !$0 { picking = nil } }), arrowEdge: .bottom) {
                        PeoplePicker(api: repo.api, projectID: repo.project.id, selected: people, allowsMultiple: multiple,
                                     note: multiple ? "Several allowed on this server." : "GitLab Free allows one. Picking someone replaces the current one.") { person in
                            set(kind, PeoplePicker.toggled(person, in: isAssignees ? assignees : reviewers, allowsMultiple: multiple))
                        }
                    }
            }
            .padding(5)
            .frame(minHeight: 34)
            .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 7))
            .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(Color(nsColor: .separatorColor)))
            Text(isAssignees
                 ? (multiple ? "Several assignees allowed on this server." : "GitLab Free allows one assignee.")
                 : (multiple ? "Each new reviewer gets a review request." : "GitLab Free allows one reviewer."))
                .font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func set(_ kind: Picking, _ people: [GitLabPerson]) {
        if kind == .assignees {
            assignees = people
            edit.assigneeIDs = people.compactMap(\.id)
        } else {
            reviewers = people
            edit.reviewerIDs = people.compactMap(\.id)
        }
    }

    private var optionsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Merge options").font(.headline)
            Toggle("Delete source branch when merge request is accepted", isOn: $edit.removeSourceBranch)
            Toggle("Squash commits when merge request is accepted", isOn: $edit.squash)
                .disabled(squashPolicy.isLocked)
            Text(squashPolicy.lockedReason ?? "The project lets you choose whether to squash.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .toggleStyle(.checkbox)
    }

    private var footer: some View {
        HStack(spacing: 10) {
            if let error {
                ErrorText(message: error).lineLimit(3)
            } else {
                Text(changes.isEmpty ? "No unsaved changes"
                     : "\(changes.count) unsaved change\(changes.count == 1 ? "" : "s"): \(sentence(changes.map(\.label)))")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Button("Cancel") { if changes.isEmpty { navigator.back() } else { confirmDiscard = true } }
                .keyboardShortcut(.cancelAction)
            Button {
                Task { await save() }
            } label: {
                if saving { ProgressView().controlSize(.small) } else { Text("Save changes") }
            }
            .buttonStyle(.borderedProminent)
            .keyboardShortcut("s", modifiers: .command)
            .disabled(changes.isEmpty || saving || edit.title.trimmingCharacters(in: .whitespaces).isEmpty)
        }
        .padding(.horizontal, 24).padding(.vertical, 12)
        .background(.bar)
    }

    private func save() async {
        saving = true
        error = nil
        defer { saving = false }
        do {
            try await detail.save(edit, original: original, api: repo.api)
            original = MergeRequestEdit(detail.mr)
            edit = original
            navigator.back()
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func sentence(_ items: [String]) -> String {
        switch items.count {
        case 0: return ""
        case 1: return items[0]
        default: return items.dropLast().joined(separator: ", ") + " and " + items.last!
        }
    }
}

extension LinkTarget {
    var helpText: String {
        switch self {
        case .mergeRequest(let iid): return "Opens !\(iid) in GitLab Client"
        case .web(let url): return "Opens \(url.absoluteString) in your browser"
        }
    }
}

/// Searchable branch list for the target branch.
struct BranchPicker: View {
    let api: GitLabAPIClient
    let projectID: Int
    let selected: String
    let excluded: String
    let onPick: (String) -> Void
    @State private var search = ""
    @State private var branches: [APIBranch]?
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            TextField("Search branches", text: $search).textFieldStyle(.roundedBorder).padding(10)
            Divider()
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    ForEach((branches ?? []).filter { $0.name != excluded }, id: \.name) { branch in
                        Button { onPick(branch.name) } label: {
                            HStack(spacing: 8) {
                                Image(systemName: "checkmark").font(.caption.weight(.bold)).foregroundStyle(Color.accentColor)
                                    .opacity(branch.name == selected ? 1 : 0).frame(width: 14)
                                Text(branch.name).font(.callout.monospaced()).lineLimit(1)
                                Spacer(minLength: 4)
                                if branch.default == true { Pill(text: "default") } else if branch.protected == true { Pill(text: "protected") }
                            }
                            .padding(.horizontal, 8).padding(.vertical, 5)
                            .contentShape(Rectangle())
                            .background(branch.name == selected ? Color.accentColor.opacity(0.12) : .clear, in: RoundedRectangle(cornerRadius: 6))
                        }
                        .buttonStyle(.plain)
                    }
                    if branches?.isEmpty == true { Text("No branch matches.").font(.caption).foregroundStyle(.secondary).padding(8) }
                    if let error { ErrorText(message: error).padding(8) }
                }
                .padding(4)
            }
            .frame(height: 260)
            .overlay { if branches == nil && error == nil { ProgressView() } }
        }
        .frame(width: 340)
        .task(id: search) {
            if !search.isEmpty { try? await Task.sleep(for: .milliseconds(300)) }
            guard !Task.isCancelled else { return }
            do {
                branches = try await api.branches(projectID: projectID, search: search)
                error = nil
            } catch is CancellationError {
            } catch {
                self.error = error.localizedDescription
            }
        }
    }
}
