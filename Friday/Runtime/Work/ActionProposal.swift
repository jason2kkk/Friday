// 功能：定义 Agent 提出本地动作与 Friday 回传执行证据时使用的供应商无关数据契约。
// 职责：表达动作身份、风险、权限、可撤销性和执行回执，并提供有版本和大小限制的 RPC JSON 编解码。
// 边界：不批准或执行任何动作，不持有 AXUIElement、凭证或用户文件，也不把模型文本视为执行成功证据。

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
        ActionID(
            "action_\(UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased())"
        )!
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        let rawValue = try container.decode(String.self)
        guard let value = ActionID(rawValue) else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Invalid ActionID"
            )
        }
        self = value
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
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
        ActionReceiptID(
            "receipt_\(UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased())"
        )!
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        let rawValue = try container.decode(String.self)
        guard let value = ActionReceiptID(rawValue) else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Invalid ActionReceiptID"
            )
        }
        self = value
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }

    var description: String { rawValue }
}

enum ActionRisk: String, Codable, Equatable, Sendable {
    case readOnly = "read_only"
    case reversibleLocalWrite = "reversible_local_write"
    case externalSideEffect = "external_side_effect"
    case destructive
}

enum ActionReversibility: String, Codable, Equatable, Sendable {
    case reversible
    case irreversible
    case unknown
}

enum ActionPermissionRequirement: String, Codable, Equatable, Sendable {
    case none
    case allowOnce = "allow_once"
    case allowForSession = "allow_for_session"
}

struct ActionProposal: Codable, Equatable, Sendable {
    let id: ActionID
    let workID: WorkID
    let kind: String
    let target: String
    let parameters: [String: String]
    let preview: String
    let risk: ActionRisk
    let reversibility: ActionReversibility
    let requiredPermission: ActionPermissionRequirement

    enum CodingKeys: String, CodingKey {
        case id
        case workID = "work_id"
        case kind
        case target
        case parameters
        case preview
        case risk
        case reversibility
        case requiredPermission = "required_permission"
    }

    init(
        id: ActionID,
        workID: WorkID,
        kind: String,
        target: String,
        parameters: [String: String],
        preview: String,
        risk: ActionRisk,
        reversibility: ActionReversibility,
        requiredPermission: ActionPermissionRequirement
    ) {
        self.id = id
        self.workID = workID
        self.kind = kind
        self.target = target
        self.parameters = parameters
        self.preview = preview
        self.risk = risk
        self.reversibility = reversibility
        self.requiredPermission = requiredPermission
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(ActionID.self, forKey: .id)
        let rawWorkID = try container.decode(String.self, forKey: .workID)
        guard let workID = WorkID(rawWorkID) else {
            throw DecodingError.dataCorruptedError(
                forKey: .workID,
                in: container,
                debugDescription: "Invalid WorkID"
            )
        }
        self.workID = workID
        kind = try container.decode(String.self, forKey: .kind)
        target = try container.decode(String.self, forKey: .target)
        parameters = try container.decode([String: String].self, forKey: .parameters)
        preview = try container.decode(String.self, forKey: .preview)
        risk = try container.decode(ActionRisk.self, forKey: .risk)
        reversibility = try container.decode(ActionReversibility.self, forKey: .reversibility)
        requiredPermission = try container.decode(
            ActionPermissionRequirement.self,
            forKey: .requiredPermission
        )
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(workID.rawValue, forKey: .workID)
        try container.encode(kind, forKey: .kind)
        try container.encode(target, forKey: .target)
        try container.encode(parameters, forKey: .parameters)
        try container.encode(preview, forKey: .preview)
        try container.encode(risk, forKey: .risk)
        try container.encode(reversibility, forKey: .reversibility)
        try container.encode(requiredPermission, forKey: .requiredPermission)
    }
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

    enum CodingKeys: String, CodingKey {
        case id
        case workID = "work_id"
        case actionID = "action_id"
        case status
        case targetRevision = "target_revision"
        case observedResult = "observed_result"
        case undoToken = "undo_token"
        case executedAt = "executed_at"
        case error
    }

    init(
        id: ActionReceiptID,
        workID: WorkID,
        actionID: ActionID,
        status: ActionReceiptStatus,
        targetRevision: String?,
        observedResult: String,
        undoToken: String?,
        executedAt: Date,
        error: String?
    ) {
        self.id = id
        self.workID = workID
        self.actionID = actionID
        self.status = status
        self.targetRevision = targetRevision
        self.observedResult = observedResult
        self.undoToken = undoToken
        self.executedAt = executedAt
        self.error = error
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(ActionReceiptID.self, forKey: .id)
        let rawWorkID = try container.decode(String.self, forKey: .workID)
        guard let workID = WorkID(rawWorkID) else {
            throw DecodingError.dataCorruptedError(
                forKey: .workID,
                in: container,
                debugDescription: "Invalid WorkID"
            )
        }
        self.workID = workID
        actionID = try container.decode(ActionID.self, forKey: .actionID)
        status = try container.decode(ActionReceiptStatus.self, forKey: .status)
        targetRevision = try container.decodeIfPresent(String.self, forKey: .targetRevision)
        observedResult = try container.decode(String.self, forKey: .observedResult)
        undoToken = try container.decodeIfPresent(String.self, forKey: .undoToken)
        executedAt = try container.decode(Date.self, forKey: .executedAt)
        error = try container.decodeIfPresent(String.self, forKey: .error)
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(workID.rawValue, forKey: .workID)
        try container.encode(actionID, forKey: .actionID)
        try container.encode(status, forKey: .status)
        try container.encodeIfPresent(targetRevision, forKey: .targetRevision)
        try container.encode(observedResult, forKey: .observedResult)
        try container.encodeIfPresent(undoToken, forKey: .undoToken)
        try container.encode(executedAt, forKey: .executedAt)
        try container.encodeIfPresent(error, forKey: .error)
    }
}

enum ActionRPCMethod: String, Codable, Equatable, Sendable {
    case proposeAction = "action.propose"
    case reportReceipt = "action.receipt"
}

struct ActionRPCEnvelope<Payload>: Codable, Equatable, Sendable
where Payload: Codable & Equatable & Sendable {
    let version: Int
    let method: ActionRPCMethod
    let requestID: String
    let payload: Payload

    enum CodingKeys: String, CodingKey {
        case version
        case method
        case requestID = "request_id"
        case payload
    }
}

enum ActionRPCCodecError: LocalizedError, Equatable {
    case payloadTooLarge
    case unsupportedVersion
    case unexpectedMethod

    var errorDescription: String? {
        switch self {
        case .payloadTooLarge:
            return "Agent 动作消息超过 Friday 的安全大小限制。"
        case .unsupportedVersion:
            return "Agent 动作消息版本不受支持。"
        case .unexpectedMethod:
            return "Agent 动作消息类型与当前操作不匹配。"
        }
    }
}

enum ActionRPCCodec {
    static let currentVersion = 1
    static let maximumPayloadBytes = 64 * 1_024

    static func encode<Payload>(
        _ envelope: ActionRPCEnvelope<Payload>
    ) throws -> Data where Payload: Codable & Equatable & Sendable {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(envelope)
        guard data.count <= maximumPayloadBytes else {
            throw ActionRPCCodecError.payloadTooLarge
        }
        return data
    }

    static func decode<Payload>(
        _ type: Payload.Type,
        from data: Data,
        expectedMethod: ActionRPCMethod
    ) throws -> ActionRPCEnvelope<Payload>
    where Payload: Codable & Equatable & Sendable {
        guard data.count <= maximumPayloadBytes else {
            throw ActionRPCCodecError.payloadTooLarge
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let envelope = try decoder.decode(ActionRPCEnvelope<Payload>.self, from: data)
        guard envelope.version == currentVersion else {
            throw ActionRPCCodecError.unsupportedVersion
        }
        guard envelope.method == expectedMethod else {
            throw ActionRPCCodecError.unexpectedMethod
        }
        return envelope
    }
}
