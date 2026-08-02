// 功能：定义可替换的唤醒词能力，并提供在本机识别完整“Hey Friday”短语的原型实现与 Mock。
// 职责：管理 Speech 和麦克风授权、识别任务与音频引擎生命周期、短周期恢复、状态回调和严格短语匹配。
// 边界：当前产品路径默认使用不监听的 Mock；唤醒服务不创建 Talk 凭证、不调用模型，也不保存识别音频或完整转写。

@preconcurrency import AVFoundation
import Foundation
@preconcurrency import Speech

enum WakeWordAuthorizationState: Equatable {
    case authorized
    case notDetermined
    case denied
    case unavailable
}

enum WakeWordListeningState: Equatable {
    case stopped
    case requestingPermission
    case listening
    case unavailable(String)

    var statusText: String {
        switch self {
        case .stopped:
            return "Hey Friday 已暂停"
        case .requestingPermission:
            return "正在准备 Hey Friday"
        case .listening:
            return "可以直接说 Hey Friday"
        case .unavailable(let message):
            return message
        }
    }
}

@MainActor
protocol WakeWordProviding: AnyObject {
    var onDetected: (() -> Void)? { get set }
    var onStateChanged: ((WakeWordListeningState) -> Void)? { get set }
    var authorizationState: WakeWordAuthorizationState { get }

    func requestAuthorization() async -> Bool
    func start() async throws
    func stop()
}

struct WakePhraseMatcher {
    static func matches(_ transcript: String) -> Bool {
        let normalized = transcript
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }

        guard normalized.count >= 2 else { return false }
        return normalized.indices.dropLast().contains { index in
            normalized[index] == "hey" && normalized[normalized.index(after: index)] == "friday"
        }
    }
}

@MainActor
final class OnDeviceWakeWordService: WakeWordProviding {
    enum WakeWordError: LocalizedError {
        case permissionDenied
        case onDeviceRecognitionUnavailable
        case recognizerUnavailable
        case microphoneUnavailable

        var errorDescription: String? {
            switch self {
            case .permissionDenied:
                return "需要语音识别和麦克风权限才能使用 Hey Friday。"
            case .onDeviceRecognitionUnavailable:
                return "这台 Mac 暂时不支持本机 Hey Friday 识别。"
            case .recognizerUnavailable:
                return "本机语音识别暂时不可用。"
            case .microphoneUnavailable:
                return "没有找到可用于 Hey Friday 的麦克风。"
            }
        }
    }

    var onDetected: (() -> Void)?
    var onStateChanged: ((WakeWordListeningState) -> Void)?

    private let recognizer: SFSpeechRecognizer?
    private let audioEngine = AVAudioEngine()
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?
    private var restartTask: Task<Void, Never>?
    private var cycleTask: Task<Void, Never>?
    private var tapInstalled = false
    private var shouldBeListening = false
    private var didDetectWakePhrase = false

    init(locale: Locale = Locale(identifier: "en-US")) {
        recognizer = SFSpeechRecognizer(locale: locale)
    }

    var authorizationState: WakeWordAuthorizationState {
        let speechStatus = SFSpeechRecognizer.authorizationStatus()
        let microphoneStatus = AVCaptureDevice.authorizationStatus(for: .audio)

        if speechStatus == .denied || speechStatus == .restricted
            || microphoneStatus == .denied || microphoneStatus == .restricted {
            return .denied
        }
        if speechStatus == .notDetermined || microphoneStatus == .notDetermined {
            return .notDetermined
        }
        guard speechStatus == .authorized,
              microphoneStatus == .authorized,
              recognizer?.supportsOnDeviceRecognition == true else {
            return .unavailable
        }
        return .authorized
    }

    func requestAuthorization() async -> Bool {
        onStateChanged?(.requestingPermission)
        let speechGranted = await requestSpeechAuthorization()
        let microphoneGranted = await requestMicrophoneAuthorization()
        return speechGranted && microphoneGranted
    }

    func start() async throws {
        guard !shouldBeListening else { return }
        if authorizationState == .notDetermined {
            guard await requestAuthorization() else {
                throw WakeWordError.permissionDenied
            }
        }
        guard authorizationState == .authorized else {
            throw authorizationState == .denied
                ? WakeWordError.permissionDenied
                : WakeWordError.onDeviceRecognitionUnavailable
        }

        shouldBeListening = true
        didDetectWakePhrase = false
        try beginRecognitionCycle()
    }

    func stop() {
        shouldBeListening = false
        restartTask?.cancel()
        restartTask = nil
        cycleTask?.cancel()
        cycleTask = nil
        stopRecognitionCycle()
        onStateChanged?(.stopped)
    }

    private func beginRecognitionCycle() throws {
        guard shouldBeListening else { return }
        guard let recognizer else { throw WakeWordError.recognizerUnavailable }
        guard recognizer.isAvailable else { throw WakeWordError.recognizerUnavailable }
        guard recognizer.supportsOnDeviceRecognition else {
            throw WakeWordError.onDeviceRecognitionUnavailable
        }

        stopRecognitionCycle()

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.requiresOnDeviceRecognition = true
        request.shouldReportPartialResults = true
        request.contextualStrings = ["Hey Friday"]
        request.taskHint = .dictation
        recognitionRequest = request

        let inputNode = audioEngine.inputNode
        let inputFormat = inputNode.outputFormat(forBus: 0)
        guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0 else {
            throw WakeWordError.microphoneUnavailable
        }

        inputNode.installTap(
            onBus: 0,
            bufferSize: 2_048,
            format: inputFormat
        ) { [weak request] buffer, _ in
            request?.append(buffer)
        }
        tapInstalled = true

        recognitionTask = recognizer.recognitionTask(with: request) { [weak self] result, error in
            Task { @MainActor [weak self] in
                self?.handleRecognition(result: result, error: error)
            }
        }

        do {
            audioEngine.prepare()
            try audioEngine.start()
        } catch {
            stopRecognitionCycle()
            throw error
        }

        onStateChanged?(.listening)
        scheduleCycleRefresh()
    }

    private func handleRecognition(result: SFSpeechRecognitionResult?, error: Error?) {
        guard shouldBeListening, !didDetectWakePhrase else { return }

        if let transcript = result?.bestTranscription.formattedString,
           WakePhraseMatcher.matches(transcript) {
            didDetectWakePhrase = true
            shouldBeListening = false
            stopRecognitionCycle()
            onDetected?()
            return
        }

        if error != nil || result?.isFinal == true {
            scheduleRestart()
        }
    }

    private func scheduleCycleRefresh() {
        cycleTask?.cancel()
        cycleTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(45))
            guard !Task.isCancelled else { return }
            self?.restartRecognitionCycle()
        }
    }

    private func scheduleRestart() {
        guard shouldBeListening else { return }
        restartTask?.cancel()
        restartTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(350))
            guard !Task.isCancelled else { return }
            self?.restartRecognitionCycle()
        }
    }

    private func restartRecognitionCycle() {
        guard shouldBeListening else { return }
        do {
            try beginRecognitionCycle()
        } catch {
            let message = (error as? LocalizedError)?.errorDescription
                ?? "Hey Friday 暂时不可用。"
            onStateChanged?(.unavailable(message))
            scheduleRestart()
        }
    }

    private func stopRecognitionCycle() {
        cycleTask?.cancel()
        cycleTask = nil
        recognitionRequest?.endAudio()
        recognitionRequest = nil
        recognitionTask?.cancel()
        recognitionTask = nil
        if audioEngine.isRunning {
            audioEngine.stop()
        }
        if tapInstalled {
            audioEngine.inputNode.removeTap(onBus: 0)
            tapInstalled = false
        }
    }

    private func requestSpeechAuthorization() async -> Bool {
        switch SFSpeechRecognizer.authorizationStatus() {
        case .authorized:
            return true
        case .notDetermined:
            return await withCheckedContinuation { continuation in
                SFSpeechRecognizer.requestAuthorization { status in
                    continuation.resume(returning: status == .authorized)
                }
            }
        case .denied, .restricted:
            return false
        @unknown default:
            return false
        }
    }

    private func requestMicrophoneAuthorization() async -> Bool {
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
}

@MainActor
final class MockWakeWordService: WakeWordProviding {
    var onDetected: (() -> Void)?
    var onStateChanged: ((WakeWordListeningState) -> Void)?
    var authorizationState: WakeWordAuthorizationState = .authorized

    func requestAuthorization() async -> Bool { true }

    func start() async throws {
        onStateChanged?(.listening)
    }

    func stop() {
        onStateChanged?(.stopped)
    }

    func simulateDetection() {
        onDetected?()
    }
}
