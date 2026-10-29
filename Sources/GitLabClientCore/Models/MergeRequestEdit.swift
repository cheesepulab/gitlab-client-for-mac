import Foundation

/// GitLab has no draft flag in the REST API: a title starting with "Draft:", "[Draft]" or
/// "(Draft)" makes the merge request a draft.
public enum DraftTitle {
    public static func split(_ title: String) -> (draft: Bool, title: String) {
        var rest = Substring(title)
        var draft = false
        while let match = rest.prefixMatch(of: #/\s*(\[draft\]|\(draft\)|draft:)\s*/#.ignoresCase()) {
            draft = true
            rest = rest[match.range.upperBound...]
        }
        return (draft, draft ? String(rest) : title)
    }

    public static func compose(_ title: String, draft: Bool) -> String {
        let plain = split(title).title.trimmingCharacters(in: .whitespaces)
        return draft ? "Draft: \(plain)" : plain
    }
}

/// The fields the Edit page changes, compared with what GitLab has so only edits are sent.
public struct MergeRequestEdit: Equatable, Sendable {
    public enum Field: String, Sendable, CaseIterable {
        case title, draft, description, targetBranch, assignees, reviewers, removeSourceBranch, squash

        public var label: String {
            switch self {
            case .title: return "title"
            case .draft: return "draft status"
            case .description: return "description"
            case .targetBranch: return "target branch"
            case .assignees: return "assignees"
            case .reviewers: return "reviewers"
            case .removeSourceBranch: return "delete source branch"
            case .squash: return "squash commits"
            }
        }
    }

    public var title: String
    public var draft: Bool
    public var description: String
    public var targetBranch: String
    public var assigneeIDs: [Int]
    public var reviewerIDs: [Int]
    public var removeSourceBranch: Bool
    public var squash: Bool

    public init(title: String, draft: Bool, description: String, targetBranch: String, assigneeIDs: [Int], reviewerIDs: [Int],
                removeSourceBranch: Bool, squash: Bool) {
        self.title = title
        self.draft = draft
        self.description = description
        self.targetBranch = targetBranch
        self.assigneeIDs = assigneeIDs
        self.reviewerIDs = reviewerIDs
        self.removeSourceBranch = removeSourceBranch
        self.squash = squash
    }

    public init(_ mr: MergeRequest) {
        let split = DraftTitle.split(mr.title)
        self.init(title: split.title, draft: split.draft || mr.draft == true, description: mr.description ?? "",
                  targetBranch: mr.targetBranch, assigneeIDs: (mr.assignees ?? []).compactMap(\.id),
                  reviewerIDs: (mr.reviewers ?? []).compactMap(\.id), removeSourceBranch: mr.forceRemoveSourceBranch ?? false,
                  squash: mr.squash ?? false)
    }

    public var fullTitle: String { DraftTitle.compose(title, draft: draft) }

    public func changes(from original: MergeRequestEdit) -> [Field] {
        var fields: [Field] = []
        if title.trimmingCharacters(in: .whitespaces) != original.title.trimmingCharacters(in: .whitespaces) { fields.append(.title) }
        if draft != original.draft { fields.append(.draft) }
        if description != original.description { fields.append(.description) }
        if targetBranch != original.targetBranch { fields.append(.targetBranch) }
        if Set(assigneeIDs) != Set(original.assigneeIDs) { fields.append(.assignees) }
        if Set(reviewerIDs) != Set(original.reviewerIDs) { fields.append(.reviewers) }
        if removeSourceBranch != original.removeSourceBranch { fields.append(.removeSourceBranch) }
        if squash != original.squash { fields.append(.squash) }
        return fields
    }

    /// PUT /merge_requests/:iid body with only the changed fields. GitLab clears a list
    /// when it gets `[0]`.
    public func body(from original: MergeRequestEdit) -> [String: Any] {
        var body: [String: Any] = [:]
        for field in changes(from: original) {
            switch field {
            case .title, .draft: body["title"] = fullTitle
            case .description: body["description"] = description
            case .targetBranch: body["target_branch"] = targetBranch
            case .assignees: body["assignee_ids"] = assigneeIDs.isEmpty ? [0] : assigneeIDs
            case .reviewers: body["reviewer_ids"] = reviewerIDs.isEmpty ? [0] : reviewerIDs
            case .removeSourceBranch: body["remove_source_branch"] = removeSourceBranch
            case .squash: body["squash"] = squash
            }
        }
        return body
    }
}

/// How the project treats the squash checkbox (`squash_option`).
public enum SquashPolicy: Equatable, Sendable {
    case choose(defaultOn: Bool)
    case always
    case never

    public init(projectOption: String?) {
        switch projectOption {
        case "always": self = .always
        case "never": self = .never
        case "default_on": self = .choose(defaultOn: true)
        default: self = .choose(defaultOn: false)
        }
    }

    public var isLocked: Bool { self == .always || self == .never }

    /// The value a locked box must show; nil when the user chooses.
    public var forcedValue: Bool? {
        switch self {
        case .always: return true
        case .never: return false
        case .choose: return nil
        }
    }

    public var lockedReason: String? {
        switch self {
        case .always: return "This project always squashes commits."
        case .never: return "This project doesn't allow squashing."
        case .choose: return nil
        }
    }
}
