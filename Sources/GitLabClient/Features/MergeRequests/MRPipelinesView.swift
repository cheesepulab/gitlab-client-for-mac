import SwiftUI
import GitLabClientCore

@MainActor
@Observable
final class PipelinesModel {
    private(set) var pipelines: [Pipeline]?
    /// Full pipeline records (user, duration), fetched for the newest rows.
    private(set) var details: [Int: Pipeline] = [:]
    var selectedID: Int?
    private(set) var stages: [PipelineStage] = []
    private(set) var jobsPipelineID: Int?
    var selectedJobID: Int?
    private(set) var log: [JobLog.Line] = []
    private(set) var logJobID: Int?
    private(set) var error: String?
    private(set) var working: String?
    var actionError: String?

    var selected: Pipeline? {
        guard let selectedID else { return nil }
        return details[selectedID] ?? pipelines?.first { $0.id == selectedID }
    }

    var jobs: [Job] { stages.flatMap(\.jobs) }
    var selectedJob: Job? { jobs.first { $0.id == selectedJobID } }
    var anyActive: Bool { (pipelines ?? []).contains { $0.ciStatus.isActive } }

    func load(api: GitLabAPIClient, projectID: Int, iid: Int) async {
        do {
            let list = try await api.pipelines(projectID: projectID, iid: iid)
            pipelines = list
            error = nil
            if selectedID == nil || !list.contains(where: { $0.id == selectedID }) { selectedID = list.first?.id }
            let stale = list.prefix(10).filter { details[$0.id] == nil || details[$0.id]?.status != $0.status }
            await withTaskGroup(of: Pipeline?.self) { group in
                for pipeline in stale {
                    group.addTask { try? await api.pipeline(projectID: projectID, pipelineID: pipeline.id) }
                }
                for await full in group {
                    if let full { details[full.id] = full }
                }
            }
        } catch is CancellationError {
        } catch {
            self.error = error.localizedDescription
        }
    }

    func loadJobs(api: GitLabAPIClient, projectID: Int) async {
        guard let pipelineID = selectedID else { stages = []; return }
        do {
            let jobs = try await api.jobs(projectID: projectID, pipelineID: pipelineID)
            guard pipelineID == selectedID else { return }
            stages = PipelineStage.group(jobs)
            if jobsPipelineID != pipelineID || selectedJob == nil {
                // Show the job most worth reading: running, else failed, else the first.
                let latest = stages.flatMap(\.jobs)
                selectedJobID = (latest.first { $0.ciStatus == .running } ?? latest.first { $0.ciStatus == .failed } ?? latest.first)?.id
            }
            jobsPipelineID = pipelineID
        } catch is CancellationError {
        } catch {
            actionError = error.localizedDescription
        }
    }

    func loadLog(api: GitLabAPIClient, projectID: Int) async {
        guard let job = selectedJob else { log = []; logJobID = nil; return }
        switch job.ciStatus {
        case .manual, .created, .pending, .skipped, .scheduled, .waitingForResource:
            log = []
            logJobID = job.id
            return
        default: break
        }
        do {
            let text = try await api.jobLog(projectID: projectID, jobID: job.id)
            guard job.id == selectedJobID else { return }
            log = JobLog.lines(text)
            logJobID = job.id
        } catch is CancellationError {
        } catch {
            if job.id == selectedJobID { log = [JobLog.Line(text: error.localizedDescription, tone: .error)]; logJobID = job.id }
        }
    }

    private func perform(_ key: String, _ body: () async throws -> Void) async {
        guard working == nil else { return }
        working = key
        actionError = nil
        defer { working = nil }
        do {
            try await body()
        } catch is CancellationError {
        } catch {
            actionError = error.localizedDescription
        }
    }

    func cancel(_ pipeline: Pipeline, api: GitLabAPIClient, projectID: Int, iid: Int) async {
        await perform("pipeline-\(pipeline.id)") {
            details[pipeline.id] = try await api.cancelPipeline(projectID: projectID, pipelineID: pipeline.id)
            await reload(api: api, projectID: projectID, iid: iid)
        }
    }

    func retry(_ pipeline: Pipeline, api: GitLabAPIClient, projectID: Int, iid: Int) async {
        await perform("pipeline-\(pipeline.id)") {
            details[pipeline.id] = try await api.retryPipeline(projectID: projectID, pipelineID: pipeline.id)
            selectedID = pipeline.id
            await reload(api: api, projectID: projectID, iid: iid)
        }
    }

    func run(api: GitLabAPIClient, projectID: Int, iid: Int) async {
        await perform("run") {
            let created = try await api.runPipeline(projectID: projectID, iid: iid)
            details[created.id] = created
            selectedID = created.id
            await reload(api: api, projectID: projectID, iid: iid)
        }
    }

    func perform(_ action: JobAction, on job: Job, api: GitLabAPIClient, projectID: Int, iid: Int) async {
        await perform("job-\(job.id)") {
            let updated = try await api.perform(action, projectID: projectID, jobID: job.id)
            // A retry makes a new job; follow it.
            selectedJobID = updated.id
            await reload(api: api, projectID: projectID, iid: iid)
            await loadLog(api: api, projectID: projectID)
        }
    }

    func reload(api: GitLabAPIClient, projectID: Int, iid: Int) async {
        await load(api: api, projectID: projectID, iid: iid)
        await loadJobs(api: api, projectID: projectID)
    }
}

struct MRPipelinesView: View {
    let repo: RepoModel
    let detail: MRDetailModel
    @Bindable var model: PipelinesModel
    @Environment(AppModel.self) private var app
    @Environment(\.controlActiveState) private var activeState

    private var canWrite: Bool { (app.accounts[repo.domain.key]?.canWrite ?? true) }
    private var projectID: Int { repo.project.id }
    private var iid: Int { detail.mr.iid }

    var body: some View {
        HSplitView {
            pipelineList
                .frame(minWidth: 250, idealWidth: 280, maxWidth: 380)
            detailPane
                .frame(minWidth: 480, maxWidth: .infinity, maxHeight: .infinity)
        }
        .task {
            await model.load(api: repo.api, projectID: projectID, iid: iid)
            #if DEBUG
            if let script = DebugSnapshot.value("GLC_DEBUG_PIPELINE_ACTIONS") { await runDebugActions(script) }
            #endif
        }
        .task(id: model.selectedID) { await model.loadJobs(api: repo.api, projectID: projectID) }
        .task(id: model.selectedJobID) { await model.loadLog(api: repo.api, projectID: projectID) }
        .task(id: activeState == .key) {
            // While something runs and the window is focused, follow it every 4 s.
            guard activeState == .key else { return }
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(4))
                guard !Task.isCancelled, model.working == nil else { continue }
                if model.anyActive || model.selected?.ciStatus.isActive == true {
                    await model.reload(api: repo.api, projectID: projectID, iid: iid)
                }
                if model.selectedJob?.ciStatus.isActive == true {
                    await model.loadLog(api: repo.api, projectID: projectID)
                }
            }
        }
    }

    #if DEBUG
    /// GLC_DEBUG_PIPELINE_ACTIONS="select:8790;retry;job:ui-tests;jobaction;cancel;run".
    private func runDebugActions(_ script: String) async {
        for step in script.split(separator: ";") {
            let parts = step.split(separator: ":", maxSplits: 1).map(String.init)
            switch parts[0] {
            case "select":
                model.selectedID = Int(parts.last ?? "")
                await model.loadJobs(api: repo.api, projectID: projectID)
            case "job":
                model.selectedJobID = model.jobs.first { $0.name == parts.last }?.id
                await model.loadLog(api: repo.api, projectID: projectID)
            case "retry": if let pipeline = model.selected { await model.retry(pipeline, api: repo.api, projectID: projectID, iid: iid) }
            case "cancel": if let pipeline = model.selected { await model.cancel(pipeline, api: repo.api, projectID: projectID, iid: iid) }
            case "run": await model.run(api: repo.api, projectID: projectID, iid: iid)
            case "jobaction":
                if let job = model.selectedJob, let action = job.action { await model.perform(action, on: job, api: repo.api, projectID: projectID, iid: iid) }
            default: break
            }
        }
    }
    #endif

    // MARK: List

    private var pipelineList: some View {
        VStack(spacing: 0) {
            HStack {
                Text(model.pipelines.map { "\($0.count) pipeline\($0.count == 1 ? "" : "s")" } ?? "Pipelines").font(.headline)
                Spacer()
                if canWrite {
                    Button {
                        Task { await model.run(api: repo.api, projectID: projectID, iid: iid) }
                    } label: {
                        if model.working == "run" { ProgressView().controlSize(.small) } else { Label("Run pipeline", systemImage: "play") }
                    }
                    .controlSize(.small)
                    .disabled(model.working != nil)
                    .help("Start a new pipeline for this merge request")
                }
            }
            .padding(.horizontal, 14).padding(.vertical, 10)
            Divider()
            List(selection: $model.selectedID) {
                ForEach(model.pipelines ?? []) { pipeline in
                    PipelineRow(pipeline: model.details[pipeline.id] ?? pipeline, title: commitTitle(pipeline.sha),
                                canWrite: canWrite, busy: model.working == "pipeline-\(pipeline.id)",
                                onCancel: { Task { await model.cancel(pipeline, api: repo.api, projectID: projectID, iid: iid) } },
                                onRetry: { Task { await model.retry(pipeline, api: repo.api, projectID: projectID, iid: iid) } })
                        .tag(pipeline.id as Int?)
                }
            }
            .listStyle(.inset)
            .overlay {
                if model.pipelines == nil {
                    if let error = model.error { ErrorText(message: error).padding() } else { ProgressView() }
                }
            }
            Divider()
            Text("Retry runs the failed and canceled jobs again. Cancel stops running and pending jobs.")
                .font(.caption).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 14).padding(.vertical, 8)
        }
    }

    private func commitTitle(_ sha: String?) -> String {
        guard let sha else { return "" }
        return detail.commits?.first { $0.id == sha || sha.hasPrefix($0.shortId) }?.title ?? ""
    }

    // MARK: Detail

    @ViewBuilder private var detailPane: some View {
        if let pipeline = model.selected {
            VStack(alignment: .leading, spacing: 14) {
                header(pipeline)
                if let error = model.actionError { ErrorText(message: error) }
                // Stages share the width; only when they can't fit do they scroll sideways.
                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .top, spacing: 10) {
                        ForEach(model.stages) { stage in stageColumn(stage).frame(minWidth: 112, maxWidth: .infinity, alignment: .topLeading) }
                    }
                    ScrollView(.horizontal) {
                        HStack(alignment: .top, spacing: 10) {
                            ForEach(model.stages) { stage in stageColumn(stage).frame(width: 160, alignment: .topLeading) }
                        }
                        .padding(.bottom, 4)
                    }
                }
                .overlay { if model.stages.isEmpty && model.jobsPipelineID != pipeline.id { ProgressView() } }
                .frame(minHeight: 60)
                logPanel
            }
            .padding(20)
        } else if model.pipelines == nil {
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ContentUnavailableView("No pipelines", systemImage: "circle.dotted", description: Text("This merge request has no pipelines yet."))
        }
    }

    private func header(_ pipeline: Pipeline) -> some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 8) {
                    Text("Pipeline #\(String(pipeline.id))").font(.title3.bold())
                    Pill(text: pipeline.ciStatus.label, tone: tone(pipeline.ciStatus))
                }
                Group {
                    Text(pipeline.source == "merge_request_event" ? "Merge request pipeline for " : "Pipeline for ")
                        + Text(String((pipeline.sha ?? "").prefix(8))).font(.caption.monospaced()).foregroundColor(.accentColor)
                        + Text(" \(commitTitle(pipeline.sha))")
                        + Text(startedText(pipeline))
                }
                .font(.caption).foregroundStyle(.secondary).lineLimit(2)
                Text(countsText).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if canWrite {
                if pipeline.ciStatus.canCancelPipeline {
                    Button(role: .destructive) {
                        Task { await model.cancel(pipeline, api: repo.api, projectID: projectID, iid: iid) }
                    } label: { Label("Cancel pipeline", systemImage: "stop.circle") }
                    .disabled(model.working != nil)
                }
                if pipeline.ciStatus.canRetryPipeline {
                    Button {
                        Task { await model.retry(pipeline, api: repo.api, projectID: projectID, iid: iid) }
                    } label: { Label("Retry failed jobs", systemImage: "arrow.clockwise") }
                    .buttonStyle(.borderedProminent)
                    .disabled(model.working != nil)
                }
            }
        }
    }

    private func startedText(_ pipeline: Pipeline) -> String {
        var parts: [String] = []
        if let date = pipeline.startedDate ?? pipeline.createdDate { parts.append("started \(relative(date))") }
        if let user = pipeline.user { parts.append("by \(user.name)") }
        if let duration = pipeline.duration, !pipeline.ciStatus.isActive { parts.append("took \(durationText(duration))") }
        return parts.isEmpty ? "" : " · " + parts.joined(separator: " ")
    }

    private var countsText: String {
        let jobs = model.jobs
        guard !jobs.isEmpty else { return "" }
        var counts: [String: Int] = [:]
        for job in jobs { counts[job.ciStatus.label.lowercased(), default: 0] += 1 }
        let order = ["passed", "running", "pending", "created", "failed", "canceled", "manual", "skipped"]
        let parts = order.compactMap { key in counts[key].map { "\($0) \(key)" } }
        return "\(jobs.count) job\(jobs.count == 1 ? "" : "s") · " + parts.joined(separator: " · ")
    }

    private func stageColumn(_ stage: PipelineStage) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(stage.name.uppercased()).font(.caption2.weight(.semibold)).foregroundStyle(.secondary).padding(.leading, 2)
            ForEach(stage.jobs) { job in jobChip(job) }
        }
    }

    private func jobChip(_ job: Job) -> some View {
        let isSelected = job.id == model.selectedJobID
        return HStack(spacing: 4) {
            Button { model.selectedJobID = job.id } label: {
                HStack(spacing: 7) {
                    PipelineIcon(status: job.status).font(.system(size: 13))
                    VStack(alignment: .leading, spacing: 1) {
                        Text(job.name).font(.caption.weight(.semibold)).lineLimit(1)
                        Text(jobSubtitle(job)).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                    }
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityAddTraits(isSelected ? .isSelected : [])
            if canWrite, let action = job.action {
                Button {
                    Task { await model.perform(action, on: job, api: repo.api, projectID: projectID, iid: iid) }
                } label: {
                    if model.working == "job-\(job.id)" { ProgressView().controlSize(.mini) } else { Image(systemName: icon(for: action)) }
                }
                .buttonStyle(.borderless)
                .foregroundStyle(action == .cancel ? Color.red : action == .play ? Color.accentColor : Color.primary)
                .help("\(action.title) \(job.name)")
                .accessibilityLabel("\(action.title) \(job.name)")
                .disabled(model.working != nil)
            }
        }
        .padding(.horizontal, 8).padding(.vertical, 6)
        .background(isSelected ? Color.accentColor.opacity(0.12) : Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(isSelected ? Color.accentColor.opacity(0.4) : Color(nsColor: .separatorColor)))
    }

    private func jobSubtitle(_ job: Job) -> String {
        if let duration = job.duration, duration > 0 { return "\(job.ciStatus.label) · \(durationText(duration))" }
        if job.ciStatus == .running, let started = job.startedDate { return "Running · \(durationText(Date.now.timeIntervalSince(started)))" }
        return job.allowFailure == true && job.ciStatus == .failed ? "Failed · allowed" : job.ciStatus.label
    }

    private func icon(for action: JobAction) -> String {
        switch action {
        case .cancel: return "stop.circle"
        case .retry: return "arrow.clockwise"
        case .play: return "play.circle"
        }
    }

    private func tone(_ status: CIStatus) -> Tone {
        switch status {
        case .success: return .green
        case .failed: return .red
        case .running, .pending, .created, .preparing, .waitingForResource: return .blue
        default: return .gray
        }
    }

    // MARK: Log

    private var logPanel: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                if let job = model.selectedJob {
                    (Text(job.name).fontWeight(.semibold) + Text("  \(jobSubtitle(job))").foregroundColor(.gray))
                        .font(.caption)
                    Spacer()
                    if job.ciStatus.isActive { Text("Live · updates every 4 s").font(.caption2).foregroundStyle(.gray) }
                    if canWrite, let action = job.action {
                        Button(action.title) {
                            Task { await model.perform(action, on: job, api: repo.api, projectID: projectID, iid: iid) }
                        }
                        .controlSize(.small)
                        .disabled(model.working != nil)
                    }
                    Button { Clipboard.copy(model.log.map(\.text).joined(separator: "\n")) } label: { Image(systemName: "doc.on.doc") }
                        .buttonStyle(.borderless).foregroundStyle(.gray)
                        .help("Copy log").accessibilityLabel("Copy log")
                        .disabled(model.log.isEmpty)
                } else {
                    Text("Pick a job to see its log").font(.caption).foregroundStyle(.gray)
                    Spacer()
                }
            }
            .padding(.horizontal, 12).padding(.vertical, 7)
            Divider().overlay(Color.white.opacity(0.08))
            ScrollViewReader { proxy in
                ScrollView([.vertical, .horizontal]) {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        if model.log.isEmpty {
                            Text(placeholder).foregroundStyle(.gray)
                        }
                        ForEach(Array(model.log.enumerated()), id: \.offset) { index, line in
                            HStack(alignment: .top, spacing: 14) {
                                Text("\(index + 1)").foregroundStyle(Color(white: 0.4)).frame(minWidth: 30, alignment: .trailing)
                                Text(line.text.isEmpty ? " " : line.text).foregroundStyle(color(line.tone)).fixedSize()
                            }
                            .id(index)
                        }
                    }
                    .font(.system(size: 11.5, design: .monospaced))
                    .padding(12)
                    .textSelection(.enabled)
                }
                .onChange(of: model.log.count) { _, count in
                    if model.selectedJob?.ciStatus.isActive == true, count > 0 { proxy.scrollTo(count - 1, anchor: .bottom) }
                }
            }
        }
        .foregroundStyle(Color(white: 0.9))
        .background(Color(red: 0.11, green: 0.11, blue: 0.12), in: RoundedRectangle(cornerRadius: 10))
        .environment(\.colorScheme, .dark)
        .frame(maxHeight: .infinity)
    }

    private var placeholder: String {
        guard let job = model.selectedJob else { return "" }
        if model.logJobID != job.id { return "Loading the log…" }
        switch job.ciStatus {
        case .manual: return "Manual job. Press Run to start it."
        case .created, .pending, .waitingForResource: return "Waiting for earlier jobs to finish."
        case .scheduled: return "Scheduled to start later."
        case .skipped: return "Skipped: a job in an earlier stage didn't pass."
        default: return "This job has no log."
        }
    }

    private func color(_ tone: JobLog.Tone) -> Color {
        switch tone {
        case .normal: return Color(white: 0.9)
        case .command: return Color(red: 0.49, green: 0.91, blue: 0.53)
        case .success: return Color(red: 0.49, green: 0.91, blue: 0.53)
        case .error: return Color(red: 1, green: 0.54, blue: 0.5)
        case .dim: return Color(white: 0.55)
        }
    }
}

struct PipelineRow: View {
    let pipeline: Pipeline
    let title: String
    let canWrite: Bool
    let busy: Bool
    let onCancel: () -> Void
    let onRetry: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            PipelineIcon(status: pipeline.status).padding(.top, 1)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 8) {
                    Text("#\(String(pipeline.id))").fontWeight(.semibold)
                    Text(pipeline.ciStatus.label).font(.caption.weight(.semibold)).foregroundStyle(color)
                }
                (Text(String((pipeline.sha ?? "").prefix(8))).font(.caption.monospaced()).foregroundColor(.accentColor) + Text(" \(title)"))
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                Text([pipeline.user?.name, relative(pipeline.createdDate)].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · "))
                    .font(.caption2).foregroundStyle(.tertiary)
            }
            Spacer(minLength: 4)
            if canWrite {
                if busy {
                    ProgressView().controlSize(.small)
                } else if pipeline.ciStatus.canCancelPipeline {
                    Button(action: onCancel) { Image(systemName: "stop.circle") }
                        .buttonStyle(.borderless).foregroundStyle(.red)
                        .help("Cancel pipeline").accessibilityLabel("Cancel pipeline #\(String(pipeline.id))")
                } else if pipeline.ciStatus.canRetryPipeline {
                    Button(action: onRetry) { Image(systemName: "arrow.clockwise") }
                        .buttonStyle(.borderless)
                        .help("Retry failed and canceled jobs").accessibilityLabel("Retry pipeline #\(String(pipeline.id))")
                }
            }
        }
        .padding(.vertical, 4)
    }

    private var color: Color {
        switch pipeline.ciStatus {
        case .success: return .green
        case .failed: return .red
        case .running, .pending, .created: return .accentColor
        default: return .secondary
        }
    }
}
