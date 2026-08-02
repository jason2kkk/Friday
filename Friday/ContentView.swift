// 功能：展示 Friday 灵动岛的展开仪表盘，让用户查看状态并执行所有常用操作。
// 职责：根据 InputOverlayModel 呈现服务、模型、权限、用量、最近结果和提示信息，并转发刷新、授权、复制、重试与退出命令。
// 边界：视图只负责展示和事件转发，不直接读取系统权限、访问网络、管理凭证或控制音频设备。

import AppKit
import SwiftUI

struct IslandDashboardSnapshot: Equatable {
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

    static let preview = IslandDashboardSnapshot(
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

struct ContentView: View {
    @ObservedObject var model: InputOverlayModel

    var body: some View {
        VStack(spacing: 0) {
            header

            Divider()
                .overlay(.white.opacity(0.1))

            ScrollView(.vertical, showsIndicators: false) {
                VStack(spacing: 14) {
                    presentedMessage
                    quickActions
                    usageMonitor
                    attentionRows
                    recentResult
                }
                .padding(.horizontal, 24)
                .padding(.vertical, 14)
            }

            Divider()
                .overlay(.white.opacity(0.1))

            footer
        }
        .foregroundStyle(.white)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var header: some View {
        HStack(spacing: 11) {
            Circle()
                .fill(statusColor)
                .frame(width: 8, height: 8)
                .shadow(color: statusColor.opacity(0.7), radius: 5)

            VStack(alignment: .leading, spacing: 2) {
                Text("Friday")
                    .font(.system(size: 16, weight: .semibold))
                Text(model.dashboard.status)
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(0.5))
                    .lineLimit(1)
            }

            Spacer(minLength: 12)

            Button {
                model.onCollapseDashboard?()
            } label: {
                Image(systemName: "chevron.up")
                    .font(.system(size: 11, weight: .bold))
                    .frame(width: 28, height: 28)
                    .background(.white.opacity(0.08))
                    .clipShape(Circle())
            }
            .buttonStyle(.plain)
            .help("收起")
            .accessibilityLabel("收起 Friday")
        }
        .padding(.horizontal, 24)
        .frame(height: 58)
    }

    @ViewBuilder
    private var presentedMessage: some View {
        switch model.phase {
        case .failure(let message, let canRetry):
            messageBand(
                message: message,
                systemImage: "exclamationmark.triangle.fill",
                tint: .orange,
                canRetry: canRetry
            )
        case .notice(let message):
            messageBand(
                message: message,
                systemImage: "checkmark.circle.fill",
                tint: .green,
                canRetry: false
            )
        case .result(let text, let message, let canRetry):
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    Image(systemName: "text.badge.checkmark")
                        .foregroundStyle(.cyan)
                    Text(message)
                        .font(.system(size: 12, weight: .semibold))
                    Spacer()
                }

                Text(text)
                    .font(.system(size: 13))
                    .foregroundStyle(.white.opacity(0.82))
                    .lineLimit(4)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)

                HStack(spacing: 8) {
                    Spacer()
                    if canRetry {
                        compactCommand(
                            title: "重试写入",
                            systemImage: "arrow.clockwise",
                            action: { model.onRetry?() }
                        )
                    }
                    compactCommand(
                        title: "复制",
                        systemImage: "doc.on.doc",
                        emphasized: true,
                        action: { model.onCopy?() }
                    )
                }
            }
            .padding(12)
            .background(.white.opacity(0.07))
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        default:
            EmptyView()
        }
    }

    private var quickActions: some View {
        HStack(spacing: 8) {
            actionButton(
                title: model.dashboard.isDictationActive ? "结束转写" : "转写",
                systemImage: model.dashboard.isDictationActive ? "stop.fill" : "text.cursor",
                tint: .cyan,
                action: { model.onToggleDictation?() }
            )
            actionButton(
                title: model.dashboard.isConversationActive ? "结束对话" : "语音 Agent",
                systemImage: model.dashboard.isConversationActive ? "stop.fill" : "waveform",
                tint: .pink,
                action: { model.onToggleConversation?() }
            )
            actionButton(
                title: "框选屏幕",
                systemImage: "viewfinder",
                tint: .purple,
                action: { model.onSelectScreenRegion?() }
            )
        }
    }

    private var usageMonitor: some View {
        VStack(spacing: 10) {
            HStack {
                Label("用量监控", systemImage: "gauge.with.dots.needle.50percent")
                    .font(.system(size: 12, weight: .semibold))
                Spacer()
                Text(model.dashboard.model)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.42))
                    .lineLimit(1)
            }

            HStack(spacing: 0) {
                metric(
                    value: "\(model.dashboard.talkResponses)",
                    label: "Talk 回复"
                )
                metric(
                    value: formattedCount(model.dashboard.talkTokens),
                    label: "Talk token"
                )
                metric(
                    value: formattedCost(model.dashboard.talkEstimatedCostUSD),
                    label: "本次估算"
                )
                metric(
                    value: model.dashboard.sessionsIssued.map(String.init) ?? "--",
                    label: "本地会话"
                )
            }

            HStack(spacing: 8) {
                Circle()
                    .fill(model.dashboard.serviceAvailable ? Color.green : Color.orange)
                    .frame(width: 6, height: 6)
                Text(model.dashboard.serviceLabel)
                Spacer()
                Text(model.dashboard.quotaLabel)
            }
            .font(.system(size: 10))
            .foregroundStyle(.white.opacity(0.48))
        }
        .padding(12)
        .background(.white.opacity(0.06))
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(.white.opacity(0.1), lineWidth: 1)
        }
    }

    @ViewBuilder
    private var attentionRows: some View {
        let dashboard = model.dashboard
        if !dashboard.accessibilityGranted
            || !dashboard.microphoneGranted
            || !dashboard.screenCaptureGranted
            || dashboard.serviceNeedsAttention
            || dashboard.canRetry {
            VStack(spacing: 0) {
                if !dashboard.accessibilityGranted {
                    attentionRow(
                        title: "允许自动写入",
                        systemImage: "hand.point.up.left.fill",
                        actionTitle: "授权",
                        action: { model.onRequestAccessibility?() }
                    )
                }
                if !dashboard.microphoneGranted {
                    attentionRow(
                        title: "允许使用麦克风",
                        systemImage: "mic.slash.fill",
                        actionTitle: dashboard.microphoneCanRequest ? "允许" : "设置",
                        action: { model.onRequestMicrophone?() }
                    )
                }
                if !dashboard.screenCaptureGranted {
                    attentionRow(
                        title: "允许屏幕框选",
                        systemImage: "rectangle.dashed.badge.record",
                        actionTitle: "授权",
                        action: { model.onRequestScreenCapture?() }
                    )
                }
                if dashboard.serviceNeedsAttention {
                    attentionRow(
                        title: "语音服务需要检查",
                        systemImage: "network.slash",
                        actionTitle: "重试",
                        action: { model.onRefresh?() }
                    )
                }
                if dashboard.canRetry {
                    attentionRow(
                        title: "本轮内容已保留",
                        systemImage: "arrow.uturn.backward.circle",
                        actionTitle: "重试",
                        action: { model.onRetry?() }
                    )
                }
            }
        }
    }

    @ViewBuilder
    private var recentResult: some View {
        if case .result = model.phase {
            EmptyView()
        } else if let output = model.dashboard.lastOutput, !output.isEmpty {
            HStack(spacing: 10) {
                Image(systemName: "text.badge.checkmark")
                    .foregroundStyle(.cyan)
                Text(output)
                    .font(.system(size: 12))
                    .foregroundStyle(.white.opacity(0.62))
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)

                Button(action: { model.onCopy?() }) {
                    Image(systemName: "doc.on.doc")
                }
                .buttonStyle(.plain)
                .help("复制最近结果")

                Button(action: { model.onClearLastOutput?() }) {
                    Image(systemName: "trash")
                }
                .buttonStyle(.plain)
                .help("清除最近结果")
            }
        }
    }

    private var footer: some View {
        HStack(spacing: 12) {
            Text("最近转写 \(formattedCount(model.dashboard.dictationTokens)) token")
                .font(.system(size: 10))
                .foregroundStyle(.white.opacity(0.38))

            Spacer()

            Button(action: { model.onRefresh?() }) {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(.plain)
            .help("刷新状态")
            .accessibilityLabel("刷新状态")

            Button(action: { model.onQuit?() }) {
                Image(systemName: "power")
            }
            .buttonStyle(.plain)
            .keyboardShortcut("q")
            .help("退出 Friday")
            .accessibilityLabel("退出 Friday")
        }
        .padding(.horizontal, 24)
        .frame(height: 38)
    }

    private func actionButton(
        title: String,
        systemImage: String,
        tint: Color,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 7) {
                Image(systemName: systemImage)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(tint)
                Text(title)
                    .font(.system(size: 12, weight: .semibold))
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity)
            .frame(height: 36)
            .background(.white.opacity(0.08))
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(.white.opacity(0.1), lineWidth: 1)
            }
        }
        .buttonStyle(.plain)
    }

    private func metric(value: String, label: String) -> some View {
        VStack(spacing: 3) {
            Text(value)
                .font(.system(size: 14, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.72)
            Text(label)
                .font(.system(size: 9))
                .foregroundStyle(.white.opacity(0.4))
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity)
    }

    private func attentionRow(
        title: String,
        systemImage: String,
        actionTitle: String,
        action: @escaping () -> Void
    ) -> some View {
        HStack(spacing: 9) {
            Image(systemName: systemImage)
                .foregroundStyle(.orange)
                .frame(width: 18)
            Text(title)
                .font(.system(size: 11, weight: .medium))
            Spacer()
            Button(actionTitle, action: action)
                .font(.system(size: 10, weight: .semibold))
                .buttonStyle(.plain)
                .foregroundStyle(.white.opacity(0.78))
        }
        .frame(height: 28)
    }

    private func messageBand(
        message: String,
        systemImage: String,
        tint: Color,
        canRetry: Bool
    ) -> some View {
        HStack(spacing: 10) {
            Image(systemName: systemImage)
                .foregroundStyle(tint)
            Text(message)
                .font(.system(size: 12, weight: .medium))
                .lineLimit(2)
                .frame(maxWidth: .infinity, alignment: .leading)
            if canRetry {
                Button(action: { model.onRetry?() }) {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.plain)
                .help("重试")
            }
        }
        .padding(.horizontal, 12)
        .frame(minHeight: 38)
        .background(tint.opacity(0.12))
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private func compactCommand(
        title: String,
        systemImage: String,
        emphasized: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(emphasized ? Color.black : Color.white.opacity(0.84))
                .padding(.horizontal, 10)
                .frame(height: 28)
                .background(emphasized ? Color.white : Color.white.opacity(0.1))
                .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    private var statusColor: Color {
        if model.dashboard.isConversationActive { return .cyan }
        if model.dashboard.isDictationActive { return .pink }
        if model.dashboard.serviceChecking { return .orange }
        return model.dashboard.serviceAvailable ? .green : .orange
    }

    private func formattedCount(_ value: Int) -> String {
        value.formatted(.number.grouping(.automatic))
    }

    private func formattedCost(_ value: Double) -> String {
        String(format: "$%.4f", value)
    }
}

@MainActor
struct ContentView_Previews: PreviewProvider {
    static var previews: some View {
        let model = InputOverlayModel()
        model.dashboard = .preview
        model.isDashboardExpanded = true
        return ContentView(model: model)
            .frame(width: 620, height: 360)
            .background(.black)
    }
}
