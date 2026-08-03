// 功能：为 Talk 提供基于 macOS VoiceProcessingIO 的原生双向音频通道和系统级回声消除。
// 职责：连接播放参考与消回声麦克风总线，在 48 kHz AudioUnit 与 24 kHz Realtime PCM16 之间转换，并回报真实播放边界。
// 边界：不判断用户意图、不连接网络、不保存音频；无法初始化时由上层选择安全的半双工降级路径。

@preconcurrency import AudioToolbox
import Foundation

final class VoiceProcessingAudioUnit: @unchecked Sendable {
    struct AudioUnitError: LocalizedError {
        let operation: String
        let status: OSStatus

        var errorDescription: String? {
            let systemMessage = NSError(
                domain: NSOSStatusErrorDomain,
                code: Int(status)
            ).localizedDescription
            return "\(operation)失败（\(status)）：\(systemMessage)"
        }
    }

    var onCapturedPCM24: (@Sendable (Data) -> Void)?
    var onPlaybackStarted: (@Sendable (UInt64) -> Void)?
    var onPlaybackDrained: (@Sendable (UInt64) -> Void)?
    var onRuntimeFailure: (@Sendable (Error) -> Void)?

    private static let voiceSampleRate = 48_000.0
    private static let transportSampleRate = 24_000.0
    private static let captureFramesPerChunk = 2_048

    private let lifecycleLock = NSLock()
    private let playbackLock = NSLock()
    private let captureQueue = DispatchQueue(
        label: "com.example.Friday.voice-processing.capture",
        qos: .userInteractive
    )
    private var audioUnit: AudioUnit?
    private var started = false
    private var runtimeFailureReported = false

    private var playbackSamples: [Int16] = []
    private var playbackReadIndex = 0
    private var playbackFinishedByServer = false
    private var playbackDidStart = false
    private var playbackDrainCallbacksRemaining = 0
    private var playbackCompletionDelivered = false
    private var playedVoiceFrames: Int64 = 0
    private var playbackGeneration: UInt64 = 0

    private var capturedVoiceSamples: [Int16] = []
    private var capturedVoiceReadIndex = 0

    var isRunning: Bool {
        lifecycleLock.lock()
        defer { lifecycleLock.unlock() }
        return started
    }

    func start() throws {
        guard !isRunning else { return }

        var description = AudioComponentDescription(
            componentType: kAudioUnitType_Output,
            componentSubType: kAudioUnitSubType_VoiceProcessingIO,
            componentManufacturer: kAudioUnitManufacturer_Apple,
            componentFlags: 0,
            componentFlagsMask: 0
        )
        guard let component = AudioComponentFindNext(nil, &description) else {
            throw AudioUnitError(
                operation: "查找 VoiceProcessingIO",
                status: kAudioUnitErr_FailedInitialization
            )
        }

        var createdUnit: AudioUnit?
        try check(
            AudioComponentInstanceNew(component, &createdUnit),
            operation: "创建 VoiceProcessingIO"
        )
        guard let createdUnit else {
            throw AudioUnitError(
                operation: "创建 VoiceProcessingIO",
                status: kAudioUnitErr_FailedInitialization
            )
        }

        do {
            var enabled: UInt32 = 1
            try check(
                AudioUnitSetProperty(
                    createdUnit,
                    kAudioOutputUnitProperty_EnableIO,
                    kAudioUnitScope_Input,
                    1,
                    &enabled,
                    UInt32(MemoryLayout<UInt32>.size)
                ),
                operation: "启用 VoiceProcessingIO 麦克风"
            )

            var format = Self.pcm16Format(sampleRate: Self.voiceSampleRate)
            let formatSize = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
            try check(
                AudioUnitSetProperty(
                    createdUnit,
                    kAudioUnitProperty_StreamFormat,
                    kAudioUnitScope_Input,
                    0,
                    &format,
                    formatSize
                ),
                operation: "设置 VoiceProcessingIO 播放格式"
            )
            try check(
                AudioUnitSetProperty(
                    createdUnit,
                    kAudioUnitProperty_StreamFormat,
                    kAudioUnitScope_Output,
                    1,
                    &format,
                    formatSize
                ),
                operation: "设置 VoiceProcessingIO 录音格式"
            )

            var playbackHandler = AURenderCallbackStruct(
                inputProc: voiceProcessingPlaybackCallback,
                inputProcRefCon: Unmanaged.passUnretained(self).toOpaque()
            )
            try check(
                AudioUnitSetProperty(
                    createdUnit,
                    kAudioUnitProperty_SetRenderCallback,
                    kAudioUnitScope_Input,
                    0,
                    &playbackHandler,
                    UInt32(MemoryLayout<AURenderCallbackStruct>.size)
                ),
                operation: "连接 VoiceProcessingIO 播放参考"
            )

            var captureHandler = AURenderCallbackStruct(
                inputProc: voiceProcessingCaptureCallback,
                inputProcRefCon: Unmanaged.passUnretained(self).toOpaque()
            )
            try check(
                AudioUnitSetProperty(
                    createdUnit,
                    kAudioOutputUnitProperty_SetInputCallback,
                    kAudioUnitScope_Global,
                    1,
                    &captureHandler,
                    UInt32(MemoryLayout<AURenderCallbackStruct>.size)
                ),
                operation: "连接 VoiceProcessingIO 消回声麦克风"
            )

            try check(
                AudioUnitInitialize(createdUnit),
                operation: "初始化 VoiceProcessingIO"
            )

            lifecycleLock.lock()
            audioUnit = createdUnit
            started = true
            runtimeFailureReported = false
            lifecycleLock.unlock()

            do {
                try check(
                    AudioOutputUnitStart(createdUnit),
                    operation: "启动 VoiceProcessingIO"
                )
            } catch {
                lifecycleLock.lock()
                started = false
                audioUnit = nil
                lifecycleLock.unlock()
                AudioUnitUninitialize(createdUnit)
                throw error
            }
        } catch {
            AudioComponentInstanceDispose(createdUnit)
            throw error
        }
    }

    @discardableResult
    func beginResponse() -> UInt64 {
        playbackLock.lock()
        playbackGeneration &+= 1
        let generation = playbackGeneration
        playbackSamples.removeAll(keepingCapacity: true)
        playbackReadIndex = 0
        playbackFinishedByServer = false
        playbackDidStart = false
        playbackDrainCallbacksRemaining = 0
        playbackCompletionDelivered = false
        playedVoiceFrames = 0
        playbackLock.unlock()
        return generation
    }

    func enqueuePCM24(_ data: Data) {
        let transportSamples = Self.decodePCM16(data)
        guard !transportSamples.isEmpty else { return }
        let voiceSamples = Self.upsampleByTwo(transportSamples)

        playbackLock.lock()
        compactPlaybackIfNeeded()
        playbackSamples.append(contentsOf: voiceSamples)
        playbackLock.unlock()
    }

    func markPlaybackFinished() {
        var deliverImmediately = false
        var completedGeneration: UInt64 = 0
        playbackLock.lock()
        playbackFinishedByServer = true
        if playbackReadIndex >= playbackSamples.count,
           !playbackDidStart,
           !playbackCompletionDelivered {
            playbackCompletionDelivered = true
            deliverImmediately = true
            completedGeneration = playbackGeneration
        }
        playbackLock.unlock()

        if deliverImmediately {
            onPlaybackDrained?(completedGeneration)
        }
    }

    @discardableResult
    func stopPlayback() -> Int {
        playbackLock.lock()
        let elapsedMilliseconds = Int(
            Double(playedVoiceFrames) / Self.voiceSampleRate * 1_000
        )
        playbackGeneration &+= 1
        playbackSamples.removeAll(keepingCapacity: true)
        playbackReadIndex = 0
        playbackFinishedByServer = false
        playbackDidStart = false
        playbackDrainCallbacksRemaining = 0
        playbackCompletionDelivered = false
        playedVoiceFrames = 0
        playbackLock.unlock()
        return max(0, elapsedMilliseconds)
    }

    func stop() {
        lifecycleLock.lock()
        let unit = audioUnit
        started = false
        audioUnit = nil
        lifecycleLock.unlock()

        if let unit {
            AudioOutputUnitStop(unit)
            AudioUnitUninitialize(unit)
            AudioComponentInstanceDispose(unit)
        }

        playbackLock.lock()
        playbackSamples.removeAll(keepingCapacity: false)
        playbackReadIndex = 0
        playbackFinishedByServer = false
        playbackDidStart = false
        playbackDrainCallbacksRemaining = 0
        playbackCompletionDelivered = false
        playedVoiceFrames = 0
        playbackLock.unlock()

        captureQueue.sync {
            capturedVoiceSamples.removeAll(keepingCapacity: false)
            capturedVoiceReadIndex = 0
        }
    }

    fileprivate func renderPlayback(
        frameCount: UInt32,
        buffers: UnsafeMutablePointer<AudioBufferList>?
    ) -> OSStatus {
        guard let buffers else { return noErr }

        var didStart = false
        var didDrain = false
        var signaledGeneration: UInt64 = 0
        let list = UnsafeMutableAudioBufferListPointer(buffers)

        playbackLock.lock()
        for bufferIndex in list.indices {
            let buffer = list[bufferIndex]
            guard let rawData = buffer.mData else { continue }
            let capacity = Int(buffer.mDataByteSize) / MemoryLayout<Int16>.size
            let requested = min(Int(frameCount), capacity)
            let destination = rawData.bindMemory(to: Int16.self, capacity: capacity)
            destination.initialize(repeating: 0, count: capacity)

            let available = max(0, playbackSamples.count - playbackReadIndex)
            let copied = min(requested, available)
            if copied > 0 {
                playbackSamples.withUnsafeBufferPointer { source in
                    guard let sourceBase = source.baseAddress else { return }
                    destination.update(
                        from: sourceBase.advanced(by: playbackReadIndex),
                        count: copied
                    )
                }
                playbackReadIndex += copied
                playedVoiceFrames += Int64(copied)
                if !playbackDidStart {
                    playbackDidStart = true
                    didStart = true
                    signaledGeneration = playbackGeneration
                }
            }

            if playbackFinishedByServer,
               playbackReadIndex >= playbackSamples.count,
               !playbackCompletionDelivered {
                if copied > 0 {
                    playbackDrainCallbacksRemaining = 1
                } else if playbackDrainCallbacksRemaining > 0 {
                    playbackDrainCallbacksRemaining -= 1
                    if playbackDrainCallbacksRemaining == 0 {
                        playbackCompletionDelivered = true
                        didDrain = true
                        signaledGeneration = playbackGeneration
                    }
                } else if playbackDidStart {
                    playbackCompletionDelivered = true
                    didDrain = true
                    signaledGeneration = playbackGeneration
                }
            }
        }
        compactPlaybackIfNeeded()
        playbackLock.unlock()

        if didStart {
            onPlaybackStarted?(signaledGeneration)
        }
        if didDrain {
            onPlaybackDrained?(signaledGeneration)
        }
        return noErr
    }

    fileprivate func capture(
        flags: UnsafeMutablePointer<AudioUnitRenderActionFlags>,
        timestamp: UnsafePointer<AudioTimeStamp>,
        frameCount: UInt32
    ) -> OSStatus {
        lifecycleLock.lock()
        let unit = audioUnit
        let shouldCapture = started
        lifecycleLock.unlock()
        guard let unit, shouldCapture else { return noErr }

        var samples = [Int16](repeating: 0, count: Int(frameCount))
        let status = samples.withUnsafeMutableBytes { bytes -> OSStatus in
            var list = AudioBufferList(
                mNumberBuffers: 1,
                mBuffers: AudioBuffer(
                    mNumberChannels: 1,
                    mDataByteSize: UInt32(bytes.count),
                    mData: bytes.baseAddress
                )
            )
            return AudioUnitRender(
                unit,
                flags,
                timestamp,
                1,
                frameCount,
                &list
            )
        }

        guard status == noErr else {
            reportRuntimeFailure(status)
            return status
        }

        captureQueue.async { [weak self] in
            self?.processCapturedVoiceSamples(samples)
        }
        return noErr
    }

    private func processCapturedVoiceSamples(_ samples: [Int16]) {
        lifecycleLock.lock()
        let shouldProcess = started
        lifecycleLock.unlock()
        guard shouldProcess else { return }

        compactCaptureIfNeeded()
        capturedVoiceSamples.append(contentsOf: samples)

        var chunks: [Data] = []
        while capturedVoiceSamples.count - capturedVoiceReadIndex
                >= Self.captureFramesPerChunk {
            let end = capturedVoiceReadIndex + Self.captureFramesPerChunk
            let voiceChunk = Array(capturedVoiceSamples[capturedVoiceReadIndex..<end])
            capturedVoiceReadIndex = end
            var transportChunk = Self.downsampleByTwo(voiceChunk)
            let data = transportChunk.withUnsafeMutableBytes { Data($0) }
            chunks.append(data)
        }
        compactCaptureIfNeeded()

        for chunk in chunks {
            onCapturedPCM24?(chunk)
        }
    }

    private func reportRuntimeFailure(_ status: OSStatus) {
        var shouldReport = false
        lifecycleLock.lock()
        if !runtimeFailureReported {
            runtimeFailureReported = true
            shouldReport = true
        }
        lifecycleLock.unlock()

        guard shouldReport else { return }
        onRuntimeFailure?(
            AudioUnitError(operation: "读取 VoiceProcessingIO 麦克风", status: status)
        )
    }

    private func compactPlaybackIfNeeded() {
        if playbackReadIndex > 8_192,
           playbackReadIndex * 2 > playbackSamples.count {
            playbackSamples.removeFirst(playbackReadIndex)
            playbackReadIndex = 0
        }
    }

    private func compactCaptureIfNeeded() {
        if capturedVoiceReadIndex > 8_192,
           capturedVoiceReadIndex * 2 > capturedVoiceSamples.count {
            capturedVoiceSamples.removeFirst(capturedVoiceReadIndex)
            capturedVoiceReadIndex = 0
        }
    }

    private func check(_ status: OSStatus, operation: String) throws {
        guard status == noErr else {
            throw AudioUnitError(operation: operation, status: status)
        }
    }

    private static func pcm16Format(sampleRate: Double) -> AudioStreamBasicDescription {
        AudioStreamBasicDescription(
            mSampleRate: sampleRate,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked,
            mBytesPerPacket: UInt32(MemoryLayout<Int16>.size),
            mFramesPerPacket: 1,
            mBytesPerFrame: UInt32(MemoryLayout<Int16>.size),
            mChannelsPerFrame: 1,
            mBitsPerChannel: 16,
            mReserved: 0
        )
    }

    private static func decodePCM16(_ data: Data) -> [Int16] {
        let sampleCount = data.count / MemoryLayout<Int16>.size
        guard sampleCount > 0 else { return [] }
        return data.withUnsafeBytes { rawBuffer in
            let samples = rawBuffer.bindMemory(to: Int16.self)
            return (0..<sampleCount).map {
                Int16(littleEndian: samples[$0])
            }
        }
    }

    private static func upsampleByTwo(_ samples: [Int16]) -> [Int16] {
        guard !samples.isEmpty else { return [] }
        var result: [Int16] = []
        result.reserveCapacity(samples.count * 2)
        for index in samples.indices {
            let current = samples[index]
            let next = index + 1 < samples.count ? samples[index + 1] : current
            result.append(current)
            result.append(Int16((Int32(current) + Int32(next)) / 2))
        }
        return result
    }

    private static func downsampleByTwo(_ samples: [Int16]) -> [Int16] {
        guard samples.count >= 2 else { return [] }
        var result: [Int16] = []
        result.reserveCapacity(samples.count / 2)
        var index = 0
        while index + 1 < samples.count {
            result.append(
                Int16((Int32(samples[index]) + Int32(samples[index + 1])) / 2)
            )
            index += 2
        }
        return result
    }
}

private let voiceProcessingPlaybackCallback: AURenderCallback = {
    reference, _, _, _, frameCount, buffers in
    let audioUnit = Unmanaged<VoiceProcessingAudioUnit>
        .fromOpaque(reference)
        .takeUnretainedValue()
    return audioUnit.renderPlayback(frameCount: frameCount, buffers: buffers)
}

private let voiceProcessingCaptureCallback: AURenderCallback = {
    reference, flags, timestamp, _, frameCount, _ in
    let audioUnit = Unmanaged<VoiceProcessingAudioUnit>
        .fromOpaque(reference)
        .takeUnretainedValue()
    return audioUnit.capture(
        flags: flags,
        timestamp: timestamp,
        frameCount: frameCount
    )
}
