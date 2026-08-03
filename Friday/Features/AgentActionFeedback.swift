// 功能：把自动输入框动作的失败或不可验证结果映射为不阻断 Talk 的轻量反馈。
// 职责：监听 ConversationActionBridge 的 ActionReceipt，在目标失败或结果未知时通过灵动岛提示用户检查原输入位置。
// 边界：成功写入不额外打断用户，不读取 Accessibility、不执行动作，也不记录或展示完整写入正文。

import Foundation

@MainActor
final class AgentActionFeedbackCoordinator {
    private let controller: InputOverlayController?
    private let bridge: ConversationActionBridge

    init(
        controller: InputOverlayController?,
        bridge: ConversationActionBridge
    ) {
        self.controller = controller
        self.bridge = bridge
    }

    func start() {
        bridge.onResolution = { [weak self] _, receipt in
            self?.present(receipt)
        }
    }

    private func present(_ receipt: ActionReceipt) {
        switch receipt.status {
        case .succeeded:
            break
        case .failed:
            controller?.showBottomToast(
                receipt.error ?? "未能写入原输入框",
                duration: .milliseconds(2_400),
                hidesOverlay: false
            )
        case .unknown:
            controller?.showBottomToast(
                "写入结果无法复验，请查看原输入框",
                duration: .milliseconds(2_400),
                hidesOverlay: false
            )
        }
    }
}
