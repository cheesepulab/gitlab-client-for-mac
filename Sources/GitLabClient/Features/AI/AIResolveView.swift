import SwiftUI
import GitLabClientCore

@MainActor
@Observable
final class AIResolveModel {
    enum Phase: Equatable {
        case starting
        case running
        case review
        case pushing
        case pushed
        case failed(String)
        case cancelled
    }

    private(set) var phase: Phase = .starting
    private(set) var stage: ResolveStage = .fetching
    private(set) var log: [String] = []
    private(set) var conflictFiles: [String] = []
    private(set) var resolvedFiles: Set<String> = []
    private(set) var outcome: ResolveOutcome?
    private(set) var startedAt = Date()
    private(set) var request: ResolveRequest?
    private var resolver: ConflictResolver?
    private var task: Task<Void, Never>?

    var timeLimit: Duration { request?.ai.timeout ?? .seconds(600) }

    func start(repo: RepoModel, mr: MergeRequest, model: AppModel) {
        guard task == nil else { return }
        let settings = model.settings
        task = Task {
            guard let git = await model.git() else {
                phase = .failed(model.gitProblem ?? GitError.gitNotFound.localizedDescription)
                return
            }
            guard let ai = await Self.aiSettings(settings: settings) else {
                phase = .failed("\(settings.aiPreset.name) isn't installed. Pick another CLI or choose its binary in Settings → AI CLI.")
                return
            }
            let account = model.accounts[repo.domain.key]
            let request = ResolveRequest(domain: repo.domain, project: repo.project, iid: mr.iid, sourceBranch: mr.sourceBranch,
                                         targetBranch: mr.targetBranch, strategy: settings.conflictStrategy, ai: ai,
                                         committerName: account?.user?.name, committerEmail: account?.user?.email)
            self.request = request
            let resolver = ConflictResolver(git: git)
            self.resolver = resolver
            phase = .running
            startedAt = .now
            do {
                let outcome = try await resolver.resolve(request) { event in
                    Task { @MainActor in self.handle(event) }
                }
                self.outcome = outcome
                phase = .review
            } catch is CancellationError {
                phase = .cancelled
                await resolver.discard()
            } catch {
                append("error: \(error.localizedDescription)")
                phase = Task.isCancelled ? .cancelled : .failed(error.localizedDescription)
            }
        }
    }

    /// Resolves the preset's binary (or the user's choice), template and prompt from Settings.
    static func aiSettings(settings: AppSettings) async -> AIRunSettings? {
        let preset = settings.aiPreset
        let template = settings.template(for: preset)
        var executable = settings.aiBinaryPaths[preset.id]
        if executable == nil || executable?.isEmpty == true {
            if let name = preset.binaryName {
                executable = await ShellEnvironment.shared.which(name)
            } else if let first = try? CommandTemplate.tokenize(template).first {
                executable = first.hasPrefix("/") ? first : await ShellEnvironment.shared.which(first)
            }
        }
        guard let executable, FileManager.default.isExecutableFile(atPath: executable) else { return nil }
        return AIRunSettings(executable: executable, template: template, prompt: settings.prompt(for: settings.conflictStrategy.task),
                             timeout: .seconds(max(1, settings.aiTimeoutMinutes) * 60), cliName: preset.name)
    }

    private func handle(_ event: ResolveEvent) {
        switch event {
        case .stage(let stage):
            self.stage = stage
            if case .runningAI(_, let files) = stage {
                for file in files where !conflictFiles.contains(file) { conflictFiles.append(file) }
            }
        case .output(let line):
            append(line.text)
        case .fileResolved(let file):
            resolvedFiles.insert(file)
        }
    }

    private func append(_ text: String) {
        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            log.append(String(line))
        }
        if log.count > 4000 { log.removeFirst(log.count - 4000) }
    }

    func push() async {
        guard let resolver, let request, let outcome else { return }
        phase = .pushing
        do {
            try await resolver.push(request, outcome: outcome) { [weak self] event in
                Task { @MainActor in self?.handle(event) }
            }
            phase = .pushed
        } catch {
            append("error: \(error.localizedDescription)")
            phase = .failed(error.localizedDescription)
        }
    }

    /// Stops the CLI if it's running and deletes the worktree.
    func discard() async {
        task?.cancel()
        await task?.value
        await resolver?.discard()
        if phase != .pushed { phase = .cancelled }
    }
}

/// Sheet for "Resolve with AI": live output while the CLI runs, then the review before push.
struct AIResolveView: View {
    let repo: RepoModel
    let mr: MergeRequest
    @Environment(AppModel.self) private var model
    @Environment(AppSettings.self) private var settings
    @Environment(\.dismiss) private var dismiss
    @State private var run = AIResolveModel()
    @State private var compareWithTarget = false

    var body: some View {
        VStack(spacing: 0) {
            titleBar
            Divider()
            ProgressSteps(stage: run.stage, phase: run.phase, strategy: settings.conflictStrategy, cliName: settings.aiPreset.name)
            Divider()
            Group {
                switch run.phase {
                case .review, .pushing, .pushed:
                    if let outcome = run.outcome { ReviewPane(outcome: outcome, log: run.log, compareWithTarget: $compareWithTarget) }
                default:
                    RunningPane(run: run, mr: mr, cliName: settings.aiPreset.name)
                }
            }
            .frame(maxHeight: .infinity)
            Divider()
            footer
        }
        .frame(minWidth: 1080, idealWidth: 1180, minHeight: 720, idealHeight: 780)
        .task { run.start(repo: repo, mr: mr, model: model) }
        .interactiveDismissDisabled()
    }

    private var titleBar: some View {
        HStack {
            Text("Resolve conflicts · !\(String(mr.iid)) \(mr.title)").font(.headline).lineLimit(1)
            Spacer()
            Label(settings.aiPreset.name, systemImage: "sparkles").foregroundStyle(.purple).font(.callout.weight(.semibold))
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
    }

    @ViewBuilder private var footer: some View {
        HStack(spacing: 12) {
            switch run.phase {
            case .starting, .running:
                Text("Cancel stops \(settings.aiPreset.name) and deletes the worktree. At \(settings.aiTimeoutMinutes) minutes the app stops it for you and keeps this log.")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Cancel run", role: .destructive) { Task { await run.discard(); dismiss() } }
                Button("Review changes") {}.disabled(true)
            case .review, .pushing:
                Text("Push runs git push --force-with-lease=\(mr.sourceBranch):\(run.outcome.map { String($0.originalSHA.prefix(7)) } ?? ""), so it fails if someone pushed in the meantime.")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Discard", role: .destructive) { Task { await run.discard(); dismiss() } }
                    .disabled(run.phase == .pushing)
                Button {
                    Task { await run.push() }
                } label: {
                    if run.phase == .pushing { ProgressView().controlSize(.small) } else { Label("Push to \(mr.sourceBranch)", systemImage: "arrow.up") }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(run.phase == .pushing || run.outcome?.allChecksPassed != true)
            case .pushed:
                Label("Pushed. GitLab updates the merge request in a moment.", systemImage: "checkmark.circle").foregroundStyle(.green)
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            case .failed(let message):
                ErrorText(message: message)
                Spacer()
                Button("Discard and close") { Task { await run.discard(); dismiss() } }.keyboardShortcut(.defaultAction)
            case .cancelled:
                Text("Cancelled. The worktree was deleted and nothing was pushed.").foregroundStyle(.secondary)
                Spacer()
                Button("Close") { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .footerBar()
    }
}

private struct ProgressSteps: View {
    let stage: ResolveStage
    let phase: AIResolveModel.Phase
    let strategy: ConflictStrategy
    let cliName: String

    private var index: Int {
        switch stage {
        case .fetching: return 0
        case .creatingWorktree: return 1
        case .replaying: return 2
        case .runningAI, .continuing: return 3
        case .checking: return 3
        case .ready, .pushing, .pushed: return 4
        }
    }

    var body: some View {
        let titles = ["Fetch", "Worktree", strategy == .rebase ? "Rebase onto target" : "Merge target", "\(cliName) resolves", "Your review"]
        HStack(spacing: 14) {
            ForEach(Array(titles.enumerated()), id: \.offset) { offset, title in
                if offset > 0 { Text("—").foregroundStyle(.tertiary) }
                HStack(spacing: 6) {
                    if offset < index || (offset == 4 && phase == .pushed) {
                        Image(systemName: "checkmark.circle").foregroundStyle(.green)
                    } else if offset == index, phase == .running || phase == .starting {
                        ProgressView().controlSize(.mini)
                    } else if offset == index {
                        Image(systemName: "\(offset + 1).circle.fill").foregroundStyle(Color.accentColor)
                    } else {
                        Image(systemName: "\(offset + 1).circle").foregroundStyle(.tertiary)
                    }
                    Text(title).fontWeight(offset == index ? .semibold : .regular)
                }
            }
            Spacer()
        }
        .font(.callout)
        .padding(.horizontal, 20)
        .padding(.vertical, 11)
    }
}

private struct RunningPane: View {
    let run: AIResolveModel
    let mr: MergeRequest
    let cliName: String

    var body: some View {
        HStack(alignment: .top, spacing: 20) {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Live output").font(.headline)
                    Spacer()
                    Button("Copy log") { Clipboard.copy(run.log.joined(separator: "\n")) }.controlSize(.small)
                }
                LogView(lines: run.log)
            }
            .frame(maxWidth: .infinity)

            VStack(alignment: .leading, spacing: 14) {
                Card {
                    VStack(alignment: .leading, spacing: 10) {
                        TimelineView(.periodic(from: run.startedAt, by: 1)) { context in
                            let elapsed = context.date.timeIntervalSince(run.startedAt)
                            let limit = Double(run.timeLimit.components.seconds)
                            VStack(alignment: .leading, spacing: 8) {
                                HStack(alignment: .firstTextBaseline, spacing: 8) {
                                    Text(Self.clock(elapsed)).font(.system(size: 26, weight: .bold).monospacedDigit())
                                    Text("of the \(Self.clock(limit)) limit").font(.caption).foregroundStyle(.secondary)
                                }
                                ProgressView(value: min(elapsed, limit), total: max(limit, 1))
                            }
                        }
                        Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 6) {
                            GridRow { Text("CLI").foregroundStyle(.secondary); Text(run.request?.ai.cliName ?? cliName) }
                            GridRow { Text("Branch").foregroundStyle(.secondary); Text("\(mr.sourceBranch) onto \(mr.targetBranch)").font(.caption.monospaced()) }
                            if let path = run.outcome?.worktree.path ?? worktreeHint {
                                GridRow { Text("Worktree").foregroundStyle(.secondary); Text(path).font(.caption.monospaced()).lineLimit(2).truncationMode(.middle) }
                            }
                        }
                        .font(.caption)
                    }
                    .padding(14)
                }
                Card {
                    HStack {
                        Text("Conflicts").font(.callout.weight(.semibold))
                        Spacer()
                        Text("\(run.resolvedFiles.count) of \(run.conflictFiles.count) resolved").font(.caption).foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 14).padding(.vertical, 10)
                    ForEach(run.conflictFiles, id: \.self) { file in
                        Divider()
                        HStack(spacing: 10) {
                            if run.resolvedFiles.contains(file) {
                                Image(systemName: "checkmark.circle").foregroundStyle(.green)
                            } else {
                                ProgressView().controlSize(.mini)
                            }
                            Text((file as NSString).lastPathComponent).font(.caption.monospaced())
                            Spacer()
                            Text(run.resolvedFiles.contains(file) ? "Resolved" : "Working").font(.caption).foregroundStyle(.secondary)
                        }
                        .padding(.horizontal, 14).padding(.vertical, 8)
                    }
                }
                Label("\(cliName) edits files only inside this worktree. Your own checkouts and the branch on GitLab stay as they are until you approve the diff.",
                      systemImage: "lock")
                    .font(.caption).foregroundStyle(.secondary)
                    .padding(12)
                    .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 10))
            }
            .frame(width: 340)
        }
        .padding(20)
    }

    private var worktreeHint: String? { nil }

    static func clock(_ seconds: Double) -> String {
        let total = Int(seconds)
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}

private struct ReviewPane: View {
    let outcome: ResolveOutcome
    let log: [String]
    @Binding var compareWithTarget: Bool
    @State private var showLog = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: 24) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Review the result before anything is pushed").font(.title3.bold())
                    Text(outcome.aiRounds == 0
                         ? "The branch replayed cleanly with no conflicts. Check the diff, then push."
                         : "Resolved \(outcome.conflictedFiles.count) conflicted file\(outcome.conflictedFiles.count == 1 ? "" : "s") in \(outcome.aiRounds) round\(outcome.aiRounds == 1 ? "" : "s").")
                        .foregroundStyle(.secondary)
                    Picker("Compare", selection: $compareWithTarget) {
                        Text("Against the original branch").tag(false)
                        Text("Merge request diff").tag(true)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .fixedSize()
                    .padding(.top, 4)
                }
                Spacer()
                VStack(alignment: .leading, spacing: 5) {
                    Text("Safety checks").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    ForEach(outcome.checks) { check in
                        Label(check.title, systemImage: check.passed ? "checkmark" : "xmark")
                            .foregroundStyle(check.passed ? .green : .red)
                            .font(.caption)
                    }
                    Button(showLog ? "Hide log" : "Show log (\(log.count) lines)") { showLog.toggle() }
                        .buttonStyle(.link).font(.caption)
                }
            }
            .padding(20)
            Divider()
            if showLog {
                LogView(lines: log).frame(height: 160).padding(12)
                Divider()
            }
            DiffView(files: compareWithTarget ? outcome.diffAgainstTarget : outcome.diffAgainstOriginal)
        }
    }
}

struct LogView: View {
    let lines: [String]

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 1) {
                    ForEach(Array(lines.enumerated()), id: \.offset) { index, line in
                        Text(line)
                            .foregroundStyle(line.hasPrefix("$") ? Color(white: 0.6) : Color(white: 0.9))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .id(index)
                    }
                }
                .font(.system(size: 12, design: .monospaced))
                .textSelection(.enabled)
                .padding(14)
            }
            .background(Color(white: 0.11), in: RoundedRectangle(cornerRadius: 10))
            .onChange(of: lines.count) { _, count in
                if count > 0 { proxy.scrollTo(count - 1, anchor: .bottom) }
            }
        }
    }
}
