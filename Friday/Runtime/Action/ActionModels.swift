// 功能：定义 Friday Agent 提议本地动作以及系统执行后返回证据的稳定数据契约。
// 职责：表达动作身份、目标描述、风险、可撤销性、参数与 ActionReceipt，不包含平台句柄或执行逻辑。
// 边界：完整写入预览只在本地内存中流转；模型不能用 ActionProposal 代替本地权限决策或执行回执。

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

enum ActionPermissionRequirement: String, Codable, Equatable, Sendable {
    case allowOnce = "allow_once"
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
    let preview: String
    let risk: ActionRisk
    let reversibility: ActionReversibility
    let requiredPermission: ActionPermissionRequirement
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
