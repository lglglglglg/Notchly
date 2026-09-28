import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct IslandView: View {
    @ObservedObject var state: IslandState
    @ObservedObject private var settings: AppSettings
    @ObservedObject private var pocket: PocketService
    @ObservedObject private var musicLibrary: MusicLibraryService
    @State private var showsCalendarDetails = false
    @State private var showsReminderDetails = false
    @State private var showsPocket = false
    @State private var showsMusicLibrary = false
    @State private var musicLibrarySection = MusicLibrarySection.recent
    @State private var confirmsPocketClear = false
    @State private var isPocketDropTarget = false
    @State private var isArtworkHovered = false
    @State private var helloWriteProgress: CGFloat = 0
    @State private var helloControlsVisible = false
    @State private var idleHelloWriteProgress: CGFloat = 0
    let safeTop: CGFloat
    let notchWidth: CGFloat
    let dismiss: () -> Void

    init(state: IslandState, safeTop: CGFloat, notchWidth: CGFloat, dismiss: @escaping () -> Void) {
        self.state = state
        self.settings = state.settings
        self.pocket = state.pocket
        self.musicLibrary = state.musicLibrary
        self.safeTop = safeTop
        self.notchWidth = notchWidth
        self.dismiss = dismiss
    }

    var body: some View {
        VStack(spacing: 0) {
            if state.hasMusic && !settings.showsWelcome {
                musicTopBand
                    .frame(height: safeTop, alignment: .bottom)
            } else {
                Color.clear.frame(height: safeTop)
            }

            if settings.showsWelcome {
                firstLaunchWelcome
            } else if state.hasMusic {
                musicContent
            } else {
                idleContent
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .animation(.easeInOut(duration: 0.45), value: settings.showsWelcome)
        .onChange(of: showsPocket) { _, _ in updatePopoverRetention() }
        .onChange(of: showsCalendarDetails) { _, _ in updatePopoverRetention() }
        .onChange(of: showsReminderDetails) { _, _ in updatePopoverRetention() }
        .onChange(of: showsMusicLibrary) { _, _ in updatePopoverRetention() }
        .onChange(of: settings.enabledIslandCards) { _, enabled in
            if !enabled.contains(.pocket) { showsPocket = false }
            if !enabled.contains(.calendar) { showsCalendarDetails = false }
            if !enabled.contains(.reminders) { showsReminderDetails = false }
            updatePopoverRetention()
        }
        .onDisappear { state.setIslandPopoverPresented(false) }
    }

    private var musicContent: some View {
        VStack(spacing: 0) {
            HStack(spacing: 11) {
                Button { state.openMusicApp() } label: {
                    artwork
                        .overlay(alignment: .bottomTrailing) {
                            Image(systemName: "arrow.up.forward.app.fill")
                                .font(.caption2.weight(.bold))
                                .foregroundStyle(.white)
                                .padding(5)
                                .background(.black.opacity(0.72), in: Circle())
                                .overlay { Circle().stroke(.white.opacity(0.16), lineWidth: 0.6) }
                        }
                        .scaleEffect(isArtworkHovered ? 1.045 : 1)
                        .shadow(
                            color: settings.islandAccentTheme.accent.opacity(isArtworkHovered ? 0.34 : 0.18),
                            radius: isArtworkHovered ? 13 : 7,
                            y: isArtworkHovered ? 5 : 3
                        )
                        .animation(.spring(response: 0.22, dampingFraction: 0.72), value: isArtworkHovered)
                }
                .buttonStyle(.plain)
                .help("打开\(state.musicSource)")
                .onHover { isArtworkHovered = $0 }

                VStack(alignment: .leading, spacing: 4) {
                    HStack(alignment: .top, spacing: 10) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(state.musicTitle)
                                .font(.title3.weight(.semibold))
                                .lineLimit(1)
                                .minimumScaleFactor(0.84)
                            artistAndAlbum
                                .font(.subheadline.weight(.medium))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .minimumScaleFactor(0.84)
                            if let message = state.musicActionMessage {
                                Text(message)
                                    .font(.footnote.weight(.medium))
                                    .foregroundColor(.orange)
                                    .lineLimit(1)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        Button { state.toggleCurrentTrackFavorite() } label: {
                            Image(systemName: currentTrackIsFavorite ? "heart.fill" : "heart")
                                .foregroundStyle(currentTrackIsFavorite ? .pink : .secondary)
                                .contentTransition(.symbolEffect(.replace))
                                .frame(width: 26, height: 26)
                        }
                        .buttonStyle(.plain)
                        .help(currentTrackIsFavorite ? "取消收藏" : "收藏当前歌曲")
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)

                    visualizer

                    TimelineView(.animation(
                        minimumInterval: settings.prefersReducedActivity ? 1 : 0.25,
                        paused: !state.isPlaying
                    )) { context in
                        let elapsed = state.elapsedTime(at: context.date)
                        HStack(spacing: 10) {
                            Text(formatTime(elapsed))
                            ProgressView(value: elapsed, total: max(1, state.musicDuration))
                                .tint(.white)
                                // A new song must replace this control instead of
                                // interpolating the old near-finished value down
                                // to the new track's opening position.
                                .id("\(state.musicSource):\(state.musicTitle):\(state.musicArtist)")
                                .transaction { $0.animation = nil }
                            Text(state.musicDuration > 0 ? formatTime(state.musicDuration) : "--:--")
                        }
                    }
                    .font(.footnote.monospacedDigit())
                    .foregroundStyle(.secondary)

                    HStack {
                        Spacer()
                        Button { state.previousMusic() } label: {
                            Image(systemName: "backward.fill").font(.title3)
                        }
                        Spacer()
                        Button { state.toggleMusic() } label: {
                            Group {
                                if state.isPerformingMusicAction {
                                    ProgressView().controlSize(.small)
                                } else {
                                    Image(systemName: state.isPlaying ? "pause.fill" : "play.fill")
                                        .contentTransition(.symbolEffect(.replace))
                                }
                            }
                            .font(.title3)
                            .frame(width: 30, height: 30)
                            .background(.white, in: Circle())
                            .foregroundStyle(.black)
                        }
                        .buttonStyle(.plain)
                        Spacer()
                        Button { state.nextMusic() } label: {
                            Image(systemName: "forward.fill").font(.title3)
                        }
                        Spacer()
                    }
                    .buttonStyle(.plain)
                    .disabled(state.isPerformingMusicAction)
                    .opacity(state.isPerformingMusicAction ? 0.72 : 1)
                }
            }
            .padding(.horizontal, 56)

            lyricsFooter
                .padding(.horizontal, 56)
                .padding(.top, 10)

            if !musicFooterCards.isEmpty {
                HStack(spacing: 8) {
                    if !musicFooterControlCards.isEmpty {
                        footerSystemControls(cards: musicFooterControlCards)
                            .frame(width: IslandCardLayoutPolicy.musicFooterControlsWidth(for: musicFooterControlCards))
                    }
                    if musicFooterCards.contains(.pocket) {
                        pocketDropRow
                            .frame(maxWidth: .infinity)
                    } else {
                        Spacer(minLength: 0)
                    }
                }
                .padding(.horizontal, 56)
                .padding(.top, 8)
                .padding(.bottom, 8)
            }
        }
    }

    private var musicFooterCards: [IslandCardID] {
        IslandCardRegistry.orderedIDs(
            for: .musicFooter,
            enabledIDs: settings.enabledIslandCards,
            preferredOrder: settings.islandCardOrder(for: .musicFooter)
        )
    }

    private var musicFooterControlCards: [IslandCardID] {
        musicFooterCards.filter { $0 != .pocket }
    }

    private func footerSystemControls(cards: [IslandCardID]) -> some View {
        HStack(spacing: 0) {
            ForEach(cards.indices, id: \.self) { index in
                if index > cards.startIndex {
                    Divider()
                        .overlay(.white.opacity(0.10))
                        .padding(.vertical, 9)
                }
                footerSystemControl(cards[index])
            }
        }
        .font(.callout.weight(.semibold))
        .background(.white.opacity(0.045), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(.white.opacity(0.055), lineWidth: 0.5)
        }
    }

    @ViewBuilder
    private func footerSystemControl(_ card: IslandCardID) -> some View {
        switch card {
        case .power:
            Button { state.refreshPower() } label: {
                Label(batteryFooterTitle, systemImage: batterySymbol)
                    .frame(width: 72)
                    .frame(minHeight: 42)
            }
            .buttonStyle(.plain)
            .foregroundStyle(batteryTint)
            .help([state.batteryStatus, state.batteryTimeRemaining].filter { !$0.isEmpty }.joined(separator: " · "))
        case .focus:
            footerFocusControl
        case .calendar:
            Button {
                showsCalendarDetails.toggle()
                if showsCalendarDetails { state.connectCalendar() }
            } label: {
                Label("日历", systemImage: "calendar")
                    .frame(width: 86)
                    .frame(minHeight: 42)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help("查看下一项日程")
            .popover(isPresented: $showsCalendarDetails, arrowEdge: .bottom) {
                calendarPopover
            }
        case .reminders:
            EmptyView()
        case .pocket:
            EmptyView()
        }
    }

    private var footerFocusControl: some View {
        Menu {
            Button(state.isPomodoroRunning ? "暂停专注" : "开始 \(settings.focusMinutes) 分钟专注") {
                state.togglePomodoro()
            }
            Button("重新开始") {
                state.resetPomodoro()
                state.togglePomodoro()
            }
            Button("重置计时") { state.resetPomodoro() }
        } label: {
            HStack(spacing: 7) {
                Image(systemName: "timer")
                Text(state.isPomodoroRunning ? state.timerText : "专注")
                    .monospacedDigit()
                    // Reserve the same title slot for the idle label and every
                    // supported timer value, so ticking never shifts its neighbors.
                    .frame(width: 58, alignment: .leading)
            }
            .padding(.horizontal, 10)
            .frame(maxWidth: .infinity, minHeight: 42, alignment: .leading)
            .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .foregroundStyle(.orange)
        .frame(width: 132)
        .help("专注计时")
    }

    private var pocketDropRow: some View {
        Button { showsPocket.toggle() } label: {
            HStack(spacing: 7) {
                Image(systemName: isPocketDropTarget ? "tray.and.arrow.down.fill" : (pocket.items.isEmpty ? "tray" : "tray.full"))
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(isPocketDropTarget ? .white : settings.islandAccentTheme.accent)
                Text(pocketDropTitle)
                    .font(.callout.weight(.semibold))
                    .lineLimit(1)
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 10)
            .frame(maxWidth: .infinity, minHeight: 42, alignment: .leading)
            .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .buttonStyle(.plain)
        .background(isPocketDropTarget ? settings.islandAccentTheme.accent.opacity(0.48) : .white.opacity(0.045), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(isPocketDropTarget ? settings.islandAccentTheme.accent.opacity(0.9) : .white.opacity(0.055), lineWidth: isPocketDropTarget ? 1 : 0.5)
        }
        .onDrop(of: [UTType.fileURL], isTargeted: $isPocketDropTarget, perform: receivePocketDrop)
        .help(pocket.items.isEmpty ? "将文件拖放到此处暂存" : "临时文件托盘 · \(pocket.items.count) 项")
        .popover(isPresented: $showsPocket, arrowEdge: .bottom) {
            pocketPopover
        }
    }

    private var pocketDropTitle: String {
        if isPocketDropTarget { return "松手" }
        return pocket.items.isEmpty ? "暂存" : "\(pocket.items.count) 项"
    }

    private func receivePocketDrop(_ providers: [NSItemProvider]) -> Bool {
        var accepted = false
        for provider in providers where provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
            accepted = true
            provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                let url: URL?
                if let value = item as? URL { url = value }
                else if let value = item as? NSURL { url = value as URL }
                else if let data = item as? Data { url = URL(dataRepresentation: data, relativeTo: nil) }
                else { url = nil }
                guard let url else { return }
                Task { @MainActor in pocket.importURLs([url]) }
            }
        }
        return accepted
    }

    private func updatePopoverRetention() {
        state.setIslandPopoverPresented(
            showsPocket || showsCalendarDetails || showsReminderDetails || showsMusicLibrary
        )
    }

    private var artistAndAlbum: Text {
        guard !state.musicAlbum.isEmpty else { return Text(state.musicArtist) }
        return Text(state.musicArtist) + Text("  ·  ") + Text(state.musicAlbum)
    }

    private var firstLaunchWelcome: some View {
        VStack(spacing: 8) {
            Spacer(minLength: 0)
            HStack(spacing: 34) {
                HandwrittenHello(progress: helloWriteProgress, lineWidth: 8)
                    .frame(width: 172, height: 72)
                    .shadow(color: .orange.opacity(0.24), radius: 8)
                    .shadow(color: .cyan.opacity(0.28), radius: 15)

                Button {
                    withAnimation(.easeInOut(duration: 0.45)) {
                        settings.dismissWelcome()
                    }
                } label: {
                    Image(systemName: "arrow.right")
                        .font(.system(size: 23, weight: .bold))
                        .foregroundStyle(.black)
                        .frame(width: 54, height: 54)
                        .background(.white, in: Circle())
                        .shadow(color: .white.opacity(0.2), radius: 12)
                }
                .buttonStyle(.plain)
                .help("进入 Notchly")
                .opacity(helloControlsVisible ? 1 : 0)
                .scaleEffect(helloControlsVisible ? 1 : 0.72)
            }
            Text("欢迎使用 Notchly")
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
                .opacity(helloControlsVisible ? 1 : 0)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 64)
        .padding(.bottom, 8)
        .transition(.opacity.combined(with: .scale(scale: 0.96)))
        .onAppear {
            helloWriteProgress = 0
            helloControlsVisible = false
            withAnimation(.easeInOut(duration: 2.15)) {
                helloWriteProgress = 1
            }
            withAnimation(.spring(response: 0.52, dampingFraction: 0.72).delay(1.65)) {
                helloControlsVisible = true
            }
        }
    }

    private var idleContent: some View {
        VStack(spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                HandwrittenHello(progress: idleHelloWriteProgress, lineWidth: 4.5)
                    .frame(width: 92, height: 34)
                Spacer()
                quickActionsMenu
            }

            if !idleDashboardCards.isEmpty {
                HStack(spacing: 8) {
                    ForEach(idleDashboardCards) { card in
                        idleDashboardCard(card)
                    }
                }
            }

            TimelineView(.periodic(from: .now, by: 60)) { context in
                Label {
                    Text("暂无播放 · \(TimeGreetingPolicy.message(at: context.date))")
                } icon: {
                    Image(systemName: "music.note")
                }
                .font(.caption)
                .foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, 64)
        .padding(.bottom, 7)
        .onAppear {
            idleHelloWriteProgress = 0
            withAnimation(.easeInOut(duration: 1.65)) {
                idleHelloWriteProgress = 1
            }
        }
    }

    private var idleDashboardCards: [IslandCardID] {
        IslandCardRegistry.orderedIDs(
            for: .idleDashboard,
            enabledIDs: settings.enabledIslandCards,
            preferredOrder: settings.islandCardOrder(for: .idleDashboard)
        )
    }

    @ViewBuilder
    private func idleDashboardCard(_ card: IslandCardID) -> some View {
        switch card {
        case .power:
            infoButton(icon: batterySymbol, title: batteryTitle, tint: batteryTint) {
                state.refreshPower()
            }
        case .calendar:
            infoButton(icon: "calendar", title: "下一日程", tint: .blue) {
                showsCalendarDetails.toggle()
                if showsCalendarDetails { state.connectCalendar() }
            }
            .popover(isPresented: $showsCalendarDetails, arrowEdge: .bottom) {
                calendarPopover
            }
        case .focus:
            infoButton(icon: "timer", title: state.isPomodoroRunning ? state.timerText : "专注", tint: .orange) {
                state.togglePomodoro()
            }
        case .reminders:
            infoButton(icon: "checklist", title: "提醒", tint: .pink) {
                showsReminderDetails.toggle()
                if showsReminderDetails { state.connectReminders() }
            }
            .popover(isPresented: $showsReminderDetails, arrowEdge: .bottom) {
                reminderPopover
            }
        case .pocket:
            infoButton(
                icon: pocket.items.isEmpty ? "tray" : "tray.full",
                title: pocket.items.isEmpty ? "托盘" : "\(pocket.items.count) 项",
                tint: .purple
            ) {
                showsPocket.toggle()
            }
            .popover(isPresented: $showsPocket, arrowEdge: .bottom) {
                pocketPopover
            }
        }
    }

    private func infoButton(icon: String, title: String, tint: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .foregroundStyle(tint)
                Text(title)
                    .lineLimit(1)
            }
            .font(.caption.weight(.semibold))
            .frame(maxWidth: .infinity)
            .padding(.vertical, 7)
            .background(.white.opacity(0.065), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(.white.opacity(0.07), lineWidth: 0.6)
            }
        }
        .buttonStyle(.plain)
    }

    private var quickActionsMenu: some View {
        Menu {
            Button {
                openSettingsWindow()
            } label: {
                Label("打开设置…", systemImage: "gearshape")
            }
            Divider()
            Button {
                NotificationCenter.default.post(name: .notchlyRestartRequested, object: nil)
            } label: {
                Label("重新启动 Notchly", systemImage: "arrow.triangle.2.circlepath")
            }
            Divider()
            Button(role: .destructive) {
                NotificationCenter.default.post(name: .notchlyQuitRequested, object: nil)
            } label: {
                Label("退出 Notchly", systemImage: "power")
            }
        } label: {
            Image(systemName: "gearshape")
        }
        .menuStyle(.borderlessButton)
        .help("快捷操作")
    }

    private var currentTrackIsFavorite: Bool {
        musicLibrary.isFavorite(
            source: state.musicSource,
            title: state.musicTitle,
            artist: state.musicArtist
        )
    }

    private var musicLibraryPopover: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("音乐记录", systemImage: "clock.arrow.circlepath")
                    .font(.headline)
                Spacer()
                Text("仅保存在本机")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            Picker("音乐记录", selection: $musicLibrarySection) {
                ForEach(MusicLibrarySection.allCases) { section in
                    Text(section.title).tag(section)
                }
            }
            .pickerStyle(.segmented)

            let tracks = musicLibrarySection == .recent
                ? musicLibrary.recentTracks
                : musicLibrary.favoriteTracks
            if tracks.isEmpty {
                ContentUnavailableView(
                    musicLibrarySection == .recent ? "还没有播放记录" : "还没有收藏",
                    systemImage: musicLibrarySection == .recent ? "music.note.list" : "heart",
                    description: Text(musicLibrarySection == .recent ? "播放歌曲后会自动记录" : "点击播放器中的爱心即可收藏")
                )
                .frame(height: 140)
            } else {
                ScrollView {
                    LazyVStack(spacing: 5) {
                        ForEach(tracks) { track in
                            musicLibraryRow(track)
                        }
                    }
                }
                .frame(maxHeight: 230)
            }

            if musicLibrarySection == .recent, !musicLibrary.recentTracks.isEmpty {
                HStack {
                    Text("最多保留 50 首，不保存封面。")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("清空记录", role: .destructive) {
                        musicLibrary.clearRecentTracks()
                    }
                }
            }
        }
        .padding(14)
        .frame(width: 360)
    }

    private func musicLibraryRow(_ track: MusicLibraryTrack) -> some View {
        HStack(spacing: 9) {
            Image(systemName: "music.note")
                .foregroundStyle(settings.islandAccentTheme.accent)
                .frame(width: 24, height: 24)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            VStack(alignment: .leading, spacing: 2) {
                Text(track.title)
                    .font(.callout.weight(.semibold))
                    .lineLimit(1)
                Text([track.artist, track.source].filter { !$0.isEmpty }.joined(separator: " · "))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 4)
            Button { musicLibrary.toggleFavorite(track) } label: {
                Image(systemName: musicLibrary.favoriteTracks.contains(where: { $0.id == track.id }) ? "heart.fill" : "heart")
                    .foregroundStyle(musicLibrary.favoriteTracks.contains(where: { $0.id == track.id }) ? .pink : .secondary)
            }
            .buttonStyle(.plain)
            .help("收藏或取消收藏")
        }
        .padding(7)
        .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
    }

    private var lyricOffsetLabel: String {
        abs(settings.lyricOffset) < 0.05 ? "0.0 秒" : String(format: "%+.1f 秒", settings.lyricOffset)
    }

    private func adjustLyricOffset(by adjustment: Double) {
        settings.lyricOffset = LyricSyncPolicy.adjustedOffset(settings.lyricOffset, by: adjustment)
    }

    private var pocketPopover: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("临时文件托盘", systemImage: "tray.full")
                    .font(.headline)
                Spacer()
                Text(pocket.storageSummary)
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            Text(pocket.statusMessage)
                .font(.caption)
                .foregroundStyle(.secondary)

            if pocket.items.isEmpty {
                ContentUnavailableView("还没有文件", systemImage: "arrow.down.doc", description: Text("把文件拖到刘海区域即可暂存"))
                    .frame(height: 120)
            } else {
                ScrollView {
                    LazyVStack(spacing: 5) {
                        ForEach(pocket.items) { item in
                            HStack(spacing: 8) {
                                Image(nsImage: NSWorkspace.shared.icon(forFile: item.url.path))
                                    .resizable()
                                    .frame(width: 24, height: 24)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(item.name).lineLimit(1)
                                    Text(ByteCountFormatter.string(fromByteCount: item.size, countStyle: .file))
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                Button { pocket.reveal(item) } label: { Image(systemName: "folder") }
                                    .buttonStyle(.plain)
                            }
                            .padding(6)
                            .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 8))
                            .onDrag { NSItemProvider(object: item.url as NSURL) }
                        }
                    }
                }
                .frame(maxHeight: 190)
            }

            HStack {
                Button("在 Finder 中打开") { pocket.reveal() }
                Spacer()
                Button("一键清空", role: .destructive) { confirmsPocketClear = true }
                    .disabled(pocket.items.isEmpty || pocket.isImporting)
            }
        }
        .padding(14)
        .frame(width: 330)
        .alert("清空临时文件托盘？", isPresented: $confirmsPocketClear) {
            Button("取消", role: .cancel) {}
            Button("清空", role: .destructive) { pocket.clear() }
        } message: {
            Text("暂存副本会被删除，原始文件不会受到影响。")
        }
    }

    private var batteryTitle: String {
        state.batteryLevel.map { "\($0)%" } ?? "--%"
    }

    private var batteryFooterTitle: String {
        guard let level = state.batteryLevel else { return "--%" }
        return state.batteryStatus.contains("充电") ? "\(level)% · 充电" : "\(level)%"
    }

    private var batterySymbol: String {
        guard let level = state.batteryLevel else { return "battery.0percent" }
        if state.batteryStatus.contains("充电") { return "battery.100percent.bolt" }
        if level >= 75 { return "battery.100percent" }
        if level >= 35 { return "battery.50percent" }
        return "battery.25percent"
    }

    private var batteryTint: Color {
        guard let level = state.batteryLevel else { return .secondary }
        if state.batteryStatus.contains("充电") { return .green }
        if level <= 20 { return .red }
        return .green
    }

    private var calendarPopover: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("下一项日程", systemImage: "calendar")
                .font(.headline)
            Text(state.calendarTitle)
                .font(.body.weight(.semibold))
                .lineLimit(2)
            Text(state.calendarSubtitle)
                .font(.caption)
                .foregroundStyle(.secondary)
            Button(state.isLoadingCalendar ? "正在读取…" : "刷新 / 授权日历") {
                state.connectCalendar()
            }
            .disabled(state.isLoadingCalendar)
        }
        .padding(16)
        .frame(width: 260, alignment: .leading)
    }

    private var reminderPopover: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("下一条提醒", systemImage: "checklist")
                .font(.headline)
            Text(state.reminderTitle)
                .font(.body.weight(.semibold))
                .lineLimit(2)
            Text(state.reminderSubtitle)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text("macOS 只提供“完全访问”授权；Notchly 实际只读取未完成提醒，不会创建、修改或删除内容。")
                .font(.caption2)
                .foregroundStyle(.tertiary)
            HStack {
                Button(state.isLoadingReminder ? "正在读取…" : "刷新 / 授权提醒事项") {
                    state.connectReminders()
                }
                .disabled(state.isLoadingReminder)
                Spacer()
                Button("打开提醒事项") { openRemindersApp() }
            }
        }
        .padding(16)
        .frame(width: 300, alignment: .leading)
    }

    private func openRemindersApp() {
        guard let appURL = NSWorkspace.shared.urlForApplication(
            withBundleIdentifier: "com.apple.reminders"
        ) else { return }
        NSWorkspace.shared.open(appURL)
    }

    @ViewBuilder
    private var visualizer: some View {
        if settings.musicVisualizerStyle == .spectrum || settings.musicVisualizerStyle == .waveform {
            MusicVisualizer(
                style: settings.musicVisualizerStyle,
                isActive: state.isPlaying && !settings.prefersReducedActivity,
                tint: settings.islandAccentTheme.accent,
                highlight: settings.islandAccentTheme.highlight
            )
            .frame(height: 16)
        } else {
            Color.clear.frame(height: 16)
        }
    }

    private var lyricsFooter: some View {
        VStack(spacing: 2) {
            if state.currentLyricText.isEmpty {
                HStack(spacing: 7) {
                    Image(systemName: "music.note")
                        .font(.callout.weight(.medium))
                        .foregroundStyle(settings.islandAccentTheme.accent.opacity(0.78))
                    if state.shouldShowSyncedLyricsUnavailable {
                        Text("暂无同步歌词")
                            .font(.footnote.weight(.medium))
                            .foregroundStyle(.tertiary)
                            .help("已依次尝试网易云音乐与 LRCLIB 的同步歌词来源")
                    }
                    Spacer(minLength: 0)
                }
            } else {
                HStack(spacing: 5) {
                    Image(systemName: "quote.opening")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(settings.islandAccentTheme.accent)
                    Text(state.currentLyricText)
                        .font(.callout.weight(.semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                        .id(state.currentLyricText)
                        .layoutPriority(-1)
                        .transition(.asymmetric(
                            insertion: .move(edge: .bottom).combined(with: .opacity),
                            removal: .move(edge: .top).combined(with: .opacity)
                        ))
                    Spacer(minLength: 4)
                    lyricCalibrationControls
                }
            }

            if !lyricSecondaryText.isEmpty {
                HStack(spacing: 5) {
                    Spacer(minLength: 22)
                    if lyricSecondaryIsTranslation {
                        Text("译")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(settings.islandAccentTheme.accent.opacity(0.82))
                    }
                    Text(lyricSecondaryText)
                        .font(.footnote)
                        .foregroundStyle(.secondary.opacity(0.82))
                        .lineLimit(1)
                        .multilineTextAlignment(.trailing)
                        .id(lyricSecondaryText)
                        .transition(.opacity)
                    Image(systemName: "quote.closing")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(settings.islandAccentTheme.accent.opacity(0.72))
                }
            } else if !state.currentLyricText.isEmpty {
                HStack {
                    Spacer()
                    Image(systemName: "quote.closing")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(settings.islandAccentTheme.accent.opacity(0.72))
                }
            }
        }
        .animation(.easeInOut(duration: 0.24), value: state.currentLyricText)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .frame(minWidth: 180, maxWidth: .infinity, minHeight: 46, maxHeight: 46, alignment: .leading)
        .background(.white.opacity(0.045), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(.white.opacity(0.055), lineWidth: 0.5)
        }
    }

    private var lyricSecondaryIsTranslation: Bool {
        settings.showsTranslatedLyrics && !state.currentLyricTranslation.isEmpty
    }

    private var lyricSecondaryText: String {
        lyricSecondaryIsTranslation ? state.currentLyricTranslation : state.nextLyricText
    }

    private var lyricCalibrationControls: some View {
        Menu {
            Text("当前偏移 \(lyricOffsetLabel)")
            Divider()
            Button("歌词后退 0.5 秒") { adjustLyricOffset(by: -0.5) }
            Button("恢复原始同步") { settings.lyricOffset = 0 }
                .disabled(abs(settings.lyricOffset) < 0.05)
            Button("歌词前进 0.5 秒") { adjustLyricOffset(by: 0.5) }
        } label: {
            HStack(spacing: 3) {
                Image(systemName: "metronome")
                if abs(settings.lyricOffset) >= 0.05 {
                    Text(lyricOffsetLabel)
                        .monospacedDigit()
                }
                Image(systemName: "chevron.down")
                    .font(.system(size: 8, weight: .bold))
            }
            .font(.caption2.weight(.semibold))
            .foregroundStyle(settings.islandAccentTheme.accent.opacity(0.86))
            .padding(.horizontal, 5)
            .padding(.vertical, 4)
            .background(.white.opacity(0.045), in: Capsule())
            .overlay { Capsule().stroke(.white.opacity(0.07), lineWidth: 0.5) }
        }
        .menuStyle(.borderlessButton)
        .help("歌词校准：前进或后退 0.5 秒")
        .fixedSize()
    }

    private var artwork: some View {
        ZStack {
            if settings.musicVisualizerStyle == .pulse || settings.musicVisualizerStyle == .cosmicDust {
                MusicVisualizer(
                    style: settings.musicVisualizerStyle,
                    isActive: state.isPlaying && !settings.prefersReducedActivity,
                    tint: settings.islandAccentTheme.accent,
                    highlight: settings.islandAccentTheme.highlight
                )
                .frame(width: 104, height: 104)
            }

            Group {
                if let image = state.artworkImage {
                    Image(nsImage: image)
                        .resizable()
                        .scaledToFill()
                } else {
                    LinearGradient(
                        colors: settings.islandAccentTheme.artworkColors,
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                    .overlay(Image(systemName: "music.note").font(.system(size: 30, weight: .medium)))
                }
            }
            .frame(
                width: settings.musicVisualizerStyle == .pulse || settings.musicVisualizerStyle == .cosmicDust ? 66 : 68,
                height: settings.musicVisualizerStyle == .pulse || settings.musicVisualizerStyle == .cosmicDust ? 66 : 68
            )
            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        }
        .frame(width: 104, height: 92)
        .shadow(color: settings.islandAccentTheme.accent.opacity(state.isPlaying ? 0.28 : 0.12), radius: 20, y: 7)
    }

    private var musicTopBand: some View {
        HStack(spacing: 8) {
            Label(state.musicSource, systemImage: "music.note")
                .lineLimit(1)
                .foregroundStyle(.secondary)
            Spacer(minLength: max(42, notchWidth - 44))
            Button { showsMusicLibrary.toggle() } label: {
                Image(systemName: "clock.arrow.circlepath")
            }
            .buttonStyle(.plain)
            .help("最近播放与收藏")
            .popover(isPresented: $showsMusicLibrary, arrowEdge: .top) {
                musicLibraryPopover
            }
            quickActionsMenu
        }
        .font(.footnote.weight(.semibold))
        .padding(.horizontal, 64)
        .padding(.bottom, 4)
    }

    private func formatTime(_ seconds: TimeInterval) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "0:00" }
        let total = Int(seconds.rounded(.down))
        return String(format: "%d:%02d", total / 60, total % 60)
    }

    private func openSettingsWindow() {
        NotificationCenter.default.post(name: .notchlyShowSettingsRequested, object: nil)
    }
}

private enum MusicLibrarySection: String, CaseIterable, Identifiable {
    case recent
    case favorites

    var id: String { rawValue }

    var title: String {
        switch self {
        case .recent: "最近播放"
        case .favorites: "收藏"
        }
    }
}

private struct HandwrittenHello: View {
    let progress: CGFloat
    let lineWidth: CGFloat

    var body: some View {
        HelloScriptPath()
            .trim(from: 0, to: min(max(progress, 0), 1))
            .stroke(
                LinearGradient(
                    colors: [.red, .orange, .yellow, .green, .cyan, .blue, .purple],
                    startPoint: .leading,
                    endPoint: .trailing
                ),
                style: StrokeStyle(lineWidth: lineWidth, lineCap: .round, lineJoin: .round)
            )
    }
}

/// A continuous cursive path so `trim` reveals “hello” in the same order a
/// pen would write it, instead of exposing a pre-rendered word with a mask.
private struct HelloScriptPath: Shape {
    func path(in rect: CGRect) -> Path {
        func point(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
            CGPoint(x: rect.minX + rect.width * x, y: rect.minY + rect.height * y)
        }

        var path = Path()
        path.move(to: point(0.02, 0.76))
        path.addCurve(to: point(0.16, 0.16), control1: point(0.09, 0.73), control2: point(0.10, 0.29))
        path.addCurve(to: point(0.14, 0.68), control1: point(0.23, -0.02), control2: point(0.17, 0.46))
        path.addCurve(to: point(0.30, 0.48), control1: point(0.20, 0.73), control2: point(0.23, 0.47))
        path.addCurve(to: point(0.29, 0.70), control1: point(0.37, 0.48), control2: point(0.36, 0.70))
        path.addCurve(to: point(0.45, 0.55), control1: point(0.36, 0.72), control2: point(0.42, 0.67))
        path.addCurve(to: point(0.38, 0.45), control1: point(0.49, 0.45), control2: point(0.42, 0.39))
        path.addCurve(to: point(0.45, 0.69), control1: point(0.31, 0.53), control2: point(0.35, 0.70))
        path.addCurve(to: point(0.58, 0.17), control1: point(0.54, 0.67), control2: point(0.54, 0.30))
        path.addCurve(to: point(0.55, 0.68), control1: point(0.63, 0.02), control2: point(0.58, 0.50))
        path.addCurve(to: point(0.70, 0.17), control1: point(0.64, 0.69), control2: point(0.66, 0.30))
        path.addCurve(to: point(0.67, 0.68), control1: point(0.75, 0.02), control2: point(0.70, 0.50))
        path.addCurve(to: point(0.82, 0.45), control1: point(0.75, 0.70), control2: point(0.76, 0.43))
        path.addCurve(to: point(0.80, 0.69), control1: point(0.90, 0.46), control2: point(0.89, 0.69))
        path.addCurve(to: point(0.94, 0.52), control1: point(0.87, 0.72), control2: point(0.91, 0.62))
        path.addCurve(to: point(0.98, 0.54), control1: point(0.96, 0.48), control2: point(0.97, 0.51))
        return path
    }
}

struct SettingsView: View {
    // Settings primarily observes AppSettings. Observing the entire IslandState
    // caused this large TabView to rebuild for every playback/lyric refresh,
    // accumulating SwiftUI Observation registrations during long sessions.
    private let state: IslandState
    @ObservedObject private var settings: AppSettings
    @State private var aboutMessage: String?
    @State private var cardOrderContext = IslandCardContext.musicFooter

    init(state: IslandState) {
        self.state = state
        settings = state.settings
    }

    var body: some View {
        TabView {
            generalSettings
                .tabItem { Label("通用", systemImage: "gearshape") }

            islandSettings
                .tabItem { Label("灵动岛", systemImage: "capsule.tophalf.filled") }

            desktopLyricsSettings
                .tabItem { Label("桌面歌词", systemImage: "text.bubble") }

            aboutSettings
                .tabItem { Label("关于", systemImage: "info.circle") }
        }
        .frame(width: 640, height: 570)
    }

    private var generalSettings: some View {
        SettingsPage(title: "通用", subtitle: "启动方式与专注计时") {
            SettingsCard(title: "Notchly", icon: "macbook") {
                SettingLine(title: "登录时启动", detail: "登录 Mac 后自动显示灵动岛") {
                    Toggle("", isOn: Binding(
                        get: { settings.launchesAtLogin },
                        set: { settings.setLaunchAtLogin($0) }
                    ))
                    .labelsHidden()
                }
                if let message = settings.launchAtLoginMessage {
                    Text(message).settingsHint()
                }
                Divider()
                SettingLine(title: "全局快捷键", detail: "展开或收起灵动岛") {
                    Text("⌘ ⇧ Space")
                        .font(.system(.body, design: .rounded).weight(.semibold))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(.quaternary, in: RoundedRectangle(cornerRadius: 7))
                }
                Divider()
                SettingLine(title: "退出应用", detail: "关闭灵动岛、桌面歌词和后台服务") {
                    Button("退出 Notchly", role: .destructive) {
                        NotificationCenter.default.post(name: .notchlyQuitRequested, object: nil)
                    }
                    .buttonStyle(.bordered)
                }
            }

            SettingsCard(title: "专注计时", icon: "timer") {
                SettingLine(title: "默认时长", detail: "在灵动岛的计时器菜单中开始") {
                    Stepper("\(settings.focusMinutes) 分钟", value: $settings.focusMinutes, in: 5...120, step: 5)
                        .fixedSize()
                }
            }

            SettingsCard(title: "健康提醒", icon: "figure.stand") {
                SettingLine(title: "喝水提醒", detail: "按设定间隔发送本地通知") {
                    HStack(spacing: 10) {
                        wellnessIntervalControl(value: $settings.hydrationIntervalMinutes)
                        Toggle("", isOn: $settings.hydrationRemindersEnabled).labelsHidden()
                    }
                }
                Divider()
                SettingLine(title: "久坐提醒", detail: "提醒起身、伸展和放松肩颈") {
                    HStack(spacing: 10) {
                        wellnessIntervalControl(value: $settings.standIntervalMinutes)
                        Toggle("", isOn: $settings.standRemindersEnabled).labelsHidden()
                    }
                }
                Text("间隔可直接输入，最短 5 分钟，最长 180 分钟。")
                    .settingsHint()
                Text("所有提醒都使用 macOS 本地通知，关闭开关后会取消已排定的提醒。")
                    .settingsHint()
                Label(
                    state.wellnessReminderSchedule.authorization.statusText,
                    systemImage: state.wellnessReminderSchedule.authorization == .authorized ? "checkmark.circle.fill" : "exclamationmark.triangle.fill"
                )
                .foregroundStyle(state.wellnessReminderSchedule.authorization == .authorized ? .green : .orange)
                .font(.footnote.weight(.medium))
                Text(state.wellnessReminderSchedule.statusMessage)
                    .settingsHint()
                if let next = state.wellnessReminderNextText {
                    Text(next)
                        .font(.footnote.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                HStack {
                    Button("立即发送提醒") {
                        state.sendWellnessReminderNow()
                    }
                    .buttonStyle(.bordered)
                    Button("打开通知设置") {
                        openSystemNotificationSettings()
                    }
                    .buttonStyle(.bordered)
                    Spacer()
                }
            }
        }
    }

    private func wellnessIntervalControl(value: Binding<Int>) -> some View {
        let clampedValue = Binding<Int>(
            get: { min(max(value.wrappedValue, 5), 180) },
            set: { value.wrappedValue = min(max($0, 5), 180) }
        )
        return HStack(spacing: 5) {
            TextField("分钟", value: clampedValue, format: .number)
                .textFieldStyle(.roundedBorder)
                .frame(width: 58)
                .multilineTextAlignment(.trailing)
            Text("分钟")
                .foregroundStyle(.secondary)
            Stepper("", value: clampedValue, in: 5...180, step: 5)
                .labelsHidden()
        }
        .fixedSize()
    }

    private var islandSettings: some View {
        SettingsPage(title: "灵动岛", subtitle: "刘海区域的交互与音乐动效") {
            SettingsCard(title: "场景预设", icon: "switch.2") {
                Picker("场景预设", selection: Binding(
                    get: { settings.activeIslandScenePreset },
                    set: { settings.applyIslandScenePreset($0) }
                )) {
                    ForEach(IslandScenePreset.allCases) { preset in
                        Text(preset.title).tag(preset)
                    }
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                Text(settings.activeIslandScenePreset.detail)
                    .settingsHint()
                Text("套用预设会调整悬停展开、全屏行为、收起状态、音乐动效、桌面歌词和模块开关；之后手动修改这些选项会自动切回“自定义”。")
                    .settingsHint()
            }

            SettingsCard(title: "显示行为", icon: "rectangle.slash") {
                SettingLine(title: "全屏时自动隐藏", detail: "视频、游戏或演示全屏时不遮挡内容") {
                    Toggle("", isOn: $settings.hidesIslandInFullScreen).labelsHidden()
                }
                Text("关闭后，灵动岛会像现在一样继续显示在其他应用的全屏空间。")
                    .settingsHint()
            }

            SettingsCard(title: "显示器位置", icon: "display.2") {
                Picker("显示器位置", selection: $settings.islandDisplayStrategy) {
                    ForEach(IslandDisplayStrategy.allCases) { strategy in
                        Text(strategy.title).tag(strategy)
                    }
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                Text(settings.islandDisplayStrategy.detail)
                    .settingsHint()
                Text("外接屏没有实体刘海时，Notchly 会在顶部中央使用紧凑的虚拟岛外观。")
                    .settingsHint()
            }

            SettingsCard(title: "收起状态", icon: "capsule") {
                Picker("收起状态", selection: $settings.compactDisplayMode) {
                    ForEach(CompactDisplayMode.allCases) { mode in
                        Text(mode.title).tag(mode)
                    }
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                Text(settings.compactDisplayMode.detail)
                    .settingsHint()
                Text("歌词模式仅显示当前句并在有限空间内自动截断；极简模式不运行常驻时间刷新。")
                    .settingsHint()
            }

            SettingsCard(title: "悬停交互", icon: "hand.point.up.left.fill") {
                SettingLine(title: "悬停自动展开", detail: "鼠标进入刘海后直接显示播放器") {
                    Toggle("", isOn: $settings.expandsOnHover).labelsHidden()
                }
                Divider()
                SettingsSliderRow(
                    title: "移出后收起",
                    value: $settings.autoCollapseDelay,
                    range: 0.3...2.0,
                    step: 0.1,
                    valueText: String(format: "%.1f 秒", settings.autoCollapseDelay)
                )
            }

            SettingsCard(title: "音乐动效", icon: "waveform") {
                Picker("音乐动效", selection: $settings.musicVisualizerStyle) {
                    ForEach(MusicVisualizerStyle.allCases) { style in
                        Text(style.title).tag(style)
                    }
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                Text("频谱与波形显示在歌曲信息下方；脉冲与宇宙尘埃围绕封面显示。")
                    .settingsHint()
                Text("所有动效均使用稳定的本地模拟动画，不读取系统音频，也不需要额外的录制权限。")
                    .settingsHint()
            }

            SettingsCard(title: "歌词同步", icon: "metronome") {
                SettingLine(title: "显示翻译", detail: "歌词源提供翻译时显示原文与译文") {
                    Toggle("", isOn: $settings.showsTranslatedLyrics).labelsHidden()
                }
                Divider()
                SettingsSliderRow(
                    title: "时间偏移",
                    value: $settings.lyricOffset,
                    range: -3...3,
                    step: 0.1,
                    valueText: String(format: "%+.1f 秒", settings.lyricOffset)
                )
                HStack {
                    Text("快捷校准位于播放器歌词右侧；此偏移同时影响灵动岛与桌面歌词。").settingsHint()
                    Spacer()
                    Button("重置") { settings.lyricOffset = 0 }
                }
                Text("翻译直接使用歌词源返回的内容，不调用 AI 或额外翻译服务；没有译文时自动保持单语显示。")
                    .settingsHint()
            }

            SettingsCard(title: "主题色", icon: "paintpalette") {
                Picker("主题色", selection: $settings.islandAccentTheme) {
                    ForEach(IslandAccentTheme.allCases) { theme in
                        Text(theme.title).tag(theme)
                    }
                }
                .pickerStyle(.segmented)
                Text("影响灵动岛的频谱、歌词标记、封面光晕和文件托盘；默认使用当前的霓虹紫。")
                    .settingsHint()
            }

            SettingsCard(title: "模块卡片", icon: "rectangle.3.group") {
                Picker("排序区域", selection: $cardOrderContext) {
                    ForEach(IslandCardContext.allCases) { context in
                        Text(context.title).tag(context)
                    }
                }
                .labelsHidden()
                .pickerStyle(.segmented)

                ForEach(Array(settings.islandCardOrder(for: cardOrderContext).enumerated()), id: \.element) { index, id in
                    if index > 0 {
                        Divider()
                    }
                    if let card = IslandCardRegistry.registration(for: id) {
                        SettingLine(title: card.title, detail: card.detail) {
                            HStack(spacing: 8) {
                                Toggle("", isOn: islandCardEnabledBinding(card.id))
                                    .labelsHidden()
                                Button {
                                    settings.moveIslandCard(card.id, by: -1, in: cardOrderContext)
                                } label: {
                                    Image(systemName: "chevron.up")
                                }
                                .buttonStyle(.borderless)
                                .disabled(!settings.canMoveIslandCard(card.id, by: -1, in: cardOrderContext))
                                .help("向前移动")
                                .accessibilityLabel("将\(card.title)向前移动")
                                Button {
                                    settings.moveIslandCard(card.id, by: 1, in: cardOrderContext)
                                } label: {
                                    Image(systemName: "chevron.down")
                                }
                                .buttonStyle(.borderless)
                                .disabled(!settings.canMoveIslandCard(card.id, by: 1, in: cardOrderContext))
                                .help("向后移动")
                                .accessibilityLabel("将\(card.title)向后移动")
                            }
                            .fixedSize()
                        }
                    }
                }
                HStack(alignment: .firstTextBaseline) {
                    Text(cardOrderContext.orderingHint)
                        .settingsHint()
                    Spacer()
                    Button("恢复默认") {
                        settings.resetIslandCardOrder(in: cardOrderContext)
                    }
                    .buttonStyle(.borderless)
                    .disabled(
                        settings.islandCardOrder(for: cardOrderContext)
                            == IslandCardRegistry.defaultOrder(for: cardOrderContext)
                    )
                }
                Text("顺序和开关会保存在本机；关闭电池后会同时停止后台电源轮询。")
                    .settingsHint()
            }

            SettingsCard(title: "临时文件托盘", icon: "tray.full") {
                SettingLine(title: "自动清理", detail: "超过保存期限的暂存副本会被删除") {
                    Stepper("保留 \(settings.pocketRetentionDays) 天", value: $settings.pocketRetentionDays, in: 1...30)
                        .fixedSize()
                }
                Divider()
                SettingLine(title: "容量上限", detail: "达到上限后停止接收新文件") {
                    Stepper("\(settings.pocketCapacityMB) MB", value: $settings.pocketCapacityMB, in: 128...2_048, step: 128)
                        .fixedSize()
                }
                Text("文件只会复制到 Notchly 的本地专用目录，不会上传。")
                    .settingsHint()
            }

            Label("普通桌面中，紧凑岛会留在内建显示器的刘海两侧；全屏显示由上方开关控制。", systemImage: "checkmark.shield")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 4)
        }
    }

    private func openSystemNotificationSettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.notifications") else { return }
        NSWorkspace.shared.open(url)
    }

    private func islandCardEnabledBinding(_ id: IslandCardID) -> Binding<Bool> {
        Binding(
            get: { settings.isIslandCardEnabled(id) },
            set: { settings.setIslandCardEnabled(id, enabled: $0) }
        )
    }

    private var desktopLyricsSettings: some View {
        SettingsPage(title: "桌面歌词", subtitle: "浮窗外观与显示行为") {
            LyricsSettingsPreview(settings: settings)

            SettingsCard(title: "显示与外观", icon: "text.bubble") {
                SettingLine(title: "显示桌面歌词", detail: "在所有桌面空间上悬浮显示") {
                    Toggle("", isOn: $settings.showsDesktopLyrics).labelsHidden()
                }
                Divider()
                SettingLine(title: "显示方式", detail: "双行时当前句居左、下一句居右") {
                    Picker("显示方式", selection: $settings.desktopLyricsShowsNextLine) {
                        Text("单行").tag(false)
                        Text("双行").tag(true)
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)
                    .frame(width: 132)
                }
                Text("开启音乐设置中的“显示翻译”后，有译文的歌曲会优先将第二行用于当前歌词翻译。")
                    .settingsHint()
                Divider()
                SettingLine(title: "KTV 覆盖色", detail: "颜色跟随当前歌词的播放进度推进") {
                    Toggle("", isOn: $settings.desktopLyricsKaraokeEnabled).labelsHidden()
                }
                Divider()
                SettingLine(title: "锁定歌词", detail: "锁定后允许鼠标穿透，不影响桌面操作") {
                    Toggle("", isOn: $settings.desktopLyricsLocked).labelsHidden()
                }
                Picker("配色", selection: $settings.desktopLyricsTheme) {
                    ForEach(DesktopLyricsTheme.allCases) { theme in
                        Text(theme.title).tag(theme)
                    }
                }
                .pickerStyle(.segmented)
                SettingsSliderRow(
                    title: "歌词字号",
                    value: $settings.desktopLyricsFontSize,
                    range: 18...38,
                    step: 1,
                    valueText: "\(Int(settings.desktopLyricsFontSize)) pt"
                )
                SettingsSliderRow(
                    title: "背景浓度",
                    value: $settings.desktopLyricsBackgroundOpacity,
                    range: 0...0.85,
                    step: 0.05,
                    valueText: "\(Int(settings.desktopLyricsBackgroundOpacity * 100))%"
                )
                HStack {
                    Text("未锁定时可拖动，悬停显示播放控制；锁定后可在歌词右下角直接解锁。").settingsHint()
                    Spacer()
                    Button("恢复默认位置") { settings.resetDesktopLyricsPosition() }
                }
            }

            Text("支持：网易云音乐、QQ音乐、酷狗音乐、酷我音乐、汽水音乐、Apple Music 与 Spotify 桌面版。")
                .settingsHint()
                .padding(.horizontal, 4)
        }
    }

    private var aboutSettings: some View {
        SettingsPage(title: "关于", subtitle: "版本信息、更新与反馈") {
            HStack(spacing: 16) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 72, height: 72)
                    .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                    .shadow(color: .black.opacity(0.12), radius: 8, y: 3)

                VStack(alignment: .leading, spacing: 4) {
                    Text("Notchly")
                        .font(.title.weight(.bold))
                    Text("让 Mac 的刘海更有用")
                        .font(.headline)
                        .foregroundStyle(.secondary)
                    Text("Alpha 内测版")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(.quaternary, in: Capsule())
                }
            }
            .padding(.horizontal, 4)
            .padding(.vertical, 4)

            SettingsCard(title: "版本", icon: "shippingbox") {
                SettingLine(title: "当前版本", detail: "版本 \(appVersion) · 构建 \(buildNumber)") {
                    Button("检查更新") {
                        aboutMessage = "当前为 Alpha 内测版，正式发布前将接入自动更新通道。"
                    }
                }
                Divider()
                SettingLine(title: "诊断信息", detail: "反馈问题时附上运行状态与匿名计数") {
                    Button("复制") { copyDiagnosticInfo() }
                }
                if let aboutMessage {
                    Label(aboutMessage, systemImage: "checkmark.circle.fill")
                        .settingsHint()
                        .foregroundStyle(.secondary)
                }
            }

            SettingsCard(title: "开源与支持", icon: "chevron.left.forwardslash.chevron.right") {
                SettingLine(title: "开源仓库", detail: "浏览源码、更新记录并参与开发") {
                    Button("打开 GitHub") { openExternalURL(projectRepositoryURL) }
                        .buttonStyle(.bordered)
                }
                Divider()
                SettingLine(title: "支持项目", detail: "微信或支付宝自愿赞赏，支持持续开发") {
                    Button("查看赞赏页") { openExternalURL(donationPageURL) }
                        .buttonStyle(.bordered)
                }
            }

            SettingsCard(title: "帮助与反馈", icon: "bubble.left.and.bubble.right") {
                SettingLine(title: "反馈与建议", detail: "在 GitHub Issues 中提交问题或建议") {
                    Button("提交反馈") { openExternalURL(projectIssuesURL) }
                        .buttonStyle(.borderedProminent)
                }
                Divider()
                SettingLine(title: "反馈模板", detail: "复制版本与系统信息，便于定位问题") {
                    Button("复制模板") { copyFeedbackTemplate() }
                }
                Divider()
                SettingLine(title: "报告安全问题", detail: "通过 GitHub 私密提交漏洞或敏感信息") {
                    Button("私密报告") { openExternalURL(projectSecurityReportURL) }
                }
                Divider()
                SettingLine(title: "第三方许可", detail: "查看项目使用的开源组件与许可") {
                    Button("查看") { openThirdPartyNotices() }
                }
                Divider()
                SettingLine(title: "开源协议", detail: "查看 Notchly 的 MIT License") {
                    Button("查看") { openBundledDocument(resource: "LICENSE", fileExtension: nil) }
                }
                Divider()
                SettingLine(title: "隐私政策", detail: "本地数据、系统权限与第三方请求说明") {
                    Button("查看") { openBundledDocument(resource: "PRIVACY", fileExtension: "md") }
                }
            }

            SettingsCard(title: "创作与版权", icon: "person.crop.circle") {
                SettingLine(title: "工作室", detail: "项目创作与维护") {
                    Text("韩十久工作室（Hanshijiu Studio）")
                        .font(.body.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
                Divider()
                SettingLine(title: "版权所有", detail: "© 2026 Stephan Li（韩十久工作室 · Hanshijiu Studio）") {
                    Text("MIT License")
                        .font(.body.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
            }

            Text("问题与建议会在 GitHub Issues 中公开跟进；漏洞或敏感信息请使用“报告安全问题”私密提交。")
                .settingsHint()
                .padding(.horizontal, 4)
        }
    }

    private var projectRepositoryURL: URL {
        URL(string: "https://github.com/lglglglglg/Notchly")!
    }

    private var projectIssuesURL: URL {
        URL(string: "https://github.com/lglglglglg/Notchly/issues")!
    }

    private var projectSecurityReportURL: URL {
        URL(string: "https://github.com/lglglglglg/Notchly/security/advisories/new")!
    }

    private var donationPageURL: URL {
        URL(string: "https://github.com/lglglglglg/Notchly/blob/main/docs/DONATE.md")!
    }

    private var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—"
    }

    private var buildNumber: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "—"
    }

    private var diagnosticInfo: String {
        let enabledCards = IslandCardRegistry.registrations
            .filter { settings.enabledIslandCards.contains($0.id) }
            .map(\.title)
            .joined(separator: "、")
        let musicCardOrder = cardOrderDescription(for: .musicFooter)
        let idleCardOrder = cardOrderDescription(for: .idleDashboard)
        return """
        \(DiagnosticStore.shared.formattedSnapshot(appVersion: appVersion, buildNumber: buildNumber))

        显示设置
        场景预设：\(settings.activeIslandScenePreset.title)
        显示器策略：\(settings.islandDisplayStrategy.title)
        收起状态：\(settings.compactDisplayMode.title)
        启用卡片：\(enabledCards.isEmpty ? "无" : enabledCards)
        音乐区卡片顺序：\(musicCardOrder)
        待机卡片顺序：\(idleCardOrder)
        全屏自动隐藏：\(settings.hidesIslandInFullScreen ? "开启" : "关闭")
        """
    }

    private func cardOrderDescription(for context: IslandCardContext) -> String {
        settings.islandCardOrder(for: context)
            .compactMap { IslandCardRegistry.registration(for: $0)?.title }
            .joined(separator: " → ")
    }

    private func copyDiagnosticInfo() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(diagnosticInfo, forType: .string)
        aboutMessage = "诊断信息已复制，可直接粘贴到反馈中。"
    }

    private func copyFeedbackTemplate() {
        let template = """
        Notchly 反馈

        问题或建议：

        复现步骤：
        1.
        2.

        \(diagnosticInfo)
        """
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(template, forType: .string)
        aboutMessage = "反馈模板已复制，可以直接粘贴并补充内容。"
    }

    private func openThirdPartyNotices() {
        openBundledDocument(resource: "THIRD_PARTY_NOTICES", fileExtension: "txt")
    }

    private func openExternalURL(_ url: URL) {
        NSWorkspace.shared.open(url)
    }

    private func openBundledDocument(resource: String, fileExtension: String?) {
        guard let url = Bundle.main.url(forResource: resource, withExtension: fileExtension) else {
            aboutMessage = "暂未找到相关文档。"
            return
        }
        NSWorkspace.shared.open(url)
    }
}

private struct SettingsPage<Content: View>: View {
    let title: String
    let subtitle: String
    @ViewBuilder let content: Content

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(title).font(.title2.weight(.bold))
                    Text(subtitle).font(.subheadline).foregroundStyle(.secondary)
                }
                .padding(.bottom, 2)
                content
            }
            .padding(.horizontal, 28)
            .padding(.vertical, 22)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }
}

private struct SettingsCard<Content: View>: View {
    let title: String
    let icon: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(title, systemImage: icon)
                .font(.headline)
                .foregroundStyle(.primary)
            content
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(.separator.opacity(0.55), lineWidth: 0.6)
        }
    }
}

private struct SettingLine<Trailing: View>: View {
    let title: String
    let detail: String
    @ViewBuilder let trailing: Trailing

    var body: some View {
        HStack(alignment: .center, spacing: 16) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                Text(detail).settingsHint()
            }
            Spacer(minLength: 18)
            trailing
        }
    }
}

private struct SettingsSliderRow: View {
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    let step: Double
    let valueText: String

    var body: some View {
        HStack(spacing: 12) {
            Text(title).frame(width: 92, alignment: .leading)
            Slider(value: $value, in: range, step: step)
            Text(valueText)
                .font(.callout.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 62, alignment: .trailing)
        }
    }
}

private struct LyricsSettingsPreview: View {
    @ObservedObject var settings: AppSettings

    var body: some View {
        VStack(spacing: 3) {
            ZStack {
                previewText.foregroundStyle(.white.opacity(settings.desktopLyricsKaraokeEnabled ? 0.28 : 0.96))
                if settings.desktopLyricsKaraokeEnabled {
                    previewText
                        .foregroundStyle(LinearGradient(colors: activeColors, startPoint: .leading, endPoint: .trailing))
                        .mask {
                            GeometryReader { proxy in
                                Rectangle()
                                    .frame(width: proxy.size.width * 0.58)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }
                }
            }
            .frame(maxWidth: .infinity, alignment: settings.desktopLyricsShowsNextLine ? .leading : .center)

            if settings.desktopLyricsShowsNextLine {
                Text("下一句会轻轻出现在这里")
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.42))
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
        }
        .padding(.horizontal, 20)
        .frame(maxWidth: .infinity)
        .frame(height: settings.desktopLyricsShowsNextLine ? 70 : 54)
        .background(
            LinearGradient(
                colors: [.black.opacity(settings.desktopLyricsBackgroundOpacity), tint.opacity(settings.desktopLyricsBackgroundOpacity)],
                startPoint: .leading,
                endPoint: .trailing
            ),
            in: RoundedRectangle(cornerRadius: 16, style: .continuous)
        )
        .overlay(alignment: .topTrailing) {
            Text("预览")
                .font(.caption2.weight(.medium))
                .foregroundStyle(.white.opacity(0.55))
                .padding(10)
        }
    }

    private var previewText: some View {
        Text("正在播放的歌词")
            .font(.system(size: min(settings.desktopLyricsFontSize, 28), weight: .bold, design: .rounded))
            .lineLimit(1)
    }

    private var activeColors: [Color] {
        switch settings.desktopLyricsTheme {
        case .white: [.white, Color(nsColor: .lightGray)]
        case .violet: [.pink, .purple, .cyan]
        case .ocean: [.mint, .cyan, .blue]
        case .sunset: [.yellow, .orange, .pink]
        }
    }

    private var tint: Color {
        switch settings.desktopLyricsTheme {
        case .white: .black
        case .violet: .indigo
        case .ocean: .blue
        case .sunset: .purple
        }
    }
}

private extension View {
    func settingsHint() -> some View {
        font(.caption).foregroundStyle(.secondary)
    }
}
