import XCTest
@testable import Notchly

final class NotchlyCoreTests: XCTestCase {
    func testLRCParserExpandsMultipleTimestampsAndKeepsTimelineOrder() {
        let lines = LyricsService.parseLRC("""
        [00:02.50][00:01.20]第一句
        [01:03.005]第二句
        [ar:Notchly]
        """)

        XCTAssertEqual(lines.map(\.text), ["第一句", "第一句", "第二句"])
        XCTAssertEqual(lines.map(\.time), [1.2, 2.5, 63.005])
    }

    func testLRCParserKeepsAndSequencesIntroCreditsBeforeFirstVocal() {
        let lines = LyricsService.parseLRC("""
        [00:00.00]作词：崔惟楷
        [00:00.00]作曲：Alexander Bard
        [00:00.00]编曲：林迈可
        [00:12.00]天空的雾来得漫不经心
        """)

        XCTAssertEqual(lines.map(\.text), ["作词：崔惟楷", "作曲：Alexander Bard", "编曲：林迈可", "天空的雾来得漫不经心"])
        XCTAssertEqual(lines.map(\.time), [0, 4, 8, 12])
        XCTAssertEqual(lines.prefix(3).map(\.isCredit), [true, true, true])
        XCTAssertFalse(lines[3].isCredit)
    }

    func testPocketStoragePolicyAppliesCapacityAndDuplicateRules() {
        XCTAssertEqual(PocketStoragePolicy.storageSummary(usedBytes: 0, capacityMB: 512), "0 KB / 512 MB")
        XCTAssertTrue(PocketStoragePolicy.canStore(incomingBytes: 128, usedBytes: 512, capacityMB: 1))
        XCTAssertFalse(PocketStoragePolicy.canStore(incomingBytes: 600_000, usedBytes: 512_000, capacityMB: 1))
        XCTAssertFalse(PocketStoragePolicy.canStore(incomingBytes: 1, usedBytes: 1_048_576, capacityMB: 1))
        XCTAssertFalse(PocketStoragePolicy.canStore(incomingBytes: -1, usedBytes: 0, capacityMB: 1))
        XCTAssertEqual(
            PocketStoragePolicy.uniqueFilename(
                for: "demo.pdf",
                existingNames: ["demo.pdf", "demo (2).pdf"]
            ),
            "demo (3).pdf"
        )
        XCTAssertEqual(
            PocketStoragePolicy.uniqueFilename(for: "README", existingNames: ["README"]),
            "README (2)"
        )
    }

    func testTrackMatchScoreFavorsExactTitleArtistAndDuration() {
        let exact = LyricsService.matchScore(
            candidateTitle: "晚安，世界",
            candidateArtist: "Notchly",
            expectedTitle: "晚安世界",
            expectedArtist: "notchly",
            duration: 180,
            candidateDuration: 181
        )
        let partial = LyricsService.matchScore(
            candidateTitle: "晚安世界（Live）",
            candidateArtist: "另一位歌手",
            expectedTitle: "晚安世界",
            expectedArtist: "Notchly",
            duration: 180,
            candidateDuration: 250
        )

        XCTAssertEqual(exact, 135)
        XCTAssertLessThan(partial, 60)
    }

    func testAdaptiveRefreshPolicyPrioritizesInteractivePlayback() {
        XCTAssertEqual(
            IslandRefreshPolicy.musicInterval(
                isExpanded: false,
                isPlaying: false,
                showsDesktopLyrics: false,
                hasMusic: false
            ),
            15
        )
        XCTAssertEqual(
            IslandRefreshPolicy.musicInterval(
                isExpanded: false,
                isPlaying: false,
                showsDesktopLyrics: false,
                hasMusic: true
            ),
            6
        )
        XCTAssertEqual(
            IslandRefreshPolicy.musicInterval(
                isExpanded: false,
                isPlaying: true,
                showsDesktopLyrics: false,
                hasMusic: true
            ),
            2
        )
        XCTAssertEqual(IslandRefreshPolicy.powerInterval(isExpanded: false), 60)
        XCTAssertEqual(IslandRefreshPolicy.powerInterval(isExpanded: true), 30)
    }

    func testMediaListenerOnlyRunsForSupportedSystemPlayersAndBacksOff() {
        XCTAssertFalse(MediaListenerPolicy.shouldListen(hasRunningSystemProvider: false))
        XCTAssertTrue(MediaListenerPolicy.shouldListen(hasRunningSystemProvider: true))
        XCTAssertEqual(MediaListenerPolicy.retryDelay(forAttempt: 0), 1)
        XCTAssertEqual(MediaListenerPolicy.retryDelay(forAttempt: 4), 16)
        XCTAssertEqual(MediaListenerPolicy.retryDelay(forAttempt: 12), 30)
    }

    func testLyricsCacheKeepsFailuresBriefAndSuccessfulResultsLonger() {
        XCTAssertEqual(LyricsCachePolicy.lifetime(hasLyrics: false), 5 * 60)
        XCTAssertEqual(LyricsCachePolicy.lifetime(hasLyrics: true), 6 * 60 * 60)
    }

    func testLyricSyncCalibrationUsesHalfSecondStepsAndStaysBounded() {
        XCTAssertEqual(LyricSyncPolicy.adjustedOffset(0, by: 0.5), 0.5)
        XCTAssertEqual(LyricSyncPolicy.adjustedOffset(2.8, by: 0.5), 3)
        XCTAssertEqual(LyricSyncPolicy.adjustedOffset(-2.8, by: -0.5), -3)
    }

    func testTimeGreetingMatchesDayPeriods() {
        XCTAssertEqual(TimeGreetingPolicy.message(hour: 7), "早上好，新的一天慢慢来。")
        XCTAssertEqual(TimeGreetingPolicy.message(hour: 10), "上午好，记得喝口水。")
        XCTAssertEqual(TimeGreetingPolicy.message(hour: 14), "下午好，忙里也要休息片刻。")
        XCTAssertEqual(TimeGreetingPolicy.message(hour: 20), "晚上好，愿你享受此刻。")
        XCTAssertEqual(TimeGreetingPolicy.message(hour: 1), "夜深了，早点睡觉。")
    }

    func testMusicRefreshGateCoalescesStalledSnapshots() {
        var gate = MusicRefreshGate()
        XCTAssertTrue(gate.begin())
        XCTAssertFalse(gate.begin())
        XCTAssertFalse(gate.begin())
        XCTAssertTrue(gate.finish())
        XCTAssertTrue(gate.begin())
        XCTAssertFalse(gate.finish())
    }

    func testExpandedNotchLayoutReservesCameraAreaWithoutTallEmptyHeader() {
        XCTAssertEqual(NotchLayoutPolicy.expandedContentTopInset(notchHeight: 32), 36)
        XCTAssertEqual(NotchLayoutPolicy.expandedContentTopInset(notchHeight: 48), 52)
        XCTAssertEqual(
            NotchLayoutPolicy.expandedShoulderRadius(notchHeight: 32, containerHeight: 222),
            32,
            accuracy: 0.001
        )
        XCTAssertEqual(NotchLayoutPolicy.compactWingWidth(hasMusic: false, isPomodoroRunning: false), 48)
        XCTAssertEqual(NotchLayoutPolicy.compactWingWidth(hasMusic: true, isPomodoroRunning: true), 72)
    }

    @MainActor
    func testFocusTimerRestorationRoundsUpAndStopsAtZero() {
        let now = Date(timeIntervalSinceReferenceDate: 1_000)
        XCTAssertEqual(IslandState.remainingSeconds(until: now.addingTimeInterval(0.1), now: now), 1)
        XCTAssertEqual(IslandState.remainingSeconds(until: now.addingTimeInterval(-1), now: now), 0)
    }
}
