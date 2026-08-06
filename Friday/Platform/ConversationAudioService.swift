// 功能：为 Talk 同时采集用户麦克风并播放 Friday 的流式语音，按端点所有权提供连续或门控的 Realtime 上行音频。
// 职责：优先编排 VoiceProcessingIO 全双工 AEC，失败时使用 AVAudioEngine 半双工降级；Provider VAD 模式转发普通 PCM，并在播放期仅放行本地确认的人声候选以支持安全插话。
// 边界：不建立网络会话、不理解语音内容、不保存原始音频；设备失败只通过类型化错误和回调交给协调器处理。

@preconcurrency import AVFoundation
import Foundation
import OSLog

struct ConversationPCM16Meter {
    static func levels(for data: Data) -> ConversationAudioLevels {
        guard data.count >= MemoryLayout<Int16>.size else {
            return ConversationAudioLevels(
                level: 0,
                waveformLevels: Self.silentWaveformLevels
            )
        }

        return data.withUnsafeBytes { rawBuffer in
            let samples = rawBuffer.bindMemory(to: Int16.self)
            guard let baseAddress = samples.baseAddress, !samples.isEmpty else {
                return ConversationAudioLevels(
                    level: 0,
                    waveformLevels: Self.silentWaveformLevels
                )
            }

            let floats = (0..<samples.count).map { index in
                Float(Int16(littleEndian: baseAddress[index])) / Float(Int16.max)
            }
            return floats.withUnsafeBufferPointer { buffer in
                guard let pointer = buffer.baseAddress else {
                    return ConversationAudioLevels(
                        level: 0,
                        waveformLevels: Self.silentWaveformLevels
                    )
                }
                return ConversationAudioLevels(
                    level: AudioLevelMeter.normalizedLevel(
                        samples: pointer,
                        count: buffer.count
                    ),
                    waveformLevels: AudioLevelMeter.waveformLevels(
                        samples: pointer,
                        count: buffer.count
                    )
                )
            }
        }
    }

    private static let silentWaveformLevels = Array(
        repeating: Float(0),
        count: AudioChunk.waveformLevelCount
    )
}

struct ConversationAudioFormatValidator {
    static func isUsable(sampleRate: Double, channelCount: UInt32) -> Bool {
        sampleRate.isFinite && sampleRate > 0 && channelCount > 0
    }

    static func isUsable(_ format: AVAudioFormat) -> Bool {
        isUsable(
            sampleRate: format.sampleRate,
            channelCount: format.channelCount
        )
    }
}

enum ConversationInputGateReleaseReason: String, Equatable {
    case acousticSilence = "acoustic_silence"
    case stableBackground = "stable_background"
}

enum ConversationInputGateCandidateResetReason: String, Equatable {
    case gapToleranceExceeded = "gap_tolerance_exceeded"
    case windowExpired = "window_expired"
}

struct ConversationInputGateCandidateSnapshot: Equatable {
    let reason: ConversationInputGateCandidateResetReason
    let interruption: Bool
    let voicedMilliseconds: Int
    let windowMilliseconds: Int
    let gapMilliseconds: Int
    let activationThreshold: Float
    let peakLevel: Float
}

enum ConversationInputGateTransition: Equatable {
    case candidateStarted(interruption: Bool)
    case candidateReset(ConversationInputGateCandidateSnapshot)
    case speechConfirmed(interruption: Bool)
    case speechReleased(reason: ConversationInputGateReleaseReason)
    case endpointSilenceExhausted

    var diagnosticName: String {
        switch self {
        case .candidateStarted:
            return "candidate_started"
        case .candidateReset:
            return "candidate_reset"
        case .speechConfirmed:
            return "speech_confirmed"
        case .speechReleased:
            return "speech_released"
        case .endpointSilenceExhausted:
            return "endpoint_silence_exhausted"
        }
    }
}

struct ConversationInputGate {
    private(set) var isAssistantPlaying = false
    private(set) var hasConfirmedSpeech = false
    private var allowsInterruption = true
    private var speechIsActive = false
    private var ambientBaseline: Float = 0.08
    private var candidateVoiceFrames = 0
    private var candidateWindowFrames = 0
    private var candidateGapFrames = 0
    private var candidateActivationThreshold: Float = 0
    private var trailingSilenceFrames = 0
    private var candidateMinimumLevel: Float = 1
    private var candidateMaximumLevel: Float = 0
    private var candidateLevelMovement: Float = 0
    private var candidateDynamicChanges = 0
    private var previousCandidateLevel: Float?
    private var activeTailFrames = 0
    private var activeTailSamples = 0
    private var activeTailMinimumLevel: Float = 1
    private var activeTailMaximumLevel: Float = 0
    private var activeTailMovement: Float = 0
    private var previousActiveTailLevel: Float?
    private var isMutingStableTail = false
    private var endpointSilenceFramesRemaining = 0
    private var preRoll: [AudioChunk] = []
    private var preRollFrameCount = 0
    private var pendingTransitions: [ConversationInputGateTransition] = []

    private static let sampleRate = 24_000
    private static let maximumPreRollFrames = Int(Double(sampleRate) * 0.45)
    private static let listeningCandidateFrames = Int(Double(sampleRate) * 0.14)
    private static let interruptionCandidateFrames = Int(Double(sampleRate) * 0.30)
    private static let strongInterruptionCandidateFrames = Int(Double(sampleRate) * 0.20)
    private static let maximumCandidateWindowFrames = Int(Double(sampleRate) * 0.75)
    private static let candidateGapToleranceFrames = Int(Double(sampleRate) * 0.18)
    private static let trailingSilenceFrames = Int(Double(sampleRate) * 0.55)
    private static let stableTailAnalysisFrames = Int(Double(sampleRate) * 0.45)
    private static let stableTailEndpointFrames = Int(Double(sampleRate) * 0.40)
    private static let maximumEndpointSilenceFrames = sampleRate * 4
    private static let resumedSpeechMovement: Float = 0.045

    static let maximumEndpointSilenceMilliseconds = maximumEndpointSilenceFrames * 1_000
        / sampleRate

    var hasConfirmedInterruption: Bool {
        isAssistantPlaying && hasConfirmedSpeech
    }

    mutating func takeTransitions() -> [ConversationInputGateTransition] {
        defer { pendingTransitions.removeAll(keepingCapacity: true) }
        return pendingTransitions
    }

    mutating func beginAssistantPlayback(allowsInterruption: Bool) {
        isAssistantPlaying = true
        self.allowsInterruption = allowsInterruption
        hasConfirmedSpeech = false
        speechIsActive = false
        candidateVoiceFrames = 0
        candidateWindowFrames = 0
        candidateGapFrames = 0
        candidateActivationThreshold = 0
        trailingSilenceFrames = 0
        resetCandidateProfile()
        resetActiveTailProfile()
        endpointSilenceFramesRemaining = 0
        preRoll.removeAll(keepingCapacity: true)
        preRollFrameCount = 0
    }

    mutating func inputForRealtime(_ chunk: AudioChunk) -> [AudioChunk] {
        if isAssistantPlaying, !allowsInterruption {
            candidateVoiceFrames = 0
            candidateWindowFrames = 0
            candidateGapFrames = 0
            candidateActivationThreshold = 0
            trailingSilenceFrames = 0
            resetCandidateProfile()
            resetActiveTailProfile()
            endpointSilenceFramesRemaining = 0
            preRoll.removeAll(keepingCapacity: true)
            preRollFrameCount = 0
            return []
        }

        let activationThreshold = currentActivationThreshold
        let releaseThreshold = max(0.16, activationThreshold - 0.08)

        if speechIsActive {
            if isMutingStableTail {
                let movement = previousActiveTailLevel.map {
                    abs(chunk.normalizedLevel - $0)
                } ?? 0
                previousActiveTailLevel = chunk.normalizedLevel
                if chunk.normalizedLevel >= releaseThreshold,
                   movement >= Self.resumedSpeechMovement {
                    isMutingStableTail = false
                    trailingSilenceFrames = 0
                    resetActiveTailProfile(seed: chunk.normalizedLevel)
                    return [chunk]
                }

                trailingSilenceFrames += chunk.frameCount
                let silentChunk = silenced(chunk)
                if trailingSilenceFrames >= Self.stableTailEndpointFrames {
                    releaseSpeech(reason: .stableBackground)
                }
                return [silentChunk]
            }

            if chunk.normalizedLevel >= releaseThreshold {
                trailingSilenceFrames = 0
                updateActiveTailProfile(with: chunk)
                if activeTailFrames >= Self.stableTailAnalysisFrames {
                    if activeTailLooksStable {
                        isMutingStableTail = true
                        trailingSilenceFrames = chunk.frameCount
                        return [silenced(chunk)]
                    }
                    resetActiveTailProfile(seed: chunk.normalizedLevel)
                }
            } else {
                trailingSilenceFrames += chunk.frameCount
                resetActiveTailProfile()
            }
            if trailingSilenceFrames >= Self.trailingSilenceFrames {
                releaseSpeech(reason: .acousticSilence)
            }
            return [chunk]
        }

        preRoll.append(chunk)
        preRollFrameCount += chunk.frameCount
        while preRollFrameCount > Self.maximumPreRollFrames, !preRoll.isEmpty {
            preRollFrameCount -= preRoll.removeFirst().frameCount
        }

        if !isAssistantPlaying,
           chunk.normalizedLevel <= max(0.18, ambientBaseline + 0.08) {
            ambientBaseline = ambientBaseline * 0.94 + chunk.normalizedLevel * 0.06
        }

        if chunk.normalizedLevel >= activationThreshold {
            let wasIdle = candidateWindowFrames == 0
            if wasIdle {
                candidateActivationThreshold = activationThreshold
            }
            candidateVoiceFrames += chunk.frameCount
            candidateWindowFrames += chunk.frameCount
            candidateGapFrames = 0
            updateCandidateProfile(with: chunk.normalizedLevel)
            if wasIdle {
                pendingTransitions.append(
                    .candidateStarted(interruption: isAssistantPlaying)
                )
            }
        } else if candidateWindowFrames > 0 {
            candidateWindowFrames += chunk.frameCount
            candidateGapFrames += chunk.frameCount
            if candidateGapFrames >= Self.candidateGapToleranceFrames {
                resetCandidateTracking(reporting: .gapToleranceExceeded)
            }
        }

        if isAssistantPlaying {
            let hasNormalInterruption = candidateVoiceFrames
                    >= Self.interruptionCandidateFrames
                && candidateLooksSpeechLike
            let hasStrongInterruption = candidateVoiceFrames
                    >= Self.strongInterruptionCandidateFrames
                && candidateMaximumLevel >= 0.72
                && candidateLooksSpeechLike
            guard hasNormalInterruption || hasStrongInterruption else {
                if candidateWindowFrames >= Self.maximumCandidateWindowFrames {
                    resetCandidateTracking(reporting: .windowExpired)
                }
                return endpointSilenceOutput(for: chunk)
            }
        } else {
            guard candidateVoiceFrames >= Self.listeningCandidateFrames,
                  candidateLooksSpeechLike else {
                if candidateWindowFrames >= Self.maximumCandidateWindowFrames {
                    resetCandidateTracking(reporting: .windowExpired)
                }
                return endpointSilenceOutput(for: chunk)
            }
        }

        endpointSilenceFramesRemaining = 0
        speechIsActive = true
        hasConfirmedSpeech = true
        trailingSilenceFrames = 0
        resetActiveTailProfile(seed: chunk.normalizedLevel)
        pendingTransitions.append(
            .speechConfirmed(interruption: isAssistantPlaying)
        )
        let released = preRoll
        preRoll.removeAll(keepingCapacity: true)
        preRollFrameCount = 0
        return released
    }

    mutating func finishAssistantPlayback(preserveActiveSpeech: Bool = false) {
        isAssistantPlaying = false
        allowsInterruption = true
        hasConfirmedSpeech = false
        endpointSilenceFramesRemaining = 0
        if !preserveActiveSpeech {
            speechIsActive = false
            candidateVoiceFrames = 0
            candidateWindowFrames = 0
            candidateGapFrames = 0
            candidateActivationThreshold = 0
            trailingSilenceFrames = 0
            resetCandidateProfile()
            resetActiveTailProfile()
        }
        preRoll.removeAll(keepingCapacity: true)
        preRollFrameCount = 0
    }

    mutating func completeUserTurnEndpoint() {
        hasConfirmedSpeech = false
        speechIsActive = false
        candidateVoiceFrames = 0
        candidateWindowFrames = 0
        candidateGapFrames = 0
        candidateActivationThreshold = 0
        trailingSilenceFrames = 0
        endpointSilenceFramesRemaining = 0
        resetCandidateProfile()
        resetActiveTailProfile()
        preRoll.removeAll(keepingCapacity: true)
        preRollFrameCount = 0
    }

    mutating func reset() {
        self = ConversationInputGate()
    }

    private var currentActivationThreshold: Float {
        if isAssistantPlaying {
            return min(0.66, max(0.46, ambientBaseline + 0.22))
        }
        return min(0.48, max(0.24, ambientBaseline + 0.12))
    }

    private var candidateLooksSpeechLike: Bool {
        candidateDynamicChanges >= 2
            && (candidateMaximumLevel - candidateMinimumLevel >= 0.045
                || candidateLevelMovement >= 0.12)
    }

    private var activeTailLooksStable: Bool {
        guard activeTailSamples >= 3 else { return false }
        let range = activeTailMaximumLevel - activeTailMinimumLevel
        let averageMovement = activeTailMovement / Float(activeTailSamples - 1)
        return range <= 0.055 && averageMovement <= 0.020
    }

    private mutating func updateCandidateProfile(with level: Float) {
        candidateMinimumLevel = min(candidateMinimumLevel, level)
        candidateMaximumLevel = max(candidateMaximumLevel, level)
        if let previousCandidateLevel {
            let movement = abs(level - previousCandidateLevel)
            candidateLevelMovement += movement
            if movement >= 0.025 {
                candidateDynamicChanges += 1
            }
        }
        previousCandidateLevel = level
    }

    private mutating func resetCandidateProfile() {
        candidateMinimumLevel = 1
        candidateMaximumLevel = 0
        candidateLevelMovement = 0
        candidateDynamicChanges = 0
        previousCandidateLevel = nil
    }

    private mutating func resetCandidateTracking(
        reporting reason: ConversationInputGateCandidateResetReason? = nil
    ) {
        if let reason, candidateWindowFrames > 0 {
            pendingTransitions.append(
                .candidateReset(
                    ConversationInputGateCandidateSnapshot(
                        reason: reason,
                        interruption: isAssistantPlaying,
                        voicedMilliseconds: milliseconds(for: candidateVoiceFrames),
                        windowMilliseconds: milliseconds(for: candidateWindowFrames),
                        gapMilliseconds: milliseconds(for: candidateGapFrames),
                        activationThreshold: candidateActivationThreshold,
                        peakLevel: candidateMaximumLevel
                    )
                )
            )
        }
        candidateVoiceFrames = 0
        candidateWindowFrames = 0
        candidateGapFrames = 0
        candidateActivationThreshold = 0
        resetCandidateProfile()
    }

    private func milliseconds(for frames: Int) -> Int {
        frames * 1_000 / Self.sampleRate
    }

    private mutating func updateActiveTailProfile(with chunk: AudioChunk) {
        if let previousActiveTailLevel,
           abs(chunk.normalizedLevel - previousActiveTailLevel)
                >= Self.resumedSpeechMovement {
            resetActiveTailProfile(seed: chunk.normalizedLevel)
            return
        }
        activeTailFrames += chunk.frameCount
        activeTailSamples += 1
        activeTailMinimumLevel = min(activeTailMinimumLevel, chunk.normalizedLevel)
        activeTailMaximumLevel = max(activeTailMaximumLevel, chunk.normalizedLevel)
        if let previousActiveTailLevel {
            activeTailMovement += abs(chunk.normalizedLevel - previousActiveTailLevel)
        }
        previousActiveTailLevel = chunk.normalizedLevel
    }

    private mutating func resetActiveTailProfile(seed: Float? = nil) {
        activeTailFrames = 0
        activeTailSamples = seed == nil ? 0 : 1
        activeTailMinimumLevel = seed ?? 1
        activeTailMaximumLevel = seed ?? 0
        activeTailMovement = 0
        previousActiveTailLevel = seed
        isMutingStableTail = false
    }

    private mutating func releaseSpeech(reason: ConversationInputGateReleaseReason) {
        speechIsActive = false
        candidateVoiceFrames = 0
        candidateWindowFrames = 0
        candidateGapFrames = 0
        candidateActivationThreshold = 0
        trailingSilenceFrames = 0
        resetCandidateProfile()
        resetActiveTailProfile()
        endpointSilenceFramesRemaining = Self.maximumEndpointSilenceFrames
        pendingTransitions.append(.speechReleased(reason: reason))
    }

    private mutating func endpointSilenceOutput(for chunk: AudioChunk) -> [AudioChunk] {
        guard endpointSilenceFramesRemaining > 0 else { return [] }

        endpointSilenceFramesRemaining = max(
            0,
            endpointSilenceFramesRemaining - chunk.frameCount
        )
        if endpointSilenceFramesRemaining == 0 {
            pendingTransitions.append(.endpointSilenceExhausted)
        }
        return [silenced(chunk)]
    }

    private func silenced(_ chunk: AudioChunk) -> AudioChunk {
        AudioChunk(
            pcm16: Data(repeating: 0, count: chunk.pcm16.count),
            sampleRate: chunk.sampleRate,
            channelCount: chunk.channelCount,
            frameCount: chunk.frameCount,
            normalizedLevel: 0,
            waveformLevels: Array(repeating: 0, count: AudioChunk.waveformLevelCount)
        )
    }
}

enum ConversationInputForwardingPolicy {
    static func realtimeChunks(
        endpointMode: ConversationEndpointMode,
        assistantIsActive: Bool,
        supportsEchoCancelledInterruption: Bool,
        capturedChunk: AudioChunk,
        gatedChunks: [AudioChunk]
    ) -> [AudioChunk] {
        switch endpointMode {
        case .providerVAD:
            if !assistantIsActive {
                return [capturedChunk]
            }
            return supportsEchoCancelledInterruption ? gatedChunks : []
        case .clientGate:
            return gatedChunks
        }
    }
}

@MainActor
protocol ConversationAudioServicing: AnyObject {
    var onInputChunk: ((AudioChunk) -> Void)? { get set }
    var onInputLevels: ((ConversationAudioLevels) -> Void)? { get set }
    var onInputGateTransition: ((ConversationInputGateTransition) -> Void)? { get set }
    var onOutputLevels: ((ConversationAudioLevels) -> Void)? { get set }
    var onPlaybackFinished: (() -> Void)? { get set }
    var onFailure: ((Error) -> Void)? { get set }
    var isRunning: Bool { get }
    var hasConfirmedInterruption: Bool { get }

    func configureInputForwarding(
        endpointMode: ConversationEndpointMode,
        allowsResponseInterruption: Bool
    )
    func start() async throws
    func completeUserTurnEndpoint()
    func resetUserInput()
    func prepareForAssistantResponse()
    func finishAssistantPreparation(preserveActiveSpeech: Bool)
    func beginAssistantResponse()
    func enqueueAssistantAudio(_ data: Data)
    func markAssistantAudioFinished()
    func stopAssistantPlayback() -> Int
    func stop()
}

extension ConversationAudioServicing {
    var hasConfirmedInterruption: Bool { false }
    func configureInputForwarding(
        endpointMode: ConversationEndpointMode,
        allowsResponseInterruption: Bool
    ) {}
    func completeUserTurnEndpoint() {}
    func resetUserInput() {}
    func prepareForAssistantResponse() {}
    func finishAssistantPreparation(preserveActiveSpeech: Bool) {}
}

@MainActor
final class ConversationAudioService: ConversationAudioServicing {
    enum AudioError: LocalizedError {
        case permissionDenied
        case unavailableInput
        case unavailableOutput
        case engineStartFailed(String)
        case configurationChanged

        var errorDescription: String? {
            switch self {
            case .permissionDenied:
                return "请先允许 Olli 使用麦克风。"
            case .unavailableInput:
                return "没有找到可用于对话的麦克风。"
            case .unavailableOutput:
                return "没有找到可用于播放 Olli 声音的设备。"
            case .engineStartFailed:
                return "Olli 无法启动 Mac 音频设备，请稍后重试。"
            case .configurationChanged:
                return "音频设备发生变化，本次对话已安全结束，请重新开始。"
            }
        }
    }

    var onInputChunk: ((AudioChunk) -> Void)?
    var onInputLevels: ((ConversationAudioLevels) -> Void)?
    var onInputGateTransition: ((ConversationInputGateTransition) -> Void)?
    var onOutputLevels: ((ConversationAudioLevels) -> Void)?
    var onPlaybackFinished: (() -> Void)?
    var onFailure: ((Error) -> Void)?

    private enum ActiveBackend {
        case stopped
        case voiceProcessing
        case halfDuplex
    }

    private var voiceProcessingIO: VoiceProcessingAudioUnit?
    private var engine = AVAudioEngine()
    private var playerNode = AVAudioPlayerNode()
    private let playbackFormat = AVAudioFormat(
        commonFormat: .pcmFormatFloat32,
        sampleRate: 24_000,
        channels: 1,
        interleaved: false
    )!
    private var tapInstalled = false
    private var playerAttached = false
    private var pendingPlaybackBuffers = 0
    private var playbackGeneration = 0
    private var serverFinishedAudio = false
    private var playbackStartedAt: ContinuousClock.Instant?
    private var scheduledPlaybackFrames: Int64 = 0
    private var activeVoicePlaybackGeneration: UInt64?
    private var expectsEngineToRun = false
    private var activeBackend = ActiveBackend.stopped
    private var inputGate = ConversationInputGate()
    private var endpointMode: ConversationEndpointMode = .providerVAD
    private var allowsResponseInterruption = false
    private var configurationObserver: NSObjectProtocol?
    private let clock = ContinuousClock()
    private let logger = Logger(subsystem: "com.example.Friday", category: "TalkAudio")

    init() {
        configurationObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            Task { @MainActor [weak self] in
                self?.handleConfigurationChange(notification)
            }
        }
    }

    deinit {
        if let configurationObserver {
            NotificationCenter.default.removeObserver(configurationObserver)
        }
    }

    var isRunning: Bool {
        voiceProcessingIO?.isRunning == true || engine.isRunning
    }

    var hasConfirmedInterruption: Bool {
        inputGate.hasConfirmedInterruption
    }

    func configureInputForwarding(
        endpointMode: ConversationEndpointMode,
        allowsResponseInterruption: Bool
    ) {
        let didChange = self.endpointMode != endpointMode
            || self.allowsResponseInterruption != allowsResponseInterruption
        self.endpointMode = endpointMode
        self.allowsResponseInterruption = allowsResponseInterruption
        if didChange, isRunning {
            inputGate.reset()
        }
    }

    func start() async throws {
        guard !isRunning else { return }
        guard await hasMicrophonePermission() else { throw AudioError.permissionDenied }
        try Task.checkCancellation()

        let voiceIO = VoiceProcessingAudioUnit()
        configureVoiceProcessingCallbacks(voiceIO)
        do {
            try voiceIO.start()
            voiceProcessingIO = voiceIO
            activeBackend = .voiceProcessing
            expectsEngineToRun = true
            inputGate.reset()
            logger.notice("Talk audio started with VoiceProcessingIO full-duplex AEC")
            return
        } catch {
            voiceIO.stop()
            logger.warning(
                "VoiceProcessingIO unavailable; using safe half-duplex fallback: \(String(reflecting: error), privacy: .public)"
            )
        }

        try Task.checkCancellation()
        do {
            try configureAndStartHalfDuplexEngine()
            activeBackend = .halfDuplex
            expectsEngineToRun = true
            inputGate.reset()
            logger.notice("Talk audio started with the safe half-duplex fallback")
        } catch {
            teardownFallbackEngine(rebuild: true)
            throw error
        }
    }

    private func configureAndStartHalfDuplexEngine() throws {
        engine.reset()

        let inputNode = engine.inputNode
        let outputNode = engine.outputNode

        let hardwareInputFormat = inputNode.inputFormat(forBus: 0)
        let inputFormat = inputNode.outputFormat(forBus: 0)
        guard ConversationAudioFormatValidator.isUsable(hardwareInputFormat),
              ConversationAudioFormatValidator.isUsable(inputFormat),
              let realtimeFormat = AVAudioFormat(
                commonFormat: .pcmFormatInt16,
                sampleRate: 24_000,
                channels: 1,
                interleaved: true
              ),
              let converter = AVAudioConverter(from: inputFormat, to: realtimeFormat) else {
            throw AudioError.unavailableInput
        }

        let outputFormat = outputNode.inputFormat(forBus: 0)
        guard ConversationAudioFormatValidator.isUsable(outputFormat) else {
            throw AudioError.unavailableOutput
        }

        if !playerAttached {
            engine.attach(playerNode)
            engine.connect(playerNode, to: engine.mainMixerNode, format: playbackFormat)
            playerAttached = true
        }

        inputNode.installTap(
            onBus: 0,
            bufferSize: MicrophoneCaptureService.bufferSize,
            format: inputFormat
        ) { [weak self] buffer, _ in
            guard let self,
                  let channelData = buffer.floatChannelData?[0],
                  let data = Self.convertToRealtimePCM16(
                    buffer,
                    converter: converter,
                    outputFormat: realtimeFormat
                  ) else { return }

            let frameCount = Int(buffer.frameLength)
            let levels = ConversationAudioLevels(
                level: AudioLevelMeter.normalizedLevel(
                    samples: channelData,
                    count: frameCount
                ),
                waveformLevels: AudioLevelMeter.waveformLevels(
                    samples: channelData,
                    count: frameCount
                )
            )
            let chunk = AudioChunk(
                pcm16: data,
                sampleRate: 24_000,
                channelCount: 1,
                frameCount: data.count / MemoryLayout<Int16>.size,
                normalizedLevel: levels.level,
                waveformLevels: levels.waveformLevels
            )

            Task { @MainActor [weak self] in
                guard let self else { return }
                handleCapturedChunk(chunk, levels: levels)
            }
        }
        tapInstalled = true

        do {
            engine.prepare()
            try engine.start()
            guard engine.isRunning else {
                throw AudioError.engineStartFailed("Engine did not enter the running state")
            }
            playerNode.play()
        } catch {
            if tapInstalled {
                inputNode.removeTap(onBus: 0)
                tapInstalled = false
            }
            if error is AudioError {
                throw error
            }
            throw AudioError.engineStartFailed(error.localizedDescription)
        }
    }

    private func configureVoiceProcessingCallbacks(_ voiceIO: VoiceProcessingAudioUnit) {
        voiceIO.onCapturedPCM24 = { [weak self] data in
            Task { @MainActor [weak self] in
                self?.handleVoiceProcessingCapture(data)
            }
        }
        voiceIO.onPlaybackStarted = { [weak self] generation in
            Task { @MainActor [weak self] in
                guard let self,
                      activeBackend == .voiceProcessing,
                      activeVoicePlaybackGeneration == generation else { return }
                if playbackStartedAt == nil {
                    playbackStartedAt = clock.now
                }
            }
        }
        voiceIO.onPlaybackDrained = { [weak self] generation in
            Task { @MainActor [weak self] in
                self?.finishVoiceProcessingPlaybackIfNeeded(generation: generation)
            }
        }
        voiceIO.onRuntimeFailure = { [weak self] error in
            Task { @MainActor [weak self] in
                guard let self, activeBackend == .voiceProcessing else { return }
                logger.error(
                    "VoiceProcessingIO runtime failure: \(String(reflecting: error), privacy: .public)"
                )
                expectsEngineToRun = false
                onFailure?(AudioError.configurationChanged)
            }
        }
    }

    private func handleVoiceProcessingCapture(_ data: Data) {
        guard activeBackend == .voiceProcessing,
              voiceProcessingIO?.isRunning == true else { return }
        let levels = ConversationPCM16Meter.levels(for: data)
        let chunk = AudioChunk(
            pcm16: data,
            sampleRate: 24_000,
            channelCount: 1,
            frameCount: data.count / MemoryLayout<Int16>.size,
            normalizedLevel: levels.level,
            waveformLevels: levels.waveformLevels
        )
        handleCapturedChunk(chunk, levels: levels)
    }

    private func handleCapturedChunk(
        _ chunk: AudioChunk,
        levels: ConversationAudioLevels
    ) {
        let gatedChunks = inputGate.inputForRealtime(chunk)
        let realtimeChunks = ConversationInputForwardingPolicy.realtimeChunks(
            endpointMode: endpointMode,
            assistantIsActive: inputGate.isAssistantPlaying,
            supportsEchoCancelledInterruption: activeBackend == .voiceProcessing
                && allowsResponseInterruption,
            capturedChunk: chunk,
            gatedChunks: gatedChunks
        )
        for realtimeChunk in realtimeChunks {
            onInputChunk?(realtimeChunk)
        }
        for transition in inputGate.takeTransitions() {
            onInputGateTransition?(transition)
        }
        onInputLevels?(levels)
    }

    func prepareForAssistantResponse() {
        // Mark Assistant activity before the first playback frame. The AEC path
        // can release locally confirmed speech with pre-roll; half-duplex stays
        // muted because it has no reliable echo reference.
        inputGate.beginAssistantPlayback(
            allowsInterruption: allowsResponseInterruption
        )
    }

    func completeUserTurnEndpoint() {
        inputGate.completeUserTurnEndpoint()
    }

    func resetUserInput() {
        inputGate.reset()
    }

    func finishAssistantPreparation(preserveActiveSpeech: Bool) {
        guard inputGate.isAssistantPlaying,
              scheduledPlaybackFrames == 0 else { return }
        if activeVoicePlaybackGeneration != nil {
            _ = voiceProcessingIO?.stopPlayback()
            activeVoicePlaybackGeneration = nil
        }
        resetPlaybackState()
        inputGate.finishAssistantPlayback(
            preserveActiveSpeech: preserveActiveSpeech
        )
        onOutputLevels?(Self.silentLevels)
    }

    func beginAssistantResponse() {
        serverFinishedAudio = false
        playbackStartedAt = nil
        scheduledPlaybackFrames = 0
        if activeBackend == .voiceProcessing {
            // Tighten the microphone gate before the first speaker frame. This
            // closes the network/audio race where echo could otherwise create
            // a speech-start event just as Friday begins replying.
            inputGate.beginAssistantPlayback(
                allowsInterruption: allowsResponseInterruption
            )
            activeVoicePlaybackGeneration = voiceProcessingIO?.beginResponse()
        } else {
            activeVoicePlaybackGeneration = nil
        }
    }

    func enqueueAssistantAudio(_ data: Data) {
        guard !data.isEmpty else { return }
        let outputLevels = ConversationPCM16Meter.levels(for: data)

        if activeBackend == .voiceProcessing,
           let voiceProcessingIO,
           voiceProcessingIO.isRunning {
            scheduledPlaybackFrames += Int64(
                data.count / MemoryLayout<Int16>.size
            )
            onOutputLevels?(outputLevels)
            voiceProcessingIO.enqueuePCM24(data)
            return
        }

        guard activeBackend == .halfDuplex,
              engine.isRunning,
              let buffer = makePlaybackBuffer(from: data),
              buffer.frameLength > 0 else { return }

        if !playerNode.isPlaying {
            playerNode.play()
        }
        if playbackStartedAt == nil {
            playbackStartedAt = clock.now
            inputGate.beginAssistantPlayback(allowsInterruption: false)
        }

        let generation = playbackGeneration
        pendingPlaybackBuffers += 1
        scheduledPlaybackFrames += Int64(buffer.frameLength)
        onOutputLevels?(outputLevels)
        playerNode.scheduleBuffer(
            buffer,
            completionCallbackType: .dataPlayedBack
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, generation == playbackGeneration else { return }
                pendingPlaybackBuffers = max(0, pendingPlaybackBuffers - 1)
                finishFallbackPlaybackIfReady()
            }
        }
    }

    func markAssistantAudioFinished() {
        serverFinishedAudio = true
        if activeBackend == .voiceProcessing {
            voiceProcessingIO?.markPlaybackFinished()
        } else {
            finishFallbackPlaybackIfReady()
        }
    }

    @discardableResult
    func stopAssistantPlayback() -> Int {
        let preserveActiveSpeech = inputGate.hasConfirmedSpeech
        let elapsedMilliseconds: Int

        if activeBackend == .voiceProcessing {
            elapsedMilliseconds = voiceProcessingIO?.stopPlayback() ?? 0
        } else {
            elapsedMilliseconds = fallbackPlaybackElapsedMilliseconds
            playbackGeneration += 1
            if playerAttached {
                playerNode.stop()
                playerNode.reset()
                if engine.isRunning {
                    playerNode.play()
                }
            }
        }

        resetPlaybackState()
        activeVoicePlaybackGeneration = nil
        inputGate.finishAssistantPlayback(
            preserveActiveSpeech: preserveActiveSpeech
        )
        onOutputLevels?(Self.silentLevels)
        return max(0, elapsedMilliseconds)
    }

    func stop() {
        expectsEngineToRun = false
        _ = stopAssistantPlayback()
        voiceProcessingIO?.stop()
        voiceProcessingIO = nil
        teardownFallbackEngine(rebuild: true)
        activeBackend = .stopped
        inputGate.reset()
        onInputLevels?(Self.silentLevels)
    }

    private func teardownFallbackEngine(rebuild: Bool) {
        expectsEngineToRun = false
        if tapInstalled {
            engine.inputNode.removeTap(onBus: 0)
            tapInstalled = false
        }
        if playerAttached {
            playerNode.stop()
            playerNode.reset()
        }
        if engine.isRunning {
            engine.stop()
        }
        engine.reset()
        resetPlaybackState()

        guard rebuild else { return }
        playbackGeneration += 1
        engine = AVAudioEngine()
        playerNode = AVAudioPlayerNode()
        playerAttached = false
    }

    private func handleConfigurationChange(_ notification: Notification) {
        guard activeBackend == .halfDuplex,
              expectsEngineToRun,
              let changedEngine = notification.object as? AVAudioEngine,
              changedEngine === engine else { return }
        expectsEngineToRun = false
        onFailure?(AudioError.configurationChanged)
    }

    private func finishFallbackPlaybackIfReady() {
        guard serverFinishedAudio, pendingPlaybackBuffers == 0 else { return }
        resetPlaybackState()
        inputGate.finishAssistantPlayback()
        onOutputLevels?(Self.silentLevels)
        onPlaybackFinished?()
    }

    private func finishVoiceProcessingPlaybackIfNeeded(generation: UInt64) {
        guard activeBackend == .voiceProcessing,
              activeVoicePlaybackGeneration == generation,
              serverFinishedAudio else { return }
        resetPlaybackState()
        activeVoicePlaybackGeneration = nil
        inputGate.finishAssistantPlayback()
        onOutputLevels?(Self.silentLevels)
        onPlaybackFinished?()
    }

    private var fallbackPlaybackElapsedMilliseconds: Int {
        guard let playbackStartedAt else { return 0 }
        let elapsed = playbackStartedAt.duration(to: clock.now)
        let components = elapsed.components
        let elapsedSeconds = Double(components.seconds)
            + Double(components.attoseconds) / 1_000_000_000_000_000_000
        let scheduledSeconds = Double(scheduledPlaybackFrames) / playbackFormat.sampleRate
        return Int(max(0, min(elapsedSeconds, scheduledSeconds)) * 1_000)
    }

    private func resetPlaybackState() {
        pendingPlaybackBuffers = 0
        serverFinishedAudio = false
        playbackStartedAt = nil
        scheduledPlaybackFrames = 0
    }

    private static let silentLevels = ConversationAudioLevels(
        level: 0,
        waveformLevels: Array(repeating: 0, count: AudioChunk.waveformLevelCount)
    )

    private func makePlaybackBuffer(from data: Data) -> AVAudioPCMBuffer? {
        let sampleCount = data.count / MemoryLayout<Int16>.size
        guard sampleCount > 0,
              let buffer = AVAudioPCMBuffer(
                pcmFormat: playbackFormat,
                frameCapacity: AVAudioFrameCount(sampleCount)
              ),
              let channel = buffer.floatChannelData?[0] else { return nil }

        buffer.frameLength = AVAudioFrameCount(sampleCount)
        data.withUnsafeBytes { rawBuffer in
            let samples = rawBuffer.bindMemory(to: Int16.self)
            for index in 0..<sampleCount {
                channel[index] = Float(Int16(littleEndian: samples[index])) / Float(Int16.max)
            }
        }
        return buffer
    }

    private func hasMicrophonePermission() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            return true
        case .notDetermined:
            return await withCheckedContinuation { continuation in
                AVCaptureDevice.requestAccess(for: .audio) { granted in
                    continuation.resume(returning: granted)
                }
            }
        case .denied, .restricted:
            return false
        @unknown default:
            return false
        }
    }

    private nonisolated static func convertToRealtimePCM16(
        _ inputBuffer: AVAudioPCMBuffer,
        converter: AVAudioConverter,
        outputFormat: AVAudioFormat
    ) -> Data? {
        let sampleRateRatio = outputFormat.sampleRate / inputBuffer.format.sampleRate
        let outputCapacity = AVAudioFrameCount(
            ceil(Double(inputBuffer.frameLength) * sampleRateRatio) + 32
        )
        guard let outputBuffer = AVAudioPCMBuffer(
            pcmFormat: outputFormat,
            frameCapacity: outputCapacity
        ) else { return nil }

        var suppliedInput = false
        var conversionError: NSError?
        let status = converter.convert(to: outputBuffer, error: &conversionError) { _, inputStatus in
            if suppliedInput {
                inputStatus.pointee = .noDataNow
                return nil
            }
            suppliedInput = true
            inputStatus.pointee = .haveData
            return inputBuffer
        }

        guard conversionError == nil,
              status != .error,
              outputBuffer.frameLength > 0 else { return nil }

        let audioBuffer = outputBuffer.audioBufferList.pointee.mBuffers
        guard let bytes = audioBuffer.mData, audioBuffer.mDataByteSize > 0 else { return nil }
        return Data(bytes: bytes, count: Int(audioBuffer.mDataByteSize))
    }
}
