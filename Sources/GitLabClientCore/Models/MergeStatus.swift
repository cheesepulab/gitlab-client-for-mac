import Foundation

/// What the merge panel offers for an MR, derived from GitLab's `detailed_merge_status`.
public enum MergeAction: Equatable, Sendable {
    case merge
    case rebase
    case resolveWithAI
    case waitForPipeline(String)
    case needsApproval
    case blocked(String)
    case checking
    case closed(String)
}

public enum MergeStatusMapper {
    /// Spec mapping: only `mergeable` enables Merge; every other status explains why and,
    /// where possible, offers the action that fixes it.
    public static func action(for detailedStatus: String?, state: String = "opened") -> MergeAction {
        if state == "merged" { return .closed("This merge request is merged.") }
        if state == "closed" { return .closed("This merge request is closed.") }
        switch detailedStatus ?? "unchecked" {
        case "mergeable":
            return .merge
        case "need_rebase":
            return .rebase
        case "conflict", "broken_status":
            return .resolveWithAI
        case "ci_must_pass":
            return .waitForPipeline("The pipeline must pass before this can merge.")
        case "ci_still_running":
            return .waitForPipeline("The pipeline is still running.")
        case "not_approved":
            return .needsApproval
        case "draft_status":
            return .blocked("This is a draft. Mark it ready in GitLab first.")
        case "discussions_not_resolved":
            return .blocked("Some threads are unresolved.")
        case "blocked_status":
            return .blocked("Another merge request blocks this one.")
        case "checking", "unchecked", "preparing", "approvals_syncing":
            return .checking
        case "not_open":
            return .closed("This merge request is not open.")
        case "requested_changes":
            return .blocked("A reviewer requested changes.")
        case "jira_association_missing":
            return .blocked("The title or description must mention a Jira issue.")
        case "merge_time":
            return .blocked("It can't merge before its scheduled merge time.")
        case "security_policy_violations", "security_policy_pipeline_check":
            return .blocked("A security policy blocks the merge.")
        case "locked_paths", "locked_lfs_files":
            return .blocked("Locked files block the merge.")
        case "title_regex":
            return .blocked("The title doesn't match the project's required format.")
        case "commits_status":
            return .blocked("Some commits don't meet the project's rules.")
        default:
            return .blocked("GitLab reports \(detailedStatus ?? "an unknown status").")
        }
    }

    /// Short label for list rows.
    public static func label(for detailedStatus: String?, state: String) -> String {
        switch action(for: detailedStatus, state: state) {
        case .merge: return "Ready to merge"
        case .rebase: return "Needs rebase"
        case .resolveWithAI: return "Conflicts"
        case .waitForPipeline(let reason): return reason.contains("running") ? "Pipeline running" : "Pipeline must pass"
        case .needsApproval: return "Needs approval"
        case .checking: return "Checking"
        case .closed: return state == "merged" ? "Merged" : "Closed"
        case .blocked:
            switch detailedStatus {
            case "draft_status": return "Draft"
            case "discussions_not_resolved": return "Unresolved threads"
            default: return "Blocked"
            }
        }
    }
}
