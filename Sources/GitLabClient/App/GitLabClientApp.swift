import SwiftUI
import GitLabClientCore

@main
struct GitLabClientApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var model = AppModel.shared

    var body: some Scene {
        WindowGroup(AppInfo.name, id: "main") {
            RootView()
                .environment(model)
                .environment(model.settings)
        }
        .defaultSize(width: 1280, height: 820)
        .windowResizability(.contentMinSize)
        .commands {
            CommandGroup(after: .newItem) {
                Button("Add Domain…") { model.showAddDomain = true }
                    .keyboardShortcut("n", modifiers: [.command, .shift])
                    .disabled(model.isOnboarding || model.needsOnboarding)
            }
        }

        Settings {
            SettingsView()
                .environment(model)
                .environment(model.settings)
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // `swift run` starts a bare binary; make it a normal app with a Dock icon and menus.
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        AppModel.shared.settings.appearance.apply()
        #if DEBUG
        DebugSnapshot.scheduleIfRequested()
        #endif
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

struct RootView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        ZStack {
            if !model.isLoaded {
                ProgressView().frame(width: 760, height: 720)
            } else if model.isOnboarding || model.needsOnboarding {
                OnboardingFlow(mode: .firstRun)
            } else {
                MainWindow()
            }
        }
        .task {
            if !model.isLoaded { await model.load() }
            #if DEBUG
            if DebugSnapshot.opensSettings { openSettings() }
            #endif
        }
        .onChange(of: model.needsOnboarding) { _, needs in
            if needs { model.isOnboarding = true }
        }
    }
}
