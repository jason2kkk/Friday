// 功能：让每个 Agent ActionProposal 在执行前获得一次与具体动作绑定的本地用户决策。
// 职责：创建 PermissionID、挂起单个待确认请求、校验 ActionID，并确保允许、拒绝或会话取消只能消费一次。
// 边界：不展示界面、不执行动作、不持久化授权，也不提供跨会话或模糊语音授权。

import Foundation

struct ActionPermissionID: Hashable, Sendable, CustomStringConvertible {
    let rawValue: String

    init?(_ rawValue: String?) {
        guard let rawValue,
              rawValue.range(
                of: #"^permission_[a-f0-9]{32}$"#,
                options: [.regularExpression, .caseInsensitive]
              ) != nil else { return nil }
        self.rawValue = rawValue
    }

    static func make() -> ActionPermissionID {
        ActionPermissionID(
            "permission_\(UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased())"
        )!
    }

    var description: String { rawValue }
}

struct ActionPermissionRequest: Equatable, Sendable {
    let id: ActionPermissionID
    let proposal: ActionProposal
    let createdAt: Date
}

enum ActionPermissionDecision: Equatable, Sendable {
    case allowOnce
    case reject
    case cancelled
}

@MainActor
final class ActionPermissionRuntime {
    enum PermissionError: LocalizedError {
        case requestInProgress

        var errorDescription: String? {
            "已有一项动作正在等待确认。"
        }
    }

    private struct PendingPermission {
        let request: ActionPermissionRequest
        let continuation: CheckedContinuation<ActionPermissionDecision, Never>
    }

    private var pending: PendingPermission?

    var currentRequest: ActionPermissionRequest? {
        pending?.request
    }

    func requestPermission(
        for proposal: ActionProposal,
        onCreated: (ActionPermissionRequest) -> Void
    ) async throws -> ActionPermissionDecision {
        guard pending == nil else { throw PermissionError.requestInProgress }
        let request = ActionPermissionRequest(
            id: .make(),
            proposal: proposal,
            createdAt: Date()
        )
        return await withCheckedContinuation { continuation in
            pending = PendingPermission(request: request, continuation: continuation)
            onCreated(request)
        }
    }

    @discardableResult
    func respond(
        permissionID: ActionPermissionID,
        actionID: ActionID,
        decision: ActionPermissionDecision
    ) -> Bool {
        guard let pending,
              pending.request.id == permissionID,
              pending.request.proposal.id == actionID else { return false }
        self.pending = nil
        pending.continuation.resume(returning: decision)
        return true
    }

    func cancelPendingPermission() {
        guard let pending else { return }
        self.pending = nil
        pending.continuation.resume(returning: .cancelled)
    }
}
