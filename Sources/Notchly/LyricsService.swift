import Foundation

struct TimedLyricLine: Identifiable, Hashable, Sendable {
    let time: TimeInterval
    let text: String

    var id: String { "\(time):\(text)" }
}

actor LyricsService {
    private struct CacheEntry {
        let lines: [TimedLyricLine]
        let expiresAt: Date
    }

    private var cache: [String: CacheEntry] = [:]
    private let successfulCacheLifetime: TimeInterval = 6 * 60 * 60
    private let failedCacheLifetime: TimeInterval = 5 * 60
    private let cacheLimit = 200

    func lyrics(for title: String, artist: String, duration: TimeInterval) async -> [TimedLyricLine] {
        let key = "\(Self.normalized(title))|\(Self.normalized(artist))"
        let now = Date()
        if let cached = cache[key], cached.expiresAt > now { return cached.lines }
        cache[key] = nil

        do {
            let songID = try await searchSongID(title: title, artist: artist, duration: duration)
            let lines = try await fetchLyrics(songID: songID)
            store(lines, for: key, lifetime: successfulCacheLifetime, now: now)
            return lines
        } catch {
            // A transient network failure should not suppress retries for the
            // rest of the app session, while still avoiding repeated requests.
            store([], for: key, lifetime: failedCacheLifetime, now: now)
            return []
        }
    }

    private func store(_ lines: [TimedLyricLine], for key: String, lifetime: TimeInterval, now: Date) {
        cache[key] = CacheEntry(lines: lines, expiresAt: now.addingTimeInterval(lifetime))
        guard cache.count > cacheLimit else { return }
        let keysToRemove = cache
            .sorted { $0.value.expiresAt < $1.value.expiresAt }
            .prefix(cache.count - cacheLimit)
            .map(\.key)
        keysToRemove.forEach { cache[$0] = nil }
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
        let data = try await request(components.url!)
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
        let data = try await request(components.url!)
        let response = try JSONDecoder().decode(LyricResponse.self, from: data)
        guard let source = response.lrc?.lyric else { throw LyricsError.notFound }
        let lines = Self.parseLRC(source)
        guard !lines.isEmpty else { throw LyricsError.notFound }
        return lines
    }

    private func request(_ url: URL) async throws -> Data {
        var request = URLRequest(url: url)
        request.timeoutInterval = 12
        request.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X) Notchly/0.6", forHTTPHeaderField: "User-Agent")
        request.setValue("https://music.163.com/", forHTTPHeaderField: "Referer")
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
        // Keep the source timeline intact. Credit lines such as “作词” and “作曲”
        // are part of the lyrics shown by the desktop player and should appear at
        // their original timestamps here as well.
        return result.sorted { $0.time < $1.time }
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

private enum LyricsError: Error {
    case network
    case notFound
}
