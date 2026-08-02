// 功能：为 Talk 同时采集用户麦克风并播放 Friday 的流式语音，提供可插话的全双工音频通道。
// 职责：管理 AVAudioEngine 生命周期、Voice Processing 回退、PCM16 转换、播放队列、音频路由变化、回声抑制、插话门控和双向音量输出。
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

struct AssistantBargeInGate {
    private(set) var isActive = false
    private(set) var hasDetectedNearbySpeech = false
    private var echoBaseline: Float = 0.18
    private var observedFrames = 0
    private var candidateVoiceFrames = 0
    private var preRoll: [AudioChunk] = []
    private var preRollFrameCount = 0
    private var echoTailFramesRemaining = 0

    private static let sampleRate = 24_000
    private static let maximumPreRollFrames = Int(Double(sampleRate) * 0.32)
    private static let baselineWarmupFrames = Int(Double(sampleRate) * 0.10)
    private static let minimumCandidateFrames = Int(Double(sampleRate) * 0.075)
    private static let echoTailFrames = Int(Double(sampleRate) * 0.20)

    mutating func beginAssistantOutput() {
        isActive = true
        hasDetectedNearbySpeech = false
        echoBaseline = 0.18
        observedFrames = 0
        candidateVoiceFrames = 0
        preRoll.removeAll(keepingCapacity: true)
        preRollFrameCount = 0
        echoTailFramesRemaining = 0
    }

    mutating func inputForRealtime(_ chunk: AudioChunk) -> [AudioChunk] {
        guard isActive else { return [chunk] }
        if hasDetectedNearbySpeech { return [chunk] }

        preRoll.append(chunk)
        preRollFrameCount += chunk.frameCount
        while preRollFrameCount > Self.maximumPreRollFrames, !preRoll.isEmpty {
            preRollFrameCount -= preRoll.removeFirst().frameCount
        }

        observedFrames += chunk.frameCount
        if observedFrames <= Self.baselineWarmupFrames {
            echoBaseline = max(echoBaseline, chunk.normalizedLevel)
        } else if chunk.normalizedLevel <= echoBaseline + 0.08 {
            echoBaseline = echoBaseline * 0.88 + chunk.normalizedLevel * 0.12
        }

        let threshold = min(0.58, max(0.32, echoBaseline + 0.11))
        if echoTailFramesRemaining > 0 {
            echoTailFramesRemaining = max(
                0,
                echoTailFramesRemaining - chunk.frameCount
            )
            if echoTailFramesRemaining == 0,
               chunk.normalizedLevel < threshold {
                finishAssistantOutput()
            }
            return []
        }

        if observedFrames >= Self.baselineWarmupFrames,
           chunk.normalizedLevel >= threshold {
            candidateVoiceFrames += chunk.frameCount
        } else {
            candidateVoiceFrames = max(0, candidateVoiceFrames - chunk.frameCount * 2)
        }

        guard candidateVoiceFrames >= Self.minimumCandidateFrames else { return [] }
        hasDetectedNearbySpeech = true
        let released = preRoll
        preRoll.removeAll(keepingCapacity: true)
        preRollFrameCount = 0
        return released
    }

    mutating func finishAssistantOutput(suppressEchoTail: Bool = false) {
        isActive = suppressEchoTail
        hasDetectedNearbySpeech = false
        if !suppressEchoTail {
            echoBaseline = 0.18
            observedFrames = 0
        }
        candidateVoiceFrames = 0
        preRoll.removeAll(keepingCapacity: true)
        preRollFrameCount = 0
        echoTailFramesRemaining = suppressEchoTail ? Self.echoTailFrames : 0
    }
}

@MainActor
protocol ConversationAudioServicing: AnyObject {
    var onInputChunk: ((AudioChunk) -> Void)? { get set }
    var onInputLevels: ((ConversationAudioLevels) -> Void)? { get set }
    var onOutputLevels: ((ConversationAudioLevels) -> Void)? { get set }
    var onPlaybackFinished: (() -> Void)? { get set }
    var onFailure: ((Error) -> Void)? { get set }
    var isRunning: Bool { get }

    func start() async throws
    func beginAssistantResponse()
    func enqueueAssistantAudio(_ data: Data)
    func markAssistantAudioFinished()
    func stopAssistantPlayback() -> Int
    func stop()
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
                return "请先允许 Friday 使用麦克风。"
            case .unavailableInput:
                return "没有找到可用于对话的麦克风。"
            case .unavailableOutput:
                return "没有找到可用于播放 Friday 声音的设备。"
            case .engineStartFailed:
                return "Friday 无法启动 Mac 音频设备，请稍后重试。"
            case .configurationChanged:
                return "音频设备发生变化，本次对话已安全结束，请重新开始。"
            }
        }
    }

    var onInputChunk: ((AudioChunk) -> Void)?
    var onInputLevels: ((ConversationAudioLevels) -> Void)?
    var onOutputLevels: ((ConversationAudioLevels) -> Void)?
    var onPlaybackFinished: (() -> Void)?
    var onFailure: ((Error) -> Void)?

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
    private var expectsEngineToRun = false
    private var prefersStandardFullDuplex = false
    private var usesSoftwareEchoGate = false
    private var bargeInGate = AssistantBargeInGate()
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
        engine.isRunning
    }

    func start() async throws {
        guard !engine.isRunning else { return }
        guard await hasMicrophonePermission() else { throw AudioError.permissionDenied }
        try Task.checkCancellation()

        var lastError: Error = AudioError.engineStartFailed("Unknown audio engine failure")
        let voiceProcessingModes = prefersStandardFullDuplex
            ? [false, true]
            : [true, false]
        for (attempt, enableVoiceProcessing) in voiceProcessingModes.enumerated() {
            do {
                try configureAndStartEngine(enableVoiceProcessing: enableVoiceProcessing)
                expectsEngineToRun = true
                prefersStandardFullDuplex = !enableVoiceProcessing
                usesSoftwareEchoGate = !enableVoiceProcessing
                if !enableVoiceProcessing {
                    logger.notice("Talk audio started with the standard full-duplex fallback")
                }
                return
            } catch {
                lastError = error
                logger.warning(
                    "Talk audio start attempt \(attempt + 1) failed: \(String(reflecting: error), privacy: .public)"
                )
                teardownEngine(rebuild: true)
                guard attempt == 0 else { break }
                try await Task.sleep(for: .milliseconds(180))
                try Task.checkCancellation()
            }
        }

        throw lastError
    }

    private func configureAndStartEngine(enableVoiceProcessing: Bool) throws {
        engine.reset()

        let inputNode = engine.inputNode
        let outputNode = engine.outputNode
        if enableVoiceProcessing {
            do {
                try inputNode.setVoiceProcessingEnabled(true)
            } catch {
                throw AudioError.engineStartFailed(
                    "Voice processing setup failed: \(error.localizedDescription)"
                )
            }
        }

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
                let realtimeChunks = usesSoftwareEchoGate
                    ? bargeInGate.inputForRealtime(chunk)
                    : [chunk]
                for realtimeChunk in realtimeChunks {
                    onInputChunk?(realtimeChunk)
                }
                onInputLevels?(levels)
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

    func beginAssistantResponse() {
        serverFinishedAudio = false
        playbackStartedAt = nil
        scheduledPlaybackFrames = 0
    }

    func enqueueAssistantAudio(_ data: Data) {
        guard engine.isRunning,
              let buffer = makePlaybackBuffer(from: data),
              buffer.frameLength > 0 else { return }

        if !playerNode.isPlaying {
            playerNode.play()
        }
        if playbackStartedAt == nil {
            playbackStartedAt = clock.now
        }

        let outputLevels = ConversationPCM16Meter.levels(for: data)
        if usesSoftwareEchoGate {
            if !bargeInGate.isActive {
                bargeInGate.beginAssistantOutput()
            }
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
                finishPlaybackIfReady()
            }
        }
    }

    func markAssistantAudioFinished() {
        serverFinishedAudio = true
        finishPlaybackIfReady()
    }

    @discardableResult
    func stopAssistantPlayback() -> Int {
        let elapsedMilliseconds: Int
        if let playbackStartedAt {
            let elapsed = playbackStartedAt.duration(to: clock.now)
            let components = elapsed.components
            let elapsedSeconds = Double(components.seconds)
                + Double(components.attoseconds) / 1_000_000_000_000_000_000
            let scheduledSeconds = Double(scheduledPlaybackFrames) / playbackFormat.sampleRate
            elapsedMilliseconds = Int(max(0, min(elapsedSeconds, scheduledSeconds)) * 1_000)
        } else {
            elapsedMilliseconds = 0
        }

        playbackGeneration += 1
        if playerAttached {
            playerNode.stop()
            playerNode.reset()
            if engine.isRunning {
                playerNode.play()
            }
        }
        resetPlaybackState()
        bargeInGate.finishAssistantOutput()
        onOutputLevels?(
            ConversationAudioLevels(
                level: 0,
                waveformLevels: Array(repeating: 0, count: AudioChunk.waveformLevelCount)
            )
        )
        return elapsedMilliseconds
    }

    func stop() {
        expectsEngineToRun = false
        _ = stopAssistantPlayback()
        teardownEngine(rebuild: true)
        onInputLevels?(
            ConversationAudioLevels(
                level: 0,
                waveformLevels: Array(repeating: 0, count: AudioChunk.waveformLevelCount)
            )
        )
    }

    private func teardownEngine(rebuild: Bool) {
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
        bargeInGate.finishAssistantOutput()
        usesSoftwareEchoGate = false

        guard rebuild else { return }
        playbackGeneration += 1
        engine = AVAudioEngine()
        playerNode = AVAudioPlayerNode()
        playerAttached = false
    }

    private func handleConfigurationChange(_ notification: Notification) {
        guard expectsEngineToRun,
              let changedEngine = notification.object as? AVAudioEngine,
              changedEngine === engine else { return }
        expectsEngineToRun = false
        onFailure?(AudioError.configurationChanged)
    }

    private func finishPlaybackIfReady() {
        guard serverFinishedAudio, pendingPlaybackBuffers == 0 else { return }
        resetPlaybackState()
        bargeInGate.finishAssistantOutput(suppressEchoTail: usesSoftwareEchoGate)
        onOutputLevels?(
            ConversationAudioLevels(
                level: 0,
                waveformLevels: Array(repeating: 0, count: AudioChunk.waveformLevelCount)
            )
        )
        onPlaybackFinished?()
    }

    private func resetPlaybackState() {
        pendingPlaybackBuffers = 0
        serverFinishedAudio = false
        playbackStartedAt = nil
        scheduledPlaybackFrames = 0
    }

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
