import Foundation

public enum CheckState: Sendable, Equatable {
    case pending
    case passed(String)
    case warning(String)
    case failed(String)

    public var detail: String? {
        switch self {
        case .pending: return nil
        case .passed(let text), .warning(let text), .failed(let text): return text
        }
    }

    public var isFailure: Bool { if case .failed = self { return true } else { return false } }
    public var isPassed: Bool { if case .passed = self { return true } else { return false } }
}

/// Checks a domain before the user is asked for a token: is GitLab's API there, does SSH answer.
public enum DomainChecker {
    public static func checkAPI(baseURL: URL, session: URLSession = .shared) async -> CheckState {
        var request = URLRequest(url: baseURL.appending(path: "api/v4/version"), timeoutInterval: 10)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else { return .failed("The server didn't answer over HTTP.") }
            return interpretAPI(status: http.statusCode, data: data)
        } catch let error as URLError {
            switch error.code {
            case .serverCertificateUntrusted, .serverCertificateHasBadDate, .serverCertificateHasUnknownRoot,
                 .serverCertificateNotYetValid, .secureConnectionFailed, .clientCertificateRejected:
                return .failed("HTTPS failed: macOS doesn't trust this server's certificate.")
            case .cannotFindHost, .dnsLookupFailed:
                return .failed("There's no such host. Check the spelling, the VPN or the company network.")
            case .timedOut, .cannotConnectToHost, .networkConnectionLost, .notConnectedToInternet:
                return .failed("The request timed out or was refused. Check the VPN or company network, then try again.")
            case .cancelled:
                return .pending
            default:
                return .failed(error.localizedDescription)
            }
        } catch {
            return .failed(error.localizedDescription)
        }
    }

    /// A 401 is the good case: GitLab is there and wants a token.
    public static func interpretAPI(status: Int, data: Data) -> CheckState {
        let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        switch status {
        case 401 where json != nil:
            return .passed("GET /api/v4/version answered 401, so GitLab is there and wants a token.")
        case 200 where json?["version"] != nil:
            return .passed("GitLab \(json?["version"] ?? "") answered.")
        case 200, 404:
            let page = json == nil ? " with a web page" : ""
            return .failed("/api/v4/version returned \(status)\(page), so this isn't a GitLab API. Check the domain, or add the path if GitLab runs under one, such as host/gitlab.")
        default:
            return .failed("/api/v4/version returned HTTP \(status).")
        }
    }

    public static func checkSSH(host: String, port: Int) async -> CheckState {
        let env = await ShellEnvironment.shared.environment()
        let arguments = ["-T", "-o", "BatchMode=yes", "-o", "ConnectTimeout=10", "-o", "StrictHostKeyChecking=yes",
                         "-p", String(port), "git@\(host)"]
        guard let result = try? await ProcessRunner.run("/usr/bin/ssh", arguments, environment: env, timeout: .seconds(15)) else {
            return .warning("Couldn't run ssh.")
        }
        return interpretSSH(output: result.combinedOutput, timedOut: result.timedOut, host: host, port: port)
    }

    public static func interpretSSH(output: String, timedOut: Bool, host: String, port: Int) -> CheckState {
        if output.contains("Welcome to GitLab") {
            let user = output.firstMatch(of: #/@([A-Za-z0-9_.\-]+)/#).map { " as @\($0.1)" } ?? ""
            return .passed("git@\(host) answered on port \(port) and knows your key\(user).")
        }
        if output.contains("Permission denied") {
            return .warning("SSH answered but refused your key (Permission denied (publickey)). Load it with ssh-add, or add it to your GitLab account.")
        }
        if output.contains("Host key verification failed") {
            return .warning("\(host)'s host key isn't in known_hosts yet. Run ssh -T git@\(host) once in Terminal to trust it.")
        }
        if timedOut || output.contains("timed out") || output.contains("Connection refused") || output.contains("Could not resolve") {
            return .warning("SSH on port \(port) didn't answer. Repos and merge requests still work; cloning, history and AI resolve need SSH.")
        }
        let firstLine = output.split(separator: "\n").first.map(String.init) ?? "no output"
        return .warning("SSH check failed: \(TokenText.redact(firstLine))")
    }
}

/// Mints a token over SSH (GitLab 16.5+): ssh git@host personal_access_token <name> <scopes> <days>.
public enum SSHTokenGenerator {
    public enum Failure: Error, LocalizedError, Equatable {
        case permissionDenied
        case hostKey
        case unreachable
        case noTokenInOutput

        public var errorDescription: String? {
            switch self {
            case .permissionDenied:
                return "Permission denied (publickey): your SSH key isn't loaded in ssh-agent, or isn't on your GitLab account."
            case .hostKey:
                return "The host key isn't trusted yet. Run the command once in Terminal to accept it."
            case .unreachable:
                return "SSH didn't answer. Check the VPN or company network."
            case .noTokenInOutput:
                return "No token in the output. The server may be older than 16.5 or have the command turned off. Ask someone with web access instead."
            }
        }
    }

    public static func arguments(host: String, port: Int, name: String, scopes: [String], days: Int) -> [String] {
        var args = ["-T", "-o", "BatchMode=yes", "-o", "ConnectTimeout=15"]
        if port != 22 { args += ["-p", String(port)] }
        return args + ["git@\(host)", "personal_access_token", name, scopes.joined(separator: ","), String(days)]
    }

    public static func displayCommand(host: String, port: Int, name: String, scopes: [String], days: Int) -> String {
        let portFlag = port == 22 ? "" : "-p \(port) "
        return "ssh \(portFlag)git@\(host) personal_access_token \(name) \(scopes.joined(separator: ",")) \(days)"
    }

    /// Runs the command and returns the token. The raw output is never logged or returned.
    public static func generate(host: String, port: Int, name: String, scopes: [String], days: Int) async throws -> String {
        let env = await ShellEnvironment.shared.environment()
        let result = try await ProcessRunner.run("/usr/bin/ssh", arguments(host: host, port: port, name: name, scopes: scopes, days: days),
                                                 environment: env, timeout: .seconds(30))
        let output = result.stdout + "\n" + result.stderr
        if let token = TokenText.extract(from: output) { return token }
        throw classify(output: output, timedOut: result.timedOut)
    }

    public static func classify(output: String, timedOut: Bool) -> Failure {
        if output.contains("Permission denied") { return .permissionDenied }
        if output.contains("Host key verification failed") { return .hostKey }
        if timedOut || output.contains("timed out") || output.contains("Could not resolve") || output.contains("Connection refused") {
            return .unreachable
        }
        return .noTokenInOutput
    }
}
