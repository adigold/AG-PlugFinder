import AppKit
import ServiceManagement
import SwiftUI

@main
enum Entry {
    static func main() {
        // The same binary doubles as the screenshot helper process.
        let args = CommandLine.arguments
        if let i = args.firstIndex(of: "--render") {
            SnapshotRenderer.run(Array(args[i...]))
        }
        AUPluginHelperApp.main()
    }
}

struct AUPluginHelperApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate

    var body: some Scene {
        Window("AU Plugin Helper", id: "library") {
            LibraryView()
                .frame(minWidth: 820, minHeight: 520)
        }
        .defaultSize(width: 1040, height: 680)

        MenuBarExtra {
            MenuBarContent()
        } label: {
            Image(systemName: "puzzlepiece.extension")
        }

        Settings {
            SettingsView()
        }
    }
}

struct MenuBarContent: View {
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        Button("Open Plugin Picker  \(HotKey.display)") { PickerPanelController.shared.show() }
        Button("Plugin Library…") {
            NSApp.activate()
            openWindow(id: "library")
        }
        Divider()
        Button("Settings…") {
            NSApp.activate()
            openSettings()
        }
        Button("Quit AU Plugin Helper") { NSApp.terminate(nil) }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        HotKey.shared.register { PickerPanelController.shared.toggle() }
        LaunchAtLogin.applyDefaultOnFirstRun()

        Task { @MainActor in
            let store = PluginStore.shared
            store.rescan()
            // Only new or updated plugins get a screenshot; the rest load from the cache.
            if store.plugins.contains(where: { $0.snapshotState == .pending }) {
                SnapshotQueue.shared.start()
            }
            #if DEBUG
            SelfTest.runIfRequested()
            #endif
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
}

enum LaunchAtLogin {
    static var isEnabled: Bool { SMAppService.mainApp.status == .enabled }

    static func set(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {
            NSLog("AU Plugin Helper: launch at login change failed: \(error)")
        }
    }

    /// Turns launch at login on the first time the app runs (Adi's choice: on, with an off switch).
    static func applyDefaultOnFirstRun() {
        // Only the installed copy registers itself, never a test build.
        guard Bundle.main.bundlePath.hasPrefix("/Applications/") else { return }
        let key = "didApplyLaunchAtLoginDefault"
        guard !UserDefaults.standard.bool(forKey: key) else { return }
        UserDefaults.standard.set(true, forKey: key)
        set(true)
    }
}
