import AppKit
import Observation
import SwiftUI

/// Owns the menu bar item, the mixer panel, and the settings window.
@MainActor
final class StatusItemController: NSObject {
    private let store: MixerStore
    private let statusItem: NSStatusItem
    private let host: NSHostingController<PanelRoot>
    private let panel: PanelWindow
    private var settingsWindow: NSWindow?
    private var globalMonitor: Any?
    private var localMonitor: Any?
    private var resignObserver: Any?

    private var cornerRadius: CGFloat {
        if #available(macOS 26.0, *) { return 16 }
        return 12
    }

    init(store: MixerStore) {
        self.store = store
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        host = NSHostingController(
            rootView: PanelRoot(
                store: store,
                maxListHeight: PanelMetrics.defaultMaxListHeight,
                cornerRadius: 12,
                onOpenSettings: {},
                onQuit: {}
            )
        )
        panel = PanelWindow(contentViewController: host)
        super.init()

        host.sizingOptions = [.preferredContentSize]
        host.view.setFrameSize(NSSize(width: PanelMetrics.width, height: 200))
        rebuildRootView(maxListHeight: PanelMetrics.defaultMaxListHeight)

        // macOS persists a hidden status item across launches, which is how the icon
        // can disappear with no way to bring it back. Force it visible every launch.
        statusItem.autosaveName = "com.bibaskandel.Still.status"
        statusItem.isVisible = true
        if let button = statusItem.button {
            // The default symbol weight renders lighter than the system's own menu bar
            // glyphs. This configuration matches them and measures 18x14pt: both even,
            // so the button centres the icon on whole pixels in a 24pt menu bar. An odd
            // height lands on a half pixel and looks blurred on a non-Retina display.
            let icon = NSImage(systemSymbolName: "slider.horizontal.3", accessibilityDescription: "Still")?
                .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 14, weight: .medium))
            icon?.isTemplate = true
            button.image = icon
            button.imagePosition = .imageOnly
            button.target = self
            button.action = #selector(statusItemClicked)
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
            button.setAccessibilityLabel("Still")
        }
        updateStatusItemAppearance()
        trackEnabledState()
    }

    // MARK: - Menu bar item

    @objc private func statusItemClicked() {
        if NSApp.currentEvent?.type == .rightMouseUp {
            closePanel()
            showContextMenu()
        } else {
            togglePanel()
        }
    }

    private func showContextMenu() {
        let menu = NSMenu()
        let toggle = NSMenuItem(title: "Enable Still", action: #selector(toggleEnabled), keyEquivalent: "")
        toggle.target = self
        toggle.state = store.isEnabled ? .on : .off
        menu.addItem(toggle)
        menu.addItem(.separator())
        let settings = NSMenuItem(title: "Still Settings…", action: #selector(showSettings), keyEquivalent: ",")
        settings.target = self
        menu.addItem(settings)
        let quit = NSMenuItem(title: "Quit Still", action: #selector(quit), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)

        statusItem.menu = menu
        statusItem.button?.performClick(nil)
        statusItem.menu = nil
    }

    @objc private func toggleEnabled() { store.setEnabled(!store.isEnabled) }

    @objc private func quit() { NSApp.terminate(nil) }

    /// Mirrors the mixer's on/off state in the menu bar so it is readable without
    /// opening the panel.
    private func updateStatusItemAppearance() {
        statusItem.button?.appearsDisabled = !store.isEnabled
        statusItem.button?.toolTip = store.isEnabled ? "Still" : "Still — off"
    }

    private func trackEnabledState() {
        withObservationTracking {
            _ = store.isEnabled
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                self?.updateStatusItemAppearance()
                self?.trackEnabledState()
            }
        }
    }

    // MARK: - Panel

    func togglePanel() {
        if panel.isVisible { closePanel() } else { openPanel() }
    }

    func openPanel() {
        guard let button = statusItem.button, let buttonWindow = button.window else { return }
        let buttonFrame = buttonWindow.convertToScreen(button.convert(button.bounds, to: nil))
        let screen = NSScreen.screens.first { $0.frame.intersects(buttonFrame) }
            ?? buttonWindow.screen ?? NSScreen.main
        panel.anchorScreen = screen
        panel.anchor = NSPoint(x: buttonFrame.midX, y: buttonFrame.minY - 6)

        store.refresh()
        rebuildRootView(maxListHeight: maxListHeight(for: screen, below: buttonFrame.minY))

        host.view.layoutSubtreeIfNeeded()
        panel.setContentSize(host.view.fittingSize)
        panel.orderFrontRegardless()
        panel.makeKey()
        button.highlight(true)
        installMonitors()
        store.setPanelVisible(true)
    }

    func closePanel() {
        // Torn down before the visibility check so a panel that AppKit ordered out
        // on its own cannot leave the dismissal monitors installed.
        removeMonitors()
        statusItem.button?.highlight(false)
        store.setPanelVisible(false)
        guard panel.isVisible else { return }
        panel.orderOut(nil)
    }

    /// Screen frame of the menu bar item, or an empty rect when it has no window.
    private func statusItemFrame() -> NSRect {
        guard let button = statusItem.button, let window = button.window else { return .zero }
        return window.convertToScreen(button.convert(button.bounds, to: nil))
    }

    /// Keeps the panel inside the screen even on short or mirrored displays.
    private func maxListHeight(for screen: NSScreen?, below menuBarBottom: CGFloat) -> CGFloat {
        guard let screen else { return PanelMetrics.defaultMaxListHeight }
        let chrome: CGFloat = 120
        let available = menuBarBottom - screen.visibleFrame.minY - chrome - 24
        return max(140, min(PanelMetrics.defaultMaxListHeight, available))
    }

    private func rebuildRootView(maxListHeight: CGFloat) {
        host.rootView = PanelRoot(
            store: store,
            maxListHeight: maxListHeight,
            cornerRadius: cornerRadius,
            onOpenSettings: { [weak self] in self?.showSettingsFromPanel() },
            onQuit: { NSApp.terminate(nil) }
        )
    }

    // MARK: - Dismissal

    private func installMonitors() {
        removeMonitors()
        globalMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        ) { [weak self] _ in
            let location = NSEvent.mouseLocation
            Task { @MainActor [weak self] in
                guard let self, !self.statusItemFrame().contains(location) else { return }
                self.closePanel()
            }
        }
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { [weak self] event in
            guard event.keyCode == 53 else { return event }  // Escape
            Task { @MainActor [weak self] in self?.closePanel() }
            return nil
        }
        resignObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didResignActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in self?.closePanel() }
        }
    }

    private func removeMonitors() {
        if let globalMonitor { NSEvent.removeMonitor(globalMonitor) }
        if let localMonitor { NSEvent.removeMonitor(localMonitor) }
        if let resignObserver { NotificationCenter.default.removeObserver(resignObserver) }
        globalMonitor = nil
        localMonitor = nil
        resignObserver = nil
    }

    // MARK: - Settings

    private func showSettingsFromPanel() {
        closePanel()
        showSettings()
    }

    @objc func showSettings() {
        let window: NSWindow
        if let existing = settingsWindow {
            window = existing
        } else {
            window = NSWindow(contentViewController: NSHostingController(rootView: SettingsView(store: store)))
            window.title = "Still Settings"
            window.styleMask = [.titled, .closable, .miniaturizable]
            window.isReleasedWhenClosed = false
            window.center()
            settingsWindow = window
        }
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }
}

