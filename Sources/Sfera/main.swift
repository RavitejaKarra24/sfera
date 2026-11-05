import AppKit
import Observation
import SwiftUI

// Menu-bar app: no window, no Dock icon. Headless probes (`Sfera --<probe>`) run first.
let app = NSApplication.shared
if Probe.handleArguments() { exit(0) }
MainActor.assumeIsolated {
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.accessory)
    withExtendedLifetime(delegate) { app.run() }
}

/// Owns the status item: left click opens the panel, right click (or ⌃-click) shows a menu.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSPopoverDelegate {
    private let model = Controller()
    private var item: NSStatusItem!
    private let popover = NSPopover()

    func applicationDidFinishLaunching(_ notification: Notification) {
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = item.button {
            button.target = self
            button.action = #selector(clicked(_:))
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }

        // The popover follows the panel's size, so switching to Settings resizes it.
        let host = NSHostingController(rootView: Panel(model: model))
        host.sizingOptions = [.preferredContentSize]
        popover.contentViewController = host
        popover.behavior = .transient
        popover.animates = true
        popover.appearance = NSAppearance(named: .darkAqua)
        popover.delegate = self

        updateIcon()
        model.launch()
    }

    /// Hand the Mac's sound output back before quitting.
    func applicationWillTerminate(_ notification: Notification) {
        model.shutdown()
    }

    // MARK: Clicks

    @objc private func clicked(_ sender: NSStatusBarButton) {
        guard let event = NSApp.currentEvent else { return }
        if event.type == .rightMouseUp || event.modifierFlags.contains(.control) {
            showMenu()
        } else {
            togglePanel()
        }
    }

    private func togglePanel() {
        if popover.isShown { popover.performClose(nil); return }
        guard let button = item.button else { return }
        NSApp.activate()
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        popover.contentViewController?.view.window?.makeKey()
    }

    private func showMenu() {
        if popover.isShown { popover.performClose(nil) }
        let menu = NSMenu()
        menu.addItem(withTitle: model.wantsOn ? "Turn Off" : "Turn On", action: #selector(toggleOn), keyEquivalent: "").target = self
        let spatial = menu.addItem(withTitle: "Spatial", action: #selector(toggleSpatial), keyEquivalent: "")
        spatial.target = self
        spatial.state = model.settings.spatial ? .on : .off
        let refined = menu.addItem(withTitle: "Refined Renderer", action: #selector(toggleRenderer), keyEquivalent: "")
        refined.target = self
        refined.state = model.settings.renderer == .refined ? .on : .off
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit Sfera", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        // Attach the menu only for this click, so a left click keeps opening the panel.
        item.menu = menu
        item.button?.performClick(nil)
        item.menu = nil
    }

    @objc private func toggleOn() { model.setOn(!model.wantsOn) }
    @objc private func toggleSpatial() { model.toggleSpatial() }
    @objc private func toggleRenderer() { model.settings.renderer = model.settings.renderer == .classic ? .refined : .classic }

    // MARK: Popover

    func popoverDidShow(_ notification: Notification) { model.panelVisible = true }

    func popoverDidClose(_ notification: Notification) {
        model.panelVisible = false
        model.panelPage = .main      // open on the main page next time
    }

    // MARK: Icon

    /// Outline when off, ring when on, filled while spatialising. Re-registers on every change.
    private func updateIcon() {
        withObservationTracking {
            let name = !model.wantsOn ? "headphones"
                : (model.settings.spatial ? "headphones.circle.fill" : "headphones.circle")
            let label = model.wantsOn ? (model.settings.spatial ? "Sfera, spatial" : "Sfera, original") : "Sfera, off"
            let image = NSImage(systemSymbolName: name, accessibilityDescription: label)
            image?.isTemplate = true
            item.button?.image = image
            item.button?.toolTip = label
        } onChange: { [weak self] in
            Task { @MainActor in self?.updateIcon() }
        }
    }
}
