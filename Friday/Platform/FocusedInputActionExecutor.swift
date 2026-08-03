// 功能：执行语音 Agent 明确提出的可撤销输入框文字写入，并返回本地可观察的 ActionReceipt。
// 职责：复验动作风险，根据显式应用提示或会话锁定目标定位输入框，调用既有粘贴路径并映射执行结果。
// 边界：不生成文字、不发送或提交内容；应用不存在、目标歧义、密码框或焦点不可靠时不猜测其他控件。

import Foundation

@MainActor
protocol AccessibilityActionAccessing: AnyObject {
    func captureFocusedTarget(
        processIdentifier: pid_t,
        applicationName: String
    ) -> InputTargetResult
    func insert(_ text: String, into target: FocusedInputTarget) async -> TextInsertionResult
}

extension AccessibilityInputService: AccessibilityActionAccessing {}

@MainActor
final class FocusedInputActionExecutor: LocalActionExecuting {
    private struct LockedTarget {
        let revision: String
        let target: FocusedInputTarget
    }

    private let inputService: any AccessibilityActionAccessing
    private let applicationResolver: any RunningApplicationResolving
    private var lockedTarget: LockedTarget?

    init(
        inputService: any AccessibilityActionAccessing,
        applicationResolver: (any RunningApplicationResolving)? = nil
    ) {
        self.inputService = inputService
        self.applicationResolver = applicationResolver ?? RunningApplicationResolver()
    }

    func lockSessionTarget(_ target: FocusedInputTarget?) {
        lockedTarget = target.map {
            LockedTarget(revision: Self.makeTargetRevision(), target: $0)
        }
    }

    func clearSessionTarget() {
        lockedTarget = nil
    }

    func execute(_ proposal: ActionProposal) async -> ActionReceipt {
        guard proposal.kind == ConversationActionBridge.focusedInputWriteToolName,
              proposal.risk == .reversibleLocalWrite,
              proposal.reversibility == .reversible,
              proposal.requiredPermission == .none,
              let text = proposal.parameters["text"],
              !text.isEmpty else {
            return receipt(
                for: proposal,
                status: .failed,
                observedResult: "动作类型或安全策略不匹配",
                error: "Friday 拒绝了不符合可撤销输入规则的动作。"
            )
        }

        let applicationHint = proposal.parameters["application_hint"]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let targetResolution = resolveTarget(
            applicationHint: applicationHint.flatMap { $0.isEmpty ? nil : $0 }
        )
        guard case .resolved(let target, let revision) = targetResolution else {
            return failedReceipt(for: proposal, resolution: targetResolution)
        }

        let result = await inputService.insert(text, into: target)
        switch result {
        case .verified:
            return receipt(
                for: proposal,
                status: .succeeded,
                targetRevision: revision,
                observedResult: "目标输入框的文本变化已复验",
                undoToken: "system_undo:\(proposal.id.rawValue)"
            )
        case .dispatched:
            return receipt(
                for: proposal,
                status: .unknown,
                targetRevision: revision,
                observedResult: "粘贴事件已发送，但目标应用未提供可验证的文本值",
                undoToken: "system_undo:\(proposal.id.rawValue)"
            )
        case .targetUnavailable:
            return receipt(
                for: proposal,
                status: .failed,
                targetRevision: revision,
                observedResult: "目标应用已不可用",
                error: "目标应用已经关闭。"
            )
        case .focusChanged:
            return receipt(
                for: proposal,
                status: .failed,
                targetRevision: revision,
                observedResult: "无法恢复并复验目标输入焦点",
                error: "目标输入框焦点已经变化，Friday 没有写入其他位置。"
            )
        case .pasteEventUnavailable:
            return receipt(
                for: proposal,
                status: .failed,
                targetRevision: revision,
                observedResult: "系统未接受粘贴事件",
                error: "无法向目标输入框发送写入操作。"
            )
        case .systemError:
            return receipt(
                for: proposal,
                status: .failed,
                targetRevision: revision,
                observedResult: "Accessibility 目标复验失败",
                error: "系统无法验证目标输入框，Friday 没有执行写入。"
            )
        }
    }

    private func resolveTarget(applicationHint: String?) -> TargetResolution {
        guard let applicationHint else {
            guard let lockedTarget else {
                return .unavailable("开始对话时没有聚焦输入框，也没有指定目标应用。")
            }
            return .resolved(lockedTarget.target, lockedTarget.revision)
        }

        switch applicationResolver.resolve(applicationHint) {
        case .notRunning:
            return .unavailable("没有找到正在运行的“\(applicationHint)”。")
        case .ambiguous:
            return .unavailable("“\(applicationHint)”对应多个应用，请说出更完整的应用名称。")
        case .resolved(let application):
            if let lockedTarget,
               lockedTarget.target.processIdentifier == application.processIdentifier {
                return .resolved(lockedTarget.target, lockedTarget.revision)
            }
            switch inputService.captureFocusedTarget(
                processIdentifier: application.processIdentifier,
                applicationName: application.localizedName
            ) {
            case .target(let target):
                return .resolved(target, Self.makeTargetRevision())
            case .secureInput:
                return .unavailable("“\(applicationHint)”当前聚焦的是密码输入框，Friday 不会写入。")
            case .accessibilityDenied:
                return .unavailable("Friday 没有辅助功能权限，无法定位“\(applicationHint)”的输入框。")
            case .fridayFocused:
                return .unavailable("不能把 Friday 自己作为输入目标。")
            case .noFocusedElement, .notEditable:
                return .unavailable("“\(applicationHint)”中没有已聚焦的可编辑输入框。")
            case .systemError:
                return .unavailable("系统无法读取“\(applicationHint)”当前聚焦的输入框。")
            }
        }
    }

    private func failedReceipt(
        for proposal: ActionProposal,
        resolution: TargetResolution
    ) -> ActionReceipt {
        let message: String
        switch resolution {
        case .resolved:
            message = "目标输入框不可用。"
        case .unavailable(let reason):
            message = reason
        }
        return receipt(
            for: proposal,
            status: .failed,
            observedResult: "没有找到可安全写入的目标",
            error: message
        )
    }

    private func receipt(
        for proposal: ActionProposal,
        status: ActionReceiptStatus,
        targetRevision: String? = nil,
        observedResult: String,
        undoToken: String? = nil,
        error: String? = nil
    ) -> ActionReceipt {
        ActionReceipt(
            id: .make(),
            workID: proposal.workID,
            actionID: proposal.id,
            status: status,
            targetRevision: targetRevision,
            observedResult: observedResult,
            undoToken: undoToken,
            executedAt: Date(),
            error: error
        )
    }

    private static func makeTargetRevision() -> String {
        "target_\(UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased())"
    }
}

private enum TargetResolution {
    case resolved(FocusedInputTarget, String)
    case unavailable(String)
}
