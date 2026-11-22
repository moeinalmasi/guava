import SwiftUI

/// The whole window: the applications on this Mac, and one button that updates everything.
struct ContentView: View {
    @StateObject private var viewModel: GuavaViewModel

    init() {
        _viewModel = StateObject(wrappedValue: GuavaViewModel(store: .home))
    }

    /// For tests, which supply a view model they have prepared.
    init(viewModel: GuavaViewModel) {
        _viewModel = StateObject(wrappedValue: viewModel)
    }

    private var isChecking: Bool {
        viewModel.isScanning || viewModel.isCheckingAll
    }

    /// The list is a single column. In a wide window it stays this narrow and sits in the
    /// middle, so that a name is never far from its version.
    private static let columnWidth: CGFloat = 760

    var body: some View {
        VStack(spacing: 0) {
            header
                .frame(maxWidth: Self.columnWidth)
            Divider()
                // The check's progress is drawn along this line, so that nothing moves when
                // the check starts and ends.
                .overlay(alignment: .leading) {
                    if viewModel.isCheckingAll {
                        GeometryReader { line in
                            Rectangle()
                                .fill(Color.accentColor)
                                .frame(width: line.size.width * viewModel.progress, height: 2)
                                .animation(.linear(duration: 0.2), value: viewModel.progress)
                        }
                        .frame(height: 2)
                        .accessibilityHidden(true)
                    }
                }
            if viewModel.listedApps.isEmpty {
                placeholder
            } else {
                appList
            }
        }
        .frame(minWidth: 520, minHeight: 420)
        .onAppear {
            if !isChecking {
                viewModel.checkForUpdates(persistTimestamp: false)
            }
        }
        .sheet(isPresented: $viewModel.isShowingUpdateProgress) {
            UpdateEverythingView(updater: viewModel.updater, isPresented: $viewModel.isShowingUpdateProgress)
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Text(viewModel.summaryLine)
                .font(.system(size: 13, weight: .medium))
                .lineLimit(1)
                .help(viewModel.listNote)

            Spacer(minLength: 12)

            Button {
                viewModel.checkForUpdates()
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .disabled(isChecking || viewModel.isUpdatingEverything)
            .keyboardShortcut("r", modifiers: .command)
            .help(checkAgainHelp)
            .accessibilityLabel("Check for updates")

            UpdateEverythingButton(updater: viewModel.updater) {
                viewModel.isShowingUpdateProgress = true
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    private var checkAgainHelp: String {
        guard let last = viewModel.lastScanTime else { return "Check for updates again" }
        return "Check for updates again. Last checked \(last.formatted(date: .abbreviated, time: .shortened))"
    }

    /// What fills the window while there is no list. The line above it says why.
    private var placeholder: some View {
        Group {
            if isChecking {
                ProgressView()
            } else {
                Image(systemName: "app.dashed")
                    .font(.system(size: 40))
                    .foregroundColor(.secondary)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityHidden(true)
    }

    private var appList: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(viewModel.listedApps) { app in
                    AppRow(app: app)
                    Divider()
                        .padding(.leading, 56)
                        .padding(.trailing, 16)
                }
            }
            .frame(maxWidth: Self.columnWidth)
            .frame(maxWidth: .infinity)
        }
    }
}

/// One application: its icon, its name, and how its version compares with the latest one.
struct AppRow: View {
    @ObservedObject var app: AppInfo

    var body: some View {
        HStack(spacing: 12) {
            Group {
                if let icon = app.icon {
                    Image(nsImage: icon).resizable()
                } else {
                    Image(systemName: "app.fill").resizable().foregroundColor(.secondary)
                }
            }
            .frame(width: 28, height: 28)

            Text(app.name)
                .font(.system(size: 13, weight: .medium))
                .lineLimit(1)
                .truncationMode(.tail)

            Spacer(minLength: 12)

            HStack(spacing: 6) {
                versions
                    .font(.system(size: 12, design: .monospaced))
                    .lineLimit(1)
                // The same width in every row, so that the versions line up.
                mark
                    .frame(width: 16, height: 16)
            }
            // A long name gives way, so that the versions can always be read in full.
            .fixedSize(horizontal: true, vertical: false)
            .help(statusDescription)
        }
        .padding(.vertical, 7)
        .padding(.horizontal, 16)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(app.name), version \(app.currentVersion). \(statusDescription)")
    }

    @ViewBuilder
    private var versions: some View {
        switch app.updateStatus {
        case .updateAvailable:
            Text("\(app.currentVersion) → \(app.latestVersion ?? "newer")")
                .fontWeight(.semibold)
                .foregroundColor(.orange)
        case .updating:
            Text("Updating…")
                .foregroundColor(.blue)
        case .checking, .upToDate, .error, .unknown:
            Text(app.currentVersion)
                .foregroundColor(.secondary)
        }
    }

    @ViewBuilder
    private var mark: some View {
        switch app.updateStatus {
        case .checking, .updating:
            ProgressView().controlSize(.small)
        case .updateAvailable:
            Image(systemName: "arrow.up.circle.fill").foregroundColor(.orange)
        case .upToDate:
            Image(systemName: "checkmark.circle.fill").foregroundColor(.green)
        case .error:
            Image(systemName: "exclamationmark.triangle.fill").foregroundColor(.red)
        case .unknown:
            Color.clear
        }
    }

    private var statusDescription: String {
        switch app.updateStatus {
        case .checking: return "Checking for updates"
        case .updating: return "Updating"
        case .updateAvailable: return "Version \(app.latestVersion ?? "newer") is available"
        case .upToDate: return upToDateDescription
        case .error: return app.updateError ?? "The last update did not work"
        case .unknown: return "No update information"
        }
    }

    /// An app can be as up to date as it will get on this Mac without being at the latest
    /// version. The row stays green, and this says why.
    private var upToDateDescription: String {
        let latest = app.latestVersion ?? "A newer version"
        switch app.heldBack {
        case .organisation:
            return "Up to date for this Mac. Version \(latest) exists, but this copy is licensed "
                + "to your organisation, which installs its updates"
        case .notInstalled:
            return "Up to date for this Mac. Version \(latest) exists, but the app's own updater "
                + "has not installed it here"
        case nil:
            return "Up to date"
        }
    }
}
