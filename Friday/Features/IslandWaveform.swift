// 功能：绘制 Dictate 与 Talk 共用的紧凑声波、思考等待动画和对话表情。
// 职责：统一固定线宽、间距、高度映射与动画参数，区分用户输入、Friday 播放、短暂停顿和未检测到语音等视觉状态。
// 边界：只消费归一化音量和展示状态，不读取音频缓冲、不判断真实语音内容，也不改变浮层窗口尺寸。

import SwiftUI

struct IslandWaveformMetrics {
    static let idleBarHeight: CGFloat = 3.5
    static let maximumBarHeight: CGFloat = 16
    static let barWidth: CGFloat = 2
    static let barSpacing: CGFloat = 2
    static let animationDuration = 0.045
    static let barGains: [CGFloat] = [0.9, 0.98, 0.94, 1.02, 1, 0.93, 0.98, 0.9]

    static func barHeights(
        level: Float,
        waveformLevels: [Float],
        isVoiceActive: Bool
    ) -> [CGFloat] {
        guard isVoiceActive else {
            return Array(repeating: idleBarHeight, count: AudioChunk.waveformLevelCount)
        }

        let levels = waveformLevels.count == AudioChunk.waveformLevelCount
            ? waveformLevels
            : Array(repeating: level, count: AudioChunk.waveformLevelCount)
        let normalizedLevels = levels.map { CGFloat(min(max($0, 0), 1)) }
        let minimum = normalizedLevels.min() ?? 0
        let maximum = normalizedLevels.max() ?? 0
        let average = normalizedLevels.reduce(0, +) / CGFloat(normalizedLevels.count)
        let contrastSpan = max(maximum - minimum, 0.06)

        return normalizedLevels.enumerated().map { index, normalized in
            let absoluteEnergy = min(max((normalized - 0.07) / 0.5, 0), 1)
            let relativeEnergy = min(
                max(0.5 + ((normalized - average) / contrastSpan) * 0.68, 0),
                1
            )
            let contrastedEnergy = min(
                max(absoluteEnergy * 0.68 + relativeEnergy * 0.32, 0),
                1
            )
            let visibleLevel = pow(contrastedEnergy, 0.82) * barGains[index]
            return min(maximumBarHeight, idleBarHeight + 12.5 * visibleLevel)
        }
    }
}

struct IslandWaveformView: View {
    let level: Float
    let waveformLevels: [Float]
    let isVoiceActive: Bool
    var color: Color = .cyan
    var accessibilityLabel = "正在录音"

    var body: some View {
        let heights = IslandWaveformMetrics.barHeights(
            level: level,
            waveformLevels: waveformLevels,
            isVoiceActive: isVoiceActive
        )

        HStack(spacing: IslandWaveformMetrics.barSpacing) {
            ForEach(heights.indices, id: \.self) { index in
                IslandWaveformBar(height: heights[index], color: color)
            }
        }
        .accessibilityLabel(accessibilityLabel)
    }
}

struct ConversationWaveformView: View {
    let source: ConversationWaveformSource
    let level: Float
    let waveformLevels: [Float]
    let isVoiceActive: Bool

    var body: some View {
        switch source {
        case .idle:
            IdleConversationWaveform()
        case .microphone:
            IslandWaveformView(
                level: level,
                waveformLevels: waveformLevels,
                isVoiceActive: isVoiceActive,
                color: .cyan,
                accessibilityLabel: "用户正在说话"
            )
        case .assistant:
            IslandWaveformView(
                level: level,
                waveformLevels: waveformLevels,
                isVoiceActive: isVoiceActive,
                color: .pink,
                accessibilityLabel: "Friday 正在说话"
            )
        }
    }
}

private struct IdleConversationWaveform: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 24.0)) { context in
            let time = context.date.timeIntervalSinceReferenceDate
            HStack(spacing: IslandWaveformMetrics.barSpacing) {
                ForEach(0..<AudioChunk.waveformLevelCount, id: \.self) { index in
                    let phase = Double(index) * 0.48
                    let wave = reduceMotion ? 0 : (sin(time * 3.2 + phase) + 1) / 2
                    IslandWaveformBar(
                        height: IslandWaveformMetrics.idleBarHeight + CGFloat(wave) * 2.2,
                        color: .white.opacity(0.58)
                    )
                }
            }
        }
        .accessibilityLabel("Friday 正在等待")
    }
}

private struct IslandWaveformBar: View {
    let height: CGFloat
    let color: Color

    var body: some View {
        IslandWaveformBarShape(height: height)
            .fill(color)
            .frame(
                width: IslandWaveformMetrics.barWidth,
                height: IslandWaveformMetrics.maximumBarHeight
            )
            .animation(
                .linear(duration: IslandWaveformMetrics.animationDuration),
                value: height
            )
    }
}

private struct IslandWaveformBarShape: Shape {
    var height: CGFloat

    var animatableData: CGFloat {
        get { height }
        set { height = newValue }
    }

    func path(in rect: CGRect) -> Path {
        let visibleHeight = min(max(height, IslandWaveformMetrics.barWidth), rect.height)
        let barRect = CGRect(
            x: 0,
            y: (rect.height - visibleHeight) / 2,
            width: rect.width,
            height: visibleHeight
        )
        return RoundedRectangle(
            cornerRadius: rect.width / 2,
            style: .continuous
        ).path(in: barRect)
    }
}

struct ThinkingDotsView: View {
    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { context in
            let time = context.date.timeIntervalSinceReferenceDate
            HStack(spacing: 5) {
                ForEach(0..<3, id: \.self) { index in
                    let pulse = thinkingPulse(at: index, time: time)
                    Circle()
                        .fill(Color.purple)
                        .frame(width: 5, height: 5)
                        .scaleEffect(0.68 + pulse * 0.58)
                        .opacity(0.42 + pulse * 0.58)
                }
            }
        }
        .accessibilityLabel("正在整理文字")
    }

    private func thinkingPulse(at index: Int, time: TimeInterval) -> CGFloat {
        let stepDuration = 0.32
        let cycleDuration = stepDuration * 3
        let position = time.truncatingRemainder(dividingBy: cycleDuration) / stepDuration
        let distance = abs(position - Double(index))
        let wrappedDistance = min(distance, 3 - distance)
        return CGFloat(max(0, 1 - wrappedDistance / 0.72))
    }
}
