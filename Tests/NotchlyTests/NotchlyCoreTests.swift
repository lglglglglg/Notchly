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

    func testTranslatedLyricsAlignByTimestampWithoutChangingOriginalTimeline() {
        let original = LyricsService.parseLRC("""
        [00:10.00]Hello world
        [00:14.50]Stay with me
        [00:20.00]Original only
        """)
        let translated = LyricsService.parseLRC("""
        [00:10.12]你好，世界
        [00:14.48]陪在我身边
        [00:21.00]时间相差太远
        """)

        let merged = LyricsService.mergingTranslations(into: original, from: translated)

        XCTAssertEqual(merged.map(\.time), original.map(\.time))
        XCTAssertEqual(merged[0].translation, "你好，世界")
        XCTAssertEqual(merged[1].translation, "陪在我身边")
        XCTAssertNil(merged[2].translation)
    }

    func testTranslatedLyricsIgnoreDuplicateOriginalText() {
        let original = [TimedLyricLine(time: 3, text: "Same line")]
        let translated = [TimedLyricLine(time: 3, text: " same line ")]

        let merged = LyricsService.mergingTranslations(into: original, from: translated)

        XCTAssertNil(merged[0].translation)
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

    func testBatteryLevelToneUsesWarningAndCriticalThresholds() {
        XCTAssertEqual(BatteryLevelPolicy.tone(for: nil), .normal)
        XCTAssertEqual(BatteryLevelPolicy.tone(for: 100), .normal)
        XCTAssertEqual(BatteryLevelPolicy.tone(for: 21), .normal)
        XCTAssertEqual(BatteryLevelPolicy.tone(for: 20), .warning)
        XCTAssertEqual(BatteryLevelPolicy.tone(for: 11), .warning)
        XCTAssertEqual(BatteryLevelPolicy.tone(for: 10), .critical)
        XCTAssertEqual(BatteryLevelPolicy.tone(for: 0), .critical)
    }

    func testBatterySymbolDistinguishesChargingExternalPowerAndBatteryUse() {
        XCTAssertEqual(
            BatterySymbolPolicy.symbol(level: 72, connectionState: .charging),
            "battery.100percent.bolt"
        )
        XCTAssertEqual(
            BatterySymbolPolicy.symbol(level: 100, connectionState: .externalPower),
            "powerplug.fill"
        )
        XCTAssertEqual(
            BatterySymbolPolicy.symbol(level: 80, connectionState: .battery),
            "battery.100percent"
        )
        XCTAssertEqual(
            BatterySymbolPolicy.symbol(level: 18, connectionState: .battery),
            "battery.25percent"
        )
    }

    func testCalendarUrgencyHighlightsOnlyUpcomingTwoHourWindow() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        XCTAssertFalse(CalendarUrgencyPolicy.isImminent(startDate: nil, now: now))
        XCTAssertFalse(CalendarUrgencyPolicy.isImminent(startDate: now.addingTimeInterval(-1), now: now))
        XCTAssertTrue(CalendarUrgencyPolicy.isImminent(startDate: now.addingTimeInterval(60), now: now))
        XCTAssertTrue(CalendarUrgencyPolicy.isImminent(startDate: now.addingTimeInterval(7_200), now: now))
        XCTAssertFalse(CalendarUrgencyPolicy.isImminent(startDate: now.addingTimeInterval(7_201), now: now))
    }

    func testPowerSavingSceneReducesOptionalWorkAndRefreshFrequency() throws {
        let configuration = try XCTUnwrap(IslandScenePreset.powerSaving.configuration)
        XCTAssertEqual(configuration.compactDisplayMode, .minimal)
        XCTAssertFalse(configuration.showsDesktopLyrics)
        XCTAssertEqual(configuration.enabledCards, IslandCardRegistry.requiredIDs)
        XCTAssertEqual(
            IslandRefreshPolicy.musicInterval(
                isExpanded: false,
                isPlaying: false,
                showsDesktopLyrics: false,
                hasMusic: false,
                prefersEfficiency: true
            ),
            30
        )
        XCTAssertEqual(
            IslandRefreshPolicy.musicInterval(
                isExpanded: false,
                isPlaying: true,
                showsDesktopLyrics: false,
                hasMusic: true,
                prefersEfficiency: true
            ),
            4
        )
    }

    func testScenePresetsHaveCompleteDeterministicConfigurations() throws {
        XCTAssertEqual(CompactDisplayMode.allCases, [.smart, .time, .minimal])
        XCTAssertNil(CompactDisplayMode(rawValue: "lyrics"))
        XCTAssertNil(IslandScenePreset.custom.configuration)

        let work = try XCTUnwrap(IslandScenePreset.work.configuration)
        XCTAssertEqual(work.compactDisplayMode, .smart)
        XCTAssertEqual(work.enabledCards, IslandCardRegistry.requiredIDs)
        XCTAssertFalse(work.showsDesktopLyrics)

        let music = try XCTUnwrap(IslandScenePreset.music.configuration)
        XCTAssertEqual(music.compactDisplayMode, .smart)
        XCTAssertTrue(music.showsDesktopLyrics)

        let presentation = try XCTUnwrap(IslandScenePreset.presentation.configuration)
        XCTAssertFalse(presentation.expandsOnHover)
        XCTAssertTrue(presentation.hidesIslandInFullScreen)
        XCTAssertEqual(presentation.enabledCards, IslandCardRegistry.requiredIDs)
    }

    func testIslandWindowPolicyHidesFromFullScreenSpacesByDefault() {
        let hidden = IslandWindowPolicy.collectionBehavior(hidesInFullScreen: true)
        XCTAssertTrue(hidden.contains(.canJoinAllSpaces))
        XCTAssertTrue(hidden.contains(.transient))
        XCTAssertTrue(hidden.contains(.fullScreenNone))
        XCTAssertFalse(hidden.contains(.fullScreenAuxiliary))

        let visible = IslandWindowPolicy.collectionBehavior(hidesInFullScreen: false)
        XCTAssertTrue(visible.contains(.canJoinAllSpaces))
        XCTAssertTrue(visible.contains(.fullScreenAuxiliary))
        XCTAssertFalse(visible.contains(.fullScreenNone))
    }

    @MainActor
    func testMusicLibraryKeepsBoundedRecentTracksAndPersistsFavorites() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("NotchlyMusicLibraryTests-\(UUID().uuidString)", isDirectory: true)
        let storageURL = directory.appendingPathComponent("library.json")
        defer { try? FileManager.default.removeItem(at: directory) }

        let library = MusicLibraryService(storageURL: storageURL, recentLimit: 2, favoriteLimit: 2)
        library.record(title: "First", artist: "Singer", album: "A", source: "Player", duration: 180)
        library.record(title: "Second", artist: "Singer", album: "B", source: "Player", duration: 200)
        library.record(title: "Third", artist: "Singer", album: "C", source: "Player", duration: 220)

        XCTAssertEqual(library.recentTracks.map(\.title), ["Third", "Second"])
        XCTAssertEqual(library.recentTracks.count, 2)

        let favorite = library.recentTracks[0]
        library.toggleFavorite(favorite)
        XCTAssertTrue(library.isFavorite(source: favorite.source, title: favorite.title, artist: favorite.artist))

        let restored = MusicLibraryService(storageURL: storageURL, recentLimit: 2, favoriteLimit: 2)
        XCTAssertEqual(restored.recentTracks.map(\.title), ["Third", "Second"])
        XCTAssertEqual(restored.favoriteTracks.map(\.title), ["Third"])

        restored.clearRecentTracks()
        XCTAssertTrue(restored.recentTracks.isEmpty)
        XCTAssertEqual(restored.favoriteTracks.map(\.title), ["Third"])
    }

    func testMusicLibraryIdentityNormalizesCaseWidthAndWhitespace() {
        XCTAssertEqual(
            MusicLibraryTrack.identity(source: " Spotify ", title: "HELLO", artist: "Singer"),
            MusicLibraryTrack.identity(source: "spotify", title: "hello", artist: "singer")
        )
    }

    func testMediaListenerOnlyRunsForSupportedSystemPlayersAndBacksOff() {
        XCTAssertFalse(MediaListenerPolicy.shouldListen(hasRunningSystemProvider: false))
        XCTAssertTrue(MediaListenerPolicy.shouldListen(hasRunningSystemProvider: true))
        XCTAssertEqual(MediaListenerPolicy.retryDelay(forAttempt: 0), 1)
        XCTAssertEqual(MediaListenerPolicy.retryDelay(forAttempt: 4), 16)
        XCTAssertEqual(MediaListenerPolicy.retryDelay(forAttempt: 12), 30)
    }

    func testMusicAdapterRegistryAssignsEveryProviderExactlyOnce() {
        let registeredProviders = MusicPlayerAdapterRegistry.registrations.flatMap(\.providers)
        XCTAssertEqual(registeredProviders.count, PlayerProvider.allCases.count)
        XCTAssertEqual(Set(registeredProviders), Set(PlayerProvider.allCases))

        let appleScript = MusicPlayerAdapterRegistry.registration(for: .music)
        XCTAssertEqual(appleScript?.id, .appleScript)
        XCTAssertEqual(appleScript?.providers, [.spotify, .music])
        XCTAssertEqual(appleScript?.usesDocumentedAPI, true)

        let mediaRemote = MusicPlayerAdapterRegistry.registration(for: .netease)
        XCTAssertEqual(mediaRemote?.id, .mediaRemote)
        XCTAssertEqual(mediaRemote?.usesDocumentedAPI, false)
    }

    func testMusicSelectionKeepsExistingProviderPriority() throws {
        let scripted = AdapterPlayback(
            provider: .music,
            playback: testPlayback(source: "Apple Music", isPlaying: true)
        )
        let systemPlaying = AdapterPlayback(
            provider: .netease,
            playback: testPlayback(source: "网易云音乐", isPlaying: true)
        )
        let systemPaused = AdapterPlayback(
            provider: .netease,
            playback: testPlayback(source: "网易云音乐", isPlaying: false)
        )

        let activeSystem = try XCTUnwrap(MusicPlaybackSelectionPolicy.preferred(
            system: systemPlaying,
            scripted: scripted
        ))
        XCTAssertEqual(activeSystem.adapter, .mediaRemote)
        XCTAssertEqual(activeSystem.playback.provider, .netease)

        let publicFallback = try XCTUnwrap(MusicPlaybackSelectionPolicy.preferred(
            system: systemPaused,
            scripted: scripted
        ))
        XCTAssertEqual(publicFallback.adapter, .appleScript)
        XCTAssertEqual(publicFallback.playback.provider, .music)
    }

    func testMusicAdapterFallbackUsesCachedSystemPlaybackAfterScriptFailure() throws {
        let systemPaused = AdapterPlayback(
            provider: .netease,
            playback: testPlayback(source: "网易云音乐", isPlaying: false)
        )

        let fallback = try XCTUnwrap(MusicAdapterFallbackPolicy.afterScriptFailure(
            system: systemPaused
        ))
        XCTAssertEqual(fallback.adapter, .mediaRemote)
        XCTAssertEqual(fallback.playback.provider, .netease)
        XCTAssertNil(MusicAdapterFallbackPolicy.afterScriptFailure(system: nil))
    }

    func testMusicAdapterHealthTracksRecoveryAndFallbacks() {
        var health = MusicAdapterHealth()
        let firstFailure = Date(timeIntervalSince1970: 10)
        let recovery = Date(timeIntervalSince1970: 20)

        health.recordAttempt()
        health.recordFailure(.automation, at: firstFailure)
        health.recordFallback()
        health.recordCooldown(until: recovery)
        health.recordSuppressed(until: recovery)
        XCTAssertEqual(health.attempts, 1)
        XCTAssertEqual(health.failures, 1)
        XCTAssertEqual(health.consecutiveFailures, 1)
        XCTAssertEqual(health.fallbacks, 1)
        XCTAssertEqual(health.suppressedAttempts, 1)
        XCTAssertEqual(health.cooldownUntil, recovery)
        XCTAssertEqual(health.lastFailureKind, .automation)

        health.recordAttempt()
        health.recordSuccess(at: recovery)
        XCTAssertEqual(health.successes, 1)
        XCTAssertEqual(health.consecutiveFailures, 0)
        XCTAssertEqual(health.lastSuccessAt, recovery)
        XCTAssertNil(health.cooldownUntil)
    }

    func testMusicAdapterFailureClassificationDoesNotExposeScriptDetails() {
        XCTAssertEqual(
            MusicAdapterFailureClassifier.classify(MusicServiceError.script("private detail")),
            .automation
        )
        XCTAssertEqual(
            MusicAdapterFailureClassifier.classify(MusicServiceError.invalidResponse),
            .invalidResponse
        )
        XCTAssertEqual(
            MusicAdapterFailureClassifier.classify(MusicServiceError.timedOut),
            .timeout
        )
    }

    func testMusicAdapterCircuitBreakerUsesBoundedCooldownAndRecovers() {
        let start = Date(timeIntervalSince1970: 100)
        var breaker = MusicAdapterCircuitBreaker()

        breaker.recordFailure(at: start)
        XCTAssertTrue(breaker.shouldAttempt(at: start))
        breaker.recordFailure(at: start)
        XCTAssertFalse(breaker.shouldAttempt(at: start.addingTimeInterval(4)))
        XCTAssertTrue(breaker.shouldAttempt(at: start.addingTimeInterval(5)))

        breaker.recordFailure(at: start)
        XCTAssertEqual(breaker.retryAfter, start.addingTimeInterval(15))
        XCTAssertEqual(
            MusicAdapterCircuitBreaker.cooldownDuration(forConsecutiveFailures: 20),
            60
        )

        breaker.recordSuccess()
        XCTAssertEqual(breaker.consecutiveFailures, 0)
        XCTAssertNil(breaker.retryAfter)
        XCTAssertTrue(breaker.shouldAttempt(at: start))
    }

    func testAppleScriptExecutionPolicyAddsFiniteTimeout() {
        let wrapped = AppleScriptExecutionPolicy.wrapped("return \"ok\"")
        XCTAssertTrue(wrapped.contains("with timeout of 8 seconds"))
        XCTAssertTrue(wrapped.contains("return \"ok\""))
        XCTAssertTrue(wrapped.contains("end timeout"))
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

    func testDesktopLyricsLayoutMigratesLegacyDoubleLinePreference() {
        XCTAssertEqual(
            DesktopLyricsLayoutMode.resolved(savedValue: "alternatingKTV", legacyShowsNextLine: false),
            .alternatingKTV
        )
        XCTAssertEqual(DesktopLyricsLayoutMode.resolved(savedValue: nil, legacyShowsNextLine: false), .single)
        XCTAssertEqual(DesktopLyricsLayoutMode.resolved(savedValue: nil, legacyShowsNextLine: true), .stackedCentered)
        XCTAssertEqual(DesktopLyricsLayoutMode.resolved(savedValue: nil, legacyShowsNextLine: nil), .stackedCentered)
    }

    func testDesktopLyricsKTVAlternatesWithoutMovingThePromotedLine() {
        let even = DesktopLyricsLanePolicy.lanes(current: "A", next: "B", currentIndex: 0)
        XCTAssertEqual(even, DesktopLyricsKTVLanes(topText: "A", bottomText: "B", currentIsTop: true))

        let odd = DesktopLyricsLanePolicy.lanes(current: "B", next: "C", currentIndex: 1)
        XCTAssertEqual(odd, DesktopLyricsKTVLanes(topText: "C", bottomText: "B", currentIsTop: false))
        XCTAssertEqual(even.bottomText, odd.bottomText)
    }

    func testTimeGreetingMatchesDayPeriods() {
        XCTAssertEqual(TimeGreetingPolicy.message(hour: 7), "早上好，新的一天慢慢来。")
        XCTAssertEqual(TimeGreetingPolicy.message(hour: 10), "上午好，记得喝口水。")
        XCTAssertEqual(TimeGreetingPolicy.message(hour: 14), "下午好，忙里也要休息片刻。")
        XCTAssertEqual(TimeGreetingPolicy.message(hour: 20), "晚上好，愿你享受此刻。")
        XCTAssertEqual(TimeGreetingPolicy.message(hour: 1), "夜深了，早点睡觉。")

        XCTAssertEqual(TimeGreetingPolicy.compactMessage(hour: 7), "早安")
        XCTAssertEqual(TimeGreetingPolicy.compactMessage(hour: 10), "上午好")
        XCTAssertEqual(TimeGreetingPolicy.compactMessage(hour: 14), "下午好")
        XCTAssertEqual(TimeGreetingPolicy.compactMessage(hour: 20), "晚上好")
        XCTAssertEqual(TimeGreetingPolicy.compactMessage(hour: 1), "夜深了")
    }

    func testCompactPlaybackUsesFixedWidthStatus() {
        XCTAssertEqual(
            CompactPlaybackPolicy.label(isPlaying: true, elapsed: 79.8, duration: 240),
            "1:19"
        )
        XCTAssertEqual(
            CompactPlaybackPolicy.label(isPlaying: true, elapsed: 3_723, duration: 7_200),
            "62:03"
        )
        XCTAssertEqual(
            CompactPlaybackPolicy.label(isPlaying: false, elapsed: 79, duration: 240),
            "已暂停"
        )
        XCTAssertEqual(
            CompactPlaybackPolicy.label(isPlaying: true, elapsed: 0, duration: 0),
            "播放中"
        )
        XCTAssertEqual(CompactPlaybackPolicy.progress(elapsed: 60, duration: 240), 0.25)
        XCTAssertEqual(CompactPlaybackPolicy.progress(elapsed: 300, duration: 240), 1)
    }

    func testCompactDisplayUsesMinuteClock() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let date = calendar.date(from: DateComponents(year: 2026, month: 9, day: 26, hour: 8, minute: 5))!
        XCTAssertEqual(CompactDisplayPolicy.clockLabel(at: date, calendar: calendar), "08:05")
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

    func testDisplaySelectionPolicyUsesRequestedScreenAndSafeFallbacks() {
        let notch = [true, true, false]
        let builtIn = [false, true, false]

        XCTAssertEqual(
            DisplaySelectionPolicy.selectedIndex(
                strategy: .builtInPreferred,
                hasNotch: notch,
                isBuiltIn: builtIn,
                primaryIndex: 0,
                pointerIndex: 2
            ),
            1
        )
        XCTAssertEqual(
            DisplaySelectionPolicy.selectedIndex(
                strategy: .primary,
                hasNotch: notch,
                isBuiltIn: builtIn,
                primaryIndex: 0,
                pointerIndex: 2
            ),
            0
        )
        XCTAssertEqual(
            DisplaySelectionPolicy.selectedIndex(
                strategy: .followsPointer,
                hasNotch: notch,
                isBuiltIn: builtIn,
                primaryIndex: 0,
                pointerIndex: 2
            ),
            2
        )
        XCTAssertEqual(
            DisplaySelectionPolicy.selectedIndex(
                strategy: .followsPointer,
                hasNotch: [false],
                isBuiltIn: [true],
                primaryIndex: 0,
                pointerIndex: 9
            ),
            0
        )
        XCTAssertNil(
            DisplaySelectionPolicy.selectedIndex(
                strategy: .primary,
                hasNotch: [],
                isBuiltIn: [],
                primaryIndex: nil,
                pointerIndex: nil
            )
        )
    }

    func testIslandCardRegistryOwnsMetadataOrderAndEnablement() {
        XCTAssertEqual(Set(IslandCardRegistry.registrations.map(\.id)), Set(IslandCardID.allCases))
        XCTAssertEqual(
            IslandCardRegistry.defaultEnabledIDs,
            Set(IslandCardID.allCases)
        )

        let enabled: Set<IslandCardID> = [.calendar, .power, .pocket]
        XCTAssertEqual(
            IslandCardRegistry.orderedIDs(for: .musicFooter, enabledIDs: enabled),
            [.power, .focus, .calendar, .pocket]
        )
        XCTAssertEqual(
            IslandCardRegistry.orderedIDs(for: .idleDashboard, enabledIDs: enabled),
            [.power, .calendar, .reminders, .focus, .pocket]
        )
    }

    func testIslandCardOrderSanitizesDuplicatesAndAppendsMissingModules() {
        XCTAssertEqual(
            IslandCardRegistry.sanitizedOrder(
                [.calendar, .power, .calendar],
                for: .idleDashboard
            ),
            [.calendar, .power, .reminders, .focus, .pocket]
        )
        XCTAssertEqual(
            IslandCardRegistry.sanitizedOrder(
                [.pocket, .calendar, .power],
                for: .musicFooter
            ),
            [.calendar, .power, .focus, .pocket]
        )
    }

    func testIslandCardOrderMovesWithinContextAndKeepsFlexiblePocketLast() {
        let idle = IslandCardRegistry.moving(
            .calendar,
            by: 1,
            in: .idleDashboard,
            order: [.power, .calendar, .focus, .pocket]
        )
        XCTAssertEqual(idle, [.power, .focus, .calendar, .pocket, .reminders])

        let music = IslandCardRegistry.moving(
            .calendar,
            by: 1,
            in: .musicFooter,
            order: [.power, .focus, .calendar, .pocket]
        )
        XCTAssertEqual(music, [.power, .focus, .calendar, .pocket])
    }

    func testReminderSelectionPrioritizesDueDatesThenPriority() {
        let now = Date(timeIntervalSinceReferenceDate: 10_000)
        let selected = ReminderSelectionPolicy.next(from: [
            ReminderSnapshot(title: "没有日期", dueDate: nil, priority: 1),
            ReminderSnapshot(title: "稍后", dueDate: now.addingTimeInterval(3_600), priority: 1),
            ReminderSnapshot(title: "已逾期", dueDate: now.addingTimeInterval(-60), priority: 9)
        ])
        XCTAssertEqual(selected?.title, "已逾期")

        let undated = ReminderSelectionPolicy.next(from: [
            ReminderSnapshot(title: "低优先级", dueDate: nil, priority: 9),
            ReminderSnapshot(title: "高优先级", dueDate: nil, priority: 1),
            ReminderSnapshot(title: "无优先级", dueDate: nil, priority: 0)
        ])
        XCTAssertEqual(undated?.title, "高优先级")
        XCTAssertNil(ReminderSelectionPolicy.next(from: []))
    }

    func testReminderSubtitleDistinguishesUndatedAndOverdueItems() {
        let now = Date(timeIntervalSinceReferenceDate: 10_000)
        XCTAssertEqual(ReminderSelectionPolicy.subtitle(dueDate: nil, now: now), "没有设置截止时间")
        XCTAssertTrue(
            ReminderSelectionPolicy.subtitle(
                dueDate: now.addingTimeInterval(-60),
                now: now
            ).hasPrefix("已逾期 · ")
        )
        XCTAssertFalse(
            ReminderSelectionPolicy.subtitle(
                dueDate: now.addingTimeInterval(60),
                now: now
            ).hasPrefix("已逾期 · ")
        )
    }

    @MainActor
    func testExpandedNotchLayoutReservesCameraAreaWithoutTallEmptyHeader() {
        XCTAssertEqual(NotchLayoutPolicy.expandedContentTopInset(notchHeight: 32), 36)
        XCTAssertEqual(NotchLayoutPolicy.expandedContentTopInset(notchHeight: 48), 52)
        XCTAssertEqual(
            NotchLayoutPolicy.expandedShoulderRadius(notchHeight: 32, containerHeight: 222),
            32,
            accuracy: 0.001
        )
        XCTAssertEqual(
            NotchLayoutPolicy.compactWingWidths(mode: .smart, hasMusic: false, isPomodoroRunning: false),
            .init(leading: 52, trailing: 52)
        )
        XCTAssertEqual(
            NotchLayoutPolicy.compactWingWidths(mode: .smart, hasMusic: true, isPomodoroRunning: true),
            .init(leading: 52, trailing: 52)
        )
        XCTAssertEqual(
            NotchLayoutPolicy.compactWingWidths(mode: .time, hasMusic: false, isPomodoroRunning: false),
            .init(leading: 52, trailing: 52)
        )
        XCTAssertEqual(
            NotchLayoutPolicy.compactWingWidths(mode: .minimal, hasMusic: true, isPomodoroRunning: true),
            .init(leading: 52, trailing: 52)
        )

        let presentation = NotchPresentation()
        XCTAssertEqual(presentation.expandedSize(hasMusic: true), NSSize(width: 540, height: 250))
        XCTAssertEqual(presentation.expandedSize(hasMusic: false), NSSize(width: 540, height: 150))
    }

    @MainActor
    func testFocusTimerRestorationRoundsUpAndStopsAtZero() {
        let now = Date(timeIntervalSinceReferenceDate: 1_000)
        XCTAssertEqual(IslandState.remainingSeconds(until: now.addingTimeInterval(0.1), now: now), 1)
        XCTAssertEqual(IslandState.remainingSeconds(until: now.addingTimeInterval(-1), now: now), 0)
    }

    private func testPlayback(source: String, isPlaying: Bool) -> MusicPlayback {
        MusicPlayback(
            title: "Test",
            artist: "Artist",
            album: "Album",
            isPlaying: isPlaying,
            source: source,
            elapsed: 1,
            duration: 10,
            artworkData: nil,
            artworkURL: nil
        )
    }
}
