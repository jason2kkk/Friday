// 功能：定义一整套 Friday Talk Runtime 的中立装配与生命周期边界。
// 职责：原子组合 Provider、音频端口、端点转发策略、音频所有权和统一启停顺序，并用直接 Realtime 包装器保持当前产品行为。
// 边界：不选择具体供应商、不绘制界面、不读取凭证，也不实现麦克风、播放、WebSocket 或后台 Work。

import Foundation

enum ConversationRuntimeKind: String, Equatable, Sendable {
    case directRealtime = "direct_realtime"
    case liveKitStageZero = "livekit_stage_zero"
}

enum ConversationAudioOwner: String, Equatable, Sendable {
    case fridayApp = "friday_app"
    case conversationRuntime = "conversation_runtime"
}

enum ConversationSessionRecordingPolicy: String, Equatable, Sendable {
    case notApplicable = "not_applicable"
    case disabled
}

struct ConversationRuntimeDescriptor: Equatable, Sendable {
    let kind: ConversationRuntimeKind
    let audioOwner: ConversationAudioOwner
    let recordingPolicy: ConversationSessionRecordingPolicy

    static let directRealtime = ConversationRuntimeDescriptor(
        kind: .directRealtime,
        audioOwner: .fridayApp,
        recordingPolicy: .notApplicable
    )
}

enum ConversationRuntimeLifecycleEvent: String, Equatable, Sendable {
    case localAudioStartRequested = "local_audio.start_requested"
    case localAudioStarted = "local_audio.started"
    case providerConnectRequested = "provider.connect_requested"
    case providerConnected = "provider.connected"
    case runtimeStartRequested = "runtime.start_requested"
    case runtimeStarted = "runtime.started"
}

@MainActor
protocol ConversationRuntimeSession: AnyObject {
    var descriptor: ConversationRuntimeDescriptor { get }
    var conversationProvider: any ConversationProviding { get }
    var audioService: any ConversationAudioServicing { get }
    var onLifecycleEvent: ((ConversationRuntimeLifecycleEvent) -> Void)? { get set }

    func start() async throws
    func stop()
}

@MainActor
final class DirectRealtimeConversationRuntimeSession: ConversationRuntimeSession {
    let descriptor = ConversationRuntimeDescriptor.directRealtime
    let conversationProvider: any ConversationProviding
    let audioService: any ConversationAudioServicing
    var onLifecycleEvent: ((ConversationRuntimeLifecycleEvent) -> Void)?

    private(set) var isStarted = false

    init(
        conversationProvider: any ConversationProviding,
        audioService: any ConversationAudioServicing
    ) {
        self.conversationProvider = conversationProvider
        self.audioService = audioService
    }

    func start() async throws {
        guard !isStarted else { return }

        do {
            audioService.configureInputForwarding(
                endpointMode: conversationProvider.endpointMode,
                allowsResponseInterruption: conversationProvider.allowsResponseInterruption
            )
            onLifecycleEvent?(.localAudioStartRequested)
            try await audioService.start()
            try Task.checkCancellation()
            onLifecycleEvent?(.localAudioStarted)
            onLifecycleEvent?(.providerConnectRequested)
            try await conversationProvider.connect()
            try Task.checkCancellation()
            audioService.configureInputForwarding(
                endpointMode: conversationProvider.endpointMode,
                allowsResponseInterruption: conversationProvider.allowsResponseInterruption
            )
            onLifecycleEvent?(.providerConnected)
            isStarted = true
        } catch {
            conversationProvider.disconnect()
            audioService.stop()
            isStarted = false
            throw error
        }
    }

    func stop() {
        conversationProvider.disconnect()
        audioService.stop()
        isStarted = false
    }
}
