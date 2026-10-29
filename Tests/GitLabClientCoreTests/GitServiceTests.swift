import Foundation
import Testing
@testable import GitLabClientCore

/// Runs against throwaway local repositories, never a real server.
@Suite(.serialized) struct GitServiceTests {
    let root = FileManager.default.temporaryDirectory.appending(path: "gitlab-client-tests-\(UUID().uuidString)", directoryHint: .isDirectory)

    func sh(_ args: [String], in dir: URL) async throws {
        let env = await ShellEnvironment.shared.environment(adding: [
            "GIT_AUTHOR_NAME": "Test", "GIT_AUTHOR_EMAIL": "test@example.com",
            "GIT_COMMITTER_NAME": "Test", "GIT_COMMITTER_EMAIL": "test@example.com",
        ])
        let result = try await ProcessRunner.run("/usr/bin/git", ["-C", dir.path] + args, environment: env)
        #expect(result.succeeded, "git \(args.joined(separator: " ")): \(result.combinedOutput)")
    }

    @Test func logTreeFileAndProcessTimeout() async throws {
        let repo = root.appending(path: "work", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: repo.appending(path: "Sources"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try await sh(["init", "-q", "-b", "main"], in: repo)
        try "hello\n".write(to: repo.appending(path: "README.md"), atomically: true, encoding: .utf8)
        try await sh(["add", "."], in: repo)
        try await sh(["commit", "-q", "-m", "First"], in: repo)
        try "let x = 1\n".write(to: repo.appending(path: "Sources/x.swift"), atomically: true, encoding: .utf8)
        try await sh(["add", "."], in: repo)
        try await sh(["commit", "-q", "-m", "Second"], in: repo)

        let git = GitService(gitPath: "/usr/bin/git", reposRoot: root.appending(path: "repos"), worktreesRoot: root.appending(path: "wt"))
        let commits = try await git.log(repo: repo, ref: "main")
        #expect(commits.map(\.subject) == ["Second", "First"])
        #expect(commits[0].parents == [commits[1].hash])

        let tree = try await git.tree(repo: repo, ref: "main", path: "")
        #expect(tree.map(\.path) == ["Sources", "README.md"])
        let inner = try await git.tree(repo: repo, ref: "main", path: "Sources")
        #expect(inner.map(\.path) == ["Sources/x.swift"])

        let data = try await git.file(repo: repo, ref: "main", path: "README.md")
        #expect(String(decoding: data, as: UTF8.self) == "hello\n")

        let shown = try await git.showCommit(repo: repo, hash: commits[0].hash)
        #expect(shown.message == "Second")
        #expect(shown.files.first?.change == .added)

        let slow = try await ProcessRunner.run("/bin/sleep", ["5"], timeout: .milliseconds(300))
        #expect(slow.timedOut)
    }

    /// Full AI flow against a local "origin": clone, worktree, rebase stops, a stand-in CLI edits
    /// the file, the app continues the rebase, checks pass, and the push uses --force-with-lease.
    @Test func resolvesConflictsAndPushesWithLease() async throws {
        let origin = root.appending(path: "origin.git", directoryHint: .isDirectory)
        let work = root.appending(path: "work", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try await sh(["init", "-q", "--bare", "-b", "main", origin.path], in: root)
        try await sh(["clone", "-q", origin.path, work.path], in: root)
        try await sh(["checkout", "-q", "-b", "main"], in: work)
        let file = work.appending(path: "file.txt")
        try "one\ntwo\nthree\n".write(to: file, atomically: true, encoding: .utf8)
        try await sh(["add", "."], in: work)
        try await sh(["commit", "-q", "-m", "Base"], in: work)
        try await sh(["push", "-q", "origin", "main"], in: work)
        try await sh(["checkout", "-q", "-b", "feature"], in: work)
        try "one\nfeature two\nthree\n".write(to: file, atomically: true, encoding: .utf8)
        try await sh(["commit", "-q", "-am", "Feature change"], in: work)
        try await sh(["push", "-q", "origin", "feature"], in: work)
        try await sh(["checkout", "-q", "main"], in: work)
        try "one\nmain two\nthree\n".write(to: file, atomically: true, encoding: .utf8)
        try await sh(["commit", "-q", "-am", "Main change"], in: work)
        try await sh(["push", "-q", "origin", "main"], in: work)

        // Stand-in for an AI CLI: keeps both sides by deleting the marker lines.
        let script = root.appending(path: "fake-ai.sh")
        try "#!/bin/sh\nfor f in \"$@\"; do [ -f \"$f\" ] && sed -i '' -e '/^<<<<<<< /d' -e '/^=======$/d' -e '/^>>>>>>> /d' \"$f\"; done\necho resolved\n"
            .write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)

        let git = GitService(gitPath: "/usr/bin/git", reposRoot: root.appending(path: "repos"), worktreesRoot: root.appending(path: "wt"))
        let domain = GitLabDomain(key: "local.test", baseURL: URL(string: "https://local.test")!, sshHost: "local.test")
        let project = Project(id: 1, name: "p", nameWithNamespace: "g / p", pathWithNamespace: "g/p", sshUrlToRepo: origin.path)
        let request = ResolveRequest(
            domain: domain, project: project, iid: 7, sourceBranch: "feature", targetBranch: "main", strategy: .rebase,
            ai: AIRunSettings(executable: script.path, template: #"fake-ai {conflicted_files} "{prompt}""#,
                              prompt: AITask.rebaseOntoTarget.defaultPrompt, timeout: .seconds(30), cliName: "Fake"),
            committerName: "Test", committerEmail: "test@example.com")

        let resolver = ConflictResolver(git: git)
        let outcome = try await resolver.resolve(request) { _ in }
        #expect(outcome.conflictedFiles == ["file.txt"])
        #expect(outcome.aiRounds == 1)
        #expect(outcome.allChecksPassed, "\(outcome.checks)")
        #expect(outcome.diffAgainstTarget.first?.path == "file.txt")
        let resolved = try String(contentsOf: outcome.worktree.appending(path: "file.txt"), encoding: .utf8)
        #expect(resolved.contains("main two") && resolved.contains("feature two"))

        try await resolver.push(request, outcome: outcome) { _ in }
        #expect(!FileManager.default.fileExists(atPath: outcome.worktree.path))
        let env = await ShellEnvironment.shared.environment()
        let ancestor = try await ProcessRunner.run("/usr/bin/git", ["-C", origin.path, "merge-base", "--is-ancestor", "main", "feature"], environment: env)
        #expect(ancestor.exitCode == 0, "origin/feature should now sit on top of main")
    }

    @Test func pushRefusesWhenSomeonePushedMeanwhile() async throws {
        let origin = root.appending(path: "origin.git", directoryHint: .isDirectory)
        let work = root.appending(path: "work", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try await sh(["init", "-q", "--bare", "-b", "main", origin.path], in: root)
        try await sh(["clone", "-q", origin.path, work.path], in: root)
        try await sh(["checkout", "-q", "-b", "main"], in: work)
        try "a\n".write(to: work.appending(path: "a.txt"), atomically: true, encoding: .utf8)
        try await sh(["add", "."], in: work)
        try await sh(["commit", "-q", "-m", "Base"], in: work)
        try await sh(["push", "-q", "origin", "main"], in: work)
        try await sh(["checkout", "-q", "-b", "feature"], in: work)
        try "b\n".write(to: work.appending(path: "b.txt"), atomically: true, encoding: .utf8)
        try await sh(["add", "."], in: work)
        try await sh(["commit", "-q", "-m", "Feature"], in: work)
        try await sh(["push", "-q", "origin", "feature"], in: work)
        try await sh(["checkout", "-q", "main"], in: work)
        try "a2\n".write(to: work.appending(path: "a.txt"), atomically: true, encoding: .utf8)
        try await sh(["commit", "-q", "-am", "Main moves"], in: work)
        try await sh(["push", "-q", "origin", "main"], in: work)

        let git = GitService(gitPath: "/usr/bin/git", reposRoot: root.appending(path: "repos"), worktreesRoot: root.appending(path: "wt"))
        let domain = GitLabDomain(key: "local.test", baseURL: URL(string: "https://local.test")!, sshHost: "local.test")
        let project = Project(id: 2, name: "p", nameWithNamespace: "g / p", pathWithNamespace: "g/p", sshUrlToRepo: origin.path)
        let request = ResolveRequest(
            domain: domain, project: project, iid: 8, sourceBranch: "feature", targetBranch: "main", strategy: .rebase,
            ai: AIRunSettings(executable: "/usr/bin/true", template: "true {prompt}", prompt: "", timeout: .seconds(5), cliName: "None"),
            committerName: "Test", committerEmail: "test@example.com")
        let resolver = ConflictResolver(git: git)
        let outcome = try await resolver.resolve(request) { _ in }
        #expect(outcome.aiRounds == 0, "a clean rebase never calls the CLI")

        // Someone pushes to the branch after the run started.
        try await sh(["checkout", "-q", "feature"], in: work)
        try "c\n".write(to: work.appending(path: "c.txt"), atomically: true, encoding: .utf8)
        try await sh(["add", "."], in: work)
        try await sh(["commit", "-q", "-m", "Teammate"], in: work)
        try await sh(["push", "-q", "origin", "feature"], in: work)

        await #expect(throws: GitError.self) { try await resolver.push(request, outcome: outcome) { _ in } }
        await resolver.discard()
    }

    @Test func detectsConflictMarkers() throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appending(path: "c.swift")
        try "a\n<<<<<<< HEAD\nb\n=======\nc\n>>>>>>> main\n".write(to: file, atomically: true, encoding: .utf8)
        #expect(ConflictResolver.hasConflictMarkers(at: file))
        try "a\n// ======= not a marker\n".write(to: file, atomically: true, encoding: .utf8)
        #expect(!ConflictResolver.hasConflictMarkers(at: file))
    }
}
