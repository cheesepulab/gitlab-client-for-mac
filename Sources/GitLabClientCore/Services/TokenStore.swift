import Foundation
import Security

public struct KeychainError: Error, LocalizedError, Sendable {
    public let status: OSStatus

    public var errorDescription: String? {
        let message = SecCopyErrorMessageString(status, nil) as String? ?? "status \(status)"
        return "Keychain error: \(message)"
    }
}

/// The only component that reads or writes tokens. One generic password per domain:
/// service = the app's Keychain service, account = the domain key.
public actor TokenStore {
    public let service: String

    public init(service: String) {
        self.service = service
    }

    public func token(for account: String) throws -> String? {
        var query = baseQuery(account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw KeychainError(status: status) }
        guard let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    public func save(_ token: String, for account: String) throws {
        let data = Data(token.utf8)
        let update: [String: Any] = [kSecValueData as String: data]
        let status = SecItemUpdate(baseQuery(account) as CFDictionary, update as CFDictionary)
        if status == errSecSuccess { return }
        guard status == errSecItemNotFound else { throw KeychainError(status: status) }
        var add = baseQuery(account)
        add[kSecValueData as String] = data
        add[kSecAttrLabel as String] = "GitLab token (\(account))"
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        let addStatus = SecItemAdd(add as CFDictionary, nil)
        guard addStatus == errSecSuccess else { throw KeychainError(status: addStatus) }
    }

    public func delete(account: String) throws {
        let status = SecItemDelete(baseQuery(account) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw KeychainError(status: status) }
    }

    private func baseQuery(_ account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }
}

public enum TokenText {
    /// Finds a GitLab personal access token in command output.
    public static func extract(from output: String) -> String? {
        output.firstMatch(of: #/glpat-[A-Za-z0-9_\-]+/#).map { String($0.output) }
    }

    /// Replaces every token in `text`, for logs and captured process output.
    public static func redact(_ text: String) -> String {
        text.replacing(#/glpat-[A-Za-z0-9_\-]+/#, with: "glpat-[REDACTED]")
    }

    /// The only form the UI shows: glpat-••••a1b2.
    public static func masked(_ token: String) -> String {
        let suffix = token.count > 10 ? String(token.suffix(4)) : ""
        return "glpat-••••" + suffix
    }
}
