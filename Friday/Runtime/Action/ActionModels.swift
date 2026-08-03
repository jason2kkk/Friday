// 功能：定义 Friday Agent 提议本地动作以及系统执行后返回证据的稳定数据契约。
// 职责：表达动作身份、目标描述、风险、自动执行策略、参数与 ActionReceipt，不包含平台句柄或执行逻辑。
// 边界：自动执行只适用于锁定目标上的可撤销本地写入；外部副作用仍需独立权限策略和执行回执。

import Foundation

struct ActionID: Hashable, Sendable, Codable, CustomStringConvertible {
    let rawValue: String

    init?(_ rawValue: String?) {
        guard let rawValue,
              rawValue.range(
                of: #"^action_[a-f0-9]{32}$"#,
                options: [.regularExpression, .caseInsensitive]
              ) != nil else { return nil }
        self.rawValue = rawValue
    }

    static func make() -> ActionID {
        ActionID("action_\(UUID().hexIdentifier)")!
    }

    var description: String { rawValue }
}

struct ActionReceiptID: Hashable, Sendable, Codable, CustomStringConvertible {
    let rawValue: String

    init?(_ rawValue: String?) {
        guard let rawValue,
              rawValue.range(
                of: #"^receipt_[a-f0-9]{32}$"#,
                options: [.regularExpression, .caseInsensitive]
              ) != nil else { return nil }
        self.rawValue = rawValue
    }

    static func make() -> ActionReceiptID {
        ActionReceiptID("receipt_\(UUID().hexIdentifier)")!
    }

    var description: String { rawValue }
}

enum AgentActionKind: String, Codable, Equatable, Sendable {
    case writeFocusedInput = "write_focused_input"
}

enum ActionRisk: String, Codable, Equatable, Sendable {
    case reversibleLocalWrite = "reversible_local_write"
}

enum ActionReversibility: String, Codable, Equatable, Sendable {
    case systemUndo = "system_undo"
}

enum ActionExecutionPolicy: String, Codable, Equatable, Sendable {
    case automaticWhenTargetLocked = "automatic_when_target_locked"
}

struct ActionTargetDescriptor: Codable, Equatable, Sendable {
    let revision: String
    let applicationName: String
    let role: String
}

struct FocusedInputWriteParameters: Codable, Equatable, Sendable {
    let text: String
}

struct ActionProposal: Codable, Equatable, Sendable {
    let id: ActionID
    let workID: WorkID
    let kind: AgentActionKind
    let target: ActionTargetDescriptor
    let parameters: FocusedInputWriteParameters
    let risk: ActionRisk
    let reversibility: ActionReversibility
    let executionPolicy: ActionExecutionPolicy
}

enum ActionReceiptStatus: String, Codable, Equatable, Sendable {
    case succeeded
    case failed
    case unknown
}

struct ActionReceipt: Codable, Equatable, Sendable {
    let id: ActionReceiptID
    let workID: WorkID
    let actionID: ActionID
    let status: ActionReceiptStatus
    let targetRevision: String?
    let observedResult: String
    let undoToken: String?
    let executedAt: Date
    let error: String?
}

@MainActor
protocol LocalActionExecuting: AnyObject {
    var focusedInputTarget: ActionTargetDescriptor? { get }
    func execute(_ proposal: ActionProposal) async -> ActionReceipt
    func clearSessionTarget()
}

@MainActor
final class UnavailableLocalActionExecutor: LocalActionExecuting {
    var focusedInputTarget: ActionTargetDescriptor? { nil }

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
            error: "当前没有可用的输入目标。"
        )
    }

    func clearSessionTarget() {}
}

extension WorkID {
    static func make() -> WorkID {
        WorkID("work_\(UUID().hexIdentifier)")!
    }
}

private extension UUID {
    var hexIdentifier: String {
        uuidString.replacingOccurrences(of: "-", with: "").lowercased()
    }
}
