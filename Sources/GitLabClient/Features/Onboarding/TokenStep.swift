import SwiftUI
import GitLabClientCore

/// State for step 2, shared with the flow's footer (Back / Connect).
@MainActor
@Observable
final class TokenEntryModel {
    var token = ""
    var reveal = false
    private(set) var isConnecting = false
    var error: String?
    var generated = false

    var canConnect: Bool { !token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !isConnecting }

    /// Validates with GET /user and /personal_access_tokens/self, then saves to the Keychain.
    func connect(entry: DomainEntryModel, model: AppModel) async -> OnboardingFlow.Connected? {
        guard let parsed = entry.parsed else { return nil }
        let value = token.trimmingCharacters(in: .whitespacesAndNewlines)
        isConnecting = true
        error = nil
        defer { isConnecting = false }
        do {
            let (user, info) = try await AppModel.validate(token: value, baseURL: parsed.baseURL)
            try await model.addDomain(parsed, sshHost: entry.resolvedSSHHost, sshPort: entry.resolvedSSHPort, token: value, user: user, info: info)
            return .init(domain: parsed, user: user, info: info, maskedToken: TokenText.masked(value))
        } catch let apiError as GitLabAPIError {
            error = Self.message(for: apiError, host: parsed.key)
        } catch {
            self.error = error.localizedDescription
        }
        return nil
    }

    static func message(for error: GitLabAPIError, host: String) -> String {
        switch error {
        case .unauthorized: return "401: this token is invalid or expired. Check you copied all of it, or generate a new one."
        case .forbidden(let scope): return "403: the token is missing the \(scope ?? "api") scope. Create one with api, or read_api for read-only use."
        case .network(_, let message): return "Can't reach \(host). \(message)"
        default: return error.localizedDescription
        }
    }
}

struct TokenStep: View {
    let entry: DomainEntryModel
    @Bindable var tokenEntry: TokenEntryModel
    let onChangeDomain: () -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Paste a personal access token").font(.system(size: 26, weight: .bold))
                    HStack(spacing: 6) {
                        Image(systemName: "server.rack").foregroundStyle(.green)
                        Text("For **\(entry.parsed?.key ?? "")**. It goes straight into your Keychain.").foregroundStyle(.secondary)
                        Button("Change domain", action: onChangeDomain).buttonStyle(.link)
                    }
                }

                VStack(alignment: .leading, spacing: 6) {
                    TokenField(token: $tokenEntry.token, reveal: $tokenEntry.reveal)
                    if let error = tokenEntry.error {
                        ErrorText(message: error)
                    } else if tokenEntry.generated {
                        Text("Token created over SSH and filled in. The raw ssh output wasn't kept.").font(.caption).foregroundStyle(.green)
                    } else {
                        Text("Starts with glpat-. Give it the api scope so Merge and Rebase work.").font(.caption).foregroundStyle(.secondary)
                    }
                }

                TokenGuide(host: entry.resolvedSSHHost, port: entry.resolvedSSHPort) { newToken in
                    tokenEntry.token = newToken
                    tokenEntry.generated = true
                    tokenEntry.error = nil
                }
            }
            .padding(.bottom, 20)
        }
    }
}

struct TokenField: View {
    @Binding var token: String
    @Binding var reveal: Bool
    var label = "Personal access token"
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label).font(.callout.weight(.semibold))
            HStack(spacing: 0) {
                Image(systemName: "key").foregroundStyle(.secondary).padding(.leading, 12)
                Group {
                    if reveal {
                        TextField("glpat-…", text: $token)
                    } else {
                        SecureField("glpat-…", text: $token)
                    }
                }
                .textFieldStyle(.plain)
                .font(.system(size: 14, design: .monospaced))
                .focused($focused)
                .padding(.horizontal, 10)
                .accessibilityLabel(label)
                Divider()
                Button {
                    reveal.toggle()
                } label: {
                    Image(systemName: reveal ? "eye.slash" : "eye").frame(width: 38, height: 38).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(reveal ? "Hide token" : "Show token")
            }
            .frame(height: 38)
            .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(focused ? Color.accentColor : Color(nsColor: .separatorColor)))
        }
        .onAppear { focused = true }
    }
}

/// "How do I get a token?": generate over SSH, or ask someone with web access.
struct TokenGuide: View {
    let host: String
    let port: Int
    let onGenerated: (String) -> Void

    @State private var expanded = true
    @State private var isGenerating = false
    @State private var failure: String?

    static let tokenName = "gitlab-mac-client"
    static let scopes = ["api", "read_repository"]
    static let days = 30

    private var command: String {
        SSHTokenGenerator.displayCommand(host: host, port: port, name: Self.tokenName, scopes: Self.scopes, days: Self.days)
    }

    var body: some View {
        DisclosureGroup(isExpanded: $expanded) {
            Card {
                optionA.padding(16)
                Divider()
                VStack(alignment: .leading, spacing: 4) {
                    Text("B. Ask someone with web access").font(.callout.weight(.semibold))
                    Text("An admin, or a colleague off the company network, creates one under User Settings → Access tokens.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                .padding(16)
                Divider()
                scopes.padding(16)
            }
            .padding(.top, 8)
        } label: {
            Text("How do I get a token?").font(.callout.weight(.semibold))
        }
    }

    private var optionA: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Text("A. Generate it over SSH").font(.callout.weight(.semibold))
                Pill(text: "Recommended", tone: .green)
                Text("GitLab 16.5 or later").font(.caption).foregroundStyle(.secondary)
            }
            Text("The web UI is blocked, but GitLab can mint a token for the account that owns your SSH key.")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Text(command).font(.system(size: 12, design: .monospaced)).textSelection(.enabled).lineLimit(1).truncationMode(.middle)
                Spacer(minLength: 8)
                Button { Clipboard.copy(command) } label: { Image(systemName: "doc.on.doc") }
                    .buttonStyle(.borderless)
                    .accessibilityLabel("Copy command")
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color(nsColor: .separatorColor)))
            HStack(spacing: 8) {
                Button {
                    Task { await generate() }
                } label: {
                    if isGenerating {
                        HStack(spacing: 6) { ProgressView().controlSize(.small); Text("Running ssh…") }
                    } else {
                        Label("Generate for me", systemImage: "terminal")
                    }
                }
                .disabled(isGenerating || host.isEmpty)
                Button("Copy command") { Clipboard.copy(command) }
                Text("Uses your ~/.ssh/config and ssh-agent.").font(.caption).foregroundStyle(.secondary)
            }
            if let failure { ErrorText(message: failure) }
        }
    }

    private var scopes: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 16) {
                scope("api", "Merge, rebase and rotate. Recommended.")
                scope("read_api", "Read-only. Merge and Rebase are hidden.")
                scope("read_repository", "Optional. git itself uses SSH.")
            }
            Text("Permission denied (publickey) means your key isn't in ssh-agent or isn't on your GitLab account. No token in the output means the server is older than 16.5 or has the command off; use option B.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }

    private func scope(_ name: String, _ text: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(name).font(.caption.monospaced().weight(.semibold))
            Text(text).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func generate() async {
        isGenerating = true
        failure = nil
        defer { isGenerating = false }
        do {
            let token = try await SSHTokenGenerator.generate(host: host, port: port, name: Self.tokenName, scopes: Self.scopes, days: Self.days)
            onGenerated(token)
        } catch {
            failure = error.localizedDescription
        }
    }
}
