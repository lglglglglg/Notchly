import AppKit
import Foundation

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

enum MediaListenerPolicy {
    static func shouldListen(hasRunningSystemProvider: Bool) -> Bool {
        hasRunningSystemProvider
    }

    static func retryDelay(forAttempt attempt: Int) -> TimeInterval {
        min(30, pow(2, Double(max(0, attempt))))
    }
}

enum MusicPlaybackSelectionPolicy {
    static func preferred(
        system: AdapterPlayback?,
        scripted: AdapterPlayback?
    ) -> (playback: AdapterPlayback, adapter: MusicAdapterID)? {
        if let system, system.playback.isPlaying {
            return (system, .mediaRemote)
        }
        if let scripted {
            return (scripted, .appleScript)
        }
        if let system {
            return (system, .mediaRemote)
        }
        return nil
    }
}

enum MusicAdapterFallbackPolicy {
    static func afterScriptFailure(
        system: AdapterPlayback?
    ) -> (playback: AdapterPlayback, adapter: MusicAdapterID)? {
        guard let system else { return nil }
        return (system, .mediaRemote)
    }
}

struct MusicAdapterCircuitBreaker: Equatable, Sendable {
    private(set) var consecutiveFailures = 0
    private(set) var retryAfter: Date?

    func shouldAttempt(at date: Date = Date()) -> Bool {
        guard let retryAfter else { return true }
        return date >= retryAfter
    }

    mutating func recordSuccess() {
        consecutiveFailures = 0
        retryAfter = nil
    }

    mutating func recordFailure(at date: Date = Date()) {
        consecutiveFailures += 1
        let delay = Self.cooldownDuration(forConsecutiveFailures: consecutiveFailures)
        retryAfter = delay > 0 ? date.addingTimeInterval(delay) : nil
    }

    static func cooldownDuration(forConsecutiveFailures failures: Int) -> TimeInterval {
        switch max(0, failures) {
        case 0, 1: 0
        case 2: 5
        case 3: 15
        case 4: 30
        default: 60
        }
    }
}

@MainActor
final class MusicService {
    /// MediaRemote pushes its first update independently of the periodic
    /// snapshot timer. Forward it immediately so a newly opened supported
    /// player does not leave the island in its placeholder state.
    var onSystemPlaybackChanged: (@MainActor () -> Void)?

    private let scriptedAdapter: AppleScriptPlayerAdapter
    private let systemAdapter: MediaRemotePlayerAdapter
    private let adapters: [any MusicPlayerAdapter]
    private var activeProvider: PlayerProvider?
    private var scriptedCircuitBreaker = MusicAdapterCircuitBreaker()

    init() {
        let scriptedAdapter = AppleScriptPlayerAdapter()
        let systemAdapter = MediaRemotePlayerAdapter()
        self.scriptedAdapter = scriptedAdapter
        self.systemAdapter = systemAdapter
        adapters = [scriptedAdapter, systemAdapter]
        systemAdapter.onPlaybackChanged = { [weak self] in
            self?.onSystemPlaybackChanged?()
        }
    }

    func shutdown() {
        adapters.forEach { $0.shutdown() }
        onSystemPlaybackChanged = nil
        activeProvider = nil
    }

    func snapshot() async throws -> MusicPlayback? {
        DiagnosticStore.shared.recordMusicSnapshotRequest()

        if let system = systemAdapter.currentPlayback, system.playback.isPlaying {
            return select(system, adapter: .mediaRemote)
        }

        let now = Date()
        if !scriptedCircuitBreaker.shouldAttempt(at: now),
           let retryAfter = scriptedCircuitBreaker.retryAfter {
            DiagnosticStore.shared.recordAdapterSuppressed(
                .appleScript,
                until: retryAfter
            )
            return selectSystemFallback(recordFallback: false)
        }

        DiagnosticStore.shared.recordAdapterAttempt(.appleScript)
        let scripted: AdapterPlayback?
        do {
            scripted = try await scriptedAdapter.snapshot()
            scriptedCircuitBreaker.recordSuccess()
            DiagnosticStore.shared.recordAdapterSuccess(.appleScript)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            // Start cooldown when the failed call returns. A timeout can itself
            // consume several seconds, so using the pre-call timestamp would
            // make the first cooldown expire before it is ever observed.
            scriptedCircuitBreaker.recordFailure()
            DiagnosticStore.shared.recordAdapterFailure(.appleScript, error: error)
            DiagnosticStore.shared.recordAdapterCooldown(
                .appleScript,
                until: scriptedCircuitBreaker.retryAfter
            )
            if let fallback = selectSystemFallback(recordFallback: true) { return fallback }
            throw error
        }

        // A MediaRemote event can arrive while AppleScript is running. Keep
        // the existing policy that an actively playing system provider wins.
        let preferred = MusicPlaybackSelectionPolicy.preferred(
            system: systemAdapter.currentPlayback,
            scripted: scripted
        )
        if let preferred {
            return select(preferred.playback, adapter: preferred.adapter)
        }

        activeProvider = nil
        DiagnosticStore.shared.setActiveProvider(nil)
        return nil
    }

    private func selectSystemFallback(recordFallback: Bool) -> MusicPlayback? {
        guard let fallback = MusicAdapterFallbackPolicy.afterScriptFailure(
            system: systemAdapter.currentPlayback
        ) else {
            activeProvider = nil
            DiagnosticStore.shared.setActiveProvider(nil)
            return nil
        }
        if recordFallback {
            DiagnosticStore.shared.recordAdapterFallback(from: .appleScript)
        }
        return select(fallback.playback, adapter: fallback.adapter)
    }

    func togglePlayback() async throws { try await perform(.toggle) }
    func previousTrack() async throws { try await perform(.previous) }
    func nextTrack() async throws { try await perform(.next) }

    func openActivePlayer() {
        let provider = activeProvider
            ?? MusicPlayerAdapterRegistry.registrations
                .flatMap(\.providers)
                .first(where: \.isRunning)
        guard let provider else { return }
        for bundleIdentifier in provider.bundleIdentifiers {
            guard let url = NSWorkspace.shared.urlForApplication(
                withBundleIdentifier: bundleIdentifier
            ) else { continue }
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.activates = true
            NSWorkspace.shared.openApplication(at: url, configuration: configuration)
            return
        }
    }

    private func select(
        _ candidate: AdapterPlayback,
        adapter: MusicAdapterID
    ) -> MusicPlayback {
        activeProvider = candidate.provider
        DiagnosticStore.shared.recordMusicSnapshotSuccess(
            provider: candidate.provider.displayName,
            adapter: adapter.title
        )
        return candidate.playback
    }

    private func perform(_ command: PlayerCommand) async throws {
        let provider = activeProvider.flatMap { $0.isRunning ? $0 : nil }
            ?? MusicPlayerAdapterRegistry.registrations
                .flatMap(\.providers)
                .first(where: \.isRunning)
        guard let provider,
              let adapter = adapters.first(where: { $0.providers.contains(provider) }) else {
            throw MusicServiceError.notRunning
        }
        try await adapter.perform(command, provider: provider)
    }
}

enum MusicServiceError: LocalizedError {
    case notRunning
    case invalidResponse
    case script(String)
    case timedOut

    var errorDescription: String? {
        switch self {
        case .notRunning: "播放器未运行"
        case .invalidResponse: "播放器返回了无法识别的信息"
        case let .script(message): message
        case .timedOut: "播放器自动化调用超时"
        }
    }
}
