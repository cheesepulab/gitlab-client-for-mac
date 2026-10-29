import Foundation
import Testing
@testable import GitLabClientCore

@Suite struct GitLogParserTests {
    @Test func parsesRecordsWithParentsAndSeparators() {
        let output = "aaaaaaa1111111111111111111111111111111111\u{1f}bbbbbbb2222222222222222222222222222222222 ccccccc3333333333333333333333333333333333\u{1f}Linh Pham\u{1f}linh@example.com\u{1f}1761724800\u{1f}Merge branch 'fix' into develop\u{1e}\n"
            + "bbbbbbb2222222222222222222222222222222222\u{1f}\u{1f}Minh Tran\u{1f}minh@example.com\u{1f}1761638400\u{1f}Initial commit\u{1e}\n"
        let commits = GitLogParser.parse(output)
        #expect(commits.count == 2)
        #expect(commits[0].parents.count == 2)
        #expect(commits[0].subject == "Merge branch 'fix' into develop")
        #expect(commits[0].authorEmail == "linh@example.com")
        #expect(commits[1].parents.isEmpty)
        #expect(commits[1].date == Date(timeIntervalSince1970: 1761638400))
        #expect(commits[1].shortHash == "bbbbbbb2")
    }

    @Test func ignoresGarbage() {
        #expect(GitLogParser.parse("").isEmpty)
        #expect(GitLogParser.parse("not a log\u{1e}").isEmpty)
    }
}

@Suite struct DiffParserTests {
    let sample = """
    diff --git a/Sources/APIClient.swift b/Sources/APIClient.swift
    index 1111111..2222222 100644
    --- a/Sources/APIClient.swift
    +++ b/Sources/APIClient.swift
    @@ -1,4 +1,5 @@ final class APIClient {
     let a = 1
    --- a removed line that looks like a header
    +let b = 2
    +let c = 3
     let d = 4
     let e = 5
    diff --git a/old.txt b/new.txt
    similarity index 90%
    rename from old.txt
    rename to new.txt
    diff --git a/logo.png b/logo.png
    new file mode 100644
    Binary files /dev/null and b/logo.png differ
    diff --git a/gone.txt b/gone.txt
    deleted file mode 100644
    --- a/gone.txt
    +++ /dev/null
    @@ -1 +0,0 @@
    -bye
    \\ No newline at end of file

    """

    @Test func parsesFilesHunksAndLineNumbers() throws {
        let files = DiffParser.parse(sample)
        #expect(files.count == 4)

        let first = files[0]
        #expect(first.path == "Sources/APIClient.swift")
        #expect(first.hunks.count == 1)
        let lines = first.hunks[0].lines
        #expect(lines.count == 6)
        #expect(lines[1].kind == .removed)
        #expect(lines[1].text == "-- a removed line that looks like a header")
        #expect(lines[2].kind == .added && lines[2].newLine == 2)
        #expect(lines[5].oldLine == 4 && lines[5].newLine == 5)
        #expect(first.additions == 2 && first.deletions == 1)

        #expect(files[1].change == .renamed)
        #expect(files[1].oldPath == "old.txt" && files[1].newPath == "new.txt")
        #expect(files[2].change == .added && files[2].isBinary)
        #expect(files[3].change == .deleted && files[3].newPath == nil)
        #expect(files[3].hunks[0].lines.last?.kind == .noNewline)
    }

    @Test func parsesAPIHunksWithoutHeaders() {
        let hunks = DiffParser.parseHunks("@@ -10,2 +10,3 @@\n context\n+added\n context2\n")
        #expect(hunks.count == 1)
        #expect(hunks[0].oldStart == 10 && hunks[0].newCount == 3)
        #expect(hunks[0].lines.map(\.kind) == [.context, .added, .context])
    }

    @Test func hunkHeaderDefaultsCountToOne() throws {
        let header = try #require(DiffParser.parseHunkHeader("@@ -3 +4 @@"))
        #expect(header.0 == 3 && header.1 == 1 && header.2 == 4 && header.3 == 1)
    }
}

@Suite struct TreeAndBlameParserTests {
    @Test func lsTreeSortsFoldersFirst() {
        let output = "100644 blob aaa\tREADME.md\u{0}040000 tree bbb\tSources\u{0}100644 blob ccc\tPackage.swift\u{0}"
        let entries = LsTreeParser.parse(output)
        #expect(entries.map(\.path) == ["Sources", "Package.swift", "README.md"])
        #expect(entries[0].isDirectory)
    }

    @Test func blameReadsAuthorsOnce() {
        let hash = String(repeating: "a", count: 40)
        let output = "\(hash) 1 1 2\nauthor Minh Tran\nsummary First\n\tline one\n\(hash) 2 2\n\tline two\n"
        let lines = BlameParser.parse(output)
        #expect(lines.count == 2)
        #expect(lines[1].author == "Minh Tran")
        #expect(lines[1].lineNumber == 2)
        #expect(lines[0].content == "line one")
    }
}

@Suite struct GraphLaneBuilderTests {
    func commit(_ hash: String, _ parents: [String]) -> Commit {
        Commit(hash: hash, parents: parents, authorName: "", authorEmail: "", date: .now, subject: hash)
    }

    @Test func linearHistoryStaysInLaneZero() {
        var builder = GraphLaneBuilder()
        let rows = builder.rows(for: [commit("c", ["b"]), commit("b", ["a"]), commit("a", [])])
        #expect(rows.map(\.lane) == [0, 0, 0])
        #expect(rows[2].bottom.isEmpty)
    }

    @Test func mergeOpensAndClosesASecondLane() {
        var builder = GraphLaneBuilder()
        // m merges f into d; f and d both come from a.
        let rows = builder.rows(for: [commit("m", ["d", "f"]), commit("f", ["a"]), commit("d", ["a"]), commit("a", [])])
        #expect(rows[0].lane == 0)
        #expect(rows[0].bottom.contains(GraphEdge(from: 0, to: 1, color: rows[0].bottom.first { $0.to == 1 }!.color)))
        #expect(rows[1].lane == 1)
        #expect(rows[2].lane == 0)
        #expect(rows[3].lane == 0)
        #expect(rows[3].top.contains { $0.from == 1 && $0.to == 0 })
    }

    @Test func lanesContinueAcrossPages() {
        var builder = GraphLaneBuilder()
        _ = builder.rows(for: [commit("m", ["d", "f"])])
        let next = builder.rows(for: [commit("f", ["a"])])
        #expect(next[0].lane == 1)
    }
}

@Suite struct MergeStatusMapperTests {
    @Test(arguments: [
        ("mergeable", MergeAction.merge),
        ("need_rebase", .rebase),
        ("conflict", .resolveWithAI),
        ("broken_status", .resolveWithAI),
        ("not_approved", .needsApproval),
        ("checking", .checking),
        ("unchecked", .checking),
    ])
    func mapsSpecStatuses(status: String, expected: MergeAction) {
        #expect(MergeStatusMapper.action(for: status) == expected)
    }

    @Test func pipelineAndBlockedStatusesExplainWhy() {
        if case .waitForPipeline(let reason) = MergeStatusMapper.action(for: "ci_still_running") {
            #expect(reason.contains("running"))
        } else {
            Issue.record("ci_still_running should wait for the pipeline")
        }
        for status in ["draft_status", "discussions_not_resolved", "blocked_status"] {
            if case .blocked = MergeStatusMapper.action(for: status) {} else { Issue.record("\(status) should be blocked") }
        }
        #expect(MergeStatusMapper.action(for: "mergeable", state: "merged") == .closed("This merge request is merged."))
    }

    @Test func listLabels() {
        #expect(MergeStatusMapper.label(for: "draft_status", state: "opened") == "Draft")
        #expect(MergeStatusMapper.label(for: "conflict", state: "opened") == "Conflicts")
        #expect(MergeStatusMapper.label(for: nil, state: "merged") == "Merged")
    }
}

@Suite struct TokenTextTests {
    @Test func extractsTokenFromSSHOutput() {
        let output = "Token:   glpat-AbC_12-xyZ890qwertyuio\nScopes:  api,read_repository\nExpires: 2026-11-28\n"
        #expect(TokenText.extract(from: output) == "glpat-AbC_12-xyZ890qwertyuio")
        #expect(TokenText.extract(from: "remote: Disallowed command") == nil)
    }

    @Test func redactsAndMasks() {
        #expect(TokenText.redact("x glpat-secretsecret123 y") == "x glpat-[REDACTED] y")
        #expect(TokenText.masked("glpat-EXAMPLEexample0000a1b2") == "glpat-••••a1b2")
    }

    @Test func classifiesSSHFailures() {
        #expect(SSHTokenGenerator.classify(output: "git@x: Permission denied (publickey).", timedOut: false) == .permissionDenied)
        #expect(SSHTokenGenerator.classify(output: "remote: Unknown command", timedOut: false) == .noTokenInOutput)
        #expect(SSHTokenGenerator.classify(output: "", timedOut: true) == .unreachable)
    }
}

@Suite struct DomainParserTests {
    @Test(arguments: [
        ("gitlab.corp.example.com", "gitlab.corp.example.com", "https://gitlab.corp.example.com"),
        ("  GITLAB.CORP.EXAMPLE.COM/  ", "gitlab.corp.example.com", "https://gitlab.corp.example.com"),
        ("https://gitlab.corp.example.com/mobile/ios-app/-/merge_requests/476", "gitlab.corp.example.com", "https://gitlab.corp.example.com"),
        ("git@gitlab.corp.example.com:mobile/ios-app.git", "gitlab.corp.example.com", "https://gitlab.corp.example.com"),
        ("https://code.example.com/gitlab/group/repo", "code.example.com/gitlab", "https://code.example.com/gitlab"),
        ("https://git.example.com:8443", "git.example.com:8443", "https://git.example.com:8443"),
        ("http://gitlab.example.com", "gitlab.example.com", "https://gitlab.example.com"),
    ])
    func normalizes(input: String, key: String, url: String) throws {
        let parsed = try #require(DomainParser.parse(input))
        #expect(parsed.key == key)
        #expect(parsed.baseURL.absoluteString == url)
    }

    @Test(arguments: ["", "not a domain", "localhostx", "ftp://gitlab.example.com", ".example.com"])
    func rejects(input: String) {
        #expect(DomainParser.parse(input) == nil)
    }
}

@Suite struct DomainCheckerTests {
    @Test func a401WithJSONMeansGitLab() {
        #expect(DomainChecker.interpretAPI(status: 401, data: Data(#"{"message":"401 Unauthorized"}"#.utf8)).isPassed)
        #expect(DomainChecker.interpretAPI(status: 404, data: Data("<html></html>".utf8)).isFailure)
        #expect(DomainChecker.interpretAPI(status: 200, data: Data("<html></html>".utf8)).isFailure)
    }

    @Test func sshOutputs() {
        #expect(DomainChecker.interpretSSH(output: "Welcome to GitLab, @duc!", timedOut: false, host: "h", port: 22).isPassed)
        if case .warning(let text) = DomainChecker.interpretSSH(output: "Permission denied (publickey).", timedOut: false, host: "h", port: 22) {
            #expect(text.contains("ssh-add"))
        } else {
            Issue.record("Permission denied should be a warning")
        }
    }
}

@Suite struct CommandTemplateTests {
    @Test func tokenizesLikeAShell() throws {
        #expect(try CommandTemplate.tokenize(#"claude -p "{prompt}" --permission-mode acceptEdits"#) == ["claude", "-p", "{prompt}", "--permission-mode", "acceptEdits"])
        #expect(try CommandTemplate.tokenize(#"a 'b c' "d \"e\"" f\ g"#) == ["a", "b c", #"d "e""#, "f g"])
        #expect(throws: CommandTemplate.ParseError.unbalancedQuote) { try CommandTemplate.tokenize(#"a "b"#) }
    }

    @Test func fillsPlaceholdersInOnePass() throws {
        let tokens = try CommandTemplate.tokenize(#"aider --message "{prompt}" {conflicted_files}"#)
        let rendered = CommandTemplate.render(tokens, values: ["prompt": "fix {worktree} literally", "worktree": "/tmp/w"],
                                              lists: ["conflicted_files": ["a.swift", "b.swift"]])
        #expect(rendered == ["aider", "--message", "fix {worktree} literally", "a.swift", "b.swift"])
    }

    @Test func promptAlwaysEndsWithSafetyRules() {
        let prompt = AIPrompt.render(AITask.rebaseOntoTarget.defaultPrompt, values: ["worktree": "/tmp/w", "branch": "feature", "target": "develop"], files: ["a.swift", "b.swift"])
        #expect(prompt.contains("a.swift\nb.swift"))
        #expect(prompt.hasSuffix("Never run git push. Never change files outside /tmp/w."))
    }

    @Test func validationNeedsPrompt() {
        #expect(throws: CommandTemplate.ParseError.missingPrompt) { try CommandTemplate.validate("claude --version") }
    }
}

@Suite struct TokenInfoTests {
    @Test func daysLeftAndScopes() throws {
        let now = try #require(GitLabDate.day("2026-10-29"))
        let info = TokenInfo(id: 1, name: "gitlab-mac-client", scopes: ["read_api"], expiresAt: "2026-11-03")
        #expect(info.daysLeft(from: now) == 5)
        #expect(!info.canWrite)
    }
}
