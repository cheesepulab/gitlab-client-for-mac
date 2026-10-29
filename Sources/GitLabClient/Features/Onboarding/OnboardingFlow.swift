import SwiftUI
import GitLabClientCore

/// Connect window: 1 domain → 2 token → 3 done. Also shown as a sheet for "Add domain…".
struct OnboardingFlow: View {
    enum Mode { case firstRun, addDomain }
    enum Step: Int { case domain = 1, token, done }

    let mode: Mode
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var step: Step = .domain
    @State private var entry = DomainEntryModel()
    @State private var tokenEntry = TokenEntryModel()
    @State private var connected: Connected?

    struct Connected {
        var domain: ParsedDomain
        var user: GitLabUser
        var info: TokenInfo
        var maskedToken: String
    }

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 22) {
                StepIndicator(current: step)
                switch step {
                case .domain:
                    DomainStep(entry: entry)
                case .token:
                    TokenStep(entry: entry, tokenEntry: tokenEntry, onChangeDomain: { step = .domain })
                case .done:
                    if let connected { ConnectedStep(connected: connected) }
                }
            }
            .frame(maxWidth: 648)
            .padding(.horizontal, 56)
            .padding(.top, 26)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)

            Divider()
            footer.frame(maxWidth: 700).footerBar()
        }
        .frame(width: mode == .addDomain ? 760 : nil, height: mode == .addDomain ? 720 : nil)
        .frame(minWidth: 760, minHeight: 720)
        .onAppear { entry.knownKeys = Set(model.domains.filter { model.accounts[$0.key]?.state != .noToken }.map(\.key)) }
    }

    /// First run swaps to the main window; "Add domain…" closes its sheet.
    private func finish() {
        if mode == .firstRun { model.isOnboarding = false } else { dismiss() }
    }

    @ViewBuilder private var footer: some View {
        switch step {
        case .domain:
            HStack {
                Text("Not sure? It's the host in your team's clone URLs: git@**domain**:group/repo.git")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button(mode == .firstRun ? "Quit" : "Cancel") {
                    if mode == .firstRun { NSApp.terminate(nil) } else { dismiss() }
                }
                .keyboardShortcut(.cancelAction)
                if entry.isAlreadyAdded, let parsed = entry.parsed {
                    Button("Switch to \(parsed.key)") {
                        if let domain = model.domains.first(where: { $0.key == parsed.key }) { model.select(domain) }
                        finish()
                    }
                    .keyboardShortcut(.defaultAction)
                } else {
                    Button("Continue") { step = .token }
                        .keyboardShortcut(.defaultAction)
                        .disabled(!entry.canContinue)
                }
            }
        case .token:
            HStack {
                Text("Pick a lifetime of 30 to 90 days.").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Back") { step = .domain }
                    .keyboardShortcut(.cancelAction)
                Button {
                    Task {
                        if let result = await tokenEntry.connect(entry: entry, model: model) {
                            connected = result
                            step = .done
                        }
                    }
                } label: {
                    if tokenEntry.isConnecting { ProgressView().controlSize(.small) } else { Text("Connect") }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!tokenEntry.canConnect)
            }
        case .done:
            HStack {
                Button {
                    entry = DomainEntryModel()
                    tokenEntry = TokenEntryModel()
                    entry.knownKeys = Set(model.domains.map(\.key))
                    connected = nil
                    step = .domain
                } label: {
                    Label("Add another domain", systemImage: "plus")
                }
                .buttonStyle(.link)
                Spacer()
                Button("Open \(AppInfo.name)") { finish() }
                    .keyboardShortcut(.defaultAction)
            }
        }
    }
}

struct StepIndicator: View {
    let current: OnboardingFlow.Step

    var body: some View {
        HStack(spacing: 12) {
            item(.domain, "Domain")
            line(done: current.rawValue > 1)
            item(.token, "Access token")
            line(done: current.rawValue > 2)
            item(.done, "Done")
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Setup progress, step \(current.rawValue) of 3")
    }

    private func item(_ step: OnboardingFlow.Step, _ title: String) -> some View {
        HStack(spacing: 8) {
            ZStack {
                if step.rawValue < current.rawValue {
                    Circle().fill(.green)
                    Image(systemName: "checkmark").font(.system(size: 10, weight: .bold)).foregroundStyle(.white)
                } else if step == current {
                    Circle().fill(Color.accentColor)
                    Text("\(step.rawValue)").font(.caption.weight(.semibold)).foregroundStyle(.white)
                } else {
                    Circle().strokeBorder(.tertiary)
                    Text("\(step.rawValue)").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                }
            }
            .frame(width: 22, height: 22)
            Text(title)
                .font(.callout.weight(step == current ? .semibold : .regular))
                .foregroundStyle(step.rawValue > current.rawValue ? .secondary : .primary)
        }
    }

    private func line(done: Bool) -> some View {
        Rectangle().fill(done ? AnyShapeStyle(.green) : AnyShapeStyle(.quaternary)).frame(height: 1)
    }
}

// MARK: - Step 1: domain

/// Parses what the user types and runs the API and SSH checks 600 ms after typing stops.
@MainActor
@Observable
final class DomainEntryModel {
    var text = "" { didSet { if text != oldValue { scheduleCheck() } } }
    var sshHost = ""
    var sshPort = "22"
    var showAdvanced = false
    private(set) var parsed: ParsedDomain?
    private(set) var api: CheckState = .pending
    private(set) var ssh: CheckState = .pending
    private(set) var isChecking = false
    var knownKeys: Set<String> = []
    private var task: Task<Void, Never>?

    var isAlreadyAdded: Bool { parsed.map { knownKeys.contains($0.key) } ?? false }
    var canContinue: Bool { parsed != nil && api.isPassed && !isChecking }
    var resolvedSSHHost: String { sshHost.isEmpty ? (parsed?.host ?? "") : sshHost }
    var resolvedSSHPort: Int { Int(sshPort) ?? 22 }

    func scheduleCheck() {
        task?.cancel()
        parsed = DomainParser.parse(text)
        api = .pending
        ssh = .pending
        guard let parsed, !isAlreadyAdded else { isChecking = false; return }
        isChecking = true
        let host = resolvedSSHHost
        let port = resolvedSSHPort
        task = Task {
            try? await Task.sleep(for: .milliseconds(600))
            guard !Task.isCancelled else { return }
            async let apiResult = DomainChecker.checkAPI(baseURL: parsed.baseURL)
            async let sshResult = DomainChecker.checkSSH(host: host, port: port)
            let (apiState, sshState) = await (apiResult, sshResult)
            guard !Task.isCancelled else { return }
            api = apiState
            ssh = sshState
            isChecking = false
        }
    }

    var tlsState: CheckState {
        switch api {
        case .pending: return .pending
        case .passed: return .passed("macOS trusts the certificate, so no exception is needed.")
        case .failed(let message) where message.contains("certificate"): return .failed(message)
        case .failed, .warning: return .warning("Waiting for the API to answer.")
        }
    }
}

private struct DomainStep: View {
    @Bindable var entry: DomainEntryModel
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            VStack(alignment: .leading, spacing: 8) {
                Text("Add your GitLab domain").font(.system(size: 26, weight: .bold))
                Text("Start with the server your team uses. The app checks that its API and SSH answer before it asks you for a token.")
                    .foregroundStyle(.secondary)
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("GitLab domain").font(.callout.weight(.semibold))
                HStack(spacing: 0) {
                    Text("https://")
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 10)
                        .frame(maxHeight: .infinity)
                        .background(.quaternary.opacity(0.5))
                    Divider()
                    TextField("gitlab.example.com", text: $entry.text)
                        .textFieldStyle(.plain)
                        .font(.system(size: 15))
                        .focused($focused)
                        .padding(.horizontal, 10)
                        .accessibilityLabel("GitLab domain")
                    statusIcon.padding(.trailing, 10)
                }
                .frame(height: 38)
                .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(focused ? Color.accentColor : Color(nsColor: .separatorColor)))
                .clipShape(RoundedRectangle(cornerRadius: 8))
                Text(helper).font(.caption).foregroundStyle(.secondary)
            }

            Card {
                if entry.parsed == nil {
                    HStack(spacing: 10) {
                        Image(systemName: "server.rack").foregroundStyle(.secondary)
                        Text("Enter a domain and the checks start on their own.").foregroundStyle(.secondary)
                        Spacer()
                        Button("Use gitlab.com") { entry.text = "gitlab.com" }.buttonStyle(.link)
                    }
                    .padding(16)
                } else if entry.isAlreadyAdded {
                    CheckRow(title: "Already added", state: .passed("\(entry.parsed?.key ?? "") is already in your domains."))
                } else {
                    CheckRow(title: "REST API reachable", state: entry.api)
                    Divider()
                    CheckRow(title: "SSH reachable", state: entry.ssh)
                    Divider()
                    CheckRow(title: "HTTPS certificate trusted", state: entry.tlsState)
                }
            }

            DisclosureGroup("Advanced: SSH host and port", isExpanded: $entry.showAdvanced) {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 12) {
                        TextField("SSH host", text: $entry.sshHost, prompt: Text(entry.parsed?.host ?? "same as the domain"))
                        TextField("Port", text: $entry.sshPort).frame(width: 80)
                        Button("Check again") { entry.scheduleCheck() }
                    }
                    Text("Change these only when SSH runs on another host, such as ssh.gitlab.example.com:443.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                .padding(.top, 8)
            }
        }
        .onAppear {
            focused = true
            #if DEBUG
            if entry.text.isEmpty, let domain = DebugSnapshot.prefilledDomain { entry.text = domain }
            #endif
        }
    }

    private var helper: String {
        guard let parsed = entry.parsed else { return "Type the domain or paste any URL from it." }
        return "API: \(parsed.baseURL.absoluteString)/api/v4 · SSH: git@\(entry.resolvedSSHHost)"
    }

    @ViewBuilder private var statusIcon: some View {
        if entry.isChecking {
            ProgressView().controlSize(.small)
        } else if entry.api.isPassed {
            Image(systemName: "checkmark.circle").foregroundStyle(.green).accessibilityLabel("Domain verified")
        } else if entry.api.isFailure {
            Image(systemName: "xmark.circle").foregroundStyle(.red)
        }
    }
}

// MARK: - Step 3: connected

private struct ConnectedStep: View {
    let connected: OnboardingFlow.Connected

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            HStack(spacing: 16) {
                Image(systemName: "checkmark.shield")
                    .font(.system(size: 22))
                    .foregroundStyle(.green)
                    .frame(width: 48, height: 48)
                    .background(.green.opacity(0.15), in: Circle())
                VStack(alignment: .leading, spacing: 4) {
                    Text("Connected to \(connected.domain.key)").font(.system(size: 26, weight: .bold))
                    Text("The token checked out and is saved in your Keychain.").foregroundStyle(.secondary)
                }
            }

            Card {
                HStack(spacing: 12) {
                    InitialsAvatar(initials: connected.user.initials)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(connected.user.name).font(.headline)
                        Text("@\(connected.user.username) · \(connected.domain.key)").font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Pill(text: "Signed in", tone: .green)
                }
                .padding(14)
                Divider()
                DetailRow(label: "Token name") { Text(connected.info.name) }
                Divider()
                DetailRow(label: "Token") { Text(connected.maskedToken).font(.callout.monospaced()) }
                Divider()
                DetailRow(label: "Scopes") { ScopeChips(scopes: connected.info.scopes) }
                Divider()
                DetailRow(label: "Expires") {
                    if let days = connected.info.daysLeft() {
                        Text("\(connected.info.expiryText) ") + Text("· \(days) days left").foregroundStyle(.secondary)
                    } else {
                        Text("Never")
                    }
                }
                Divider()
                DetailRow(label: "Stored in") { Text("Keychain ") + Text("· \(AppInfo.keychainService) · \(connected.domain.key)").foregroundStyle(.secondary) }
            }

            if !connected.info.canWrite {
                Label("Read-only token: Merge and Rebase stay hidden until you use a token with the api scope.", systemImage: "eye")
                    .font(.callout).foregroundStyle(.orange)
            }
            Label("Add more domains later from the domain menu at the top of the sidebar, or in Settings → Domains.", systemImage: "info.circle")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}
