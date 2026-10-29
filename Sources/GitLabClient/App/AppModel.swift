import AppKit
import GitLabClientCore

/// What the app knows about the signed-in account on one domain.
struct DomainAccount: Equatable {
    enum State: Equatable {
        case loading
        case ok
        case noToken
        case invalid(String)
        case unreachable(String)
    }

    var state: State = .loading
    var user: GitLabUser?
    var token: TokenInfo?
    var maskedToken: String?
    var rotateUnsupported = false

    var daysLeft: Int? { token?.daysLeft() }
    var canWrite: Bool { token?.canWrite ?? true }

    var statusLine: String {
        switch state {
        case .loading: return "Checking…"
        case .noToken: return "No token"
        case .invalid: return "Token expired or invalid"
        case .unreachable: return "Can't reach server"
        case .ok:
            if let days = daysLeft { return days < 0 ? "Token expired" : "\(days) day\(days == 1 ? "" : "s") left" }
            return "Signed in"
        }
    }
}

/// A 401 that is waiting for the user to paste a new token.
struct ReauthRequest: Identifiable, Equatable {
    let domainKey: String
    var id: String { domainKey }
}

@MainActor
@Observable
final class AppModel {
    static let shared = AppModel()

    let settings = AppSettings()
    let tokens = TokenStore(service: AppInfo.keychainService)

    private(set) var domains: [GitLabDomain] = []
    private(set) var accounts: [String: DomainAccount] = [:]
    private(set) var isLoaded = false
    var currentKey: String? { didSet { UserDefaults.standard.set(currentKey, forKey: "currentDomain") } }

    /// The Connect window stays up until the user presses Open, even after a token is saved.
    var isOnboarding = false
    var showAddDomain = false
    var reauthRequest: ReauthRequest?
    var dismissedExpiryBanners: Set<String> = []

    private var clients: [String: GitLabAPIClient] = [:]
    private var reauthWaiters: [String: [CheckedContinuation<Bool, Never>]] = [:]
    private var repoLists: [String: RepoListModel] = [:]
    private var gitService: GitService?
    private(set) var gitProblem: String?
    private(set) var resolvedGitPath: String?
    private var cleanedWorktrees = false
    #if DEBUG
    private var debugTokens: [String: String] = [:]
    #endif

    var current: GitLabDomain? { domains.first { $0.key == currentKey } ?? domains.first }
    var currentAccount: DomainAccount? { current.flatMap { accounts[$0.key] } }

    /// No domain has a token yet, so the app shows the Connect window.
    var needsOnboarding: Bool {
        isLoaded && !domains.contains { accounts[$0.key]?.state != .noToken }
    }

    // MARK: Loading

    func load() async {
        #if DEBUG
        if let seed = DebugSnapshot.value("GLC_DEBUG_SEED"), let token = DebugSnapshot.value("GLC_DEBUG_TOKEN"), let parsed = DomainParser.parse(seed) {
            debugTokens[parsed.key] = token
            let domain = GitLabDomain(key: parsed.key, baseURL: parsed.baseURL, sshHost: parsed.host, username: "dev")
            domains = [domain]
            currentKey = domain.key
            accounts[domain.key] = DomainAccount(state: .loading)
            isLoaded = true
            await refreshAccount(domain)
            return
        }
        #endif
        if let data = UserDefaults.standard.data(forKey: "domains"),
           let saved = try? JSONDecoder().decode([GitLabDomain].self, from: data) {
            domains = saved
        }
        currentKey = UserDefaults.standard.string(forKey: "currentDomain") ?? domains.first?.key
        for domain in domains {
            let hasToken = (try? await tokens.token(for: domain.key)) != nil
            accounts[domain.key] = DomainAccount(state: hasToken ? .loading : .noToken)
        }
        isLoaded = true
        isOnboarding = needsOnboarding
        for domain in domains where accounts[domain.key]?.state == .loading {
            Task { await refreshAccount(domain) }
        }
    }

    /// The Keychain item for a domain (or, in debug runs against a mock server, a test token).
    private func storedToken(for key: String) async -> String? {
        #if DEBUG
        if let token = debugTokens[key] { return token }
        #endif
        return try? await tokens.token(for: key)
    }

    func refreshAccount(_ domain: GitLabDomain) async {
        guard let token = await storedToken(for: domain.key) else {
            accounts[domain.key] = DomainAccount(state: .noToken)
            return
        }
        var account = accounts[domain.key] ?? DomainAccount()
        account.maskedToken = TokenText.masked(token)
        do {
            let (user, info) = try await Self.validate(token: token, baseURL: domain.baseURL)
            account.user = user
            account.token = info
            account.state = .ok
        } catch GitLabAPIError.unauthorized {
            account.state = .invalid("The token was rejected (401).")
        } catch let error as GitLabAPIError {
            if case .network(_, let message) = error { account.state = .unreachable(message) } else { account.state = .invalid(error.localizedDescription) }
        } catch {
            account.state = .unreachable(error.localizedDescription)
        }
        accounts[domain.key] = account
    }

    /// GET /user and /personal_access_tokens/self with a token that isn't stored yet.
    nonisolated static func validate(token: String, baseURL: URL) async throws -> (GitLabUser, TokenInfo) {
        let client = GitLabAPIClient(baseURL: baseURL, tokenProvider: { token })
        async let user = client.currentUser()
        async let info = client.tokenInfo()
        return try await (user, info)
    }

    func api(for domain: GitLabDomain) -> GitLabAPIClient {
        if let client = clients[domain.key] { return client }
        let key = domain.key
        let tokens = self.tokens
        var override: String?
        #if DEBUG
        override = debugTokens[key]
        #endif
        let debugToken = override
        let client = GitLabAPIClient(
            baseURL: domain.baseURL,
            tokenProvider: { if let debugToken { return debugToken }; return try await tokens.token(for: key) },
            onUnauthorized: { [weak self] in await self?.requestReauth(domainKey: key) ?? false }
        )
        clients[key] = client
        return client
    }

    func repoList(for domain: GitLabDomain) -> RepoListModel {
        if let list = repoLists[domain.key] { return list }
        let list = RepoListModel(api: api(for: domain))
        repoLists[domain.key] = list
        return list
    }

    // MARK: Domains

    /// Saves a domain whose token was just validated; the token goes only to the Keychain.
    func addDomain(_ parsed: ParsedDomain, sshHost: String, sshPort: Int, token: String, user: GitLabUser, info: TokenInfo) async throws {
        try await tokens.save(token, for: parsed.key)
        var domain = domains.first { $0.key == parsed.key }
            ?? GitLabDomain(key: parsed.key, baseURL: parsed.baseURL, sshHost: sshHost, sshPort: sshPort)
        domain.sshHost = sshHost
        domain.sshPort = sshPort
        domain.username = user.username
        domain.displayName = user.name
        if let index = domains.firstIndex(where: { $0.key == domain.key }) { domains[index] = domain } else { domains.append(domain) }
        accounts[domain.key] = DomainAccount(state: .ok, user: user, token: info, maskedToken: TokenText.masked(token))
        clients[domain.key] = nil
        currentKey = domain.key
        saveDomains()
    }

    func select(_ domain: GitLabDomain) {
        currentKey = domain.key
    }

    func makeDefault(_ domain: GitLabDomain) {
        guard let index = domains.firstIndex(of: domain) else { return }
        domains.move(fromOffsets: IndexSet(integer: index), toOffset: 0)
        saveDomains()
    }

    func removeDomain(_ domain: GitLabDomain, deleteClones: Bool) async {
        try? await tokens.delete(account: domain.key)
        if deleteClones, let git = await git() { try? await git.clearClones(domain: domain) }
        domains.removeAll { $0.key == domain.key }
        accounts[domain.key] = nil
        clients[domain.key] = nil
        repoLists[domain.key] = nil
        if currentKey == domain.key { currentKey = domains.first?.key }
        saveDomains()
    }

    private func saveDomains() {
        if let data = try? JSONEncoder().encode(domains) {
            UserDefaults.standard.set(data, forKey: "domains")
        }
    }

    // MARK: Tokens

    /// Validates first and swaps the Keychain item only if the new token works.
    func replaceToken(for domain: GitLabDomain, with token: String) async throws {
        let (user, info) = try await Self.validate(token: token, baseURL: domain.baseURL)
        try await tokens.save(token, for: domain.key)
        accounts[domain.key] = DomainAccount(state: .ok, user: user, token: info, maskedToken: TokenText.masked(token))
        dismissedExpiryBanners.remove(domain.key)
    }

    func rotateToken(for domain: GitLabDomain) async throws {
        do {
            let rotated = try await api(for: domain).rotateToken()
            try await tokens.save(rotated.token, for: domain.key)
            dismissedExpiryBanners.remove(domain.key)
            await refreshAccount(domain)
        } catch GitLabAPIError.notFound {
            accounts[domain.key]?.rotateUnsupported = true
            throw RotateError.unsupported
        }
    }

    /// Kills the token on the server, then forgets it here.
    func revokeToken(for domain: GitLabDomain) async throws {
        try await api(for: domain).revokeToken()
        try await tokens.delete(account: domain.key)
        accounts[domain.key] = DomainAccount(state: .noToken)
    }

    /// Forgets the token on this Mac only; it stays valid on the server.
    func signOut(of domain: GitLabDomain) async {
        try? await tokens.delete(account: domain.key)
        accounts[domain.key] = DomainAccount(state: .noToken)
    }

    // MARK: Re-authentication after a 401

    func requestReauth(domainKey: String) async -> Bool {
        await withCheckedContinuation { continuation in
            reauthWaiters[domainKey, default: []].append(continuation)
            if reauthRequest == nil { reauthRequest = ReauthRequest(domainKey: domainKey) }
        }
    }

    func completeReauth(domainKey: String, token: String) async throws {
        guard let domain = domains.first(where: { $0.key == domainKey }) else { return }
        try await replaceToken(for: domain, with: token)
        finishReauth(domainKey: domainKey, succeeded: true)
    }

    func finishReauth(domainKey: String, succeeded: Bool) {
        let waiters = reauthWaiters.removeValue(forKey: domainKey) ?? []
        if reauthRequest?.domainKey == domainKey { reauthRequest = nil }
        if !succeeded, accounts[domainKey]?.state == .ok { accounts[domainKey]?.state = .invalid("The token was rejected (401).") }
        for waiter in waiters { waiter.resume(returning: succeeded) }
        if let next = reauthWaiters.keys.first { reauthRequest = ReauthRequest(domainKey: next) }
    }

    // MARK: Git

    func git() async -> GitService? {
        if let gitService { return gitService }
        guard let path = await GitService.resolveGit(override: settings.gitPathOverride) else {
            gitProblem = GitError.gitNotFound.localizedDescription
            return nil
        }
        gitProblem = nil
        resolvedGitPath = path
        let service = GitService(gitPath: path, reposRoot: settings.reposRoot, worktreesRoot: GitService.defaultWorktreesRoot())
        gitService = service
        if !cleanedWorktrees {
            cleanedWorktrees = true
            await service.removeStaleWorktrees()
        }
        return service
    }

    /// Call after the git path or clone location changes.
    func resetGit() {
        gitService = nil
        resolvedGitPath = nil
    }
}

enum RotateError: Error, LocalizedError {
    case unsupported

    var errorDescription: String? { "This GitLab server can't rotate tokens over the API. Use Replace or Generate via SSH instead." }
}
