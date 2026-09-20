import AppKit
import SwiftUI

@MainActor
final class NotchPresentation: ObservableObject {
    enum Phase: CGFloat {
        case compact = 0
        case expanded = 1
    }

    @Published var phase: Phase = .compact
    @Published var notchWidth: CGFloat = 164
    @Published var notchHeight: CGFloat = 32
    @Published var centerX: CGFloat = 0

    let panelSize = NSSize(width: 580, height: 272)

    func compactSize(hasMusic: Bool, isPomodoroRunning: Bool) -> NSSize {
        let wingWidth = NotchLayoutPolicy.compactWingWidth(
            hasMusic: hasMusic,
            isPomodoroRunning: isPomodoroRunning
        )
        return NSSize(width: max(220, notchWidth + wingWidth * 2), height: notchHeight + 2)
    }

    // The compact island stays inside the menu-bar band; the expanded player
    // gets its own wider canvas so metadata, lyrics and status chips do not
    // compete for the same narrow strip.
    var expandedSize: NSSize { NSSize(width: 540, height: 250) }

    var expandedContentTopInset: CGFloat {
        NotchLayoutPolicy.expandedContentTopInset(notchHeight: notchHeight)
    }

    func surfaceSize(hasMusic: Bool, isPomodoroRunning: Bool) -> NSSize {
        switch phase {
        case .compact: compactSize(hasMusic: hasMusic, isPomodoroRunning: isPomodoroRunning)
        case .expanded: expandedSize
        }
    }
}

struct NotchIslandView: View {
    @ObservedObject var state: IslandState
    @ObservedObject var presentation: NotchPresentation
    let showFull: () -> Void
    let collapse: () -> Void

    init(state: IslandState, presentation: NotchPresentation, showFull: @escaping () -> Void, collapse: @escaping () -> Void) {
        self.state = state
        self.presentation = presentation
        self.showFull = showFull
        self.collapse = collapse
    }

    var body: some View {
        let surface = NotchSurface(
            notchHeight: presentation.notchHeight,
            expansionProgress: presentation.phase.rawValue
        )
        let surfaceSize = presentation.surfaceSize(
            hasMusic: state.hasMusic,
            isPomodoroRunning: state.isPomodoroRunning
        )

        ZStack(alignment: .top) {
            Color.clear

            ZStack(alignment: .top) {
                surface
                    .fill(.black.opacity(0.985))
                    .overlay(surface.stroke(.white.opacity(0.07), lineWidth: 0.7))
                    .shadow(color: .black.opacity(presentation.phase == .compact ? 0 : 0.34), radius: 18, y: 8)

                if presentation.phase == .compact {
                    compactStatus
                        // Do not reveal the compact artwork and visualizer while
                        // the large surface is still collapsing around them.
                        .transition(.asymmetric(
                            insertion: .opacity.animation(.linear(duration: 0.08).delay(0.24)),
                            removal: .opacity.animation(.linear(duration: 0.04))
                        ))
                } else {
                    IslandView(
                        state: state,
                        safeTop: presentation.expandedContentTopInset,
                        notchWidth: presentation.notchWidth,
                        dismiss: collapse
                    )
                        .transition(.asymmetric(
                            insertion: .opacity.animation(.easeOut(duration: 0.19).delay(0.11)),
                            removal: .opacity.animation(.linear(duration: 0.05))
                        ))
                }
            }
            .frame(width: surfaceSize.width, height: surfaceSize.height)
            .clipShape(surface)
            .contentShape(surface)
            .onTapGesture {
                if presentation.phase != .expanded { showFull() }
            }
            .contextMenu {
                Button("刷新播放状态") {
                    state.refreshMusic()
                }
                Button("设置…") {
                    NotificationCenter.default.post(name: .notchlyShowSettingsRequested, object: nil)
                }
                Divider()
                Button("重新启动 Notchly") {
                    NotificationCenter.default.post(name: .notchlyRestartRequested, object: nil)
                }
                Button("退出 Notchly") {
                    NotificationCenter.default.post(name: .notchlyQuitRequested, object: nil)
                }
            }
            .animation(.spring(response: 0.30, dampingFraction: 0.90), value: presentation.phase)
        }
        .frame(width: presentation.panelSize.width, height: presentation.panelSize.height, alignment: .top)
        .preferredColorScheme(.dark)
    }

    private var compactStatus: some View {
        let size = presentation.compactSize(
            hasMusic: state.hasMusic,
            isPomodoroRunning: state.isPomodoroRunning
        )
        let wingWidth = NotchLayoutPolicy.compactWingWidth(
            hasMusic: state.hasMusic,
            isPomodoroRunning: state.isPomodoroRunning
        )

        return HStack(spacing: 0) {
            Group {
                if state.hasMusic {
                    compactArtwork
                } else if state.isPomodoroRunning {
                    Image(systemName: "timer").foregroundStyle(.orange)
                } else {
                    Image(systemName: "music.note")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(state.settings.islandAccentTheme.accent)
                }
            }
            .padding(.trailing, 4)
            .frame(width: wingWidth, height: size.height, alignment: .trailing)

            Color.clear
                .frame(width: presentation.notchWidth, height: size.height)

            Group {
                if state.isPomodoroRunning {
                    if state.hasMusic {
                        HStack(spacing: 4) {
                            Image(systemName: "timer")
                            Text(state.timerText).monospacedDigit()
                        }
                        .foregroundStyle(.orange)
                    } else {
                        Text(state.timerText).monospacedDigit()
                    }
                } else if state.hasMusic {
                    MusicVisualizer(
                        style: state.settings.musicVisualizerStyle,
                        isActive: state.isPlaying,
                        audioLevel: state.settings.audioReactiveVisualizerEnabled ? state.audioReactiveLevel : nil,
                        tint: state.settings.islandAccentTheme.accent,
                        highlight: state.settings.islandAccentTheme.highlight
                    )
                    .frame(width: 22, height: 14)
                } else {
                    Text("悬停")
                        .foregroundStyle(.white.opacity(0.62))
                }
            }
            .font(.caption2.weight(.semibold))
            .padding(.leading, 4)
            .frame(width: wingWidth, height: size.height, alignment: .leading)
        }
        .frame(width: size.width, height: size.height)
        .zIndex(3)
    }

    @ViewBuilder
    private var compactArtwork: some View {
        if let artwork = state.artworkImage {
            Image(nsImage: artwork)
                .resizable()
                .scaledToFill()
                .frame(width: 20, height: 20)
                .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
        } else {
            albumPlaceholder(size: 20, radius: 5)
        }
    }

    private func albumPlaceholder(size: CGFloat, radius: CGFloat) -> some View {
        RoundedRectangle(cornerRadius: radius, style: .continuous)
            .fill(LinearGradient(colors: state.settings.islandAccentTheme.artworkColors, startPoint: .topLeading, endPoint: .bottomTrailing))
            .frame(width: size, height: size)
            .overlay(Image(systemName: "music.note").font(size > 30 ? .title3 : .caption2))
    }
}

private struct NotchSurface: Shape {
    var notchHeight: CGFloat
    var expansionProgress: CGFloat

    var animatableData: CGFloat {
        get { expansionProgress }
        set { expansionProgress = newValue }
    }

    func path(in rect: CGRect) -> Path {
        let progress = min(max(expansionProgress, 0), 1)
        let topInset: CGFloat = 0
        let compactShoulderRadius = min(12, rect.height * 0.38)
        let expandedShoulderRadius = NotchLayoutPolicy.expandedShoulderRadius(
            notchHeight: notchHeight,
            containerHeight: rect.height
        )
        let shoulderRadius = compactShoulderRadius + (expandedShoulderRadius - compactShoulderRadius) * progress
        let compactBodyInset = min(12, rect.width * 0.055)
        let expandedBodyInset = min(expandedShoulderRadius, rect.width * 0.115)
        let bodyInset = compactBodyInset + (expandedBodyInset - compactBodyInset) * progress
        let compactBottomRadius = min(8, max(4, (rect.height - shoulderRadius) * 0.48))
        let expandedBottomRadius = min(30, rect.height * 0.30, rect.width * 0.12)
        let bottomRadius = compactBottomRadius + (expandedBottomRadius - compactBottomRadius) * progress
        let circleControl = 0.552_284_75

        var path = Path()
        path.move(to: CGPoint(x: rect.minX + topInset, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX - topInset, y: rect.minY))

        // Both compact and expanded states keep the same silhouette language:
        // a full-width top edge immediately flows through two inward shoulders,
        // leaving a visibly narrower body below. Expansion only scales the
        // shoulders up; it never falls back to a conventional capsule.
        path.addCurve(
            to: CGPoint(x: rect.maxX - bodyInset, y: rect.minY + shoulderRadius),
            control1: CGPoint(x: rect.maxX - topInset - bodyInset * circleControl, y: rect.minY),
            control2: CGPoint(x: rect.maxX - bodyInset, y: rect.minY + shoulderRadius * (1 - circleControl))
        )
        path.addLine(to: CGPoint(x: rect.maxX - bodyInset, y: rect.maxY - bottomRadius))
        path.addCurve(
            to: CGPoint(x: rect.maxX - bodyInset - bottomRadius, y: rect.maxY),
            control1: CGPoint(x: rect.maxX - bodyInset, y: rect.maxY - bottomRadius * 0.42),
            control2: CGPoint(x: rect.maxX - bodyInset - bottomRadius * 0.42, y: rect.maxY)
        )
        path.addLine(to: CGPoint(x: rect.minX + bodyInset + bottomRadius, y: rect.maxY))
        path.addCurve(
            to: CGPoint(x: rect.minX + bodyInset, y: rect.maxY - bottomRadius),
            control1: CGPoint(x: rect.minX + bodyInset + bottomRadius * 0.42, y: rect.maxY),
            control2: CGPoint(x: rect.minX + bodyInset, y: rect.maxY - bottomRadius * 0.42)
        )
        path.addLine(to: CGPoint(x: rect.minX + bodyInset, y: rect.minY + shoulderRadius))
        path.addCurve(
            to: CGPoint(x: rect.minX + topInset, y: rect.minY),
            control1: CGPoint(x: rect.minX + bodyInset, y: rect.minY + shoulderRadius * (1 - circleControl)),
            control2: CGPoint(x: rect.minX + topInset + bodyInset * circleControl, y: rect.minY)
        )
        path.closeSubpath()
        return path
    }
}

/// Separates the visible shoulder curve from the area reserved for the actual
/// camera housing. The old layout used the large curve radius as a content
/// inset, which left an unnecessarily tall empty header above the player.
enum NotchLayoutPolicy {
    static func compactWingWidth(hasMusic: Bool, isPomodoroRunning: Bool) -> CGFloat {
        hasMusic && isPomodoroRunning ? 72 : 48
    }

    static func expandedContentTopInset(notchHeight: CGFloat) -> CGFloat {
        max(36, notchHeight + 4)
    }

    static func expandedShoulderRadius(notchHeight: CGFloat, containerHeight: CGFloat) -> CGFloat {
        // Keep the top edge visually flat, like a shallow MacBook notch
        // extension, rather than turning the expanded island into a deep arch.
        min(max(28, notchHeight), containerHeight * 0.20)
    }
}
