import ServiceManagement
import SwiftUI

enum MusicVisualizerStyle: String, CaseIterable, Identifiable {
    case spectrum
    case waveform
    case pulse
    case halo

    var id: String { rawValue }

    var title: String {
        switch self {
        case .spectrum: "频谱"
        case .waveform: "波形"
        case .pulse: "脉冲"
        case .halo: "唱片光晕"
        }
    }
}

enum DesktopLyricsTheme: String, CaseIterable, Identifiable {
    case white
    case violet
    case ocean
    case sunset

    var id: String { rawValue }

    var title: String {
        switch self {
        case .white: "月光"
        case .violet: "霓虹"
        case .ocean: "极光"
        case .sunset: "落日"
        }
    }
}

@MainActor
final class AppSettings: ObservableObject {
    static let islandLayoutDidChange = Notification.Name("Notchly.islandLayoutDidChange")
    static let desktopLyricsDidChange = Notification.Name("Notchly.desktopLyricsDidChange")
    static let desktopLyricsPositionReset = Notification.Name("Notchly.desktopLyricsPositionReset")
    static let wellnessRemindersDidChange = Notification.Name("Notchly.wellnessRemindersDidChange")
    @Published private(set) var launchesAtLogin: Bool
    @Published private(set) var launchAtLoginMessage: String?
    @Published var showsPomodoro: Bool { didSet { saveCardPreferences() } }
    @Published var showsCalendar: Bool { didSet { saveCardPreferences() } }
    @Published var showsPower: Bool { didSet { saveCardPreferences() } }
    @Published var showsWelcome: Bool { didSet { UserDefaults.standard.set(!showsWelcome, forKey: Self.welcomeSeenKey) } }
    @Published var expandsOnHover: Bool {
        didSet { UserDefaults.standard.set(expandsOnHover, forKey: "interaction.hoverPreview") }
    }
    @Published var autoCollapseDelay: Double {
        didSet { UserDefaults.standard.set(autoCollapseDelay, forKey: "interaction.collapseDelay") }
    }
    @Published var musicVisualizerStyle: MusicVisualizerStyle {
        didSet { UserDefaults.standard.set(musicVisualizerStyle.rawValue, forKey: "music.visualizer") }
    }
    @Published var lyricOffset: Double {
        didSet { UserDefaults.standard.set(lyricOffset, forKey: "music.lyricOffset") }
    }
    @Published var showsDesktopLyrics: Bool {
        didSet {
            UserDefaults.standard.set(showsDesktopLyrics, forKey: "music.desktopLyrics")
            NotificationCenter.default.post(name: Self.desktopLyricsDidChange, object: self)
        }
    }
    @Published var desktopLyricsShowsNextLine: Bool { didSet { saveDesktopLyricsPreferences() } }
    @Published var desktopLyricsKaraokeEnabled: Bool { didSet { saveDesktopLyricsPreferences() } }
    @Published var desktopLyricsFontSize: Double { didSet { saveDesktopLyricsPreferences() } }
    @Published var desktopLyricsBackgroundOpacity: Double { didSet { saveDesktopLyricsPreferences() } }
    @Published var desktopLyricsLocked: Bool { didSet { saveDesktopLyricsPreferences() } }
    @Published var desktopLyricsTheme: DesktopLyricsTheme { didSet { saveDesktopLyricsPreferences() } }
    @Published var focusMinutes: Int { didSet { UserDefaults.standard.set(focusMinutes, forKey: "pomodoro.focusMinutes") } }
    @Published var hydrationRemindersEnabled: Bool { didSet { saveWellnessPreferences() } }
    @Published var hydrationIntervalMinutes: Int { didSet { saveWellnessPreferences() } }
    @Published var standRemindersEnabled: Bool { didSet { saveWellnessPreferences() } }
    @Published var standIntervalMinutes: Int { didSet { saveWellnessPreferences() } }
    @Published var pocketRetentionDays: Int { didSet { UserDefaults.standard.set(pocketRetentionDays, forKey: "pocket.retentionDays") } }
    @Published var pocketCapacityMB: Int { didSet { UserDefaults.standard.set(pocketCapacityMB, forKey: "pocket.capacityMB") } }

    private static let welcomeSeenKey = "welcome.seen"

    init() {
        launchesAtLogin = SMAppService.mainApp.status == .enabled
        let defaults = UserDefaults.standard
        showsPomodoro = defaults.object(forKey: "cards.pomodoro") as? Bool ?? true
        showsCalendar = defaults.object(forKey: "cards.calendar") as? Bool ?? true
        showsPower = defaults.object(forKey: "cards.power") as? Bool ?? true
        showsWelcome = !defaults.bool(forKey: Self.welcomeSeenKey)
        expandsOnHover = defaults.object(forKey: "interaction.hoverPreview") as? Bool ?? true
        autoCollapseDelay = min(max(defaults.object(forKey: "interaction.collapseDelay") as? Double ?? 0.65, 0.3), 2.0)
        musicVisualizerStyle = MusicVisualizerStyle(
            rawValue: defaults.string(forKey: "music.visualizer") ?? ""
        ) ?? .spectrum
        lyricOffset = min(max(defaults.object(forKey: "music.lyricOffset") as? Double ?? 0, -3), 3)
        showsDesktopLyrics = defaults.object(forKey: "music.desktopLyrics") as? Bool ?? false
        desktopLyricsShowsNextLine = defaults.object(forKey: "desktopLyrics.nextLine") as? Bool ?? true
        desktopLyricsKaraokeEnabled = defaults.object(forKey: "desktopLyrics.karaokeFill") as? Bool ?? true
        desktopLyricsFontSize = min(max(defaults.object(forKey: "desktopLyrics.fontSize") as? Double ?? 24, 18), 38)
        desktopLyricsBackgroundOpacity = min(max(defaults.object(forKey: "desktopLyrics.backgroundOpacity") as? Double ?? 0.58, 0), 0.85)
        desktopLyricsLocked = defaults.object(forKey: "desktopLyrics.locked") as? Bool ?? false
        desktopLyricsTheme = DesktopLyricsTheme(rawValue: defaults.string(forKey: "desktopLyrics.theme") ?? "") ?? .white
        focusMinutes = min(max(defaults.object(forKey: "pomodoro.focusMinutes") as? Int ?? 25, 5), 120)
        hydrationRemindersEnabled = defaults.bool(forKey: "wellness.hydration.enabled")
        hydrationIntervalMinutes = min(max(defaults.object(forKey: "wellness.hydration.minutes") as? Int ?? 60, 30), 180)
        standRemindersEnabled = defaults.bool(forKey: "wellness.stand.enabled")
        standIntervalMinutes = min(max(defaults.object(forKey: "wellness.stand.minutes") as? Int ?? 45, 30), 180)
        pocketRetentionDays = min(max(defaults.object(forKey: "pocket.retentionDays") as? Int ?? 7, 1), 30)
        pocketCapacityMB = min(max(defaults.object(forKey: "pocket.capacityMB") as? Int ?? 512, 128), 2_048)
    }

    func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
                launchAtLoginMessage = "Notchly 将在登录后自动启动。"
            } else {
                try SMAppService.mainApp.unregister()
                launchAtLoginMessage = "已关闭登录时自动启动。"
            }
            launchesAtLogin = enabled
        } catch {
            launchesAtLogin = SMAppService.mainApp.status == .enabled
            launchAtLoginMessage = "无法更新登录启动设置，请在系统设置中检查“登录项”。"
        }
    }

    func dismissWelcome() {
        showsWelcome = false
        NotificationCenter.default.post(name: Self.islandLayoutDidChange, object: self)
    }

    func resetDesktopLyricsPosition() {
        UserDefaults.standard.removeObject(forKey: "desktopLyrics.originX")
        UserDefaults.standard.removeObject(forKey: "desktopLyrics.originY")
        NotificationCenter.default.post(name: Self.desktopLyricsPositionReset, object: self)
    }

    private func saveDesktopLyricsPreferences() {
        let defaults = UserDefaults.standard
        defaults.set(desktopLyricsShowsNextLine, forKey: "desktopLyrics.nextLine")
        defaults.set(desktopLyricsKaraokeEnabled, forKey: "desktopLyrics.karaokeFill")
        defaults.set(desktopLyricsFontSize, forKey: "desktopLyrics.fontSize")
        defaults.set(desktopLyricsBackgroundOpacity, forKey: "desktopLyrics.backgroundOpacity")
        defaults.set(desktopLyricsLocked, forKey: "desktopLyrics.locked")
        defaults.set(desktopLyricsTheme.rawValue, forKey: "desktopLyrics.theme")
        NotificationCenter.default.post(name: Self.desktopLyricsDidChange, object: self)
    }

    private func saveCardPreferences() {
        let defaults = UserDefaults.standard
        defaults.set(showsPomodoro, forKey: "cards.pomodoro")
        defaults.set(showsCalendar, forKey: "cards.calendar")
        defaults.set(showsPower, forKey: "cards.power")
    }

    private func saveWellnessPreferences() {
        let defaults = UserDefaults.standard
        defaults.set(hydrationRemindersEnabled, forKey: "wellness.hydration.enabled")
        defaults.set(hydrationIntervalMinutes, forKey: "wellness.hydration.minutes")
        defaults.set(standRemindersEnabled, forKey: "wellness.stand.enabled")
        defaults.set(standIntervalMinutes, forKey: "wellness.stand.minutes")
        NotificationCenter.default.post(name: Self.wellnessRemindersDidChange, object: self)
    }
}
