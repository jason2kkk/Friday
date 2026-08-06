// 功能：用类型化状态描述 Friday Dictate 从环境检查、录音、处理、写入到成功或失败恢复的完整生命周期。
// 职责：集中定义模式、恢复动作、用户可理解错误、服务可用性以及各状态派生的文案和工作标记。
// 边界：状态类型不执行权限请求、网络调用、音频采集或写回副作用，只作为工作流与界面的单一事实来源。

import Foundation

enum DictationMode: String, CaseIterable, Identifiable {
    case mock
    case live

    var id: String { rawValue }

    static var configured: DictationMode {
        let value = ProcessInfo.processInfo.environment["FRIDAY_DICTATION_MODE"]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        return value == DictationMode.mock.rawValue ? .mock : .live
    }
}

enum RecoveryAction {
    case process(
        context: DictationContext,
        target: FocusedInputTarget?,
        audio: RetainedAudio
    )
    case insert(text: String, target: FocusedInputTarget)
}

enum DictationWorkflowState: Equatable {
    case checkingReadiness
    case unavailable(String)
    case ready
    case preparing
    case recording
    case processing(partialText: String?)
    case inserting
    case success(String)
    case recoverableFailure(String)

    var statusText: String {
        switch self {
        case .checkingReadiness:
            return "正在检查 Olli"
        case .unavailable(let message), .recoverableFailure(let message):
            return message
        case .ready:
            return "已就绪"
        case .preparing:
            return "正在录音"
        case .recording:
            return "正在录音"
        case .processing:
            return "正在整理文字"
        case .inserting:
            return "正在写入输入框"
        case .success(let message):
            return message
        }
    }

    var isWorking: Bool {
        switch self {
        case .preparing, .recording, .processing, .inserting:
            return true
        default:
            return false
        }
    }

    var isRecording: Bool {
        self == .recording
    }

    var canCancel: Bool {
        isWorking
    }

    var isReady: Bool {
        self == .ready
    }
}

enum SessionServiceAvailability: Equatable {
    case notRequired
    case checking
    case available(SessionServiceHealth)
    case unavailable(String)

    var isAvailable: Bool {
        switch self {
        case .notRequired, .available:
            return true
        case .checking, .unavailable:
            return false
        }
    }
}
