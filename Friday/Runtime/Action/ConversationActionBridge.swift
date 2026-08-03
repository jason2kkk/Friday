// 功能：把 Realtime 的明确输入框写入工具调用转换为供应商无关的 ActionProposal，并返回本地执行回执。
// 职责：校验文字与应用提示、串行调用本地执行器，并按 Tool Call ID 缓存结果以避免重复写入。
// 边界：只处理可撤销本地文字写入；不记录正文、不发送或提交内容，也不把未知结果视为成功。

import Foundation

@MainActor
protocol LocalActionExecuting: AnyObject {
    func lockSessionTarget(_ target: FocusedInputTarget?)
    func execute(_ proposal: ActionProposal) async -> ActionReceipt
    func clearSessionTarget()
}

@MainActor
final class UnavailableLocalActionExecutor: LocalActionExecuting {
    func lockSessionTarget(_ target: FocusedInputTarget?) {}

    func execute(_ proposal: ActionProposal) async -> ActionReceipt {
        ActionReceipt(
            id: .make(),
            workID: proposal.workID,
            actionID: proposal.id,
            status: .failed,
            targetRevision: nil,
            observedResult: "未执行本地动作",
            undoToken: nil,
            executedAt: Date(),
            error: "当前没有可用的本地动作执行器。"
        )
    }

    func clearSessionTarget() {}
}

@MainActor
final class ConversationActionBridge {
    static let focusedInputWriteToolName = "write_focused_input"

    private let executor: any LocalActionExecuting
    private var completedOutputs: [ConversationToolCallID: String] = [:]
    private var activeCallID: ConversationToolCallID?
    private var sessionRevision = 0

    init(executor: (any LocalActionExecuting)? = nil) {
        self.executor = executor ?? UnavailableLocalActionExecutor()
    }

    func lockSessionTarget(_ target: FocusedInputTarget?) {
        executor.lockSessionTarget(target)
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

        do {
            let arguments = try requestedArguments(from: call.argumentsJSON)
            let proposal = ActionProposal(
                id: .make(),
                workID: .makeForLocalAction(),
                kind: Self.focusedInputWriteToolName,
                target: arguments.applicationHint ?? "session_input",
                parameters: [
                    "text": arguments.text,
                    "application_hint": arguments.applicationHint ?? ""
                ],
                preview: arguments.applicationHint.map { "写入 \($0) 的输入框" }
                    ?? "写入本次对话锁定的输入框",
                risk: .reversibleLocalWrite,
                reversibility: .reversible,
                requiredPermission: .none
            )
            let revisionAtStart = sessionRevision
            activeCallID = call.callID
            defer {
                if activeCallID == call.callID {
                    activeCallID = nil
                }
            }

            let receipt = await executor.execute(proposal)
            let toolResolution = receiptResolution(callID: call.callID, receipt: receipt)
            if sessionRevision == revisionAtStart {
                completedOutputs[call.callID] = toolResolution.output
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

    private func requestedArguments(from argumentsJSON: String) throws -> WriteArguments {
        guard let data = argumentsJSON.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data),
              let arguments = object as? [String: Any],
              let rawText = arguments["text"] as? String else {
            throw BridgeError.invalidText
        }
        let text = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw BridgeError.invalidText }
        guard text.count <= 8_000 else { throw BridgeError.textTooLong }

        let applicationHint = (arguments["application"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return WriteArguments(
            text: text,
            applicationHint: applicationHint.flatMap { $0.isEmpty ? nil : $0 }
        )
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
            payload["message"] = "文字已写入目标输入框，可以使用 Command-Z 撤销。"
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

private struct WriteArguments {
    let text: String
    let applicationHint: String?
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

private extension WorkID {
    static func makeForLocalAction() -> WorkID {
        WorkID(
            "work_\(UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased())"
        )!
    }
}
