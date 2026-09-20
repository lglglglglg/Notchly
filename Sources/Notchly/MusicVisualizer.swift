import SwiftUI

struct MusicVisualizer: View {
    let style: MusicVisualizerStyle
    let isActive: Bool
    /// `nil` keeps the lightweight simulated animation. A value from 0…1 is
    /// supplied only by the opt-in local system-audio analyzer.
    var audioLevel: Double?
    var tint: Color = .purple

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: !isActive)) { timeline in
            let time = timeline.date.timeIntervalSinceReferenceDate
            Group {
                switch style {
                case .spectrum: spectrum(time: time, level: audioLevel)
                case .waveform: waveform(time: time, level: audioLevel)
                case .pulse: pulse(time: time, level: audioLevel)
                case .halo: halo(time: time, level: audioLevel)
                }
            }
        }
        .accessibilityHidden(true)
    }

    private func spectrum(time: TimeInterval, level: Double?) -> some View {
        GeometryReader { geometry in
            let count = max(5, Int(geometry.size.width / 5.5))
            HStack(alignment: .center, spacing: 2.5) {
                ForEach(0..<count, id: \.self) { index in
                    let wave = spectrumWave(time: time, index: index, level: level)
                    Capsule(style: .continuous)
                        .fill(tint.gradient)
                        .frame(height: isActive ? 4 + geometry.size.height * 0.74 * wave : 4)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .animation(.easeOut(duration: 0.22), value: isActive)
    }

    private func spectrumWave(time: TimeInterval, index: Int, level: Double?) -> Double {
        let phase = time * 4.2 + Double(index) * 0.72
        let simulatedWave = (sin(phase) + sin(phase * 0.47 + 1.8) + 2) / 4
        guard let level else { return simulatedWave }

        // Actual system-audio energy controls the overall lift. A subtle moving
        // texture preserves legibility during quiet passages and when an audio
        // driver reports zero instead of delivering a useful signal.
        let contour = 0.26 + (sin(Double(index) * 1.91 + 0.7) + 1) * 0.24
        let texture = (sin(phase * 1.8) + sin(phase * 0.63 + 1.1) + 2) / 4
        return min(1, 0.10 + level * (0.48 + contour) + texture * (0.06 + level * 0.10))
    }

    private func waveform(time: TimeInterval, level: Double?) -> some View {
        Canvas { context, size in
            var path = Path()
            let midY = size.height / 2
            let reactiveTexture = (sin(time * 2.7) + 1) / 2
            let amplitude = isActive
                ? size.height * (level.map { 0.11 + $0 * 0.43 + reactiveTexture * 0.045 } ?? 0.34)
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
                Gradient(colors: [tint.opacity(0.45), tint, .pink.opacity(0.75)]),
                startPoint: .zero,
                endPoint: CGPoint(x: size.width, y: 0)
            ), lineWidth: 2)
        }
        .animation(.easeOut(duration: 0.22), value: isActive)
    }

    private func pulse(time: TimeInterval, level: Double?) -> some View {
        let idleTexture = (sin(time * 3.2) + 1) / 2
        let amount = isActive ? (level.map { min(1, 0.10 + $0 * 0.86 + idleTexture * 0.04) } ?? idleTexture) : 0
        return ZStack {
            Circle().fill(tint.opacity(0.12 + amount * 0.12)).scaleEffect(0.72 + amount * 0.24)
            Circle().stroke(tint.opacity(0.45), lineWidth: 2).scaleEffect(0.42 + amount * 0.16)
            Circle().fill(tint).frame(width: 6, height: 6)
        }
    }

    private func halo(time: TimeInterval, level: Double?) -> some View {
        let idleTexture = (sin(time * 2.1) + 1) / 2
        let amount = isActive ? (level.map { min(1, 0.12 + $0 * 0.84 + idleTexture * 0.04) } ?? 0.45) : 0
        return ZStack {
            Circle()
                .trim(from: 0.08, to: 0.78)
                .stroke(AngularGradient(colors: [.clear, tint, .pink, .clear], center: .center),
                        style: StrokeStyle(lineWidth: 2 + amount * 2, lineCap: .round))
                .rotationEffect(.degrees(isActive ? time * 26 : 0))
            Circle().fill(tint.opacity(0.07 + amount * 0.18)).padding(5)
        }
    }
}
