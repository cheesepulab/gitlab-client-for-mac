import Foundation
import Testing
@testable import GitLabClientCore

/// Serves canned responses per host, so tests running in parallel don't share a handler.
final class StubURLProtocol: URLProtocol, @unchecked Sendable {
    typealias Handler = @Sendable (URLRequest) throws -> (Int, Data, [String: String])

    private static let lock = NSLock()
    nonisolated(unsafe) private static var handlers: [String: Handler] = [:]

    static func register(host: String, handler: @escaping Handler) {
        lock.lock(); defer { lock.unlock() }
        handlers[host] = handler
    }

    static func session() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        return URLSession(configuration: configuration)
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.lock.lock()
        let handler = request.url?.host.flatMap { Self.handlers[$0] }
        Self.lock.unlock()
        guard let handler else {
            client?.urlProtocol(self, didFailWithError: URLError(.cannotFindHost))
            return
        }
        do {
            let (status, data, headers) = try handler(request)
            let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}

final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    func next() -> Int { lock.lock(); defer { lock.unlock() }; value += 1; return value }
    var count: Int { lock.lock(); defer { lock.unlock() }; return value }
}

@Suite struct APIErrorMappingTests {
    func client(host: String, token: String = "glpat-test", reauth: GitLabAPIClient.ReauthHandler? = nil,
                handler: @escaping StubURLProtocol.Handler) -> GitLabAPIClient {
        StubURLProtocol.register(host: host, handler: handler)
        return GitLabAPIClient(baseURL: URL(string: "https://\(host)")!, session: StubURLProtocol.session(),
                               tokenProvider: { token }, onUnauthorized: reauth)
    }

    @Test func sendsTokenHeaderAndDecodesSnakeCase() async throws {
        let api = client(host: "ok.test") { request in
            #expect(request.value(forHTTPHeaderField: "PRIVATE-TOKEN") == "glpat-test")
            #expect(request.url?.path == "/api/v4/user")
            return (200, Data(#"{"id":7,"username":"duc","name":"Duc Nguyen","avatar_url":null}"#.utf8), [:])
        }
        let user = try await api.currentUser()
        #expect(user.username == "duc")
        #expect(user.initials == "DN")
    }

    @Test func unauthorizedAsksForANewTokenOnceThenRetries() async throws {
        let calls = Counter()
        let reauths = Counter()
        let api = client(host: "reauth.test", reauth: { _ = reauths.next(); return true }) { _ in
            calls.next() == 1 ? (401, Data(#"{"message":"401 Unauthorized"}"#.utf8), [:])
                : (200, Data(#"{"id":1,"name":"t","scopes":["api"],"expires_at":"2026-12-01"}"#.utf8), [:])
        }
        let info = try await api.tokenInfo()
        #expect(info.canWrite)
        #expect(calls.count == 2)
        #expect(reauths.count == 1)
    }

    @Test func unauthorizedWithoutNewTokenThrows() async {
        let api = client(host: "noreauth.test", reauth: { false }) { _ in (401, Data(#"{"message":"401 Unauthorized"}"#.utf8), [:]) }
        await #expect(throws: GitLabAPIError.unauthorized) { try await api.currentUser() }
    }

    @Test func mapsStatusCodes() async {
        let cases: [(Int, String, GitLabAPIError)] = [
            (403, #"{"error":"insufficient_scope","scope":"api"}"#, .forbidden(missingScope: "api")),
            (404, #"{"message":"404 Not found"}"#, .notFound),
            (405, #"{"message":"Method Not Allowed"}"#, .methodNotAllowed(reason: "Method Not Allowed")),
            (406, #"{"message":"Branch cannot be merged"}"#, .notAcceptable(message: "Branch cannot be merged")),
            (409, #"{"message":"SHA does not match HEAD of source branch"}"#, .conflict(message: "SHA does not match HEAD of source branch")),
            (500, #"{"message":{"base":["went wrong"]}}"#, .server(status: 500, message: "base went wrong")),
        ]
        for (index, (status, body, expected)) in cases.enumerated() {
            let api = client(host: "status\(index).test") { _ in (status, Data(body.utf8), [:]) }
            await #expect(throws: expected) { try await api.currentUser() }
        }
    }

    @Test func networkErrorsAreTyped() async {
        let api = client(host: "down.test") { _ in throw URLError(.timedOut) }
        do {
            _ = try await api.currentUser()
            Issue.record("Expected a network error")
        } catch let error as GitLabAPIError {
            guard case .network(let code, _) = error else { Issue.record("Expected .network, got \(error)"); return }
            #expect(code == .timedOut)
        } catch {
            Issue.record("Unexpected error \(error)")
        }
    }

    @Test func followsXNextPage() async throws {
        let api = client(host: "pages.test") { request in
            let page = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "page" }?.value
            let project = { (id: Int) in #"{"id":\#(id),"name":"p\#(id)","name_with_namespace":"g / p","path_with_namespace":"g/p\#(id)","ssh_url_to_repo":"git@h:g/p.git"}"# }
            if page == "1" { return (200, Data("[\(project(1)),\(project(2))]".utf8), ["X-Next-Page": "2"]) }
            return (200, Data("[\(project(3))]".utf8), ["X-Next-Page": ""])
        }
        var ids: [Int] = []
        for try await page in api.projects() { ids += page.map(\.id) }
        #expect(ids == [1, 2, 3])
    }

    @Test func mergeSendsSHAAndOptions() async throws {
        let api = client(host: "merge.test") { request in
            #expect(request.httpMethod == "PUT")
            let body = try JSONSerialization.jsonObject(with: request.bodyData()) as? [String: Any]
            #expect(body?["sha"] as? String == "abc123")
            #expect(body?["squash"] as? Bool == true)
            #expect(body?["should_remove_source_branch"] as? Bool == false)
            return (200, Data(#"{"id":1,"iid":5,"project_id":9,"title":"t","state":"merged","author":{"name":"A","username":"a"},"source_branch":"f","target_branch":"main","updated_at":"2026-10-29T08:00:00.000Z"}"#.utf8), [:])
        }
        let merged = try await api.merge(projectID: 9, iid: 5, sha: "abc123", squash: true, removeSourceBranch: false)
        #expect(merged.state == "merged")
    }
}

extension URLRequest {
    /// URLProtocol receives uploads as a stream.
    func bodyData() -> Data {
        if let httpBody { return httpBody }
        guard let stream = httpBodyStream else { return Data() }
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let read = stream.read(&buffer, maxLength: buffer.count)
            if read <= 0 { break }
            data.append(buffer, count: read)
        }
        return data
    }
}
