import Combine
import Foundation

struct MusicLibraryTrack: Codable, Equatable, Identifiable {
    let id: String
    let title: String
    let artist: String
    let album: String
    let source: String
    let duration: TimeInterval
    let lastPlayedAt: Date
    let playCount: Int

    static func identity(source: String, title: String, artist: String) -> String {
        [source, title, artist]
            .map {
                $0.folding(
                    options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive],
                    locale: .current
                )
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased()
            }
            .joined(separator: "\u{001F}")
    }
}

@MainActor
final class MusicLibraryService: ObservableObject {
    @Published private(set) var recentTracks: [MusicLibraryTrack] = []
    @Published private(set) var favoriteTracks: [MusicLibraryTrack] = []

    private struct StoredLibrary: Codable {
        var recentTracks: [MusicLibraryTrack]
        var favoriteTracks: [MusicLibraryTrack]
    }

    private let storageURL: URL
    private let recentLimit: Int
    private let favoriteLimit: Int

    init(
        storageURL: URL? = nil,
        recentLimit: Int = 50,
        favoriteLimit: Int = 100
    ) {
        self.storageURL = storageURL ?? Self.defaultStorageURL()
        self.recentLimit = max(1, recentLimit)
        self.favoriteLimit = max(1, favoriteLimit)
        load()
    }

    func record(
        title: String,
        artist: String,
        album: String,
        source: String,
        duration: TimeInterval,
        at date: Date = .now
    ) {
        let id = MusicLibraryTrack.identity(source: source, title: title, artist: artist)
        guard !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        let previous = recentTracks.first(where: { $0.id == id })
        let track = MusicLibraryTrack(
            id: id,
            title: title,
            artist: artist,
            album: album,
            source: source,
            duration: max(0, duration),
            lastPlayedAt: date,
            playCount: (previous?.playCount ?? 0) + 1
        )

        recentTracks.removeAll { $0.id == id }
        recentTracks.insert(track, at: 0)
        if recentTracks.count > recentLimit {
            recentTracks.removeLast(recentTracks.count - recentLimit)
        }

        if let favoriteIndex = favoriteTracks.firstIndex(where: { $0.id == id }) {
            let favoriteDate = favoriteTracks[favoriteIndex].lastPlayedAt
            favoriteTracks[favoriteIndex] = MusicLibraryTrack(
                id: track.id,
                title: track.title,
                artist: track.artist,
                album: track.album,
                source: track.source,
                duration: track.duration,
                lastPlayedAt: favoriteDate,
                playCount: track.playCount
            )
        }
        persist()
    }

    func isFavorite(source: String, title: String, artist: String) -> Bool {
        let id = MusicLibraryTrack.identity(source: source, title: title, artist: artist)
        return favoriteTracks.contains { $0.id == id }
    }

    func toggleFavorite(
        title: String,
        artist: String,
        album: String,
        source: String,
        duration: TimeInterval,
        at date: Date = .now
    ) {
        let id = MusicLibraryTrack.identity(source: source, title: title, artist: artist)
        guard !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        if let index = favoriteTracks.firstIndex(where: { $0.id == id }) {
            favoriteTracks.remove(at: index)
        } else {
            let recent = recentTracks.first(where: { $0.id == id })
            favoriteTracks.insert(
                MusicLibraryTrack(
                    id: id,
                    title: title,
                    artist: artist,
                    album: album,
                    source: source,
                    duration: max(0, duration),
                    lastPlayedAt: date,
                    playCount: max(1, recent?.playCount ?? 1)
                ),
                at: 0
            )
            if favoriteTracks.count > favoriteLimit {
                favoriteTracks.removeLast(favoriteTracks.count - favoriteLimit)
            }
        }
        persist()
    }

    func toggleFavorite(_ track: MusicLibraryTrack) {
        toggleFavorite(
            title: track.title,
            artist: track.artist,
            album: track.album,
            source: track.source,
            duration: track.duration,
            at: track.lastPlayedAt
        )
    }

    func clearRecentTracks() {
        recentTracks = []
        persist()
    }

    private func load() {
        guard let data = try? Data(contentsOf: storageURL),
              let library = try? JSONDecoder().decode(StoredLibrary.self, from: data) else { return }
        recentTracks = Array(library.recentTracks.prefix(recentLimit))
        favoriteTracks = Array(library.favoriteTracks.prefix(favoriteLimit))
    }

    private func persist() {
        let library = StoredLibrary(recentTracks: recentTracks, favoriteTracks: favoriteTracks)
        guard let data = try? JSONEncoder().encode(library) else { return }
        do {
            try FileManager.default.createDirectory(
                at: storageURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try data.write(to: storageURL, options: .atomic)
        } catch {
            NSLog("Notchly could not save the local music library: \(error.localizedDescription)")
        }
    }

    private static func defaultStorageURL() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base
            .appendingPathComponent("Notchly", isDirectory: true)
            .appendingPathComponent("music-library.json", isDirectory: false)
    }
}
