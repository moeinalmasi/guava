import SwiftUI

/// The one button that updates everything.
struct UpdateEverythingButton: View {
    @ObservedObject var updater: UpdateOrchestrator
    /// Shows the progress sheet.
    let reveal: () -> Void

    var body: some View {
        Button {
            if !updater.isRunning {
                updater.start()
            }
            reveal()
        } label: {
            if updater.isRunning {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("Updating: \(updater.phase.rawValue)")
                }
            } else {
                Label("Update Everything", systemImage: "arrow.triangle.2.circlepath.circle.fill")
            }
        }
        .buttonStyle(.borderedProminent)
        .tint(.green)
        .keyboardShortcut("u", modifiers: .command)
        .help("Update Homebrew, developer tools and every application, then delete the downloaded packages")
    }
}

/// Progress, results and the activity log of an Update Everything run.
struct UpdateEverythingView: View {
    @ObservedObject var updater: UpdateOrchestrator
    @Binding var isPresented: Bool
    // Stored preferences rather than @State: with the current SDK @State needs a compiler
    // plugin that the Command Line Tools do not ship.
    @AppStorage("updateAll.showsLog") private var showsLog = true

    private static let steps: [UpdateOrchestrator.Phase] = [
        .scanning, .homebrew, .tools, .apps, .installing, .cleanup, .verifying,
    ]

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            itemList
            Divider()
            logSection
            Divider()
            footer
        }
        .frame(minWidth: 560, idealWidth: 700, minHeight: 480, idealHeight: 600)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Image(systemName: "arrow.triangle.2.circlepath.circle.fill")
                    .font(.system(size: 26))
                    .foregroundColor(.green)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Update Everything")
                        .font(.title3)
                        .fontWeight(.semibold)
                    Text(updater.activity.isEmpty ? "Ready" : updater.activity)
                        .font(.system(size: 12))
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                }
                Spacer()
                if updater.isRunning {
                    // A clock that keeps counting is the plainest sign that the run is alive.
                    if let started = updater.runStarted {
                        TimelineView(.periodic(from: started, by: 1)) { context in
                            Text(UpdateOrchestrator.formatElapsed(context.date.timeIntervalSince(started)))
                                .font(.system(size: 12))
                                .monospacedDigit()
                                .foregroundColor(.secondary)
                        }
                        .help("Time since this run started")
                    }
                    ProgressView().controlSize(.small)
                }
            }

            HStack(spacing: 6) {
                ForEach(Self.steps, id: \.self) { step in
                    let progress = progress(of: step)
                    Text(step.rawValue)
                        .font(.system(size: 10, weight: .medium))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .foregroundColor(progress == .upcoming ? .secondary : .white)
                        .background(Capsule().fill(progress.color))
                }
            }
        }
        .padding(16)
    }

    private enum StepProgress {
        case done
        case current
        case upcoming

        var color: Color {
            switch self {
            case .done: return .green
            case .current: return .blue
            case .upcoming: return Color(nsColor: .controlBackgroundColor)
            }
        }
    }

    private func progress(of step: UpdateOrchestrator.Phase) -> StepProgress {
        if updater.phase == .finished {
            return .done
        }
        guard let current = Self.steps.firstIndex(of: updater.phase),
              let index = Self.steps.firstIndex(of: step) else {
            return .upcoming
        }
        if index < current { return .done }
        return index == current ? .current : .upcoming
    }

    private var itemList: some View {
        ScrollView {
            if updater.items.isEmpty {
                VStack(spacing: 8) {
                    if updater.isRunning {
                        ProgressView()
                        Text("Scanning applications, Homebrew and the home folder…")
                            .foregroundColor(.secondary)
                    } else {
                        Text("Nothing has run yet.")
                            .foregroundColor(.secondary)
                    }
                }
                .frame(maxWidth: .infinity)
                .padding(24)
            } else {
                LazyVStack(spacing: 0) {
                    ForEach(updater.items) { item in
                        HStack(spacing: 10) {
                            stateIcon(item.state)
                                .frame(width: 18)
                            Text(item.name)
                                .font(.system(size: 13, weight: .medium))
                                .lineLimit(1)
                            Text(item.category.rawValue)
                                .font(.system(size: 9, weight: .semibold))
                                .foregroundColor(.secondary)
                                .padding(.horizontal, 5)
                                .padding(.vertical, 1)
                                .background(Color(nsColor: .controlBackgroundColor))
                                .cornerRadius(3)
                            Spacer(minLength: 12)
                            detailText(for: item)
                                .font(.system(size: 11))
                                .foregroundColor(detailColor(item.state))
                                .lineLimit(2)
                                .multilineTextAlignment(.trailing)
                                .help(item.state.detail)
                        }
                        .padding(.vertical, 6)
                        .padding(.horizontal, 16)
                        Divider()
                    }
                }
            }
        }
        .frame(minHeight: 150)
    }

    /// What an item is doing. One that is running counts the time it has taken, so that a step
    /// working in silence can be told from one that has stopped.
    @ViewBuilder
    private func detailText(for item: UpdateItem) -> some View {
        if case .running = item.state, let started = item.startedAt {
            TimelineView(.periodic(from: started, by: 1)) { context in
                Text("Working… \(UpdateOrchestrator.formatElapsed(context.date.timeIntervalSince(started)))")
                    .monospacedDigit()
            }
        } else {
            Text(item.state.detail)
        }
    }

    @ViewBuilder
    private func stateIcon(_ state: UpdateItemState) -> some View {
        switch state {
        case .pending:
            Image(systemName: "clock").foregroundColor(.secondary)
        case .running:
            ProgressView().controlSize(.small)
        case .updated:
            Image(systemName: "checkmark.circle.fill").foregroundColor(.green)
        case .started:
            Image(systemName: "arrow.down.circle.fill").foregroundColor(.blue)
        case .unchanged:
            Image(systemName: "checkmark.circle").foregroundColor(.secondary)
        case .needsAttention:
            Image(systemName: "exclamationmark.circle.fill").foregroundColor(.orange)
        case .failed:
            Image(systemName: "xmark.octagon.fill").foregroundColor(.red)
        case .skipped:
            Image(systemName: "minus.circle").foregroundColor(.secondary)
        }
    }

    private func detailColor(_ state: UpdateItemState) -> Color {
        switch state {
        case .failed: return .red
        case .needsAttention: return .orange
        case .updated: return .green
        default: return .secondary
        }
    }

    private var logSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                showsLog.toggle()
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: showsLog ? "chevron.down" : "chevron.right")
                        .font(.system(size: 9, weight: .bold))
                    Text("Activity log")
                        .font(.system(size: 11, weight: .semibold))
                    Spacer()
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundColor(.secondary)
            .padding(.horizontal, 16)
            .padding(.vertical, 6)

            if showsLog {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 1) {
                            ForEach(updater.log) { entry in
                                Text(entry.text)
                                    .font(.system(size: 11, design: .monospaced))
                                    .fontWeight(entry.level == .phase ? .bold : .regular)
                                    .foregroundColor(logColor(entry.level))
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .textSelection(.enabled)
                                    .id(entry.id)
                            }
                        }
                        .padding(.horizontal, 16)
                        .padding(.bottom, 8)
                    }
                    .frame(minHeight: 140, maxHeight: 220)
                    .background(Color(nsColor: .textBackgroundColor).opacity(0.5))
                    .onChange(of: updater.log.last?.id) { last in
                        if let last {
                            proxy.scrollTo(last, anchor: .bottom)
                        }
                    }
                    .onAppear {
                        // Reopening the sheet after a run should show how it ended.
                        if let last = updater.log.last?.id {
                            proxy.scrollTo(last, anchor: .bottom)
                        }
                    }
                }
            }
        }
    }

    private func logColor(_ level: UpdateLogEntry.Level) -> Color {
        switch level {
        case .phase, .info: return .primary
        case .detail: return .secondary
        case .success: return .green
        case .warning: return .orange
        case .error: return .red
        }
    }

    private var footer: some View {
        HStack(spacing: 10) {
            if let summary = updater.summary {
                Image(systemName: summary.isClean ? "checkmark.seal.fill" : "exclamationmark.triangle.fill")
                    .foregroundColor(summary.isClean ? .green : .orange)
                VStack(alignment: .leading, spacing: 1) {
                    Text(summary.headline)
                        .font(.system(size: 12, weight: .medium))
                    if summary.bytesFreed > 0 {
                        Text("\(UpdateOrchestrator.formatBytes(summary.bytesFreed)) of downloaded packages deleted")
                            .font(.system(size: 10))
                            .foregroundColor(.secondary)
                    }
                }
            } else if updater.isRunning {
                Text("You can hide this window; the update keeps running.")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
            }
            Spacer()
            if updater.isRunning {
                Button("Stop", role: .destructive) { updater.cancel() }
                Button("Hide") { isPresented = false }
                    .keyboardShortcut(.cancelAction)
            } else {
                Button("Run Again") { updater.start() }
                Button("Done") { isPresented = false }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }
}

/// Preferences for Update Everything.
struct UpdateSettingsView: View {
    @AppStorage(UpdateSettings.Key.agentEnabled) private var agentEnabled = true
    @AppStorage(UpdateSettings.Key.allowComputerUse) private var allowComputerUse = true
    @AppStorage(UpdateSettings.Key.quitRunningApps) private var quitRunningApps = true
    @AppStorage(UpdateSettings.Key.sweepDownloads) private var sweepDownloads = true
    @AppStorage(UpdateSettings.Key.cleanBrewCache) private var cleanBrewCache = true
    @AppStorage(UpdateSettings.Key.agentModel) private var agentModel = ""
    @AppStorage(UpdateSettings.Key.agentMaxCredits) private var agentMaxCredits = 60
    @AppStorage(UpdateSettings.Key.agentTimeoutMinutes) private var agentTimeoutMinutes = 20
    @StateObject private var agentStatus = AgentStatus()

    var body: some View {
        Form {
            Section {
                Toggle("Use the GitHub Copilot agent for apps nothing else can update", isOn: $agentEnabled)
                Toggle("Let the agent control the screen (computer use)", isOn: $allowComputerUse)
                    .disabled(!agentEnabled)
                TextField("Model", text: $agentModel, prompt: Text("Copilot CLI default"))
                    .disabled(!agentEnabled)
                Stepper("AI credit limit per app: \(agentMaxCredits)", value: $agentMaxCredits, in: 30...1000, step: 10)
                    .disabled(!agentEnabled)
                Stepper("Time limit per app: \(agentTimeoutMinutes) min", value: $agentTimeoutMinutes, in: 5...120, step: 5)
                    .disabled(!agentEnabled)
                Text(agentStatus.text)
                    .font(.caption)
                    .foregroundColor(.secondary)
            } header: {
                Text("Copilot agent")
            } footer: {
                Text("The agent never installs what it downloads. Guava checks the signature, developer and notarization of each download first, and never gives the agent administrator rights. With computer use on, the agent may also operate an app's own updater or the App Store.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Section("Installing") {
                Toggle("Quit running apps to update them, then reopen them", isOn: $quitRunningApps)
            }

            Section("Afterwards") {
                Toggle("Empty Homebrew's download cache", isOn: $cleanBrewCache)
                Toggle("Move installers that appear in Downloads to the Trash", isOn: $sweepDownloads)
            }
        }
        .formStyle(.grouped)
        .frame(width: 520, height: 620)
        .task {
            await agentStatus.refresh()
        }
    }
}

/// Whether the Copilot CLI the agent depends on is installed.
@MainActor
private final class AgentStatus: ObservableObject {
    @Published var text = "Checking…"

    func refresh() async {
        guard let cli = CopilotCLI.locate() else {
            text = "GitHub Copilot CLI not found. Install it and sign in to use the agent."
            return
        }
        let version = await cli.version().map { " \($0)" } ?? ""
        text = "GitHub Copilot CLI\(version) found at \(cli.executablePath)"
    }
}
