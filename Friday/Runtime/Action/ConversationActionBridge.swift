// 功能：把 Realtime 的明确输入框写入工具调用转换为自动执行的本地 ActionProposal 和结构化工具结果。
// 职责：校验完整文字、绑定当前锁定目标、串行调用 Action Executor，并按 Tool Call ID 缓存结果以避免重复写入。
// 边界：只自动执行锁定目标上的可撤销本地写入；不记录正文，不支持发送提交等外部副作用，也不把结果未知视为成功。

import Foundation

@MainActor
final class ConversationActionBridge {
    static let focusedInputWriteToolName = "write_focused_input"

    var onResolution: ((ActionProposal, ActionReceipt) -> Void)?

    private let executor: any LocalActionExecuting
    private var completedOutputs: [ConversationToolCallID: String] = [:]
    private var activeCallID: ConversationToolCallID?
    private var sessionRevision = 0

    init(executor: (any LocalActionExecuting)? = nil) {
        self.executor = executor ?? UnavailableLocalActionExecutor()
    }

    func beginConversationSession() {
        sessionRevision += 1
        completedOutputs.removeAll(keepingCapacity: false)
    }

    func endConversationSession() {
        sessionRevision += 1
        executor.clearSessionTarget()
        completedOutputs.removeAll(keepingCapacity: false)
    }

    func canResolve(_ toolName: String) -> Bool {
        toolName == Self.focusedInputWriteToolName
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
        guard activeCallID == nil else {
            return resolution(
                callID: call.callID,
                payload: [
                    "status": "busy",
                    "message": "上一项本地写入仍在执行，请稍后重试。"
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
                risk: .reversibleLocalWrite,
                reversibility: .systemUndo,
                executionPolicy: .automaticWhenTargetLocked
            )
            let revisionAtStart = sessionRevision
            activeCallID = call.callID
            defer {
                if activeCallID == call.callID {
                    activeCallID = nil
                }
            }

            let receipt = await executor.execute(proposal)
            let toolResolution = receiptResolution(
                callID: call.callID,
                receipt: receipt
            )
            if sessionRevision == revisionAtStart {
                completedOutputs[call.callID] = toolResolution.output
                onResolution?(proposal, receipt)
            }
            return toolResolution
        } catch {
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

    var errorDescription: String? {
        switch self {
        case .invalidText:
            return "模型没有提供可写入的完整文字。"
        case .textTooLong:
            return "本次写入内容过长，请缩短后重试。"
        }
    }
}
