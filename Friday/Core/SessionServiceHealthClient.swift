// 功能：确认 Friday 本地凭证服务及其 OpenAI 模型路由是否已经可以支持 Live 模式。
// 职责：调用独立模型就绪端点，解码配置、累计签发、保护和账单状态，并输出可恢复错误。
// 边界：不把本地进程存活当成模型就绪，不申请短期凭证、不创建 Realtime 会话，也不会产生模型 token。

import Foundation

struct SessionServiceHealth: Decodable, Equatable, Sendable {
    let status: String
    let model: String
    let sessionsIssued: Int?
    let burstProtectionEnabled: Bool?
    let accountBalanceReadable: Bool?
    let billingStatus: String?
    let billingIssueCode: String?
    let inputTranscriptionEnabled: Bool?
    let inputTranscriptionModel: String?

    enum CodingKeys: String, CodingKey {
        case status
        case model
        case sessionsIssued = "sessions_issued"
        case burstProtectionEnabled = "burst_protection_enabled"
        case accountBalanceReadable = "account_balance_readable"
        case billingStatus = "billing_status"
        case billingIssueCode = "billing_issue_code"
        case inputTranscriptionEnabled = "input_transcription_enabled"
        case inputTranscriptionModel = "input_transcription_model"
    }
}

protocol SessionServiceHealthChecking {
    func check() async throws -> SessionServiceHealth
}

struct SessionServiceHealthClient: SessionServiceHealthChecking {
    enum HealthError: LocalizedError {
        case invalidEndpoint
        case unavailable(Int)
        case invalidResponse
        case serviceNotReady
        case service(String)

        var errorDescription: String? {
            switch self {
            case .invalidEndpoint:
                return "语音服务地址未配置"
            case .unavailable:
                return "语音服务未连接"
            case .invalidResponse:
                return "语音服务状态异常"
            case .serviceNotReady:
                return "语音服务尚未就绪"
            case .service(let message):
                return message
            }
        }
    }

    private let endpoint: URL?
    private let urlSession: URLSession

    init(
        endpoint: URL? = RealtimeConfiguration.readinessEndpoint,
        urlSession: URLSession = .shared
    ) {
        self.endpoint = endpoint
        self.urlSession = urlSession
    }

    func check() async throws -> SessionServiceHealth {
        guard let endpoint else { throw HealthError.invalidEndpoint }

        var request = URLRequest(url: endpoint)
        request.timeoutInterval = 4
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let (data, response) = try await urlSession.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw HealthError.invalidResponse
        }
        guard (200..<300).contains(httpResponse.statusCode) else {
            if let response = try? JSONDecoder().decode(ServiceErrorResponse.self, from: data),
               !response.error.isEmpty {
                throw HealthError.service(response.error)
            }
            throw HealthError.unavailable(httpResponse.statusCode)
        }
        guard let health = try? JSONDecoder().decode(SessionServiceHealth.self, from: data) else {
            throw HealthError.invalidResponse
        }
        guard health.status == "ok" else { throw HealthError.serviceNotReady }
        return health
    }
}

private struct ServiceErrorResponse: Decodable {
    let error: String
}
