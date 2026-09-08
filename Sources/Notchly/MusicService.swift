import AppKit
import Foundation
import MediaRemoteAdapter

struct MusicPlayback: Sendable {
    let title: String
    let artist: String
    let isPlaying: Bool
    let source: String
    let elapsed: TimeInterval
    let duration: TimeInterval
    let artworkData: Data?
    let artworkURL: URL?
}

@MainActor
final class MusicService {
    private let separator = "\u{001F}"
    private let scriptedProviders: [PlayerProvider] = [.spotify, .music]
    private let systemProviders: [PlayerProvider] = [.netease, .qqMusic, .kugou, .kuwo, .qishui]
    private var activeProvider: PlayerProvider?
    private var cachedArtworkKey: String?
    private var cachedArtworkData: Data?
    private let mediaController: MediaController
    private var systemPlayback: (provider: PlayerProvider, playback: MusicPlayback)?

    init() {
        mediaController = MediaController()
        mediaController.onTrackInfoReceived = { [weak self] trackInfo in
            Task { @MainActor [weak self] in
                self?.receiveSystemTrack(trackInfo)
            }
        }
        mediaController.startListening()
    }

    func snapshot() async throws -> MusicPlayback? {
        if let systemPlayback, systemPlayback.playback.isPlaying {
            activeProvider = systemPlayback.provider
            return systemPlayback.playback
        }

        var pausedScriptedPlayback: MusicPlayback?
        for provider in scriptedProviders where provider.isNativeScriptableRunning {
            let response = try run(provider.snapshotScript(separator: separator))
            guard !response.isEmpty else { continue }
            let fields = response.components(separatedBy: separator)
            guard fields.count == 6 else { throw MusicServiceError.invalidResponse }
            let elapsed = max(0, Double(fields[3]) ?? 0)
            var duration = max(0, Double(fields[4]) ?? 0)
            if provider == .spotify { duration /= 1_000 }
            let artworkKey = "\(provider.bundleIdentifiers.first ?? provider.displayName):\(fields[0]):\(fields[1])"
            if artworkKey != cachedArtworkKey {
                cachedArtworkKey = artworkKey
                cachedArtworkData = provider == .music ? loadAppleMusicArtwork() : nil
            }
            let playback = MusicPlayback(
                title: fields[0],
                artist: fields[1],
                isPlaying: fields[2].lowercased() == "true",
                source: provider.displayName,
                elapsed: min(elapsed, duration > 0 ? duration : elapsed),
                duration: duration,
                artworkData: cachedArtworkData,
                artworkURL: URL(string: fields[5])
            )
            if playback.isPlaying {
                activeProvider = provider
                return playback
            }
            pausedScriptedPlayback = playback
        }

        if let systemPlayback {
            activeProvider = systemPlayback.provider
            return systemPlayback.playback
        }

        if pausedScriptedPlayback != nil {
            activeProvider = scriptedProviders.first(where: \.isNativeScriptableRunning)
        }
        return pausedScriptedPlayback
    }

    func togglePlayback() throws { try perform(.toggle) }
    func previousTrack() throws { try perform(.previous) }
    func nextTrack() throws { try perform(.next) }

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

    private func perform(_ command: PlayerCommand) throws {
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
            _ = try run("tell application \"\(provider.applicationName)\" to \(command.appleScriptCommand)")
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
            return
        }

        let duration = max(0, (payload.durationMicros ?? 0) / 1_000_000)
        let elapsed = max(0, payload.currentElapsedTime ?? ((payload.elapsedTimeMicros ?? 0) / 1_000_000))
        let artworkData = payload.artworkDataBase64.flatMap { Data(base64Encoded: $0) }
        systemPlayback = (provider, MusicPlayback(
            title: title,
            artist: payload.artist ?? "未知歌手",
            isPlaying: payload.isPlaying ?? ((payload.playbackRate ?? 0) > 0),
            source: provider.displayName,
            elapsed: min(elapsed, duration > 0 ? duration : elapsed),
            duration: duration,
            artworkData: artworkData,
            artworkURL: nil
        ))
    }

    private func run(_ source: String) throws -> String {
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

    private func loadAppleMusicArtwork() -> Data? {
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

private enum PlayerCommand {
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

private enum PlayerProvider: Equatable {
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
            set playingNow to (player state is playing) as string
            set trackPosition to (player position) as string
            set trackDuration to (duration of current track) as string
            set artworkLocation to \(artworkExpression)
            return trackName & "\(separator)" & trackArtist & "\(separator)" & playingNow & "\(separator)" & trackPosition & "\(separator)" & trackDuration & "\(separator)" & artworkLocation
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
