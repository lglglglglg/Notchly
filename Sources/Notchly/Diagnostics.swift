import AppKit
import Darwin
import Foundation

/// A local-only, privacy-conscious runtime snapshot used for bug reports.
/// It intentionally records counters and health state, never titles, paths,
/// account identifiers, calendar contents, or file names.
@MainActor
final class DiagnosticStore {
    static let shared = DiagnosticStore()

    let launchedAt = Date()
    private(set) var musicSnapshotRequests = 0
    private(set) var musicSnapshotSuccesses = 0
    private(set) var musicSnapshotFailures = 0
    private(set) var mediaRemoteEvents = 0
    private(set) var mediaRemotePublished = 0
    private(set) var mediaRemoteDeduplicated = 0
    private(set) var mediaRemoteInvalid = 0
    private(set) var listenerStarts = 0
    private(set) var listenerStops = 0
    private(set) var listenerRestarts = 0
    private(set) var artworkCacheHits = 0
    private(set) var artworkCacheMisses = 0
    private(set) var lastMediaRemoteEventAt: Date?
    private(set) var lastSuccessfulSnapshotAt: Date?
    private(set) var lastMediaRemoteError: String?
    private(set) var activeProvider = "无"
    private(set) var mediaRemoteListening = false

    private init() {}

    func recordMusicSnapshotRequest() { musicSnapshotRequests += 1 }
    func recordMusicSnapshotSuccess(provider: String?) {
        musicSnapshotSuccesses += 1
        lastSuccessfulSnapshotAt = Date()
        if let provider, !provider.isEmpty { activeProvider = provider }
    }
    func recordMusicSnapshotFailure() { musicSnapshotFailures += 1 }
    func recordMediaRemoteEvent() {
        mediaRemoteEvents += 1
        lastMediaRemoteEventAt = Date()
    }
    func recordMediaRemotePublished(provider: String) {
        mediaRemotePublished += 1
        activeProvider = provider
    }
    func recordMediaRemoteDeduplicated() { mediaRemoteDeduplicated += 1 }
    func recordMediaRemoteInvalid(_ reason: String? = nil) {
        mediaRemoteInvalid += 1
        if let reason, !reason.isEmpty { lastMediaRemoteError = reason }
    }
    func recordListenerStarted() { listenerStarts += 1; mediaRemoteListening = true }
    func recordListenerStopped() { listenerStops += 1; mediaRemoteListening = false }
    func recordListenerRestart() { listenerRestarts += 1 }
    func recordArtworkCache(hit: Bool) {
        if hit { artworkCacheHits += 1 } else { artworkCacheMisses += 1 }
    }
    func setMediaRemoteListening(_ listening: Bool) { mediaRemoteListening = listening }
    func setActiveProvider(_ provider: String?) {
        activeProvider = provider?.isEmpty == false ? provider! : "无"
    }

    var uptime: TimeInterval { Date().timeIntervalSince(launchedAt) }

    func formattedSnapshot(appVersion: String, buildNumber: String) -> String {
        let process = ProcessInfo.processInfo
        let os = process.operatingSystemVersion
        let osVersion = "\(os.majorVersion).\(os.minorVersion).\(os.patchVersion)"
        let lastEvent = lastMediaRemoteEventAt.map(Self.formatDate) ?? "无"
        let lastSnapshot = lastSuccessfulSnapshotAt.map(Self.formatDate) ?? "无"
        let lastError = lastMediaRemoteError ?? "无"
        let runtime = Self.runtimeUsage(uptime: uptime)
        #if arch(arm64)
        let architecture = "Apple Silicon"
        #else
        let architecture = "Intel"
        #endif

        return """
        Notchly 诊断信息
        ====================
        版本：\(appVersion) (\(buildNumber))
        macOS：\(osVersion) (\(process.operatingSystemVersionString))
        架构：\(architecture)
        运行时长：\(Self.formatDuration(uptime))
        当前物理内存：\(Self.formatBytes(runtime.physicalFootprint))
        峰值常驻内存：\(Self.formatBytes(runtime.peakResidentMemory))
        CPU 累计时间：\(String(format: "%.1f 秒", runtime.cpuTime))
        CPU 平均占用：\(String(format: "%.1f%%", runtime.averageCPUPercent))
        诊断生成时间：\(Self.formatDate(Date()))

        媒体状态
        当前播放器：\(activeProvider)
        MediaRemote 监听：\(mediaRemoteListening ? "运行中" : "未监听")
        最近事件：\(lastEvent)
        最近成功快照：\(lastSnapshot)

        运行计数
        音乐快照请求：\(musicSnapshotRequests)
        音乐快照成功：\(musicSnapshotSuccesses)
        音乐快照失败：\(musicSnapshotFailures)
        MediaRemote 事件：\(mediaRemoteEvents)
        MediaRemote 发布：\(mediaRemotePublished)
        重复事件丢弃：\(mediaRemoteDeduplicated)
        无效事件：\(mediaRemoteInvalid)
        监听启动：\(listenerStarts)
        监听停止：\(listenerStops)
        自动重连：\(listenerRestarts)
        封面缓存命中：\(artworkCacheHits)
        封面缓存未命中：\(artworkCacheMisses)
        最近诊断错误：\(lastError)

        说明：以上信息仅包含版本、系统和匿名运行计数，不包含歌曲名、文件路径、日历内容或账号信息。
        """
    }

    private static func formatDate(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }

    private static func formatDuration(_ duration: TimeInterval) -> String {
        let total = max(0, Int(duration))
        return String(format: "%02d:%02d:%02d", total / 3600, (total / 60) % 60, total % 60)
    }

    private static func formatBytes(_ bytes: UInt64) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(clamping: bytes), countStyle: .memory)
    }

    private static func runtimeUsage(uptime: TimeInterval) -> (
        physicalFootprint: UInt64,
        peakResidentMemory: UInt64,
        cpuTime: TimeInterval,
        averageCPUPercent: Double
    ) {
        var vmInfo = task_vm_info_data_t()
        var vmCount = mach_msg_type_number_t(
            MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size
        )
        let vmResult = withUnsafeMutablePointer(to: &vmInfo) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(vmCount)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &vmCount)
            }
        }

        var usage = rusage()
        let usageResult = getrusage(RUSAGE_SELF, &usage)
        let cpuTime: TimeInterval
        let peakResident: UInt64
        if usageResult == 0 {
            cpuTime = TimeInterval(usage.ru_utime.tv_sec)
                + TimeInterval(usage.ru_utime.tv_usec) / 1_000_000
                + TimeInterval(usage.ru_stime.tv_sec)
                + TimeInterval(usage.ru_stime.tv_usec) / 1_000_000
            peakResident = UInt64(max(0, usage.ru_maxrss))
        } else {
            cpuTime = 0
            peakResident = 0
        }

        return (
            physicalFootprint: vmResult == KERN_SUCCESS ? UInt64(vmInfo.phys_footprint) : 0,
            peakResidentMemory: peakResident,
            cpuTime: cpuTime,
            averageCPUPercent: uptime > 0 ? cpuTime / uptime * 100 : 0
        )
    }
}
