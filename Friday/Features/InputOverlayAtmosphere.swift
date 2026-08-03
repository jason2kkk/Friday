// 功能：为紧凑灵动岛绘制状态氛围，并为展开矩形叠加顶部可读性渐变。
// 职责：映射工作流颜色、稳定装饰背景布局与动画，并响应系统降低动态效果设置。
// 边界：只负责装饰性背景，不改变浮层尺寸、业务状态、交互命中区域或内容文案。

import SwiftUI

enum InputOverlayAtmosphereKind: Equatable {
    case hidden
    case listening
    case processing
    case conversationListening
    case conversationSpeaking
    case failure
    case result

    init(phase: InputOverlayPhase) {
        switch phase {
        case .hidden, .idle:
            self = .hidden
        case .listening:
            self = .listening
        case .processing:
            self = .processing
        case .conversation(_, let source):
            self = source == .assistant ? .conversationSpeaking : .conversationListening
        case .failure:
            self = .failure
        case .result, .notice:
            self = .result
        }
    }
}

enum InputOverlayAtmosphereLayout {
    static let sideFraction: CGFloat = 0.18
    static let centerClearFraction: CGFloat = 1 - sideFraction * 2
}

struct InputOverlayAtmosphereView: View {
    let phase: InputOverlayPhase
    let isExpanded: Bool

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isDrifting = false

    var body: some View {
        GeometryReader { geometry in
            let palette = palette(for: InputOverlayAtmosphereKind(phase: phase))
            let sideWidth = geometry.size.width * InputOverlayAtmosphereLayout.sideFraction

            ZStack {
                if isExpanded {
                    ExpandedIslandReadabilityBackground()
                } else {
                    ZStack {
                        Color.black

                        HStack(spacing: 0) {
                            sideDiffusion(
                                palette: palette,
                                width: sideWidth,
                                height: geometry.size.height,
                                edge: .leading
                            )

                            Spacer(minLength: 0)

                            sideDiffusion(
                                palette: palette,
                                width: sideWidth,
                                height: geometry.size.height,
                                edge: .trailing
                            )
                        }
                        .opacity(palette.opacity)
                        .blendMode(.screen)
                    }
                    .compositingGroup()
                }
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
        .onAppear(perform: startDrift)
    }

    private func sideDiffusion(
        palette: AtmospherePalette,
        width: CGFloat,
        height: CGFloat,
        edge: HorizontalEdge
    ) -> some View {
        ZStack {
            diffusionBand(
                colors: [
                    palette.primary.opacity(0.32),
                    palette.secondary.opacity(0.14),
                    .clear
                ],
                width: width * 1.18,
                height: height * 2
            )
            .offset(
                x: -width * 0.14,
                y: driftOffset(from: -height * 0.18, to: height * 0.06)
            )

            diffusionBand(
                colors: [
                    palette.secondary.opacity(0.1),
                    palette.primary.opacity(0.2),
                    .clear
                ],
                width: width,
                height: height * 1.5
            )
            .offset(
                x: -width * 0.04,
                y: driftOffset(from: height * 0.2, to: -height * 0.04)
            )
        }
        .scaleEffect(x: edge == .trailing ? -1 : 1, y: 1)
        .frame(width: width, height: height)
        .clipped()
    }

    private func diffusionBand(
        colors: [Color],
        width: CGFloat,
        height: CGFloat
    ) -> some View {
        Rectangle()
            .fill(
                LinearGradient(
                    colors: colors,
                    startPoint: .leading,
                    endPoint: .trailing
                )
            )
            .frame(width: width, height: height)
            .blur(radius: max(8, height * 0.24))
    }

    private func driftOffset(from start: CGFloat, to end: CGFloat) -> CGFloat {
        reduceMotion ? (start + end) / 2 : (isDrifting ? end : start)
    }

    private func startDrift() {
        guard !reduceMotion else {
            isDrifting = false
            return
        }

        isDrifting = false
        withAnimation(.easeInOut(duration: 5.8).repeatForever(autoreverses: true)) {
            isDrifting = true
        }
    }

    private func palette(for kind: InputOverlayAtmosphereKind) -> AtmospherePalette {
        switch kind {
        case .hidden:
            return AtmospherePalette(primary: .clear, secondary: .clear, opacity: 0)
        case .listening:
            return AtmospherePalette(
                primary: Color(red: 0.08, green: 0.78, blue: 0.86),
                secondary: Color(red: 0.2, green: 0.91, blue: 0.65),
                opacity: 0.48
            )
        case .processing:
            return AtmospherePalette(
                primary: Color(red: 0.46, green: 0.34, blue: 0.96),
                secondary: Color(red: 0.96, green: 0.33, blue: 0.64),
                opacity: 0.44
            )
        case .conversationListening:
            return AtmospherePalette(
                primary: Color(red: 0.04, green: 0.75, blue: 0.86),
                secondary: Color(red: 0.18, green: 0.9, blue: 0.62),
                opacity: 0.4
            )
        case .conversationSpeaking:
            return AtmospherePalette(
                primary: Color(red: 0.94, green: 0.26, blue: 0.58),
                secondary: Color(red: 0.56, green: 0.34, blue: 0.98),
                opacity: 0.42
            )
        case .failure:
            return AtmospherePalette(
                primary: Color(red: 0.98, green: 0.52, blue: 0.12),
                secondary: Color(red: 0.9, green: 0.2, blue: 0.22),
                opacity: 0.3
            )
        case .result:
            return AtmospherePalette(
                primary: Color(red: 0.08, green: 0.72, blue: 0.7),
                secondary: Color(red: 0.42, green: 0.82, blue: 0.38),
                opacity: 0.24
            )
        }
    }
}

private struct ExpandedIslandReadabilityBackground: View {
    var body: some View {
        topReadabilityGradient
    }

    private var topReadabilityGradient: some View {
        LinearGradient(
            stops: [
                .init(color: .black, location: 0),
                .init(color: .black, location: 0.1),
                .init(color: .black.opacity(0.82), location: 0.2),
                .init(color: .black.opacity(0.3), location: 0.31),
                .init(color: .clear, location: 0.5),
                .init(color: .clear, location: 1)
            ],
            startPoint: .top,
            endPoint: .bottom
        )
        .allowsHitTesting(false)
    }

}

private struct AtmospherePalette {
    let primary: Color
    let secondary: Color
    let opacity: Double
}
