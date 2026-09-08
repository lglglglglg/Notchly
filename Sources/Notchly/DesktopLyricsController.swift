import AppKit
import SwiftUI

@MainActor
private final class DesktopLyricsPresentation: ObservableObject {
    @Published var isHovering = false
}

@MainActor
final class DesktopLyricsController: NSObject, NSWindowDelegate {
    private let panel: NSPanel
    private let state: IslandState
    private let presentation = DesktopLyricsPresentation()
    private var settingsObserver: NSObjectProtocol?
    private var positionResetObserver: NSObjectProtocol?
    private var pointerTimer: Timer?
    private var isRestoringPosition = false

    init(state: IslandState) {
        self.state = state
        panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 700, height: 84),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        super.init()

        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.hidesOnDeactivate = false
        panel.acceptsMouseMovedEvents = true
        panel.becomesKeyOnlyIfNeeded = true
        panel.delegate = self
        panel.contentView = NSHostingView(rootView: DesktopLyricsView(state: state, presentation: presentation))

        settingsObserver = NotificationCenter.default.addObserver(
            forName: AppSettings.desktopLyricsDidChange,
            object: state.settings,
            queue: .main
        ) { [weak self, weak state] _ in
            Task { @MainActor in
                guard let self, let state else { return }
                self.applySettings(state.settings)
            }
        }
        positionResetObserver = NotificationCenter.default.addObserver(
            forName: AppSettings.desktopLyricsPositionReset,
            object: state.settings,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.moveToDefaultPosition() }
        }

        applySettings(state.settings)
        restorePositionOrUseDefault()
        pointerTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.updatePointerState() }
        }
        pointerTimer?.tolerance = 1.0 / 60.0
    }

    private func applySettings(_ settings: AppSettings) {
        let height: CGFloat = settings.desktopLyricsShowsNextLine
            ? max(96, settings.desktopLyricsFontSize * 1.55 + 38)
            : max(72, settings.desktopLyricsFontSize + 38)
        let oldCenter = panel.frame.center
        panel.setContentSize(NSSize(width: 700, height: height))
        panel.setFrameOrigin(NSPoint(x: oldCenter.x - 350, y: oldCenter.y - height / 2))
        panel.isMovableByWindowBackground = !settings.desktopLyricsLocked
        panel.ignoresMouseEvents = settings.desktopLyricsLocked

        if settings.showsDesktopLyrics {
            panel.orderFrontRegardless()
        } else {
            panel.orderOut(nil)
        }
    }

    private var preferredScreen: NSScreen? {
        NSScreen.screens.first(where: {
            $0.auxiliaryTopLeftArea != nil && $0.auxiliaryTopRightArea != nil
        }) ?? NSScreen.main ?? NSScreen.screens.first
    }

    private func restorePositionOrUseDefault() {
        let defaults = UserDefaults.standard
        guard let x = defaults.object(forKey: "desktopLyrics.originX") as? Double,
              let y = defaults.object(forKey: "desktopLyrics.originY") as? Double else {
            moveToDefaultPosition()
            return
        }
        let origin = NSPoint(x: x, y: y)
        let candidate = NSRect(origin: origin, size: panel.frame.size)
        guard NSScreen.screens.contains(where: { $0.frame.intersects(candidate) }) else {
            moveToDefaultPosition()
            return
        }
        isRestoringPosition = true
        panel.setFrameOrigin(origin)
        isRestoringPosition = false
    }

    private func moveToDefaultPosition() {
        guard let screen = preferredScreen else { return }
        isRestoringPosition = true
        panel.setFrameOrigin(NSPoint(
            x: screen.frame.midX - panel.frame.width / 2,
            y: screen.visibleFrame.minY + 105
        ))
        isRestoringPosition = false
        savePosition()
    }

    func windowDidMove(_ notification: Notification) {
        guard !isRestoringPosition else { return }
        savePosition()
    }

    private func savePosition() {
        let origin = panel.frame.origin
        UserDefaults.standard.set(origin.x, forKey: "desktopLyrics.originX")
        UserDefaults.standard.set(origin.y, forKey: "desktopLyrics.originY")
    }

    private func updatePointerState() {
        guard panel.isVisible else {
            panel.ignoresMouseEvents = true
            if presentation.isHovering { presentation.isHovering = false }
            return
        }

        let pointer = NSEvent.mouseLocation
        let hovering: Bool
        if state.settings.desktopLyricsLocked {
            // Keep the lyrics click-through while locked, except for the small
            // bottom-right unlock badge. The timer can still observe the global
            // pointer and temporarily make that single hotspot interactive.
            let unlockHotspot = NSRect(
                x: panel.frame.maxX - 54,
                y: panel.frame.minY,
                width: 54,
                height: 48
            )
            hovering = unlockHotspot.contains(pointer)
            panel.ignoresMouseEvents = !hovering
        } else {
            hovering = panel.frame.contains(pointer)
            panel.ignoresMouseEvents = false
        }
        if presentation.isHovering != hovering { presentation.isHovering = hovering }
    }
}

private extension NSRect {
    var center: NSPoint { NSPoint(x: midX, y: midY) }
}

private struct DesktopLyricsView: View {
    @ObservedObject var state: IslandState
    @ObservedObject private var settings: AppSettings
    @ObservedObject private var presentation: DesktopLyricsPresentation

    init(state: IslandState, presentation: DesktopLyricsPresentation) {
        self.state = state
        settings = state.settings
        self.presentation = presentation
    }

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(backgroundGradient)

            VStack(spacing: 2) {
                TimelineView(.animation(minimumInterval: 1.0 / 60.0, paused: !state.isPlaying)) { context in
                    KaraokeLyricText(
                        text: desktopPrimaryText,
                        fontSize: settings.desktopLyricsFontSize,
                        progress: state.lyricProgress(at: context.date),
                        isEnabled: settings.desktopLyricsKaraokeEnabled && !state.currentLyricText.isEmpty,
                        colors: activeColors
                    )
                }
                    .frame(
                        maxWidth: .infinity,
                        alignment: settings.desktopLyricsShowsNextLine ? .leading : .center
                    )
                    .id(state.currentLyricText)
                    .transition(.opacity.combined(with: .move(edge: .bottom)))

                if settings.desktopLyricsShowsNextLine, !state.nextLyricText.isEmpty {
                    Text(state.nextLyricText)
                        .font(.system(size: max(13, settings.desktopLyricsFontSize * 0.60), weight: .medium, design: .rounded))
                        .foregroundStyle(.white.opacity(0.42))
                        .lineLimit(1)
                        .minimumScaleFactor(0.72)
                        .shadow(color: .black.opacity(0.6), radius: 2, y: 1)
                        .frame(maxWidth: .infinity, alignment: .trailing)
                }
            }
            .padding(.horizontal, 26)
            .padding(.top, 7)
            .padding(.bottom, 30)

            if presentation.isHovering, !settings.desktopLyricsLocked {
                HStack(spacing: 8) {
                    hoverButton("backward.fill", help: "上一曲") { state.previousMusic() }
                    hoverButton(state.isPlaying ? "pause.fill" : "play.fill", help: state.isPlaying ? "暂停" : "播放") {
                        state.toggleMusic()
                    }
                    hoverButton("forward.fill", help: "下一曲") { state.nextMusic() }
                    Divider().frame(height: 14)
                    hoverButton("lock.open", help: "锁定并允许鼠标穿透") {
                        settings.desktopLyricsLocked = true
                    }
                    hoverButton("slider.horizontal.3", help: "桌面歌词设置") {
                        NotificationCenter.default.post(name: .notchlyShowSettingsRequested, object: nil)
                    }
                }
                .font(.caption.weight(.semibold))
                .foregroundStyle(.white.opacity(0.9))
                .padding(.horizontal, 9)
                .padding(.vertical, 5)
                .background(.black.opacity(0.70), in: Capsule())
                .overlay { Capsule().stroke(.white.opacity(0.12), lineWidth: 0.7) }
                .frame(maxHeight: .infinity, alignment: .bottom)
                .padding(.bottom, 6)
                .transition(.opacity.combined(with: .scale(scale: 0.94, anchor: .bottom)))
            }

            if settings.desktopLyricsLocked {
                Button {
                    settings.desktopLyricsLocked = false
                } label: {
                    Image(systemName: presentation.isHovering ? "lock.open.fill" : "lock.fill")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.white.opacity(presentation.isHovering ? 0.95 : 0.52))
                        .frame(width: 32, height: 26)
                        .background(.black.opacity(presentation.isHovering ? 0.78 : 0.42), in: Capsule())
                        .overlay { Capsule().stroke(.white.opacity(presentation.isHovering ? 0.18 : 0.08), lineWidth: 0.7) }
                }
                .buttonStyle(.plain)
                .help("解锁桌面歌词")
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                .padding(.trailing, 9)
                .padding(.bottom, 7)
            }

            if presentation.isHovering, !settings.desktopLyricsLocked {
                Capsule()
                    .fill(.white.opacity(0.30))
                    .frame(width: 30, height: 3)
                    .frame(maxHeight: .infinity, alignment: .top)
                    .padding(.top, 5)
            }
        }
        .overlay {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(accentColor.opacity(presentation.isHovering ? 0.30 : 0.10), lineWidth: 0.8)
        }
        .contentShape(Rectangle())
        .animation(.smooth(duration: 0.20), value: presentation.isHovering)
        .animation(.smooth(duration: 0.20), value: settings.desktopLyricsLocked)
        .animation(.easeInOut(duration: 0.24), value: state.currentLyricText)
    }

    private func hoverButton(_ symbol: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .frame(width: 22, height: 20)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help(help)
    }

    private var accentColor: Color {
        switch settings.desktopLyricsTheme {
        case .white: .white
        case .violet: .purple
        case .ocean: .cyan
        case .sunset: .pink
        }
    }

    private var activeColors: [Color] {
        switch settings.desktopLyricsTheme {
        case .white: [.white, Color(nsColor: .lightGray)]
        case .violet: [.pink, .purple, .cyan]
        case .ocean: [.mint, .cyan, .blue]
        case .sunset: [.yellow, .orange, .pink]
        }
    }

    private var backgroundGradient: LinearGradient {
        LinearGradient(
            colors: [
                .black.opacity(settings.desktopLyricsBackgroundOpacity),
                backgroundTint.opacity(settings.desktopLyricsBackgroundOpacity)
            ],
            startPoint: .leading,
            endPoint: .trailing
        )
    }

    private var backgroundTint: Color {
        switch settings.desktopLyricsTheme {
        case .white: .black
        case .violet: .indigo
        case .ocean: .blue
        case .sunset: .purple
        }
    }

    private var desktopPrimaryText: String {
        if !state.currentLyricText.isEmpty { return state.currentLyricText }
        if state.isLyricInterlude { return "♪" }
        if state.hasMusic { return state.musicTitle }
        return "播放音乐后显示歌词"
    }
}

private struct KaraokeLyricText: View {
    let text: String
    let fontSize: Double
    let progress: Double
    let isEnabled: Bool
    let colors: [Color]

    var body: some View {
        ZStack {
            lyric
                .foregroundStyle(.white.opacity(isEnabled ? 0.28 : 0.94))

            if isEnabled {
                lyric
                    .foregroundStyle(LinearGradient(colors: colors, startPoint: .leading, endPoint: .trailing))
                    .mask {
                        GeometryReader { proxy in
                            Rectangle()
                                .frame(width: proxy.size.width * min(max(progress, 0), 1))
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
            }
        }
        .shadow(color: .black.opacity(0.72), radius: 3, y: 1)
    }

    private var lyric: some View {
        Text(text)
            .font(.system(size: fontSize, weight: .bold, design: .rounded))
            .lineLimit(1)
            .minimumScaleFactor(0.68)
    }
}
