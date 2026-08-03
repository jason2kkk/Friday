// 功能：通过 OpenAI Realtime WebSocket 实现可持续、可打断并支持用户选区图片上下文的 Talk 会话。
// 职责：从本地服务获取短期凭证，维护 WebSocket 生命周期，发送 PCM16 与图片事件，并解析语音、回复身份、用量、错误和截断事件。
// 边界：不持有长期 API Key、不直接操作 AVAudioEngine 或屏幕捕获，也不决定灵动岛展示和产品级会话状态。

import Foundation
import OSLog

@MainActor
final class RealtimeConversationProvider: ConversationProviding {
    enum ConversationError: LocalizedError {
        case invalidCredentialEndpoint
        case credentialRequestFailed(Int)
        case invalidCredentialResponse
        case sessionAlreadyActive
        case screenContextRejected(String)
        case transport(String)
        case service(String)

        var errorDescription: String? {
            switch self {
            case .invalidCredentialEndpoint:
                return "语音服务地址未配置。"
            case .credentialRequestFailed(let statusCode):
                return "无法创建 Talk 会话（HTTP \(statusCode)）。"
            case .invalidCredentialResponse:
                return "语音服务返回了无效的 Talk 凭证。"
            case .sessionAlreadyActive:
                return "上一段 Friday 对话仍在进行。"
            case .screenContextRejected:
                return "Friday 暂时无法读取所选区域。"
            case .transport:
                return "Friday 语音连接已中断。"
            case .service:
                return "Friday 语音服务暂时不可用。"
            }
        }
    }

    var onEvent: ((ConversationEvent) -> Void)?

    private static let packetByteCount = 4_800
    private let credentialEndpoint: URL?
    private let urlSession: URLSession
    private let logger = Logger(subsystem: "com.example.Friday", category: "RealtimeTalk")

    private var webSocket: URLSessionWebSocketTask?
    private var audioBuffer = Data()
    private var audioContinuation: AsyncStream<Data>.Continuation?
    private var audioSenderTask: Task<Void, Never>?
    private var receiverTask: Task<Void, Never>?
    private var isDisconnecting = false
    private var activeScreenContextItemID: String?
    private var pendingScreenContextConfirmations: [
        String: CheckedContinuation<Void, Error>
    ] = [:]
    private var pendingScreenContextTimeouts: [String: Task<Void, Never>] = [:]
    private var pendingScreenContextEventIDs: [String: String] = [:]

    init(
        credentialEndpoint: URL? = RealtimeConfiguration.credentialEndpoint,
        urlSession: URLSession = .shared
    ) {
        self.credentialEndpoint = credentialEndpoint
        self.urlSession = urlSession
    }

    func connect() async throws {
        guard webSocket == nil else { throw ConversationError.sessionAlreadyActive }
        guard let credentialEndpoint else { throw ConversationError.invalidCredentialEndpoint }

        let credential = try await fetchCredential(from: credentialEndpoint)
        try Task.checkCancellation()
        guard var components = URLComponents(string: credential.realtimeURL) else {
            throw ConversationError.invalidCredentialResponse
        }
        if components.queryItems?.contains(where: { $0.name == "model" }) != true {
            var queryItems = components.queryItems ?? []
            queryItems.append(URLQueryItem(name: "model", value: credential.model))
            components.queryItems = queryItems
        }
        guard let socketURL = components.url else {
            throw ConversationError.invalidCredentialResponse
        }

        var request = URLRequest(url: socketURL)
        request.setValue("Bearer \(credential.value)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 15

        let socket = urlSession.webSocketTask(with: request)
        isDisconnecting = false
        webSocket = socket
        audioBuffer.removeAll(keepingCapacity: true)
        activeScreenContextItemID = nil
        socket.resume()
        if Task.isCancelled {
            socket.cancel(with: .goingAway, reason: nil)
            webSocket = nil
            throw CancellationError()
        }
        startAudioSender(for: socket)
        startReceiver(for: socket)
        logger.info("Realtime Talk session started for model \(credential.model, privacy: .public)")
    }

    func append(_ chunk: AudioChunk) {
        guard webSocket != nil,
              chunk.sampleRate == 24_000,
              chunk.channelCount == 1 else { return }

        audioBuffer.append(chunk.pcm16)
        while audioBuffer.count >= Self.packetByteCount {
            let packet = Data(audioBuffer.prefix(Self.packetByteCount))
            audioBuffer.removeFirst(Self.packetByteCount)
            audioContinuation?.yield(packet)
        }
    }

    func setScreenContext(_ image: ConversationImage) async throws {
        guard let socket = webSocket else {
            throw ConversationError.transport("Talk session is not connected.")
        }

        let previousScreenContextItemID = activeScreenContextItemID

        let itemID = Self.makeScreenContextItemID()
        let eventID = "ev_scr_\(String(UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(24)))"
        let payload: [String: Any] = [
            "event_id": eventID,
            "type": "conversation.item.create",
            "item": [
                "id": itemID,
                "type": "message",
                "role": "user",
                "content": [
                    [
                        "type": "input_image",
                        "image_url": image.dataURL,
                        "detail": "high"
                    ]
                ]
            ]
        ]
        try await withCheckedThrowingContinuation { continuation in
            pendingScreenContextConfirmations[itemID] = continuation
            pendingScreenContextEventIDs[itemID] = eventID
            pendingScreenContextTimeouts[itemID] = Task { [weak self] in
                try? await Task.sleep(for: .seconds(5))
                guard !Task.isCancelled else { return }
                self?.completeScreenContextConfirmation(
                    itemID: itemID,
                    error: ConversationError.transport(
                        "Timed out waiting for screen context confirmation."
                    )
                )
            }
            Task { [weak self] in
                guard let self else { return }
                do {
                    try await sendJSON(payload, over: socket)
                } catch {
                    completeScreenContextConfirmation(itemID: itemID, error: error)
                }
            }
        }
        activeScreenContextItemID = itemID
        if let previousScreenContextItemID {
            do {
                try await sendJSON(
                    [
                        "type": "conversation.item.delete",
                        "item_id": previousScreenContextItemID
                    ],
                    over: socket
                )
            } catch {
                logger.warning("Unable to remove the previous selected screen context")
            }
        }
        logger.info(
            "Attached selected screen context width=\(image.pixelWidth, privacy: .public) height=\(image.pixelHeight, privacy: .public)"
        )
    }

    func requestUserResponse() async throws {
        guard let socket = webSocket else {
            throw ConversationError.transport("Talk session is not connected.")
        }
        try await sendJSON(["type": "response.create"], over: socket)
    }

    func discardUserAudioItem(_ itemID: ConversationProviderItemID) {
        guard let socket = webSocket else { return }
        Task { [weak self] in
            do {
                try await self?.sendJSON(
                    [
                        "type": "conversation.item.delete",
                        "item_id": itemID.rawValue
                    ],
                    over: socket
                )
            } catch {
                guard self?.isDisconnecting == false else { return }
                self?.logger.warning("Unable to discard a suppressed user audio item")
            }
        }
    }

    func requestOpeningGreeting() {
        guard let socket = webSocket else { return }
        Task { [weak self] in
            do {
                try await self?.sendJSON(
                    [
                        "type": "response.create",
                        "response": [
                            "instructions": ConversationPrompt.openingGreeting,
                            "output_modalities": ["audio"],
                            "max_output_tokens": ConversationLimits.openingGreetingMaximumTokens
                        ]
                    ],
                    over: socket
                )
            } catch {
                guard self?.isDisconnecting == false else { return }
                self?.onEvent?(.failed("Friday 暂时无法开始这次问候。"))
            }
        }
    }

    func provideToolOutput(
        callID: ConversationToolCallID,
        output: String,
        createsResponse: Bool
    ) async throws {
        guard let socket = webSocket else {
            throw ConversationError.transport("Talk session is not connected.")
        }
        try await sendJSON(
            [
                "type": "conversation.item.create",
                "item": [
                    "type": "function_call_output",
                    "call_id": callID.rawValue,
                    "output": output
                ]
            ],
            over: socket
        )
        guard createsResponse else { return }
        try await sendJSON(
            [
                "type": "response.create",
                "response": [
                    "instructions": ConversationPrompt.toolFollowUp,
                    "output_modalities": ["audio"],
                    "tool_choice": "none",
                    "max_output_tokens": ConversationLimits.toolFollowUpMaximumTokens
                ]
            ],
            over: socket
        )
    }

    func presentCompletedWork(_ result: String) async throws {
        guard let socket = webSocket else {
            throw ConversationError.transport("Talk session is not connected.")
        }
        let boundedResult = String(result.prefix(4_000))
        try await sendJSON(
            [
                "type": "response.create",
                "response": [
                    "instructions": ConversationPrompt.completedWork(boundedResult),
                    "output_modalities": ["audio"],
                    "tool_choice": "none",
                    "max_output_tokens": ConversationLimits.workResultMaximumTokens
                ]
            ],
            over: socket
        )
    }

    func cancelAssistantResponse() {
        guard let socket = webSocket else { return }
        Task { [weak self] in
            try? await self?.sendJSON(["type": "response.cancel"], over: socket)
        }
    }

    func truncateAssistantResponse(
        itemID: ConversationProviderItemID,
        audioEndMilliseconds: Int
    ) {
        guard let socket = webSocket else { return }
        let safeMilliseconds = max(0, audioEndMilliseconds)
        Task { [weak self] in
            do {
                try await self?.sendJSON(
                    [
                        "type": "conversation.item.truncate",
                        "item_id": itemID.rawValue,
                        "content_index": 0,
                        "audio_end_ms": safeMilliseconds
                    ],
                    over: socket
                )
            } catch {
                self?.onEvent?(.failed("无法同步用户插话，请重新说一遍。"))
            }
        }
    }

    func disconnect() {
        isDisconnecting = true
        failPendingScreenContextConfirmations(
            ConversationError.transport("Talk session ended before screen context was confirmed.")
        )
        if !audioBuffer.isEmpty {
            audioContinuation?.yield(audioBuffer)
        }
        audioBuffer.removeAll(keepingCapacity: false)
        audioContinuation?.finish()
        audioContinuation = nil
        audioSenderTask?.cancel()
        audioSenderTask = nil
        receiverTask?.cancel()
        receiverTask = nil
        webSocket?.cancel(with: .normalClosure, reason: nil)
        webSocket = nil
        activeScreenContextItemID = nil
        logger.info("Realtime Talk session disconnected")
    }

    private func fetchCredential(from endpoint: URL) async throws -> TalkClientCredential {
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 15
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["mode": "talk"])

        let (data, response) = try await urlSession.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw ConversationError.invalidCredentialResponse
        }
        guard (200..<300).contains(httpResponse.statusCode) else {
            let serviceMessage = (try? JSONDecoder().decode(
                TalkCredentialServiceError.self,
                from: data
            ))?.error
            if let serviceMessage, !serviceMessage.isEmpty {
                throw ConversationError.service(serviceMessage)
            }
            throw ConversationError.credentialRequestFailed(httpResponse.statusCode)
        }

        guard let credential = try? JSONDecoder().decode(TalkClientCredential.self, from: data),
              !credential.value.isEmpty,
              !credential.model.isEmpty,
              credential.mode == "talk" else {
            throw ConversationError.invalidCredentialResponse
        }
        return credential
    }

    private func startAudioSender(for socket: URLSessionWebSocketTask) {
        var continuation: AsyncStream<Data>.Continuation?
        let stream = AsyncStream<Data> { continuation = $0 }
        audioContinuation = continuation
        audioSenderTask = Task { [weak self] in
            do {
                for await packet in stream {
                    guard !Task.isCancelled else { return }
                    try await self?.sendJSON(
                        [
                            "type": "input_audio_buffer.append",
                            "audio": packet.base64EncodedString()
                        ],
                        over: socket
                    )
                }
            } catch {
                guard self?.isDisconnecting == false else { return }
                self?.onEvent?(.failed("Friday 无法继续发送麦克风音频。"))
            }
        }
    }

    private func startReceiver(for socket: URLSessionWebSocketTask) {
        receiverTask = Task { [weak self] in
            guard let self else { return }
            var parser = ConversationEventParser()

            while !Task.isCancelled {
                do {
                    let message = try await socket.receive()
                    let data: Data
                    switch message {
                    case .string(let text):
                        data = Data(text.utf8)
                    case .data(let receivedData):
                        data = receivedData
                    @unknown default:
                        continue
                    }

                    guard let object = try JSONSerialization.jsonObject(with: data)
                        as? [String: Any] else { continue }
                    if handlePendingScreenContextEvent(object) {
                        continue
                    }
                    for event in parser.consume(object) {
                        onEvent?(event)
                    }
                } catch {
                    guard !Task.isCancelled, !isDisconnecting else { return }
                    onEvent?(.failed("Friday 语音连接已中断。"))
                    return
                }
            }
        }
    }

    private func sendJSON(
        _ object: [String: Any],
        over socket: URLSessionWebSocketTask
    ) async throws {
        let data = try JSONSerialization.data(withJSONObject: object)
        guard let text = String(data: data, encoding: .utf8) else {
            throw ConversationError.transport("Could not encode Talk event.")
        }
        try await socket.send(.string(text))
    }

    static func makeScreenContextItemID() -> String {
        let suffix = UUID().uuidString
            .replacingOccurrences(of: "-", with: "")
            .prefix(20)
        return "scr_\(suffix)"
    }

    private func handlePendingScreenContextEvent(_ event: [String: Any]) -> Bool {
        guard let type = event["type"] as? String else { return false }
        switch type {
        case "conversation.item.added", "conversation.item.done":
            guard let item = event["item"] as? [String: Any],
                  let itemID = item["id"] as? String,
                  pendingScreenContextConfirmations[itemID] != nil else { return false }
            completeScreenContextConfirmation(itemID: itemID, error: nil)
            return true
        case "error":
            let error = event["error"] as? [String: Any]
            let rejectedEventID = error?["event_id"] as? String
            let message = error?["message"] as? String
                ?? "Realtime rejected the selected screen context."
            guard let itemID = pendingScreenContextEventIDs.first(where: {
                $0.value == rejectedEventID || message.contains($0.key)
            })?.key else { return false }
            completeScreenContextConfirmation(
                itemID: itemID,
                error: ConversationError.screenContextRejected(message)
            )
            return true
        default:
            return false
        }
    }

    private func failPendingScreenContextConfirmations(_ error: Error) {
        let pending = pendingScreenContextConfirmations
        pendingScreenContextConfirmations.removeAll(keepingCapacity: false)
        pendingScreenContextEventIDs.removeAll(keepingCapacity: false)
        let timeouts = pendingScreenContextTimeouts
        pendingScreenContextTimeouts.removeAll(keepingCapacity: false)
        timeouts.values.forEach { $0.cancel() }
        for continuation in pending.values {
            continuation.resume(throwing: error)
        }
    }

    private func completeScreenContextConfirmation(itemID: String, error: Error?) {
        guard let continuation = pendingScreenContextConfirmations.removeValue(
            forKey: itemID
        ) else { return }
        pendingScreenContextTimeouts.removeValue(forKey: itemID)?.cancel()
        pendingScreenContextEventIDs.removeValue(forKey: itemID)
        if let error {
            continuation.resume(throwing: error)
        } else {
            continuation.resume()
        }
    }
}

struct ConversationEventParser {
    mutating func consume(_ event: [String: Any]) -> [ConversationEvent] {
        guard let type = event["type"] as? String else { return [] }

        switch type {
        case "session.created", "session.updated":
            return [.sessionReady]
        case "input_audio_buffer.speech_started":
            return [
                .userSpeechStarted(
                    itemID: ConversationProviderItemID(event["item_id"] as? String)
                )
            ]
        case "input_audio_buffer.speech_stopped":
            return [
                .userSpeechStopped(
                    itemID: ConversationProviderItemID(event["item_id"] as? String)
                )
            ]
        case "conversation.item.input_audio_transcription.completed":
            guard let itemID = ConversationProviderItemID(event["item_id"] as? String),
                  let transcript = event["transcript"] as? String else { return [] }
            return [
                .userTranscriptionCompleted(
                    ConversationInputTranscription(
                        itemID: itemID,
                        text: transcript,
                        language: extractLanguage(from: event),
                        confidence: nil,
                        usage: extractTranscriptionUsage(from: event)
                    )
                )
            ]
        case "conversation.item.input_audio_transcription.failed":
            guard let itemID = ConversationProviderItemID(
                event["item_id"] as? String
            ) else { return [] }
            let error = event["error"] as? [String: Any]
            return [
                .userTranscriptionFailed(
                    ConversationInputTranscriptionFailure(
                        itemID: itemID,
                        code: error?["code"] as? String
                    )
                )
            ]
        case "response.created":
            let response = event["response"] as? [String: Any]
            return [
                .assistantResponseStarted(
                    responseID: ConversationProviderResponseID(response?["id"] as? String)
                )
            ]
        case "response.output_item.added":
            guard let item = event["item"] as? [String: Any],
                  let itemID = ConversationProviderItemID(item["id"] as? String) else { return [] }
            guard item["type"] as? String != "function_call" else { return [] }
            return [
                .assistantItemStarted(
                    ConversationProviderEventIdentity(
                        responseID: ConversationProviderResponseID(
                            event["response_id"] as? String
                        ),
                        itemID: itemID
                    )
                )
            ]
        case "response.output_audio.delta":
            guard let encodedAudio = event["delta"] as? String,
                  let audio = Data(base64Encoded: encodedAudio),
                  !audio.isEmpty else { return [] }
            return [
                .assistantAudio(
                    identity: providerIdentity(from: event),
                    data: audio
                )
            ]
        case "response.output_audio.done":
            return [.assistantAudioFinished(providerIdentity(from: event))]
        case "response.output_audio_transcript.delta":
            guard let delta = event["delta"] as? String, !delta.isEmpty else { return [] }
            return [
                .assistantTranscriptDelta(
                    identity: providerIdentity(from: event),
                    delta: delta
                )
            ]
        case "response.cancelled":
            return [
                .responseCancelled(
                    responseID: ConversationProviderResponseID(event["response_id"] as? String)
                )
            ]
        case "response.done":
            guard let response = event["response"] as? [String: Any] else { return [] }
            let responseID = ConversationProviderResponseID(response["id"] as? String)
            if let status = response["status"] as? String, status == "cancelled" {
                return [.responseCancelled(responseID: responseID)]
            }
            if let status = response["status"] as? String, status != "completed" {
                let details = response["status_details"] as? [String: Any]
                let reason = details?["reason"] as? String
                if reason == "max_output_tokens" {
                    return [
                        .responseCompleted(
                            responseID: responseID,
                            usage: extractUsage(from: response)
                        )
                    ]
                }
                let responseError = details?["error"] as? [String: Any]
                let message = responseError?["message"] as? String
                    ?? reason
                    ?? "Friday 没有完成这次回复。"
                if Self.isCancellationWithoutActiveResponse(
                    code: responseError?["code"] as? String,
                    message: message
                ) {
                    return [
                        .assistantCancellationIgnored(
                            code: responseError?["code"] as? String
                        )
                    ]
                }
                return [.failed(message)]
            }
            return extractToolCalls(from: response, responseID: responseID) + [
                .responseCompleted(
                    responseID: responseID,
                    usage: extractUsage(from: response)
                )
            ]
        case "error":
            let error = event["error"] as? [String: Any]
            let code = error?["code"] as? String
            let message = error?["message"] as? String
                ?? "Friday 语音服务返回错误。"
            if Self.isCancellationWithoutActiveResponse(
                code: code,
                message: message
            ) {
                return [.assistantCancellationIgnored(code: code)]
            }
            return [.failed(message)]
        default:
            return []
        }
    }

    private static func isCancellationWithoutActiveResponse(
        code: String?,
        message: String
    ) -> Bool {
        if code?.lowercased() == "response_cancel_not_active" {
            return true
        }
        return message.localizedCaseInsensitiveContains(
            "no active response found"
        )
    }

    private func providerIdentity(
        from event: [String: Any]
    ) -> ConversationProviderEventIdentity {
        ConversationProviderEventIdentity(
            responseID: ConversationProviderResponseID(event["response_id"] as? String),
            itemID: ConversationProviderItemID(event["item_id"] as? String)
        )
    }

    private func extractToolCalls(
        from response: [String: Any],
        responseID: ConversationProviderResponseID?
    ) -> [ConversationEvent] {
        let output = response["output"] as? [[String: Any]] ?? []
        return output.compactMap { item in
            guard item["type"] as? String == "function_call",
                  let callID = ConversationToolCallID(item["call_id"] as? String),
                  let name = item["name"] as? String,
                  !name.isEmpty,
                  let arguments = item["arguments"] as? String else { return nil }
            return .toolCall(
                ConversationToolCall(
                    callID: callID,
                    name: name,
                    argumentsJSON: arguments,
                    responseID: responseID
                )
            )
        }
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
            outputAudioTokens: outputDetails?["audio_tokens"] as? Int ?? 0,
            totalTokens: usage["total_tokens"] as? Int ?? 0
        )
    }

    private func extractLanguage(from event: [String: Any]) -> String? {
        let languages = event["languages"] as? [[String: Any]]
        return languages?.compactMap { $0["code"] as? String }.first
    }

    private func extractTranscriptionUsage(
        from event: [String: Any]
    ) -> UserTurnTranscriptionUsage? {
        guard let usage = event["usage"] as? [String: Any] else { return nil }
        switch usage["type"] as? String {
        case "tokens":
            return UserTurnTranscriptionUsage(
                inputTokens: usage["input_tokens"] as? Int,
                outputTokens: usage["output_tokens"] as? Int,
                totalTokens: usage["total_tokens"] as? Int,
                audioSeconds: nil
            )
        case "duration":
            return UserTurnTranscriptionUsage(
                inputTokens: nil,
                outputTokens: nil,
                totalTokens: nil,
                audioSeconds: usage["seconds"] as? Double
            )
        default:
            return nil
        }
    }
}

private struct TalkClientCredential: Decodable {
    let value: String
    let model: String
    let realtimeURL: String
    let mode: String

    enum CodingKeys: String, CodingKey {
        case value
        case model
        case realtimeURL = "realtime_url"
        case mode
    }
}

private struct TalkCredentialServiceError: Decodable {
    let error: String
}
