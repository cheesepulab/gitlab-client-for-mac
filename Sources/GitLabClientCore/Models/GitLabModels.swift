import Foundation

// Codable mirrors of the GitLab REST API v4 payloads the app uses.
// Keys are decoded with .convertFromSnakeCase; timestamps stay strings and are parsed on demand.

public struct GitLabUser: Codable, Sendable, Hashable {
    public var id: Int
    public var username: String
    public var name: String
    public var avatarUrl: String?
    public var webUrl: String?
    public var email: String?

    public init(id: Int, username: String, name: String, avatarUrl: String? = nil, webUrl: String? = nil, email: String? = nil) {
        self.id = id
        self.username = username
        self.name = name
        self.avatarUrl = avatarUrl
        self.webUrl = webUrl
        self.email = email
    }

    public var initials: String {
        let words = name.split(separator: " ").prefix(2)
        let letters = words.compactMap(\.first).map(String.init).joined()
        return (letters.isEmpty ? String(username.prefix(2)) : letters).uppercased()
    }
}

public struct TokenInfo: Codable, Sendable, Hashable {
    public var id: Int
    public var name: String
    public var scopes: [String]
    public var expiresAt: String?
    public var active: Bool?
    public var revoked: Bool?

    public init(id: Int, name: String, scopes: [String], expiresAt: String? = nil, active: Bool? = true, revoked: Bool? = false) {
        self.id = id
        self.name = name
        self.scopes = scopes
        self.expiresAt = expiresAt
        self.active = active
        self.revoked = revoked
    }

    public var expiryDate: Date? { expiresAt.flatMap(GitLabDate.day) }

    public func daysLeft(from now: Date = .now) -> Int? {
        guard let expiry = expiryDate else { return nil }
        let calendar = Calendar.current
        return calendar.dateComponents([.day], from: calendar.startOfDay(for: now), to: calendar.startOfDay(for: expiry)).day
    }

    /// `api` is needed for merge, rebase and rotation; `read_api` gives a read-only app.
    public var canWrite: Bool { scopes.contains("api") }
}

public struct RotatedToken: Codable, Sendable {
    public var token: String
    public var expiresAt: String?
}

public struct Namespace: Codable, Sendable, Hashable {
    public var id: Int
    public var name: String
    public var fullPath: String
    public var kind: String?
}

public struct Project: Codable, Sendable, Hashable, Identifiable {
    public var id: Int
    public var name: String
    public var nameWithNamespace: String
    public var pathWithNamespace: String
    public var description: String?
    public var defaultBranch: String?
    public var sshUrlToRepo: String
    public var httpUrlToRepo: String?
    public var webUrl: String?
    public var starCount: Int?
    public var lastActivityAt: String?
    public var namespace: Namespace?
    public var squashOption: String?
    public var removeSourceBranchAfterMerge: Bool?
    public var emptyRepo: Bool?
    public var archived: Bool?

    public init(id: Int, name: String, nameWithNamespace: String, pathWithNamespace: String, sshUrlToRepo: String,
                defaultBranch: String? = "main", namespace: Namespace? = nil) {
        self.id = id
        self.name = name
        self.nameWithNamespace = nameWithNamespace
        self.pathWithNamespace = pathWithNamespace
        self.sshUrlToRepo = sshUrlToRepo
        self.defaultBranch = defaultBranch
        self.namespace = namespace
    }

    /// "mobile" for "mobile/ios-app".
    public var groupPath: String {
        namespace?.fullPath ?? pathWithNamespace.split(separator: "/").dropLast().joined(separator: "/")
    }

    /// Project default for the squash checkbox in the merge sheet.
    public var squashByDefault: Bool { squashOption == "default_on" || squashOption == "always" }
}

public struct GitLabPerson: Codable, Sendable, Hashable {
    public var id: Int?
    public var name: String
    public var username: String
    public var avatarUrl: String?

    public init(id: Int? = nil, name: String, username: String, avatarUrl: String? = nil) {
        self.id = id
        self.name = name
        self.username = username
        self.avatarUrl = avatarUrl
    }

    public var initials: String {
        GitLabUser(id: id ?? 0, username: username, name: name).initials
    }
}

public struct PipelineRef: Codable, Sendable, Hashable {
    public var id: Int
    public var status: String
    public var webUrl: String?
    public var sha: String?
    public var ref: String?
    public var updatedAt: String?
}

public struct MergeRequest: Codable, Sendable, Hashable, Identifiable {
    public var id: Int
    public var iid: Int
    public var projectId: Int
    public var title: String
    public var description: String?
    public var state: String
    public var draft: Bool?
    public var author: GitLabPerson
    public var sourceBranch: String
    public var targetBranch: String
    public var sha: String?
    public var detailedMergeStatus: String?
    public var mergeStatus: String?
    public var hasConflicts: Bool?
    public var updatedAt: String
    public var createdAt: String?
    public var mergedAt: String?
    public var webUrl: String?
    public var headPipeline: PipelineRef?
    public var pipeline: PipelineRef?
    public var rebaseInProgress: Bool?
    public var mergeError: String?
    public var userNotesCount: Int?
    public var squash: Bool?
    public var forceRemoveSourceBranch: Bool?
    public var changesCount: String?
    public var assignees: [GitLabPerson]?
    public var reviewers: [GitLabPerson]?
    /// True while auto-merge is set. GitLab kept this name after renaming the feature.
    public var mergeWhenPipelineSucceeds: Bool?
    public var mergeUser: GitLabPerson?
    public var blockingDiscussionsResolved: Bool?
    public var references: References?

    public struct References: Codable, Sendable, Hashable {
        public var short: String?
        public var full: String?
    }

    public init(id: Int, iid: Int, projectId: Int, title: String, state: String = "opened", author: GitLabPerson,
                sourceBranch: String, targetBranch: String, sha: String? = nil, detailedMergeStatus: String? = nil,
                updatedAt: String = "2026-10-29T08:00:00Z") {
        self.id = id
        self.iid = iid
        self.projectId = projectId
        self.title = title
        self.state = state
        self.author = author
        self.sourceBranch = sourceBranch
        self.targetBranch = targetBranch
        self.sha = sha
        self.detailedMergeStatus = detailedMergeStatus
        self.updatedAt = updatedAt
    }

    public var pipelineStatus: String? { (headPipeline ?? pipeline)?.status }
    public var updatedDate: Date? { GitLabDate.parse(updatedAt) }
}

public struct ApprovedBy: Codable, Sendable, Hashable {
    public var user: GitLabPerson
}

public struct Approvals: Codable, Sendable, Hashable {
    public struct RuleLeft: Codable, Sendable, Hashable {
        public var name: String
    }

    public var approvalsRequired: Int?
    public var approvalsLeft: Int?
    public var approved: Bool?
    public var approvedBy: [ApprovedBy]?
    public var userHasApproved: Bool?
    public var userCanApprove: Bool?
    /// Premium and Ultimate only; Free servers leave out the counts and rules.
    public var approvalRulesLeft: [RuleLeft]?

    public init(approvalsRequired: Int? = nil, approvalsLeft: Int? = nil, approved: Bool? = nil, approvedBy: [ApprovedBy]? = nil,
                userHasApproved: Bool? = nil, userCanApprove: Bool? = nil) {
        self.approvalsRequired = approvalsRequired
        self.approvalsLeft = approvalsLeft
        self.approved = approved
        self.approvedBy = approvedBy
        self.userHasApproved = userHasApproved
        self.userCanApprove = userCanApprove
    }

    public var approvedCount: Int { approvedBy?.count ?? 0 }
    /// Free servers have no approval rules, so approval is optional there.
    public var hasRequirement: Bool { (approvalsRequired ?? 0) > 0 }
    /// "2/2" when GitLab reports a requirement, otherwise just the count.
    public var summary: String {
        if let required = approvalsRequired, required > 0 { return "\(approvedCount)/\(required)" }
        return "\(approvedCount)"
    }
}

public struct MergeRequestCommit: Codable, Sendable, Hashable, Identifiable {
    public var id: String
    public var shortId: String
    public var title: String
    public var authorName: String
    public var createdAt: String?
    public var message: String?
}

public struct APIDiff: Codable, Sendable, Hashable {
    public var oldPath: String
    public var newPath: String
    public var diff: String
    public var newFile: Bool?
    public var renamedFile: Bool?
    public var deletedFile: Bool?
}

public struct APIChanges: Codable, Sendable {
    public var changes: [APIDiff]
}

public struct APITreeItem: Codable, Sendable, Hashable {
    public var id: String
    public var name: String
    public var type: String
    public var path: String
    public var mode: String
}

public struct APIBranch: Codable, Sendable, Hashable {
    public struct BranchCommit: Codable, Sendable, Hashable {
        public var id: String
        public var committedDate: String?
    }
    public var name: String
    public var commit: BranchCommit
    public var `default`: Bool?
    public var protected: Bool?
}

public struct RebaseResponse: Codable, Sendable {
    public var rebaseInProgress: Bool?
}

/// A member of a project, direct or inherited from its groups.
public struct ProjectMember: Codable, Sendable, Hashable, Identifiable {
    public var id: Int
    public var username: String
    public var name: String
    public var avatarUrl: String?
    public var state: String?
    public var accessLevel: Int?

    public init(id: Int, username: String, name: String) {
        self.id = id
        self.username = username
        self.name = name
    }

    public var person: GitLabPerson { GitLabPerson(id: id, name: name, username: username, avatarUrl: avatarUrl) }
}

/// GET /version, e.g. "17.11.2-ee".
public struct ServerVersion: Codable, Sendable, Hashable {
    public var version: String
    public var revision: String?

    public init(version: String, revision: String? = nil) {
        self.version = version
        self.revision = revision
    }

    public var major: Int { numbers.first ?? 0 }
    public var minor: Int { numbers.dropFirst().first ?? 0 }

    public func atLeast(_ major: Int, _ minor: Int) -> Bool {
        self.major > major || (self.major == major && self.minor >= minor)
    }

    private var numbers: [Int] {
        version.prefix { $0.isNumber || $0 == "." }.split(separator: ".").compactMap { Int($0) }
    }
}

/// Whether this merge request can have more than one assignee or reviewer (paid tiers only).
public struct PeopleLimits: Sendable, Hashable {
    public var multipleAssignees: Bool
    public var multipleReviewers: Bool

    public init(multipleAssignees: Bool, multipleReviewers: Bool) {
        self.multipleAssignees = multipleAssignees
        self.multipleReviewers = multipleReviewers
    }

    public static let single = PeopleLimits(multipleAssignees: false, multipleReviewers: false)
}

public enum GitLabDate {
    public static func parse(_ text: String) -> Date? {
        if let date = try? Date(text, strategy: Date.ISO8601FormatStyle(includingFractionalSeconds: true)) { return date }
        if let date = try? Date(text, strategy: .iso8601) { return date }
        return day(text)
    }

    /// "2026-11-28" in the user's calendar.
    public static func day(_ text: String) -> Date? {
        let parts = text.prefix(10).split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else { return nil }
        return Calendar.current.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2]))
    }
}
