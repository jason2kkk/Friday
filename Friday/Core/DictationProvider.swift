// 功能：定义 Dictate 的音频、上下文、用量和结果契约，并提供可独立开发界面的零成本 Mock Provider。
// 职责：封装 PCM16 音频分片与内存留存、语音存在判定、处理接口、错误类型和 Mock 成功或失败行为。
// 边界：不实现真实 Realtime WebSocket、不访问麦克风或输入框，也不把保留音频写入磁盘。

import Foundation

struct AudioChunk: Sendable {
    static let waveformLevelCount = 8

    let pcm16: Data
    let sampleRate: Double
    let channelCount: Int
    let frameCount: Int
    let normalizedLevel: Float
    let waveformLevels: [Float]

    init(
        pcm16: Data,
        sampleRate: Double,
        channelCount: Int,
        frameCount: Int,
        normalizedLevel: Float = 0,
        waveformLevels: [Float] = []
    ) {
        let safeLevel = min(max(normalizedLevel, 0), 1)
        let safeWaveformLevels = waveformLevels.map { min(max($0, 0), 1) }

        self.pcm16 = pcm16
        self.sampleRate = sampleRate
        self.channelCount = channelCount
        self.frameCount = frameCount
        self.normalizedLevel = safeLevel
        self.waveformLevels = safeWaveformLevels.count == Self.waveformLevelCount
            ? safeWaveformLevels
            : Array(repeating: safeLevel, count: Self.waveformLevelCount)
    }
}

struct RetainedAudio: Sendable {
    private(set) var chunks: [AudioChunk] = []
    private(set) var frameCount = 0
    private(set) var voicedFrameCount = 0
    private(set) var sampleRate: Double = 24_000
    private(set) var peakLevel: Float = 0

    private static let speechLevelThreshold: Float = 0.18
    private static let minimumPeakLevel: Float = 0.24
    private static let minimumVoicedDuration: TimeInterval = 0.08

    var duration: TimeInterval {
        guard sampleRate > 0 else { return 0 }
        return Double(frameCount) / sampleRate
    }

    var isEmpty: Bool {
        chunks.isEmpty
    }

    var voicedDuration: TimeInterval {
        guard sampleRate > 0 else { return 0 }
        return Double(voicedFrameCount) / sampleRate
    }

    var hasLikelySpeech: Bool {
        peakLevel >= Self.minimumPeakLevel
            && voicedDuration >= Self.minimumVoicedDuration
    }

    static func isSpeechLevel(_ level: Float) -> Bool {
        level >= speechLevelThreshold
    }

    mutating func append(_ chunk: AudioChunk) {
        if chunks.isEmpty {
            sampleRate = chunk.sampleRate
        }
        chunks.append(chunk)
        frameCount += chunk.frameCount
        peakLevel = max(peakLevel, chunk.normalizedLevel)
        if Self.isSpeechLevel(chunk.normalizedLevel) {
            voicedFrameCount += chunk.frameCount
        }
    }

    mutating func removeAll() {
        chunks.removeAll(keepingCapacity: false)
        frameCount = 0
        voicedFrameCount = 0
        sampleRate = 24_000
        peakLevel = 0
    }
}

struct DictationContext: Sendable {
    let targetApplication: String
    let targetRole: String
    let mockOutputText: String
}

struct DictationUsage: Sendable, Equatable {
    var inputTextTokens = 0
    var inputAudioTokens = 0
    var cachedInputTextTokens = 0
    var cachedInputAudioTokens = 0
    var inputImageTokens = 0
    var cachedInputImageTokens = 0
    var outputTextTokens = 0
    var outputAudioTokens = 0
    var totalTokens = 0

    static let zero = DictationUsage()
}

struct DictationResult: Sendable, Equatable {
    let rawTranscript: String?
    let finalText: String
    let hasUncertainty: Bool
    let usage: DictationUsage
}

@MainActor
protocol DictationProvider: AnyObject {
    var displayName: String { get }
    var onPartialText: ((String) -> Void)? { get set }

    func begin(context: DictationContext) async throws
    func append(_ chunk: AudioChunk)
    func finish() async throws -> DictationResult
    func cancel()
}

@MainActor
final class MockDictationProvider: DictationProvider {
    enum MockError: LocalizedError {
        case noSession
        case emptyOutput
        case injectedFailure

        var errorDescription: String? {
            switch self {
            case .noSession:
                return "当前没有正在进行的语音输入。"
            case .emptyOutput:
                return "开发测试文本为空。"
            case .injectedFailure:
                return "模拟网络波动，本轮内容已保留。"
            }
        }
    }

    let displayName = "开发测试"
    var onPartialText: ((String) -> Void)?

    private var context: DictationContext?
    private var receivedFrameCount = 0
    private var remainingInjectedFailures: Int

    init() {
        remainingInjectedFailures = Self.shouldFailFirstFinish ? 1 : 0
    }

    init(failFirstFinish: Bool) {
        remainingInjectedFailures = failFirstFinish ? 1 : 0
    }

    func begin(context: DictationContext) async throws {
        self.context = context
        receivedFrameCount = 0
    }

    func append(_ chunk: AudioChunk) {
        receivedFrameCount += chunk.frameCount
    }

    func finish() async throws -> DictationResult {
        try await Task.sleep(for: .milliseconds(650))
        guard let context else { throw MockError.noSession }
        self.context = nil
        receivedFrameCount = 0

        if remainingInjectedFailures > 0 {
            remainingInjectedFailures -= 1
            throw MockError.injectedFailure
        }

        let output = context.mockOutputText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !output.isEmpty else { throw MockError.emptyOutput }
        onPartialText?(output)

        return DictationResult(
            rawTranscript: nil,
            finalText: output,
            hasUncertainty: false,
            usage: .zero
        )
    }

    func cancel() {
        context = nil
        receivedFrameCount = 0
    }

    private static var shouldFailFirstFinish: Bool {
        ProcessInfo.processInfo.environment["FRIDAY_MOCK_FAIL_ONCE"] == "1"
    }
}
