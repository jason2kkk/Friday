// 功能：表达语音 Agent 在正式创建 Work 前的内部任务草稿与确认状态。
// 职责：保存同一用户 Turn 的模型意图、最终用户转写和提交结果，支持幂等确认与丢弃。
// 边界：WorkDraft 不进入后台队列、不产生工具副作用，也不替代正式 Work 或权限确认。

import Foundation

struct WorkDraftID: Hashable, Sendable, CustomStringConvertible {
    let rawValue: String

    init?(_ rawValue: String?) {
        guard let rawValue,
              rawValue.range(
                of: #"^draft_[a-f0-9]{32}$"#,
                options: [.regularExpression, .caseInsensitive]
              ) != nil else { return nil }
        self.rawValue = rawValue
    }

    static func make() -> WorkDraftID {
        WorkDraftID(
            "draft_\(UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased())"
        )!
    }

    var description: String { rawValue }
}

enum WorkDraftState: String, Equatable, Sendable {
    case awaitingTranscript
    case awaitingConfirmation
    case submitting
    case submitted
    case discarded
}

struct WorkDraft: Equatable, Sendable {
    let id: WorkDraftID
    let sourceTurnID: ConversationTurnID
    let submissionCallID: ConversationToolCallID
    let objective: String
    var sourceTranscript: FinalUserTranscript?
    var state: WorkDraftState
    var submittedWorkID: WorkID?
}
