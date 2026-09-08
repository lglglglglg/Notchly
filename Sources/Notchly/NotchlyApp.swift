import AppKit
import Carbon.HIToolbox
import SwiftUI

extension Notification.Name {
    static let notchlyShowSettingsRequested = Notification.Name("Notchly.showSettingsRequested")
    static let notchlyQuitRequested = Notification.Name("Notchly.quitRequested")
}

@main
struct NotchlyApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        Settings {
            SettingsView(settings: appDelegate.settings)
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let settings = AppSettings()
    private lazy var state = IslandState(settings: settings)
    private var islandController: IslandController?
    private var desktopLyricsController: DesktopLyricsController?
    private var statusItem: NSStatusItem?
    private var statusMenu: NSMenu?
    private var hotKey: HotKeyRegistrar?
    private var settingsWindowController: NSWindowController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        terminateOlderInstances()
        islandController = IslandController(state: state)
        desktopLyricsController = DesktopLyricsController(state: state)
        configureMenuBar()
        installKeyboardShortcut()
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleShowSettingsRequest(_:)),
            name: .notchlyShowSettingsRequested,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleWellnessSettingsChanged(_:)),
            name: AppSettings.wellnessRemindersDidChange,
            object: settings
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleQuitRequest(_:)),
            name: .notchlyQuitRequested,
            object: nil
        )
        state.syncWellnessReminders()
        NSApp.setActivationPolicy(.accessory)
    }

    /// Keep a single status-bar owner even when another build of Notchly is opened.
    /// The newly launched build stays alive and asks older instances to quit.
    private func terminateOlderInstances() {
        guard let bundleIdentifier = Bundle.main.bundleIdentifier else { return }
        let currentPID = ProcessInfo.processInfo.processIdentifier
        for application in NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier)
        where application.processIdentifier != currentPID {
            application.terminate()
        }
    }

    private func configureMenuBar() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.isVisible = true
        item.button?.image = makeStatusBarIcon()
        item.button?.action = #selector(statusItemClicked)
        item.button?.target = self
        item.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
        item.button?.toolTip = "Notchly — ⌘⇧Space"
        statusItem = item

        // The island is itself a status-bar-level panel. When the menu bar is
        // crowded, macOS may place this item directly beneath that panel.
        // Keep Notchly's own escape hatch one level above the island so it can
        // always be clicked to show the quit menu.
        DispatchQueue.main.async {
            item.button?.window?.level = NSWindow.Level(
                rawValue: NSWindow.Level.statusBar.rawValue + 1
            )
        }

        let menu = NSMenu()
        menu.addItem(withTitle: "显示 / 隐藏 Notchly", action: #selector(toggleIsland), keyEquivalent: "")
        menu.addItem(withTitle: "设置…", action: #selector(showSettings), keyEquivalent: ",")
        menu.addItem(.separator())
        menu.addItem(withTitle: "退出 Notchly", action: #selector(quit), keyEquivalent: "q")
        menu.items.forEach { $0.target = self }
        statusMenu = menu
    }

    private func makeStatusBarIcon() -> NSImage {
        let size = NSSize(width: 21, height: 18)
        let image = NSImage(size: size, flipped: false) { _ in
            NSColor.black.setFill()

            // The compact Dynamic Island silhouette: one pill and one satellite dot.
            // Template rendering keeps it consistent with the other menu-bar icons.
            NSBezierPath(
                roundedRect: NSRect(x: 1, y: 6.25, width: 13, height: 5.5),
                xRadius: 2.75,
                yRadius: 2.75
            ).fill()
            NSBezierPath(ovalIn: NSRect(x: 16, y: 6.5, width: 5, height: 5)).fill()
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "Notchly"
        return image
    }

    private func installKeyboardShortcut() {
        let registrar = HotKeyRegistrar(keyCode: UInt32(kVK_Space), modifiers: UInt32(cmdKey | shiftKey)) { [weak self] in
            self?.toggleIsland()
        }
        do { try registrar.register(); hotKey = registrar }
        catch { NSLog("Notchly could not register its global shortcut: \(error)") }
    }

    @objc private func toggleIsland() {
        islandController?.toggle()
    }

    @objc private func statusItemClicked() {
        guard let button = statusItem?.button else { return }
        if NSApp.currentEvent?.type == .rightMouseUp, let statusMenu {
            statusMenu.popUp(positioning: nil, at: .zero, in: button)
        } else {
            toggleIsland()
        }
    }

    @objc func showSettings() {
        if settingsWindowController == nil {
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 640, height: 570),
                styleMask: [.titled, .closable, .miniaturizable],
                backing: .buffered,
                defer: false
            )
            window.title = "Notchly 设置"
            window.isReleasedWhenClosed = false
            window.tabbingMode = .disallowed
            window.collectionBehavior = [.moveToActiveSpace]
            window.contentView = NSHostingView(rootView: SettingsView(settings: settings))
            window.center()
            settingsWindowController = NSWindowController(window: window)
        }
        NSApp.activate(ignoringOtherApps: true)
        settingsWindowController?.showWindow(nil)
        settingsWindowController?.window?.makeKeyAndOrderFront(nil)
    }

    @objc private func handleShowSettingsRequest(_ notification: Notification) {
        showSettings()
    }

    @objc private func handleWellnessSettingsChanged(_ notification: Notification) {
        state.syncWellnessReminders()
    }

    @objc private func handleQuitRequest(_ notification: Notification) {
        NSApp.terminate(nil)
    }

    @objc private func quit() { NSApp.terminate(nil) }
}
