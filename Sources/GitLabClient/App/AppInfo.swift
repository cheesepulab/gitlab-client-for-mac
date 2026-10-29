import Foundation

/// Values the build script writes into the app's Info.plist (see scripts/config.sh).
enum AppInfo {
    static let name = "GitLab Client"

    private static func string(_ key: String) -> String? {
        let value = Bundle.main.object(forInfoDictionaryKey: key) as? String
        return (value?.isEmpty ?? true) ? nil : value
    }

    static var version: String { string("CFBundleShortVersionString") ?? "dev" }
    static var build: String { string("CFBundleVersion") ?? "0" }

    // Each value falls back to BuildDefaults (generated from the same config) when the app
    // runs without its packaged Info.plist, for example from Xcode or `swift run`.

    /// Keychain service for tokens; the account is the domain.
    static var keychainService: String { string("GLCKeychainService") ?? BuildDefaults.keychainService }
    static var repositoryURL: URL? { URL(string: string("GLCRepositoryURL") ?? BuildDefaults.repositoryURL) }
}
