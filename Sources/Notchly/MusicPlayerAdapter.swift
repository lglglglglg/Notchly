import AppKit
import Foundation
import MediaRemoteAdapter

enum MusicAdapterID: String, CaseIterable, Sendable {
    case appleScript
    case mediaRemote

    var title: String {
        switch self {
        case .appleScript: "AppleScript（公开）"
        case .mediaRemote: "MediaRemote（兼容）"
        }
    }
}

struct MusicPlayerAdapterRegistration: Equatable, Sendable {
    let id: MusicAdapterID
    let providers: [PlayerProvider]
    let usesDocumentedAPI: Bool
}

enum MusicPlayerAdapterRegistry {
    static let registrations: [MusicPlayerAdapterRegistration] = [
        MusicPlayerAdapterRegistration(
            id: .appleScript,
            providers: [.spotify, .music],
            usesDocumentedAPI: true
        ),
        MusicPlayerAdapterRegistration(
            id: .mediaRemote,
            providers: [.netease, .qqMusic, .kugou, .kuwo, .qishui],
            usesDocumentedAPI: false
        )
    ]

    static func registration(for provider: PlayerProvider) -> MusicPlayerAdapterRegistration? {
        registrations.first { $0.providers.contains(provider) }
    }
}

struct AdapterPlayback: Sendable {
    let provider: PlayerProvider
    let playback: MusicPlayback
}

@MainActor
protocol MusicPlayerAdapter: AnyObject {
    var id: MusicAdapterID { get }
    var providers: [PlayerProvider] { get }
    func snapshot() async throws -> AdapterPlayback?
    func perform(_ command: PlayerCommand, provider: PlayerProvider) async throws
    func shutdown()
}

@MainActor
final class AppleScriptPlayerAdapter: MusicPlayerAdapter {
    let id = MusicAdapterID.appleScript
    let providers = MusicPlayerAdapterRegistry.registration(for: .music)?.providers ?? []

    private let separator = "\u{001F}"
    private let reader = MusicScriptReader()
    private var cachedArtworkKey: String?
    private var cachedArtworkData: Data?

    func snapshot() async throws -> AdapterPlayback? {
        let runningProviders = providers.filter(\.isNativeScriptableRunning)
        guard let scripted = try await reader.snapshot(
            providers: runningProviders,
            separator: separator
        ) else { return nil }

        let artworkKey = "\(scripted.provider.bundleIdentifiers.first ?? scripted.provider.displayName):\(scripted.title):\(scripted.artist)"
        if artworkKey != cachedArtworkKey {
            cachedArtworkKey = artworkKey
            cachedArtworkData = nil
            if scripted.provider == .music {
                cachedArtworkData = await reader.appleMusicArtwork()
            }
        }

        return AdapterPlayback(
            provider: scripted.provider,
            playback: MusicPlayback(
                title: scripted.title,
                artist: scripted.artist,
                album: scripted.album,
                isPlaying: scripted.isPlaying,
                source: scripted.provider.displayName,
                elapsed: min(
                    scripted.elapsed,
                    scripted.duration > 0 ? scripted.duration : scripted.elapsed
                ),
                duration: scripted.duration,
                artworkData: cachedArtworkData,
                artworkURL: scripted.artworkURL
            )
        )
    }

    func perform(_ command: PlayerCommand, provider: PlayerProvider) async throws {
        guard providers.contains(provider), provider.isNativeScriptableRunning else {
            throw MusicServiceError.notRunning
        }
        try await reader.perform(command: command, in: provider.applicationName)
    }

    func shutdown() {
        cachedArtworkKey = nil
        cachedArtworkData = nil
    }
}

@MainActor
final class MediaRemotePlayerAdapter: MusicPlayerAdapter {
    let id = MusicAdapterID.mediaRemote
    let providers = MusicPlayerAdapterRegistry.registration(for: .netease)?.providers ?? []
    var onPlaybackChanged: (@MainActor () -> Void)?

    private let controller: MediaController
    private var playback: AdapterPlayback?
    private var isListening = false
    private var restartTask: Task<Void, Never>?
    private var restartAttempt = 0
    private var cachedArtworkKey: String?
    private var cachedArtworkPayload: String?
    private var cachedArtworkData: Data?

    init(controller: MediaController = MediaController()) {
        self.controller = controller
        controller.onTrackInfoReceived = { [weak self] trackInfo in
            Task { @MainActor [weak self] in
                self?.receive(trackInfo)
            }
        }
        controller.onListenerTerminated = { [weak self] in
            Task { @MainActor [weak self] in
                self?.scheduleRestart()
            }
        }
    }

    func refreshAvailability() {
        let hasRunningProvider = providers.contains(where: \.isRunning)
        updateListener(hasRunningProvider: hasRunningProvider)
        if let playback, !playback.provider.isRunning {
            self.playback = nil
        }
    }

    var currentPlayback: AdapterPlayback? {
        refreshAvailability()
        return playback
    }

    func snapshot() async throws -> AdapterPlayback? {
        currentPlayback
    }

    func perform(_ command: PlayerCommand, provider: PlayerProvider) async throws {
        guard providers.contains(provider), provider.isRunning else {
            throw MusicServiceError.notRunning
        }
        switch command {
        case .toggle: controller.togglePlayPause()
        case .previous: controller.previousTrack()
        case .next: controller.nextTrack()
        }
    }

    func shutdown() {
        restartTask?.cancel()
        restartTask = nil
        isListening = false
        playback = nil
        controller.stopListening()
        controller.onTrackInfoReceived = nil
        controller.onListenerTerminated = nil
        controller.onDecodingError = nil
        onPlaybackChanged = nil
    }

    private func receive(_ trackInfo: TrackInfo?) {
        DiagnosticStore.shared.recordMediaRemoteEvent()
        guard let payload = trackInfo?.payload,
              let title = payload.title,
              !title.isEmpty,
              let provider = providers.first(where: {
                  if let bundleID = payload.bundleIdentifier,
                     $0.bundleIdentifiers.contains(bundleID) {
                      return true
                  }
                  guard let applicationName = payload.applicationName else { return false }
                  return [$0.applicationName, $0.displayName].contains {
                      applicationName.localizedCaseInsensitiveCompare($0) == .orderedSame
                  }
              }) else {
            DiagnosticStore.shared.recordMediaRemoteInvalid("媒体数据不完整")
            guard playback != nil else { return }
            playback = nil
            onPlaybackChanged?()
            return
        }

        let duration = max(0, (payload.durationMicros ?? 0) / 1_000_000)
        let elapsed = max(
            0,
            payload.currentElapsedTime ?? ((payload.elapsedTimeMicros ?? 0) / 1_000_000)
        )
        let artist = payload.artist ?? "未知歌手"
        let album = payload.album?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let isPlaying = payload.isPlaying ?? ((payload.playbackRate ?? 0) > 0)
        let clampedElapsed = min(elapsed, duration > 0 ? duration : elapsed)

        if let previous = playback,
           previous.provider == provider,
           previous.playback.title == title,
           previous.playback.artist == artist,
           previous.playback.album == album,
           previous.playback.duration == duration,
           previous.playback.isPlaying == isPlaying,
           (previous.playback.artworkData == nil) == (payload.artworkDataBase64?.isEmpty != false),
           abs(previous.playback.elapsed - clampedElapsed) < 1.0 {
            DiagnosticStore.shared.recordMediaRemoteDeduplicated()
            return
        }

        let artworkKey = "\(provider.displayName):\(title):\(artist)"
        let artworkPayload = payload.artworkDataBase64
        let artworkData: Data?
        if cachedArtworkKey == artworkKey, cachedArtworkPayload == artworkPayload {
            DiagnosticStore.shared.recordArtworkCache(hit: true)
            artworkData = cachedArtworkData
        } else {
            DiagnosticStore.shared.recordArtworkCache(hit: false)
            artworkData = artworkPayload.flatMap { Data(base64Encoded: $0) }
            cachedArtworkKey = artworkKey
            cachedArtworkPayload = artworkPayload
            cachedArtworkData = artworkData
        }

        let resolved = MusicPlayback(
            title: title,
            artist: artist,
            album: album,
            isPlaying: isPlaying,
            source: provider.displayName,
            elapsed: clampedElapsed,
            duration: duration,
            artworkData: artworkData,
            artworkURL: nil
        )
        playback = AdapterPlayback(provider: provider, playback: resolved)
        restartAttempt = 0
        DiagnosticStore.shared.recordMediaRemotePublished(provider: provider.displayName)
        onPlaybackChanged?()
    }

    private func updateListener(hasRunningProvider: Bool) {
        let shouldListen = MediaListenerPolicy.shouldListen(
            hasRunningSystemProvider: hasRunningProvider
        )
        guard shouldListen != isListening else { return }
        restartTask?.cancel()
        restartTask = nil
        isListening = shouldListen
        restartAttempt = 0
        if shouldListen {
            startListener()
        } else {
            controller.stopListening()
            DiagnosticStore.shared.recordListenerStopped()
            DiagnosticStore.shared.setActiveProvider(nil)
            playback = nil
            onPlaybackChanged?()
        }
    }

    private func startListener() {
        guard isListening else { return }
        controller.startListening()
        DiagnosticStore.shared.recordListenerStarted()
    }

    private func scheduleRestart() {
        guard isListening,
              providers.contains(where: \.isRunning),
              restartTask == nil else { return }
        let delay = MediaListenerPolicy.retryDelay(forAttempt: restartAttempt)
        restartAttempt += 1
        DiagnosticStore.shared.recordListenerRestart()
        restartTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled, let self else { return }
            self.restartTask = nil
            self.startListener()
        }
    }
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

enum AppleScriptExecutionPolicy {
    static let timeoutSeconds = 8

    static func wrapped(_ source: String) -> String {
        """
        with timeout of \(timeoutSeconds) seconds
        \(source)
        end timeout
        """
    }
}

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
        guard let script = NSAppleScript(source: AppleScriptExecutionPolicy.wrapped(source)) else {
            throw MusicServiceError.script("无法编译播放器自动化脚本")
        }
        let result = script.executeAndReturnError(&error)
        if let error {
            if (error[NSAppleScript.errorNumber] as? Int) == -1712 {
                throw MusicServiceError.timedOut
            }
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
        guard let script = NSAppleScript(
            source: AppleScriptExecutionPolicy.wrapped(source)
        ) else { return nil }
        let result = script.executeAndReturnError(&error)
        guard error == nil, result.descriptorType != 0 else { return nil }
        return result.data
    }
}

enum PlayerCommand: Sendable {
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

enum PlayerProvider: CaseIterable, Hashable, Sendable {
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
