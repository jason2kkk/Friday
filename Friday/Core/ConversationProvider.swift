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

enum ConversationEvent: Equatable {
    case sessionReady
    case userSpeechStarted(itemID: ConversationProviderItemID?)
    case userSpeechStopped(itemID: ConversationProviderItemID?)
    case assistantResponseStarted(responseID: ConversationProviderResponseID?)
    case assistantItemStarted(ConversationProviderEventIdentity)
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
    case failed(String)
}

@MainActor
protocol ConversationProviding: AnyObject {
    var onEvent: ((ConversationEvent) -> Void)? { get set }

    func connect() async throws
    func append(_ chunk: AudioChunk)
    func setScreenContext(_ image: ConversationImage) async throws
    func requestOpeningGreeting()
    func provideToolOutput(callID: ConversationToolCallID, output: String) async throws
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
    The user deliberately opened Friday but has not spoken yet. Greet them warmly in one very short spoken sentence, then wait. Do not mention silence, waiting, listening, the microphone, or system status. Do not ask more than one brief question. Use the language most likely appropriate for the current conversation context; when there is no context, use Simplified Chinese.
    """

    static let toolFollowUp = """
    Respond to the function result in one short natural spoken sentence. If status is accepted, say only that the specific task has started and the user can continue talking. If it is rejected, explain the recoverable reason briefly. Do not call another tool, reveal IDs, or claim unfinished work is complete.
    """

    static func completedWork(_ result: String) -> String {
        """
        This is a trusted completion event from Friday's bounded Work Runtime, not a new user request. Tell the user the actual result in concise natural speech. Do not call tools, reveal internal IDs, add facts, or claim any external action beyond the supplied result.

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
    private(set) var assistantCancellationCount = 0
    private(set) var toolOutputs: [(callID: String, output: String)] = []
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

    func requestOpeningGreeting() {
        guard isConnected else { return }
        openingGreetingRequestCount += 1
        onEvent?(.assistantResponseStarted(responseID: nil))
    }

    func provideToolOutput(callID: ConversationToolCallID, output: String) async throws {
        guard isConnected else { return }
        toolOutputs.append((callID.rawValue, output))
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
