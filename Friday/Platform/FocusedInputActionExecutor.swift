// 功能：执行 Agent 已获一次性许可的当前输入框写入动作，并返回本地可观察的 ActionReceipt。
// 职责：锁定会话开始时的 Accessibility 目标、复验目标 revision、调用既有剪贴板写入路径并映射成功、失败或未知结果。
// 边界：不生成文本、不申请模型会话、不执行发送或提交；目标缺失、变化或不可验证时不猜测其他控件。

import ApplicationServices
import Foundation

@MainActor
protocol AccessibilityTextInserting: AnyObject {
    func insert(_ text: String, into target: FocusedInputTarget) async -> TextInsertionResult
}

extension AccessibilityInputService: AccessibilityTextInserting {}

@MainActor
final class FocusedInputActionExecutor: LocalActionExecuting {
    private struct LockedTarget {
        let descriptor: ActionTargetDescriptor
        let target: FocusedInputTarget
    }

    private let inputService: any AccessibilityTextInserting
    private var lockedTarget: LockedTarget?

    init(inputService: any AccessibilityTextInserting) {
        self.inputService = inputService
    }

    var focusedInputTarget: ActionTargetDescriptor? {
        lockedTarget?.descriptor
    }

    func lockSessionTarget(_ target: FocusedInputTarget?) {
        guard let target else {
            lockedTarget = nil
            return
        }
        lockedTarget = LockedTarget(
            descriptor: ActionTargetDescriptor(
                revision: "target_\(UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased())",
                applicationName: target.applicationName,
                role: target.role
            ),
            target: target
        )
    }

    func clearSessionTarget() {
        lockedTarget = nil
    }

    func execute(_ proposal: ActionProposal) async -> ActionReceipt {
        guard proposal.kind == .writeFocusedInput,
              let lockedTarget,
              proposal.target == lockedTarget.descriptor else {
            return receipt(
                for: proposal,
                status: .failed,
                observedResult: "输入目标与动作提议不匹配",
                error: "原输入目标已经失效，请重新聚焦后开始新的语音 Agent 对话。"
            )
        }

        let result = await inputService.insert(
            proposal.parameters.text,
            into: lockedTarget.target
        )
        switch result {
        case .verified:
            return receipt(
                for: proposal,
                status: .succeeded,
                observedResult: "目标输入框的文本变化已复验",
                undoToken: "system_undo:\(proposal.id.rawValue)"
            )
        case .dispatched:
            return receipt(
                for: proposal,
                status: .unknown,
                observedResult: "粘贴事件已发送，但目标应用未提供可验证的文本值",
                undoToken: "system_undo:\(proposal.id.rawValue)"
            )
        case .targetUnavailable:
            return receipt(
                for: proposal,
                status: .failed,
                observedResult: "目标应用已不可用",
                error: "原输入框所在的应用已经关闭。"
            )
        case .focusChanged:
            return receipt(
                for: proposal,
                status: .failed,
                observedResult: "无法恢复并复验原输入焦点",
                error: "原输入框焦点已经变化，Friday 没有写入其他位置。"
            )
        case .pasteEventUnavailable:
            return receipt(
                for: proposal,
                status: .failed,
                observedResult: "系统未接受粘贴事件",
                error: "无法向原输入框发送写入操作。"
            )
        case .systemError:
            return receipt(
                for: proposal,
                status: .failed,
                observedResult: "Accessibility 目标复验失败",
                error: "系统无法验证原输入框，Friday 没有执行写入。"
            )
        }
    }

    private func receipt(
        for proposal: ActionProposal,
        status: ActionReceiptStatus,
        observedResult: String,
        undoToken: String? = nil,
        error: String? = nil
    ) -> ActionReceipt {
        ActionReceipt(
            id: .make(),
            workID: proposal.workID,
            actionID: proposal.id,
            status: status,
            targetRevision: proposal.target.revision,
            observedResult: observedResult,
            undoToken: undoToken,
            executedAt: Date(),
            error: error
        )
    }
}
