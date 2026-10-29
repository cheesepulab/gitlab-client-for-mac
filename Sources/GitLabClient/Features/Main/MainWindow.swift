import SwiftUI
import GitLabClientCore

struct MainWindow: View {
    @Environment(AppModel.self) private var model
    @State private var selection: Project?

    var body: some View {
        @Bindable var model = model
        NavigationSplitView {
            if let domain = model.current {
                SidebarView(domain: domain, list: model.repoList(for: domain), selection: $selection)
                    .navigationSplitViewColumnWidth(min: 240, ideal: 270, max: 360)
            }
        } detail: {
            VStack(spacing: 0) {
                if let domain = model.current {
                    ExpiryBanner(domain: domain)
                }
                if let domain = model.current, let project = selection {
                    RepoView(domain: domain, project: project)
                        .id("\(domain.key)/\(project.id)")
                } else {
                    ContentUnavailableView("Pick a repository", systemImage: "books.vertical",
                                           description: Text("Your repositories on \(model.current?.key ?? "this domain") are in the sidebar."))
                }
            }
        }
        .frame(minWidth: 980, minHeight: 640)
        .onChange(of: model.currentKey) { _, _ in selection = nil }
        .sheet(isPresented: $model.showAddDomain) {
            OnboardingFlow(mode: .addDomain)
        }
        .sheet(item: $model.reauthRequest) { request in
            ReauthSheet(domainKey: request.domainKey)
        }
    }
}

/// Shown when the current domain's token has fewer than 7 days left.
struct ExpiryBanner: View {
    let domain: GitLabDomain
    @Environment(AppModel.self) private var model
    @State private var replacing = false
    @State private var working = false
    @State private var error: String?

    var body: some View {
        if let account = model.accounts[domain.key], let days = account.daysLeft, days < 7,
           !model.dismissedExpiryBanners.contains(domain.key), account.state == .ok {
            HStack(spacing: 10) {
                Image(systemName: "clock").foregroundStyle(.orange)
                Group {
                    if days < 0 {
                        Text("Your token for **\(domain.key)** has expired.")
                    } else {
                        Text("Your token for **\(domain.key)** expires in \(days) day\(days == 1 ? "" : "s"), on \(account.token?.expiryText ?? "").")
                    }
                }
                .font(.callout)
                if let error { Text(error).font(.caption).foregroundStyle(.red).lineLimit(2) }
                Spacer()
                if !account.rotateUnsupported && account.canWrite {
                    Button {
                        Task {
                            working = true
                            defer { working = false }
                            do { try await model.rotateToken(for: domain) } catch { self.error = error.localizedDescription }
                        }
                    } label: {
                        if working { ProgressView().controlSize(.small) } else { Text("Rotate now") }
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                }
                Button("Replace…") { replacing = true }.controlSize(.small)
                Button {
                    model.dismissedExpiryBanners.insert(domain.key)
                } label: {
                    Image(systemName: "xmark")
                }
                .buttonStyle(.borderless)
                .accessibilityLabel("Dismiss")
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 9)
            .background(Color.orange.opacity(0.12))
            .overlay(alignment: .bottom) { Divider() }
            .sheet(isPresented: $replacing) { ReplaceTokenSheet(domain: domain) }
        }
    }
}

/// A request got 401: ask for a new token over the current window, then the request retries.
struct ReauthSheet: View {
    let domainKey: String
    @Environment(AppModel.self) private var model
    @State private var token = ""
    @State private var reveal = false
    @State private var working = false
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label("Sign in to \(domainKey) again", systemImage: "key.fill").font(.title3.bold())
            Text("GitLab rejected the token (401). It may have expired or been revoked. Paste a new one and the app picks up where it left off.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            TokenField(token: $token, reveal: $reveal)
            if let error { ErrorText(message: error) }
            if let domain = model.domains.first(where: { $0.key == domainKey }) {
                TokenGuide(host: domain.sshHost, port: domain.sshPort) { token = $0 }
            }
            HStack {
                Spacer()
                Button("Cancel") { model.finishReauth(domainKey: domainKey, succeeded: false) }
                    .keyboardShortcut(.cancelAction)
                Button {
                    Task {
                        working = true
                        defer { working = false }
                        do {
                            try await model.completeReauth(domainKey: domainKey, token: token.trimmingCharacters(in: .whitespacesAndNewlines))
                        } catch let apiError as GitLabAPIError {
                            error = TokenEntryModel.message(for: apiError, host: domainKey)
                        } catch {
                            self.error = error.localizedDescription
                        }
                    }
                } label: {
                    if working { ProgressView().controlSize(.small) } else { Text("Save and retry") }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(token.trimmingCharacters(in: .whitespaces).isEmpty || working)
            }
        }
        .padding(24)
        .frame(width: 620)
        .interactiveDismissDisabled()
    }
}

/// Paste a new token; it replaces the old one only if GitLab accepts it.
struct ReplaceTokenSheet: View {
    let domain: GitLabDomain
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var token = ""
    @State private var reveal = false
    @State private var working = false
    @State private var error: String?
    var showsGuide = true

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Replace the token for \(domain.key)").font(.title3.bold())
            Text("The new token is checked first. Your current one stays until GitLab accepts the new one.")
                .foregroundStyle(.secondary)
            TokenField(token: $token, reveal: $reveal, label: "New personal access token")
            if let error { ErrorText(message: error) }
            if showsGuide {
                TokenGuide(host: domain.sshHost, port: domain.sshPort) { token = $0 }
            }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button {
                    Task {
                        working = true
                        defer { working = false }
                        do {
                            try await model.replaceToken(for: domain, with: token.trimmingCharacters(in: .whitespacesAndNewlines))
                            dismiss()
                        } catch let apiError as GitLabAPIError {
                            error = TokenEntryModel.message(for: apiError, host: domain.key)
                        } catch {
                            self.error = error.localizedDescription
                        }
                    }
                } label: {
                    if working { ProgressView().controlSize(.small) } else { Text("Replace") }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(token.trimmingCharacters(in: .whitespaces).isEmpty || working)
            }
        }
        .padding(24)
        .frame(width: 620)
    }
}
