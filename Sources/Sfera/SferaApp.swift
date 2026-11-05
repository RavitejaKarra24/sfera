import SwiftUI
import SpatialCore

@main
struct SferaApp: App {
    @NSApplicationDelegateAdaptor(SferaAppDelegate.self) private var delegate

    init() {
        if Headless.handleLaunchArguments() { exit(0) }
    }

    var body: some Scene {
        Window("Sfera", id: "main") {
            ListenView()
                .frame(minWidth: 360, idealWidth: 400, minHeight: 520, idealHeight: 580)
                .preferredColorScheme(.dark)
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentMinSize)
        .defaultSize(width: 400, height: 580)
        .commands { ListenCommands() }

        Settings {
            ListenSettingsView()
                .frame(width: 480, height: 620)
                .preferredColorScheme(.dark)
        }

        MenuBarExtra("Sfera", systemImage: "headphones") {
            ListenMenu()
        }
    }
}

/// Keeps Sfera running in the menu bar when its window is closed, and opens files
/// handed over by Finder ("Open With › Sfera" or dropping on the Dock icon).
final class SferaAppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    /// Hand the Mac's sound output back before quitting.
    func applicationWillTerminate(_ notification: Notification) {
        MainActor.assumeIsolated { AppEnv.listen.shutdown() }
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        Task { @MainActor in AppEnv.listen.addFiles(urls) }
    }
}

/// Menus. Space plays/pauses files (or toggles Spatial for Mac audio).
struct ListenCommands: Commands {
    private var listen: ListenModel { AppEnv.listen }
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("Open…") { listen.presentOpenPanel() }
                .keyboardShortcut("o", modifiers: .command)
        }
        CommandMenu("Playback") {
            Button("Play / Pause") { listen.togglePlay() }
                .keyboardShortcut(.space, modifiers: [])
            Button("Next") { listen.next() }
                .keyboardShortcut(.rightArrow, modifiers: .command)
            Button("Previous") { listen.previous() }
                .keyboardShortcut(.leftArrow, modifiers: .command)
            Button("Forward 10 s") { listen.skip(seconds: 10) }
                .keyboardShortcut(.rightArrow, modifiers: [])
            Button("Back 10 s") { listen.skip(seconds: -10) }
                .keyboardShortcut(.leftArrow, modifiers: [])
            Divider()
            Button(listen.settings.spatial ? "Switch to Original" : "Switch to Spatial") { listen.toggleSpatial() }
                .keyboardShortcut("s", modifiers: .command)
        }
        CommandGroup(after: .windowList) {
            Button("Sfera") { openWindow(id: "main") }
                .keyboardShortcut("1", modifiers: .command)
        }
    }
}

