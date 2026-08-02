// 功能：使用指定的本地 PCM16 音频，人工验证 Realtime Talk 能建立会话并返回可播放的完整音频。
// 职责：向本地服务申请一次 Talk 短期凭证，发送音频、收集服务端事件和回复音频，并输出不含用户正文的诊断结果。
// 边界：脚本不读取长期 API Key、不属于自动门禁；执行时会创建真实 Realtime 会话，必须由开发者明确触发。

import Foundation

private struct TalkProbeCredential: Decodable {
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

private enum TalkProbeError: LocalizedError {
    case missingPCMPath
    case invalidPCM
    case invalidCredential
    case service(String)
    case timeout
    case noAudioResponse

    var errorDescription: String? {
        switch self {
        case .missingPCMPath:
            return "Usage: RealtimeTalkProbe /absolute/path/to/24k-mono-s16le.pcm"
        case .invalidPCM:
            return "The probe input must be non-empty 24 kHz mono PCM16 data."
        case .invalidCredential:
            return "The local Friday service returned an invalid Talk credential."
        case .service(let message):
            return message
        case .timeout:
            return "Timed out waiting for the Realtime Talk response."
        case .noAudioResponse:
            return "Realtime completed without returning assistant audio."
        }
    }
}

@main
private struct RealtimeTalkProbe {
    private static let packetByteCount = 4_800

    static func main() async {
        do {
            try await run()
        } catch {
            FileHandle.standardError.write(
                Data("Talk probe failed: \(error.localizedDescription)\n".utf8)
            )
            Foundation.exit(1)
        }
    }

    private static func run() async throws {
        guard CommandLine.arguments.count == 2 else {
            throw TalkProbeError.missingPCMPath
        }
        let pcm = try Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1]))
        guard !pcm.isEmpty, pcm.count.isMultiple(of: MemoryLayout<Int16>.size) else {
            throw TalkProbeError.invalidPCM
        }

        let credential = try await fetchCredential()
        guard credential.mode == "talk", !credential.value.isEmpty else {
            throw TalkProbeError.invalidCredential
        }

        guard var components = URLComponents(string: credential.realtimeURL) else {
            throw TalkProbeError.invalidCredential
        }
        if components.queryItems?.contains(where: { $0.name == "model" }) != true {
            var queryItems = components.queryItems ?? []
            queryItems.append(URLQueryItem(name: "model", value: credential.model))
            components.queryItems = queryItems
        }
        guard let socketURL = components.url else {
            throw TalkProbeError.invalidCredential
        }

        var request = URLRequest(url: socketURL)
        request.setValue("Bearer \(credential.value)", forHTTPHeaderField: "Authorization")
        let socket = URLSession.shared.webSocketTask(with: request)
        socket.resume()
        defer { socket.cancel(with: .normalClosure, reason: nil) }

        try await waitForSession(on: socket)
        try await sendAudio(pcm, over: socket)

        let silencePacket = Data(repeating: 0, count: packetByteCount)
        for _ in 0..<14 {
            try await sendAudioPacket(silencePacket, over: socket)
            try await Task.sleep(for: .milliseconds(100))
        }

        var responseAudioBytes = 0
        var sawSpeechStart = false
        var sawSpeechStop = false
        var sawCompletedResponse = false

        while !sawCompletedResponse {
            let event = try await receiveJSON(from: socket, timeout: .seconds(25))
            guard let type = event["type"] as? String else { continue }
            switch type {
            case "input_audio_buffer.speech_started":
                sawSpeechStart = true
            case "input_audio_buffer.speech_stopped":
                sawSpeechStop = true
            case "response.output_audio.delta":
                if let encoded = event["delta"] as? String,
                   let audio = Data(base64Encoded: encoded) {
                    responseAudioBytes += audio.count
                }
            case "response.done":
                let response = event["response"] as? [String: Any]
                let status = response?["status"] as? String
                if status == "completed" {
                    sawCompletedResponse = true
                } else {
                    throw TalkProbeError.service("Realtime Talk response status: \(status ?? "unknown")")
                }
            case "error":
                let error = event["error"] as? [String: Any]
                throw TalkProbeError.service(
                    error?["message"] as? String ?? "Realtime Talk returned an error."
                )
            default:
                break
            }
        }

        guard responseAudioBytes > 0 else { throw TalkProbeError.noAudioResponse }
        print(
            "Talk probe passed: speech_started=\(sawSpeechStart), "
                + "speech_stopped=\(sawSpeechStop), assistant_audio_bytes=\(responseAudioBytes)"
        )
    }

    private static func fetchCredential() async throws -> TalkProbeCredential {
        let endpoint = URL(string: "http://127.0.0.1:8787/v1/realtime/client-secret")!
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data(#"{"mode":"talk"}"#.utf8)
        request.timeoutInterval = 15

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse,
              (200..<300).contains(httpResponse.statusCode),
              let credential = try? JSONDecoder().decode(TalkProbeCredential.self, from: data) else {
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            throw TalkProbeError.service(
                object?["error"] as? String ?? "Could not create the Talk probe credential."
            )
        }
        return credential
    }

    private static func waitForSession(on socket: URLSessionWebSocketTask) async throws {
        while true {
            let event = try await receiveJSON(from: socket, timeout: .seconds(15))
            guard let type = event["type"] as? String else { continue }
            if type == "session.created" || type == "session.updated" { return }
            if type == "error" {
                let error = event["error"] as? [String: Any]
                throw TalkProbeError.service(
                    error?["message"] as? String ?? "Realtime Talk session failed."
                )
            }
        }
    }

    private static func sendAudio(
        _ data: Data,
        over socket: URLSessionWebSocketTask
    ) async throws {
        var offset = 0
        while offset < data.count {
            let end = min(offset + packetByteCount, data.count)
            try await sendAudioPacket(Data(data[offset..<end]), over: socket)
            offset = end
            try await Task.sleep(for: .milliseconds(100))
        }
    }

    private static func sendAudioPacket(
        _ packet: Data,
        over socket: URLSessionWebSocketTask
    ) async throws {
        let event: [String: Any] = [
            "type": "input_audio_buffer.append",
            "audio": packet.base64EncodedString()
        ]
        let data = try JSONSerialization.data(withJSONObject: event)
        try await socket.send(.string(String(decoding: data, as: UTF8.self)))
    }

    private static func receiveJSON(
        from socket: URLSessionWebSocketTask,
        timeout: Duration
    ) async throws -> [String: Any] {
        try await withThrowingTaskGroup(of: URLSessionWebSocketTask.Message.self) { group in
            group.addTask {
                try await socket.receive()
            }
            group.addTask {
                try await Task.sleep(for: timeout)
                socket.cancel(with: .goingAway, reason: nil)
                throw TalkProbeError.timeout
            }

            guard let message = try await group.next() else {
                throw TalkProbeError.timeout
            }
            group.cancelAll()

            let data: Data
            switch message {
            case .string(let text):
                data = Data(text.utf8)
            case .data(let receivedData):
                data = receivedData
            @unknown default:
                throw TalkProbeError.service("Realtime Talk returned an unknown message type.")
            }
            guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw TalkProbeError.service("Realtime Talk returned invalid JSON.")
            }
            return object
        }
    }
}
