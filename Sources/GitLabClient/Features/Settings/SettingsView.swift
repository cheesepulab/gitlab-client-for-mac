import SwiftUI
import GitLabClientCore

struct SettingsView: View {
    @AppStorage("settingsTab") private var tab = "domains"

    var body: some View {
        TabView(selection: $tab) {
            DomainsSettings().tabItem { Label("Domains", systemImage: "server.rack") }.tag("domains")
            AISettings().tabItem { Label("AI CLI", systemImage: "sparkles") }.tag("ai")
            GitSettings().tabItem { Label("Git", systemImage: "arrow.triangle.branch") }.tag("git")
            GeneralSettings().tabItem { Label("General", systemImage: "gearshape") }.tag("general")
        }
        .frame(width: 880, height: 680)
    }
}

// MARK: - Domains

private struct DomainsSettings: View {
    @Environment(AppModel.self) private var model
    @State private var selection: String?
    @State private var confirmRemove = false

    var body: some View {
        @Bindable var model = model
        HStack(alignment: .top, spacing: 20) {
            VStack(spacing: 0) {
                List(selection: $selection) {
                    ForEach(model.domains) { domain in
                        HStack(spacing: 10) {
                            Monogram(text: domain.monogram, color: domain.tint)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(domain.key).fontWeight(.semibold)
                                Text((model.domains.first == domain ? "Default · " : "") + (model.accounts[domain.key]?.statusLine ?? ""))
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        .padding(.vertical, 3)
                        .tag(domain.key)
                    }
                }
                Divider()
                HStack(spacing: 0) {
                    Button { model.showAddDomain = true } label: { Image(systemName: "plus").frame(width: 28, height: 24) }
                        .accessibilityLabel("Add domain")
                    Divider().frame(height: 18)
                    Button { confirmRemove = true } label: { Image(systemName: "minus").frame(width: 28, height: 24) }
                        .disabled(selectedDomain == nil)
                        .accessibilityLabel("Remove domain")
                    Spacer()
                    Button("Make default") { if let selectedDomain { model.makeDefault(selectedDomain) } }
                        .disabled(selectedDomain == nil || selectedDomain == model.domains.first)
                        .font(.caption)
                        .padding(.trailing, 8)
                }
                .buttonStyle(.borderless)
                .padding(.vertical, 3)
            }
            .frame(width: 250)
            .background(Color(nsColor: .controlBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color(nsColor: .separatorColor)))

            if let domain = selectedDomain {
                DomainDetail(domain: domain).id(domain.key)
            } else {
                ContentUnavailableView("No domain selected", systemImage: "server.rack")
            }
        }
        .padding(20)
        .onAppear { selection = selection ?? model.current?.key }
        .sheet(isPresented: $model.showAddDomain) { OnboardingFlow(mode: .addDomain).environment(model) }
        .confirmationDialog("Remove \(selectedDomain?.key ?? "")?", isPresented: $confirmRemove) {
            Button("Remove and delete local clones", role: .destructive) { remove(deleteClones: true) }
            Button("Remove, keep local clones") { remove(deleteClones: false) }
        } message: {
            Text("The token is deleted from your Keychain. It stays valid on the server; revoke it first if you want it gone.")
        }
    }

    private var selectedDomain: GitLabDomain? { model.domains.first { $0.key == selection } }

    private func remove(deleteClones: Bool) {
        guard let domain = selectedDomain else { return }
        Task {
            await model.removeDomain(domain, deleteClones: deleteClones)
            selection = model.domains.first?.key
        }
    }
}

private struct DomainDetail: View {
    let domain: GitLabDomain
    @Environment(AppModel.self) private var model
    @State private var replacing = false
    @State private var working: String?
    @State private var message: String?
    @State private var confirmRevoke = false
    @State private var confirmSignOut = false

    private var account: DomainAccount { model.accounts[domain.key] ?? DomainAccount() }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                InitialsAvatar(initials: account.user?.initials ?? domain.monogram, tint: domain.tint)
                VStack(alignment: .leading, spacing: 2) {
                    Text(domain.key).font(.title3.bold())
                    Text(account.user.map { "Signed in as \($0.name) (@\($0.username))" } ?? "Last signed in as @\(domain.username ?? "?")")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                statusPill
            }

            switch account.state {
            case .invalid(let reason), .unreachable(let reason):
                Label(reason, systemImage: "exclamationmark.octagon").foregroundStyle(.red).font(.callout)
                    .padding(12).frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.red.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
            case .noToken:
                Label("No token on this Mac. Repositories and merge requests for \(domain.key) stay hidden until you add one.", systemImage: "key")
                    .font(.callout).padding(12).frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.orange.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
            default:
                EmptyView()
            }

            Card {
                DetailRow(label: "Web URL") { Text(domain.baseURL.absoluteString).textSelection(.enabled) }
                Divider()
                DetailRow(label: "SSH") { Text("git@\(domain.sshHost) ") + Text("· port \(domain.sshPort)").foregroundStyle(.secondary) }
                Divider()
                DetailRow(label: "Token") {
                    if let masked = account.maskedToken {
                        Text(masked).font(.callout.monospaced()) + Text(account.token.map { " · \($0.name)" } ?? "").foregroundStyle(.secondary)
                    } else {
                        Text("None").foregroundStyle(.secondary)
                    }
                }
                Divider()
                DetailRow(label: "Scopes") { if let token = account.token { ScopeChips(scopes: token.scopes) } else { Text("—").foregroundStyle(.secondary) } }
                Divider()
                DetailRow(label: "Expires") {
                    if let token = account.token, let days = token.daysLeft() {
                        Text("\(token.expiryText) ") + Text("· \(days < 0 ? "expired" : "\(days) days left")").foregroundStyle(days < 7 ? .orange : .secondary)
                    } else {
                        Text(account.token == nil ? "—" : "Never")
                    }
                }
            }

            HStack(spacing: 8) {
                if account.state == .noToken || account.token == nil {
                    Button("Add a new token…") { replacing = true }.buttonStyle(.borderedProminent)
                } else {
                    if !account.rotateUnsupported && account.canWrite {
                        busyButton("Rotate token", id: "rotate", prominent: true) {
                            try await model.rotateToken(for: domain)
                            message = "Rotated. The new token is in your Keychain."
                        }
                    }
                    Button("Replace…") { replacing = true }
                }
                busyButton("Generate via SSH…", id: "ssh") {
                    let token = try await SSHTokenGenerator.generate(host: domain.sshHost, port: domain.sshPort, name: TokenGuide.tokenName,
                                                                     scopes: TokenGuide.scopes, days: TokenGuide.days)
                    try await model.replaceToken(for: domain, with: token)
                    message = "A new token was created over SSH and saved."
                }
                Spacer()
                if account.maskedToken != nil {
                    Button("Sign out") { confirmSignOut = true }
                    Button("Revoke…", role: .destructive) { confirmRevoke = true }.disabled(!account.canWrite && account.token != nil)
                }
            }
            if let message { Text(message).font(.caption).foregroundStyle(message.hasPrefix("Error") ? .red : .secondary) }
            Text("Replace checks the new token first and swaps it in only if it works. Sign out removes it from this Mac only; Revoke also kills it on the server.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Spacer()
            Text("Each domain keeps its own Keychain item (account = \(domain.key)) and its own clones under …/GitLabClient/repos/\(domain.folderName)/.")
                .font(.caption2).foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .sheet(isPresented: $replacing) { ReplaceTokenSheet(domain: domain).environment(model) }
        .confirmationDialog("Revoke the token for \(domain.key)?", isPresented: $confirmRevoke) {
            Button("Revoke", role: .destructive) {
                run("revoke") { try await model.revokeToken(for: domain) }
            }
        } message: {
            Text("GitLab deletes the token, so it stops working everywhere. You'll need a new one to use \(domain.key).")
        }
        .confirmationDialog("Sign out of \(domain.key)?", isPresented: $confirmSignOut) {
            Button("Sign out") { Task { await model.signOut(of: domain) } }
        } message: {
            Text("The token is removed from this Mac's Keychain only. It stays valid on the server until it expires or you revoke it.")
        }
    }

    @ViewBuilder private var statusPill: some View {
        switch account.state {
        case .ok: Pill(text: "API and token OK", tone: .green)
        case .loading: ProgressView().controlSize(.small)
        case .noToken: Pill(text: "No token", tone: .orange)
        case .invalid: Pill(text: "Token rejected", tone: .red)
        case .unreachable: Pill(text: "Unreachable", tone: .orange)
        }
    }

    private func busyButton(_ title: String, id: String, prominent: Bool = false, action: @escaping () async throws -> Void) -> some View {
        Button {
            run(id, action)
        } label: {
            if working == id { ProgressView().controlSize(.small) } else { Text(title) }
        }
        .disabled(working != nil)
        .buttonStyle(prominent ? AnyPrimitiveButtonStyle(.borderedProminent) : AnyPrimitiveButtonStyle(.automatic))
    }

    private func run(_ id: String, _ action: @escaping () async throws -> Void) {
        Task {
            working = id
            message = nil
            defer { working = nil }
            do { try await action() } catch { message = "Error: \(error.localizedDescription)" }
        }
    }
}

struct AnyPrimitiveButtonStyle: PrimitiveButtonStyle {
    private let make: (Configuration) -> AnyView

    init<S: PrimitiveButtonStyle>(_ style: S) {
        make = { AnyView(style.makeBody(configuration: $0)) }
    }

    func makeBody(configuration: Configuration) -> some View { make(configuration) }
}

// MARK: - AI CLI

@MainActor
@Observable
final class AIDetection {
    private(set) var found: [String: String] = [:]
    private(set) var checkedAt: Date?

    func scan() async {
        var result: [String: String] = [:]
        for preset in AIPreset.all {
            if let name = preset.binaryName, let path = await ShellEnvironment.shared.which(name) { result[preset.id] = path }
        }
        found = result
        checkedAt = .now
    }
}

private struct AISettings: View {
    @Environment(AppSettings.self) private var settings
    @State private var detection = AIDetection()
    @State private var selected = AIPreset.claude.id
    @State private var task: AITask = .rebaseOntoTarget
    @State private var testOutput: String?
    @State private var testOK: Bool?
    @State private var testing = false
    @State private var choosingBinary = false

    private var preset: AIPreset { AIPreset.with(id: selected) }

    var body: some View {
        @Bindable var settings = settings
        HStack(alignment: .top, spacing: 20) {
            VStack(alignment: .leading, spacing: 8) {
                Text("Command-line AI").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                VStack(spacing: 0) {
                    List(AIPreset.all, selection: $selected) { item in
                        HStack(spacing: 10) {
                            Monogram(text: mark(item), color: color(item))
                            VStack(alignment: .leading, spacing: 1) {
                                Text(item.name).fontWeight(.semibold)
                                Text(status(item)).font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            if settings.aiPresetID == item.id { Image(systemName: "checkmark").foregroundStyle(Color.accentColor).accessibilityLabel("In use") }
                        }
                        .padding(.vertical, 3)
                        .tag(item.id)
                    }
                    Divider()
                    HStack {
                        Text(detection.checkedAt.map { "Checked \(relative($0))" } ?? "Checking…").font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        Button("Scan again") { Task { await detection.scan() } }.buttonStyle(.link).font(.caption)
                    }
                    .padding(.horizontal, 10).padding(.vertical, 6)
                }
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color(nsColor: .separatorColor)))
                Text("Found with your login shell: /bin/zsh -lc 'command -v <name>'.").font(.caption).foregroundStyle(.secondary)
            }
            .frame(width: 230)

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(preset.name).font(.title3.bold())
                            Text(preset.summary).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        if settings.aiPresetID == preset.id {
                            Pill(text: "Used for AI tasks", tone: .green)
                        } else {
                            Button("Use \(preset.name)") { settings.aiPresetID = preset.id }.buttonStyle(.borderedProminent)
                        }
                    }

                    VStack(alignment: .leading, spacing: 6) {
                        Text("Binary").font(.caption.weight(.semibold))
                        HStack {
                            TextField(binaryPlaceholder, text: binaryBinding)
                                .font(.callout.monospaced())
                            Button("Choose…") { choosingBinary = true }
                        }
                        binaryStatus
                    }

                    VStack(alignment: .leading, spacing: 6) {
                        Text("Command template").font(.caption.weight(.semibold))
                        TextField("", text: templateBinding).font(.callout.monospaced())
                        HStack(spacing: 6) {
                            Text("Insert:").font(.caption).foregroundStyle(.secondary)
                            ForEach(CommandTemplate.placeholders, id: \.self) { name in
                                Button("{\(name)}") { templateBinding.wrappedValue += " {\(name)}" }
                                    .font(.caption.monospaced())
                                    .buttonStyle(.bordered)
                                    .controlSize(.small)
                            }
                            Spacer()
                            if settings.aiTemplates[preset.id] != nil {
                                Button("Restore default") { settings.aiTemplates[preset.id] = nil }.buttonStyle(.link).font(.caption)
                            }
                        }
                        if let problem = templateProblem {
                            Text(problem).font(.caption).foregroundStyle(.red)
                        } else {
                            Text("Runs with the worktree as its working folder. No shell is involved, so quotes only group words.")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }

                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text("Prompt for each task").font(.caption.weight(.semibold))
                            Spacer()
                            Picker("Task", selection: $task) {
                                ForEach(AITask.allCases) { Text($0.title).tag($0) }
                            }
                            .pickerStyle(.segmented)
                            .labelsHidden()
                            .fixedSize()
                        }
                        VStack(spacing: 0) {
                            TextEditor(text: promptBinding)
                                .font(.system(size: 12, design: .monospaced))
                                .frame(height: 130)
                                .scrollContentBackground(.hidden)
                                .padding(6)
                            Divider()
                            Label {
                                Text("Always added, can't be edited: ") + Text(AIPrompt.safetyRules).font(.caption.monospaced())
                            } icon: {
                                Image(systemName: "lock")
                            }
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(8)
                            .background(.quaternary.opacity(0.4))
                        }
                        .background(Color(nsColor: .textBackgroundColor))
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color(nsColor: .separatorColor)))
                        HStack {
                            Text("{conflicted_files} is filled in with one path per line. The app does every git step itself; the CLI only edits files.")
                                .font(.caption).foregroundStyle(.secondary)
                            Spacer()
                            if settings.aiPrompts[task.rawValue] != nil {
                                Button("Restore default") { settings.aiPrompts[task.rawValue] = nil }.buttonStyle(.link).font(.caption)
                            }
                        }
                    }

                    Divider()
                    HStack(spacing: 10) {
                        Text("Stop after").font(.caption.weight(.semibold))
                        Stepper(value: $settings.aiTimeoutMinutes, in: 1...60) {
                            Text("\(settings.aiTimeoutMinutes) minutes").monospacedDigit()
                        }
                        .fixedSize()
                        Spacer()
                        Button {
                            Task { await test() }
                        } label: {
                            if testing { ProgressView().controlSize(.small) } else { Label("Test \(preset.name)", systemImage: "terminal") }
                        }
                        .disabled(testing || resolvedBinary == nil || templateProblem != nil)
                    }
                    testPanel
                }
                .padding(.trailing, 8)
            }
        }
        .padding(20)
        .task { await detection.scan() }
        .onAppear { selected = settings.aiPresetID }
        .onChange(of: selected) { _, _ in testOutput = nil; testOK = nil }
        .fileImporter(isPresented: $choosingBinary, allowedContentTypes: [.unixExecutable, .item]) { result in
            if case .success(let url) = result { settings.aiBinaryPaths[preset.id] = url.path }
        }
    }

    private func color(_ preset: AIPreset) -> Color {
        switch preset.id {
        case "claude": return .purple
        case "codex": return .indigo
        case "gemini": return .blue
        case "aider": return .green
        default: return .gray
        }
    }

    private func mark(_ preset: AIPreset) -> String {
        switch preset.id {
        case "claude": return "CC"
        case "codex": return "CX"
        case "gemini": return "GE"
        case "aider": return "AI"
        default: return "{ }"
        }
    }

    private func status(_ preset: AIPreset) -> String {
        if settings.aiPresetID == preset.id { return "In use" }
        if settings.aiBinaryPaths[preset.id] != nil || detection.found[preset.id] != nil { return "Found" }
        return preset.binaryName == nil ? "Your own command" : "Not installed"
    }

    private var binaryPlaceholder: String { detection.found[preset.id] ?? (preset.binaryName == nil ? "/path/to/your/cli" : "Not installed") }

    private var binaryBinding: Binding<String> {
        Binding(get: { settings.aiBinaryPaths[preset.id] ?? "" },
                set: { settings.aiBinaryPaths[preset.id] = $0.isEmpty ? nil : $0 })
    }

    private var templateBinding: Binding<String> {
        Binding(get: { settings.template(for: preset) },
                set: { settings.aiTemplates[preset.id] = $0 == preset.defaultTemplate ? nil : $0 })
    }

    private var promptBinding: Binding<String> {
        Binding(get: { settings.prompt(for: task) },
                set: { settings.aiPrompts[task.rawValue] = $0 == task.defaultPrompt ? nil : $0 })
    }

    private var resolvedBinary: String? {
        if let chosen = settings.aiBinaryPaths[preset.id], !chosen.isEmpty { return chosen }
        if let found = detection.found[preset.id] { return found }
        if preset.binaryName == nil, let first = try? CommandTemplate.tokenize(settings.template(for: preset)).first, first.hasPrefix("/") { return first }
        return nil
    }

    private var templateProblem: String? {
        do { try CommandTemplate.validate(settings.template(for: preset)); return nil } catch { return error.localizedDescription }
    }

    @ViewBuilder private var binaryStatus: some View {
        if let path = resolvedBinary, FileManager.default.isExecutableFile(atPath: path) {
            Label("Found at \(path)", systemImage: "checkmark.circle").font(.caption).foregroundStyle(.green)
        } else if preset.binaryName == nil {
            Text("Any executable. The template below decides its arguments.").font(.caption).foregroundStyle(.secondary)
        } else {
            Label("Not on your PATH. Install \(preset.name), or pick its binary with Choose…", systemImage: "exclamationmark.triangle")
                .font(.caption).foregroundStyle(.orange)
        }
    }

    @ViewBuilder private var testPanel: some View {
        VStack(alignment: .leading, spacing: 4) {
            if testing {
                Text("Waiting for an answer…").foregroundStyle(Color(white: 0.7))
            } else if let testOutput {
                Text(testOutput.isEmpty ? "(no output)" : String(testOutput.prefix(1500))).foregroundStyle(Color(white: 0.9))
                if let testOK {
                    Label(testOK ? "Works and is signed in" : "The CLI exited with an error. Check it's installed and signed in.",
                          systemImage: testOK ? "checkmark" : "xmark")
                        .font(.caption).foregroundStyle(testOK ? .green : .red)
                }
            } else {
                Text("Runs the CLI once in an empty temporary folder with a prompt asking it to reply OK.").foregroundStyle(Color(white: 0.6))
            }
        }
        .font(.system(size: 11, design: .monospaced))
        .textSelection(.enabled)
        .frame(maxWidth: .infinity, minHeight: 48, alignment: .topLeading)
        .padding(12)
        .background(Color(white: 0.11), in: RoundedRectangle(cornerRadius: 8))
    }

    private func test() async {
        guard let binary = resolvedBinary else { return }
        testing = true
        defer { testing = false }
        do {
            let result = try await AICLITester.test(executable: binary, template: settings.template(for: preset))
            testOutput = result.output + String(format: "\n— answered in %.1f s", result.seconds)
            testOK = result.succeeded
        } catch {
            testOutput = error.localizedDescription
            testOK = false
        }
    }
}

// MARK: - Git

private struct GitSettings: View {
    @Environment(AppModel.self) private var model
    @Environment(AppSettings.self) private var settings
    @State private var detected: String?

    var body: some View {
        @Bindable var settings = settings
        Form {
            Section {
                TextField("git binary", text: $settings.gitPathOverride, prompt: Text(detected ?? "Looking for git…"))
                    .font(.callout.monospaced())
                    .onSubmit { model.resetGit() }
                Text("Leave empty to use git from your login shell's PATH\(detected.map { " (\($0))" } ?? "").")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section {
                LabeledContent("Clone location") {
                    HStack {
                        Text(settings.reposRoot.path).font(.caption.monospaced()).lineLimit(1).truncationMode(.middle)
                        Button("Show in Finder") {
                            try? FileManager.default.createDirectory(at: settings.reposRoot, withIntermediateDirectories: true)
                            NSWorkspace.shared.activateFileViewerSelecting([settings.reposRoot])
                        }
                    }
                }
                Text("One bare clone per project, cloned over SSH. Your own checkouts are never touched.").font(.caption).foregroundStyle(.secondary)
            }
            Section("Resolving conflicts with AI") {
                Picker("Strategy", selection: $settings.conflictStrategy) {
                    ForEach(ConflictStrategy.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.radioGroup)
            }
            Section("Default merge options") {
                Picker("Squash commits", selection: $settings.squashDefault) {
                    ForEach(MergeOptionDefault.allCases) { Text($0.title).tag($0) }
                }
                Picker("Delete source branch", selection: $settings.deleteSourceDefault) {
                    ForEach(MergeOptionDefault.allCases) { Text($0.title).tag($0) }
                }
            }
        }
        .formStyle(.grouped)
        .task { detected = await GitService.resolveGit(override: nil) }
        .onChange(of: settings.gitPathOverride) { _, _ in model.resetGit() }
    }
}

// MARK: - General

private struct GeneralSettings: View {
    @Environment(AppModel.self) private var model
    @Environment(AppSettings.self) private var settings
    @State private var cacheSize: Int64?
    @State private var confirmClear = false

    var body: some View {
        @Bindable var settings = settings
        Form {
            Section {
                Picker("Appearance", selection: $settings.appearance) {
                    ForEach(Appearance.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
            }
            Section {
                Picker("Refresh an open merge request every", selection: $settings.autoRefreshSeconds) {
                    Text("15 seconds").tag(15)
                    Text("30 seconds").tag(30)
                    Text("1 minute").tag(60)
                    Text("5 minutes").tag(300)
                }
                Picker("Default merge request tab", selection: $settings.defaultMRState) {
                    Text("Open").tag("opened")
                    Text("Merged").tag("merged")
                    Text("Closed").tag("closed")
                }
            }
            Section {
                LabeledContent("Local clones") {
                    HStack {
                        Text(cacheSize.map { ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) } ?? "…").monospacedDigit()
                        Button("Clear…", role: .destructive) { confirmClear = true }
                    }
                }
                Text("Clones are made again the next time you open a repository.").font(.caption).foregroundStyle(.secondary)
            }
            Section {
                LabeledContent("Version", value: "\(AppInfo.version) (\(AppInfo.build))")
                if let url = AppInfo.repositoryURL { Link("Source code and issues", destination: url) }
            }
        }
        .formStyle(.grouped)
        .task { await measure() }
        .confirmationDialog("Delete all local clones?", isPresented: $confirmClear) {
            Button("Delete", role: .destructive) {
                Task {
                    if let git = await model.git() { try? await git.clearClones() }
                    await measure()
                }
            }
        }
    }

    private func measure() async {
        let root = settings.reposRoot
        cacheSize = await Task.detached { GitService.folderSize(root) }.value
    }
}
