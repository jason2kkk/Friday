// 功能：执行语音 Agent 明确提出的应用打开与可撤销输入框写入，并返回本地可观察的 ActionReceipt。
// 职责：复验动作风险，启动或激活指定应用，等待其 Accessibility 目标就绪，再定位输入框，并把权限快照和本地结果映射为回执。
// 边界：不生成文字、不发送或提交内容；应用不存在、目标歧义、密码框或焦点不可靠时不猜测其他控件。

import Foundation

@MainActor
protocol AccessibilityActionAccessing: AnyObject {
    var isTrusted: Bool { get }
    func captureActionTarget(
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

    var accessibilityPermissionGranted: Bool? {
        inputService.isTrusted
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
        switch proposal.kind {
        case ConversationActionBridge.openApplicationToolName:
            return await openApplication(proposal)
        case ConversationActionBridge.focusedInputWriteToolName:
            return await writeFocusedInput(proposal)
        default:
            return receipt(
                for: proposal,
                status: .failed,
                observedResult: "动作类型或安全策略不匹配",
                errorCode: "policy_rejected",
                error: "Olli 拒绝了当前未注册的本地动作。"
            )
        }
    }

    private func openApplication(_ proposal: ActionProposal) async -> ActionReceipt {
        guard proposal.risk == .localNavigation,
              proposal.reversibility == .reversible,
              proposal.requiredPermission == .none,
              let applicationHint = proposal.parameters["application"]?
                .trimmingCharacters(in: .whitespacesAndNewlines),
              !applicationHint.isEmpty else {
            return receipt(
                for: proposal,
                status: .failed,
                observedResult: "打开应用动作不符合本地策略",
                errorCode: "policy_rejected",
                error: "Olli 没有得到可验证的应用名称。"
            )
        }

        switch await applicationResolver.activate(applicationHint) {
        case .activated(let application, let wasAlreadyRunning):
            return receipt(
                for: proposal,
                status: .succeeded,
                targetRevision: Self.applicationRevision(application),
                observedResult: wasAlreadyRunning
                    ? "目标应用已从后台切换到前台"
                    : "目标应用已启动并位于前台"
            )
        case .notFound:
            return receipt(
                for: proposal,
                status: .failed,
                observedResult: "本机没有找到唯一应用 Bundle",
                errorCode: "application_not_found",
                error: "没有找到已安装的“\(applicationHint)”。"
            )
        case .ambiguous:
            return receipt(
                for: proposal,
                status: .failed,
                observedResult: "应用名称对应多个候选",
                errorCode: "application_ambiguous",
                error: "“\(applicationHint)”对应多个应用，请说出更完整的名称。"
            )
        case .failed(_, let failure):
            return receipt(
                for: proposal,
                status: .failed,
                observedResult: "应用没有在有限等待时间内进入前台",
                errorCode: failure.rawValue,
                error: "无法打开或切换到“\(applicationHint)”。"
            )
        }
    }

    private func writeFocusedInput(_ proposal: ActionProposal) async -> ActionReceipt {
        guard proposal.risk == .reversibleLocalWrite,
              proposal.reversibility == .reversible,
              proposal.requiredPermission == .none,
              let text = proposal.parameters["text"],
              !text.isEmpty else {
            return receipt(
                for: proposal,
                status: .failed,
                observedResult: "动作类型或安全策略不匹配",
                errorCode: "policy_rejected",
                error: "Olli 拒绝了不符合可撤销输入规则的动作。"
            )
        }

        let applicationHint = proposal.parameters["application_hint"]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let targetResolution = await resolveTarget(
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
                errorCode: "application_not_running",
                error: "目标应用已经关闭。"
            )
        case .focusChanged:
            return receipt(
                for: proposal,
                status: .failed,
                targetRevision: revision,
                observedResult: "无法恢复并复验目标输入焦点",
                errorCode: "focus_restore_failed",
                error: "目标输入框焦点已经变化，Olli 没有写入其他位置。"
            )
        case .pasteEventUnavailable:
            return receipt(
                for: proposal,
                status: .failed,
                targetRevision: revision,
                observedResult: "系统未接受粘贴事件",
                errorCode: "paste_event_failed",
                error: "无法向目标输入框发送写入操作。"
            )
        case .systemError:
            return receipt(
                for: proposal,
                status: .failed,
                targetRevision: revision,
                observedResult: "Accessibility 目标复验失败",
                errorCode: "accessibility_read_failed",
                error: "系统无法验证目标输入框，Olli 没有执行写入。"
            )
        }
    }

    private func resolveTarget(applicationHint: String?) async -> TargetResolution {
        guard let applicationHint else {
            guard let lockedTarget else {
                return .unavailable(
                    "开始对话时没有聚焦输入框，也没有指定目标应用。",
                    "target_not_focused"
                )
            }
            return .resolved(lockedTarget.target, lockedTarget.revision)
        }

        switch await applicationResolver.activate(applicationHint) {
        case .notFound:
            return .unavailable(
                "没有找到已安装的“\(applicationHint)”。",
                "application_not_found"
            )
        case .ambiguous:
            return .unavailable(
                "“\(applicationHint)”对应多个应用，请说出更完整的应用名称。",
                "application_ambiguous"
            )
        case .failed(_, let failure):
            return .unavailable(
                "无法打开或切换到“\(applicationHint)”。",
                failure.rawValue
            )
        case .activated(let application, _):
            switch await captureReadyActionTarget(application: application) {
            case .target(let target):
                return .resolved(target, Self.makeTargetRevision())
            case .secureInput:
                return .unavailable(
                    "“\(applicationHint)”当前聚焦的是密码输入框，Olli 不会写入。",
                    "secure_input"
                )
            case .accessibilityDenied:
                return .unavailable(
                    "Olli 没有辅助功能权限，无法定位“\(applicationHint)”的输入框。",
                    "accessibility_denied"
                )
            case .fridayFocused:
                return .unavailable(
                    "不能把 Olli 自己作为输入目标。",
                    "self_target_rejected"
                )
            case .noFocusedElement, .notEditable:
                return .unavailable(
                    "“\(applicationHint)”中没有已聚焦或鼠标指向的可编辑输入框。",
                    "target_not_focused"
                )
            case .systemError:
                return .unavailable(
                    "系统无法读取“\(applicationHint)”当前聚焦的输入框。",
                    "accessibility_read_failed"
                )
            }
        }
    }

    private func captureReadyActionTarget(
        application: RunningApplicationReference
    ) async -> InputTargetResult {
        var latestResult: InputTargetResult = .noFocusedElement
        for attempt in 0..<24 {
            latestResult = inputService.captureActionTarget(
                processIdentifier: application.processIdentifier,
                applicationName: application.localizedName
            )
            switch latestResult {
            case .target, .secureInput, .accessibilityDenied, .fridayFocused:
                return latestResult
            case .noFocusedElement, .notEditable, .systemError:
                if attempt < 23 {
                    try? await Task.sleep(for: .milliseconds(125))
                }
            }
        }
        return latestResult
    }

    private func failedReceipt(
        for proposal: ActionProposal,
        resolution: TargetResolution
    ) -> ActionReceipt {
        let message: String
        switch resolution {
        case .resolved:
            message = "目标输入框不可用。"
        case .unavailable(let reason, _):
            message = reason
        }
        let errorCode: String?
        switch resolution {
        case .resolved:
            errorCode = "target_unavailable"
        case .unavailable(_, let code):
            errorCode = code
        }
        return receipt(
            for: proposal,
            status: .failed,
            observedResult: "没有找到可安全写入的目标",
            errorCode: errorCode,
            error: message
        )
    }

    private func receipt(
        for proposal: ActionProposal,
        status: ActionReceiptStatus,
        targetRevision: String? = nil,
        observedResult: String,
        undoToken: String? = nil,
        errorCode: String? = nil,
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
            errorCode: errorCode,
            error: error
        )
    }

    private static func makeTargetRevision() -> String {
        "target_\(UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased())"
    }

    private static func applicationRevision(
        _ application: RunningApplicationReference
    ) -> String {
        let identity = application.bundleIdentifier
            ?? String(application.processIdentifier)
        return "application_\(identity)"
    }
}

private enum TargetResolution {
    case resolved(FocusedInputTarget, String)
    case unavailable(String, String)
}
