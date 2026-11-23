import SwiftUI
import AppKit
import Combine

/// Plain AppKit entry point. (A SwiftUI `App` needs at least one scene, and on recent macOS versions
/// an empty `Settings` scene pops up as an empty "AirMonitor Settings" window at launch.)
@main
enum AirMonitorMain {
    static func main() {
        MainActor.assumeIsolated {
            let app = NSApplication.shared
            let delegate = AppDelegate()
            withExtendedLifetime(delegate) {
                app.delegate = delegate
                app.setActivationPolicy(.accessory)
                app.run()
            }
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private var statusItem: NSStatusItem!
    private var store: AirStore!
    private var popover: NSPopover!
    private var settingsWindow: NSWindow?
    private var mapModel: SensorMapModel?
    private var cancellables = Set<AnyCancellable>()

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        NSApp.applicationIconImage = AppIcon.make()
        buildMainMenu()

        let store = AirStore()
        self.store = store

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            button.target = self
            button.action = #selector(statusItemClicked(_:))
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
            button.imagePosition = .imageLeading
        }

        let popoverView = PopoverView(store: store, openSettings: { [weak self] in self?.openSettings() })
        let hosting = NSHostingController(rootView: popoverView)
        hosting.sizingOptions = [.preferredContentSize]
        popover = NSPopover()
        popover.contentViewController = hosting
        popover.behavior = .transient
        popover.animates = true

        // Any change in the store → update the menu bar text and icon.
        store.objectWillChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.updateStatusItem() }
            .store(in: &cancellables)

        updateStatusItem()
        store.start()

        // First launch (no sensor picked yet): open Settings so a sensor can be chosen on the map.
        if store.hasNoSources {
            Task {
                try? await Task.sleep(nanoseconds: 500_000_000)
                self.openSettings()
            }
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    // MARK: Clicking the menu bar icon

    @objc private func statusItemClicked(_ sender: NSStatusBarButton) {
        if NSApp.currentEvent?.type == .rightMouseUp {
            showContextMenu()
        } else {
            togglePopover(sender)
        }
    }

    private func togglePopover(_ sender: NSStatusBarButton) {
        if popover.isShown {
            popover.performClose(sender)
        } else {
            popover.show(relativeTo: sender.bounds, of: sender, preferredEdge: .minY)
            activateApp()
            popover.contentViewController?.view.window?.makeKey()
            store.refreshIfOlder(than: 60)
        }
    }

    private func showContextMenu() {
        let menu = NSMenu()
        menu.addItem(withTitle: "Refresh Now", action: #selector(refreshNow), keyEquivalent: "r").target = self
        menu.addItem(withTitle: "Settings…", action: #selector(openSettingsFromMenu), keyEquivalent: ",").target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit AirMonitor", action: #selector(quit), keyEquivalent: "q").target = self
        statusItem.menu = menu
        statusItem.button?.performClick(nil)
        statusItem.menu = nil
    }

    @objc private func refreshNow() {
        Task { await store.refresh() }
    }

    @objc private func openSettingsFromMenu() {
        openSettings()
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }

    /// Standard menus, visible while the Settings window is open (needed for ⌘C / ⌘V / ⌘W …).
    private func buildMainMenu() {
        let mainMenu = NSMenu()

        let appMenu = NSMenu(title: "AirMonitor")
        appMenu.addItem(withTitle: "About AirMonitor",
                        action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Settings…", action: #selector(openSettingsFromMenu), keyEquivalent: ",").target = self
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Hide AirMonitor", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appMenu.addItem(withTitle: "Quit AirMonitor", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        let appItem = NSMenuItem()
        appItem.submenu = appMenu
        mainMenu.addItem(appItem)

        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        editMenu.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "z")
            .keyEquivalentModifierMask = [.command, .shift]
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        let editItem = NSMenuItem()
        editItem.submenu = editMenu
        mainMenu.addItem(editItem)

        let windowMenu = NSMenu(title: "Window")
        windowMenu.addItem(withTitle: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        windowMenu.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        let windowItem = NSMenuItem()
        windowItem.submenu = windowMenu
        mainMenu.addItem(windowItem)

        NSApp.mainMenu = mainMenu
        NSApp.windowsMenu = windowMenu
    }

    private func activateApp() {
        if #available(macOS 14.0, *) { NSApp.activate() } else { NSApp.activate(ignoringOtherApps: true) }
    }

    // MARK: Settings window

    func openSettings() {
        if popover.isShown { popover.performClose(nil) }

        if settingsWindow == nil {
            let model = SensorMapModel(store: store)
            mapModel = model
            let hosting = NSHostingController(rootView: SettingsView(store: store, map: model))
            hosting.sizingOptions = [.minSize]
            let window = NSWindow(contentViewController: hosting)
            window.title = "AirMonitor Settings"
            window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
            window.setContentSize(NSSize(width: 1000, height: 660))
            window.isReleasedWhenClosed = false
            window.delegate = self
            window.center()
            settingsWindow = window
        }
        mapModel?.prepare()

        // While the window is open the app behaves like a normal app (Dock icon, menus, ⌘C/⌘V).
        NSApp.setActivationPolicy(.regular)
        activateApp()
        settingsWindow?.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        guard (notification.object as? NSWindow) === settingsWindow else { return }
        NSApp.setActivationPolicy(.accessory)
    }

    // MARK: Menu bar appearance

    private func updateStatusItem() {
        guard let button = statusItem?.button, let store = self.store else { return }
        let color: NSColor = store.isStale ? .systemGray : (store.level?.color ?? .systemGray)

        switch store.iconStyle {
        case .symbol:
            button.image = StatusIcon.symbol(named: store.level?.symbolName ?? "aqi.medium", color: color)
                ?? StatusIcon.dot(color: color)
        case .dot:
            button.image = StatusIcon.dot(color: color)
        }

        let text = store.menuBarText
        button.title = text.isEmpty ? "" : " " + text
        button.imagePosition = text.isEmpty ? .imageOnly : .imageLeading
        button.toolTip = store.tooltip
    }
}

/// Colored menu bar icons (isTemplate = false, so macOS doesn't turn them black and white).
enum StatusIcon {
    static func symbol(named name: String, color: NSColor) -> NSImage? {
        let config = NSImage.SymbolConfiguration(pointSize: 14, weight: .semibold)
            .applying(NSImage.SymbolConfiguration(paletteColors: [color]))
        guard let base = NSImage(systemSymbolName: name, accessibilityDescription: "Air quality"),
              let image = base.withSymbolConfiguration(config) else { return nil }
        image.isTemplate = false
        return image
    }

    static func dot(color: NSColor, diameter: CGFloat = 11) -> NSImage {
        let size = NSSize(width: diameter + 2, height: diameter + 2)
        let image = NSImage(size: size, flipped: false) { rect in
            let path = NSBezierPath(ovalIn: rect.insetBy(dx: 1, dy: 1))
            color.setFill()
            path.fill()
            NSColor.black.withAlphaComponent(0.3).setStroke()
            path.lineWidth = 0.8
            path.stroke()
            return true
        }
        image.isTemplate = false
        return image
    }
}

/// App icon drawn in code (shown in the Dock while the Settings window is open).
enum AppIcon {
    static func make(size: CGFloat = 512) -> NSImage {
        NSImage(size: NSSize(width: size, height: size), flipped: false) { rect in
            let tile = rect.insetBy(dx: size * 0.1, dy: size * 0.1)
            let path = NSBezierPath(roundedRect: tile, xRadius: size * 0.18, yRadius: size * 0.18)
            NSGradient(colors: [AirQuality.hex(0x2E86DE), AirQuality.hex(0x50CCAA)])?.draw(in: path, angle: 90)

            let config = NSImage.SymbolConfiguration(pointSize: size * 0.36, weight: .semibold)
                .applying(NSImage.SymbolConfiguration(paletteColors: [.white]))
            if let symbol = NSImage(systemSymbolName: "aqi.medium", accessibilityDescription: nil)?
                .withSymbolConfiguration(config) {
                let s = symbol.size
                symbol.draw(in: NSRect(x: rect.midX - s.width / 2, y: rect.midY - s.height / 2,
                                       width: s.width, height: s.height))
            }
            return true
        }
    }
}
