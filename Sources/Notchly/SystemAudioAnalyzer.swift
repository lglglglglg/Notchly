import CoreAudio
import CoreGraphics
import CoreMedia
import Foundation
import ScreenCaptureKit

/// Captures only the system audio stream when the user explicitly enables the
/// reactive visualizer. No screen output is registered, and audio samples are
/// reduced immediately to a tiny transient energy value on this device.
@MainActor
final class SystemAudioAnalyzer: NSObject {
    var onLevel: (@MainActor (Double) -> Void)?
    var onStatus: (@MainActor (String?) -> Void)?

    private var stream: SCStream?
    private var startTask: Task<Void, Never>?
    private var generation = 0
    private var hasRequestedPermission = false
    private let audioQueue = DispatchQueue(label: "com.notchly.audio-reactive", qos: .userInteractive)
    nonisolated private let meter = AudioEnergyMeter()

    func start() {
        guard stream == nil, startTask == nil else { return }
        guard CGPreflightScreenCaptureAccess() else {
            if !hasRequestedPermission {
                hasRequestedPermission = true
                _ = CGRequestScreenCaptureAccess()
            }
            onStatus?("需要允许“屏幕与系统音频录制”后才能启用真实律动")
            return
        }

        generation += 1
        let expectedGeneration = generation
        onStatus?("正在连接系统音频…")
        startTask = Task { [weak self] in
            guard let self else { return }
            do {
                let content = try await SCShareableContent.excludingDesktopWindows(
                    false,
                    onScreenWindowsOnly: true
                )
                guard let display = content.displays.first else {
                    throw SystemAudioAnalyzerError.noDisplay
                }
                guard !Task.isCancelled, generation == expectedGeneration else { return }

                let filter = SCContentFilter(
                    display: display,
                    excludingApplications: [],
                    exceptingWindows: []
                )
                let configuration = SCStreamConfiguration()
                // ScreenCaptureKit uses a display filter even for audio. Keeping
                // the unused video surface at 2×2 avoids allocating a full-size
                // screen buffer; only `.audio` is registered below.
                configuration.width = 2
                configuration.height = 2
                configuration.minimumFrameInterval = CMTime(value: 1, timescale: 2)
                configuration.queueDepth = 3
                configuration.capturesAudio = true
                configuration.excludesCurrentProcessAudio = true
                configuration.sampleRate = 44_100
                configuration.channelCount = 2

                let candidate = SCStream(
                    filter: filter,
                    configuration: configuration,
                    delegate: self
                )
                try candidate.addStreamOutput(
                    self,
                    type: .audio,
                    sampleHandlerQueue: audioQueue
                )
                try await candidate.startCapture()
                guard !Task.isCancelled, generation == expectedGeneration else {
                    try? await candidate.stopCapture()
                    return
                }
                stream = candidate
                startTask = nil
                onStatus?("正在根据系统音频律动")
            } catch {
                guard generation == expectedGeneration else { return }
                stream = nil
                startTask = nil
                onStatus?("无法读取系统音频；可在系统设置中检查“屏幕与系统音频录制”权限")
            }
        }
    }

    func stop() {
        generation += 1
        startTask?.cancel()
        startTask = nil
        let activeStream = stream
        stream = nil
        meter.reset()
        onLevel?(0)
        onStatus?(nil)
        guard let activeStream else { return }
        Task { try? await activeStream.stopCapture() }
    }

    private func handleStop(error: Error) {
        stream = nil
        startTask = nil
        meter.reset()
        onLevel?(0)
        onStatus?("系统音频连接已中断；播放时会自动重试")
    }
}

extension SystemAudioAnalyzer: SCStreamOutput {
    nonisolated func stream(
        _ stream: SCStream,
        didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
        of outputType: SCStreamOutputType
    ) {
        guard outputType == .audio,
              let level = meter.ingest(sampleBuffer: sampleBuffer) else { return }
        Task { @MainActor [weak self] in
            self?.onLevel?(level)
        }
    }
}

extension SystemAudioAnalyzer: SCStreamDelegate {
    nonisolated func stream(_ stream: SCStream, didStopWithError error: Error) {
        Task { @MainActor [weak self] in
            self?.handleStop(error: error)
        }
    }
}

private enum SystemAudioAnalyzerError: LocalizedError {
    case noDisplay

    var errorDescription: String? {
        switch self {
        case .noDisplay: "没有可用于读取系统音频的显示器"
        }
    }
}

/// This object is touched only by ScreenCaptureKit's dedicated serial audio
/// queue. It both smooths incoming RMS values and caps UI updates at 30 Hz.
private final class AudioEnergyMeter: @unchecked Sendable {
    private var smoothedLevel = 0.0
    private var rollingBaseline = 0.0
    private var lastEmission = 0.0

    func reset() {
        smoothedLevel = 0
        rollingBaseline = 0
        lastEmission = 0
    }

    func ingest(sampleBuffer: CMSampleBuffer) -> Double? {
        let rawLevel = Self.energy(from: sampleBuffer)
        // A slow baseline separates a drum hit/onset from a sustained pad or
        // vocal. The returned value still follows overall loudness, but gives
        // transient beats a clearly visible lift instead of a uniform loop.
        rollingBaseline = rollingBaseline * 0.965 + rawLevel * 0.035
        let onset = max(0, rawLevel - rollingBaseline - 0.045)
        let target = min(1, rawLevel * 0.58 + onset * 4.6)
        smoothedLevel = max(target, smoothedLevel * 0.74)
        let now = ProcessInfo.processInfo.systemUptime
        guard now - lastEmission >= 1.0 / 30.0 else { return nil }
        lastEmission = now
        return smoothedLevel
    }

    private static func energy(from sampleBuffer: CMSampleBuffer) -> Double {
        guard let format = CMSampleBufferGetFormatDescription(sampleBuffer),
              let basicDescription = CMAudioFormatDescriptionGetStreamBasicDescription(format)?.pointee,
              basicDescription.mFormatID == kAudioFormatLinearPCM,
              let dataBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else {
            return 0
        }

        var lengthAtOffset = 0
        var totalLength = 0
        var dataPointer: UnsafeMutablePointer<Int8>?
        guard CMBlockBufferGetDataPointer(
            dataBuffer,
            atOffset: 0,
            lengthAtOffsetOut: &lengthAtOffset,
            totalLengthOut: &totalLength,
            dataPointerOut: &dataPointer
        ) == noErr,
        let dataPointer,
        totalLength > 0 else { return 0 }

        let meanSquare: Double
        let isFloat = basicDescription.mFormatFlags & kAudioFormatFlagIsFloat != 0
        switch (basicDescription.mBitsPerChannel, isFloat) {
        case (32, true):
            let values = dataPointer.withMemoryRebound(to: Float.self, capacity: totalLength / 4) { buffer in
                UnsafeBufferPointer(start: buffer, count: totalLength / 4)
            }
            meanSquare = values.reduce(0) { $0 + Double($1 * $1) } / Double(max(values.count, 1))
        case (16, false):
            let values = dataPointer.withMemoryRebound(to: Int16.self, capacity: totalLength / 2) { buffer in
                UnsafeBufferPointer(start: buffer, count: totalLength / 2)
            }
            meanSquare = values.reduce(0) {
                let value = Double($1) / Double(Int16.max)
                return $0 + value * value
            } / Double(max(values.count, 1))
        case (32, false):
            let values = dataPointer.withMemoryRebound(to: Int32.self, capacity: totalLength / 4) { buffer in
                UnsafeBufferPointer(start: buffer, count: totalLength / 4)
            }
            meanSquare = values.reduce(0) {
                let value = Double($1) / Double(Int32.max)
                return $0 + value * value
            } / Double(max(values.count, 1))
        default:
            return 0
        }

        let decibels = 20 * log10(max(sqrt(meanSquare), 0.000_01))
        return min(max((decibels + 56) / 44, 0), 1)
    }
}
