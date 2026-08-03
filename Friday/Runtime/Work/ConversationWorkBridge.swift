// 功能：把 Realtime Talk 中的后台任务工具调用连接到 Friday 本地 Work Service，并把结果返回当前对话。
// 职责：定义 Work 数据契约与本地 HTTP 客户端，校验工具参数，执行幂等提交、状态查询和取消，并轮询后台任务直到终态只交付一次。
// 边界：只调用配置的本地 Work 接口，不直接操作文件、应用或账号，不执行真实外部副作用，也不负责终态结果的界面展示。

import Foundation

struct WorkID: Hashable, Sendable, Codable, CustomStringConvertible {
    let rawValue: String

    init?(_ rawValue: String?) {
        guard let rawValue,
              rawValue.range(
                of: #"^work_[a-f0-9]{32}$"#,
                options: [.regularExpression, .caseInsensitive]
              ) != nil else { return nil }
        self.rawValue = rawValue
    }

    var description: String { rawValue }
}

enum WorkState: String, Codable, Equatable, Sendable {
    case queued
    case running
    case completed
    case cancelled
    case failed

    var isTerminal: Bool {
        self == .completed || self == .cancelled || self == .failed
    }
}

struct WorkResult: Codable, Equatable, Sendable {
    let summary: String
    let detail: String
}

struct WorkRecord: Codable, Equatable, Sendable {
    let id: WorkID
    let objective: String
    let objectiveSource: String
    let executor: String
    let state: WorkState
    let publicActivity: String
    let result: WorkResult?
    let error: String?
    let createdAt: String
    let updatedAt: String

    enum CodingKeys: String, CodingKey {
        case id
        case objective
        case objectiveSource = "objective_source"
        case executor
        case state
        case publicActivity = "public_activity"
        case result
        case error
        case createdAt = "created_at"
        case updatedAt = "updated_at"
    }
}

@MainActor
protocol WorkServicing {
    func submit(
        objective: String,
        submissionKey: String,
        objectiveSource: String
    ) async throws -> WorkRecord
    func status(for workID: WorkID) async throws -> WorkRecord
    func cancel(_ workID: WorkID) async throws -> WorkRecord
}

struct LocalWorkServiceClient: WorkServicing {
    enum ServiceError: LocalizedError {
        case invalidEndpoint
        case invalidResponse
        case rejected(String)

        var errorDescription: String? {
            switch self {
            case .invalidEndpoint:
                return "Agent 服务地址未配置。"
            case .invalidResponse:
                return "Agent 服务返回了无效数据。"
            case .rejected(let message):
                return message.isEmpty ? "Agent 服务暂时不可用。" : message
            }
        }
    }

    private let endpoint: URL?
    private let urlSession: URLSession

    init(
        endpoint: URL? = RealtimeConfiguration.workEndpoint,
        urlSession: URLSession = .shared
    ) {
        self.endpoint = endpoint
        self.urlSession = urlSession
    }

    func submit(
        objective: String,
        submissionKey: String,
        objectiveSource: String
    ) async throws -> WorkRecord {
        guard let endpoint else { throw ServiceError.invalidEndpoint }
        let body = try JSONSerialization.data(withJSONObject: [
            "objective": objective,
            "submission_key": submissionKey,
            "objective_source": objectiveSource
        ])
        return try await request(endpoint, method: "POST", body: body)
    }

    func status(for workID: WorkID) async throws -> WorkRecord {
        guard let endpoint else { throw ServiceError.invalidEndpoint }
        return try await request(
            endpoint.appendingPathComponent(workID.rawValue),
            method: "GET",
            body: nil
        )
    }

    func cancel(_ workID: WorkID) async throws -> WorkRecord {
        guard let endpoint else { throw ServiceError.invalidEndpoint }
        return try await request(
            endpoint
                .appendingPathComponent(workID.rawValue)
                .appendingPathComponent("cancel"),
            method: "POST",
            body: nil
        )
    }

    private func request(
        _ url: URL,
        method: String,
        body: Data?
    ) async throws -> WorkRecord {
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = 5
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if body != nil {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        request.httpBody = body

        let (data, response) = try await urlSession.data(for: request)
        guard let response = response as? HTTPURLResponse else {
            throw ServiceError.invalidResponse
        }
        guard (200..<300).contains(response.statusCode) else {
            let message = (try? JSONDecoder().decode(
                WorkServiceErrorResponse.self,
                from: data
            ))?.error ?? ""
            throw ServiceError.rejected(message)
        }
        guard let work = try? JSONDecoder().decode(
            WorkServiceResponse.self,
            from: data
        ).work else {
            throw ServiceError.invalidResponse
        }
        return work
    }
}

struct ConversationToolResolution: Equatable, Sendable {
    let callID: ConversationToolCallID
    let output: String
    let workToObserve: WorkID?
}

@MainActor
final class ConversationWorkBridge {
    var onTerminalWork: ((WorkRecord) -> Void)?

    private let service: any WorkServicing
    private let transcriptWaitAttempts: Int
    private let transcriptWaitInterval: Duration
    private var latestWorkID: WorkID?
    private var latestDraftID: WorkDraftID?
    private var observationTasks: [WorkID: Task<Void, Never>] = [:]
    private var deliveredTerminalWorkIDs: Set<WorkID> = []
    private var finalTranscripts: [ConversationTurnID: FinalUserTranscript] = [:]
    private var failedTranscriptionTurnIDs: Set<ConversationTurnID> = []
    private var drafts: [WorkDraftID: WorkDraft] = [:]
    private var draftIDBySubmissionCallID: [ConversationToolCallID: WorkDraftID] = [:]

    init(
        service: (any WorkServicing)? = nil,
        transcriptWaitAttempts: Int = 24,
        transcriptWaitInterval: Duration = .milliseconds(50)
    ) {
        self.service = service ?? LocalWorkServiceClient()
        self.transcriptWaitAttempts = max(0, transcriptWaitAttempts)
        self.transcriptWaitInterval = transcriptWaitInterval
    }

    func beginConversationSession() {
        clearConversationDrafts()
    }

    func endConversationSession() {
        clearConversationDrafts()
    }

    func recordFinalTranscript(_ transcript: FinalUserTranscript) {
        finalTranscripts[transcript.turnID] = transcript
        failedTranscriptionTurnIDs.remove(transcript.turnID)
        for draftID in Array(drafts.keys) {
            guard var draft = drafts[draftID],
                  draft.sourceTurnID == transcript.turnID,
                  draft.state == .awaitingTranscript else { continue }
            draft.sourceTranscript = transcript
            draft.state = .awaitingConfirmation
            drafts[draftID] = draft
        }
    }

    func markFinalTranscriptUnavailable(for turnID: ConversationTurnID) {
        guard finalTranscripts[turnID] == nil else { return }
        failedTranscriptionTurnIDs.insert(turnID)
    }

    func resolve(
        _ call: ConversationToolCall,
        sourceTurnID: ConversationTurnID? = nil
    ) async -> ConversationToolResolution {
        do {
            switch call.name {
            case "submit_work":
                return try await prepareDraft(call, sourceTurnID: sourceTurnID)

            case "confirm_work":
                return try await confirmDraft(call, confirmationTurnID: sourceTurnID)

            case "discard_work_draft":
                return try discardDraft(call)

            case "get_work_status":
                let workID = try requestedWorkID(from: call.argumentsJSON)
                let work = try await service.status(for: workID)
                latestWorkID = work.id
                return ConversationToolResolution(
                    callID: call.callID,
                    output: encodeWorkStatus(work),
                    workToObserve: nil
                )

            case "cancel_work":
                let workID = try requestedWorkID(from: call.argumentsJSON)
                let work = try await service.cancel(workID)
                observationTasks.removeValue(forKey: workID)?.cancel()
                deliveredTerminalWorkIDs.insert(workID)
                latestWorkID = work.id
                return ConversationToolResolution(
                    callID: call.callID,
                    output: encodeWorkStatus(work),
                    workToObserve: nil
                )

            default:
                throw ToolError.unsupportedTool
            }
        } catch {
            return ConversationToolResolution(
                callID: call.callID,
                output: encodeOutput([
                    "status": "rejected",
                    "message": userFacingMessage(for: error)
                ]),
                workToObserve: nil
            )
        }
    }

    func observe(_ workID: WorkID) {
        guard observationTasks[workID] == nil,
              !deliveredTerminalWorkIDs.contains(workID) else { return }
        observationTasks[workID] = Task { [weak self] in
            guard let self else { return }
            for _ in 0..<120 {
                try? await Task.sleep(for: .milliseconds(250))
                guard !Task.isCancelled else { return }
                do {
                    let work = try await service.status(for: workID)
                    guard work.state.isTerminal else { continue }
                    observationTasks.removeValue(forKey: workID)
                    guard deliveredTerminalWorkIDs.insert(workID).inserted else { return }
                    onTerminalWork?(work)
                    return
                } catch {
                    continue
                }
            }
            observationTasks.removeValue(forKey: workID)
        }
    }

    private func prepareDraft(
        _ call: ConversationToolCall,
        sourceTurnID: ConversationTurnID?
    ) async throws -> ConversationToolResolution {
        guard let sourceTurnID else { throw ToolError.unmatchedTurn }
        let arguments = try decodeArguments(call.argumentsJSON)
        guard let objective = normalizedString(arguments["objective"]) else {
            throw ToolError.invalidArguments("缺少可核对的任务目标。")
        }

        let draftID: WorkDraftID
        if let existingDraftID = draftIDBySubmissionCallID[call.callID] {
            draftID = existingDraftID
        } else {
            draftID = WorkDraftID.make()
            drafts[draftID] = WorkDraft(
                id: draftID,
                sourceTurnID: sourceTurnID,
                submissionCallID: call.callID,
                objective: objective,
                sourceTranscript: finalTranscripts[sourceTurnID],
                state: finalTranscripts[sourceTurnID] == nil
                    ? .awaitingTranscript
                    : .awaitingConfirmation,
                submittedWorkID: nil
            )
            draftIDBySubmissionCallID[call.callID] = draftID
        }
        latestDraftID = draftID

        if failedTranscriptionTurnIDs.contains(sourceTurnID) {
            return transcriptUnavailableResolution(callID: call.callID, draftID: draftID)
        }
        if finalTranscripts[sourceTurnID] == nil {
            _ = await waitForFinalTranscript(turnID: sourceTurnID)
        }
        guard var draft = drafts[draftID] else { throw ToolError.noRecentDraft }
        if let transcript = finalTranscripts[sourceTurnID] {
            draft.sourceTranscript = transcript
            draft.state = .awaitingConfirmation
            drafts[draftID] = draft
        }
        guard draft.sourceTranscript != nil else {
            return transcriptUnavailableResolution(callID: call.callID, draftID: draftID)
        }

        return ConversationToolResolution(
            callID: call.callID,
            output: encodeOutput([
                "status": "awaiting_confirmation",
                "draft_id": draftID.rawValue,
                "objective": draft.objective,
                "message": "这只是任务草稿，尚未创建后台任务。请复述目标并让用户明确说‘确认提交’或‘取消’。"
            ]),
            workToObserve: nil
        )
    }

    private func confirmDraft(
        _ call: ConversationToolCall,
        confirmationTurnID: ConversationTurnID?
    ) async throws -> ConversationToolResolution {
        guard let confirmationTurnID else { throw ToolError.unmatchedTurn }
        let draftID = try requestedDraftID(from: call.argumentsJSON)
        guard var draft = drafts[draftID] else { throw ToolError.noRecentDraft }
        guard draft.state != .discarded else { throw ToolError.discardedDraft }
        guard confirmationTurnID != draft.sourceTurnID else {
            throw ToolError.unverifiedConfirmation
        }

        if draft.state == .submitted, let workID = draft.submittedWorkID {
            let work = try await service.status(for: workID)
            latestWorkID = work.id
            return acceptedResolution(callID: call.callID, work: work)
        }

        if failedTranscriptionTurnIDs.contains(confirmationTurnID) {
            throw ToolError.unverifiedConfirmation
        }
        if finalTranscripts[confirmationTurnID] == nil {
            _ = await waitForFinalTranscript(turnID: confirmationTurnID)
        }
        guard let confirmation = finalTranscripts[confirmationTurnID],
              isExplicitConfirmation(confirmation.text) else {
            throw ToolError.unverifiedConfirmation
        }
        guard draft.sourceTranscript != nil else {
            throw ToolError.missingSourceTranscript
        }

        draft.state = .submitting
        drafts[draftID] = draft
        do {
            let work = try await service.submit(
                objective: draft.objective,
                submissionKey: "draft:\(draftID.rawValue)",
                objectiveSource: "model_derived"
            )
            draft.state = .submitted
            draft.submittedWorkID = work.id
            drafts[draftID] = draft
            latestWorkID = work.id
            return acceptedResolution(callID: call.callID, work: work)
        } catch {
            draft.state = .awaitingConfirmation
            drafts[draftID] = draft
            throw error
        }
    }

    private func discardDraft(
        _ call: ConversationToolCall
    ) throws -> ConversationToolResolution {
        let draftID = try requestedDraftID(from: call.argumentsJSON)
        guard var draft = drafts[draftID] else { throw ToolError.noRecentDraft }
        guard draft.state != .submitted else { throw ToolError.alreadySubmittedDraft }
        draft.state = .discarded
        drafts[draftID] = draft
        return ConversationToolResolution(
            callID: call.callID,
            output: encodeOutput([
                "status": "discarded",
                "draft_id": draftID.rawValue,
                "message": "任务草稿已取消，没有创建后台任务。"
            ]),
            workToObserve: nil
        )
    }

    private func acceptedResolution(
        callID: ConversationToolCallID,
        work: WorkRecord
    ) -> ConversationToolResolution {
        ConversationToolResolution(
            callID: callID,
            output: encodeOutput([
                "status": "accepted",
                "work_id": work.id.rawValue,
                "state": work.state.rawValue,
                "message": "已确认并创建后台测试任务，当前语音对话可以继续。"
            ]),
            workToObserve: work.state.isTerminal ? nil : work.id
        )
    }

    private func transcriptUnavailableResolution(
        callID: ConversationToolCallID,
        draftID: WorkDraftID
    ) -> ConversationToolResolution {
        ConversationToolResolution(
            callID: callID,
            output: encodeOutput([
                "status": "transcript_unavailable",
                "draft_id": draftID.rawValue,
                "message": "这一轮没有可核对的最终用户转写，因此没有创建后台任务。请重新说出完整任务；在最终转写 Provider 启用前，Friday 只能继续普通对话。"
            ]),
            workToObserve: nil
        )
    }

    private func waitForFinalTranscript(
        turnID: ConversationTurnID
    ) async -> FinalUserTranscript? {
        for _ in 0..<transcriptWaitAttempts {
            if let transcript = finalTranscripts[turnID] { return transcript }
            if failedTranscriptionTurnIDs.contains(turnID) { return nil }
            try? await Task.sleep(for: transcriptWaitInterval)
            guard !Task.isCancelled else { return nil }
        }
        return finalTranscripts[turnID]
    }

    private func requestedDraftID(from argumentsJSON: String) throws -> WorkDraftID {
        let arguments = try decodeArguments(argumentsJSON)
        if let rawDraftID = normalizedString(arguments["draft_id"]) {
            guard let draftID = WorkDraftID(rawDraftID) else {
                throw ToolError.invalidArguments("任务草稿编号无效。")
            }
            return draftID
        }
        guard let latestDraftID else { throw ToolError.noRecentDraft }
        return latestDraftID
    }

    private func isExplicitConfirmation(_ value: String) -> Bool {
        let normalized = value
            .lowercased()
            .replacingOccurrences(
                of: #"[\s，。！？、,.!?]+"#,
                with: "",
                options: .regularExpression
            )
        return [
            "确认提交",
            "确认创建",
            "确认执行",
            "confirm",
            "confirmed"
        ].contains(normalized)
    }

    private func clearConversationDrafts() {
        finalTranscripts.removeAll(keepingCapacity: false)
        failedTranscriptionTurnIDs.removeAll(keepingCapacity: false)
        drafts.removeAll(keepingCapacity: false)
        draftIDBySubmissionCallID.removeAll(keepingCapacity: false)
        latestDraftID = nil
    }

    private func requestedWorkID(from argumentsJSON: String) throws -> WorkID {
        let arguments = try decodeArguments(argumentsJSON)
        if let rawWorkID = normalizedString(arguments["work_id"]) {
            guard let workID = WorkID(rawWorkID) else {
                throw ToolError.invalidArguments("任务编号无效。")
            }
            return workID
        }
        guard let latestWorkID else { throw ToolError.noRecentWork }
        return latestWorkID
    }

    private func decodeArguments(_ value: String) throws -> [String: Any] {
        guard let data = value.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data),
              let arguments = object as? [String: Any] else {
            throw ToolError.invalidArguments("任务参数无效。")
        }
        return arguments
    }

    private func normalizedString(_ value: Any?) -> String? {
        guard let value = value as? String else { return nil }
        let normalized = value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(
                of: #"\s+"#,
                with: " ",
                options: .regularExpression
            )
        return normalized.isEmpty ? nil : String(normalized.prefix(2_000))
    }

    private func encodeWorkStatus(_ work: WorkRecord) -> String {
        var payload: [String: Any] = [
            "status": "ok",
            "work_id": work.id.rawValue,
            "state": work.state.rawValue,
            "public_activity": work.publicActivity
        ]
        if let result = work.result {
            payload["result"] = [
                "summary": result.summary,
                "detail": result.detail
            ]
        }
        if let error = work.error, !error.isEmpty {
            payload["error"] = error
        }
        return encodeOutput(payload)
    }

    private func encodeOutput(_ payload: [String: Any]) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: payload),
              let output = String(data: data, encoding: .utf8) else {
            return #"{"status":"rejected","message":"无法生成任务结果。"}"#
        }
        return output
    }

    private func userFacingMessage(for error: Error) -> String {
        if let error = error as? ToolError {
            return error.errorDescription ?? "无法处理这次任务。"
        }
        if error is URLError {
            return "Agent 服务未连接。"
        }
        return (error as? LocalizedError)?.errorDescription
            ?? "Agent 服务暂时不可用。"
    }
}

private enum ToolError: LocalizedError {
    case invalidArguments(String)
    case noRecentWork
    case noRecentDraft
    case unmatchedTurn
    case missingSourceTranscript
    case unverifiedConfirmation
    case discardedDraft
    case alreadySubmittedDraft
    case unsupportedTool

    var errorDescription: String? {
        switch self {
        case .invalidArguments(let message):
            return message
        case .noRecentWork:
            return "当前对话里没有可以查询或取消的后台任务。"
        case .noRecentDraft:
            return "当前对话里没有等待确认的任务草稿。"
        case .unmatchedTurn:
            return "Friday 无法确认这次请求属于哪一轮对话，因此没有执行。"
        case .missingSourceTranscript:
            return "原任务没有可靠的最终用户转写，因此不能提交。请重新说出完整任务。"
        case .unverifiedConfirmation:
            return "Friday 没有从最终用户转写中确认到‘确认提交’，因此没有创建任务。"
        case .discardedDraft:
            return "这个任务草稿已经取消。"
        case .alreadySubmittedDraft:
            return "这个任务草稿已经提交；如需停止，请取消对应的后台任务。"
        case .unsupportedTool:
            return "Friday 暂不支持这个任务操作。"
        }
    }
}

private struct WorkServiceResponse: Decodable {
    let work: WorkRecord
}

private struct WorkServiceErrorResponse: Decodable {
    let error: String
}
