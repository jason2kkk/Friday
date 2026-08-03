// 功能：把 Realtime 的输入框写入工具调用转换为本地 ActionProposal、一次性权限等待和结构化工具结果。
// 职责：校验工具参数、绑定当前锁定目标、协调 Permission Runtime 与 Action Executor，并对重复调用保持幂等。
// 边界：不直接访问 Accessibility、不记录写入正文、不支持发送提交等外部副作用，也不把模型调用视为用户授权。

import Foundation

enum ConversationActionOutcome: Equatable, Sendable {
    case rejected
    case cancelled
    case receipt(ActionReceipt)
}

@MainActor
final class ConversationActionBridge {
    static let focusedInputWriteToolName = "propose_focused_input_write"

    var onPermissionRequest: ((ActionPermissionRequest) -> Void)?
    var onExecutionStarted: ((ActionPermissionRequest) -> Void)?
    var onResolution: ((ActionPermissionRequest, ConversationActionOutcome) -> Void)?

    private let executor: any LocalActionExecuting
    private let permissionRuntime: ActionPermissionRuntime
    private var completedOutputs: [ConversationToolCallID: String] = [:]
    private var pendingCallID: ConversationToolCallID?

    init(
        executor: (any LocalActionExecuting)? = nil,
        permissionRuntime: ActionPermissionRuntime? = nil
    ) {
        self.executor = executor ?? UnavailableLocalActionExecutor()
        self.permissionRuntime = permissionRuntime ?? ActionPermissionRuntime()
    }

    func beginConversationSession() {
        permissionRuntime.cancelPendingPermission()
        completedOutputs.removeAll(keepingCapacity: false)
        pendingCallID = nil
    }

    func endConversationSession() {
        permissionRuntime.cancelPendingPermission()
        executor.clearSessionTarget()
        completedOutputs.removeAll(keepingCapacity: false)
        pendingCallID = nil
    }

    func canResolve(_ toolName: String) -> Bool {
        toolName == Self.focusedInputWriteToolName
    }

    func respond(
        permissionID: ActionPermissionID,
        actionID: ActionID,
        allow: Bool
    ) -> Bool {
        permissionRuntime.respond(
            permissionID: permissionID,
            actionID: actionID,
            decision: allow ? .allowOnce : .reject
        )
    }

    func resolve(_ call: ConversationToolCall) async -> ConversationToolResolution {
        guard canResolve(call.name) else {
            return resolution(
                callID: call.callID,
                payload: [
                    "status": "rejected",
                    "message": "Friday 暂不支持这个本地动作。"
                ]
            )
        }
        if let output = completedOutputs[call.callID] {
            return ConversationToolResolution(
                callID: call.callID,
                output: output,
                workToObserve: nil
            )
        }
        guard pendingCallID == nil else {
            return resolution(
                callID: call.callID,
                payload: [
                    "status": "busy",
                    "message": "已有一项写入正在等待用户确认。"
                ]
            )
        }
        guard let target = executor.focusedInputTarget else {
            return resolution(
                callID: call.callID,
                payload: [
                    "status": "target_unavailable",
                    "message": "启动语音 Agent 时没有锁定可安全写入的输入框。请聚焦目标输入框后重新开始对话。"
                ]
            )
        }

        do {
            let text = try requestedText(from: call.argumentsJSON)
            let proposal = ActionProposal(
                id: .make(),
                workID: .make(),
                kind: .writeFocusedInput,
                target: target,
                parameters: FocusedInputWriteParameters(text: text),
                preview: text,
                risk: .reversibleLocalWrite,
                reversibility: .systemUndo,
                requiredPermission: .allowOnce
            )
            pendingCallID = call.callID
            var permissionRequest: ActionPermissionRequest?
            let decision = try await permissionRuntime.requestPermission(
                for: proposal
            ) { request in
                permissionRequest = request
                onPermissionRequest?(request)
            }
            guard let request = permissionRequest else {
                throw BridgeError.permissionUnavailable
            }

            let outcome: ConversationActionOutcome
            let toolResolution: ConversationToolResolution
            switch decision {
            case .allowOnce:
                onExecutionStarted?(request)
                let receipt = await executor.execute(proposal)
                outcome = .receipt(receipt)
                toolResolution = receiptResolution(callID: call.callID, receipt: receipt)
            case .reject:
                outcome = .rejected
                toolResolution = resolution(
                    callID: call.callID,
                    payload: [
                        "status": "rejected_by_user",
                        "action_id": proposal.id.rawValue,
                        "work_id": proposal.workID.rawValue,
                        "message": "用户取消了这次写入，未执行任何动作。"
                    ]
                )
            case .cancelled:
                outcome = .cancelled
                toolResolution = resolution(
                    callID: call.callID,
                    payload: [
                        "status": "cancelled",
                        "action_id": proposal.id.rawValue,
                        "work_id": proposal.workID.rawValue,
                        "message": "对话已结束，这次写入没有执行。"
                    ]
                )
            }
            pendingCallID = nil
            completedOutputs[call.callID] = toolResolution.output
            onResolution?(request, outcome)
            return toolResolution
        } catch {
            pendingCallID = nil
            return resolution(
                callID: call.callID,
                payload: [
                    "status": "rejected",
                    "message": (error as? LocalizedError)?.errorDescription
                        ?? "无法准备这次写入。"
                ]
            )
        }
    }

    private func requestedText(from argumentsJSON: String) throws -> String {
        guard let data = argumentsJSON.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data),
              let arguments = object as? [String: Any],
              let rawText = arguments["text"] as? String else {
            throw BridgeError.invalidText
        }
        let text = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw BridgeError.invalidText }
        guard text.count <= 8_000 else { throw BridgeError.textTooLong }
        return text
    }

    private func receiptResolution(
        callID: ConversationToolCallID,
        receipt: ActionReceipt
    ) -> ConversationToolResolution {
        var payload: [String: Any] = [
            "status": receipt.status.rawValue,
            "receipt_id": receipt.id.rawValue,
            "action_id": receipt.actionID.rawValue,
            "work_id": receipt.workID.rawValue,
            "observed_result": receipt.observedResult,
            "undo_available": receipt.undoToken != nil
        ]
        if let error = receipt.error, !error.isEmpty {
            payload["error"] = error
        }
        switch receipt.status {
        case .succeeded:
            payload["message"] = "文字已写入锁定的输入框，可以使用 Command-Z 撤销。"
        case .unknown:
            payload["message"] = "写入事件已经发送，但目标应用无法提供可验证结果，请用户查看输入框。"
        case .failed:
            payload["message"] = "写入没有完成，Friday 没有改写其他输入框。"
        }
        return resolution(callID: callID, payload: payload)
    }

    private func resolution(
        callID: ConversationToolCallID,
        payload: [String: Any]
    ) -> ConversationToolResolution {
        let data = try? JSONSerialization.data(withJSONObject: payload)
        let output = data.flatMap { String(data: $0, encoding: .utf8) }
            ?? #"{"status":"rejected","message":"无法生成动作结果。"}"#
        return ConversationToolResolution(
            callID: callID,
            output: output,
            workToObserve: nil
        )
    }
}

private enum BridgeError: LocalizedError {
    case invalidText
    case textTooLong
    case permissionUnavailable

    var errorDescription: String? {
        switch self {
        case .invalidText:
            return "模型没有提供可预览的写入文字。"
        case .textTooLong:
            return "本次写入内容过长，请缩短后重试。"
        case .permissionUnavailable:
            return "无法创建本次写入确认。"
        }
    }
}
