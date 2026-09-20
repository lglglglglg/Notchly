import Foundation

struct TimedLyricLine: Identifiable, Hashable, Sendable {
    let time: TimeInterval
    let text: String
    let isCredit: Bool

    init(time: TimeInterval, text: String, isCredit: Bool = false) {
        self.time = time
        self.text = text
        self.isCredit = isCredit
    }

    var id: String { "\(time):\(text)" }
}

enum LyricsCachePolicy {
    static let successLifetime: TimeInterval = 6 * 60 * 60
    static let failureLifetime: TimeInterval = 5 * 60

    static func lifetime(hasLyrics: Bool) -> TimeInterval {
        hasLyrics ? successLifetime : failureLifetime
    }
}

enum LyricSource: String, Sendable {
    case netease = "网易云音乐"
    case lrclib = "LRCLIB"
}

struct LyricsLookupResult: Sendable {
    let lines: [TimedLyricLine]
    let source: LyricSource?

    static let unavailable = LyricsLookupResult(lines: [], source: nil)
}

actor LyricsService {
    private struct CacheEntry {
        let result: LyricsLookupResult
        let expiresAt: Date
    }

    private var cache: [String: CacheEntry] = [:]
    private let cacheLimit = 200

    /// Retrieves timed lyrics in provider priority order. The public NetEase
    /// LRC is preferred for a NetEase playback session; LRCLIB is a sequential
    /// fallback rather than a parallel fan-out, keeping requests small and
    /// making a provider outage indistinguishable from a missing lyric only
    /// after both sources have been tried.
    func lyrics(for title: String, artist: String, duration: TimeInterval) async -> LyricsLookupResult {
        let key = "\(Self.normalized(title))|\(Self.normalized(artist))"
        let now = Date()
        if let cached = cache[key], cached.expiresAt > now { return cached.result }
        cache[key] = nil

        let result: LyricsLookupResult
        if let lines = try? await fetchNetEaseLyrics(title: title, artist: artist, duration: duration), !lines.isEmpty {
            result = LyricsLookupResult(lines: lines, source: .netease)
        } else if let lines = try? await fetchLRCLibLyrics(title: title, artist: artist, duration: duration), !lines.isEmpty {
            result = LyricsLookupResult(lines: lines, source: .lrclib)
        } else {
            result = .unavailable
        }

        // A transient network failure should not suppress retries for the
        // rest of the app session, while still avoiding repeated requests.
        store(result, for: key, lifetime: LyricsCachePolicy.lifetime(hasLyrics: !result.lines.isEmpty), now: now)
        return result
    }

    private func store(_ result: LyricsLookupResult, for key: String, lifetime: TimeInterval, now: Date) {
        cache[key] = CacheEntry(result: result, expiresAt: now.addingTimeInterval(lifetime))
        guard cache.count > cacheLimit else { return }
        let keysToRemove = cache
            .sorted { $0.value.expiresAt < $1.value.expiresAt }
            .prefix(cache.count - cacheLimit)
            .map(\.key)
        keysToRemove.forEach { cache[$0] = nil }
    }

    private func fetchNetEaseLyrics(title: String, artist: String, duration: TimeInterval) async throws -> [TimedLyricLine] {
        let songID = try await searchSongID(title: title, artist: artist, duration: duration)
        return try await fetchLyrics(songID: songID)
    }

    private func searchSongID(title: String, artist: String, duration: TimeInterval) async throws -> Int {
        var components = URLComponents(string: "https://music.163.com/api/search/get/web")!
        components.queryItems = [
            URLQueryItem(name: "s", value: "\(title) \(artist)"),
            URLQueryItem(name: "type", value: "1"),
            URLQueryItem(name: "offset", value: "0"),
            URLQueryItem(name: "total", value: "true"),
            URLQueryItem(name: "limit", value: "8")
        ]
        let data = try await request(components.url!, provider: .netease)
        let response = try JSONDecoder().decode(SearchResponse.self, from: data)
        guard let songs = response.result?.songs, !songs.isEmpty else { throw LyricsError.notFound }

        let expectedTitle = Self.normalized(title)
        let expectedArtist = Self.normalized(artist)
        let best = songs.max { lhs, rhs in
            score(lhs, expectedTitle: expectedTitle, expectedArtist: expectedArtist, duration: duration)
                < score(rhs, expectedTitle: expectedTitle, expectedArtist: expectedArtist, duration: duration)
        }
        guard let best, score(best, expectedTitle: expectedTitle, expectedArtist: expectedArtist, duration: duration) >= 60 else {
            throw LyricsError.notFound
        }
        return best.id
    }

    private func fetchLyrics(songID: Int) async throws -> [TimedLyricLine] {
        var components = URLComponents(string: "https://music.163.com/api/song/lyric")!
        components.queryItems = [
            URLQueryItem(name: "id", value: String(songID)),
            URLQueryItem(name: "lv", value: "1"),
            URLQueryItem(name: "kv", value: "1"),
            URLQueryItem(name: "tv", value: "-1")
        ]
        let data = try await request(components.url!, provider: .netease)
        let response = try JSONDecoder().decode(LyricResponse.self, from: data)
        guard let source = response.lrc?.lyric else { throw LyricsError.notFound }
        let lines = Self.parseLRC(source)
        guard !lines.isEmpty else { throw LyricsError.notFound }
        return lines
    }

    private func fetchLRCLibLyrics(title: String, artist: String, duration: TimeInterval) async throws -> [TimedLyricLine] {
        var components = URLComponents(string: "https://lrclib.net/api/search")!
        components.queryItems = [
            URLQueryItem(name: "track_name", value: title),
            URLQueryItem(name: "artist_name", value: artist)
        ]
        let data = try await request(components.url!, provider: .lrclib)
        let candidates = try JSONDecoder().decode([LRCLibTrack].self, from: data)
        let expectedTitle = Self.normalized(title)
        let expectedArtist = Self.normalized(artist)
        let best = candidates
            .filter { !($0.syncedLyrics?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true) }
            .max { lhs, rhs in
                lrcLibScore(lhs, expectedTitle: expectedTitle, expectedArtist: expectedArtist, duration: duration)
                    < lrcLibScore(rhs, expectedTitle: expectedTitle, expectedArtist: expectedArtist, duration: duration)
            }
        guard let best,
              lrcLibScore(best, expectedTitle: expectedTitle, expectedArtist: expectedArtist, duration: duration) >= 60,
              let source = best.syncedLyrics else {
            throw LyricsError.notFound
        }
        let lines = Self.parseLRC(source)
        guard !lines.isEmpty else { throw LyricsError.notFound }
        return lines
    }

    private func request(_ url: URL, provider: LyricSource) async throws -> Data {
        var request = URLRequest(url: url)
        request.timeoutInterval = 12
        switch provider {
        case .netease:
            request.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X) Notchly/0.13", forHTTPHeaderField: "User-Agent")
            request.setValue("https://music.163.com/", forHTTPHeaderField: "Referer")
        case .lrclib:
            request.setValue("Notchly/0.13 (macOS lyrics companion)", forHTTPHeaderField: "User-Agent")
        }
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw LyricsError.network
        }
        return data
    }

    private func score(
        _ song: SearchSong,
        expectedTitle: String,
        expectedArtist: String,
        duration: TimeInterval
    ) -> Int {
        Self.matchScore(
            candidateTitle: song.name,
            candidateArtist: song.artists.map(\.name).joined(separator: " "),
            expectedTitle: expectedTitle,
            expectedArtist: expectedArtist,
            duration: duration,
            candidateDuration: Double(song.duration) / 1_000
        )
    }

    private func lrcLibScore(
        _ track: LRCLibTrack,
        expectedTitle: String,
        expectedArtist: String,
        duration: TimeInterval
    ) -> Int {
        Self.matchScore(
            candidateTitle: track.trackName,
            candidateArtist: track.artistName,
            expectedTitle: expectedTitle,
            expectedArtist: expectedArtist,
            duration: duration,
            candidateDuration: track.duration ?? 0
        )
    }

    nonisolated static func matchScore(
        candidateTitle: String,
        candidateArtist: String,
        expectedTitle: String,
        expectedArtist: String,
        duration: TimeInterval,
        candidateDuration: TimeInterval
    ) -> Int {
        let candidateTitle = normalized(candidateTitle)
        let candidateArtists = normalized(candidateArtist)
        let expectedTitle = normalized(expectedTitle)
        let expectedArtist = normalized(expectedArtist)
        var value = candidateTitle == expectedTitle ? 80 : (candidateTitle.contains(expectedTitle) || expectedTitle.contains(candidateTitle) ? 45 : 0)
        if !expectedArtist.isEmpty, candidateArtists.contains(expectedArtist) || expectedArtist.contains(candidateArtists) { value += 35 }
        if duration > 0, abs(candidateDuration - duration) < 4 { value += 20 }
        return value
    }

    nonisolated private static func normalized(_ value: String) -> String {
        value.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: .current)
            .replacingOccurrences(of: #"[\s\p{P}\p{S}]"#, with: "", options: .regularExpression)
            .lowercased()
    }

    nonisolated static func parseLRC(_ source: String) -> [TimedLyricLine] {
        let pattern = #"\[(\d{1,3}):(\d{2})(?:[\.:](\d{1,3}))?\]"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        var result: [TimedLyricLine] = []

        for rawLine in source.components(separatedBy: .newlines) {
            let range = NSRange(rawLine.startIndex..<rawLine.endIndex, in: rawLine)
            let matches = regex.matches(in: rawLine, range: range)
            guard !matches.isEmpty, let finalRange = matches.last?.range,
                  let textStart = Range(finalRange, in: rawLine)?.upperBound else { continue }
            let text = rawLine[textStart...].trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }

            for match in matches {
                guard let minuteRange = Range(match.range(at: 1), in: rawLine),
                      let secondRange = Range(match.range(at: 2), in: rawLine),
                      let minutes = Double(rawLine[minuteRange]),
                      let seconds = Double(rawLine[secondRange]) else { continue }
                var fraction = 0.0
                if match.range(at: 3).location != NSNotFound,
                   let fractionRange = Range(match.range(at: 3), in: rawLine) {
                    let digits = String(rawLine[fractionRange])
                    fraction = (Double(digits) ?? 0) / pow(10, Double(digits.count))
                }
                result.append(TimedLyricLine(time: minutes * 60 + seconds + fraction, text: text))
            }
        }
        let timeline = result.enumerated()
            .sorted { lhs, rhs in
                lhs.element.time == rhs.element.time ? lhs.offset < rhs.offset : lhs.element.time < rhs.element.time
            }
            .map(\.element)
        return distributeIntroCredits(in: timeline)
    }

    /// NetEase commonly assigns every credit the same 00:00 timestamp. Showing
    /// only the last one for a fraction of a second makes credits appear lost.
    /// Space that opening group across the instrumental intro so every source
    /// line remains part of the lyric timeline before the first vocal line.
    nonisolated private static func distributeIntroCredits(in timeline: [TimedLyricLine]) -> [TimedLyricLine] {
        guard let firstVocal = timeline.first(where: { !$0.isCredit && !isCredit($0.text) && $0.time > 0.2 }) else {
            return timeline
        }
        let introCreditIndexes = timeline.indices.filter {
            timeline[$0].time <= 0.2 && isCredit(timeline[$0].text)
        }
        guard !introCreditIndexes.isEmpty else { return timeline }

        let slot = min(4, max(0.3, firstVocal.time / Double(introCreditIndexes.count)))
        var creditOrder = 0
        return timeline.enumerated().map { index, line in
            guard introCreditIndexes.contains(index) else { return line }
            defer { creditOrder += 1 }
            return TimedLyricLine(time: Double(creditOrder) * slot, text: line.text, isCredit: true)
        }
    }

    nonisolated private static func isCredit(_ text: String) -> Bool {
        let compact = text
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: " ", with: "")
            .lowercased()
        let prefixes = [
            "作词", "填词", "作曲", "编曲", "制作", "监制", "出品", "录音", "混音", "母带",
            "和声", "吉他", "贝斯", "键盘", "鼓", "词:", "曲:", "lyrics", "composer", "arranger", "producer"
        ]
        return prefixes.contains { compact.hasPrefix($0) }
    }
}

private struct SearchResponse: Decodable {
    let result: SearchResult?
}

private struct SearchResult: Decodable {
    let songs: [SearchSong]?
}

private struct SearchSong: Decodable {
    let id: Int
    let name: String
    let duration: Int
    let artists: [SearchArtist]
}

private struct SearchArtist: Decodable {
    let name: String
}

private struct LyricResponse: Decodable {
    let lrc: LyricPayload?
}

private struct LyricPayload: Decodable {
    let lyric: String?
}

private struct LRCLibTrack: Decodable {
    let trackName: String
    let artistName: String
    let duration: TimeInterval?
    let syncedLyrics: String?
}

private enum LyricsError: Error {
    case network
    case notFound
}
