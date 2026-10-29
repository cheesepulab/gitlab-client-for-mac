import Foundation

public enum GitLabAPIError: Error, Equatable, Sendable, LocalizedError {
    case unauthorized
    case forbidden(missingScope: String?)
    case notFound
    case conflict(message: String)
    case methodNotAllowed(reason: String)
    case notAcceptable(message: String)
    case unprocessable(message: String)
    case server(status: Int, message: String)
    case network(code: URLError.Code, message: String)
    case decoding(String)

    /// Maps an HTTP status and body to a typed error; nil for 2xx.
    public static func from(status: Int, data: Data) -> GitLabAPIError? {
        guard !(200..<300).contains(status) else { return nil }
        let message = ErrorBody.message(from: data)
        switch status {
        case 401: return .unauthorized
        case 403: return .forbidden(missingScope: ErrorBody.scope(from: data))
        case 404: return .notFound
        case 405: return .methodNotAllowed(reason: message ?? "GitLab doesn't allow this merge right now.")
        case 406: return .notAcceptable(message: message ?? "GitLab can't do this right now.")
        case 409: return .conflict(message: message ?? "The merge request changed since it was loaded.")
        case 422: return .unprocessable(message: message ?? "GitLab rejected the request.")
        default: return .server(status: status, message: message ?? HTTPURLResponse.localizedString(forStatusCode: status))
        }
    }

    public static func from(_ error: URLError) -> GitLabAPIError {
        let message: String
        switch error.code {
        case .cannotFindHost, .dnsLookupFailed:
            message = "The host can't be found. Check the domain, the VPN or the company network."
        case .timedOut, .cannotConnectToHost, .networkConnectionLost, .notConnectedToInternet:
            message = "The host is unreachable. Check the VPN or the company network."
        case .serverCertificateUntrusted, .serverCertificateHasBadDate, .serverCertificateHasUnknownRoot,
             .serverCertificateNotYetValid, .secureConnectionFailed:
            message = "macOS doesn't trust this server's HTTPS certificate."
        default:
            message = error.localizedDescription
        }
        return .network(code: error.code, message: message)
    }

    public var errorDescription: String? {
        switch self {
        case .unauthorized: return "The token is invalid or expired."
        case .forbidden(let scope):
            if let scope { return "The token is missing the \(scope) scope." }
            return "The token doesn't have permission for this."
        case .notFound: return "GitLab couldn't find it (404)."
        case .conflict(let message), .methodNotAllowed(let message), .notAcceptable(let message), .unprocessable(let message):
            return message
        case .server(let status, let message): return "GitLab returned \(status): \(message)"
        case .network(_, let message): return message
        case .decoding(let detail): return "Unexpected response from GitLab: \(detail)"
        }
    }
}

enum ErrorBody {
    static func message(from data: Data) -> String? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            let text = String(decoding: data.prefix(300), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            return text.isEmpty || text.hasPrefix("<") ? nil : text
        }
        if let message = object["message"] { return flatten(message) }
        if let description = object["error_description"] as? String { return description }
        if let error = object["error"] { return flatten(error) }
        return nil
    }

    static func scope(from data: Data) -> String? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        if let scope = object["scope"] as? String { return scope }
        if let error = object["error"] as? String, error == "insufficient_scope" { return "api" }
        return nil
    }

    private static func flatten(_ value: Any) -> String {
        switch value {
        case let text as String: return text
        case let list as [Any]: return list.map(flatten).joined(separator: "; ")
        case let dict as [String: Any]:
            return dict.keys.sorted().map { "\($0) \(flatten(dict[$0]!))" }.joined(separator: "; ")
        default: return String(describing: value)
        }
    }
}

/// GitLab REST API v4 client for one domain. The token is read from the provider on every
/// request. On a 401 the client asks `onUnauthorized` for a new token once, then retries.
public actor GitLabAPIClient {
    public typealias TokenProvider = @Sendable () async throws -> String?
    public typealias ReauthHandler = @Sendable () async -> Bool

    public let baseURL: URL
    private let session: URLSession
    private let tokenProvider: TokenProvider
    private let onUnauthorized: ReauthHandler?
    private let decoder: JSONDecoder

    public init(baseURL: URL, session: URLSession = .shared, tokenProvider: @escaping TokenProvider, onUnauthorized: ReauthHandler? = nil) {
        self.baseURL = baseURL
        self.session = session
        self.tokenProvider = tokenProvider
        self.onUnauthorized = onUnauthorized
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        self.decoder = decoder
    }

    // MARK: Token and user

    public func currentUser() async throws -> GitLabUser { try await get("/user") }
    public func tokenInfo() async throws -> TokenInfo { try await get("/personal_access_tokens/self") }

    public func rotateToken() async throws -> RotatedToken {
        try await decode(send("POST", "/personal_access_tokens/self/rotate").0)
    }

    public func revokeToken() async throws {
        _ = try await send("DELETE", "/personal_access_tokens/self")
    }

    // MARK: Projects

    public nonisolated func projects(search: String? = nil) -> AsyncThrowingStream<[Project], Error> {
        var query = [URLQueryItem(name: "membership", value: "true"), URLQueryItem(name: "order_by", value: "last_activity_at"),
                     URLQueryItem(name: "archived", value: "false")]
        if let search, !search.isEmpty { query.append(URLQueryItem(name: "search", value: search)) }
        return pages("/projects", query: query)
    }

    public func starredProjectIDs() async throws -> Set<Int> {
        var ids = Set<Int>()
        for try await page in pages("/projects", query: [URLQueryItem(name: "starred", value: "true"), URLQueryItem(name: "simple", value: "true")]) as AsyncThrowingStream<[Project], Error> {
            ids.formUnion(page.map(\.id))
        }
        return ids
    }

    public func project(_ id: Int) async throws -> Project { try await get("/projects/\(id)") }

    // MARK: Merge requests

    public func mergeRequests(projectID: Int, state: String) async throws -> [MergeRequest] {
        try await get("/projects/\(projectID)/merge_requests", query: [
            URLQueryItem(name: "state", value: state), URLQueryItem(name: "order_by", value: "updated_at"),
            URLQueryItem(name: "per_page", value: "50"),
        ])
    }

    public func mergeRequest(projectID: Int, iid: Int, includeRebaseInProgress: Bool = false) async throws -> MergeRequest {
        var query: [URLQueryItem] = []
        if includeRebaseInProgress { query.append(URLQueryItem(name: "include_rebase_in_progress", value: "true")) }
        return try await get("/projects/\(projectID)/merge_requests/\(iid)", query: query)
    }

    public func mergeRequestCommits(projectID: Int, iid: Int) async throws -> [MergeRequestCommit] {
        try await get("/projects/\(projectID)/merge_requests/\(iid)/commits", query: [URLQueryItem(name: "per_page", value: "100")])
    }

    /// Fallback diff when the local MR ref isn't available. Older servers only have /changes.
    public func mergeRequestDiffs(projectID: Int, iid: Int) async throws -> [APIDiff] {
        do {
            return try await get("/projects/\(projectID)/merge_requests/\(iid)/diffs", query: [URLQueryItem(name: "per_page", value: "100")])
        } catch GitLabAPIError.notFound {
            let changes: APIChanges = try await get("/projects/\(projectID)/merge_requests/\(iid)/changes")
            return changes.changes
        }
    }

    public func approvals(projectID: Int, iid: Int) async throws -> Approvals {
        try await get("/projects/\(projectID)/merge_requests/\(iid)/approvals")
    }

    /// `sha` makes GitLab refuse (409) if the branch moved after the user looked. A 401 here can
    /// mean the project wants the user's password (`approval_password`), so it doesn't trigger
    /// the new-token flow; the caller checks the token separately.
    public func approve(projectID: Int, iid: Int, sha: String?, password: String? = nil) async throws -> Approvals {
        var body: [String: Any] = [:]
        if let sha { body["sha"] = sha }
        if let password { body["approval_password"] = password }
        return try await decode(send("POST", "/projects/\(projectID)/merge_requests/\(iid)/approve", body: body, reauth: false).0)
    }

    public func unapprove(projectID: Int, iid: Int) async throws {
        _ = try await send("POST", "/projects/\(projectID)/merge_requests/\(iid)/unapprove")
    }

    /// Passing `sha` makes GitLab refuse (409) if someone pushed after the user reviewed.
    public func merge(projectID: Int, iid: Int, sha: String?, squash: Bool, removeSourceBranch: Bool) async throws -> MergeRequest {
        var body: [String: Any] = ["squash": squash, "should_remove_source_branch": removeSourceBranch]
        if let sha { body["sha"] = sha }
        return try await decode(send("PUT", "/projects/\(projectID)/merge_requests/\(iid)/merge", body: body).0)
    }

    /// Sends both `auto_merge` (GitLab 17.11+) and `merge_when_pipeline_succeeds` (older). Each
    /// server ignores the one it doesn't know, so an old server never merges at once by mistake.
    public func setAutoMerge(projectID: Int, iid: Int, sha: String?, squash: Bool, removeSourceBranch: Bool) async throws -> MergeRequest {
        var body: [String: Any] = ["auto_merge": true, "merge_when_pipeline_succeeds": true,
                                   "squash": squash, "should_remove_source_branch": removeSourceBranch]
        if let sha { body["sha"] = sha }
        return try await decode(send("PUT", "/projects/\(projectID)/merge_requests/\(iid)/merge", body: body).0)
    }

    /// `cancel_auto_merge` on new servers, `cancel_merge_when_pipeline_succeeds` on older ones.
    public func cancelAutoMerge(projectID: Int, iid: Int) async throws -> MergeRequest {
        let base = "/projects/\(projectID)/merge_requests/\(iid)"
        do {
            return try await decode(send("POST", base + "/cancel_auto_merge").0)
        } catch GitLabAPIError.notFound {
            return try await decode(send("POST", base + "/cancel_merge_when_pipeline_succeeds").0)
        }
    }

    public func rebase(projectID: Int, iid: Int) async throws {
        _ = try await send("PUT", "/projects/\(projectID)/merge_requests/\(iid)/rebase")
    }

    /// Only the fields that differ from `original` are sent.
    public func updateMergeRequest(projectID: Int, iid: Int, edit: MergeRequestEdit, original: MergeRequestEdit) async throws -> MergeRequest {
        let body = edit.body(from: original)
        if body.isEmpty { return try await mergeRequest(projectID: projectID, iid: iid) }
        return try await decode(send("PUT", "/projects/\(projectID)/merge_requests/\(iid)", body: body).0)
    }

    public func setAssignees(projectID: Int, iid: Int, userIDs: [Int]) async throws -> MergeRequest {
        try await decode(send("PUT", "/projects/\(projectID)/merge_requests/\(iid)", body: ["assignee_ids": userIDs.isEmpty ? [0] : userIDs]).0)
    }

    public func setReviewers(projectID: Int, iid: Int, userIDs: [Int]) async throws -> MergeRequest {
        try await decode(send("PUT", "/projects/\(projectID)/merge_requests/\(iid)", body: ["reviewer_ids": userIDs.isEmpty ? [0] : userIDs]).0)
    }

    /// Multiple assignees and reviewers are paid features; only GraphQL says which this MR has.
    /// Falls back to one of each when the server can't answer.
    public func peopleLimits(projectPath: String, iid: Int) async -> PeopleLimits {
        let query = "query($path: ID!, $iid: String!) { project(fullPath: $path) { mergeRequest(iid: $iid) { allowsMultipleAssignees allowsMultipleReviewers } } }"
        guard let (data, _) = try? await send("POST", "/api/graphql", body: ["query": query, "variables": ["path": projectPath, "iid": String(iid)]], root: ""),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let mr = ((object["data"] as? [String: Any])?["project"] as? [String: Any])?["mergeRequest"] as? [String: Any] else {
            return .single
        }
        return PeopleLimits(multipleAssignees: mr["allowsMultipleAssignees"] as? Bool ?? false,
                            multipleReviewers: mr["allowsMultipleReviewers"] as? Bool ?? false)
    }

    public func version() async throws -> ServerVersion { try await get("/version") }

    // MARK: Activity

    public func discussions(projectID: Int, iid: Int) async throws -> [Discussion] {
        var all: [Discussion] = []
        for try await page in pages("/projects/\(projectID)/merge_requests/\(iid)/discussions", query: []) as AsyncThrowingStream<[Discussion], Error> {
            all += page
        }
        return all
    }

    public func addComment(projectID: Int, iid: Int, body: String) async throws -> Note {
        try await decode(send("POST", "/projects/\(projectID)/merge_requests/\(iid)/notes", body: ["body": body]).0)
    }

    public func reply(projectID: Int, iid: Int, discussionID: String, body: String) async throws -> Note {
        try await decode(send("POST", "/projects/\(projectID)/merge_requests/\(iid)/discussions/\(discussionID)/notes", body: ["body": body]).0)
    }

    public func resolveDiscussion(projectID: Int, iid: Int, discussionID: String, resolved: Bool) async throws -> Discussion {
        try await decode(send("PUT", "/projects/\(projectID)/merge_requests/\(iid)/discussions/\(discussionID)",
                              query: [URLQueryItem(name: "resolved", value: resolved ? "true" : "false")]).0)
    }

    // MARK: People

    /// Active members, including those inherited from groups.
    public func members(projectID: Int, search: String) async throws -> [ProjectMember] {
        var query = [URLQueryItem(name: "per_page", value: "50")]
        if !search.isEmpty { query.append(URLQueryItem(name: "query", value: search)) }
        let members: [ProjectMember] = try await get("/projects/\(projectID)/members/all", query: query)
        return members.filter { $0.state == nil || $0.state == "active" }
    }

    // MARK: Pipelines and jobs

    public func pipelines(projectID: Int, iid: Int) async throws -> [Pipeline] {
        try await get("/projects/\(projectID)/merge_requests/\(iid)/pipelines", query: [URLQueryItem(name: "per_page", value: "50")])
    }

    public func pipeline(projectID: Int, pipelineID: Int) async throws -> Pipeline {
        try await get("/projects/\(projectID)/pipelines/\(pipelineID)")
    }

    /// Retried attempts are included so `PipelineStage.group` can order stages correctly.
    public func jobs(projectID: Int, pipelineID: Int) async throws -> [Job] {
        var all: [Job] = []
        for try await page in pages("/projects/\(projectID)/pipelines/\(pipelineID)/jobs",
                                    query: [URLQueryItem(name: "include_retried", value: "true")]) as AsyncThrowingStream<[Job], Error> {
            all += page
        }
        return all
    }

    public func runPipeline(projectID: Int, iid: Int) async throws -> Pipeline {
        try await decode(send("POST", "/projects/\(projectID)/merge_requests/\(iid)/pipelines").0)
    }

    public func cancelPipeline(projectID: Int, pipelineID: Int) async throws -> Pipeline {
        try await decode(send("POST", "/projects/\(projectID)/pipelines/\(pipelineID)/cancel").0)
    }

    /// Reruns the failed and canceled jobs.
    public func retryPipeline(projectID: Int, pipelineID: Int) async throws -> Pipeline {
        try await decode(send("POST", "/projects/\(projectID)/pipelines/\(pipelineID)/retry").0)
    }

    public func perform(_ action: JobAction, projectID: Int, jobID: Int) async throws -> Job {
        try await decode(send("POST", "/projects/\(projectID)/jobs/\(jobID)/\(action.rawValue)").0)
    }

    public func jobLog(projectID: Int, jobID: Int) async throws -> String {
        String(decoding: try await send("GET", "/projects/\(projectID)/jobs/\(jobID)/trace").0, as: UTF8.self)
    }

    // MARK: Repository (fallback before the local clone exists)

    public func branches(projectID: Int, search: String = "") async throws -> [APIBranch] {
        var query = [URLQueryItem(name: "per_page", value: "100")]
        if !search.isEmpty { query.append(URLQueryItem(name: "search", value: search)) }
        return try await get("/projects/\(projectID)/repository/branches", query: query)
    }

    public func tree(projectID: Int, ref: String, path: String) async throws -> [APITreeItem] {
        var query = [URLQueryItem(name: "ref", value: ref), URLQueryItem(name: "per_page", value: "100")]
        if !path.isEmpty { query.append(URLQueryItem(name: "path", value: path)) }
        return try await get("/projects/\(projectID)/repository/tree", query: query)
    }

    public func rawFile(projectID: Int, path: String, ref: String) async throws -> Data {
        let encoded = path.addingPercentEncoding(withAllowedCharacters: .alphanumerics.union(CharacterSet(charactersIn: "-._~"))) ?? path
        return try await send("GET", "/projects/\(projectID)/repository/files/\(encoded)/raw",
                              query: [URLQueryItem(name: "ref", value: ref)], pathIsEncoded: true).0
    }

    // MARK: Plumbing

    public nonisolated func pages<T: Decodable & Sendable>(_ path: String, query: [URLQueryItem]) -> AsyncThrowingStream<[T], Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                var page: String? = "1"
                do {
                    while let current = page {
                        try Task.checkCancellation()
                        let (items, next): ([T], String?) = try await self.page(path, query: query + [
                            URLQueryItem(name: "page", value: current), URLQueryItem(name: "per_page", value: "100"),
                        ])
                        continuation.yield(items)
                        page = next
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private func page<T: Decodable & Sendable>(_ path: String, query: [URLQueryItem]) async throws -> ([T], String?) {
        let (data, response) = try await send("GET", path, query: query)
        let next = response.value(forHTTPHeaderField: "X-Next-Page").flatMap { $0.isEmpty ? nil : $0 }
        return (try decode(data), next)
    }

    private func get<T: Decodable>(_ path: String, query: [URLQueryItem] = []) async throws -> T {
        try await decode(send("GET", path, query: query).0)
    }

    private func decode<T: Decodable>(_ data: Data) throws -> T {
        do {
            return try decoder.decode(T.self, from: data)
        } catch {
            throw GitLabAPIError.decoding(String(describing: error).prefix(200).description)
        }
    }

    /// `root` is prepended to `path` (GraphQL lives outside /api/v4). With `reauth: false` a 401
    /// is thrown as is instead of asking for a new token.
    func send(_ method: String, _ path: String, query: [URLQueryItem] = [], body: [String: Any]? = nil,
              pathIsEncoded: Bool = false, root: String = "/api/v4", reauth: Bool = true, isRetry: Bool = false) async throws -> (Data, HTTPURLResponse) {
        guard var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false) else {
            throw GitLabAPIError.decoding("Bad base URL")
        }
        let basePath = components.path.hasSuffix("/") ? String(components.path.dropLast()) : components.path
        if pathIsEncoded {
            components.percentEncodedPath = basePath + root + path
        } else {
            components.path = basePath + root + path
        }
        if !query.isEmpty { components.queryItems = query }
        guard let url = components.url else { throw GitLabAPIError.decoding("Bad URL for \(path)") }

        var request = URLRequest(url: url, timeoutInterval: 30)
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let token = try await tokenProvider() {
            request.setValue(token, forHTTPHeaderField: "PRIVATE-TOKEN")
        }
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
        }

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch let error as URLError {
            if error.code == .cancelled { throw CancellationError() }
            throw GitLabAPIError.from(error)
        }
        guard let http = response as? HTTPURLResponse else { throw GitLabAPIError.decoding("Not an HTTP response") }

        if http.statusCode == 401, reauth, !isRetry, let onUnauthorized, await onUnauthorized() {
            return try await send(method, path, query: query, body: body, pathIsEncoded: pathIsEncoded, root: root, reauth: reauth, isRetry: true)
        }
        if let error = GitLabAPIError.from(status: http.statusCode, data: data) { throw error }
        return (data, http)
    }
}
