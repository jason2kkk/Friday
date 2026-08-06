// 功能：播放 Dictate 与 Talk 快捷键流程中的本地交互提示音，并在采集开始前隔离提示音与用户语音。
// 职责：把工作流事件映射到内置 WAV，管理 AVAudioPlayer 复用、抢占、有限时长播放、淡出和取消。
// 边界：只读取 App Bundle 内资源并输出本机音频；不采集麦克风、不连接模型，资源缺失或解码失败时静默降级。

@preconcurrency import AVFoundation
import Foundation

enum InteractionSoundCue: String, CaseIterable, Equatable {
    case chime
    case sparkle
    case success
    case error
}

enum InteractionSoundEvent: CaseIterable {
    case dictateCaptureRequested
    case dictateProcessingStarted
    case talkCaptureRequested
    case dictateProcessingFailed
    case dictateNoSpeech
    case dictateRecordingTooShort
    case dictateCaptureFailed
    case dictateInsertionFailed
    case talkEnded
    case talkFailed
}

struct InteractionSoundPolicy {
    static func cue(for event: InteractionSoundEvent) -> InteractionSoundCue? {
        switch event {
        case .dictateCaptureRequested:
            return .chime
        case .dictateProcessingStarted:
            return .sparkle
        case .talkCaptureRequested:
            return .success
        case .dictateProcessingFailed:
            return .error
        case .dictateNoSpeech,
             .dictateRecordingTooShort,
             .dictateCaptureFailed,
             .dictateInsertionFailed,
             .talkEnded,
             .talkFailed:
            return nil
        }
    }
}

@MainActor
protocol InteractionSoundPlaying: AnyObject {
    func play(for event: InteractionSoundEvent)
    func playBeforeCapture(for event: InteractionSoundEvent) async
    func stop()
}

@MainActor
final class InteractionSoundService: NSObject, InteractionSoundPlaying {
    private static let audibleLeadDuration: Duration = .milliseconds(360)
    private static let fadeDuration: Duration = .milliseconds(60)
    private static let fadeDurationSeconds: TimeInterval = 0.06

    private let players: [InteractionSoundCue: AVAudioPlayer]
    private var currentPlayer: AVAudioPlayer?

    init(bundle: Bundle = .main) {
        var loadedPlayers: [InteractionSoundCue: AVAudioPlayer] = [:]
        for cue in InteractionSoundCue.allCases {
            guard let url = bundle.url(forResource: cue.rawValue, withExtension: "wav"),
                  let player = try? AVAudioPlayer(contentsOf: url) else { continue }
            player.prepareToPlay()
            loadedPlayers[cue] = player
        }
        players = loadedPlayers
        super.init()
    }

    func play(for event: InteractionSoundEvent) {
        guard let cue = InteractionSoundPolicy.cue(for: event) else { return }
        start(cue)
    }

    func playBeforeCapture(for event: InteractionSoundEvent) async {
        guard let cue = InteractionSoundPolicy.cue(for: event),
              let player = start(cue) else { return }

        do {
            try await Task.sleep(for: Self.audibleLeadDuration)
            guard currentPlayer === player else { return }
            player.setVolume(0, fadeDuration: Self.fadeDurationSeconds)
            try await Task.sleep(for: Self.fadeDuration)
        } catch {
            // Cancellation intentionally shortens the cue so a cancelled workflow cannot start capture.
        }
        stop(player)
    }

    func stop() {
        guard let currentPlayer else { return }
        stop(currentPlayer)
    }

    @discardableResult
    private func start(_ cue: InteractionSoundCue) -> AVAudioPlayer? {
        guard let player = players[cue] else { return nil }
        stop()
        player.currentTime = 0
        player.volume = 1
        guard player.play() else { return nil }
        currentPlayer = player
        return player
    }

    private func stop(_ player: AVAudioPlayer) {
        guard currentPlayer === player else { return }
        player.stop()
        player.currentTime = 0
        player.volume = 1
        currentPlayer = nil
    }
}
