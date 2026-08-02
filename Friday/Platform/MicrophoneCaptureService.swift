// 功能：为单轮 Dictate 采集本地麦克风音频，生成 Realtime 所需 PCM16 分片和界面声波数据。
// 职责：管理麦克风授权与输入设备、AVAudioEngine 生命周期、格式转换、分段音量、语音活动阈值和录音时长统计。
// 边界：音频只保留在内存并通过回调输出；本服务不连接模型、不写磁盘，也不负责 Talk 的全双工播放。

@preconcurrency import AVFoundation
import Foundation

struct AudioLevelMeter {
    static let visualActivityThreshold: Float = 0.13

    static func hasVisualActivity(_ level: Float) -> Bool {
        level >= visualActivityThreshold
    }

    static func normalizedLevel(
        samples: UnsafePointer<Float>,
        count: Int
    ) -> Float {
        guard count > 0 else { return 0 }

        var squareSum: Float = 0
        for index in 0..<count {
            let sample = samples[index]
            squareSum += sample * sample
        }

        let rootMeanSquare = sqrt(squareSum / Float(count))
        let decibels = 20 * log10(max(rootMeanSquare, 0.000_001))
        return min(max((decibels + 60) / 60, 0), 1)
    }

    static func waveformLevels(
        samples: UnsafePointer<Float>,
        count: Int,
        barCount: Int = AudioChunk.waveformLevelCount
    ) -> [Float] {
        guard count > 0, barCount > 0 else { return [] }

        return (0..<barCount).map { index in
            let start = index * count / barCount
            let end = (index + 1) * count / barCount
            let segmentCount = max(end - start, 1)
            return normalizedLevel(
                samples: samples.advanced(by: min(start, count - 1)),
                count: min(segmentCount, count - min(start, count - 1))
            )
        }
    }
}

@MainActor
final class MicrophoneCaptureService {
    static let bufferSize: AVAudioFrameCount = 1_024

    enum CaptureError: LocalizedError {
        case permissionDenied
        case unavailableInput

        var errorDescription: String? {
            switch self {
            case .permissionDenied:
                return "请先允许 Friday 使用麦克风。"
            case .unavailableInput:
                return "没有找到可用的麦克风。"
            }
        }
    }

    var onLevel: ((Float) -> Void)?
    var onAudioChunk: ((AudioChunk) -> Void)?

    private let engine = AVAudioEngine()
    private var tapInstalled = false

    var isCapturing: Bool {
        engine.isRunning
    }

    var authorizationStatus: AVAuthorizationStatus {
        AVCaptureDevice.authorizationStatus(for: .audio)
    }

    func preflight() async throws {
        guard await hasPermission() else { throw CaptureError.permissionDenied }

        let inputFormat = engine.inputNode.outputFormat(forBus: 0)
        guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0 else {
            throw CaptureError.unavailableInput
        }
    }

    func start() async throws {
        guard !engine.isRunning else { return }
        try await preflight()

        let inputNode = engine.inputNode
        let inputFormat = inputNode.outputFormat(forBus: 0)
        guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0,
              let realtimeFormat = AVAudioFormat(
                commonFormat: .pcmFormatInt16,
                sampleRate: 24_000,
                channels: 1,
                interleaved: true
              ),
              let converter = AVAudioConverter(from: inputFormat, to: realtimeFormat) else {
            throw CaptureError.unavailableInput
        }

        inputNode.installTap(
            onBus: 0,
            bufferSize: Self.bufferSize,
            format: inputFormat
        ) { [weak self] buffer, _ in
            guard let self,
                  let channelData = buffer.floatChannelData?[0] else { return }

            let frameCount = Int(buffer.frameLength)
            guard let data = Self.convertToRealtimePCM16(
                buffer,
                converter: converter,
                outputFormat: realtimeFormat
            ) else { return }

            let level = AudioLevelMeter.normalizedLevel(
                samples: channelData,
                count: frameCount
            )
            let waveformLevels = AudioLevelMeter.waveformLevels(
                samples: channelData,
                count: frameCount
            )
            let chunk = AudioChunk(
                pcm16: data,
                sampleRate: realtimeFormat.sampleRate,
                channelCount: 1,
                frameCount: data.count / MemoryLayout<Int16>.size,
                normalizedLevel: level,
                waveformLevels: waveformLevels
            )

            Task { @MainActor [weak self] in
                self?.onAudioChunk?(chunk)
                self?.onLevel?(level)
            }
        }
        tapInstalled = true

        do {
            engine.prepare()
            try engine.start()
        } catch {
            inputNode.removeTap(onBus: 0)
            tapInstalled = false
            throw error
        }
    }

    func stop() {
        if engine.isRunning {
            engine.stop()
        }
        if tapInstalled {
            engine.inputNode.removeTap(onBus: 0)
            tapInstalled = false
        }
        onLevel?(0)
    }

    private func hasPermission() async -> Bool {
        switch authorizationStatus {
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
