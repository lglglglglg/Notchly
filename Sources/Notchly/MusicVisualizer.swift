import SwiftUI

struct MusicVisualizer: View {
    let style: MusicVisualizerStyle
    let isActive: Bool
    var tint: Color = .purple
    var highlight: Color = .pink

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: !isActive)) { timeline in
            let time = timeline.date.timeIntervalSinceReferenceDate
            Group {
                switch style {
                case .spectrum: spectrum(time: time)
                case .waveform: waveform(time: time)
                case .pulse: pulse(time: time)
                case .cosmicDust: cosmicDust(time: time)
                }
            }
        }
        .accessibilityHidden(true)
    }

    private func spectrum(time: TimeInterval) -> some View {
        GeometryReader { geometry in
            let count = max(5, Int(geometry.size.width / 5.5))
            HStack(alignment: .center, spacing: 2.5) {
                ForEach(0..<count, id: \.self) { index in
                    let wave = spectrumWave(time: time, index: index, count: count)
                    Capsule(style: .continuous)
                        .fill(tint.gradient)
                        .frame(height: isActive ? 4 + geometry.size.height * 0.74 * wave : 4)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .animation(.easeOut(duration: 0.22), value: isActive)
    }

    private func spectrumWave(time: TimeInterval, index: Int, count: Int) -> Double {
        let phase = time * 4.2 + Double(index) * 0.72
        return (sin(phase) + sin(phase * 0.47 + 1.8) + 2) / 4
    }

    private func waveform(time: TimeInterval) -> some View {
        Canvas { context, size in
            var path = Path()
            let midY = size.height / 2
            let amplitude = isActive ? size.height * 0.34 : 1
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

    private func pulse(time: TimeInterval) -> some View {
        let beat = isActive ? (sin(time * 3.7) + 1) / 2 : 0
        return ZStack {
            ForEach(0..<3, id: \.self) { index in
                let phase = (beat + Double(index) * 0.34).truncatingRemainder(dividingBy: 1)
                Circle()
                    .stroke(tint.opacity(0.48 - Double(index) * 0.10), lineWidth: 1.5)
                    .scaleEffect(0.48 + phase * 0.48)
                    .opacity(0.88 - phase * 0.72)
            }
            Circle()
                .fill(
                    RadialGradient(
                        colors: [highlight.opacity(0.82), tint.opacity(0.34), .clear],
                        center: .center,
                        startRadius: 0,
                        endRadius: 26
                    )
                )
                .scaleEffect(0.60 + beat * 0.12)
            Circle()
                .fill(tint)
                .frame(width: 5, height: 5)
                .shadow(color: tint.opacity(0.9), radius: 5)
        }
    }

    private func cosmicDust(time: TimeInterval) -> some View {
        GeometryReader { geometry in
            Canvas { context, size in
                let center = CGPoint(x: size.width / 2, y: size.height / 2)
                let radius = min(size.width, size.height) / 2
                for index in 0..<58 {
                    let seed = Double(index) * 0.618_033_988_75
                    let orbit = radius * (0.40 + seed.truncatingRemainder(dividingBy: 1) * 0.54)
                    let speed = isActive ? (0.24 + Double(index % 5) * 0.035) : 0
                    let angle = seed * .pi * 2 + time * speed
                    let point = CGPoint(
                        x: center.x + cos(angle) * orbit,
                        y: center.y + sin(angle) * orbit * 0.68
                    )
                    let dotSize = 1.1 + Double(index % 4) * 0.48
                    let color = index.isMultiple(of: 5) ? highlight : tint
                    let rect = CGRect(
                        x: point.x - dotSize / 2,
                        y: point.y - dotSize / 2,
                        width: dotSize,
                        height: dotSize
                    )
                    context.fill(Path(ellipseIn: rect), with: .color(color.opacity(0.28 + Double(index % 5) * 0.11)))
                }
            }
            .drawingGroup()
        }
    }
}
