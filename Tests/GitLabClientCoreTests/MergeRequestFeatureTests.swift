import Foundation
import Testing
@testable import GitLabClientCore

@Suite struct LinkDetectionTests {
    func kinds(_ text: String) -> [LinkDetector.Kind] { LinkDetector.matches(in: text).map(\.kind) }
    func texts(_ text: String) -> [String] { LinkDetector.matches(in: text).map(\.text) }

    @Test func findsURLsWithoutTrailingPunctuation() {
        #expect(texts("Spec: https://wiki.example.com/mobile/face-id. Done") == ["https://wiki.example.com/mobile/face-id"])
        #expect(texts("(see https://example.com/a)") == ["https://example.com/a"])
        #expect(texts("https://en.wikipedia.org/wiki/Swift_(language), ok") == ["https://en.wikipedia.org/wiki/Swift_(language)"])
        #expect(texts("http://host:8080/x?a=1&b=2#top!") == ["http://host:8080/x?a=1&b=2#top"])
        #expect(texts("no scheme example.com here").isEmpty)
    }

    @Test func findsGitLabReferences() {
        #expect(kinds("Closes #1203 and builds on !476.") == [.issue(project: nil, iid: 1203), .mergeRequest(project: nil, iid: 476)])
        #expect(kinds("See mobile/android-app!12") == [.mergeRequest(project: "mobile/android-app", iid: 12)])
        #expect(kinds("ping @lan.pham, thanks") == [.mention("lan.pham")])
    }

    @Test func ignoresLookalikes() {
        #expect(kinds("mail duc@example.com").isEmpty)
        #expect(kinds("C#1 and abc!12 and &#39;").isEmpty)
        #expect(kinds("## Heading").isEmpty)
    }

    @Test func urlsKeepTheirFragments() {
        #expect(kinds("https://example.com/page#12") == [.url("https://example.com/page#12")])
    }

    @Test func resolvesTargets() {
        let resolver = LinkResolver(baseURL: URL(string: "https://gitlab.example.com")!, projectPath: "mobile/ios-app")
        #expect(resolver.target(for: .mergeRequest(project: nil, iid: 476)) == .mergeRequest(iid: 476))
        #expect(resolver.target(for: .mergeRequest(project: "mobile/ios-app", iid: 5)) == .mergeRequest(iid: 5))
        #expect(resolver.target(for: .mergeRequest(project: "web/portal", iid: 5)) == .web(URL(string: "https://gitlab.example.com/web/portal/-/merge_requests/5")!))
        #expect(resolver.target(for: .issue(project: nil, iid: 9)) == .web(URL(string: "https://gitlab.example.com/mobile/ios-app/-/issues/9")!))
        #expect(resolver.target(for: .mention("lan.pham")) == .web(URL(string: "https://gitlab.example.com/lan.pham")!))
        #expect(resolver.target(for: .url("https://gitlab.example.com/mobile/ios-app/-/merge_requests/12/diffs")) == .mergeRequest(iid: 12))
        #expect(resolver.target(for: .url("https://gitlab.example.com/web/portal/-/merge_requests/12")) == .web(URL(string: "https://gitlab.example.com/web/portal/-/merge_requests/12")!))
    }

    @Test func appLinksRoundTrip() {
        let target = LinkTarget.mergeRequest(iid: 482)
        #expect(LinkTarget(url: target.url) == target)
        #expect(LinkTarget(url: URL(string: "https://example.com")!) == .web(URL(string: "https://example.com")!))
    }
}

@Suite struct ActivityAndPipelineParsingTests {
    @Test func systemNotesBecomeSentenceAndItems() {
        let body = "added 2 commits\n\n<ul><li>3f2a91c - Fall back to the passcode</li><li>9b0c4de - Add BiometricGate tests</li></ul>\n\n[Compare with previous version](/mobile/ios-app/-/merge_requests/482/diffs?diff_id=1)"
        let parsed = SystemNote.parse(body)
        #expect(parsed.text == "added 2 commits")
        #expect(parsed.items == ["3f2a91c - Fall back to the passcode", "9b0c4de - Add BiometricGate tests"])
        #expect(SystemNote.parse("marked this merge request as **ready**").text == "marked this merge request as ready")
    }

    @Test func discussionResolution() {
        let author = GitLabPerson(id: 1, name: "A", username: "a")
        let open = Discussion(id: "d", individualNote: false, notes: [
            Note(id: 1, body: "x", author: author, createdAt: "2026-10-29T08:00:00Z", resolvable: true, resolved: true),
            Note(id: 2, body: "y", author: author, createdAt: "2026-10-29T09:00:00Z", resolvable: true, resolved: false),
        ])
        #expect(open.isResolvable)
        #expect(!open.isResolved)
        let plain = Discussion(id: "e", individualNote: true, notes: [Note(id: 3, body: "z", author: author, createdAt: "2026-10-29T08:00:00Z")])
        #expect(!plain.isResolvable)
        #expect(!plain.isResolved)
    }

    @Test func jobLogDropsEscapesAndSections() {
        let raw = "section_start:1730000000:step_script\r\u{1B}[0K\u{1B}[0;m\u{1B}[32;1m$ swift test\u{1B}[0;m\n" +
            "Building 10%\rBuilding 100%\n\u{1B}[31;1mERROR: Job failed: exit status 1\u{1B}[0;m\nsection_end:1730000001:step_script\r\u{1B}[0K\n\n"
        let lines = JobLog.lines(raw)
        #expect(lines.map(\.text) == ["$ swift test", "Building 100%", "ERROR: Job failed: exit status 1"])
        #expect(lines[0].tone == .command)
        #expect(lines[2].tone == .error)
    }

    @Test func stagesKeepRunOrderAndLatestAttempt() {
        let jobs = [
            Job(id: 10, name: "build", stage: "build", status: "success"),
            Job(id: 11, name: "unit", stage: "test", status: "failed"),
            Job(id: 12, name: "lint", stage: "test", status: "success"),
            Job(id: 13, name: "deploy", stage: "deploy", status: "manual"),
            Job(id: 20, name: "unit", stage: "test", status: "running"),
        ]
        let stages = PipelineStage.group(jobs)
        #expect(stages.map(\.name) == ["build", "test", "deploy"])
        #expect(stages[1].jobs.map(\.id) == [20, 12])
    }

    @Test func jobActionsFollowStatus() {
        #expect(JobAction.available(for: .running) == .cancel)
        #expect(JobAction.available(for: .manual) == .play)
        #expect(JobAction.available(for: .failed) == .retry)
        #expect(JobAction.available(for: .skipped) == nil)
        #expect(CIStatus("canceled").canRetryPipeline)
        #expect(CIStatus("running").canCancelPipeline)
        #expect(!CIStatus("success").canRetryPipeline)
    }
}

@Suite struct MergeRequestEditTests {
    @Test func draftPrefixes() {
        #expect(DraftTitle.split("Draft: Add Face ID") == (true, "Add Face ID"))
        #expect(DraftTitle.split("[Draft] (draft) Add") == (true, "Add"))
        #expect(DraftTitle.split("Drafting the plan") == (false, "Drafting the plan"))
        #expect(DraftTitle.compose("Add Face ID", draft: true) == "Draft: Add Face ID")
        #expect(DraftTitle.compose("Draft: Add Face ID", draft: false) == "Add Face ID")
    }

    @Test func bodyHasOnlyChangedFields() {
        var mr = MergeRequest(id: 1, iid: 482, projectId: 11, title: "Draft: Add Face ID", author: GitLabPerson(name: "H", username: "h"),
                              sourceBranch: "feature/face-id", targetBranch: "develop")
        mr.assignees = [GitLabPerson(id: 4, name: "H", username: "h")]
        mr.reviewers = [GitLabPerson(id: 7, name: "M", username: "m")]
        mr.squash = false
        mr.forceRemoveSourceBranch = true
        let original = MergeRequestEdit(mr)
        #expect(original.draft)
        #expect(original.title == "Add Face ID")

        var edit = original
        #expect(edit.body(from: original).isEmpty)
        edit.draft = false
        edit.targetBranch = "main"
        edit.reviewerIDs = []
        let body = edit.body(from: original)
        #expect(body["title"] as? String == "Add Face ID")
        #expect(body["target_branch"] as? String == "main")
        #expect(body["reviewer_ids"] as? [Int] == [0])
        #expect(body["assignee_ids"] == nil)
        #expect(edit.changes(from: original) == [.draft, .targetBranch, .reviewers])
    }

    @Test func squashPolicy() {
        #expect(SquashPolicy(projectOption: "always").forcedValue == true)
        #expect(SquashPolicy(projectOption: "never").isLocked)
        #expect(SquashPolicy(projectOption: "default_on") == .choose(defaultOn: true))
        #expect(SquashPolicy(projectOption: nil) == .choose(defaultOn: false))
    }

    @Test func serverVersions() {
        #expect(ServerVersion(version: "17.11.2-ee").atLeast(17, 11))
        #expect(!ServerVersion(version: "16.9.0").atLeast(17, 0))
        #expect(ServerVersion(version: "19.5.0-pre").atLeast(19, 5))
    }
}

@Suite struct MergeRequestAPITests {
    static let mrJSON = #"{"id":1,"iid":5,"project_id":9,"title":"t","state":"opened","author":{"name":"A","username":"a"},"source_branch":"f","target_branch":"main","updated_at":"2026-10-29T08:00:00.000Z","merge_when_pipeline_succeeds":true}"#

    func client(host: String, reauth: GitLabAPIClient.ReauthHandler? = nil, handler: @escaping StubURLProtocol.Handler) -> GitLabAPIClient {
        StubURLProtocol.register(host: host, handler: handler)
        return GitLabAPIClient(baseURL: URL(string: "https://\(host)")!, session: StubURLProtocol.session(),
                               tokenProvider: { "glpat-test" }, onUnauthorized: reauth)
    }

    @Test func approveSendsSHAAndSkipsTokenPromptOn401() async throws {
        let reauths = Counter()
        let api = client(host: "approve.test", reauth: { _ = reauths.next(); return true }) { request in
            #expect(request.httpMethod == "POST")
            #expect(request.url?.path == "/api/v4/projects/9/merge_requests/5/approve")
            let body = try JSONSerialization.jsonObject(with: request.bodyData()) as? [String: Any]
            if body?["approval_password"] == nil { return (401, Data(#"{"message":"401 Unauthorized"}"#.utf8), [:]) }
            #expect(body?["sha"] as? String == "abc")
            return (201, Data(#"{"approved":true,"user_has_approved":true,"approved_by":[{"user":{"name":"D","username":"d"}}]}"#.utf8), [:])
        }
        await #expect(throws: GitLabAPIError.unauthorized) { try await api.approve(projectID: 9, iid: 5, sha: "abc") }
        #expect(reauths.count == 0)
        let approvals = try await api.approve(projectID: 9, iid: 5, sha: "abc", password: "test-password")
        #expect(approvals.userHasApproved == true)
    }

    @Test func autoMergeSendsOldAndNewFlags() async throws {
        let api = client(host: "auto.test") { request in
            #expect(request.httpMethod == "PUT")
            let body = try JSONSerialization.jsonObject(with: request.bodyData()) as? [String: Any]
            #expect(body?["auto_merge"] as? Bool == true)
            #expect(body?["merge_when_pipeline_succeeds"] as? Bool == true)
            #expect(body?["sha"] as? String == "abc")
            return (200, Data(Self.mrJSON.utf8), [:])
        }
        let mr = try await api.setAutoMerge(projectID: 9, iid: 5, sha: "abc", squash: true, removeSourceBranch: true)
        #expect(mr.mergeWhenPipelineSucceeds == true)
    }

    @Test func cancelAutoMergeFallsBackToTheOldEndpoint() async throws {
        let paths = PathLog()
        let api = client(host: "cancel.test") { request in
            paths.append(request.url!.path)
            if request.url!.path.hasSuffix("/cancel_auto_merge") { return (404, Data(#"{"message":"404 Not Found"}"#.utf8), [:]) }
            return (200, Data(Self.mrJSON.utf8), [:])
        }
        _ = try await api.cancelAutoMerge(projectID: 9, iid: 5)
        #expect(paths.all == ["/api/v4/projects/9/merge_requests/5/cancel_auto_merge",
                              "/api/v4/projects/9/merge_requests/5/cancel_merge_when_pipeline_succeeds"])
    }

    @Test func peopleLimitsUseGraphQL() async {
        let api = client(host: "graphql.test") { request in
            #expect(request.url?.path == "/api/graphql")
            let body = try JSONSerialization.jsonObject(with: request.bodyData()) as? [String: Any]
            #expect((body?["variables"] as? [String: Any])?["iid"] as? String == "5")
            return (200, Data(#"{"data":{"project":{"mergeRequest":{"allowsMultipleAssignees":true,"allowsMultipleReviewers":false}}}}"#.utf8), [:])
        }
        let limits = await api.peopleLimits(projectPath: "g/p", iid: 5)
        #expect(limits == PeopleLimits(multipleAssignees: true, multipleReviewers: false))

        let broken = client(host: "nographql.test") { _ in (404, Data(), [:]) }
        #expect(await broken.peopleLimits(projectPath: "g/p", iid: 5) == .single)
    }

    @Test func updateSendsOnlyChanges() async throws {
        let api = client(host: "update.test") { request in
            #expect(request.httpMethod == "PUT")
            let body = try JSONSerialization.jsonObject(with: request.bodyData()) as? [String: Any]
            #expect(body?.keys.sorted() == ["squash", "title"])
            #expect(body?["title"] as? String == "Draft: t")
            return (200, Data(Self.mrJSON.utf8), [:])
        }
        let original = MergeRequestEdit(title: "t", draft: false, description: "", targetBranch: "main", assigneeIDs: [], reviewerIDs: [],
                                        removeSourceBranch: true, squash: false)
        var edit = original
        edit.draft = true
        edit.squash = true
        _ = try await api.updateMergeRequest(projectID: 9, iid: 5, edit: edit, original: original)
    }

    @Test func jobLogIsText() async throws {
        let api = client(host: "trace.test") { request in
            #expect(request.url?.path == "/api/v4/projects/9/jobs/77/trace")
            return (200, Data("$ make\nok\n".utf8), ["Content-Type": "text/plain"])
        }
        #expect(try await api.jobLog(projectID: 9, jobID: 77) == "$ make\nok\n")
    }
}

final class PathLog: @unchecked Sendable {
    private let lock = NSLock()
    private var paths: [String] = []
    func append(_ path: String) { lock.lock(); paths.append(path); lock.unlock() }
    var all: [String] { lock.lock(); defer { lock.unlock() }; return paths }
}
