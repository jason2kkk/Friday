// 功能：用本机系统语音生成有限的中文测试轮次，并验证同一个 Realtime Talk 会话的多轮事件时序。
// 职责：申请一次短期 Talk 凭证，按轮发送 24 kHz PCM16，采集 VAD、用户转写、助手文字/音频、工具和用量事件，输出脱敏诊断报告。
// 边界：这是明确触发的人工联调脚本，不属于自动门禁；它不读取长期 API Key，不模拟真实麦克风声学，也不会执行工具动作。

import Foundation

private struct TalkScenarioCredential: Decodable {
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

private struct ScenarioConfiguration {
    let turnCount: Int
    let reportURL: URL
}

private struct StampedRealtimeEvent {
    let payload: [String: Any]
    let receivedAt: ContinuousClock.Instant
}

private struct TurnReport {
    var index: Int
    var prompt: String
    var audioBytes = 0
    var audioDurationMilliseconds = 0
    var eventCount = 0
    var speechStartedAtMilliseconds: Int?
    var speechStoppedAtMilliseconds: Int?
    var responseStartedAtMilliseconds: Int?
    var firstAudioAtMilliseconds: Int?
    var responseCompletedAtMilliseconds: Int?
    var inputTranscription: String?
    var assistantTranscript = ""
    var assistantAudioBytes = 0
    var responseIDs: [String] = []
    var responseStatuses: [String] = []
    var toolNames: [String] = []
    var errors: [String] = []
    var unexpectedResponseCount = 0
    var usage: [String: Int] = [:]
    var ignoredEventTypes: [String: Int] = [:]

    func jsonObject() -> [String: Any] {
        [
            "turn": index,
            "synthetic_prompt": prompt,
            "audio_bytes": audioBytes,
            "audio_duration_ms": audioDurationMilliseconds,
            "event_count": eventCount,
            "speech_started_at_ms": speechStartedAtMilliseconds as Any,
            "speech_stopped_at_ms": speechStoppedAtMilliseconds as Any,
            "response_started_at_ms": responseStartedAtMilliseconds as Any,
            "first_audio_at_ms": firstAudioAtMilliseconds as Any,
            "response_completed_at_ms": responseCompletedAtMilliseconds as Any,
            "input_transcription": inputTranscription as Any,
            "assistant_transcript": assistantTranscript,
            "assistant_audio_bytes": assistantAudioBytes,
            "response_ids": responseIDs,
            "response_statuses": responseStatuses,
            "tool_names": toolNames,
            "errors": errors,
            "unexpected_response_count": unexpectedResponseCount,
            "usage": usage,
            "ignored_event_types": ignoredEventTypes
        ]
    }
}

private enum ScenarioProbeError: LocalizedError {
    case invalidArguments
    case service(String)
    case invalidCredential
    case timeout(String)
    case synthesisFailed(String)
    case invalidWaveform

    var errorDescription: String? {
        switch self {
        case .invalidArguments:
            return "Usage: RealtimeTalkScenarioProbe [--turns 1-3] [--report /tmp/report.json]"
        case .service(let message):
            return message
        case .invalidCredential:
            return "The local Friday service returned an invalid Talk credential."
        case .timeout(let stage):
            return "Timed out while waiting for \(stage)."
        case .synthesisFailed(let message):
            return "Could not generate synthetic speech: \(message)"
        case .invalidWaveform:
            return "The generated file did not contain a valid mono 24 kHz PCM16 data chunk."
        }
    }
}

@main
private struct RealtimeTalkScenarioProbe {
    private static let packetByteCount = 4_800
    private static let packetDurationMilliseconds = 100
    private static let silencePacketCount = 18
    private static let receiveTimeout: Duration = .seconds(30)
    private static let prompts = [
        "你好，简单介绍一下你自己。",
        "现在请用一句话说明，今天的天气应该怎么查询。",
        "把刚才的回答总结成三个词。"
    ]

    static func main() async {
        do {
            let configuration = try parseArguments()
            let report = try await run(configuration: configuration)
            try writeReport(report, to: configuration.reportURL)
            printReportSummary(report, at: configuration.reportURL)
        } catch {
            FileHandle.standardError.write(
                Data("Talk scenario probe failed: \(error.localizedDescription)\n".utf8)
            )
            Foundation.exit(1)
        }
    }

    private static func parseArguments() throws -> ScenarioConfiguration {
        var turnCount = prompts.count
        var reportURL = URL(fileURLWithPath: "/tmp/friday-talk-scenario-\(timestamp()).json")
        var index = 1

        while index < CommandLine.arguments.count {
            switch CommandLine.arguments[index] {
            case "--turns":
                index += 1
                guard index < CommandLine.arguments.count,
                      let parsed = Int(CommandLine.arguments[index]),
                      (1...prompts.count).contains(parsed) else {
                    throw ScenarioProbeError.invalidArguments
                }
                turnCount = parsed
            case "--report":
                index += 1
                guard index < CommandLine.arguments.count else {
                    throw ScenarioProbeError.invalidArguments
                }
                reportURL = URL(fileURLWithPath: CommandLine.arguments[index])
            default:
                throw ScenarioProbeError.invalidArguments
            }
            index += 1
        }

        return ScenarioConfiguration(turnCount: turnCount, reportURL: reportURL)
    }

    private static func run(configuration: ScenarioConfiguration) async throws -> [String: Any] {
        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("friday-talk-scenario-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: temporaryDirectory,
            withIntermediateDirectories: true
        )

        let credential = try await fetchCredential()
        guard credential.mode == "talk", !credential.value.isEmpty else {
            throw ScenarioProbeError.invalidCredential
        }
        guard var components = URLComponents(string: credential.realtimeURL) else {
            throw ScenarioProbeError.invalidCredential
        }
        if components.queryItems?.contains(where: { $0.name == "model" }) != true {
            var queryItems = components.queryItems ?? []
            queryItems.append(URLQueryItem(name: "model", value: credential.model))
            components.queryItems = queryItems
        }
        guard let socketURL = components.url else {
            throw ScenarioProbeError.invalidCredential
        }

        var request = URLRequest(url: socketURL)
        request.setValue("Bearer \(credential.value)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 15
        let socket = URLSession.shared.webSocketTask(with: request)
        socket.resume()
        defer {
            socket.cancel(with: .normalClosure, reason: nil)
            try? FileManager.default.removeItem(at: temporaryDirectory)
        }

        let eventStream = makeEventStream(for: socket)
        var events = eventStream.makeAsyncIterator()
        let connectionStarted = ContinuousClock.now
        let connectionTimeout = Task {
            try await Task.sleep(for: .seconds(15))
            socket.cancel(with: .goingAway, reason: nil)
        }
        let firstSessionEvent = try await waitForSession(events: &events)
        connectionTimeout.cancel()
        let sessionReadyMilliseconds = elapsedMilliseconds(since: connectionStarted)
        var turnReports: [[String: Any]] = []
        var totalAudioBytes = 0

        for (offset, prompt) in prompts.prefix(configuration.turnCount).enumerated() {
            let pcm = try synthesize(prompt, index: offset + 1, in: temporaryDirectory)
            let report = try await runTurn(
                index: offset + 1,
                prompt: prompt,
                pcm: pcm,
                socket: socket,
                events: &events
            )
            totalAudioBytes += report.assistantAudioBytes
            turnReports.append(report.jsonObject())
        }

        return [
            "probe": "RealtimeTalkScenarioProbe",
            "started_at": ISO8601DateFormatter().string(from: Date()),
            "model": credential.model,
            "session_ready_ms": sessionReadyMilliseconds,
            "session_ready_event": firstSessionEvent,
            "turn_count": turnReports.count,
            "assistant_audio_bytes_total": totalAudioBytes,
            "turns": turnReports,
            "limitations": [
                "Synthetic say/afconvert audio validates the Realtime WebSocket and provider-VAD path, not human microphone acoustics, echo cancellation, or environmental noise.",
                "The report stores synthetic prompts and assistant transcript text because this probe was explicitly requested for reply inspection; it is written outside the repository.",
                "Tool calls are observed but never executed by this script."
            ]
        ]
    }

    private static func runTurn(
        index: Int,
        prompt: String,
        pcm: Data,
        socket: URLSessionWebSocketTask,
        events: inout AsyncThrowingStream<StampedRealtimeEvent, Error>.Iterator
    ) async throws -> TurnReport {
        let started = ContinuousClock.now
        var report = TurnReport(index: index, prompt: prompt)
        report.audioBytes = pcm.count
        report.audioDurationMilliseconds = pcm.count / 48

        var offset = 0
        while offset < pcm.count {
            let end = min(offset + packetByteCount, pcm.count)
            try await sendAudioPacket(Data(pcm[offset..<end]), over: socket)
            offset = end
            try await Task.sleep(for: .milliseconds(packetDurationMilliseconds))
        }
        for _ in 0..<silencePacketCount {
            try await sendAudioPacket(
                Data(repeating: 0, count: packetByteCount),
                over: socket
            )
            try await Task.sleep(for: .milliseconds(packetDurationMilliseconds))
        }

        var responseFinished = false
        let responseTimeout = Task {
            try await Task.sleep(for: receiveTimeout)
            socket.cancel(with: .goingAway, reason: nil)
        }
        defer { responseTimeout.cancel() }
        while !responseFinished, let event = try await events.next() {
            responseFinished = consume(event, report: &report, started: started)
        }
        guard responseFinished else {
            throw ScenarioProbeError.timeout("Realtime response for turn \(index)")
        }

        return report
    }

    @discardableResult
    private static func consume(
        _ stampedEvent: StampedRealtimeEvent,
        report: inout TurnReport,
        started: ContinuousClock.Instant
    ) -> Bool {
        report.eventCount += 1
        let event = stampedEvent.payload
        guard let type = event["type"] as? String else { return false }
        let elapsed = elapsedMilliseconds(from: started, to: stampedEvent.receivedAt)

        switch type {
        case "input_audio_buffer.speech_started":
            report.speechStartedAtMilliseconds = report.speechStartedAtMilliseconds ?? elapsed
        case "input_audio_buffer.speech_stopped":
            report.speechStoppedAtMilliseconds = report.speechStoppedAtMilliseconds ?? elapsed
        case "conversation.item.input_audio_transcription.completed":
            if let transcript = event["transcript"] as? String, !transcript.isEmpty {
                report.inputTranscription = transcript
            }
        case "response.created":
            let response = event["response"] as? [String: Any]
            let responseID = response?["id"] as? String ?? "unknown"
            report.responseIDs.append(responseID)
            report.responseStartedAtMilliseconds = report.responseStartedAtMilliseconds ?? elapsed
            if report.responseIDs.count > 1 {
                report.unexpectedResponseCount += 1
            }
        case "response.output_audio.delta":
            if let encoded = event["delta"] as? String,
               let audio = Data(base64Encoded: encoded) {
                report.assistantAudioBytes += audio.count
                report.firstAudioAtMilliseconds = report.firstAudioAtMilliseconds ?? elapsed
            }
        case "response.output_audio_transcript.delta", "response.output_text.delta":
            if let delta = event["delta"] as? String {
                report.assistantTranscript += delta
            }
        case "response.done":
            let response = event["response"] as? [String: Any]
            let status = response?["status"] as? String ?? "unknown"
            report.responseStatuses.append(status)
            report.responseCompletedAtMilliseconds = report.responseCompletedAtMilliseconds ?? elapsed
            if let usage = response?["usage"] as? [String: Any] {
                report.usage = usageNumbers(usage)
            }
            let output = response?["output"] as? [[String: Any]] ?? []
            for item in output where item["type"] as? String == "function_call" {
                if let name = item["name"] as? String, !name.isEmpty {
                    report.toolNames.append(name)
                }
            }
            return true
        case "error":
            let error = event["error"] as? [String: Any]
            let code = error?["code"] as? String ?? "unknown"
            let message = error?["message"] as? String ?? "Realtime error"
            report.errors.append("\(code): \(message)")
        case "response.cancelled":
            report.responseStatuses.append("cancelled")
        default:
            report.ignoredEventTypes[type, default: 0] += 1
        }
        return false
    }

    private static func fetchCredential() async throws -> TalkScenarioCredential {
        let endpoint = URL(string: "http://127.0.0.1:8787/v1/realtime/client-secret")!
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data(#"{"mode":"talk"}"#.utf8)
        request.timeoutInterval = 15

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse,
              (200..<300).contains(httpResponse.statusCode),
              let credential = try? JSONDecoder().decode(TalkScenarioCredential.self, from: data) else {
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            throw ScenarioProbeError.service(
                object?["error"] as? String ?? "Could not create the Talk scenario credential."
            )
        }
        return credential
    }

    private static func waitForSession(
        events: inout AsyncThrowingStream<StampedRealtimeEvent, Error>.Iterator
    ) async throws -> String {
        while let stampedEvent = try await events.next() {
            let event = stampedEvent.payload
            guard let type = event["type"] as? String else { continue }
            if type == "session.created" || type == "session.updated" {
                return type
            }
            if type == "error" {
                let error = event["error"] as? [String: Any]
                throw ScenarioProbeError.service(
                    error?["message"] as? String ?? "Realtime Talk session failed."
                )
            }
        }
        throw ScenarioProbeError.timeout("Realtime session readiness")
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

    private static func makeEventStream(
        for socket: URLSessionWebSocketTask
    ) -> AsyncThrowingStream<StampedRealtimeEvent, Error> {
        AsyncThrowingStream(bufferingPolicy: .bufferingNewest(512)) { continuation in
            let receiver = Task {
                do {
                    while !Task.isCancelled {
                        let message = try await socket.receive()
                        let event = try decode(message)
                        continuation.yield(
                            StampedRealtimeEvent(
                                payload: event,
                                receivedAt: .now
                            )
                        )
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { @Sendable _ in
                receiver.cancel()
            }
        }
    }

    private static func decode(
        _ message: URLSessionWebSocketTask.Message
    ) throws -> [String: Any] {
        let data: Data
        switch message {
        case .string(let text):
            data = Data(text.utf8)
        case .data(let receivedData):
            data = receivedData
        @unknown default:
            throw ScenarioProbeError.service("Realtime Talk returned an unknown message type.")
        }
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ScenarioProbeError.service("Realtime Talk returned invalid JSON.")
        }
        return object
    }

    private static func synthesize(
        _ prompt: String,
        index: Int,
        in directory: URL
    ) throws -> Data {
        let aiffURL = directory.appendingPathComponent("turn-\(index).aiff")
        let waveURL = directory.appendingPathComponent("turn-\(index).wav")
        try runProcess(
            "/usr/bin/say",
            arguments: ["-v", "Meijia", "-o", aiffURL.path, "--", prompt]
        )
        try runProcess(
            "/usr/bin/afconvert",
            arguments: [
                "-f", "WAVE",
                "-d", "LEI16@24000",
                "-c", "1",
                aiffURL.path,
                waveURL.path
            ]
        )
        let wave = try Data(contentsOf: waveURL)
        return try extractPCM16Data(from: wave)
    }

    private static func runProcess(_ path: String, arguments: [String]) throws {
        let process = Process()
        let errorPipe = Pipe()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        process.standardError = errorPipe
        do {
            try process.run()
        } catch {
            throw ScenarioProbeError.synthesisFailed(error.localizedDescription)
        }
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()
            let message = String(decoding: errorData, as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            throw ScenarioProbeError.synthesisFailed(message.isEmpty ? "process failed" : message)
        }
    }

    private static func extractPCM16Data(from wave: Data) throws -> Data {
        let bytes = [UInt8](wave)
        guard bytes.count >= 12,
              String(decoding: bytes[0..<4], as: UTF8.self) == "RIFF",
              String(decoding: bytes[8..<12], as: UTF8.self) == "WAVE" else {
            throw ScenarioProbeError.invalidWaveform
        }

        var offset = 12
        while offset + 8 <= bytes.count {
            let chunkID = String(decoding: bytes[offset..<(offset + 4)], as: UTF8.self)
            let chunkSize = Int(bytes[offset + 4])
                | (Int(bytes[offset + 5]) << 8)
                | (Int(bytes[offset + 6]) << 16)
                | (Int(bytes[offset + 7]) << 24)
            let dataStart = offset + 8
            let dataEnd = dataStart + chunkSize
            guard dataEnd <= bytes.count else { break }
            if chunkID == "data" {
                let pcm = Data(bytes[dataStart..<dataEnd])
                guard !pcm.isEmpty, pcm.count.isMultiple(of: 2) else {
                    throw ScenarioProbeError.invalidWaveform
                }
                return pcm
            }
            offset = dataEnd + (chunkSize % 2)
        }
        throw ScenarioProbeError.invalidWaveform
    }

    private static func usageNumbers(_ usage: [String: Any]) -> [String: Int] {
        var result: [String: Int] = [:]
        for key in ["total_tokens", "input_tokens", "output_tokens"] {
            if let value = usage[key] as? Int {
                result[key] = value
            }
        }
        if let inputDetails = usage["input_token_details"] as? [String: Any] {
            for key in ["text_tokens", "audio_tokens", "image_tokens"] {
                if let value = inputDetails[key] as? Int {
                    result["input_\(key)"] = value
                }
            }
        }
        if let outputDetails = usage["output_token_details"] as? [String: Any] {
            for key in ["text_tokens", "audio_tokens"] {
                if let value = outputDetails[key] as? Int {
                    result["output_\(key)"] = value
                }
            }
        }
        return result
    }

    private static func writeReport(_ report: [String: Any], to url: URL) throws {
        let directory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        let data = try JSONSerialization.data(
            withJSONObject: report,
            options: [.prettyPrinted, .sortedKeys]
        )
        try data.write(to: url, options: .atomic)
    }

    private static func printReportSummary(_ report: [String: Any], at url: URL) {
        let turns = report["turns"] as? [[String: Any]] ?? []
        print("Talk scenario completed: turns=\(turns.count), report=\(url.path)")
        for turn in turns {
            let index = turn["turn"] as? Int ?? 0
            let responseStart = turn["response_started_at_ms"] as? Int
            let firstAudio = turn["first_audio_at_ms"] as? Int
            let completed = turn["response_completed_at_ms"] as? Int
            let transcript = turn["assistant_transcript"] as? String ?? ""
            let errors = turn["errors"] as? [String] ?? []
            print(
                "turn \(index): response_start=\(responseStart.map(String.init) ?? "-")ms "
                    + "first_audio=\(firstAudio.map(String.init) ?? "-")ms "
                    + "completed=\(completed.map(String.init) ?? "-")ms "
                    + "assistant_audio=\(turn["assistant_audio_bytes"] as? Int ?? 0)B "
                    + "unexpected_responses=\(turn["unexpected_response_count"] as? Int ?? 0)"
            )
            print("turn \(index) assistant transcript: \(transcript.isEmpty ? "<none>" : transcript)")
            if !errors.isEmpty {
                print("turn \(index) errors: \(errors.joined(separator: " | "))")
            }
        }
    }

    private static func elapsedMilliseconds(since start: ContinuousClock.Instant) -> Int {
        elapsedMilliseconds(from: start, to: .now)
    }

    private static func elapsedMilliseconds(
        from start: ContinuousClock.Instant,
        to end: ContinuousClock.Instant
    ) -> Int {
        let duration = start.duration(to: end)
        return Int(duration.components.seconds * 1_000)
            + Int(duration.components.attoseconds / 1_000_000_000_000_000)
    }

    private static func timestamp() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter.string(from: Date())
    }
}
