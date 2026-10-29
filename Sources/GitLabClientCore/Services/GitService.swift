import Foundation

public enum GitError: Error, LocalizedError, Sendable, Equatable {
    case gitNotFound
    case sshPermissionDenied
    case hostKeyVerificationFailed(host: String)
    case timedOut(String)
    case failed(command: String, message: String)

    public var errorDescription: String? {
        switch self {
        case .gitNotFound:
            return "git wasn't found. Install the Xcode command line tools, or set its path in Settings → Git."
        case .sshPermissionDenied:
            return "Permission denied (publickey): your SSH key isn't loaded in ssh-agent (run ssh-add), or isn't on your GitLab account."
        case .hostKeyVerificationFailed(let host):
            return "Host key verification failed. Run ssh -T git@\(host) once in Terminal to trust the server."
        case .timedOut(let command):
            return "\(command) took too long and was stopped."
        case .failed(let command, let message):
            return "\(command) failed: \(message)"
        }
    }

    static func from(_ result: ProcessResult, command: String, host: String?) -> GitError {
        let output = TokenText.redact(result.stderr.isEmpty ? result.stdout : result.stderr)
        if output.contains("Permission denied (publickey)") { return .sshPermissionDenied }
        if output.contains("Host key verification failed") { return .hostKeyVerificationFailed(host: host ?? "the server") }
        if result.timedOut { return .timedOut(command) }
        let message = output.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("hint:") }.prefix(4).joined(separator: " ")
        return .failed(command: command, message: message.isEmpty ? "exit \(result.exitCode)" : message)
    }
}

/// Runs the system git so the user's ~/.ssh/config, ssh-agent and Keychain SSH keys just work.
/// Each project gets one bare clone under `reposRoot/<domain>/<project-id>.git`, and anything that
/// changes a branch happens in a throwaway worktree under `worktreesRoot`.
public actor GitService {
    public let gitPath: String
    public let reposRoot: URL
    public let worktreesRoot: URL

    public init(gitPath: String, reposRoot: URL, worktreesRoot: URL) {
        self.gitPath = gitPath
        self.reposRoot = reposRoot
        self.worktreesRoot = worktreesRoot
    }

    /// The user's override if it's executable, else git from the login shell's PATH.
    public static func resolveGit(override: String?) async -> String? {
        if let override, !override.isEmpty, FileManager.default.isExecutableFile(atPath: override) { return override }
        if let found = await ShellEnvironment.shared.which("git") { return found }
        return FileManager.default.isExecutableFile(atPath: "/usr/bin/git") ? "/usr/bin/git" : nil
    }

    public static func defaultReposRoot() -> URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appending(path: "GitLabClient/repos", directoryHint: .isDirectory)
    }

    public static func defaultWorktreesRoot() -> URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appending(path: "GitLabClient/worktrees", directoryHint: .isDirectory)
    }

    // MARK: Running git

    func run(_ arguments: [String], in directory: URL? = nil, env extra: [String: String] = [:],
             timeout: Duration = .seconds(120), onLine: (@Sendable (OutputLine) -> Void)? = nil) async throws -> ProcessResult {
        let env = await ShellEnvironment.shared.environment(adding: extra)
        var args = arguments
        if let directory { args = ["-C", directory.path] + args }
        return try await ProcessRunner.run(gitPath, args, environment: env, timeout: timeout, onLine: onLine)
    }

    @discardableResult
    func checked(_ arguments: [String], in directory: URL? = nil, env: [String: String] = [:], timeout: Duration = .seconds(120),
                 host: String? = nil, onLine: (@Sendable (OutputLine) -> Void)? = nil) async throws -> String {
        let result = try await run(arguments, in: directory, env: env, timeout: timeout, onLine: onLine)
        guard result.succeeded else {
            throw GitError.from(result, command: "git " + (arguments.first ?? ""), host: host)
        }
        return result.stdout
    }

    // MARK: Local mirrors

    public func repositoryURL(domain: GitLabDomain, projectID: Int) -> URL {
        reposRoot.appending(path: domain.folderName, directoryHint: .isDirectory).appending(path: "\(projectID).git", directoryHint: .isDirectory)
    }

    public func isCloned(domain: GitLabDomain, projectID: Int) -> Bool {
        FileManager.default.fileExists(atPath: repositoryURL(domain: domain, projectID: projectID).appending(path: "HEAD").path)
    }

    /// Clones once, then fetches. Branches live under refs/remotes/origin and MR heads under refs/mr.
    public func prepare(domain: GitLabDomain, project: Project, fetch: Bool = true,
                        onProgress: (@Sendable (String) -> Void)? = nil) async throws -> URL {
        let repo = repositoryURL(domain: domain, projectID: project.id)
        var progress: (@Sendable (OutputLine) -> Void)?
        if let onProgress {
            progress = { @Sendable line in onProgress(line.text) }
        }
        if !isCloned(domain: domain, projectID: project.id) {
            try FileManager.default.createDirectory(at: repo.deletingLastPathComponent(), withIntermediateDirectories: true)
            let partial = repo.deletingPathExtension().appendingPathExtension("partial")
            try? FileManager.default.removeItem(at: partial)
            try await checked(["clone", "--bare", "--progress", project.sshUrlToRepo, partial.path],
                              timeout: .seconds(1800), host: domain.sshHost, onLine: progress)
            try await checked(["config", "remote.origin.fetch", "+refs/heads/*:refs/remotes/origin/*"], in: partial)
            try await checked(["config", "--add", "remote.origin.fetch", "+refs/merge-requests/*/head:refs/mr/*"], in: partial)
            try FileManager.default.moveItem(at: partial, to: repo)
            try await checked(["fetch", "--prune", "--tags", "--progress", "origin"], in: repo, timeout: .seconds(900), host: domain.sshHost, onLine: progress)
        } else if fetch {
            try await checked(["fetch", "--prune", "--tags", "--progress", "origin"], in: repo, timeout: .seconds(900), host: domain.sshHost, onLine: progress)
        }
        return repo
    }

    public func fetch(repo: URL, host: String) async throws {
        try await checked(["fetch", "--prune", "--tags", "origin"], in: repo, timeout: .seconds(900), host: host)
    }

    // MARK: Reading

    public func branches(repo: URL) async throws -> [GitRef] {
        let output = try await checked(["for-each-ref", "--sort=-committerdate", "--format=%(refname)%1f%(objectname)%1f%(committerdate:unix)", "refs/remotes/origin"], in: repo)
        return RefParser.parse(output.replacingOccurrences(of: "%1f", with: "\u{1f}"), stripping: "refs/remotes/origin/")
    }

    public func tags(repo: URL) async throws -> [GitRef] {
        let output = try await checked(["for-each-ref", "--sort=-creatordate", "--format=%(refname)%1f%(objectname)%1f%(creatordate:unix)", "refs/tags"], in: repo)
        return RefParser.parse(output.replacingOccurrences(of: "%1f", with: "\u{1f}"), stripping: "refs/tags/")
    }

    /// One page of history, newest first in date order so the graph stays stable across pages.
    public func log(repo: URL, ref: String, skip: Int = 0, limit: Int = 200) async throws -> [Commit] {
        let output = try await checked(["log", "--date-order", "--format=\(GitLogParser.format)", "--skip=\(skip)", "-n", "\(limit)", ref, "--"], in: repo)
        return GitLogParser.parse(output)
    }

    public func tree(repo: URL, ref: String, path: String) async throws -> [TreeEntry] {
        let target = path.isEmpty ? ref : "\(ref):\(path)"
        let output = try await checked(["ls-tree", "-z", target], in: repo)
        return LsTreeParser.parse(output).map { entry in
            var full = entry
            full.path = path.isEmpty ? entry.path : "\(path)/\(entry.path)"
            return full
        }
    }

    public func file(repo: URL, ref: String, path: String) async throws -> Data {
        let env = await ShellEnvironment.shared.environment()
        let result = try await ProcessRunner.run(gitPath, ["-C", repo.path, "show", "\(ref):\(path)"], environment: env, timeout: .seconds(60))
        guard result.succeeded else { throw GitError.from(result, command: "git show", host: nil) }
        return Data(result.stdout.utf8)
    }

    public func blame(repo: URL, ref: String, path: String) async throws -> [BlameLine] {
        BlameParser.parse(try await checked(["blame", "--porcelain", ref, "--", path], in: repo, timeout: .seconds(180)))
    }

    public func showCommit(repo: URL, hash: String) async throws -> (message: String, files: [DiffFile]) {
        let output = try await checked(["show", "--patience", "--format=%B%x1e", hash], in: repo, timeout: .seconds(60))
        let parts = output.split(separator: "\u{1e}", maxSplits: 1, omittingEmptySubsequences: false)
        let message = parts.first.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) } ?? ""
        return (message, DiffParser.parse(parts.count > 1 ? String(parts[1]) : ""))
    }

    /// The MR's changes as GitLab shows them: target...mr-head with the patience algorithm.
    public func mergeRequestDiff(repo: URL, targetBranch: String, iid: Int) async throws -> [DiffFile] {
        DiffParser.parse(try await checked(["diff", "--patience", "refs/remotes/origin/\(targetBranch)...refs/mr/\(iid)"], in: repo, timeout: .seconds(120)))
    }

    public func diff(in directory: URL, from: String, to: String, threeDot: Bool = false) async throws -> [DiffFile] {
        let range = threeDot ? "\(from)...\(to)" : "\(from)..\(to)"
        return DiffParser.parse(try await checked(["diff", "--patience", range], in: directory, timeout: .seconds(120)))
    }

    public func revParse(_ ref: String, in directory: URL) async throws -> String {
        try await checked(["rev-parse", "--verify", "\(ref)^{commit}"], in: directory).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: Worktrees (used only by AI conflict resolution)

    public func addWorktree(repo: URL, name: String, from ref: String) async throws -> (path: URL, branch: String) {
        try FileManager.default.createDirectory(at: worktreesRoot, withIntermediateDirectories: true)
        let path = worktreesRoot.appending(path: name, directoryHint: .isDirectory)
        try? FileManager.default.removeItem(at: path)
        let branch = "gitlab-client/\(name)"
        try await checked(["worktree", "prune"], in: repo)
        _ = try? await run(["branch", "-D", branch], in: repo)
        try await checked(["worktree", "add", "-b", branch, path.path, ref], in: repo)
        return (path, branch)
    }

    /// Worktrees are throwaway; anything left from a run that was interrupted (for example by
    /// quitting mid-run) is deleted at launch, along with its temporary branches.
    public func removeStaleWorktrees() async {
        try? FileManager.default.removeItem(at: worktreesRoot)
        guard let domains = try? FileManager.default.contentsOfDirectory(at: reposRoot, includingPropertiesForKeys: nil) else { return }
        for domain in domains {
            for repo in (try? FileManager.default.contentsOfDirectory(at: domain, includingPropertiesForKeys: nil)) ?? [] where repo.pathExtension == "git" {
                _ = try? await run(["worktree", "prune"], in: repo)
                let branches = (try? await checked(["for-each-ref", "--format=%(refname:short)", "refs/heads/gitlab-client/"], in: repo)) ?? ""
                for branch in branches.split(separator: "\n") where !branch.isEmpty {
                    _ = try? await run(["branch", "-D", String(branch)], in: repo)
                }
            }
        }
    }

    public func removeWorktree(repo: URL, path: URL, branch: String) async {
        if (try? await operationInProgress(in: path)) == true {
            _ = try? await run(["rebase", "--abort"], in: path)
            _ = try? await run(["merge", "--abort"], in: path)
        }
        _ = try? await run(["worktree", "remove", "--force", path.path], in: repo)
        try? FileManager.default.removeItem(at: path)
        _ = try? await run(["worktree", "prune"], in: repo)
        _ = try? await run(["branch", "-D", branch], in: repo)
    }

    public func conflictedFiles(in worktree: URL) async throws -> [String] {
        try await checked(["diff", "--name-only", "--diff-filter=U"], in: worktree)
            .split(separator: "\n").map(String.init).filter { !$0.isEmpty }
    }

    /// True while a rebase or merge is stopped in the worktree.
    public func operationInProgress(in worktree: URL) async throws -> Bool {
        for name in ["rebase-merge", "rebase-apply", "MERGE_HEAD"] {
            let path = try await checked(["rev-parse", "--git-path", name], in: worktree).trimmingCharacters(in: .whitespacesAndNewlines)
            let url = path.hasPrefix("/") ? URL(fileURLWithPath: path) : worktree.appending(path: path)
            if FileManager.default.fileExists(atPath: url.path) { return true }
        }
        return false
    }

    public func hasCommitterIdentity(in directory: URL) async -> Bool {
        let email = try? await checked(["config", "user.email"], in: directory)
        return !(email?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
    }

    // MARK: Housekeeping

    public func clearClones() throws {
        try? FileManager.default.removeItem(at: worktreesRoot)
        if FileManager.default.fileExists(atPath: reposRoot.path) {
            try FileManager.default.removeItem(at: reposRoot)
        }
    }

    public func clearClones(domain: GitLabDomain) throws {
        let folder = reposRoot.appending(path: domain.folderName, directoryHint: .isDirectory)
        if FileManager.default.fileExists(atPath: folder.path) {
            try FileManager.default.removeItem(at: folder)
        }
    }

    public static func folderSize(_ url: URL) -> Int64 {
        guard let enumerator = FileManager.default.enumerator(at: url, includingPropertiesForKeys: [.totalFileAllocatedSizeKey]) else { return 0 }
        var total: Int64 = 0
        for case let file as URL in enumerator {
            total += Int64((try? file.resourceValues(forKeys: [.totalFileAllocatedSizeKey]).totalFileAllocatedSize) ?? 0)
        }
        return total
    }
}
