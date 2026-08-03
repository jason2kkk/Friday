// 功能：把 Talk Coordinator 的状态、身份和安全提示转换为不含对话内容的诊断字段。
// 职责：构建 Session/Turn/Response/Playback 关联上下文，并统一状态名、启动错误和 Provider 提示的安全映射。
// 边界：不写文件、不读取对话文本、不控制 Provider 或界面，实际持久化由 ConversationDiagnosticsRecording 完成。

import Foundation

struct ConversationTurnDiagnosticTimeline {
    private struct Milestones {
        var userSpeechStartedAt: ContinuousClock.Instant?
        var userSpeechStoppedAt: ContinuousClock.Instant?
        var responseRequestedAt: ContinuousClock.Instant?
        var responseStartedAt: ContinuousClock.Instant?
        var assistantItemStartedAt: ContinuousClock.Instant?
        var playbackStartedAt: ContinuousClock.Instant?
        var providerAudioFinishedAt: ContinuousClock.Instant?
    }

    private let clock = ContinuousClock()
    private var milestonesByTurn: [ConversationTurnID: Milestones] = [:]
    private var toolCallStartedAt: [ConversationToolCallID: ContinuousClock.Instant] = [:]
    private var lastLocalVoiceActivityAt: ContinuousClock.Instant?
    private var lastPlaybackFinishedAt: ContinuousClock.Instant?

    mutating func reset() {
        milestonesByTurn.removeAll(keepingCapacity: false)
        toolCallStartedAt.removeAll(keepingCapacity: false)
        lastLocalVoiceActivityAt = nil
        lastPlaybackFinishedAt = nil
    }

    mutating func recordLocalVoiceActivity() {
        lastLocalVoiceActivityAt = clock.now
    }

    mutating func recordUserSpeechStarted(
        turnID: ConversationTurnID
    ) -> [String: String] {
        let now = clock.now
        var milestones = milestonesByTurn[turnID] ?? Milestones()
        milestones.userSpeechStartedAt = now
        milestonesByTurn[turnID] = milestones
        return attributes(
            ("since_playback_finished_ms", duration(from: lastPlaybackFinishedAt, to: now))
        )
    }

    mutating func recordUserSpeechStopped(
        turnID: ConversationTurnID
    ) -> [String: String] {
        let now = clock.now
        var milestones = milestonesByTurn[turnID] ?? Milestones()
        milestones.userSpeechStoppedAt = now
        milestonesByTurn[turnID] = milestones
        return attributes(
            ("provider_speech_duration_ms", duration(from: milestones.userSpeechStartedAt, to: now)),
            ("local_silence_before_endpoint_ms", duration(from: lastLocalVoiceActivityAt, to: now))
        )
    }

    mutating func recordResponseRequested(
        turnID: ConversationTurnID
    ) -> [String: String] {
        let now = clock.now
        var milestones = milestonesByTurn[turnID] ?? Milestones()
        milestones.responseRequestedAt = now
        milestonesByTurn[turnID] = milestones
        return attributes(
            ("endpoint_to_request_ms", duration(from: milestones.userSpeechStoppedAt, to: now)),
            ("local_silence_to_request_ms", duration(from: lastLocalVoiceActivityAt, to: now))
        )
    }

    mutating func recordResponseStarted(
        turnID: ConversationTurnID
    ) -> [String: String] {
        let now = clock.now
        var milestones = milestonesByTurn[turnID] ?? Milestones()
        milestones.responseStartedAt = now
        milestonesByTurn[turnID] = milestones
        return attributes(
            ("request_to_response_ms", duration(from: milestones.responseRequestedAt, to: now)),
            ("endpoint_to_response_ms", duration(from: milestones.userSpeechStoppedAt, to: now))
        )
    }

    mutating func recordAssistantItemStarted(
        turnID: ConversationTurnID
    ) -> [String: String] {
        let now = clock.now
        var milestones = milestonesByTurn[turnID] ?? Milestones()
        milestones.assistantItemStartedAt = now
        milestonesByTurn[turnID] = milestones
        return attributes(
            ("response_to_item_ms", duration(from: milestones.responseStartedAt, to: now))
        )
    }

    mutating func recordPlaybackStarted(
        turnID: ConversationTurnID
    ) -> [String: String] {
        let now = clock.now
        var milestones = milestonesByTurn[turnID] ?? Milestones()
        milestones.playbackStartedAt = now
        milestonesByTurn[turnID] = milestones
        return attributes(
            ("endpoint_to_first_audio_ms", duration(from: milestones.userSpeechStoppedAt, to: now)),
            ("request_to_first_audio_ms", duration(from: milestones.responseRequestedAt, to: now)),
            ("response_to_first_audio_ms", duration(from: milestones.responseStartedAt, to: now)),
            ("item_to_first_audio_ms", duration(from: milestones.assistantItemStartedAt, to: now)),
            ("local_silence_to_first_audio_ms", duration(from: lastLocalVoiceActivityAt, to: now))
        )
    }

    mutating func recordProviderAudioFinished(
        turnID: ConversationTurnID
    ) -> [String: String] {
        let now = clock.now
        var milestones = milestonesByTurn[turnID] ?? Milestones()
        milestones.providerAudioFinishedAt = now
        milestonesByTurn[turnID] = milestones
        return attributes(
            ("provider_audio_stream_ms", duration(from: milestones.playbackStartedAt, to: now))
        )
    }

    func responseCompleted(turnID: ConversationTurnID) -> [String: String] {
        let now = clock.now
        let milestones = milestonesByTurn[turnID]
        return attributes(
            ("response_generation_ms", duration(from: milestones?.responseStartedAt, to: now)),
            ("request_to_completion_ms", duration(from: milestones?.responseRequestedAt, to: now))
        )
    }

    mutating func recordPlaybackFinished(
        turnID: ConversationTurnID
    ) -> [String: String] {
        let now = clock.now
        let milestones = milestonesByTurn[turnID]
        lastPlaybackFinishedAt = now
        return attributes(
            ("playback_duration_ms", duration(from: milestones?.playbackStartedAt, to: now)),
            ("endpoint_to_playback_end_ms", duration(from: milestones?.userSpeechStoppedAt, to: now)),
            ("provider_audio_done_to_playback_end_ms", duration(from: milestones?.providerAudioFinishedAt, to: now))
        )
    }

    mutating func recordToolCall(_ callID: ConversationToolCallID) {
        toolCallStartedAt[callID] = clock.now
    }

    mutating func recordToolResolution(
        _ callID: ConversationToolCallID
    ) -> [String: String] {
        let startedAt = toolCallStartedAt.removeValue(forKey: callID)
        return attributes(
            ("tool_resolution_ms", duration(from: startedAt, to: clock.now))
        )
    }

    private func duration(
        from start: ContinuousClock.Instant?,
        to end: ContinuousClock.Instant
    ) -> Int? {
        guard let start else { return nil }
        let components = start.duration(to: end).components
        let seconds = Double(components.seconds)
            + Double(components.attoseconds) / 1_000_000_000_000_000_000
        return Int(max(0, seconds) * 1_000)
    }

    private func attributes(
        _ values: (String, Int?)...
    ) -> [String: String] {
        Dictionary(uniqueKeysWithValues: values.compactMap { entry in
            let (key, value) = entry
            return value.map { (key, String($0)) }
        })
    }
}

@MainActor
extension ConversationCoordinator {
    func recordDiagnostic(
        _ event: String,
        turn: ConversationTurnCorrelationSnapshot? = nil,
        providerUserItemID: ConversationProviderItemID? = nil,
        providerResponseID: ConversationProviderResponseID? = nil,
        providerAssistantItemID: ConversationProviderItemID? = nil,
        attributes: [String: String] = [:]
    ) {
        let turn = turn ?? turnCorrelator.activeTurn
        let context = ConversationDiagnosticContext(
            turnID: turn?.turnID.description,
            responseID: turn?.responseID?.description,
            assistantItemID: turn?.assistantItemID?.description,
            playbackID: turn?.playbackID?.description,
            providerUserItemID: providerUserItemID?.description
                ?? turn?.providerUserItemID?.description,
            providerResponseID: providerResponseID?.description
                ?? turn?.providerResponseID?.description,
            providerAssistantItemID: providerAssistantItemID?.description
                ?? turn?.providerAssistantItemID?.description
        )
        diagnostics.record(
            event,
            state: state.diagnosticName,
            context: context,
            attributes: attributes
        )
    }

    func userFacingMessage(for error: Error) -> String {
        if let conversationError = error as? RealtimeConversationProvider.ConversationError {
            return conversationError.localizedDescription
        }
        if let audioError = error as? ConversationAudioService.AudioError {
            return audioError.localizedDescription
        }
        if error is URLError {
            return "Friday 语音服务未连接"
        }
        return "Friday 暂时无法开始语音对话"
    }

    func sanitizedServiceMessage(_ message: String) -> String {
        let lowercased = message.lowercased()
        if lowercased.contains("api key") || lowercased.contains("bearer") {
            return "Friday 语音服务配置不可用"
        }
        return message.isEmpty ? "Friday 语音服务暂时不可用" : message
    }
}

extension ConversationState {
    var diagnosticName: String {
        switch self {
        case .dormant:
            return "dormant"
        case .requestingPermission:
            return "requesting_permission"
        case .waitingForWakeWord:
            return "waiting_for_wake_word"
        case .connecting:
            return "connecting"
        case .listening:
            return "listening"
        case .userSpeaking:
            return "user_speaking"
        case .selectingScreenRegion:
            return "selecting_screen_region"
        case .capturingScreenRegion:
            return "capturing_screen_region"
        case .assistantPreparing:
            return "assistant_preparing"
        case .assistantSpeaking:
            return "assistant_speaking"
        case .ending:
            return "ending"
        case .unavailable:
            return "unavailable"
        }
    }
}

extension ConversationTurnSource {
    var diagnosticName: String {
        switch self {
        case .userSpeech:
            return "user_speech"
        case .openingGreeting:
            return "opening_greeting"
        case .providerInitiated:
            return "provider_initiated"
        }
    }
}

func diagnosticToolStatus(from output: String) -> String {
    guard let data = output.data(using: .utf8),
          let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let status = object["status"] as? String,
          status.range(of: #"^[a-z_]{1,40}$"#, options: .regularExpression) != nil else {
        return "unknown"
    }
    return status
}
