// 功能：定义 Friday Talk 双向语音对话的中立状态、事件、身份和值类型，以及可替换的 Provider 接口。
// 职责：统一连接、音频、图片上下文、取消和用量事件，集中声明模式、价格估算、提示词，并提供零成本 Mock Provider。
// 边界：不建立真实网络连接、不访问音频设备，也不包含灵动岛或会话窗口的具体展示逻辑。

import Foundation

enum ConversationState: Equatable {
    case dormant
    case requestingPermission
    case waitingForWakeWord
    case connecting
    case listening
    case userSpeaking
    case selectingScreenRegion
    case capturingScreenRegion
    case assistantPreparing
    case assistantSpeaking
    case ending
    case unavailable(String)

    var statusText: String {
        switch self {
        case .dormant:
            return "Hey Friday 已暂停"
        case .requestingPermission:
            return "正在准备 Hey Friday"
        case .waitingForWakeWord:
            return "可以直接说 Hey Friday"
        case .connecting:
            return "Friday 已被唤醒"
        case .listening, .userSpeaking:
            return "正在和 Friday 对话"
        case .selectingScreenRegion:
            return "拖动选择 Friday 要看的区域"
        case .capturingScreenRegion:
            return "Friday 正在查看所选区域"
        case .assistantPreparing, .assistantSpeaking:
            return "Friday 正在回应"
        case .ending:
            return "正在结束对话"
        case .unavailable(let message):
            return message
        }
    }

    var isConversationActive: Bool {
        switch self {
        case .connecting, .listening, .userSpeaking, .selectingScreenRegion,
             .capturingScreenRegion, .assistantPreparing, .assistantSpeaking, .ending:
            return true
        case .dormant, .requestingPermission, .waitingForWakeWord, .unavailable:
            return false
        }
    }
}

struct ConversationImage: Sendable, Equatable {
    let data: Data
    let mimeType: String
    let pixelWidth: Int
    let pixelHeight: Int

    var dataURL: String {
        "data:\(mimeType);base64,\(data.base64EncodedString())"
    }
}

struct ConversationProviderResponseID: Hashable, Sendable, CustomStringConvertible {
    let rawValue: String

    init?(_ rawValue: String?) {
        guard let rawValue, !rawValue.isEmpty else { return nil }
        self.rawValue = rawValue
    }

    var description: String { rawValue }
}

struct ConversationProviderItemID: Hashable, Sendable, CustomStringConvertible {
    let rawValue: String

    init?(_ rawValue: String?) {
        guard let rawValue, !rawValue.isEmpty else { return nil }
        self.rawValue = rawValue
    }

    var description: String { rawValue }
}

struct ConversationProviderEventIdentity: Equatable, Sendable {
    let responseID: ConversationProviderResponseID?
    let itemID: ConversationProviderItemID?

    static let unavailable = ConversationProviderEventIdentity(
        responseID: nil,
        itemID: nil
    )
}

struct ConversationToolCallID: Hashable, Sendable, CustomStringConvertible {
    let rawValue: String

    init?(_ rawValue: String?) {
        guard let rawValue, !rawValue.isEmpty else { return nil }
        self.rawValue = rawValue
    }

    var description: String { rawValue }
}

struct ConversationToolCall: Equatable, Sendable {
    let callID: ConversationToolCallID
    let name: String
    let argumentsJSON: String
    let responseID: ConversationProviderResponseID?
}

struct ConversationInputTranscription: Equatable, Sendable {
    let itemID: ConversationProviderItemID
    let text: String
    let language: String?
    let confidence: Double?
    let usage: UserTurnTranscriptionUsage?
}

struct ConversationInputTranscriptionFailure: Equatable, Sendable {
    let itemID: ConversationProviderItemID
    let code: String?
}

enum ConversationEvent: Equatable {
    case sessionReady
    case userSpeechStarted(itemID: ConversationProviderItemID?)
    case userSpeechStopped(itemID: ConversationProviderItemID?)
    case userTranscriptionCompleted(ConversationInputTranscription)
    case userTranscriptionFailed(ConversationInputTranscriptionFailure)
    case assistantResponseStarted(responseID: ConversationProviderResponseID?)
    case assistantItemStarted(ConversationProviderEventIdentity)
    // A runtime-managed audio path has begun playback; no PCM should be replayed locally.
    case assistantPlaybackStarted(ConversationProviderEventIdentity)
    case assistantAudio(identity: ConversationProviderEventIdentity, data: Data)
    case assistantAudioFinished(ConversationProviderEventIdentity)
    case assistantTranscriptDelta(
        identity: ConversationProviderEventIdentity,
        delta: String
    )
    case toolCall(ConversationToolCall)
    case responseCompleted(
        responseID: ConversationProviderResponseID?,
        usage: DictationUsage
    )
    case responseCancelled(responseID: ConversationProviderResponseID?)
    case assistantCancellationIgnored(code: String?)
    case failed(String)
}

@MainActor
protocol ConversationProviding: AnyObject {
    var onEvent: ((ConversationEvent) -> Void)? { get set }

    func connect() async throws
    func append(_ chunk: AudioChunk)
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
    func disconnect()
}

enum ConversationMode {
    case mock
    case live

    static var configured: ConversationMode {
        ProcessInfo.processInfo.environment["FRIDAY_TALK_MODE"]?.lowercased() == "mock"
            ? .mock
            : .live
    }
}

enum ConversationLimits {
    static let idleTimeout: Duration = .seconds(20)
    static let openingGreetingDelay: Duration = .seconds(5)
    static let userTurnResponseGrace: Duration = .milliseconds(450)
    static let openingGreetingMaximumTokens = 48
    static let toolFollowUpMaximumTokens = 80
    static let workResultMaximumTokens = 180
}

enum RealtimeTalkPricing {
    // Official gpt-realtime-2.1 standard pricing checked on 2026-07-29.
    private static let inputTextPerMillion = 4.0
    private static let cachedInputPerMillion = 0.4
    private static let inputAudioPerMillion = 32.0
    private static let inputImagePerMillion = 5.0
    private static let cachedInputImagePerMillion = 0.5
    private static let outputTextPerMillion = 24.0
    private static let outputAudioPerMillion = 64.0

    static func estimatedCostUSD(for usage: DictationUsage) -> Double {
        let cachedText = min(usage.inputTextTokens, max(0, usage.cachedInputTextTokens))
        let cachedAudio = min(usage.inputAudioTokens, max(0, usage.cachedInputAudioTokens))
        let cachedImage = min(usage.inputImageTokens, max(0, usage.cachedInputImageTokens))
        let uncachedText = max(0, usage.inputTextTokens - cachedText)
        let uncachedAudio = max(0, usage.inputAudioTokens - cachedAudio)
        let uncachedImage = max(0, usage.inputImageTokens - cachedImage)

        let million = 1_000_000.0
        return (
            Double(uncachedText) * inputTextPerMillion
                + Double(uncachedAudio) * inputAudioPerMillion
                + Double(uncachedImage) * inputImagePerMillion
                + Double(cachedText + cachedAudio) * cachedInputPerMillion
                + Double(cachedImage) * cachedInputImagePerMillion
                + Double(max(0, usage.outputTextTokens)) * outputTextPerMillion
                + Double(max(0, usage.outputAudioTokens)) * outputAudioPerMillion
        ) / million
    }
}

enum ConversationPrompt {
    static let openingGreeting = """
    用户主动打开了 Friday，但还没有说话。必须使用简体中文，用一句很短、自然、温和的话打招呼，然后等待。不要提到沉默、等待、监听、麦克风或系统状态；最多问一个简短问题。
    """

    static let toolFollowUp = """
    使用用户最近一段完整请求的语言，用一句简短自然的口语回应函数结果；无法确定语言时使用简体中文。不要因为函数返回值、JSON 字段或英文系统说明改用英文。status 为 clarification_required 时，只问一个简短澄清问题，不能静默；status 为 awaiting_confirmation 时，忠实复述 objective，并明确请用户说“确认提交”或“取消”；status 为 transcript_unavailable 时，只说明无法核对这轮原话且没有创建任务；status 为 accepted 时，只说明测试任务已经开始且用户可以继续说话；status 为 discarded 时，只说明草稿已取消；被拒绝时简短说明可恢复原因。不要透露内部 ID，不要把草稿说成已提交，也不要声称未完成的任务已经完成。
    """

    static func completedWork(_ result: String) -> String {
        """
        这是 Friday 有限 Work Runtime 发出的可信完成事件，不是新的用户请求。使用用户最近一段完整请求的语言，以简洁自然的口语告诉用户实际结果；无法确定语言时使用简体中文。不要因为结果包含英文、JSON 字段或内部术语而切换语言。不要调用工具、透露内部 ID、补充事实，也不要声称发生了结果之外的任何外部操作。

        <work_result>
        \(result)
        </work_result>
        """
    }
}

@MainActor
final class MockConversationProvider: ConversationProviding {
    var onEvent: ((ConversationEvent) -> Void)?
    private(set) var isConnected = false
    private(set) var appendedChunkCount = 0
    private(set) var openingGreetingRequestCount = 0
    private(set) var truncations: [(itemID: String, audioEndMilliseconds: Int)] = []
    private(set) var screenContexts: [ConversationImage] = []
    private(set) var userResponseRequestCount = 0
    private(set) var discardedUserAudioItemIDs: [String] = []
    private(set) var assistantCancellationCount = 0
    private(set) var toolOutputs: [(callID: String, output: String, createsResponse: Bool)] = []
    private(set) var completedWorkResults: [String] = []

    func connect() async throws {
        isConnected = true
        onEvent?(.sessionReady)
    }

    func append(_ chunk: AudioChunk) {
        guard isConnected else { return }
        appendedChunkCount += 1
    }

    func setScreenContext(_ image: ConversationImage) async throws {
        guard isConnected else { return }
        screenContexts.append(image)
    }

    func requestUserResponse() async throws {
        guard isConnected else { return }
        userResponseRequestCount += 1
    }

    func discardUserAudioItem(_ itemID: ConversationProviderItemID) {
        guard isConnected else { return }
        discardedUserAudioItemIDs.append(itemID.rawValue)
    }

    func requestOpeningGreeting() {
        guard isConnected else { return }
        openingGreetingRequestCount += 1
        onEvent?(.assistantResponseStarted(responseID: nil))
    }

    func provideToolOutput(
        callID: ConversationToolCallID,
        output: String,
        createsResponse: Bool
    ) async throws {
        guard isConnected else { return }
        toolOutputs.append((callID.rawValue, output, createsResponse))
    }

    func presentCompletedWork(_ result: String) async throws {
        guard isConnected else { return }
        completedWorkResults.append(result)
    }

    func cancelAssistantResponse() {
        assistantCancellationCount += 1
    }

    func truncateAssistantResponse(
        itemID: ConversationProviderItemID,
        audioEndMilliseconds: Int
    ) {
        truncations.append((itemID.rawValue, audioEndMilliseconds))
    }

    func disconnect() {
        isConnected = false
    }

    func simulate(_ event: ConversationEvent) {
        onEvent?(event)
    }
}
