// 功能：读取 Friday 本地短期凭证服务、OpenAI 模型路由和本地用量监控的当前健康状态。
// 职责：解码模型配置、代理状态、累计签发、重试保护和账单可见性，并把网络或响应错误转换为调用方可处理的结果。
// 边界：只调用健康检查端点，不申请短期凭证、不创建 Realtime 会话，也不会产生模型 token。

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
        endpoint: URL? = RealtimeConfiguration.healthEndpoint,
        urlSession: URLSession = .shared
    ) {
        self.endpoint = endpoint
        self.urlSession = urlSession
    }

    func check() async throws -> SessionServiceHealth {
        guard let endpoint else { throw HealthError.invalidEndpoint }

        var request = URLRequest(url: endpoint)
        request.timeoutInterval = 3
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
