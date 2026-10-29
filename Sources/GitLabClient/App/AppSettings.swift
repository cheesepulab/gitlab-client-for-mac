import AppKit
import GitLabClientCore

enum Appearance: String, CaseIterable, Identifiable {
    case system, light, dark

    var id: String { rawValue }

    var title: String {
        switch self {
        case .system: return "System"
        case .light: return "Light"
        case .dark: return "Dark"
        }
    }

    @MainActor
    func apply() {
        switch self {
        case .system: NSApp.appearance = nil
        case .light: NSApp.appearance = NSAppearance(named: .aqua)
        case .dark: NSApp.appearance = NSAppearance(named: .darkAqua)
        }
    }
}

/// "Use the project's setting", or a fixed choice for the merge sheet's checkboxes.
enum MergeOptionDefault: String, CaseIterable, Identifiable {
    case project, on, off

    var id: String { rawValue }
    var title: String {
        switch self {
        case .project: return "Project default"
        case .on: return "On"
        case .off: return "Off"
        }
    }

    func resolve(projectDefault: Bool) -> Bool {
        switch self {
        case .project: return projectDefault
        case .on: return true
        case .off: return false
        }
    }
}

/// Preferences, stored in UserDefaults. Tokens are never stored here.
@MainActor
@Observable
final class AppSettings {
    private let defaults = UserDefaults.standard

    var appearance: Appearance { didSet { defaults.set(appearance.rawValue, forKey: "appearance"); appearance.apply() } }
    var autoRefreshSeconds: Int { didSet { defaults.set(autoRefreshSeconds, forKey: "autoRefreshSeconds") } }
    var defaultMRState: String { didSet { defaults.set(defaultMRState, forKey: "defaultMRState") } }

    var gitPathOverride: String { didSet { defaults.set(gitPathOverride, forKey: "gitPathOverride") } }
    var cloneRootOverride: String { didSet { defaults.set(cloneRootOverride, forKey: "cloneRootOverride") } }
    var conflictStrategy: ConflictStrategy { didSet { defaults.set(conflictStrategy.rawValue, forKey: "conflictStrategy") } }
    var squashDefault: MergeOptionDefault { didSet { defaults.set(squashDefault.rawValue, forKey: "squashDefault") } }
    var deleteSourceDefault: MergeOptionDefault { didSet { defaults.set(deleteSourceDefault.rawValue, forKey: "deleteSourceDefault") } }

    var aiPresetID: String { didSet { defaults.set(aiPresetID, forKey: "aiPresetID") } }
    var aiBinaryPaths: [String: String] { didSet { defaults.set(aiBinaryPaths, forKey: "aiBinaryPaths") } }
    var aiTemplates: [String: String] { didSet { defaults.set(aiTemplates, forKey: "aiTemplates") } }
    var aiPrompts: [String: String] { didSet { defaults.set(aiPrompts, forKey: "aiPrompts") } }
    var aiTimeoutMinutes: Int { didSet { defaults.set(aiTimeoutMinutes, forKey: "aiTimeoutMinutes") } }

    init() {
        appearance = Appearance(rawValue: defaults.string(forKey: "appearance") ?? "") ?? .system
        autoRefreshSeconds = defaults.object(forKey: "autoRefreshSeconds") as? Int ?? 30
        defaultMRState = defaults.string(forKey: "defaultMRState") ?? "opened"
        gitPathOverride = defaults.string(forKey: "gitPathOverride") ?? ""
        cloneRootOverride = defaults.string(forKey: "cloneRootOverride") ?? ""
        conflictStrategy = ConflictStrategy(rawValue: defaults.string(forKey: "conflictStrategy") ?? "") ?? .rebase
        squashDefault = MergeOptionDefault(rawValue: defaults.string(forKey: "squashDefault") ?? "") ?? .project
        deleteSourceDefault = MergeOptionDefault(rawValue: defaults.string(forKey: "deleteSourceDefault") ?? "") ?? .project
        aiPresetID = defaults.string(forKey: "aiPresetID") ?? AIPreset.claude.id
        aiBinaryPaths = defaults.dictionary(forKey: "aiBinaryPaths") as? [String: String] ?? [:]
        aiTemplates = defaults.dictionary(forKey: "aiTemplates") as? [String: String] ?? [:]
        aiPrompts = defaults.dictionary(forKey: "aiPrompts") as? [String: String] ?? [:]
        aiTimeoutMinutes = defaults.object(forKey: "aiTimeoutMinutes") as? Int ?? 10
    }

    var aiPreset: AIPreset { AIPreset.with(id: aiPresetID) }

    func template(for preset: AIPreset) -> String { aiTemplates[preset.id] ?? preset.defaultTemplate }
    func prompt(for task: AITask) -> String { aiPrompts[task.rawValue] ?? task.defaultPrompt }

    var reposRoot: URL {
        cloneRootOverride.isEmpty ? GitService.defaultReposRoot() : URL(fileURLWithPath: cloneRootOverride, isDirectory: true)
    }
}
