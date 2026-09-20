import AppKit
import SwiftUI

@MainActor
final class IslandController {
    private let panel: NSPanel
    private let state: IslandState
    private let presentation = NotchPresentation()
    private var localEventMonitor: Any?
    private var globalEventMonitor: Any?
    private var desktopLyricsObserver: NSObjectProtocol?
    private var refreshTimer: Timer?
    private var pointerTimer: Timer?
    private var refreshInterval: TimeInterval?
    private var pointerInterval: TimeInterval?
    private var collapseTask: Task<Void, Never>?
    private var wasPointerInside = false

    init(state: IslandState) {
        self.state = state
        panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: presentation.panelSize),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.acceptsMouseMovedEvents = true
        panel.animationBehavior = .none
        panel.ignoresMouseEvents = true
        panel.contentView = NSHostingView(rootView: NotchIslandView(
            state: state,
            presentation: presentation,
            showFull: { [weak self] in self?.expandFully() },
            collapse: { [weak self] in self?.collapse() }
        ))

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(screenParametersChanged),
            name: NSApplication.didChangeScreenParametersNotification,
            object: nil
        )
        showCompactPanel()
        state.onMusicRefreshPolicyChanged = { [weak self] in
            self?.updateRefreshSchedule()
        }
        desktopLyricsObserver = NotificationCenter.default.addObserver(
            forName: AppSettings.desktopLyricsDidChange,
            object: state.settings,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.updateRefreshSchedule() }
        }
        state.refreshMusic()
        updateRefreshSchedule()
        updatePointerTracking()
        // During an app's very first launch NSScreen can briefly be unavailable
        // while the menu-bar-only app finishes activation. Retry once on the
        // next run-loop window so the welcome island reliably opens by itself.
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(180))
            self?.presentFirstLaunchWelcomeIfNeeded()
        }
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    private func presentFirstLaunchWelcomeIfNeeded() {
        guard state.settings.showsWelcome else { return }
        expandFully()
    }

    func toggle() {
        presentation.phase == .expanded ? collapse() : expandFully()
    }

    private func expandFully() {
        collapseTask?.cancel()
        guard presentation.phase != .expanded, let screen = activeScreen else { return }
        updateNotchGeometry(from: screen)
        positionPanel(on: screen)
        state.refreshAuthorizedServices()
        presentation.phase = .expanded
        panel.orderFrontRegardless()
        installDismissMonitors()
        updateRefreshSchedule()
        updatePointerTracking()
    }

    private func collapse() {
        collapseTask?.cancel()
        guard presentation.phase != .compact else { return }
        presentation.phase = .compact
        removeDismissMonitors()
        updateRefreshSchedule()
        updatePointerTracking()

    }

    private func hoverChanged(_ inside: Bool) {
        collapseTask?.cancel()
        if inside {
            guard presentation.phase == .compact, state.settings.expandsOnHover else { return }
            collapseTask = Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(80))
                guard !Task.isCancelled else { return }
                self?.expandFully()
            }
        } else if presentation.phase != .compact {
            collapseTask = Task { [weak self] in
                guard let self else { return }
                let delay = UInt64(self.state.settings.autoCollapseDelay * 1_000_000_000)
                try? await Task.sleep(nanoseconds: delay)
                guard !Task.isCancelled else { return }
                self.collapse()
            }
        }
    }

    private func showCompactPanel() {
        guard let screen = activeScreen else { return }
        updateNotchGeometry(from: screen)
        positionPanel(on: screen)
        panel.orderFrontRegardless()
    }

    @objc private func screenParametersChanged() {
        guard let screen = activeScreen else { return }
        updateNotchGeometry(from: screen)
        positionPanel(on: screen)
    }

    private var activeScreen: NSScreen? {
        let screens = NSScreen.screens
        return screens.first(where: {
            $0.auxiliaryTopLeftArea != nil && $0.auxiliaryTopRightArea != nil
        }) ?? NSScreen.main ?? screens.first
    }

    private func updateNotchGeometry(from screen: NSScreen) {
        if let left = screen.auxiliaryTopLeftArea, let right = screen.auxiliaryTopRightArea {
            presentation.notchWidth = max(120, right.minX - left.maxX)
            presentation.notchHeight = max(28, screen.frame.maxY - min(left.minY, right.minY))
            presentation.centerX = (left.maxX + right.minX) / 2
        } else {
            presentation.notchWidth = 164
            presentation.notchHeight = 32
            presentation.centerX = screen.frame.midX
        }
    }

    private func positionPanel(on screen: NSScreen) {
        let size = presentation.panelSize
        panel.setFrame(NSRect(
            x: presentation.centerX - size.width / 2,
            y: screen.frame.maxY - size.height,
            width: size.width,
            height: size.height
        ), display: true)
    }

    private func updatePointerTracking() {
        // The compact island only needs to detect entry into its small hover
        // target. Full-rate tracking is reserved for the interactive panel.
        let interval = presentation.phase == .expanded ? 1.0 / 60.0 : 1.0 / 12.0
        guard pointerInterval != interval else { return }
        pointerTimer?.invalidate()
        pointerInterval = interval
        pointerTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.updatePointerState() }
        }
        pointerTimer?.tolerance = interval * 0.25
    }

    private func updatePointerState() {
        guard panel.isVisible, let screen = activeScreen else {
            panel.ignoresMouseEvents = true
            wasPointerInside = false
            return
        }
        let inside = surfaceFrame(on: screen).contains(NSEvent.mouseLocation)
        panel.ignoresMouseEvents = !inside
        guard inside != wasPointerInside else { return }
        wasPointerInside = inside
        hoverChanged(inside)
    }

    private func surfaceFrame(on screen: NSScreen) -> NSRect {
        let size = presentation.surfaceSize
        return NSRect(
            x: presentation.centerX - size.width / 2,
            y: screen.frame.maxY - size.height,
            width: size.width,
            height: size.height
        )
    }

    private func updateRefreshSchedule() {
        let interval: TimeInterval
        if presentation.phase == .expanded || state.isPlaying || state.settings.showsDesktopLyrics {
            interval = 2
        } else if state.hasMusic {
            interval = 6
        } else {
            interval = 15
        }
        guard refreshInterval != interval else { return }
        refreshTimer?.invalidate()
        refreshInterval = interval
        refreshTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.state.refreshMusic()
                self?.state.refreshPower()
            }
        }
        refreshTimer?.tolerance = min(1, interval * 0.15)
    }

    private func installDismissMonitors() {
        removeDismissMonitors()
        localEventMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .keyDown]) { [weak self] event in
            if event.type == .keyDown, event.keyCode == 53 { self?.collapse() }
            return event
        }
        globalEventMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            Task { @MainActor in
                guard let self, let screen = self.activeScreen,
                      self.presentation.phase != .compact,
                      !self.surfaceFrame(on: screen).contains(NSEvent.mouseLocation) else { return }
                self.collapse()
            }
        }
    }

    private func removeDismissMonitors() {
        if let localEventMonitor { NSEvent.removeMonitor(localEventMonitor) }
        if let globalEventMonitor { NSEvent.removeMonitor(globalEventMonitor) }
        localEventMonitor = nil
        globalEventMonitor = nil
    }
}
