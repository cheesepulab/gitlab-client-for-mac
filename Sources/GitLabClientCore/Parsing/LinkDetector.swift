import Foundation

/// Finds what GitLab turns into links in plain text: URLs, `!12` merge requests, `#34` issues
/// (optionally `group/project!12`) and `@user` mentions. Callers skip code spans themselves.
public enum LinkDetector {
    public enum Kind: Equatable, Sendable {
        case url(String)
        case mergeRequest(project: String?, iid: Int)
        case issue(project: String?, iid: Int)
        case mention(String)
    }

    public struct Match: Equatable, Sendable {
        public var range: Range<String.Index>
        public var text: String
        public var kind: Kind
    }

    private static let pattern = try! NSRegularExpression(pattern: [
        #"(https?://[^\s<>"'`]+)"#,
        #"((?<![\w/.&-])(?:([A-Za-z0-9_][A-Za-z0-9_.-]*(?:/[A-Za-z0-9_][A-Za-z0-9_.-]*)+))?([!#])([0-9]+)(?![\w]))"#,
        #"((?<![\w.@/-])@([A-Za-z0-9_](?:[A-Za-z0-9_.-]*[A-Za-z0-9_])?))"#,
    ].joined(separator: "|"))

    public static func matches(in text: String) -> [Match] {
        let whole = NSRange(text.startIndex..., in: text)
        var found: [Match] = []
        for result in pattern.matches(in: text, range: whole) {
            if let range = Range(result.range(at: 1), in: text) {
                let trimmed = trimURL(text[range])
                guard trimmed.count > "https://".count else { continue }
                let end = text.index(range.lowerBound, offsetBy: trimmed.count)
                found.append(Match(range: range.lowerBound..<end, text: trimmed, kind: .url(trimmed)))
            } else if let range = Range(result.range(at: 2), in: text),
                      let sigil = Range(result.range(at: 4), in: text), let number = Range(result.range(at: 5), in: text),
                      let iid = Int(text[number]) {
                let project = Range(result.range(at: 3), in: text).map { String(text[$0]) }
                let kind: Kind = text[sigil] == "!" ? .mergeRequest(project: project, iid: iid) : .issue(project: project, iid: iid)
                found.append(Match(range: range, text: String(text[range]), kind: kind))
            } else if let range = Range(result.range(at: 6), in: text), let name = Range(result.range(at: 7), in: text) {
                found.append(Match(range: range, text: String(text[range]), kind: .mention(String(text[name]))))
            }
        }
        return found
    }

    /// Drops sentence punctuation after a URL and a closing bracket that has no opening one.
    static func trimURL(_ url: Substring) -> String {
        var result = String(url)
        while let last = result.last {
            if ".,;:!?*_~".contains(last) {
                result.removeLast()
            } else if last == ")" && result.filter({ $0 == "(" }).count < result.filter({ $0 == ")" }).count {
                result.removeLast()
            } else if last == "]" && result.filter({ $0 == "[" }).count < result.filter({ $0 == "]" }).count {
                result.removeLast()
            } else {
                break
            }
        }
        return result
    }
}

/// Where a detected link goes: merge requests of the open project stay in the app, the rest
/// opens in the browser.
public enum LinkTarget: Equatable, Sendable {
    case mergeRequest(iid: Int)
    case web(URL)

    public static let appScheme = "gitlabclient"

    /// In-app targets ride on a private URL scheme so SwiftUI's link handling can carry them.
    public var url: URL {
        switch self {
        case .mergeRequest(let iid): return URL(string: "\(Self.appScheme)://merge-request/\(iid)")!
        case .web(let url): return url
        }
    }

    public init(url: URL) {
        if url.scheme == Self.appScheme, url.host == "merge-request", let iid = Int(url.lastPathComponent) {
            self = .mergeRequest(iid: iid)
        } else {
            self = .web(url)
        }
    }
}

public struct LinkResolver: Sendable {
    public var baseURL: URL
    public var projectPath: String

    public init(baseURL: URL, projectPath: String) {
        self.baseURL = baseURL
        self.projectPath = projectPath
    }

    public func target(for kind: LinkDetector.Kind) -> LinkTarget? {
        switch kind {
        case .url(let text):
            guard let url = URL(string: text) else { return nil }
            if let iid = mergeRequestIID(in: url) { return .mergeRequest(iid: iid) }
            return .web(url)
        case .mergeRequest(let project, let iid):
            if project == nil || project == projectPath { return .mergeRequest(iid: iid) }
            return web("\(project!)/-/merge_requests/\(iid)")
        case .issue(let project, let iid):
            return web("\(project ?? projectPath)/-/issues/\(iid)")
        case .mention(let username):
            return web(username)
        }
    }

    /// `https://<this server>/<this project>/-/merge_requests/12` → 12.
    func mergeRequestIID(in url: URL) -> Int? {
        guard url.host?.lowercased() == baseURL.host?.lowercased(), url.port == baseURL.port else { return nil }
        let base = baseURL.path.hasSuffix("/") ? String(baseURL.path.dropLast()) : baseURL.path
        let expected = "\(base)/\(projectPath)/-/merge_requests/"
        guard url.path.hasPrefix(expected) else { return nil }
        let rest = url.path.dropFirst(expected.count).split(separator: "/").first
        return rest.flatMap { Int($0) }
    }

    private func web(_ path: String) -> LinkTarget? {
        let base = baseURL.absoluteString.hasSuffix("/") ? String(baseURL.absoluteString.dropLast()) : baseURL.absoluteString
        return URL(string: "\(base)/\(path)").map(LinkTarget.web)
    }
}
