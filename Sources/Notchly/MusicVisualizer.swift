import SwiftUI

struct MusicVisualizer: View {
    let style: MusicVisualizerStyle
    let isActive: Bool
    var tint: Color = .purple

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: !isActive)) { timeline in
            let time = timeline.date.timeIntervalSinceReferenceDate
            Group {
                switch style {
                case .spectrum: spectrum(time: time)
                case .waveform: waveform(time: time)
                case .pulse: pulse(time: time)
                case .halo: halo(time: time)
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
                    let phase = time * 4.2 + Double(index) * 0.72
                    let wave = (sin(phase) + sin(phase * 0.47 + 1.8) + 2) / 4
                    Capsule(style: .continuous)
                        .fill(tint.gradient)
                        .frame(height: isActive ? 4 + geometry.size.height * 0.74 * wave : 4)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .animation(.easeOut(duration: 0.22), value: isActive)
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
                Gradient(colors: [tint.opacity(0.45), tint, .pink.opacity(0.75)]),
                startPoint: .zero,
                endPoint: CGPoint(x: size.width, y: 0)
            ), lineWidth: 2)
        }
        .animation(.easeOut(duration: 0.22), value: isActive)
    }

    private func pulse(time: TimeInterval) -> some View {
        let amount = isActive ? (sin(time * 3) + 1) / 2 : 0
        return ZStack {
            Circle().fill(tint.opacity(0.12 + amount * 0.12)).scaleEffect(0.72 + amount * 0.24)
            Circle().stroke(tint.opacity(0.45), lineWidth: 2).scaleEffect(0.42 + amount * 0.16)
            Circle().fill(tint).frame(width: 6, height: 6)
        }
    }

    private func halo(time: TimeInterval) -> some View {
        ZStack {
            Circle()
                .trim(from: 0.08, to: 0.78)
                .stroke(AngularGradient(colors: [.clear, tint, .pink, .clear], center: .center),
                        style: StrokeStyle(lineWidth: 3, lineCap: .round))
                .rotationEffect(.degrees(isActive ? time * 26 : 0))
            Circle().fill(tint.opacity(isActive ? 0.16 : 0.07)).padding(5)
        }
    }
}
