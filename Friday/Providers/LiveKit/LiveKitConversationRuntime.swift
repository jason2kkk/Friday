// 功能：定义 LiveKit 作为 Friday 候选 Talk Runtime 时的零费用 Stage 0 适配边界。
// 职责：校验短期 Room 凭证与禁用录制配置，映射 Transport 事件，并以单一 Runtime 独占音频、Provider 和 RPC 生命周期。
// 边界：不包含 LiveKit SDK 或云连接实现，不创建 Room、Realtime 凭证或付费响应，也不执行收到的 ActionProposal。

import Foundation

enum LiveKitStageZeroError: LocalizedError {
    case invalidServerURL
    case missingRoomToken
    case recordingMustBeDisabled
    case missingModel

    var errorDescription: String? {
        switch self {
        case .invalidServerURL:
            return "LiveKit Room 地址无效。"
        case .missingRoomToken:
            return "LiveKit 短期 Room Token 缺失。"
        case .recordingMustBeDisabled:
            return "Friday 的 LiveKit 会话必须明确关闭录制。"
        case .missingModel:
            return "LiveKit Realtime 模型未配置。"
        }
    }
}

struct LiveKitRoomCredential: Sendable, CustomStringConvertible {
    let serverURL: URL
    let token: String

    init(serverURL: URL, token: String) throws {
        guard let scheme = serverURL.scheme?.lowercased(),
              scheme == "wss" || scheme == "https" else {
            throw LiveKitStageZeroError.invalidServerURL
        }
        guard !token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw LiveKitStageZeroError.missingRoomToken
        }
        self.serverURL = serverURL
        self.token = token
    }

    var description: String {
        "LiveKitRoomCredential(serverURL: \(serverURL.absoluteString), token: <redacted>)"
    }
}

struct LiveKitConversationSessionConfiguration: Equatable, Sendable {
    let recordSession: Bool
    let model: String
    let voice: String
    let reasoningEffort: String
    let adaptiveInterruptionEnabled: Bool

    init(
        recordSession: Bool,
        model: String = "gpt-realtime-2.1",
        voice: String = "marin",
        reasoningEffort: String = "low",
        adaptiveInterruptionEnabled: Bool = true
    ) throws {
        guard recordSession == false else {
            throw LiveKitStageZeroError.recordingMustBeDisabled
        }
        guard !model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw LiveKitStageZeroError.missingModel
        }
        self.recordSession = recordSession
        self.model = model
        self.voice = voice
        self.reasoningEffort = reasoningEffort
        self.adaptiveInterruptionEnabled = adaptiveInterruptionEnabled
    }

    var openAIPluginArguments: [String: String] {
        [
            "model": model,
            "voice": voice,
            "reasoning_effort": reasoningEffort
        ]
    }
}

@MainActor
protocol LiveKitRoomCredentialProviding: AnyObject {
    func fetchRoomCredential() async throws -> LiveKitRoomCredential
}

enum LiveKitConversationTransportEvent: Equatable {
    case connected
    case userSpeechStarted(itemID: ConversationProviderItemID?)
    case userSpeechStopped(itemID: ConversationProviderItemID?)
    case userTranscriptionCompleted(ConversationInputTranscription)
    case userTranscriptionFailed(ConversationInputTranscriptionFailure)
    case assistantResponseStarted(responseID: ConversationProviderResponseID?)
    case assistantItemStarted(ConversationProviderEventIdentity)
    case assistantPlaybackStarted(ConversationProviderEventIdentity)
    case toolCall(ConversationToolCall)
    case responseCompleted(responseID: ConversationProviderResponseID?, usage: DictationUsage)
    case responseCancelled(responseID: ConversationProviderResponseID?)
    case failed(String)
}

@MainActor
protocol LiveKitConversationTransporting: AnyObject {
    var onEvent: ((LiveKitConversationTransportEvent) -> Void)? { get set }
    var onInputLevels: ((ConversationAudioLevels) -> Void)? { get set }
    var onOutputLevels: ((ConversationAudioLevels) -> Void)? { get set }
    var onPlaybackFinished: (() -> Void)? { get set }
    var onActionProposalData: ((Data) -> Void)? { get set }
    var onFailure: ((Error) -> Void)? { get set }
    var isRunning: Bool { get }
    var hasConfirmedInterruption: Bool { get }

    func start(
        credential: LiveKitRoomCredential,
        configuration: LiveKitConversationSessionConfiguration
    ) async throws
    func setScreenContext(_ image: ConversationImage) async throws
    func requestUserResponse() async throws
    func discardUserAudioItem(_ itemID: ConversationProviderItemID)
    func requestOpeningGreeting()
    func provideToolOutput(
        callID: ConversationToolCallID,
        output: String,
        createsResponse: Bool
    ) async throws
    func presentCompletedWork(_ result: String) async throws
    func cancelAssistantResponse()
    func truncateAssistantResponse(
        itemID: ConversationProviderItemID,
        audioEndMilliseconds: Int
    )
    func stopAssistantPlayback() -> Int
    func sendActionReceiptData(_ data: Data) async throws
    func stop()
}

@MainActor
final class LiveKitConversationRuntimeSession:
    ConversationRuntimeSession,
    ConversationProviding,
    ConversationAudioServicing
{
    let descriptor = ConversationRuntimeDescriptor(
        kind: .liveKitStageZero,
        audioOwner: .conversationRuntime,
        recordingPolicy: .disabled
    )

    var conversationProvider: any ConversationProviding { self }
    var audioService: any ConversationAudioServicing { self }

    var onEvent: ((ConversationEvent) -> Void)?
    var onInputChunk: ((AudioChunk) -> Void)?
    var onInputLevels: ((ConversationAudioLevels) -> Void)?
    var onInputGateTransition: ((ConversationInputGateTransition) -> Void)?
    var onOutputLevels: ((ConversationAudioLevels) -> Void)?
    var onPlaybackFinished: (() -> Void)?
    var onFailure: ((Error) -> Void)?
    var onActionProposal: ((ActionProposal) -> Void)?
    var onLifecycleEvent: ((ConversationRuntimeLifecycleEvent) -> Void)?

    var isRunning: Bool { transport.isRunning }
    var hasConfirmedInterruption: Bool { transport.hasConfirmedInterruption }

    private let credentialProvider: any LiveKitRoomCredentialProviding
    private let transport: any LiveKitConversationTransporting
    private let configuration: LiveKitConversationSessionConfiguration

    init(
        credentialProvider: any LiveKitRoomCredentialProviding,
        transport: any LiveKitConversationTransporting,
        configuration: LiveKitConversationSessionConfiguration
    ) {
        self.credentialProvider = credentialProvider
        self.transport = transport
        self.configuration = configuration
        configureTransportCallbacks()
    }

    func start() async throws {
        guard !transport.isRunning else { return }
        onLifecycleEvent?(.runtimeStartRequested)
        do {
            let credential = try await credentialProvider.fetchRoomCredential()
            try Task.checkCancellation()
            try await transport.start(
                credential: credential,
                configuration: configuration
            )
            try Task.checkCancellation()
            onLifecycleEvent?(.runtimeStarted)
        } catch {
            transport.stop()
            throw error
        }
    }

    func stop() {
        transport.stop()
    }

    func connect() async throws {
        try await start()
    }

    func append(_ chunk: AudioChunk) {
        // LiveKit owns microphone publishing; Coordinator receives levels only.
    }

    func setScreenContext(_ image: ConversationImage) async throws {
        try await transport.setScreenContext(image)
    }

    func requestUserResponse() async throws {
        try await transport.requestUserResponse()
    }

    func discardUserAudioItem(_ itemID: ConversationProviderItemID) {
        transport.discardUserAudioItem(itemID)
    }

    func requestOpeningGreeting() {
        transport.requestOpeningGreeting()
    }

    func provideToolOutput(
        callID: ConversationToolCallID,
        output: String,
        createsResponse: Bool
    ) async throws {
        try await transport.provideToolOutput(
            callID: callID,
            output: output,
            createsResponse: createsResponse
        )
    }

    func presentCompletedWork(_ result: String) async throws {
        try await transport.presentCompletedWork(result)
    }

    func cancelAssistantResponse() {
        transport.cancelAssistantResponse()
    }

    func truncateAssistantResponse(
        itemID: ConversationProviderItemID,
        audioEndMilliseconds: Int
    ) {
        transport.truncateAssistantResponse(
            itemID: itemID,
            audioEndMilliseconds: audioEndMilliseconds
        )
    }

    func disconnect() {
        stop()
    }

    func prepareForAssistantResponse() {}
    func finishAssistantPreparation(preserveActiveSpeech: Bool) {}
    func beginAssistantResponse() {}

    func enqueueAssistantAudio(_ data: Data) {
        // LiveKit owns remote audio playback; PCM is not replayed by Friday.
    }

    func markAssistantAudioFinished() {}

    func stopAssistantPlayback() -> Int {
        transport.stopAssistantPlayback()
    }

    func sendActionReceipt(_ receipt: ActionReceipt, requestID: String) async throws {
        let envelope = ActionRPCEnvelope(
            version: ActionRPCCodec.currentVersion,
            method: .reportReceipt,
            requestID: requestID,
            payload: receipt
        )
        try await transport.sendActionReceiptData(ActionRPCCodec.encode(envelope))
    }

    private func configureTransportCallbacks() {
        transport.onEvent = { [weak self] event in
            self?.handleTransportEvent(event)
        }
        transport.onInputLevels = { [weak self] levels in
            self?.onInputLevels?(levels)
        }
        transport.onOutputLevels = { [weak self] levels in
            self?.onOutputLevels?(levels)
        }
        transport.onPlaybackFinished = { [weak self] in
            self?.onPlaybackFinished?()
        }
        transport.onActionProposalData = { [weak self] data in
            self?.handleActionProposalData(data)
        }
        transport.onFailure = { [weak self] error in
            self?.onFailure?(error)
        }
    }

    private func handleTransportEvent(_ event: LiveKitConversationTransportEvent) {
        switch event {
        case .connected:
            onEvent?(.sessionReady)
        case .userSpeechStarted(let itemID):
            onEvent?(.userSpeechStarted(itemID: itemID))
        case .userSpeechStopped(let itemID):
            onEvent?(.userSpeechStopped(itemID: itemID))
        case .userTranscriptionCompleted(let transcription):
            onEvent?(.userTranscriptionCompleted(transcription))
        case .userTranscriptionFailed(let failure):
            onEvent?(.userTranscriptionFailed(failure))
        case .assistantResponseStarted(let responseID):
            onEvent?(.assistantResponseStarted(responseID: responseID))
        case .assistantItemStarted(let identity):
            onEvent?(.assistantItemStarted(identity))
        case .assistantPlaybackStarted(let identity):
            onEvent?(.assistantPlaybackStarted(identity))
        case .toolCall(let call):
            onEvent?(.toolCall(call))
        case .responseCompleted(let responseID, let usage):
            onEvent?(.responseCompleted(responseID: responseID, usage: usage))
        case .responseCancelled(let responseID):
            onEvent?(.responseCancelled(responseID: responseID))
        case .failed(let message):
            onEvent?(.failed(message))
        }
    }

    private func handleActionProposalData(_ data: Data) {
        do {
            let envelope = try ActionRPCCodec.decode(
                ActionProposal.self,
                from: data,
                expectedMethod: .proposeAction
            )
            onActionProposal?(envelope.payload)
        } catch {
            onFailure?(error)
        }
    }
}
