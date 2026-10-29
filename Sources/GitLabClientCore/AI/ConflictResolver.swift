import Foundation

public enum ConflictStrategy: String, CaseIterable, Codable, Sendable, Identifiable {
    case rebase
    case merge

    public var id: String { rawValue }
    public var title: String { self == .rebase ? "Rebase onto target" : "Merge target into branch" }
    public var task: AITask { self == .rebase ? .rebaseOntoTarget : .resolveMergeConflicts }
}

public struct AIRunSettings: Sendable {
    public var executable: String
    public var template: String
    public var prompt: String
    public var timeout: Duration
    public var cliName: String

    public init(executable: String, template: String, prompt: String, timeout: Duration, cliName: String) {
        self.executable = executable
        self.template = template
        self.prompt = prompt
        self.timeout = timeout
        self.cliName = cliName
    }
}

public struct ResolveRequest: Sendable {
    public var domain: GitLabDomain
    public var project: Project
    public var iid: Int
    public var sourceBranch: String
    public var targetBranch: String
    public var strategy: ConflictStrategy
    public var ai: AIRunSettings
    public var committerName: String?
    public var committerEmail: String?

    public init(domain: GitLabDomain, project: Project, iid: Int, sourceBranch: String, targetBranch: String,
                strategy: ConflictStrategy, ai: AIRunSettings, committerName: String?, committerEmail: String?) {
        self.domain = domain
        self.project = project
        self.iid = iid
        self.sourceBranch = sourceBranch
        self.targetBranch = targetBranch
        self.strategy = strategy
        self.ai = ai
        self.committerName = committerName
        self.committerEmail = committerEmail
    }
}

public enum ResolveStage: Sendable, Equatable {
    case fetching
    case creatingWorktree
    case replaying(ConflictStrategy)
    case runningAI(round: Int, files: [String])
    case continuing
    case checking
    case ready
    case pushing
    case pushed
}

public enum ResolveEvent: Sendable {
    case stage(ResolveStage)
    case output(OutputLine)
    case fileResolved(String)
}

public struct SafetyCheck: Sendable, Identifiable, Equatable {
    public var title: String
    public var passed: Bool
    public var id: String { title }
}

public struct ResolveOutcome: Sendable {
    public var worktree: URL
    public var originalSHA: String
    public var newSHA: String
    public var conflictedFiles: [String]
    public var aiRounds: Int
    public var checks: [SafetyCheck]
    public var diffAgainstOriginal: [DiffFile]
    public var diffAgainstTarget: [DiffFile]

    public var allChecksPassed: Bool { checks.allSatisfy(\.passed) }
}

public enum ResolveError: Error, LocalizedError, Sendable {
    case markersRemain([String])
    case aiFailed(exitCode: Int32, timedOut: Bool)
    case tooManyRounds
    case gitFailed(String)
    case alreadyRunning

    public var errorDescription: String? {
        switch self {
        case .markersRemain(let files): return "Conflict markers are still in \(files.joined(separator: ", ")). Nothing was pushed."
        case .aiFailed(let code, let timedOut):
            return timedOut ? "The AI CLI hit the time limit and was stopped. Nothing was pushed." : "The AI CLI exited with code \(code). Nothing was pushed."
        case .tooManyRounds: return "The rebase kept stopping with new conflicts. Nothing was pushed."
        case .gitFailed(let message): return message
        case .alreadyRunning: return "A resolution is already running for this merge request."
        }
    }
}

/// Resolves MR conflicts with an AI CLI in a throwaway worktree. The CLI only edits files;
/// this actor does every git step, and pushes only when `push` is called after review.
public actor ConflictResolver {
    private let git: GitService
    private var worktree: (repo: URL, path: URL, branch: String)?

    public init(git: GitService) {
        self.git = git
    }

    public func resolve(_ request: ResolveRequest, events: @escaping @Sendable (ResolveEvent) -> Void) async throws -> ResolveOutcome {
        guard worktree == nil else { throw ResolveError.alreadyRunning }

        events(.stage(.fetching))
        let repo = try await git.prepare(domain: request.domain, project: request.project)
        let source = "refs/remotes/origin/\(request.sourceBranch)"
        let target = "refs/remotes/origin/\(request.targetBranch)"
        let originalSHA = try await git.revParse(source, in: repo)

        events(.stage(.creatingWorktree))
        let name = "\(request.project.id)-\(request.iid)-\(Int(Date().timeIntervalSince1970))"
        let created = try await git.addWorktree(repo: repo, name: name, from: source)
        worktree = (repo, created.path, created.branch)
        let path = created.path

        var identity: [String: String] = [:]
        if await !git.hasCommitterIdentity(in: path), let name = request.committerName {
            let email = request.committerEmail ?? "\(request.domain.username ?? "user")@users.noreply.\(request.domain.host)"
            identity = ["GIT_AUTHOR_NAME": name, "GIT_AUTHOR_EMAIL": email, "GIT_COMMITTER_NAME": name, "GIT_COMMITTER_EMAIL": email]
        }

        events(.stage(.replaying(request.strategy)))
        let first: ProcessResult
        switch request.strategy {
        case .rebase: first = try await git.run(["rebase", target], in: path, env: identity, timeout: .seconds(300))
        case .merge: first = try await git.run(["merge", "--no-ff", "--no-edit", target], in: path, env: identity, timeout: .seconds(300))
        }
        events(.output(.stdout(TokenText.redact(first.combinedOutput))))

        var allConflicts: [String] = []
        var rounds = 0
        var stillRunning = try await git.operationInProgress(in: path)
        if !first.succeeded && !stillRunning {
            throw ResolveError.gitFailed(GitError.from(first, command: "git \(request.strategy.rawValue)", host: nil).localizedDescription)
        }

        while stillRunning {
            rounds += 1
            guard rounds <= 25 else { throw ResolveError.tooManyRounds }
            let files = try await git.conflictedFiles(in: path)
            if files.isEmpty {
                // A commit that became empty after resolution; skip it like `git rebase` suggests.
                events(.stage(.continuing))
                let skip = request.strategy == .rebase
                    ? try await git.run(["rebase", "--skip"], in: path, env: identity)
                    : try await git.run(["commit", "--no-edit"], in: path, env: identity)
                events(.output(.stdout(skip.combinedOutput)))
                stillRunning = try await git.operationInProgress(in: path)
                continue
            }
            allConflicts.append(contentsOf: files.filter { !allConflicts.contains($0) })

            events(.stage(.runningAI(round: rounds, files: files)))
            try await runAI(request, worktree: path, files: files, events: events)

            let leftover = files.filter { Self.hasConflictMarkers(at: path.appending(path: $0)) }
            guard leftover.isEmpty else { throw ResolveError.markersRemain(leftover) }
            for file in files { events(.fileResolved(file)) }

            events(.stage(.continuing))
            _ = try await git.checked(["add", "--"] + files, in: path)
            let next = request.strategy == .rebase
                ? try await git.run(["rebase", "--continue"], in: path, env: identity, timeout: .seconds(300))
                : try await git.run(["commit", "--no-edit"], in: path, env: identity)
            events(.output(.stdout(TokenText.redact(next.combinedOutput))))
            stillRunning = try await git.operationInProgress(in: path)
            if !next.succeeded && !stillRunning {
                throw ResolveError.gitFailed(GitError.from(next, command: "git \(request.strategy.rawValue) --continue", host: nil).localizedDescription)
            }
        }

        events(.stage(.checking))
        let newSHA = try await git.revParse("HEAD", in: path)
        let markersLeft = allConflicts.contains { Self.hasConflictMarkers(at: path.appending(path: $0)) }
        let inProgress = try await git.operationInProgress(in: path)
        let checks = [
            SafetyCheck(title: "No conflict markers left in the worktree", passed: !markersLeft),
            SafetyCheck(title: request.strategy == .rebase ? "Rebase finished, nothing in progress" : "Merge committed, nothing in progress", passed: !inProgress),
            SafetyCheck(title: "Branch tip moved \(originalSHA.prefix(7)) → \(newSHA.prefix(7))", passed: newSHA != originalSHA),
        ]
        let againstOriginal = try await git.diff(in: path, from: originalSHA, to: "HEAD")
        let againstTarget = try await git.diff(in: path, from: target, to: "HEAD", threeDot: true)
        events(.stage(.ready))
        return ResolveOutcome(worktree: path, originalSHA: originalSHA, newSHA: newSHA, conflictedFiles: allConflicts,
                              aiRounds: rounds, checks: checks, diffAgainstOriginal: againstOriginal, diffAgainstTarget: againstTarget)
    }

    /// The only push in the app: fails if anyone pushed to the branch since `originalSHA`.
    public func push(_ request: ResolveRequest, outcome: ResolveOutcome, events: @escaping @Sendable (ResolveEvent) -> Void) async throws {
        events(.stage(.pushing))
        let branch = request.sourceBranch
        let output = try await git.checked(["push", "--force-with-lease=refs/heads/\(branch):\(outcome.originalSHA)", "origin", "HEAD:refs/heads/\(branch)"],
                                           in: outcome.worktree, timeout: .seconds(300), host: request.domain.sshHost)
        events(.output(.stdout(TokenText.redact(output))))
        events(.stage(.pushed))
        await discard()
    }

    public func discard() async {
        guard let worktree else { return }
        self.worktree = nil
        await git.removeWorktree(repo: worktree.repo, path: worktree.path, branch: worktree.branch)
    }

    private func runAI(_ request: ResolveRequest, worktree: URL, files: [String], events: @escaping @Sendable (ResolveEvent) -> Void) async throws {
        let values = ["worktree": worktree.path, "branch": request.sourceBranch, "target": request.targetBranch]
        let prompt = AIPrompt.render(request.ai.prompt, values: values, files: files)
        var arguments = CommandTemplate.render(try CommandTemplate.tokenize(request.ai.template),
                                               values: values.merging(["prompt": prompt]) { _, new in new },
                                               lists: ["conflicted_files": files])
        arguments.removeFirst()  // the binary; its resolved path is request.ai.executable
        events(.output(.stdout("$ \(request.ai.cliName) … (\(files.count) file\(files.count == 1 ? "" : "s"))")))
        let env = await ShellEnvironment.shared.environment()
        let result = try await ProcessRunner.run(request.ai.executable, arguments, in: worktree, environment: env, timeout: request.ai.timeout) { line in
            events(.output(line.redacted))
        }
        guard result.succeeded else { throw ResolveError.aiFailed(exitCode: result.exitCode, timedOut: result.timedOut) }
    }

    public static func hasConflictMarkers(at url: URL) -> Bool {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return false }
        return text.split(separator: "\n", omittingEmptySubsequences: false).contains { line in
            line.hasPrefix("<<<<<<< ") || line == "=======" || line.hasPrefix(">>>>>>> ") || line.hasPrefix("||||||| ")
        }
    }
}

extension OutputLine {
    var redacted: OutputLine {
        switch self {
        case .stdout(let text): return .stdout(TokenText.redact(text))
        case .stderr(let text): return .stderr(TokenText.redact(text))
        }
    }
}

/// Runs the chosen CLI once with a trivial prompt so Settings can show it works and is signed in.
public enum AICLITester {
    public static func test(executable: String, template: String, timeout: Duration = .seconds(90)) async throws -> (output: String, seconds: Double, succeeded: Bool) {
        let folder = FileManager.default.temporaryDirectory.appending(path: "gitlab-client-ai-test-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        var arguments = CommandTemplate.render(try CommandTemplate.tokenize(template),
                                               values: ["prompt": "Reply with the word OK and nothing else.", "worktree": folder.path, "branch": "test", "target": "main"],
                                               lists: ["conflicted_files": []])
        arguments.removeFirst()
        let env = await ShellEnvironment.shared.environment()
        let start = Date()
        let result = try await ProcessRunner.run(executable, arguments, in: folder, environment: env, timeout: timeout)
        let output = TokenText.redact(result.combinedOutput)
        return (output, Date().timeIntervalSince(start), result.succeeded)
    }
}
