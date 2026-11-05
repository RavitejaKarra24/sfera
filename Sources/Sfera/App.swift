import AppKit
import SwiftUI

@MainActor
enum Shared {
    static let model = Controller()
}

@main
struct SferaApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    init() {
        if Probe.handleArguments() { exit(0) }
    }

    var body: some Scene {
        MenuBarExtra {
            Panel(model: Shared.model)
                .background(VisibilityObserver { Shared.model.panelVisible = $0 })
        } label: {
            MenuIcon(model: Shared.model)
        }
        .menuBarExtraStyle(.window)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        MainActor.assumeIsolated { Shared.model.launch() }
    }

    /// Hand the Mac's sound output back before quitting.
    func applicationWillTerminate(_ notification: Notification) {
        MainActor.assumeIsolated { Shared.model.shutdown() }
    }
}

/// Menu bar icon: outline when off, ring when on, filled while spatialising.
private struct MenuIcon: View {
    let model: Controller
    var body: some View {
        let name = !model.wantsOn ? "headphones"
            : (model.settings.spatial ? "headphones.circle.fill" : "headphones.circle")
        Image(systemName: name)
            .accessibilityLabel(model.wantsOn ? (model.settings.spatial ? "Sfera, spatial" : "Sfera, original") : "Sfera, off")
    }
}

/// Reports whether the panel's window is on screen, so meters only run while it's visible.
private struct VisibilityObserver: NSViewRepresentable {
    let onChange: (Bool) -> Void

    func makeNSView(context: Context) -> NSView { WatchView(onChange: onChange) }
    func updateNSView(_ nsView: NSView, context: Context) {}

    final class WatchView: NSView {
        let onChange: (Bool) -> Void
        private var token: NSObjectProtocol?
        init(onChange: @escaping (Bool) -> Void) {
            self.onChange = onChange
            super.init(frame: .zero)
        }
        required init?(coder: NSCoder) { fatalError() }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let token { NotificationCenter.default.removeObserver(token) }
            token = nil
            guard let window else { onChange(false); return }
            token = NotificationCenter.default.addObserver(
                forName: NSWindow.didChangeOcclusionStateNotification, object: window, queue: .main
            ) { [weak self] _ in
                guard let self, let window = self.window else { return }
                self.onChange(window.occlusionState.contains(.visible))
            }
            onChange(window.occlusionState.contains(.visible))
        }

        deinit { if let token { NotificationCenter.default.removeObserver(token) } }
    }
}
