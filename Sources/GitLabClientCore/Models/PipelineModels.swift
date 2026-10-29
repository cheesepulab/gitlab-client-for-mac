import Foundation

public struct Pipeline: Codable, Sendable, Hashable, Identifiable {
    public var id: Int
    public var iid: Int?
    public var status: String
    public var source: String?
    public var ref: String?
    public var sha: String?
    public var createdAt: String?
    public var updatedAt: String?
    public var startedAt: String?
    public var finishedAt: String?
    /// Seconds; only on GET /pipelines/:id.
    public var duration: Double?
    public var user: GitLabPerson?
    public var webUrl: String?

    public init(id: Int, status: String, sha: String? = nil, ref: String? = nil, createdAt: String? = nil) {
        self.id = id
        self.status = status
        self.sha = sha
        self.ref = ref
        self.createdAt = createdAt
    }

    public var ciStatus: CIStatus { CIStatus(status) }
    public var createdDate: Date? { createdAt.flatMap(GitLabDate.parse) }
    public var startedDate: Date? { startedAt.flatMap(GitLabDate.parse) }
}

public struct Job: Codable, Sendable, Hashable, Identifiable {
    public var id: Int
    public var name: String
    public var stage: String
    public var status: String
    public var duration: Double?
    public var createdAt: String?
    public var startedAt: String?
    public var finishedAt: String?
    public var allowFailure: Bool?
    public var failureReason: String?
    public var user: GitLabPerson?
    public var webUrl: String?

    public init(id: Int, name: String, stage: String, status: String, duration: Double? = nil) {
        self.id = id
        self.name = name
        self.stage = stage
        self.status = status
        self.duration = duration
    }

    public var ciStatus: CIStatus { CIStatus(status) }
    public var action: JobAction? { JobAction.available(for: ciStatus) }
    public var startedDate: Date? { startedAt.flatMap(GitLabDate.parse) }
}

/// GitLab's pipeline and job statuses.
public enum CIStatus: Equatable, Sendable {
    case success, failed, running, pending, created, preparing, waitingForResource, scheduled
    case canceling, canceled, skipped, manual
    case other(String)

    public init(_ raw: String) {
        switch raw {
        case "success": self = .success
        case "failed": self = .failed
        case "running": self = .running
        case "pending": self = .pending
        case "created": self = .created
        case "preparing": self = .preparing
        case "waiting_for_resource": self = .waitingForResource
        case "scheduled": self = .scheduled
        case "canceling": self = .canceling
        case "canceled": self = .canceled
        case "skipped": self = .skipped
        case "manual": self = .manual
        default: self = .other(raw)
        }
    }

    /// Still going: worth polling, and Cancel applies.
    public var isActive: Bool {
        switch self {
        case .running, .pending, .created, .preparing, .waitingForResource, .canceling: return true
        default: return false
        }
    }

    /// Pipeline-level Retry reruns only the failed and canceled jobs.
    public var canRetryPipeline: Bool { self == .failed || self == .canceled }
    public var canCancelPipeline: Bool { isActive && self != .canceling }

    public var label: String {
        switch self {
        case .success: return "Passed"
        case .failed: return "Failed"
        case .running: return "Running"
        case .pending: return "Pending"
        case .created: return "Created"
        case .preparing: return "Preparing"
        case .waitingForResource: return "Waiting"
        case .scheduled: return "Scheduled"
        case .canceling: return "Canceling"
        case .canceled: return "Canceled"
        case .skipped: return "Skipped"
        case .manual: return "Manual"
        case .other(let raw): return raw.replacingOccurrences(of: "_", with: " ").capitalized
        }
    }
}

public enum JobAction: String, Sendable {
    case cancel, retry, play

    public static func available(for status: CIStatus) -> JobAction? {
        switch status {
        case .running, .pending, .created, .preparing, .waitingForResource: return .cancel
        case .manual: return .play
        case .failed, .canceled, .success: return .retry
        default: return nil
        }
    }

    public var title: String {
        switch self {
        case .cancel: return "Cancel"
        case .retry: return "Retry"
        case .play: return "Run"
        }
    }
}

/// A pipeline's jobs grouped by stage, in the order the stages run.
public struct PipelineStage: Sendable, Hashable, Identifiable {
    public var name: String
    public var jobs: [Job]
    public var id: String { name }

    /// Expects jobs fetched with `include_retried=true`: stage order comes from the first job
    /// created in each stage, and only the newest attempt of each job is kept.
    public static func group(_ jobs: [Job]) -> [PipelineStage] {
        let sorted = jobs.sorted { $0.id < $1.id }
        var order: [String] = []
        var latest: [String: Job] = [:]
        var nameOrder: [String: [String]] = [:]
        for job in sorted {
            if !order.contains(job.stage) { order.append(job.stage) }
            let key = job.stage + "\u{1F}" + job.name
            if latest[key] == nil { nameOrder[job.stage, default: []].append(job.name) }
            latest[key] = job
        }
        return order.map { stage in
            PipelineStage(name: stage, jobs: (nameOrder[stage] ?? []).compactMap { latest[stage + "\u{1F}" + $0] })
        }
    }
}

/// Job log text without ANSI escapes and GitLab's collapsible-section markers.
public enum JobLog {
    public enum Tone: Sendable, Equatable { case normal, command, error, success, dim }

    public struct Line: Sendable, Equatable {
        public var text: String
        public var tone: Tone

        public init(text: String, tone: Tone) {
            self.text = text
            self.tone = tone
        }
    }

    public static func lines(_ raw: String, limit: Int = 4000) -> [Line] {
        let text = raw.replacingOccurrences(of: "\r\n", with: "\n")
        var lines: [Line] = []
        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: false) {
            var line = String(rawLine)
            // section_start:1730000000:step_script\r\e[0K… : the marker is followed by the real text.
            let marked = line.contains("section_start:") || line.contains("section_end:")
            line = line.replacing(#/section_(start|end):\d+:[A-Za-z0-9_.\-]+(\[[^\]]*\])?\r?/#, with: "")
            let color = firstColor(in: line)
            line = line.replacing(#/\u{1B}\[[0-9;?]*[A-Za-z]/#, with: "")
            // A carriage return redraws the line (progress output); keep what was drawn last.
            if let lastReturn = line.lastIndex(of: "\r") {
                let tail = line[line.index(after: lastReturn)...]
                line = tail.isEmpty ? String(line[..<lastReturn]) : String(tail)
                line = line.replacingOccurrences(of: "\r", with: "")
            }
            if marked && line.isEmpty { continue }
            lines.append(Line(text: line, tone: tone(for: line, color: color)))
        }
        while lines.last?.text.isEmpty == true { lines.removeLast() }
        return lines.count > limit ? Array(lines.suffix(limit)) : lines
    }

    private static func firstColor(in line: String) -> Int? {
        guard let match = line.firstMatch(of: #/\u{1B}\[([0-9;]*)m/#) else { return nil }
        return match.1.split(separator: ";").compactMap { Int($0) }.first { (30...37).contains($0) || (90...97).contains($0) }
    }

    private static func tone(for text: String, color: Int?) -> Tone {
        switch color {
        case 31, 91: return .error
        case 32, 92: return text.hasPrefix("$ ") ? .command : .success
        case 90: return .dim
        default: return text.hasPrefix("$ ") ? .command : .normal
        }
    }
}
