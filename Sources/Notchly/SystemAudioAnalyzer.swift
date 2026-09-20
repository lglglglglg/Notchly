import CoreAudio
import CoreGraphics
import CoreMedia
import Foundation
import ScreenCaptureKit

struct AudioReactiveFrame: Sendable, Equatable {
    let energy: Double
    let bands: [Double]

    static let silence = AudioReactiveFrame(energy: 0, bands: Array(repeating: 0, count: 8))
}

/// Captures only the system audio stream when the user explicitly enables the
/// reactive visualizer. No screen output is registered, and audio samples are
/// reduced immediately to a tiny transient energy value on this device.
@MainActor
final class SystemAudioAnalyzer: NSObject {
    var onFrame: (@MainActor (AudioReactiveFrame) -> Void)?
    var onStatus: (@MainActor (String?) -> Void)?

    private var stream: SCStream?
    private var startTask: Task<Void, Never>?
    private var generation = 0
    private var hasRequestedPermission = false
    private var hasReceivedAudio = false
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
        hasReceivedAudio = false
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
                // ScreenCaptureKit officially supports 8/16/24/48 kHz. Using
                // 44.1 kHz relies on a fallback and can leave some output
                // devices delivering no usable audio samples.
                configuration.sampleRate = 48_000
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
                onStatus?("已连接系统音频，等待播放声音…")
                Task { [weak self, weak candidate] in
                    try? await Task.sleep(for: .seconds(2))
                    guard let self,
                          self.stream === candidate,
                          !self.hasReceivedAudio else { return }
                    self.onStatus?("已连接但未收到音频样本；请确认声音正在从当前 Mac 输出设备播放")
                }
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
        hasReceivedAudio = false
        meter.reset()
        onFrame?(.silence)
        onStatus?(nil)
        guard let activeStream else { return }
        Task { try? await activeStream.stopCapture() }
    }

    private func handleStop(error: Error) {
        stream = nil
        startTask = nil
        hasReceivedAudio = false
        meter.reset()
        onFrame?(.silence)
        onStatus?("系统音频连接已中断；播放时会自动重试")
    }

    private func receiveAudioFrame(_ frame: AudioReactiveFrame) {
        if !hasReceivedAudio {
            hasReceivedAudio = true
            onStatus?("正在根据系统音频律动")
        }
        onFrame?(frame)
    }
}

extension SystemAudioAnalyzer: SCStreamOutput {
    nonisolated func stream(
        _ stream: SCStream,
        didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
        of outputType: SCStreamOutputType
    ) {
        guard outputType == .audio,
              let frame = meter.ingest(sampleBuffer: sampleBuffer) else { return }
        Task { @MainActor [weak self] in
            self?.receiveAudioFrame(frame)
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
    private var fastEnvelope = 0.0
    private var slowEnvelope = 0.0
    private var peakSinceLastEmission = 0.0
    private var hasEnvelopeBaseline = false
    private var lastEmission = 0.0

    func reset() {
        fastEnvelope = 0
        slowEnvelope = 0
        peakSinceLastEmission = 0
        hasEnvelopeBaseline = false
        lastEmission = 0
    }

    func ingest(sampleBuffer: CMSampleBuffer) -> AudioReactiveFrame? {
        let rawLevel = Self.energy(from: sampleBuffer)
        // Keep a quick and a slow envelope. Their difference is a true local
        // transient from the captured audio (kick, snare or accent), not a
        // timeline animation. A short peak hold ensures a hit remains visible
        // at the UI's 30 Hz update rate, then drops rapidly before the next one.
        if !hasEnvelopeBaseline {
            fastEnvelope = rawLevel
            slowEnvelope = rawLevel
            hasEnvelopeBaseline = true
        } else {
            fastEnvelope = fastEnvelope * 0.56 + rawLevel * 0.44
            slowEnvelope = slowEnvelope * 0.975 + rawLevel * 0.025
        }
        let transient = max(0, fastEnvelope - slowEnvelope - 0.006)
        let sustainedFloor = min(0.16, rawLevel * 0.16)
        let target = min(1, sustainedFloor + transient * 20)
        peakSinceLastEmission = max(target, peakSinceLastEmission * 0.54)
        let now = ProcessInfo.processInfo.systemUptime
        guard now - lastEmission >= 1.0 / 30.0 else { return nil }
        lastEmission = now
        let emittedPeak = peakSinceLastEmission
        peakSinceLastEmission *= 0.22
        return AudioReactiveFrame(
            energy: emittedPeak,
            bands: Self.frequencyBands(from: sampleBuffer)
        )
    }

    /// A compact Goertzel bank measures eight musically useful regions from
    /// the real PCM buffer. It is much cheaper than retaining audio or running
    /// a large FFT, yet gives the renderer independent bass/mid/treble bars.
    private static func frequencyBands(from sampleBuffer: CMSampleBuffer) -> [Double] {
        guard let format = CMSampleBufferGetFormatDescription(sampleBuffer),
              let description = CMAudioFormatDescriptionGetStreamBasicDescription(format)?.pointee,
              description.mFormatID == kAudioFormatLinearPCM,
              description.mBitsPerChannel == 32,
              description.mFormatFlags & kAudioFormatFlagIsFloat != 0,
              description.mSampleRate > 0 else { return [] }

        var neededBytes = 0
        CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            sampleBuffer,
            bufferListSizeNeededOut: &neededBytes,
            bufferListOut: nil,
            bufferListSize: 0,
            blockBufferAllocator: nil,
            blockBufferMemoryAllocator: nil,
            flags: 0,
            blockBufferOut: nil
        )
        guard neededBytes > 0 else { return [] }

        let rawBufferList = UnsafeMutableRawPointer.allocate(
            byteCount: neededBytes,
            alignment: MemoryLayout<AudioBufferList>.alignment
        )
        defer { rawBufferList.deallocate() }
        let bufferList = rawBufferList.assumingMemoryBound(to: AudioBufferList.self)
        var retainedBlockBuffer: CMBlockBuffer?
        let status = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            sampleBuffer,
            bufferListSizeNeededOut: nil,
            bufferListOut: bufferList,
            bufferListSize: neededBytes,
            blockBufferAllocator: kCFAllocatorDefault,
            blockBufferMemoryAllocator: kCFAllocatorDefault,
            flags: 0,
            blockBufferOut: &retainedBlockBuffer
        )
        guard status == noErr,
              let firstBuffer = UnsafeMutableAudioBufferListPointer(bufferList).first,
              let data = firstBuffer.mData else { return [] }

        let values = data.assumingMemoryBound(to: Float.self)
        let valueCount = Int(firstBuffer.mDataByteSize) / MemoryLayout<Float>.size
        let channelStride = bufferList.pointee.mNumberBuffers == 1
            ? max(1, Int(description.mChannelsPerFrame))
            : 1
        let frameCount = min(1_024, valueCount / channelStride)
        guard frameCount >= 96 else { return [] }

        var samples = [Double]()
        samples.reserveCapacity(frameCount)
        for frame in 0..<frameCount {
            samples.append(Double(values[frame * channelStride]))
        }

        let centers = [70.0, 130, 250, 500, 1_000, 2_000, 4_000, 8_000]
        return centers.map { frequency in
            let nyquistSafeFrequency = min(frequency, description.mSampleRate * 0.42)
            let bin = Int((Double(frameCount) * nyquistSafeFrequency / description.mSampleRate).rounded())
            let omega = 2 * Double.pi * Double(bin) / Double(frameCount)
            let coefficient = 2 * cos(omega)
            var previous = 0.0
            var previousPrevious = 0.0
            for (index, sample) in samples.enumerated() {
                let window = 0.54 - 0.46 * cos(2 * Double.pi * Double(index) / Double(frameCount - 1))
                let current = sample * window + coefficient * previous - previousPrevious
                previousPrevious = previous
                previous = current
            }
            let magnitude = sqrt(max(0, previous * previous + previousPrevious * previousPrevious - coefficient * previous * previousPrevious)) / Double(frameCount)
            let decibels = 20 * log10(max(magnitude, 0.000_01))
            return min(max((decibels + 58) / 42, 0), 1)
        }
    }

    private static func energy(from sampleBuffer: CMSampleBuffer) -> Double {
        guard let format = CMSampleBufferGetFormatDescription(sampleBuffer),
              let basicDescription = CMAudioFormatDescriptionGetStreamBasicDescription(format)?.pointee,
              basicDescription.mFormatID == kAudioFormatLinearPCM else {
            return 0
        }

        // ScreenCaptureKit may hand us interleaved or non-interleaved audio,
        // and the bytes are not guaranteed to live in one CMBlockBuffer. Ask
        // CoreMedia for its canonical AudioBufferList so every supported
        // player/device layout contributes to the level meter.
        var neededBytes = 0
        CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            sampleBuffer,
            bufferListSizeNeededOut: &neededBytes,
            bufferListOut: nil,
            bufferListSize: 0,
            blockBufferAllocator: nil,
            blockBufferMemoryAllocator: nil,
            flags: 0,
            blockBufferOut: nil
        )
        guard neededBytes > 0 else { return 0 }

        let rawBufferList = UnsafeMutableRawPointer.allocate(
            byteCount: neededBytes,
            alignment: MemoryLayout<AudioBufferList>.alignment
        )
        defer { rawBufferList.deallocate() }
        let bufferList = rawBufferList.assumingMemoryBound(to: AudioBufferList.self)
        var retainedBlockBuffer: CMBlockBuffer?
        let status = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            sampleBuffer,
            bufferListSizeNeededOut: nil,
            bufferListOut: bufferList,
            bufferListSize: neededBytes,
            blockBufferAllocator: kCFAllocatorDefault,
            blockBufferMemoryAllocator: kCFAllocatorDefault,
            flags: 0,
            blockBufferOut: &retainedBlockBuffer
        )
        guard status == noErr else { return 0 }

        let isFloat = basicDescription.mFormatFlags & kAudioFormatFlagIsFloat != 0
        var sumOfSquares = 0.0
        var sampleCount = 0
        for audioBuffer in UnsafeMutableAudioBufferListPointer(bufferList) {
            guard let data = audioBuffer.mData, audioBuffer.mDataByteSize > 0 else { continue }
            switch (basicDescription.mBitsPerChannel, isFloat) {
            case (32, true):
                let values = data.assumingMemoryBound(to: Float.self)
                let count = Int(audioBuffer.mDataByteSize) / MemoryLayout<Float>.size
                for index in 0..<count {
                    let value = Double(values[index])
                    sumOfSquares += value * value
                }
                sampleCount += count
            case (16, false):
                let values = data.assumingMemoryBound(to: Int16.self)
                let count = Int(audioBuffer.mDataByteSize) / MemoryLayout<Int16>.size
                for index in 0..<count {
                    let value = Double(values[index]) / Double(Int16.max)
                    sumOfSquares += value * value
                }
                sampleCount += count
            case (32, false):
                let values = data.assumingMemoryBound(to: Int32.self)
                let count = Int(audioBuffer.mDataByteSize) / MemoryLayout<Int32>.size
                for index in 0..<count {
                    let value = Double(values[index]) / Double(Int32.max)
                    sumOfSquares += value * value
                }
                sampleCount += count
            default:
                return 0
            }
        }
        guard sampleCount > 0 else { return 0 }

        let decibels = 20 * log10(max(sqrt(sumOfSquares / Double(sampleCount)), 0.000_01))
        return min(max((decibels + 56) / 44, 0), 1)
    }
}
