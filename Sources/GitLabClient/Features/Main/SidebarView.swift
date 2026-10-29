import SwiftUI
import GitLabClientCore

/// Projects the user is a member of, starred first, with search and a group filter.
@MainActor
@Observable
final class RepoListModel {
    private let api: GitLabAPIClient
    private(set) var projects: [Project] = []
    private(set) var starred: Set<Int> = []
    private(set) var isLoading = false
    private(set) var error: String?
    private(set) var loadedAt: Date?

    init(api: GitLabAPIClient) {
        self.api = api
    }

    func loadIfNeeded() async {
        if loadedAt == nil && !isLoading { await reload() }
    }

    func reload() async {
        isLoading = true
        error = nil
        defer { isLoading = false }
        var collected: [Project] = []
        do {
            async let starredIDs = api.starredProjectIDs()
            for try await page in api.projects() {
                collected += page
                projects = collected
            }
            starred = (try? await starredIDs) ?? []
            loadedAt = .now
        } catch is CancellationError {
        } catch {
            self.error = error.localizedDescription
        }
    }

    var groups: [String] {
        Array(Set(projects.map(\.groupPath))).sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }
}

struct SidebarView: View {
    let domain: GitLabDomain
    let list: RepoListModel
    @Binding var selection: Project?

    @State private var search = ""
    @State private var group: String?

    var body: some View {
        VStack(spacing: 0) {
            DomainSwitcher(domain: domain)
                .padding(.horizontal, 10)
                .padding(.bottom, 6)

            List(selection: $selection) {
                if !starredProjects.isEmpty {
                    Section("Starred") {
                        ForEach(starredProjects) { row($0) }
                    }
                }
                Section(group ?? "Recently active") {
                    ForEach(otherProjects) { row($0) }
                }
            }
            .listStyle(.sidebar)
            .searchable(text: $search, placement: .sidebar, prompt: "Filter repositories")
            .overlay {
                if list.projects.isEmpty {
                    if list.isLoading {
                        ProgressView("Loading repositories…")
                    } else if let error = list.error {
                        ContentUnavailableView {
                            Label("Couldn't load repositories", systemImage: "exclamationmark.triangle")
                        } description: {
                            Text(error)
                        } actions: {
                            Button("Try again") { Task { await list.reload() } }
                        }
                    } else if list.loadedAt != nil {
                        ContentUnavailableView("No repositories", systemImage: "tray", description: Text("You're not a member of any project on \(domain.key)."))
                    }
                }
            }

            Divider()
            HStack(spacing: 8) {
                Circle().fill(list.error == nil ? Color.green : Color.orange).frame(width: 7, height: 7)
                Text(footerText).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                Spacer()
                Menu {
                    Button("All groups") { group = nil }
                    Divider()
                    ForEach(list.groups, id: \.self) { name in
                        Button(name) { group = name }
                    }
                } label: {
                    Image(systemName: group == nil ? "line.3.horizontal.decrease.circle" : "line.3.horizontal.decrease.circle.fill")
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .help("Filter by group")
                Button {
                    Task { await list.reload() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.borderless)
                .disabled(list.isLoading)
                .help("Reload repositories")
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
        }
        .task(id: domain.key) {
            await list.loadIfNeeded()
            #if DEBUG
            if selection == nil, let id = Int(DebugSnapshot.value("GLC_DEBUG_PROJECT") ?? "") {
                selection = list.projects.first { $0.id == id }
            }
            #endif
        }
    }

    private func row(_ project: Project) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "book.closed").foregroundStyle(.secondary).font(.caption)
            VStack(alignment: .leading, spacing: 1) {
                Text(project.name).lineLimit(1)
                Text(project.groupPath).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
        }
        .tag(project)
    }

    private var filtered: [Project] {
        list.projects.filter { project in
            (group == nil || project.groupPath == group)
                && (search.isEmpty || project.nameWithNamespace.localizedCaseInsensitiveContains(search) || project.pathWithNamespace.localizedCaseInsensitiveContains(search))
        }
    }

    private var starredProjects: [Project] { filtered.filter { list.starred.contains($0.id) } }
    private var otherProjects: [Project] { filtered.filter { !list.starred.contains($0.id) } }

    private var footerText: String {
        if list.isLoading { return "Loading… \(list.projects.count) so far" }
        if let loaded = list.loadedAt { return "\(list.projects.count) repositories · \(relative(loaded))" }
        return domain.key
    }
}

/// Top of the sidebar: the current domain, and a menu to switch, add or manage domains.
struct DomainSwitcher: View {
    let domain: GitLabDomain
    @Environment(AppModel.self) private var model

    var body: some View {
        Menu {
            Section("Domains") {
                ForEach(Array(model.domains.enumerated()), id: \.element.key) { index, item in
                    Button {
                        model.select(item)
                    } label: {
                        let account = model.accounts[item.key]
                        Text(item.key + (item.key == domain.key ? "  ✓" : ""))
                        Text("@\(item.username ?? "?") · \(account?.statusLine ?? "")")
                    }
                    .keyboardShortcut(index < 9 ? KeyboardShortcut(KeyEquivalent(Character("\(index + 1)")), modifiers: .command) : nil)
                }
            }
            Divider()
            Button("Add Domain…") { model.showAddDomain = true }
            SettingsLink { Text("Manage Domains…") }
        } label: {
            HStack(spacing: 10) {
                Monogram(text: domain.monogram, color: domain.tint)
                VStack(alignment: .leading, spacing: 1) {
                    Text(domain.key).font(.callout.weight(.semibold)).lineLimit(1)
                    Text("@\(model.accounts[domain.key]?.user?.username ?? domain.username ?? "")")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.up.chevron.down").font(.caption).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color(nsColor: .separatorColor)))
            .contentShape(Rectangle())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .accessibilityLabel("Domain: \(domain.key). Switch or add a domain")
    }
}
