import AppKit
import Foundation
import SwiftUI

@MainActor
final class IslandState: ObservableObject {
    let settings: AppSettings
    let pocket: PocketService
    @Published var isPomodoroRunning = false
    @Published var remainingSeconds = 25 * 60
    @Published private(set) var musicTitle = "正在等待音乐"
    @Published private(set) var musicArtist = "支持国内主流播放器、Apple Music 与 Spotify"
    @Published private(set) var musicSource = "Notchly"
    @Published private(set) var hasMusic = false
    @Published private(set) var isPlaying = false
    @Published private(set) var isPerformingMusicAction = false
    @Published private(set) var musicElapsed: TimeInterval = 0
    @Published private(set) var musicDuration: TimeInterval = 0
    @Published private(set) var artworkImage: NSImage?
    @Published private(set) var lyricLines: [TimedLyricLine] = []
    @Published private(set) var isLoadingLyrics = false
    @Published private(set) var currentLyricText = ""
    @Published private(set) var nextLyricText = ""
    @Published private(set) var currentLyricProgress = 0.0
    @Published private(set) var isLyricInterlude = false
    @Published private(set) var currentLyricStart: TimeInterval = 0
    @Published private(set) var currentLyricEnd: TimeInterval = 0
    @Published private(set) var batteryLevel: Int?
    @Published private(set) var batteryStatus = "正在读取电源状态"
    @Published private(set) var batteryTimeRemaining = ""
    @Published private(set) var calendarTitle = "连接日历后显示下一项"
    @Published private(set) var calendarSubtitle = "你的日程只会保留在这台 Mac 上"
    @Published private(set) var isLoadingCalendar = false
    var onMusicRefreshPolicyChanged: (@MainActor () -> Void)?

    private var timer: Timer?
    private var musicRefreshTask: Task<Void, Never>?
    private var musicActionTask: Task<Void, Never>?
    private var artworkTask: Task<Void, Never>?
    private var lyricsTask: Task<Void, Never>?
    private var lyricTimer: Timer?
    private var musicSnapshotDate = Date()
    private var artworkKey: String?
    private var artworkCache: [URL: ArtworkCacheEntry] = [:]
    private let artworkCacheLifetime: TimeInterval = 60 * 60
    private let artworkCacheLimit = 40
    private let calendarService = CalendarService()
    private let notificationService = NotificationService()
    private let musicService = MusicService()
    private let lyricsService = LyricsService()
    private let powerService = PowerService()
    private let timerEndDateKey = "pomodoro.endDate"
    private let remainingSecondsKey = "pomodoro.remainingSeconds"
    private let musicConnectedKey = "music.connected"

    init(settings: AppSettings) {
        self.settings = settings
        pocket = PocketService(settings: settings)
        restorePomodoro()
        refreshPower()
    }

    var timerText: String {
        String(format: "%02d:%02d", remainingSeconds / 60, remainingSeconds % 60)
    }

    private var focusDuration: Int { settings.focusMinutes * 60 }

    func togglePomodoro() {
        isPomodoroRunning ? pausePomodoro() : startPomodoro()
    }

    func resetPomodoro() {
        pausePomodoro()
        remainingSeconds = focusDuration
        UserDefaults.standard.set(remainingSeconds, forKey: remainingSecondsKey)
    }

    private func startPomodoro() {
        if remainingSeconds == 0 { remainingSeconds = focusDuration }
        let endDate = Date().addingTimeInterval(TimeInterval(remainingSeconds))
        UserDefaults.standard.set(endDate, forKey: timerEndDateKey)
        UserDefaults.standard.set(remainingSeconds, forKey: remainingSecondsKey)
        isPomodoroRunning = true
        beginTicking()
        Task { await notificationService.scheduleFocusComplete(after: remainingSeconds) }
    }

    private func pausePomodoro() {
        updateRemainingTime()
        isPomodoroRunning = false
        timer?.invalidate()
        timer = nil
        UserDefaults.standard.removeObject(forKey: timerEndDateKey)
        UserDefaults.standard.set(remainingSeconds, forKey: remainingSecondsKey)
        notificationService.cancelFocusComplete()
    }

    private func restorePomodoro() {
        let defaults = UserDefaults.standard
        let savedRemaining = defaults.object(forKey: remainingSecondsKey) as? Int
        remainingSeconds = savedRemaining ?? focusDuration
        guard let endDate = defaults.object(forKey: timerEndDateKey) as? Date else { return }
        guard endDate > Date() else {
            remainingSeconds = 0
            defaults.removeObject(forKey: timerEndDateKey)
            return
        }
        isPomodoroRunning = true
        updateRemainingTime()
        beginTicking()
    }

    private func beginTicking() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.updateRemainingTime() }
        }
        timer?.tolerance = 0.1
    }

    private func updateRemainingTime() {
        guard let endDate = UserDefaults.standard.object(forKey: timerEndDateKey) as? Date else { return }
        remainingSeconds = Self.remainingSeconds(until: endDate)
        UserDefaults.standard.set(remainingSeconds, forKey: remainingSecondsKey)
        guard remainingSeconds == 0 else { return }
        isPomodoroRunning = false
        timer?.invalidate()
        timer = nil
        UserDefaults.standard.removeObject(forKey: timerEndDateKey)
    }

    static func remainingSeconds(until endDate: Date, now: Date = .now) -> Int {
        max(0, Int(ceil(endDate.timeIntervalSince(now))))
    }

    func connectCalendar() {
        guard !isLoadingCalendar else { return }
        isLoadingCalendar = true
        Task {
            defer { isLoadingCalendar = false }
            do {
                if let event = try await calendarService.nextEvent(requestingAccessIfNeeded: true) {
                    calendarTitle = event.title ?? "未命名日程"
                    calendarSubtitle = event.startDate.notchlyRelativeDate
                } else {
                    calendarTitle = "未来 7 天没有日程"
                    calendarSubtitle = "享受一段安静的时间吧"
                }
            } catch {
                calendarTitle = "无法读取日历"
                calendarSubtitle = "请在系统设置中允许 Notchly 访问日历"
            }
        }
    }

    func refreshMusic() {
        musicRefreshTask?.cancel()
        musicRefreshTask = Task { [weak self] in
            guard let self else { return }
            do {
                let playback = try await self.musicService.snapshot()
                guard !Task.isCancelled else { return }
                if let playback {
                    self.apply(playback)
                    UserDefaults.standard.set(true, forKey: self.musicConnectedKey)
                } else {
                    self.musicTitle = "播放一首音乐开始"
                    self.musicArtist = "支持国内主流播放器、Apple Music 与 Spotify"
                    self.musicSource = "等待播放器"
                    self.hasMusic = false
                    self.isPlaying = false
                    self.musicElapsed = 0
                    self.musicDuration = 0
                    self.artworkImage = nil
                    self.lyricLines = []
                    self.isLoadingLyrics = false
                    self.publishLyrics(at: Date())
                    self.updateLyricTicker()
                    self.onMusicRefreshPolicyChanged?()
                }
            } catch {
                guard !Task.isCancelled else { return }
                self.musicTitle = "无法连接播放器"
                self.musicArtist = "请检查播放器或系统媒体权限"
                self.musicSource = "Notchly"
                self.hasMusic = false
                self.isPlaying = false
                self.updateLyricTicker()
                self.onMusicRefreshPolicyChanged?()
            }
        }
    }

    private func apply(_ playback: MusicPlayback) {
        let now = Date()
        let newTrackKey = "\(playback.source):\(playback.title):\(playback.artist)"
        let isSameTrack = artworkKey == newTrackKey
        let predictedElapsed = elapsedTime(at: now)

        musicTitle = playback.title
        musicArtist = playback.artist
        musicSource = playback.source
        hasMusic = true
        let wasPlaying = isPlaying
        isPlaying = playback.isPlaying
        musicDuration = playback.duration
        musicElapsed = reconciledElapsed(
            incoming: playback.elapsed,
            predicted: predictedElapsed,
            isSameTrack: isSameTrack,
            wasPlaying: wasPlaying,
            isPlaying: playback.isPlaying
        )
        musicSnapshotDate = now
        updateLyricTicker()
        onMusicRefreshPolicyChanged?()

        guard !isSameTrack else { return }
        artworkKey = newTrackKey
        loadLyrics(for: playback, key: newTrackKey)
        artworkTask?.cancel()
        if let data = playback.artworkData, let image = NSImage(data: data) {
            artworkImage = image
        } else if let url = playback.artworkURL {
            if let cached = cachedArtwork(for: url) {
                artworkImage = cached
                return
            }
            artworkImage = nil
            artworkTask = Task { [weak self] in
                guard let self else { return }
            let request = URLRequest(url: url, timeoutInterval: 10)
            guard let (data, response) = try? await URLSession.shared.data(for: request),
                  !Task.isCancelled,
                  let http = response as? HTTPURLResponse,
                  (200..<300).contains(http.statusCode),
                  http.expectedContentLength <= 8 * 1_024 * 1_024 || http.expectedContentLength == NSURLSessionTransferSizeUnknown,
                  data.count <= 8 * 1_024 * 1_024,
                  let image = NSImage(data: data) else { return }
            self.storeArtwork(image, for: url)
            self.artworkImage = image
            }
        } else {
            artworkImage = nil
        }
    }

    private func cachedArtwork(for url: URL, now: Date = .now) -> NSImage? {
        guard let entry = artworkCache[url] else { return nil }
        guard now.timeIntervalSince(entry.cachedAt) < artworkCacheLifetime else {
            artworkCache[url] = nil
            return nil
        }
        return entry.image
    }

    private func storeArtwork(_ image: NSImage, for url: URL, now: Date = .now) {
        artworkCache[url] = ArtworkCacheEntry(image: image, cachedAt: now)
        guard artworkCache.count > artworkCacheLimit else { return }
        let expired = artworkCache
            .sorted { $0.value.cachedAt < $1.value.cachedAt }
            .prefix(artworkCache.count - artworkCacheLimit)
            .map(\.key)
        expired.forEach { artworkCache[$0] = nil }
    }

    private func reconciledElapsed(
        incoming: TimeInterval,
        predicted: TimeInterval,
        isSameTrack: Bool,
        wasPlaying: Bool,
        isPlaying: Bool
    ) -> TimeInterval {
        guard isSameTrack else { return max(0, incoming) }

        // Some MediaRemote clients repeatedly publish a stale zero elapsed value.
        // Keep the local monotonic clock in that case, while still accepting a
        // meaningful seek or a fresh non-zero timestamp from the player.
        let incomingIsUseful = incoming > 0.5
        if incomingIsUseful, abs(incoming - predicted) > 3 {
            return max(0, incoming)
        }
        if !isPlaying, !wasPlaying, incomingIsUseful {
            return max(0, incoming)
        }
        return max(0, predicted)
    }

    private func loadLyrics(for playback: MusicPlayback, key: String) {
        lyricsTask?.cancel()
        lyricLines = []
        isLoadingLyrics = true
        lyricsTask = Task { [weak self] in
            guard let self else { return }
            let lines = await self.lyricsService.lyrics(
                for: playback.title,
                artist: playback.artist,
                duration: playback.duration
            )
            guard !Task.isCancelled, self.artworkKey == key else { return }
            self.lyricLines = lines
            self.isLoadingLyrics = false
            self.publishLyrics(at: Date())
            self.updateLyricTicker()
        }
    }

    private func updateLyricTicker() {
        let shouldTick = isPlaying && !lyricLines.isEmpty
        guard shouldTick else {
            lyricTimer?.invalidate()
            lyricTimer = nil
            return
        }
        guard lyricTimer == nil else { return }
        lyricTimer = Timer.scheduledTimer(withTimeInterval: 0.10, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.publishLyrics(at: Date()) }
        }
        lyricTimer?.tolerance = 0.02
    }

    private func publishLyrics(at date: Date) {
        guard !lyricLines.isEmpty else {
            setPublishedLyrics(current: "", next: "", progress: 0, start: 0, end: 0, isInterlude: false)
            return
        }
        let elapsed = elapsedTime(at: date) + settings.lyricOffset
        let currentIndex = lyricLines.lastIndex { $0.time <= elapsed + 0.12 }
        let candidate = currentIndex.map { lyricLines[$0].text } ?? ""
        let followingStart = (currentIndex ?? -1) + 1
        let next = followingStart < lyricLines.count
            ? lyricLines[followingStart...].first(where: { $0.text != candidate })?.text ?? ""
            : ""
        guard let currentIndex else {
            setPublishedLyrics(current: "", next: next, progress: 0, start: 0, end: 0, isInterlude: false)
            return
        }

        let start = lyricLines[currentIndex].time
        let nextLineStart = lyricLines.dropFirst(currentIndex + 1)
            .first(where: { $0.text != candidate })?.time
        let end = lyricActiveEnd(start: start, nextStart: nextLineStart, text: candidate)
        let isInterlude = elapsed > end + 0.12
            && (nextLineStart == nil || elapsed < (nextLineStart ?? .greatestFiniteMagnitude) - 0.08)

        if isInterlude {
            setPublishedLyrics(current: "", next: next, progress: 0, start: 0, end: 0, isInterlude: true)
            return
        }

        let progress = lyricProgress(elapsed: elapsed, start: start, end: end)
        setPublishedLyrics(
            current: candidate,
            next: next,
            progress: progress,
            start: start,
            end: end,
            isInterlude: false
        )
    }

    private func lyricActiveEnd(start: TimeInterval, nextStart: TimeInterval?, text: String) -> TimeInterval {
        let visibleCount = text.unicodeScalars.reduce(into: 0) { count, scalar in
            if !CharacterSet.whitespacesAndNewlines.union(.punctuationCharacters).contains(scalar) {
                count += 1
            }
        }
        // Plain LRC only gives one timestamp per line. Estimate a comfortable
        // singing window from the visible lyric length, but respect tightly
        // spaced source timestamps and leave long gaps to the interlude state.
        let naturalDuration = min(max(1.4 + Double(visibleCount) * 0.30, 2.2), 6.0)
        guard let nextStart else { return start + naturalDuration }
        let sourceSpan = max(0.45, nextStart - start - 0.08)
        let duration = sourceSpan <= naturalDuration + 1.3 ? sourceSpan : naturalDuration
        return start + duration
    }

    private func lyricProgress(elapsed: TimeInterval, start: TimeInterval, end: TimeInterval) -> Double {
        let span = max(0.35, end - start)
        return min(max((elapsed - start) / span, 0), 1)
    }

    func lyricProgress(at date: Date) -> Double {
        guard !currentLyricText.isEmpty, currentLyricEnd > currentLyricStart else { return 0 }
        return lyricProgress(
            elapsed: elapsedTime(at: date) + settings.lyricOffset,
            start: currentLyricStart,
            end: currentLyricEnd
        )
    }

    private func setPublishedLyrics(
        current: String,
        next: String,
        progress: Double,
        start: TimeInterval,
        end: TimeInterval,
        isInterlude: Bool
    ) {
        if currentLyricText != current { currentLyricText = current }
        if nextLyricText != next { nextLyricText = next }
        if abs(currentLyricProgress - progress) > 0.002 { currentLyricProgress = progress }
        if currentLyricStart != start { currentLyricStart = start }
        if currentLyricEnd != end { currentLyricEnd = end }
        if self.isLyricInterlude != isInterlude { self.isLyricInterlude = isInterlude }
    }

    func elapsedTime(at date: Date) -> TimeInterval {
        let advanced = isPlaying ? date.timeIntervalSince(musicSnapshotDate) : 0
        let value = musicElapsed + advanced
        return min(max(0, value), musicDuration > 0 ? musicDuration : value)
    }

    func toggleMusic() {
        performMusicAction { try await self.musicService.togglePlayback() }
    }

    func previousMusic() {
        performMusicAction { try await self.musicService.previousTrack() }
    }

    func nextMusic() {
        performMusicAction { try await self.musicService.nextTrack() }
    }

    func openMusicApp() {
        musicService.openActivePlayer()
    }

    private func performMusicAction(_ action: @escaping () async throws -> Void) {
        guard musicActionTask == nil else { return }
        isPerformingMusicAction = true
        musicActionTask = Task { [weak self] in
            guard let self else { return }
            defer {
                self.musicActionTask = nil
                self.isPerformingMusicAction = false
            }
            do {
                try await action()
                try? await Task.sleep(for: .milliseconds(250))
                self.refreshMusic()
            } catch {
                self.musicTitle = "请先打开 Spotify 或 Music"
                self.musicArtist = "然后播放任意一首歌曲"
                self.hasMusic = false
                self.isPlaying = false
                self.updateLyricTicker()
                self.onMusicRefreshPolicyChanged?()
            }
        }
    }

    func refreshPower() {
        let snapshot = powerService.snapshot()
        batteryLevel = snapshot.level
        batteryStatus = snapshot.status
        batteryTimeRemaining = snapshot.timeRemaining
    }

    func refreshAuthorizedServices() {
        refreshPower()
        refreshMusic()
        guard calendarService.hasAuthorizedAccess, !isLoadingCalendar else { return }
        isLoadingCalendar = true
        Task {
            defer { isLoadingCalendar = false }
            do {
                if let event = try await calendarService.nextEvent(requestingAccessIfNeeded: false) {
                    calendarTitle = event.title ?? "未命名日程"
                    calendarSubtitle = event.startDate.notchlyRelativeDate
                } else {
                    calendarTitle = "未来 7 天没有日程"
                    calendarSubtitle = "享受一段安静的时间吧"
                }
            } catch {
                // Keep the last successfully loaded event when a refresh fails.
            }
        }
    }

    func syncWellnessReminders() {
        Task {
            await notificationService.updateWellnessReminders(
                hydrationEnabled: settings.hydrationRemindersEnabled,
                hydrationMinutes: settings.hydrationIntervalMinutes,
                standEnabled: settings.standRemindersEnabled,
                standMinutes: settings.standIntervalMinutes
            )
        }
    }
}

private struct ArtworkCacheEntry {
    let image: NSImage
    let cachedAt: Date
}

private extension Date {
    var notchlyRelativeDate: String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = Calendar.current.isDateInToday(self) ? "今天 HH:mm" : "M月d日 HH:mm"
        return formatter.string(from: self)
    }
}
