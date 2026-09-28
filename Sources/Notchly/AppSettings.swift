import ServiceManagement
import SwiftUI

enum MusicVisualizerStyle: String, CaseIterable, Identifiable {
    case spectrum
    case waveform
    case pulse
    case cosmicDust

    var id: String { rawValue }

    var title: String {
        switch self {
        case .spectrum: "频谱"
        case .waveform: "波形"
        case .pulse: "脉冲"
        case .cosmicDust: "宇宙尘埃"
        }
    }

}

enum CompactDisplayMode: String, CaseIterable, Identifiable {
    case smart
    case lyrics
    case time
    case minimal

    var id: String { rawValue }

    var title: String {
        switch self {
        case .smart: "智能"
        case .lyrics: "歌词"
        case .time: "时间"
        case .minimal: "极简"
        }
    }

    var detail: String {
        switch self {
        case .smart: "专注计时优先，其次显示播放进度或问候"
        case .lyrics: "显示当前歌词，无歌词时使用简短状态"
        case .time: "显示当前时间，专注时显示剩余时间"
        case .minimal: "仅保留封面与播放状态符号"
        }
    }
}

enum IslandDisplayStrategy: String, CaseIterable, Identifiable {
    case builtInPreferred
    case primary
    case followsPointer

    var id: String { rawValue }

    var title: String {
        switch self {
        case .builtInPreferred: "内建屏"
        case .primary: "主屏"
        case .followsPointer: "随鼠标"
        }
    }

    var detail: String {
        switch self {
        case .builtInPreferred: "优先显示在带刘海的内建屏幕"
        case .primary: "固定显示在 macOS 主菜单栏所在屏幕"
        case .followsPointer: "鼠标跨屏后，收起岛移到鼠标所在屏幕"
        }
    }
}

enum IslandScenePreset: String, CaseIterable, Identifiable {
    case custom
    case work
    case music
    case presentation
    case powerSaving

    var id: String { rawValue }

    var title: String {
        switch self {
        case .custom: "自定义"
        case .work: "工作"
        case .music: "音乐"
        case .presentation: "演示"
        case .powerSaving: "省电"
        }
    }

    var detail: String {
        switch self {
        case .custom: "保留当前逐项设置，不主动改变界面或后台刷新策略。"
        case .work: "使用智能收起状态，保留全部效率卡片，并关闭桌面歌词。"
        case .music: "歌词优先，启用桌面歌词与完整音乐动效，保留全部卡片。"
        case .presentation: "关闭悬停展开和桌面歌词，全屏时隐藏，并使用极简收起状态。"
        case .powerSaving: "停止可选卡片轮询与装饰动效，降低媒体轮询频率并使用极简状态。"
        }
    }

    var configuration: IslandSceneConfiguration? {
        switch self {
        case .custom:
            nil
        case .work:
            IslandSceneConfiguration(
                compactDisplayMode: .smart,
                expandsOnHover: true,
                hidesIslandInFullScreen: true,
                musicVisualizerStyle: .spectrum,
                showsDesktopLyrics: false,
                enabledCards: IslandCardRegistry.defaultEnabledIDs.union([.reminders])
            )
        case .music:
            IslandSceneConfiguration(
                compactDisplayMode: .lyrics,
                expandsOnHover: true,
                hidesIslandInFullScreen: true,
                musicVisualizerStyle: .cosmicDust,
                showsDesktopLyrics: true,
                enabledCards: IslandCardRegistry.defaultEnabledIDs
            )
        case .presentation:
            IslandSceneConfiguration(
                compactDisplayMode: .minimal,
                expandsOnHover: false,
                hidesIslandInFullScreen: true,
                musicVisualizerStyle: .pulse,
                showsDesktopLyrics: false,
                enabledCards: []
            )
        case .powerSaving:
            IslandSceneConfiguration(
                compactDisplayMode: .minimal,
                expandsOnHover: true,
                hidesIslandInFullScreen: true,
                musicVisualizerStyle: .pulse,
                showsDesktopLyrics: false,
                enabledCards: []
            )
        }
    }
}

struct IslandSceneConfiguration: Equatable {
    let compactDisplayMode: CompactDisplayMode
    let expandsOnHover: Bool
    let hidesIslandInFullScreen: Bool
    let musicVisualizerStyle: MusicVisualizerStyle
    let showsDesktopLyrics: Bool
    let enabledCards: Set<IslandCardID>
}

enum LyricSyncPolicy {
    static func adjustedOffset(_ current: Double, by adjustment: Double) -> Double {
        min(max(current + adjustment, -3), 3)
    }
}

enum IslandAccentTheme: String, CaseIterable, Identifiable {
    case violet
    case ocean
    case sunset
    case forest

    var id: String { rawValue }

    var title: String {
        switch self {
        case .violet: "霓虹紫"
        case .ocean: "深海蓝"
        case .sunset: "日落橙"
        case .forest: "森林绿"
        }
    }

    var accent: Color {
        switch self {
        case .violet: .purple
        case .ocean: .cyan
        case .sunset: .orange
        case .forest: .green
        }
    }

    var highlight: Color {
        switch self {
        case .violet: .pink
        case .ocean: .mint
        case .sunset: .pink
        case .forest: .mint
        }
    }

    var artworkColors: [Color] {
        switch self {
        case .violet: [.indigo, .purple, .pink.opacity(0.82)]
        case .ocean: [.blue, .cyan, .mint.opacity(0.82)]
        case .sunset: [.red, .orange, .pink.opacity(0.82)]
        case .forest: [.teal, .green, .mint.opacity(0.82)]
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
    static let islandFullScreenBehaviorDidChange = Notification.Name("Notchly.islandFullScreenBehaviorDidChange")
    static let islandDisplayStrategyDidChange = Notification.Name("Notchly.islandDisplayStrategyDidChange")
    static let islandCardsDidChange = Notification.Name("Notchly.islandCardsDidChange")
    static let islandSceneDidChange = Notification.Name("Notchly.islandSceneDidChange")
    @Published private(set) var launchesAtLogin: Bool
    @Published private(set) var launchAtLoginMessage: String?
    @Published private(set) var enabledIslandCards: Set<IslandCardID>
    @Published private(set) var islandCardOrders: [IslandCardContext: [IslandCardID]]
    @Published private(set) var activeIslandScenePreset: IslandScenePreset
    @Published var showsWelcome: Bool { didSet { UserDefaults.standard.set(!showsWelcome, forKey: Self.welcomeSeenKey) } }
    @Published var expandsOnHover: Bool {
        didSet {
            UserDefaults.standard.set(expandsOnHover, forKey: "interaction.hoverPreview")
            markIslandSceneCustomized()
        }
    }
    @Published var autoCollapseDelay: Double {
        didSet { UserDefaults.standard.set(autoCollapseDelay, forKey: "interaction.collapseDelay") }
    }
    @Published var hidesIslandInFullScreen: Bool {
        didSet {
            UserDefaults.standard.set(hidesIslandInFullScreen, forKey: "interaction.hideInFullScreen")
            markIslandSceneCustomized()
            NotificationCenter.default.post(name: Self.islandFullScreenBehaviorDidChange, object: self)
        }
    }
    @Published var compactDisplayMode: CompactDisplayMode {
        didSet {
            UserDefaults.standard.set(compactDisplayMode.rawValue, forKey: "island.compactDisplayMode")
            markIslandSceneCustomized()
        }
    }
    @Published var islandDisplayStrategy: IslandDisplayStrategy {
        didSet {
            UserDefaults.standard.set(islandDisplayStrategy.rawValue, forKey: "island.displayStrategy")
            NotificationCenter.default.post(name: Self.islandDisplayStrategyDidChange, object: self)
        }
    }
    @Published var musicVisualizerStyle: MusicVisualizerStyle {
        didSet {
            UserDefaults.standard.set(musicVisualizerStyle.rawValue, forKey: "music.visualizer")
            markIslandSceneCustomized()
        }
    }
    @Published var islandAccentTheme: IslandAccentTheme {
        didSet { UserDefaults.standard.set(islandAccentTheme.rawValue, forKey: "island.accentTheme") }
    }
    @Published var lyricOffset: Double {
        didSet { UserDefaults.standard.set(lyricOffset, forKey: "music.lyricOffset") }
    }
    @Published var showsTranslatedLyrics: Bool {
        didSet {
            UserDefaults.standard.set(showsTranslatedLyrics, forKey: "music.translatedLyrics")
            NotificationCenter.default.post(name: Self.desktopLyricsDidChange, object: self)
        }
    }
    @Published var showsDesktopLyrics: Bool {
        didSet {
            UserDefaults.standard.set(showsDesktopLyrics, forKey: "music.desktopLyrics")
            markIslandSceneCustomized()
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
    private var isApplyingIslandScenePreset = false

    init() {
        launchesAtLogin = SMAppService.mainApp.status == .enabled
        let defaults = UserDefaults.standard
        enabledIslandCards = Self.loadEnabledIslandCards(from: defaults)
        islandCardOrders = Self.loadIslandCardOrders(from: defaults)
        activeIslandScenePreset = IslandScenePreset(
            rawValue: defaults.string(forKey: "island.scenePreset") ?? ""
        ) ?? .custom
        showsWelcome = !defaults.bool(forKey: Self.welcomeSeenKey)
        expandsOnHover = defaults.object(forKey: "interaction.hoverPreview") as? Bool ?? true
        autoCollapseDelay = min(max(defaults.object(forKey: "interaction.collapseDelay") as? Double ?? 0.65, 0.3), 2.0)
        hidesIslandInFullScreen = defaults.object(forKey: "interaction.hideInFullScreen") as? Bool ?? true
        compactDisplayMode = CompactDisplayMode(
            rawValue: defaults.string(forKey: "island.compactDisplayMode") ?? ""
        ) ?? .smart
        islandDisplayStrategy = IslandDisplayStrategy(
            rawValue: defaults.string(forKey: "island.displayStrategy") ?? ""
        ) ?? .builtInPreferred
        let savedVisualizer = defaults.string(forKey: "music.visualizer") ?? ""
        // Keep existing users' former "唱片光晕" choice meaningful while
        // replacing the effect with its less generic successor.
        musicVisualizerStyle = savedVisualizer == "halo"
            ? .cosmicDust
            : MusicVisualizerStyle(rawValue: savedVisualizer) ?? .spectrum
        islandAccentTheme = IslandAccentTheme(
            rawValue: defaults.string(forKey: "island.accentTheme") ?? ""
        ) ?? .violet
        lyricOffset = min(max(defaults.object(forKey: "music.lyricOffset") as? Double ?? 0, -3), 3)
        showsTranslatedLyrics = defaults.object(forKey: "music.translatedLyrics") as? Bool ?? true
        showsDesktopLyrics = defaults.object(forKey: "music.desktopLyrics") as? Bool ?? false
        desktopLyricsShowsNextLine = defaults.object(forKey: "desktopLyrics.nextLine") as? Bool ?? true
        desktopLyricsKaraokeEnabled = defaults.object(forKey: "desktopLyrics.karaokeFill") as? Bool ?? true
        desktopLyricsFontSize = min(max(defaults.object(forKey: "desktopLyrics.fontSize") as? Double ?? 24, 18), 38)
        desktopLyricsBackgroundOpacity = min(max(defaults.object(forKey: "desktopLyrics.backgroundOpacity") as? Double ?? 0.58, 0), 0.85)
        desktopLyricsLocked = defaults.object(forKey: "desktopLyrics.locked") as? Bool ?? false
        desktopLyricsTheme = DesktopLyricsTheme(rawValue: defaults.string(forKey: "desktopLyrics.theme") ?? "") ?? .white
        focusMinutes = min(max(defaults.object(forKey: "pomodoro.focusMinutes") as? Int ?? 25, 5), 120)
        hydrationRemindersEnabled = defaults.bool(forKey: "wellness.hydration.enabled")
        hydrationIntervalMinutes = min(max(defaults.object(forKey: "wellness.hydration.minutes") as? Int ?? 60, 5), 180)
        standRemindersEnabled = defaults.bool(forKey: "wellness.stand.enabled")
        standIntervalMinutes = min(max(defaults.object(forKey: "wellness.stand.minutes") as? Int ?? 45, 5), 180)
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

    func isIslandCardEnabled(_ id: IslandCardID) -> Bool {
        enabledIslandCards.contains(id)
    }

    func setIslandCardEnabled(_ id: IslandCardID, enabled: Bool) {
        var updated = enabledIslandCards
        if enabled {
            updated.insert(id)
        } else {
            updated.remove(id)
        }
        updated = IslandCardRegistry.sanitized(updated)
        guard updated != enabledIslandCards else { return }
        saveEnabledIslandCards(updated)
        markIslandSceneCustomized()
    }

    var prefersReducedActivity: Bool {
        activeIslandScenePreset == .powerSaving
    }

    func applyIslandScenePreset(_ preset: IslandScenePreset) {
        guard let configuration = preset.configuration else {
            activeIslandScenePreset = .custom
            UserDefaults.standard.set(IslandScenePreset.custom.rawValue, forKey: "island.scenePreset")
            NotificationCenter.default.post(name: Self.islandSceneDidChange, object: self)
            return
        }

        isApplyingIslandScenePreset = true
        activeIslandScenePreset = preset
        expandsOnHover = configuration.expandsOnHover
        hidesIslandInFullScreen = configuration.hidesIslandInFullScreen
        compactDisplayMode = configuration.compactDisplayMode
        musicVisualizerStyle = configuration.musicVisualizerStyle
        showsDesktopLyrics = configuration.showsDesktopLyrics
        saveEnabledIslandCards(configuration.enabledCards)
        isApplyingIslandScenePreset = false

        UserDefaults.standard.set(preset.rawValue, forKey: "island.scenePreset")
        NotificationCenter.default.post(name: Self.islandSceneDidChange, object: self)
    }

    func islandCardOrder(for context: IslandCardContext) -> [IslandCardID] {
        IslandCardRegistry.sanitizedOrder(islandCardOrders[context] ?? [], for: context)
    }

    func canMoveIslandCard(_ id: IslandCardID, by offset: Int, in context: IslandCardContext) -> Bool {
        let current = islandCardOrder(for: context)
        return IslandCardRegistry.moving(id, by: offset, in: context, order: current) != current
    }

    func moveIslandCard(_ id: IslandCardID, by offset: Int, in context: IslandCardContext) {
        let current = islandCardOrder(for: context)
        let updated = IslandCardRegistry.moving(id, by: offset, in: context, order: current)
        guard updated != current else { return }

        saveIslandCardOrder(updated, for: context)
    }

    func resetIslandCardOrder(in context: IslandCardContext) {
        let defaultOrder = IslandCardRegistry.defaultOrder(for: context)
        guard islandCardOrder(for: context) != defaultOrder else { return }
        saveIslandCardOrder(defaultOrder, for: context)
    }

    private func saveIslandCardOrder(_ order: [IslandCardID], for context: IslandCardContext) {
        islandCardOrders[context] = order
        UserDefaults.standard.set(order.map(\.rawValue), forKey: "cards.order.\(context.rawValue)")
        NotificationCenter.default.post(name: Self.islandCardsDidChange, object: self)
    }

    private func saveEnabledIslandCards(_ cards: Set<IslandCardID>) {
        let sanitized = IslandCardRegistry.sanitized(cards)
        guard sanitized != enabledIslandCards else { return }
        enabledIslandCards = sanitized

        let defaults = UserDefaults.standard
        let rawValues = IslandCardRegistry.registrations
            .map(\.id)
            .filter(sanitized.contains)
            .map(\.rawValue)
        defaults.set(rawValues, forKey: "cards.enabled")
        // Keep the former keys synchronized so a temporary downgrade does not
        // silently re-enable cards the user intentionally hid.
        defaults.set(sanitized.contains(.focus), forKey: "cards.pomodoro")
        defaults.set(sanitized.contains(.calendar), forKey: "cards.calendar")
        defaults.set(sanitized.contains(.power), forKey: "cards.power")
        NotificationCenter.default.post(name: Self.islandCardsDidChange, object: self)
    }

    private func markIslandSceneCustomized() {
        guard !isApplyingIslandScenePreset, activeIslandScenePreset != .custom else { return }
        activeIslandScenePreset = .custom
        UserDefaults.standard.set(IslandScenePreset.custom.rawValue, forKey: "island.scenePreset")
        NotificationCenter.default.post(name: Self.islandSceneDidChange, object: self)
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

    private static func loadEnabledIslandCards(from defaults: UserDefaults) -> Set<IslandCardID> {
        if let rawValues = defaults.stringArray(forKey: "cards.enabled") {
            return IslandCardRegistry.sanitized(rawValues.compactMap(IslandCardID.init(rawValue:)))
        }

        var enabled = IslandCardRegistry.defaultEnabledIDs
        let legacyKeys: [(IslandCardID, String)] = [
            (.focus, "cards.pomodoro"),
            (.calendar, "cards.calendar"),
            (.power, "cards.power")
        ]
        for (id, key) in legacyKeys {
            if let legacyValue = defaults.object(forKey: key) as? Bool, !legacyValue {
                enabled.remove(id)
            }
        }
        return enabled
    }

    private static func loadIslandCardOrders(
        from defaults: UserDefaults
    ) -> [IslandCardContext: [IslandCardID]] {
        Dictionary(uniqueKeysWithValues: IslandCardContext.allCases.map { context in
            let saved = defaults.stringArray(forKey: "cards.order.\(context.rawValue)") ?? []
            let decoded = saved.compactMap(IslandCardID.init(rawValue:))
            return (context, IslandCardRegistry.sanitizedOrder(decoded, for: context))
        })
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
