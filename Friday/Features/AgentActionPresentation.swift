// 功能：把 Agent 本地动作的一次性权限生命周期映射到灵动岛确认界面。
// 职责：展示完整写入预览，转发允许或拒绝按钮，并把执行中、失败、未知和完成结果映射为可恢复界面状态。
// 边界：不读取 Accessibility、不执行写入、不调用模型，也不持久化或记录用户预览正文。

import Foundation

@MainActor
final class AgentActionPresentationCoordinator {
    private let model: InputOverlayModel
    private let controller: InputOverlayController?
    private let bridge: ConversationActionBridge

    init(
        model: InputOverlayModel,
        controller: InputOverlayController?,
        bridge: ConversationActionBridge
    ) {
        self.model = model
        self.controller = controller
        self.bridge = bridge
    }

    func start() {
        model.onAllowAction = { [weak self] in
            self?.respondToPendingAction(allow: true)
        }
        model.onRejectAction = { [weak self] in
            self?.respondToPendingAction(allow: false)
        }
        model.onDismissActionResult = { [weak self] in
            self?.dismissActionResult()
        }
        bridge.onPermissionRequest = { [weak self] request in
            self?.presentPermission(request)
        }
        bridge.onExecutionStarted = { [weak self] request in
            self?.markExecuting(request)
        }
        bridge.onResolution = { [weak self] request, outcome in
            self?.presentResolution(request: request, outcome: outcome)
        }
    }

    private func presentPermission(_ request: ActionPermissionRequest) {
        let proposal = request.proposal
        model.actionConfirmation = ActionConfirmationPresentation(
            permissionID: request.id,
            actionID: proposal.id,
            targetApplication: proposal.target.applicationName,
            targetRole: userFacingTargetRole(proposal.target.role),
            preview: proposal.preview,
            state: .pending
        )
        controller?.presentActionConfirmation()
    }

    private func markExecuting(_ request: ActionPermissionRequest) {
        guard var confirmation = matchingConfirmation(for: request) else { return }
        confirmation.state = .executing
        model.actionConfirmation = confirmation
    }

    private func presentResolution(
        request: ActionPermissionRequest,
        outcome: ConversationActionOutcome
    ) {
        guard var confirmation = matchingConfirmation(for: request) else { return }
        switch outcome {
        case .rejected, .cancelled:
            model.actionConfirmation = nil
            controller?.collapseAfterActionResolution()
        case .receipt(let receipt):
            switch receipt.status {
            case .succeeded:
                model.actionConfirmation = nil
                controller?.collapseAfterActionResolution()
            case .failed:
                confirmation.state = .failed(
                    receipt.error ?? "写入没有完成，原输入框没有被修改。"
                )
                model.actionConfirmation = confirmation
                controller?.presentActionConfirmation()
            case .unknown:
                confirmation.state = .unknown(
                    "写入事件已发送，但目标应用无法提供结果复验，请查看原输入框。"
                )
                model.actionConfirmation = confirmation
                controller?.presentActionConfirmation()
            }
        }
    }

    private func respondToPendingAction(allow: Bool) {
        guard var confirmation = model.actionConfirmation else { return }
        let accepted = bridge.respond(
            permissionID: confirmation.permissionID,
            actionID: confirmation.actionID,
            allow: allow
        )
        guard accepted else {
            confirmation.state = .failed("这项确认已经失效，没有执行写入。")
            model.actionConfirmation = confirmation
            return
        }
        confirmation.state = .executing
        model.actionConfirmation = confirmation
    }

    private func dismissActionResult() {
        model.actionConfirmation = nil
        controller?.collapseAfterActionResolution()
    }

    private func matchingConfirmation(
        for request: ActionPermissionRequest
    ) -> ActionConfirmationPresentation? {
        guard let confirmation = model.actionConfirmation,
              confirmation.permissionID == request.id,
              confirmation.actionID == request.proposal.id else { return nil }
        return confirmation
    }

    private func userFacingTargetRole(_ role: String) -> String {
        switch role {
        case "AXTextArea":
            return "文本区域"
        case "AXTextField", "AXComboBox":
            return "输入框"
        default:
            return "当前输入位置"
        }
    }
}
