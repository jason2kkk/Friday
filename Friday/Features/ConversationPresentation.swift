// 功能：把 Talk 运行时状态和音频强度转换成用户能看到的灵动岛表情、声波和轻提示。
// 职责：维护 Conversation 到 InputOverlay 的单向映射，控制对话浮层的准备、显示、更新、收起和错误提示时机。
// 边界：不决定 Talk 状态机、不访问 Provider 或音频设备，也不拥有窗口布局与绘制实现。

import Foundation

enum ConversationExpression: String, Equatable, CaseIterable {
    case awake
    case attentive
    case observing
    case speaking
    case interrupted
    case uncertain
    case resting

    var glyph: String {
        switch self {
        case .awake:
            return "^ω^"
        case .attentive:
            return "(´▽｀)"
        case .observing:
            return "(◉_◉)"
        case .speaking:
            return "~_^"
        case .interrupted:
            return "-_-#"
        case .uncertain:
            return "(・_・?)"
        case .resting:
            return "(u_u)"
        }
    }

    var accessibilityLabel: String {
        switch self {
        case .awake:
            return "Friday 已被唤醒"
        case .attentive:
            return "Friday 正在听"
        case .observing:
            return "Friday 正在查看你选择的屏幕区域"
        case .speaking:
            return "Friday 正在说话"
        case .interrupted:
            return "Friday 已停止说话并继续听"
        case .uncertain:
            return "Friday 没有听清"
        case .resting:
            return "Friday 正在结束对话"
        }
    }
}

enum ConversationWaveformSource: Equatable {
    case idle
    case microphone
    case assistant
}

@MainActor
protocol ConversationPresenting: AnyObject {
    func show(
        expression: ConversationExpression,
        source: ConversationWaveformSource
    )
    func updateWaveform(
        _ levels: ConversationAudioLevels,
        source: ConversationWaveformSource
    )
    func hide()
    func showToast(_ message: String, hidesOverlay: Bool)
}

@MainActor
final class InputOverlayConversationPresenter: ConversationPresenting {
    private let model: InputOverlayModel
    private let controller: InputOverlayController?

    init(
        model: InputOverlayModel,
        controller: InputOverlayController?
    ) {
        self.model = model
        self.controller = controller
    }

    func show(
        expression: ConversationExpression,
        source: ConversationWaveformSource
    ) {
        model.audioLevel = 0
        model.isVoiceActive = false
        model.waveformLevels = InputOverlayModel.silentWaveformLevels
        let phase = InputOverlayPhase.conversation(
            expression: expression,
            source: source
        )
        model.phase = phase
        controller?.show(phase)
    }

    func updateWaveform(
        _ levels: ConversationAudioLevels,
        source: ConversationWaveformSource
    ) {
        model.audioLevel = levels.level
        model.isVoiceActive = AudioLevelMeter.hasVisualActivity(levels.level)
        model.waveformLevels = levels.waveformLevels

        let expression: ConversationExpression = source == .assistant
            ? .speaking
            : .attentive
        let phase = InputOverlayPhase.conversation(
            expression: expression,
            source: source
        )
        model.phase = phase
        controller?.show(phase)
    }

    func hide() {
        controller?.hide()
    }

    func showToast(_ message: String, hidesOverlay: Bool = true) {
        controller?.showBottomToast(message, hidesOverlay: hidesOverlay)
    }
}
