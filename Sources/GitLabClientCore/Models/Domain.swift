import Foundation

/// A GitLab server the user has added. Its token lives in the Keychain, never here.
public struct GitLabDomain: Codable, Hashable, Identifiable, Sendable {
    /// Normalized host plus optional port and path prefix, e.g. "gitlab.example.com".
    /// Also used as the Keychain account and the folder name for local clones.
    public var key: String
    public var baseURL: URL
    public var sshHost: String
    public var sshPort: Int
    public var username: String?
    public var displayName: String?

    public var id: String { key }
    public var host: String { baseURL.host() ?? key }
    public var apiURL: URL { baseURL.appending(path: "api/v4") }

    public init(key: String, baseURL: URL, sshHost: String, sshPort: Int = 22, username: String? = nil, displayName: String? = nil) {
        self.key = key
        self.baseURL = baseURL
        self.sshHost = sshHost
        self.sshPort = sshPort
        self.username = username
        self.displayName = displayName
    }

    /// Two-letter mark for the domain switcher, e.g. "EX" for gitlab.example.com.
    public var monogram: String {
        let parts = host.split(separator: ".").filter { $0 != "gitlab" && $0 != "www" }
        let source = parts.first.map(String.init) ?? host
        return String(source.prefix(2)).uppercased()
    }

    /// Folder-safe version of the key.
    public var folderName: String {
        key.map { $0.isLetter || $0.isNumber || $0 == "." || $0 == "-" ? $0 : "_" }.reduce(into: "") { $0.append($1) }
    }
}

public struct ParsedDomain: Equatable, Sendable {
    public let key: String
    public let baseURL: URL
    public let host: String
}

/// Turns whatever the user typed or pasted into a GitLab base URL.
public enum DomainParser {
    /// Accepts "gitlab.example.com", any URL on the server, or an SSH clone URL such as
    /// git@gitlab.example.com:group/repo.git. Only a leading "/gitlab" path is kept, since
    /// that is the usual relative URL root; anything else after the host is dropped.
    public static func parse(_ raw: String) -> ParsedDomain? {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !text.contains(" ") else { return nil }

        if !text.contains("://"), let at = text.firstIndex(of: "@") {
            let afterAt = text[text.index(after: at)...]
            text = afterAt.split(separator: ":").first.map(String.init) ?? String(afterAt)
        }
        if !text.contains("://") { text = "https://" + text }

        guard let components = URLComponents(string: text),
              let host = components.host?.lowercased(), isValidHost(host) else { return nil }
        let scheme = components.scheme?.lowercased() ?? "https"
        guard ["https", "http", "ssh"].contains(scheme) else { return nil }

        var base = URLComponents()
        let isLocal = host == "localhost" || host == "127.0.0.1"
        base.scheme = scheme == "http" && isLocal ? "http" : "https"
        base.host = host
        var key = host
        if scheme != "ssh", let port = components.port, port != 443, port != 80 {
            base.port = port
            key += ":\(port)"
        }
        if components.path.split(separator: "/").first?.lowercased() == "gitlab" {
            base.path = "/gitlab"
            key += "/gitlab"
        }
        guard let url = base.url else { return nil }
        return ParsedDomain(key: key, baseURL: url, host: host)
    }

    static func isValidHost(_ host: String) -> Bool {
        guard host.contains(".") || host == "localhost" else { return false }
        guard !host.hasPrefix("."), !host.hasSuffix("."), !host.hasPrefix("-") else { return false }
        return host.allSatisfy { $0.isLetter || $0.isNumber || $0 == "." || $0 == "-" }
    }
}
