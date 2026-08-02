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
    private var latestWorkID: WorkID?
    private var observationTasks: [WorkID: Task<Void, Never>] = [:]
    private var deliveredTerminalWorkIDs: Set<WorkID> = []

    init(service: (any WorkServicing)? = nil) {
        self.service = service ?? LocalWorkServiceClient()
    }

    func resolve(_ call: ConversationToolCall) async -> ConversationToolResolution {
        do {
            switch call.name {
            case "submit_work":
                let arguments = try decodeArguments(call.argumentsJSON)
                guard let objective = normalizedString(arguments["objective"]) else {
                    throw ToolError.invalidArguments("缺少可执行的任务目标。")
                }
                let work = try await service.submit(
                    objective: objective,
                    submissionKey: "realtime:\(call.callID.rawValue)",
                    objectiveSource: "model_derived"
                )
                latestWorkID = work.id
                return ConversationToolResolution(
                    callID: call.callID,
                    output: encodeOutput([
                        "status": "accepted",
                        "work_id": work.id.rawValue,
                        "state": work.state.rawValue,
                        "message": "任务已在后台创建，当前语音对话可以继续。"
                    ]),
                    workToObserve: work.state.isTerminal ? nil : work.id
                )

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
    case unsupportedTool

    var errorDescription: String? {
        switch self {
        case .invalidArguments(let message):
            return message
        case .noRecentWork:
            return "当前对话里没有可以查询或取消的后台任务。"
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
