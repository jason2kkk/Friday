// 功能：通过 OpenAI Realtime WebSocket 将一轮 Dictate PCM16 语音整理为经过本地防护的可粘贴文本。
// 职责：获取短期凭证，建立单轮会话，顺序发送音频与提交事件，并解析文本增量、最终结果、原始转写、用量和协议错误。
// 边界：不持有长期 API Key、不采集麦克风、不写入目标应用，也不在最终校验前把模型增量当作可交付结果。

import Foundation
import OSLog

@MainActor
final class RealtimeDictationProvider: DictationProvider {
    enum RealtimeError: LocalizedError {
        case invalidCredentialEndpoint
        case credentialRequestFailed(Int)
        case invalidCredentialResponse
        case sessionAlreadyActive
        case noSession
        case transport(String)
        case service(String)
        case timeout
        case emptyOutput
        case noSpeech

        var errorDescription: String? {
            switch self {
            case .invalidCredentialEndpoint:
                return "语音服务地址未配置。"
            case .credentialRequestFailed(let statusCode):
                return "无法连接语音服务（HTTP \(statusCode)）。"
            case .invalidCredentialResponse:
                return "语音服务返回了无效数据。"
            case .sessionAlreadyActive:
                return "上一轮语音输入仍在进行。"
            case .noSession:
                return "当前没有正在进行的语音输入。"
            case .transport:
                return "无法连接语音服务，请确认本地服务已启动。"
            case .service:
                return "语音服务暂时不可用，请稍后再试。"
            case .timeout:
                return "文字整理超时，请重试。"
            case .emptyOutput:
                return "没有识别到可用的语音内容。"
            case .noSpeech:
                return "没有检测到清晰语音，请重新说一遍。"
            }
        }
    }

    let displayName = "实时语音"
    var onPartialText: ((String) -> Void)?

    private static let packetByteCount = 4_800
    private let logger = Logger(subsystem: "com.example.Friday", category: "Realtime")
    private let credentialEndpoint: URL?
    private let urlSession: URLSession

    private var webSocket: URLSessionWebSocketTask?
    private var audioBuffer = Data()
    private var audioContinuation: AsyncStream<Data>.Continuation?
    private var audioSenderTask: Task<Error?, Never>?
    private var activeContext: DictationContext?
    private var expectsInputTranscript = false
    private var sessionStartedAt: Date?

    init(
        credentialEndpoint: URL? = RealtimeConfiguration.credentialEndpoint,
        urlSession: URLSession = .shared
    ) {
        self.credentialEndpoint = credentialEndpoint
        self.urlSession = urlSession
    }

    func begin(context: DictationContext) async throws {
        guard activeContext == nil else { throw RealtimeError.sessionAlreadyActive }
        guard let credentialEndpoint else { throw RealtimeError.invalidCredentialEndpoint }

        let sessionStart = Date()
        sessionStartedAt = sessionStart
        let credentialStart = Date()
        let credential = try await fetchCredential(from: credentialEndpoint)
        logger.info(
            "Dictate stage=credential_ready elapsed_ms=\(self.elapsedMilliseconds(since: sessionStart), privacy: .public) request_ms=\(self.elapsedMilliseconds(since: credentialStart), privacy: .public)"
        )
        guard var components = URLComponents(string: credential.realtimeURL) else {
            throw RealtimeError.invalidCredentialResponse
        }
        if components.queryItems?.contains(where: { $0.name == "model" }) != true {
            var queryItems = components.queryItems ?? []
            queryItems.append(URLQueryItem(name: "model", value: credential.model))
            components.queryItems = queryItems
        }
        guard let socketURL = components.url else { throw RealtimeError.invalidCredentialResponse }

        var request = URLRequest(url: socketURL)
        request.setValue("Bearer \(credential.value)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 15

        let socket = urlSession.webSocketTask(with: request)
        webSocket = socket
        activeContext = context
        expectsInputTranscript = credential.inputTranscriptionEnabled ?? false
        audioBuffer.removeAll(keepingCapacity: true)
        socket.resume()
        startAudioSender(for: socket)
        logger.info(
            "Dictate stage=socket_started elapsed_ms=\(self.elapsedMilliseconds(since: sessionStart), privacy: .public) model=\(credential.model, privacy: .public) input_transcription_wait=\(self.expectsInputTranscript, privacy: .public)"
        )
    }

    func append(_ chunk: AudioChunk) {
        guard activeContext != nil,
              chunk.sampleRate == 24_000,
              chunk.channelCount == 1 else { return }

        audioBuffer.append(chunk.pcm16)
        while audioBuffer.count >= Self.packetByteCount {
            let packet = Data(audioBuffer.prefix(Self.packetByteCount))
            audioBuffer.removeFirst(Self.packetByteCount)
            audioContinuation?.yield(packet)
        }
    }

    func finish() async throws -> DictationResult {
        guard activeContext != nil, let socket = webSocket else {
            throw RealtimeError.noSession
        }

        let finishStart = Date()

        if !audioBuffer.isEmpty {
            audioContinuation?.yield(audioBuffer)
            audioBuffer.removeAll(keepingCapacity: true)
        }
        audioContinuation?.finish()
        audioContinuation = nil

        if let senderError = await audioSenderTask?.value {
            resetSession(cancelSocket: true)
            throw RealtimeError.transport(senderError.localizedDescription)
        }
        audioSenderTask = nil
        logger.info(
            "Dictate stage=audio_upload_finished elapsed_ms=\(self.elapsedMilliseconds(since: finishStart), privacy: .public) session_ms=\(self.elapsedMillisecondsSinceSessionStart(), privacy: .public)"
        )

        do {
            try await sendJSON(["type": "input_audio_buffer.commit"], over: socket)
            logger.info(
                "Dictate stage=commit_sent elapsed_ms=\(self.elapsedMilliseconds(since: finishStart), privacy: .public) session_ms=\(self.elapsedMillisecondsSinceSessionStart(), privacy: .public)"
            )
            try await sendJSON(
                [
                    "type": "response.create",
                    "response": [
                        "output_modalities": ["text"],
                        "instructions": DictationPrompt.instructions,
                        "max_output_tokens": 256
                    ]
                ],
                over: socket
            )
            logger.info(
                "Dictate stage=response_requested elapsed_ms=\(self.elapsedMilliseconds(since: finishStart), privacy: .public) session_ms=\(self.elapsedMillisecondsSinceSessionStart(), privacy: .public)"
            )

            let result = try await receiveResultWithTimeout(from: socket)
            logger.info(
                "Dictate stage=final_result elapsed_ms=\(self.elapsedMilliseconds(since: finishStart), privacy: .public) session_ms=\(self.elapsedMillisecondsSinceSessionStart(), privacy: .public) input_transcription_wait=\(self.expectsInputTranscript, privacy: .public)"
            )
            resetSession(cancelSocket: false)
            socket.cancel(with: .normalClosure, reason: nil)
            logger.info(
                "Dictate stage=returned elapsed_ms=\(self.elapsedMilliseconds(since: finishStart), privacy: .public) total_tokens=\(result.usage.totalTokens, privacy: .public)"
            )
            return result
        } catch {
            logger.error(
                "Dictate stage=failed elapsed_ms=\(self.elapsedMilliseconds(since: finishStart), privacy: .public) session_ms=\(self.elapsedMillisecondsSinceSessionStart(), privacy: .public) error_type=\(String(describing: type(of: error)), privacy: .public)"
            )
            resetSession(cancelSocket: true)
            throw error
        }
    }

    func cancel() {
        resetSession(cancelSocket: true)
        logger.info("Realtime session cancelled")
    }

    private func fetchCredential(from endpoint: URL) async throws -> ClientCredential {
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 15
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let (data, response) = try await urlSession.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw RealtimeError.invalidCredentialResponse
        }
        guard (200..<300).contains(httpResponse.statusCode) else {
            let serviceMessage = (try? JSONDecoder().decode(
                CredentialServiceError.self,
                from: data
            ))?.error
            if let serviceMessage, !serviceMessage.isEmpty {
                throw RealtimeError.service(serviceMessage)
            }
            throw RealtimeError.credentialRequestFailed(httpResponse.statusCode)
        }

        guard let credential = try? JSONDecoder().decode(ClientCredential.self, from: data),
              !credential.value.isEmpty,
              !credential.model.isEmpty else {
            throw RealtimeError.invalidCredentialResponse
        }
        return credential
    }

    private func startAudioSender(for socket: URLSessionWebSocketTask) {
        var continuation: AsyncStream<Data>.Continuation?
        let stream = AsyncStream<Data> { continuation = $0 }
        audioContinuation = continuation
        audioSenderTask = Task { [weak self] in
            guard let self else { return nil }
            do {
                for await packet in stream {
                    guard !Task.isCancelled else { return nil }
                    try await sendJSON(
                        [
                            "type": "input_audio_buffer.append",
                            "audio": packet.base64EncodedString()
                        ],
                        over: socket
                    )
                }
                return nil
            } catch {
                return error
            }
        }
    }

    private func sendJSON(
        _ object: [String: Any],
        over socket: URLSessionWebSocketTask
    ) async throws {
        let data = try JSONSerialization.data(withJSONObject: object)
        guard let string = String(data: data, encoding: .utf8) else {
            throw RealtimeError.transport("Could not encode an event.")
        }
        try await socket.send(.string(string))
    }

    private func receiveResultWithTimeout(
        from socket: URLSessionWebSocketTask
    ) async throws -> DictationResult {
        try await withThrowingTaskGroup(of: DictationResult.self) { group in
            group.addTask { [weak self] in
                guard let self else { throw CancellationError() }
                return try await self.receiveResult(from: socket)
            }
            group.addTask {
                try await Task.sleep(for: .seconds(30))
                throw RealtimeError.timeout
            }

            guard let result = try await group.next() else {
                throw RealtimeError.timeout
            }
            group.cancelAll()
            return result
        }
    }

    private func receiveResult(
        from socket: URLSessionWebSocketTask
    ) async throws -> DictationResult {
        var parser = RealtimeEventParser(expectsInputTranscript: expectsInputTranscript)
        var firstEventLogged = false
        var responseDoneAt: Date?

        while !Task.isCancelled {
            let message = try await socket.receive()
            let data: Data
            switch message {
            case .string(let string):
                data = Data(string.utf8)
            case .data(let receivedData):
                data = receivedData
            @unknown default:
                continue
            }

            guard let event = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  event["type"] is String else { continue }

            let eventType = event["type"] as? String ?? "unknown"
            if !firstEventLogged {
                firstEventLogged = true
                logger.info(
                    "Dictate stage=first_event elapsed_ms=\(self.elapsedMillisecondsSinceSessionStart(), privacy: .public) event=\(eventType, privacy: .public)"
                )
            }
            if eventType == "response.done" {
                responseDoneAt = Date()
                logger.info(
                    "Dictate stage=response_done elapsed_ms=\(self.elapsedMillisecondsSinceSessionStart(), privacy: .public)"
                )
            } else if eventType == "conversation.item.input_audio_transcription.completed" {
                let waitMilliseconds = responseDoneAt.map { self.elapsedMilliseconds(since: $0) } ?? -1
                logger.info(
                    "Dictate stage=input_transcription_completed elapsed_ms=\(self.elapsedMillisecondsSinceSessionStart(), privacy: .public) after_response_ms=\(waitMilliseconds, privacy: .public)"
                )
            }

            switch try parser.consume(event) {
            case .ignored:
                continue
            case .partial:
                // Model deltas are untrusted until the final dictation guard validates them.
                continue
            case .completed(let result):
                return result
            }
        }

        throw CancellationError()
    }

    private func resetSession(cancelSocket: Bool) {
        audioContinuation?.finish()
        audioContinuation = nil
        audioSenderTask?.cancel()
        audioSenderTask = nil
        audioBuffer.removeAll(keepingCapacity: false)
        activeContext = nil
        expectsInputTranscript = false
        sessionStartedAt = nil

        if cancelSocket {
            webSocket?.cancel(with: .goingAway, reason: nil)
        }
        webSocket = nil
    }

    private func elapsedMilliseconds(since date: Date) -> Int {
        max(0, Int(Date().timeIntervalSince(date) * 1_000))
    }

    private func elapsedMillisecondsSinceSessionStart() -> Int {
        guard let sessionStartedAt else { return 0 }
        return elapsedMilliseconds(since: sessionStartedAt)
    }
}

enum RealtimeEventProgress: Equatable {
    case ignored
    case partial(String)
    case completed(DictationResult)
}

struct RealtimeEventParser {
    private let expectsInputTranscript: Bool
    private var streamedText = ""
    private var rawTranscript = ""
    private var pendingResponse: PendingRealtimeResponse?
    private var inputTranscriptionFailed = false

    init(expectsInputTranscript: Bool = false) {
        self.expectsInputTranscript = expectsInputTranscript
    }

    mutating func consume(_ event: [String: Any]) throws -> RealtimeEventProgress {
        guard let type = event["type"] as? String else { return .ignored }

        switch type {
        case "conversation.item.input_audio_transcription.delta":
            guard let delta = event["delta"] as? String, !delta.isEmpty else {
                return .ignored
            }
            rawTranscript.append(delta)
            return .ignored

        case "conversation.item.input_audio_transcription.completed":
            if let transcript = event["transcript"] as? String, !transcript.isEmpty {
                rawTranscript = transcript
            }
            guard let pendingResponse else { return .ignored }
            self.pendingResponse = nil
            return try resolve(
                candidateText: pendingResponse.candidateText,
                usage: pendingResponse.usage
            )

        case "conversation.item.input_audio_transcription.failed":
            inputTranscriptionFailed = true
            guard let pendingResponse else { return .ignored }
            self.pendingResponse = nil
            return try resolve(
                candidateText: pendingResponse.candidateText,
                usage: pendingResponse.usage,
                allowMissingTranscript: true
            )

        case "response.output_text.delta", "response.text.delta":
            guard let delta = event["delta"] as? String, !delta.isEmpty else {
                return .ignored
            }
            streamedText.append(delta)
            return .partial(streamedText)

        case "response.output_text.done", "response.text.done":
            guard let text = event["text"] as? String, !text.isEmpty else {
                return .ignored
            }
            streamedText = text
            return .partial(text)

        case "error":
            let errorObject = event["error"] as? [String: Any]
            let message = errorObject?["message"] as? String ?? "Unknown service error."
            throw RealtimeDictationProvider.RealtimeError.service(message)

        case "response.done":
            guard let response = event["response"] as? [String: Any] else {
                throw RealtimeDictationProvider.RealtimeError.emptyOutput
            }
            if let status = response["status"] as? String, status != "completed" {
                let details = response["status_details"] as? [String: Any]
                let errorObject = details?["error"] as? [String: Any]
                let reason = details?["reason"] as? String
                let message = errorObject?["message"] as? String
                    ?? reason
                    ?? "The response ended with status \(status)."
                throw RealtimeDictationProvider.RealtimeError.service(message)
            }

            let fullText = extractOutputText(from: response)
            let candidateText = (fullText.isEmpty ? streamedText : fullText)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !candidateText.isEmpty else {
                throw RealtimeDictationProvider.RealtimeError.emptyOutput
            }
            let usage = extractUsage(from: response)
            if expectsInputTranscript,
               rawTranscript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
               !inputTranscriptionFailed {
                pendingResponse = PendingRealtimeResponse(
                    candidateText: candidateText,
                    usage: usage
                )
                return .ignored
            }
            return try resolve(
                candidateText: candidateText,
                usage: usage,
                allowMissingTranscript: inputTranscriptionFailed
            )

        default:
            return .ignored
        }
    }

    private func resolve(
        candidateText: String,
        usage: DictationUsage,
        allowMissingTranscript: Bool = false
    ) throws -> RealtimeEventProgress {
        let transcript = rawTranscript.trimmingCharacters(in: .whitespacesAndNewlines)
        let usableTranscript = transcript.isEmpty ? nil : transcript
        if expectsInputTranscript, usableTranscript == nil, !allowMissingTranscript {
            return .ignored
        }
        guard let resolution = DictationPrompt.resolveOutput(
            modelOutput: candidateText,
            rawTranscript: usableTranscript
        ) else {
            throw RealtimeDictationProvider.RealtimeError.noSpeech
        }
        return .completed(
            DictationResult(
                rawTranscript: usableTranscript,
                finalText: resolution.text,
                hasUncertainty: resolution.usedRawTranscriptFallback,
                usage: usage
            )
        )
    }

    private func extractOutputText(from response: [String: Any]) -> String {
        guard let output = response["output"] as? [[String: Any]] else { return "" }
        return output.compactMap { item -> String? in
            guard let content = item["content"] as? [[String: Any]] else { return nil }
            return content.compactMap { contentPart in
                if let text = contentPart["text"] as? String { return text }
                if let transcript = contentPart["transcript"] as? String { return transcript }
                return nil
            }.joined()
        }.joined(separator: "\n")
    }

    private func extractUsage(from response: [String: Any]) -> DictationUsage {
        guard let usage = response["usage"] as? [String: Any] else { return .zero }
        let inputDetails = usage["input_token_details"] as? [String: Any]
        let outputDetails = usage["output_token_details"] as? [String: Any]
        let cachedDetails = inputDetails?["cached_tokens_details"] as? [String: Any]
        return DictationUsage(
            inputTextTokens: inputDetails?["text_tokens"] as? Int ?? 0,
            inputAudioTokens: inputDetails?["audio_tokens"] as? Int ?? 0,
            cachedInputTextTokens: cachedDetails?["text_tokens"] as? Int ?? 0,
            cachedInputAudioTokens: cachedDetails?["audio_tokens"] as? Int ?? 0,
            inputImageTokens: inputDetails?["image_tokens"] as? Int ?? 0,
            cachedInputImageTokens: cachedDetails?["image_tokens"] as? Int ?? 0,
            outputTextTokens: outputDetails?["text_tokens"] as? Int
                ?? usage["output_tokens"] as? Int
                ?? 0,
            totalTokens: usage["total_tokens"] as? Int ?? 0
        )
    }
}

private struct ClientCredential: Decodable {
    let value: String
    let model: String
    let realtimeURL: String
    let inputTranscriptionEnabled: Bool?
    let inputTranscriptionModel: String?

    enum CodingKeys: String, CodingKey {
        case value
        case model
        case realtimeURL = "realtime_url"
        case inputTranscriptionEnabled = "input_transcription_enabled"
        case inputTranscriptionModel = "input_transcription_model"
    }
}

private struct PendingRealtimeResponse {
    let candidateText: String
    let usage: DictationUsage
}

private struct CredentialServiceError: Decodable {
    let error: String
}

enum RealtimeConfiguration {
    static var credentialEndpoint: URL? {
        let environment = ProcessInfo.processInfo.environment
        let configuredValue = environment["FRIDAY_SESSION_ENDPOINT"]
            ?? "http://127.0.0.1:8787/v1/realtime/client-secret"
        return URL(string: configuredValue)
    }

    static var readinessEndpoint: URL? {
        guard let credentialEndpoint else { return nil }
        var components = URLComponents(url: credentialEndpoint, resolvingAgainstBaseURL: false)
        components?.path = "/ready"
        components?.query = nil
        components?.fragment = nil
        return components?.url
    }

    static var workEndpoint: URL? {
        guard let credentialEndpoint else { return nil }
        var components = URLComponents(url: credentialEndpoint, resolvingAgainstBaseURL: false)
        components?.path = "/v1/work"
        components?.query = nil
        components?.fragment = nil
        return components?.url
    }
}
