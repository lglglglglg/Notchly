import AppKit
import Foundation
import MediaRemoteAdapter

struct MusicPlayback: Sendable {
    let title: String
    let artist: String
    let album: String
    let isPlaying: Bool
    let source: String
    let elapsed: TimeInterval
    let duration: TimeInterval
    let artworkData: Data?
    let artworkURL: URL?
}

private struct ScriptedPlayback: Sendable {
    let provider: PlayerProvider
    let title: String
    let artist: String
    let album: String
    let isPlaying: Bool
    let elapsed: TimeInterval
    let duration: TimeInterval
    let artworkURL: URL?
}

enum MediaListenerPolicy {
    static func shouldListen(hasRunningSystemProvider: Bool) -> Bool {
        hasRunningSystemProvider
    }

    static func retryDelay(forAttempt attempt: Int) -> TimeInterval {
        min(30, pow(2, Double(max(0, attempt))))
    }
}

@MainActor
final class MusicService {
    /// MediaRemote pushes its first update independently of the periodic
    /// snapshot timer. Forward it immediately so a newly opened supported
    /// player does not leave the island in its placeholder state.
    var onSystemPlaybackChanged: (@MainActor () -> Void)?
    private let separator = "\u{001F}"
    private let scriptedProviders: [PlayerProvider] = [.spotify, .music]
    private let systemProviders: [PlayerProvider] = [.netease, .qqMusic, .kugou, .kuwo, .qishui]
    private var activeProvider: PlayerProvider?
    private var cachedArtworkKey: String?
    private var cachedArtworkData: Data?
    private let mediaController: MediaController
    private let scriptReader = MusicScriptReader()
    private var systemPlayback: (provider: PlayerProvider, playback: MusicPlayback)?
    private var isListeningToSystemMedia = false
    private var listenerRestartTask: Task<Void, Never>?
    private var listenerRestartAttempt = 0

    init() {
        mediaController = MediaController()
        mediaController.onTrackInfoReceived = { [weak self] trackInfo in
            Task { @MainActor [weak self] in
                self?.receiveSystemTrack(trackInfo)
            }
        }
        mediaController.onListenerTerminated = { [weak self] in
            Task { @MainActor [weak self] in
                self?.scheduleSystemMediaListenerRestart()
            }
        }
    }

    func snapshot() async throws -> MusicPlayback? {
        let hasRunningSystemProvider = systemProviders.contains(where: \.isRunning)
        updateSystemMediaListener(hasRunningSystemProvider: hasRunningSystemProvider)
        if let systemPlayback, !systemPlayback.provider.isRunning {
            self.systemPlayback = nil
        }
        if let systemPlayback, systemPlayback.playback.isPlaying {
            activeProvider = systemPlayback.provider
            return systemPlayback.playback
        }

        let runningScriptedProviders = scriptedProviders.filter(\.isNativeScriptableRunning)
        let scriptedPlayback = try await scriptReader.snapshot(
            providers: runningScriptedProviders,
            separator: separator
        )

        if let systemPlayback, systemPlayback.provider.isRunning, systemPlayback.playback.isPlaying {
            activeProvider = systemPlayback.provider
            return systemPlayback.playback
        }

        guard let scriptedPlayback else {
            if let systemPlayback {
                activeProvider = systemPlayback.provider
                return systemPlayback.playback
            }
            return nil
        }

        let artworkKey = "\(scriptedPlayback.provider.bundleIdentifiers.first ?? scriptedPlayback.provider.displayName):\(scriptedPlayback.title):\(scriptedPlayback.artist)"
        if artworkKey != cachedArtworkKey {
            cachedArtworkKey = artworkKey
            cachedArtworkData = nil
            if scriptedPlayback.provider == .music {
                cachedArtworkData = await scriptReader.appleMusicArtwork()
            }
        }
        activeProvider = scriptedPlayback.provider
        return MusicPlayback(
            title: scriptedPlayback.title,
            artist: scriptedPlayback.artist,
            album: scriptedPlayback.album,
            isPlaying: scriptedPlayback.isPlaying,
            source: scriptedPlayback.provider.displayName,
            elapsed: min(
                scriptedPlayback.elapsed,
                scriptedPlayback.duration > 0 ? scriptedPlayback.duration : scriptedPlayback.elapsed
            ),
            duration: scriptedPlayback.duration,
            artworkData: cachedArtworkData,
            artworkURL: scriptedPlayback.artworkURL
        )
    }

    func togglePlayback() async throws { try await perform(.toggle) }
    func previousTrack() async throws { try await perform(.previous) }
    func nextTrack() async throws { try await perform(.next) }

    func openActivePlayer() {
        let provider = activeProvider
            ?? scriptedProviders.first(where: \.isRunning)
            ?? systemProviders.first(where: \.isRunning)
        guard let provider else { return }
        for bundleIdentifier in provider.bundleIdentifiers {
            guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier) else { continue }
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.activates = true
            NSWorkspace.shared.openApplication(at: url, configuration: configuration)
            return
        }
    }

    private func perform(_ command: PlayerCommand) async throws {
        let provider: PlayerProvider
        if let activeProvider, activeProvider.isRunning {
            provider = activeProvider
        } else if let scripted = scriptedProviders.first(where: { $0.isRunning }) {
            provider = scripted
        } else if let systemProvider = systemProviders.first(where: \.isRunning) {
            provider = systemProvider
        } else {
            throw MusicServiceError.notRunning
        }

        if provider.usesAppleScript && provider.isNativeScriptableRunning {
            try await scriptReader.perform(command: command, in: provider.applicationName)
        } else {
            switch command {
            case .toggle: mediaController.togglePlayPause()
            case .previous: mediaController.previousTrack()
            case .next: mediaController.nextTrack()
            }
        }
    }

    private func receiveSystemTrack(_ trackInfo: TrackInfo?) {
        guard let payload = trackInfo?.payload,
              let title = payload.title,
              !title.isEmpty,
              let provider = systemProviders.first(where: {
                  if let bundleID = payload.bundleIdentifier, $0.bundleIdentifiers.contains(bundleID) {
                      return true
                  }
                  guard let applicationName = payload.applicationName else { return false }
                  return [ $0.applicationName, $0.displayName ].contains {
                      applicationName.localizedCaseInsensitiveCompare($0) == .orderedSame
                  }
              }) else {
            systemPlayback = nil
            onSystemPlaybackChanged?()
            return
        }

        let duration = max(0, (payload.durationMicros ?? 0) / 1_000_000)
        let elapsed = max(0, payload.currentElapsedTime ?? ((payload.elapsedTimeMicros ?? 0) / 1_000_000))
        let artworkData = payload.artworkDataBase64.flatMap { Data(base64Encoded: $0) }
        systemPlayback = (provider, MusicPlayback(
            title: title,
            artist: payload.artist ?? "未知歌手",
            album: payload.album?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "",
            isPlaying: payload.isPlaying ?? ((payload.playbackRate ?? 0) > 0),
            source: provider.displayName,
            elapsed: min(elapsed, duration > 0 ? duration : elapsed),
            duration: duration,
            artworkData: artworkData,
            artworkURL: nil
        ))
        listenerRestartAttempt = 0
        onSystemPlaybackChanged?()
    }

    private func updateSystemMediaListener(hasRunningSystemProvider: Bool) {
        let shouldListen = MediaListenerPolicy.shouldListen(
            hasRunningSystemProvider: hasRunningSystemProvider
        )
        guard shouldListen != isListeningToSystemMedia else { return }
        listenerRestartTask?.cancel()
        listenerRestartTask = nil
        isListeningToSystemMedia = shouldListen
        listenerRestartAttempt = 0
        if shouldListen {
            startSystemMediaListener()
        } else {
            mediaController.stopListening()
            systemPlayback = nil
            onSystemPlaybackChanged?()
        }
    }

    private func startSystemMediaListener() {
        guard isListeningToSystemMedia else { return }
        mediaController.startListening()
        mediaController.getTrackInfo { [weak self] trackInfo in
            Task { @MainActor [weak self] in
                self?.receiveSystemTrack(trackInfo)
            }
        }
    }

    private func scheduleSystemMediaListenerRestart() {
        guard isListeningToSystemMedia,
              systemProviders.contains(where: \.isRunning),
              listenerRestartTask == nil else { return }
        let delay = MediaListenerPolicy.retryDelay(forAttempt: listenerRestartAttempt)
        listenerRestartAttempt += 1
        listenerRestartTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled, let self else { return }
            self.listenerRestartTask = nil
            self.startSystemMediaListener()
        }
    }

}

/// Serializes AppleScript work away from the main actor. A stalled player can
/// therefore delay only the next music snapshot, never island interaction.
private final class MusicScriptReader: @unchecked Sendable {
    private let queue = DispatchQueue(label: "com.notchly.music.apple-script", qos: .utility)

    func snapshot(providers: [PlayerProvider], separator: String) async throws -> ScriptedPlayback? {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                do {
                    continuation.resume(returning: try Self.readSnapshot(
                        providers: providers,
                        separator: separator
                    ))
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    func appleMusicArtwork() async -> Data? {
        await withCheckedContinuation { continuation in
            queue.async {
                continuation.resume(returning: Self.readAppleMusicArtwork())
            }
        }
    }

    func perform(command: PlayerCommand, in applicationName: String) async throws {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                do {
                    _ = try Self.run("tell application \"\(applicationName)\" to \(command.appleScriptCommand)")
                    continuation.resume()
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    private static func readSnapshot(
        providers: [PlayerProvider],
        separator: String
    ) throws -> ScriptedPlayback? {
        var pausedPlayback: ScriptedPlayback?
        for provider in providers {
            let response = try run(provider.snapshotScript(separator: separator))
            guard !response.isEmpty else { continue }
            let fields = response.components(separatedBy: separator)
            guard fields.count == 7 else { throw MusicServiceError.invalidResponse }
            let elapsed = max(0, Double(fields[4]) ?? 0)
            var duration = max(0, Double(fields[5]) ?? 0)
            if provider == .spotify { duration /= 1_000 }
            let playback = ScriptedPlayback(
                provider: provider,
                title: fields[0],
                artist: fields[1],
                album: fields[2],
                isPlaying: fields[3].lowercased() == "true",
                elapsed: elapsed,
                duration: duration,
                artworkURL: URL(string: fields[6])
            )
            if playback.isPlaying { return playback }
            pausedPlayback = playback
        }
        return pausedPlayback
    }

    private static func run(_ source: String) throws -> String {
        var error: NSDictionary?
        guard let script = NSAppleScript(source: source) else {
            throw MusicServiceError.script("无法编译播放器自动化脚本")
        }
        let result = script.executeAndReturnError(&error)
        if let error {
            let message = error[NSAppleScript.errorMessage] as? String ?? "播放器没有返回结果"
            throw MusicServiceError.script(message)
        }
        return result.stringValue ?? ""
    }

    private static func readAppleMusicArtwork() -> Data? {
        var error: NSDictionary?
        let source = """
        tell application "Music"
            if (count of artworks of current track) is 0 then return missing value
            return raw data of artwork 1 of current track
        end tell
        """
        guard let script = NSAppleScript(source: source) else { return nil }
        let result = script.executeAndReturnError(&error)
        guard error == nil, result.descriptorType != 0 else { return nil }
        return result.data
    }
}

private enum PlayerCommand: Sendable {
    case toggle
    case previous
    case next

    var appleScriptCommand: String {
        switch self {
        case .toggle: "playpause"
        case .previous: "previous track"
        case .next: "next track"
        }
    }
}

private enum PlayerProvider: Equatable, Sendable {
    case spotify
    case music
    case netease
    case qqMusic
    case kugou
    case kuwo
    case qishui

    var bundleIdentifiers: [String] {
        switch self {
        case .spotify: ["com.spotify.client"]
        case .music: ["com.apple.Music"]
        case .netease: ["com.netease.163music"]
        case .qqMusic: ["com.tencent.QQMusicMac"]
        case .kugou: ["com.kugou.mac.Music", "com.kugou.mac.KugouMusic", "com.kugou.KugouMusic", "com.Kugou.mac.KugouMusic"]
        case .kuwo: ["com.yeelion.kwplayer", "cn.kuwo.KuwoMusic", "com.kuwo.KuwoMusic", "com.kuwo.mac"]
        case .qishui: ["com.soda.music", "com.luna.music", "com.bytedance.qishui", "com.bytedance.qishui-music"]
        }
    }

    var applicationName: String {
        switch self {
        case .spotify: "Spotify"
        case .music: "Music"
        case .netease: "NeteaseMusic"
        case .qqMusic: "QQMusic"
        case .kugou: "KuGou"
        case .kuwo: "KuwoMusic"
        case .qishui: "汽水音乐"
        }
    }

    var displayName: String {
        switch self {
        case .spotify: "Spotify"
        case .music: "Apple Music"
        case .netease: "网易云音乐"
        case .qqMusic: "QQ音乐"
        case .kugou: "酷狗音乐"
        case .kuwo: "酷我音乐"
        case .qishui: "汽水音乐"
        }
    }

    var usesAppleScript: Bool { self == .spotify || self == .music }

    var isNativeScriptableRunning: Bool {
        bundleIdentifiers.contains {
            !NSRunningApplication.runningApplications(withBundleIdentifier: $0).isEmpty
        }
    }

    var isRunning: Bool {
        if bundleIdentifiers.contains(where: {
            !NSRunningApplication.runningApplications(withBundleIdentifier: $0).isEmpty
        }) {
            return true
        }
        let expectedNames = [applicationName, displayName]
        return NSWorkspace.shared.runningApplications.contains { app in
            guard let name = app.localizedName else { return false }
            return expectedNames.contains { name.localizedCaseInsensitiveCompare($0) == .orderedSame }
        }
    }

    func snapshotScript(separator: String) -> String {
        let artworkExpression = self == .spotify ? "artwork url of current track" : "\"\""
        return """
        tell application "\(applicationName)"
            if player state is stopped then return ""
            set trackName to name of current track
            set trackArtist to artist of current track
            set trackAlbum to album of current track
            set playingNow to (player state is playing) as string
            set trackPosition to (player position) as string
            set trackDuration to (duration of current track) as string
            set artworkLocation to \(artworkExpression)
            return trackName & "\(separator)" & trackArtist & "\(separator)" & trackAlbum & "\(separator)" & playingNow & "\(separator)" & trackPosition & "\(separator)" & trackDuration & "\(separator)" & artworkLocation
        end tell
        """
    }

}

enum MusicServiceError: LocalizedError {
    case notRunning
    case invalidResponse
    case script(String)

    var errorDescription: String? {
        switch self {
        case .notRunning: "播放器未运行"
        case .invalidResponse: "播放器返回了无法识别的信息"
        case let .script(message): message
        }
    }
}
