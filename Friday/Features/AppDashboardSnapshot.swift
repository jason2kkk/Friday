// 功能：定义 Friday 主工作台与灵动岛共享的只读运行状态快照。
// 职责：承载服务、模型、用量、权限、恢复结果和当前语音活动的可展示字段，并提供零费用界面预览数据。
// 边界：不主动读取权限、网络或音频状态，不包含 API Key、完整诊断、持久化历史或模型内部字段。

import Foundation

struct AppDashboardSnapshot: Equatable {
    var status = "正在检查 Friday"
    var model = "--"
    var serviceLabel = "正在检查"
    var serviceAvailable = false
    var serviceChecking = true
    var sessionsIssued: Int?
    var quotaLabel = "账户余额：OpenAI 未提供可读接口"
    var talkResponses = 0
    var talkTokens = 0
    var talkEstimatedCostUSD = 0.0
    var dictationTokens = 0
    var accessibilityGranted = false
    var microphoneGranted = false
    var microphoneCanRequest = false
    var screenCaptureGranted = false
    var serviceNeedsAttention = false
    var canRetry = false
    var lastOutput: String?
    var isDictationActive = false
    var isConversationActive = false

    static let preview = AppDashboardSnapshot(
        status: "已就绪",
        model: "gpt-realtime-2.1",
        serviceLabel: "本地服务已连接",
        serviceAvailable: true,
        serviceChecking: false,
        sessionsIssued: 12,
        quotaLabel: "账户余额：OpenAI 未提供可读接口",
        talkResponses: 3,
        talkTokens: 1_284,
        talkEstimatedCostUSD: 0.084,
        dictationTokens: 238,
        accessibilityGranted: true,
        microphoneGranted: true,
        microphoneCanRequest: false,
        screenCaptureGranted: true,
        serviceNeedsAttention: false,
        canRetry: false,
        lastOutput: "这是最近一次整理后的文字。",
        isDictationActive: false,
        isConversationActive: false
    )
}
