import SwiftUI
import AppKit

class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)

        // Downloads from an update run that was interrupted must not be left on disk.
        Task {
            _ = await InstallCleanup.removeAbandonedRuns()
        }
    }
    
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        return true
    }
}

@main
enum GuavaMain {
    static func main() {
        if let command = HeadlessCommand(arguments: Array(CommandLine.arguments.dropFirst())) {
            HeadlessRunner.run(command)
        }
        GuavaApp.main()
    }
}

struct GuavaApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        .windowStyle(.titleBar)
        .defaultSize(width: 620, height: 720)
        
        Settings {
            TabView {
                UpdateSettingsView()
                    .tabItem { Label("Updates", systemImage: "arrow.triangle.2.circlepath") }
                AboutView()
                    .tabItem { Label("About", systemImage: "info.circle") }
            }
        }
    }
}

struct AboutView: View {
    private let appVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
    private let copyright = (Bundle.main.object(forInfoDictionaryKey: "NSHumanReadableCopyright") as? String)
        .flatMap { $0.isEmpty ? nil : $0 }

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "leaf.fill")
                .font(.system(size: 48))
                .foregroundColor(.green)
            Text("Guava")
                .font(.title)
                .fontWeight(.bold)
            Text("macOS App Updater")
                .font(.subheadline)
                .foregroundColor(.secondary)
            Text("Version \(appVersion)")
                .font(.caption)
                .foregroundColor(.secondary)
            if let copyright {
                Divider().frame(width: 200)
                Text(copyright)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
        .padding(30)
        .frame(width: 300, height: 250)
    }
}
