import SwiftUI

struct MusicVisualizer: View {
    let style: MusicVisualizerStyle
    let isActive: Bool
    /// `nil` keeps the lightweight simulated animation. A value from 0…1 is
    /// supplied only by the opt-in local system-audio analyzer.
    var audioLevel: Double?
    /// Independent low-to-high frequency energy from the local audio stream.
    /// It is used only by the spectrum style; other styles follow the beat.
    var audioBands: [Double]?
    /// Keeps an enabled real-audio session visually distinct even before the
    /// first sample arrives: quiet means quiet, never a hidden simulated loop.
    var usesAudioReactiveMode = false
    var tint: Color = .purple
    var highlight: Color = .pink

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: !isActive)) { timeline in
            let time = timeline.date.timeIntervalSinceReferenceDate
            // Small visualizers need a slightly eased response curve: a real
            // low-level passage remains quiet, while ordinary listening volume
            // still produces a visible, beat-driven lift.
            let renderedAudioLevel = usesAudioReactiveMode
                ? min(1, pow(max(audioLevel ?? 0, 0), 0.62) * 1.06)
                : nil
            Group {
                switch style {
                case .spectrum: spectrum(time: time, level: renderedAudioLevel, bands: audioBands)
                case .waveform: waveform(time: time, level: renderedAudioLevel)
                case .pulse: pulse(time: time, level: renderedAudioLevel)
                case .halo: halo(time: time, level: renderedAudioLevel)
                }
            }
        }
        .accessibilityHidden(true)
    }

    private func spectrum(time: TimeInterval, level: Double?, bands: [Double]?) -> some View {
        GeometryReader { geometry in
            let count = max(5, Int(geometry.size.width / 5.5))
            HStack(alignment: .center, spacing: 2.5) {
                ForEach(0..<count, id: \.self) { index in
                    let wave = spectrumWave(time: time, index: index, count: count, level: level, bands: bands)
                    Capsule(style: .continuous)
                        .fill(tint.gradient)
                        .frame(height: isActive ? 4 + geometry.size.height * 0.74 * wave : 4)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .animation(.easeOut(duration: 0.22), value: isActive)
    }

    private func spectrumWave(time: TimeInterval, index: Int, count: Int, level: Double?, bands: [Double]?) -> Double {
        let phase = time * 4.2 + Double(index) * 0.72
        let simulatedWave = (sin(phase) + sin(phase * 0.47 + 1.8) + 2) / 4
        guard let level else { return simulatedWave }

        if let bands, bands.count >= 2 {
            let position = Double(index) / Double(max(1, count - 1))
            let scaled = position * Double(bands.count - 1)
            let lower = min(bands.count - 1, Int(scaled))
            let upper = min(bands.count - 1, lower + 1)
            let blend = scaled - Double(lower)
            let band = bands[lower] * (1 - blend) + bands[upper] * blend
            // Real low/mid/high values give every bar its own height. The
            // beat envelope adds a restrained global lift without flattening
            // the frequency detail.
            return min(1, 0.05 + band * 0.76 + level * 0.18)
        }

        // Keep a varied fallback until the first band frame arrives, but never
        // use a time-based simulation while real audio mode is enabled.
        let contour = 0.26 + (sin(Double(index) * 1.91 + 0.7) + 1) * 0.24
        return min(1, 0.05 + level * contour)
    }

    private func waveform(time: TimeInterval, level: Double?) -> some View {
        Canvas { context, size in
            var path = Path()
            let midY = size.height / 2
            let amplitude = isActive
                ? size.height * (level.map { 0.06 + $0 * 0.48 } ?? 0.34)
                : 1
            let points = max(24, Int(size.width))
            for point in 0...points {
                let progress = Double(point) / Double(points)
                let x = size.width * progress
                let envelope = sin(.pi * progress)
                let y = midY + amplitude * envelope * sin(progress * .pi * 5 + time * 4.5)
                if point == 0 { path.move(to: CGPoint(x: x, y: y)) }
                else { path.addLine(to: CGPoint(x: x, y: y)) }
            }
            context.stroke(path, with: .linearGradient(
                Gradient(colors: [tint.opacity(0.45), tint, highlight.opacity(0.75)]),
                startPoint: .zero,
                endPoint: CGPoint(x: size.width, y: 0)
            ), lineWidth: 2)
        }
        .animation(.easeOut(duration: 0.22), value: isActive)
    }

    private func pulse(time: TimeInterval, level: Double?) -> some View {
        let idleTexture = (sin(time * 3.2) + 1) / 2
        let amount = isActive ? (level.map { min(1, 0.08 + $0 * 0.90) } ?? idleTexture) : 0
        return ZStack {
            Circle().fill(tint.opacity(0.12 + amount * 0.12)).scaleEffect(0.72 + amount * 0.24)
            Circle().stroke(tint.opacity(0.45), lineWidth: 2).scaleEffect(0.42 + amount * 0.16)
            Circle().fill(tint).frame(width: 6, height: 6)
        }
    }

    private func halo(time: TimeInterval, level: Double?) -> some View {
        let idleTexture = (sin(time * 2.1) + 1) / 2
        let amount = isActive ? (level.map { min(1, 0.10 + $0 * 0.88) } ?? 0.45) : 0
        return ZStack {
            Circle()
                .trim(from: 0.08, to: 0.78)
                .stroke(AngularGradient(colors: [.clear, tint, highlight, .clear], center: .center),
                        style: StrokeStyle(lineWidth: 2 + amount * 2, lineCap: .round))
                .rotationEffect(.degrees(isActive ? (level.map { time * $0 * 32 } ?? time * 26) : 0))
            Circle().fill(tint.opacity(0.07 + amount * 0.18)).padding(5)
        }
    }
}
