// 功能：验证 Talk Runtime 装配、LiveKit Stage 0 和 Action RPC 的零费用契约。
// 职责：覆盖现有 Realtime 启停顺序、失败清理、候选 Runtime 音频独占、禁用录制、事件映射、凭证脱敏和动作消息编解码。
// 边界：只使用内存假 Provider、音频和 Room Transport，不访问麦克风、网络、LiveKit Cloud、OpenAI 或任何付费模型。

import Foundation
import XCTest
@testable import Friday

@MainActor
final class ConversationRuntimeTests: XCTestCase {
    func testDirectRuntimeStartsAudioBeforeProviderAndStopsBoth() async throws {
        let trace = RuntimeTestTrace()
        let provider = RuntimeTestConversationProvider(trace: trace)
        let audio = RuntimeTestAudioService(trace: trace)
        let runtime = DirectRealtimeConversationRuntimeSession(
            conversationProvider: provider,
            audioService: audio
        )

        try await runtime.start()

        XCTAssertEqual(trace.events, ["audio.start", "provider.connect"])
        XCTAssertTrue(runtime.isStarted)
        XCTAssertEqual(runtime.descriptor, .directRealtime)

        runtime.stop()

        XCTAssertEqual(
            trace.events,
            ["audio.start", "provider.connect", "provider.disconnect", "audio.stop"]
        )
        XCTAssertFalse(runtime.isStarted)
    }

    func testDirectRuntimeCleansUpWhenProviderConnectionFails() async {
        let trace = RuntimeTestTrace()
        let provider = RuntimeTestConversationProvider(trace: trace)
        provider.connectError = RuntimeTestError.expected
        let audio = RuntimeTestAudioService(trace: trace)
        let runtime = DirectRealtimeConversationRuntimeSession(
            conversationProvider: provider,
            audioService: audio
        )

        do {
            try await runtime.start()
            XCTFail("Expected provider connection to fail")
        } catch {
            XCTAssertEqual(error as? RuntimeTestError, .expected)
        }

        XCTAssertEqual(
            trace.events,
            ["audio.start", "provider.connect", "provider.disconnect", "audio.stop"]
        )
        XCTAssertFalse(runtime.isStarted)
        XCTAssertFalse(audio.isRunning)
    }

    func testLiveKitConfigurationRequiresExplicitlyDisabledRecording() throws {
        XCTAssertThrowsError(
            try LiveKitConversationSessionConfiguration(recordSession: true)
        ) { error in
            XCTAssertEqual(
                error as? LiveKitStageZeroError,
                .recordingMustBeDisabled
            )
        }

        let configuration = try LiveKitConversationSessionConfiguration(
            recordSession: false
        )
        XCTAssertEqual(configuration.model, "gpt-realtime-2.1")
        XCTAssertEqual(configuration.openAIPluginArguments["model"], "gpt-realtime-2.1")
        XCTAssertEqual(configuration.openAIPluginArguments["voice"], "marin")
        XCTAssertFalse(configuration.recordSession)
    }

    func testLiveKitRuntimeOwnsOneTransportAndMapsProviderManagedPlayback() async throws {
        let credential = try LiveKitRoomCredential(
            serverURL: URL(string: "wss://livekit.invalid")!,
            token: "test-room-token"
        )
        let credentialProvider = RuntimeTestLiveKitCredentialProvider(credential: credential)
        let transport = RuntimeTestLiveKitTransport()
        let configuration = try LiveKitConversationSessionConfiguration(recordSession: false)
        let runtime = LiveKitConversationRuntimeSession(
            credentialProvider: credentialProvider,
            transport: transport,
            configuration: configuration
        )
        var events: [ConversationEvent] = []
        runtime.onEvent = { events.append($0) }

        try await runtime.start()
        try await runtime.start()

        XCTAssertEqual(credentialProvider.fetchCount, 1)
        XCTAssertEqual(transport.startCount, 1)
        XCTAssertEqual(runtime.descriptor.audioOwner, .conversationRuntime)
        XCTAssertEqual(runtime.descriptor.recordingPolicy, .disabled)
        XCTAssertTrue(runtime.isRunning)

        let responseID = ConversationProviderResponseID("response-stage-zero")!
        let itemID = ConversationProviderItemID("item-stage-zero")!
        let identity = ConversationProviderEventIdentity(
            responseID: responseID,
            itemID: itemID
        )
        transport.emit(.connected)
        transport.emit(.userSpeechStarted(itemID: itemID))
        transport.emit(.userSpeechStopped(itemID: itemID))
        transport.emit(.assistantResponseStarted(responseID: responseID))
        transport.emit(.assistantItemStarted(identity))
        transport.emit(.assistantPlaybackStarted(identity))
        transport.emit(.failed("stage-zero-failure"))

        XCTAssertEqual(
            events,
            [
                .sessionReady,
                .userSpeechStarted(itemID: itemID),
                .userSpeechStopped(itemID: itemID),
                .assistantResponseStarted(responseID: responseID),
                .assistantItemStarted(identity),
                .assistantPlaybackStarted(identity),
                .failed("stage-zero-failure")
            ]
        )
        XCTAssertEqual(transport.startCount, 1)

        runtime.stop()
        XCTAssertEqual(transport.stopCount, 1)
        XCTAssertFalse(runtime.isRunning)
    }

    func testLiveKitRuntimeStopsTransportWhenStartFails() async throws {
        let credential = try LiveKitRoomCredential(
            serverURL: URL(string: "wss://livekit.invalid")!,
            token: "test-room-token"
        )
        let transport = RuntimeTestLiveKitTransport()
        transport.startError = RuntimeTestError.expected
        let runtime = LiveKitConversationRuntimeSession(
            credentialProvider: RuntimeTestLiveKitCredentialProvider(credential: credential),
            transport: transport,
            configuration: try LiveKitConversationSessionConfiguration(
                recordSession: false
            )
        )

        do {
            try await runtime.start()
            XCTFail("Expected transport startup to fail")
        } catch {
            XCTAssertEqual(error as? RuntimeTestError, .expected)
        }

        XCTAssertEqual(transport.startCount, 1)
        XCTAssertEqual(transport.stopCount, 1)
        XCTAssertFalse(runtime.isRunning)
    }

    func testLiveKitCredentialDescriptionNeverContainsToken() throws {
        let credential = try LiveKitRoomCredential(
            serverURL: URL(string: "wss://livekit.invalid")!,
            token: "private-test-token"
        )

        XCTAssertFalse(credential.description.contains("private-test-token"))
        XCTAssertTrue(credential.description.contains("<redacted>"))
    }

    func testLiveKitActionProposalAndReceiptUseVersionedRPCWithoutExecution() async throws {
        let credential = try LiveKitRoomCredential(
            serverURL: URL(string: "wss://livekit.invalid")!,
            token: "test-room-token"
        )
        let transport = RuntimeTestLiveKitTransport()
        let runtime = LiveKitConversationRuntimeSession(
            credentialProvider: RuntimeTestLiveKitCredentialProvider(credential: credential),
            transport: transport,
            configuration: try LiveKitConversationSessionConfiguration(
                recordSession: false
            )
        )
        let workID = WorkID("work_11111111111111111111111111111111")!
        let proposal = ActionProposal(
            id: ActionID("action_22222222222222222222222222222222")!,
            workID: workID,
            kind: "insert_text",
            target: "focused_input",
            parameters: ["mode": "replace_selection"],
            preview: "受控测试文本",
            risk: .reversibleLocalWrite,
            reversibility: .reversible,
            requiredPermission: .none
        )
        let proposalEnvelope = ActionRPCEnvelope(
            version: ActionRPCCodec.currentVersion,
            method: .proposeAction,
            requestID: "rpc-proposal-1",
            payload: proposal
        )
        var receivedProposal: ActionProposal?
        runtime.onActionProposal = { receivedProposal = $0 }

        transport.emitActionProposalData(try ActionRPCCodec.encode(proposalEnvelope))

        XCTAssertEqual(receivedProposal, proposal)

        let receipt = ActionReceipt(
            id: ActionReceiptID("receipt_33333333333333333333333333333333")!,
            workID: workID,
            actionID: proposal.id,
            status: .succeeded,
            targetRevision: "revision-1",
            observedResult: "text_present",
            undoToken: "undo-1",
            executedAt: Date(timeIntervalSince1970: 1_700_000_000),
            error: nil
        )

        try await runtime.sendActionReceipt(receipt, requestID: "rpc-receipt-1")

        let data = try XCTUnwrap(transport.sentActionReceiptData)
        let decoded = try ActionRPCCodec.decode(
            ActionReceipt.self,
            from: data,
            expectedMethod: .reportReceipt
        )
        XCTAssertEqual(decoded.payload, receipt)
        XCTAssertEqual(decoded.requestID, "rpc-receipt-1")
    }

    func testActionRPCRejectsInvalidSchemaVersionMethodAndSize() throws {
        let proposal = ActionProposal(
            id: ActionID("action_aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa")!,
            workID: WorkID("work_bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb")!,
            kind: "insert_text",
            target: "focused_input",
            parameters: [:],
            preview: "preview",
            risk: .reversibleLocalWrite,
            reversibility: .reversible,
            requiredPermission: .none
        )
        let validEnvelope = ActionRPCEnvelope(
            version: ActionRPCCodec.currentVersion,
            method: .proposeAction,
            requestID: "rpc-contract-1",
            payload: proposal
        )
        let validData = try ActionRPCCodec.encode(validEnvelope)
        let json = try XCTUnwrap(
            JSONSerialization.jsonObject(with: validData) as? [String: Any]
        )
        var payload = try XCTUnwrap(json["payload"] as? [String: Any])

        XCTAssertEqual(payload["id"] as? String, proposal.id.rawValue)
        XCTAssertEqual(payload["work_id"] as? String, proposal.workID.rawValue)

        payload["id"] = "invalid-action-id"
        var invalidIDJSON = json
        invalidIDJSON["payload"] = payload
        let invalidIDData = try JSONSerialization.data(withJSONObject: invalidIDJSON)
        XCTAssertThrowsError(
            try ActionRPCCodec.decode(
                ActionProposal.self,
                from: invalidIDData,
                expectedMethod: .proposeAction
            )
        )

        let unsupportedVersion = ActionRPCEnvelope(
            version: ActionRPCCodec.currentVersion + 1,
            method: .proposeAction,
            requestID: "rpc-contract-2",
            payload: proposal
        )
        XCTAssertThrowsError(
            try ActionRPCCodec.decode(
                ActionProposal.self,
                from: ActionRPCCodec.encode(unsupportedVersion),
                expectedMethod: .proposeAction
            )
        ) { error in
            XCTAssertEqual(error as? ActionRPCCodecError, .unsupportedVersion)
        }

        let unexpectedMethod = ActionRPCEnvelope(
            version: ActionRPCCodec.currentVersion,
            method: .reportReceipt,
            requestID: "rpc-contract-3",
            payload: proposal
        )
        XCTAssertThrowsError(
            try ActionRPCCodec.decode(
                ActionProposal.self,
                from: ActionRPCCodec.encode(unexpectedMethod),
                expectedMethod: .proposeAction
            )
        ) { error in
            XCTAssertEqual(error as? ActionRPCCodecError, .unexpectedMethod)
        }

        let oversizedData = Data(
            repeating: 0,
            count: ActionRPCCodec.maximumPayloadBytes + 1
        )
        XCTAssertThrowsError(
            try ActionRPCCodec.decode(
                ActionProposal.self,
                from: oversizedData,
                expectedMethod: .proposeAction
            )
        ) { error in
            XCTAssertEqual(error as? ActionRPCCodecError, .payloadTooLarge)
        }
    }
}

private enum RuntimeTestError: Error, Equatable {
    case expected
}

@MainActor
private final class RuntimeTestTrace {
    var events: [String] = []
}

@MainActor
private final class RuntimeTestConversationProvider: ConversationProviding {
    var onEvent: ((ConversationEvent) -> Void)?
    var connectError: Error?
    private let trace: RuntimeTestTrace

    init(trace: RuntimeTestTrace) {
        self.trace = trace
    }

    func connect() async throws {
        trace.events.append("provider.connect")
        if let connectError { throw connectError }
    }

    func append(_ chunk: AudioChunk) {}
    func setScreenContext(_ image: ConversationImage) async throws {}
    func requestUserResponse() async throws {}
    func discardUserAudioItem(_ itemID: ConversationProviderItemID) {}
    func requestOpeningGreeting() {}
    func provideToolOutput(
        callID: ConversationToolCallID,
        output: String,
        createsResponse: Bool
    ) async throws {}
    func presentCompletedWork(_ result: String) async throws {}
    func cancelAssistantResponse() {}
    func truncateAssistantResponse(
        itemID: ConversationProviderItemID,
        audioEndMilliseconds: Int
    ) {}

    func disconnect() {
        trace.events.append("provider.disconnect")
    }
}

@MainActor
private final class RuntimeTestAudioService: ConversationAudioServicing {
    var onInputChunk: ((AudioChunk) -> Void)?
    var onInputLevels: ((ConversationAudioLevels) -> Void)?
    var onInputGateTransition: ((ConversationInputGateTransition) -> Void)?
    var onOutputLevels: ((ConversationAudioLevels) -> Void)?
    var onPlaybackFinished: (() -> Void)?
    var onFailure: ((Error) -> Void)?
    private(set) var isRunning = false
    private let trace: RuntimeTestTrace

    init(trace: RuntimeTestTrace) {
        self.trace = trace
    }

    func start() async throws {
        trace.events.append("audio.start")
        isRunning = true
    }

    func prepareForAssistantResponse() {}
    func finishAssistantPreparation(preserveActiveSpeech: Bool) {}
    func beginAssistantResponse() {}
    func enqueueAssistantAudio(_ data: Data) {}
    func markAssistantAudioFinished() {}
    func stopAssistantPlayback() -> Int { 0 }

    func stop() {
        trace.events.append("audio.stop")
        isRunning = false
    }
}

@MainActor
private final class RuntimeTestLiveKitCredentialProvider: LiveKitRoomCredentialProviding {
    private let credential: LiveKitRoomCredential
    private(set) var fetchCount = 0

    init(credential: LiveKitRoomCredential) {
        self.credential = credential
    }

    func fetchRoomCredential() async throws -> LiveKitRoomCredential {
        fetchCount += 1
        return credential
    }
}

@MainActor
private final class RuntimeTestLiveKitTransport: LiveKitConversationTransporting {
    var onEvent: ((LiveKitConversationTransportEvent) -> Void)?
    var onInputLevels: ((ConversationAudioLevels) -> Void)?
    var onOutputLevels: ((ConversationAudioLevels) -> Void)?
    var onPlaybackFinished: (() -> Void)?
    var onActionProposalData: ((Data) -> Void)?
    var onFailure: ((Error) -> Void)?
    private(set) var isRunning = false
    var hasConfirmedInterruption = false
    var startError: Error?
    private(set) var startCount = 0
    private(set) var stopCount = 0
    private(set) var sentActionReceiptData: Data?

    func start(
        credential: LiveKitRoomCredential,
        configuration: LiveKitConversationSessionConfiguration
    ) async throws {
        startCount += 1
        if let startError {
            isRunning = true
            throw startError
        }
        isRunning = true
    }

    func setScreenContext(_ image: ConversationImage) async throws {}
    func requestUserResponse() async throws {}
    func discardUserAudioItem(_ itemID: ConversationProviderItemID) {}
    func requestOpeningGreeting() {}
    func provideToolOutput(
        callID: ConversationToolCallID,
        output: String,
        createsResponse: Bool
    ) async throws {}
    func presentCompletedWork(_ result: String) async throws {}
    func cancelAssistantResponse() {}
    func truncateAssistantResponse(
        itemID: ConversationProviderItemID,
        audioEndMilliseconds: Int
    ) {}
    func stopAssistantPlayback() -> Int { 0 }

    func sendActionReceiptData(_ data: Data) async throws {
        sentActionReceiptData = data
    }

    func stop() {
        stopCount += 1
        isRunning = false
    }

    func emit(_ event: LiveKitConversationTransportEvent) {
        onEvent?(event)
    }

    func emitActionProposalData(_ data: Data) {
        onActionProposalData?(data)
    }
}
