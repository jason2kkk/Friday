// 功能：展示 Friday 灵动岛的主页与设置形态，让用户查看状态并执行所有常用操作。
// 职责：根据 InputOverlayModel 选择主页、Agent 动作确认或设置内容，呈现快捷操作、服务、权限、用量和最近结果，并转发业务命令。
// 边界：视图只负责展示和事件转发，不直接读取系统权限、访问网络、管理凭证或控制音频设备。

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

private extension View {
    func solidModule(cornerRadius: CGFloat = 20) -> some View {
        background {
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .fill(Color(red: 0.027, green: 0.027, blue: 0.027))
        }
        .overlay {
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .strokeBorder(.white.opacity(0.2), lineWidth: 1)
        }
    }
}

struct ContentView: View {
    @ObservedObject var model: InputOverlayModel

    var body: some View {
        ZStack(alignment: .top) {
            switch model.expandedPage {
            case .dashboard:
                dashboardPage
                    .transition(.opacity)
            case .settings:
                settingsPage
                    .transition(.opacity)
            }
        }
        .foregroundStyle(.white)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .animation(.easeInOut(duration: 0.16), value: model.expandedPage)
    }

    private var dashboardPage: some View {
        VStack(spacing: 0) {
            dashboardHeader
            sectionDivider

            if let confirmation = model.actionConfirmation {
                AgentActionConfirmationView(
                    confirmation: confirmation,
                    onAllow: { model.onAllowAction?() },
                    onReject: { model.onRejectAction?() },
                    onDismiss: { model.onDismissActionResult?() }
                )
            } else {
                ScrollView(.vertical, showsIndicators: false) {
                    VStack(spacing: 10) {
                        presentedMessage
                        quickActions
                        usageMonitor
                        attentionRows
                        recentResult
                    }
                    .padding(.horizontal, 20)
                    .padding(.vertical, 12)
                }
            }
        }
    }

    private var dashboardHeader: some View {
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

            headerButton(
                assetName: "设置图标",
                rendersOriginal: true,
                help: "设置",
                accessibilityLabel: "打开 Friday 设置",
                action: { model.onPresentSettings?() }
            )
        }
        .padding(.horizontal, 20)
        .frame(height: 56)
    }

    private var settingsPage: some View {
        VStack(spacing: 0) {
            settingsHeader
            sectionDivider

            ScrollView(.vertical, showsIndicators: false) {
                VStack(spacing: 18) {
                    settingsSection("权限") {
                        permissionRow(
                            title: "辅助功能",
                            detail: "写回当前输入框",
                            icon: "鼠标图标",
                            isGranted: model.dashboard.accessibilityGranted,
                            actionTitle: "去设置",
                            action: { model.onRequestAccessibility?() }
                        )
                        permissionRow(
                            title: "麦克风",
                            detail: "转写与语音对话",
                            icon: "麦克风图标",
                            isGranted: model.dashboard.microphoneGranted,
                            actionTitle: model.dashboard.microphoneCanRequest ? "允许" : "去设置",
                            action: { model.onRequestMicrophone?() }
                        )
                        permissionRow(
                            title: "屏幕录制",
                            detail: "仅用于主动框选",
                            icon: "框选图标",
                            isGranted: model.dashboard.screenCaptureGranted,
                            actionTitle: "去设置",
                            showsDivider: false,
                            action: { model.onRequestScreenCapture?() }
                        )
                    }

                    settingsSection("服务与用量") {
                        informationRow(
                            title: "本地语音服务",
                            detail: model.dashboard.serviceLabel,
                            icon: "云连接图标",
                            trailing: model.dashboard.serviceAvailable ? "可用" : "需检查",
                            trailingColor: model.dashboard.serviceAvailable ? .green : .orange
                        )
                        informationRow(
                            title: "当前模型",
                            detail: model.dashboard.model,
                            icon: "处理器图标",
                            trailing: nil
                        )
                        informationRow(
                            title: "Talk 用量",
                            detail: "\(model.dashboard.talkResponses) 次回复 · \(formattedCount(model.dashboard.talkTokens)) token · \(formattedCost(model.dashboard.talkEstimatedCostUSD))",
                            icon: "语音图标",
                            trailing: nil
                        )
                        informationRow(
                            title: "账户额度",
                            detail: model.dashboard.quotaLabel,
                            icon: "额度图标",
                            trailing: nil,
                            showsDivider: false
                        )
                    }

                    settingsSection("通用") {
                        commandRow(
                            title: "刷新状态",
                            detail: "重新检查权限、服务与模型",
                            icon: "刷新图标",
                            showsDivider: model.dashboard.lastOutput?.isEmpty == false,
                            action: { model.onRefresh?() }
                        )
                        if let output = model.dashboard.lastOutput, !output.isEmpty {
                            commandRow(
                                title: "清除最近结果",
                                detail: "移除当前保留的转写结果",
                                icon: "删除图标",
                                showsDivider: false,
                                action: { model.onClearLastOutput?() }
                            )
                        }
                    }
                }
                .padding(.horizontal, 18)
                .padding(.vertical, 16)
            }
        }
    }

    private var settingsHeader: some View {
        HStack(spacing: 10) {
            headerButton(
                assetName: "返回图标",
                help: "返回",
                accessibilityLabel: "返回 Friday 主页",
                action: { model.onPresentDashboard?() }
            )

            VStack(alignment: .leading, spacing: 2) {
                Text("设置")
                    .font(.system(size: 15, weight: .semibold))
                Text("Friday")
                    .font(.system(size: 10))
                    .foregroundStyle(.white.opacity(0.45))
            }

            Spacer(minLength: 12)

            quitHeaderButton
        }
        .padding(.horizontal, 18)
        .frame(height: 56)
    }

    @ViewBuilder
    private var presentedMessage: some View {
        switch model.phase {
        case .failure(let message, let canRetry):
            messageBand(
                message: message,
                icon: "警告图标",
                tint: .orange,
                canRetry: canRetry
            )
        case .notice(let message):
            messageBand(
                message: message,
                icon: "完成图标",
                tint: .green,
                canRetry: false
            )
        case .result(let text, let message, let canRetry):
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    appIcon("文档图标")
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
                            icon: "刷新图标",
                            action: { model.onRetry?() }
                        )
                    }
                    compactCommand(
                        title: "复制",
                        icon: "复制图标",
                        emphasized: true,
                        action: { model.onCopy?() }
                    )
                }
            }
            .padding(12)
            .solidModule()
        default:
            EmptyView()
        }
    }

    private var quickActions: some View {
        HStack(spacing: 8) {
            actionButton(
                title: model.dashboard.isDictationActive ? "结束转写" : "转写",
                icon: model.dashboard.isDictationActive ? "停止图标" : "文字图标",
                tint: .cyan,
                action: { model.onToggleDictation?() }
            )
            actionButton(
                title: model.dashboard.isConversationActive ? "结束对话" : "语音 Agent",
                icon: model.dashboard.isConversationActive ? "停止图标" : "语音图标",
                tint: .pink,
                action: { model.onToggleConversation?() }
            )
            actionButton(
                title: "框选屏幕",
                icon: "框选图标",
                tint: .purple,
                action: { model.onSelectScreenRegion?() }
            )
        }
        .padding(12)
        .solidModule()
    }

    private var usageMonitor: some View {
        VStack(spacing: 8) {
            HStack {
                HStack(spacing: 7) {
                    Circle()
                        .fill(model.dashboard.serviceAvailable ? Color.green : Color.orange)
                        .frame(width: 6, height: 6)
                    Text(model.dashboard.serviceLabel)
                        .font(.system(size: 11, weight: .medium))
                }
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
                Text(model.dashboard.quotaLabel)
                    .lineLimit(1)
                    .minimumScaleFactor(0.78)
                Spacer(minLength: 8)
                Text("转写 \(formattedCount(model.dashboard.dictationTokens)) token")
                    .lineLimit(1)
            }
            .font(.system(size: 10))
            .foregroundStyle(.white.opacity(0.48))
        }
        .padding(12)
        .solidModule()
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
                        icon: "编辑图标",
                        actionTitle: "授权",
                        action: { model.onRequestAccessibility?() }
                    )
                }
                if !dashboard.microphoneGranted {
                    attentionRow(
                        title: "允许使用麦克风",
                        icon: "麦克风关闭图标",
                        actionTitle: dashboard.microphoneCanRequest ? "允许" : "设置",
                        action: { model.onRequestMicrophone?() }
                    )
                }
                if !dashboard.screenCaptureGranted {
                    attentionRow(
                        title: "允许屏幕框选",
                        icon: "框选图标",
                        actionTitle: "授权",
                        action: { model.onRequestScreenCapture?() }
                    )
                }
                if dashboard.serviceNeedsAttention {
                    attentionRow(
                        title: "语音服务需要检查",
                        icon: "网络图标",
                        actionTitle: "重试",
                        action: { model.onRefresh?() }
                    )
                }
                if dashboard.canRetry {
                    attentionRow(
                        title: "本轮内容已保留",
                        icon: "刷新图标",
                        actionTitle: "重试",
                        action: { model.onRetry?() }
                    )
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 4)
            .solidModule()
        }
    }

    @ViewBuilder
    private var recentResult: some View {
        if case .result = model.phase {
            EmptyView()
        } else if let output = model.dashboard.lastOutput, !output.isEmpty {
            HStack(spacing: 10) {
                appIcon("文档图标")
                    .foregroundStyle(.cyan)
                Text(output)
                    .font(.system(size: 12))
                    .foregroundStyle(.white.opacity(0.62))
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)

                Button(action: { model.onCopy?() }) {
                    appIcon("复制图标")
                }
                .buttonStyle(.plain)
                .help("复制最近结果")

                Button(action: { model.onClearLastOutput?() }) {
                    appIcon("删除图标")
                }
                .buttonStyle(.plain)
                .help("清除最近结果")
            }
            .padding(12)
            .solidModule()
        }
    }

    private func actionButton(
        title: String,
        icon: String,
        tint: Color,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 7) {
                appIcon(icon)
                    .foregroundStyle(tint)
                Text(title)
                    .font(.system(size: 12, weight: .semibold))
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity)
            .frame(height: 36)
            .contentShape(Rectangle())
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
        icon: String,
        actionTitle: String,
        action: @escaping () -> Void
    ) -> some View {
        HStack(spacing: 9) {
            appIcon(icon)
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
        icon: String,
        tint: Color,
        canRetry: Bool
    ) -> some View {
        HStack(spacing: 10) {
            appIcon(icon)
                .foregroundStyle(tint)
            Text(message)
                .font(.system(size: 12, weight: .medium))
                .lineLimit(2)
                .frame(maxWidth: .infinity, alignment: .leading)
            if canRetry {
                Button(action: { model.onRetry?() }) {
                    appIcon("刷新图标")
                }
                .buttonStyle(.plain)
                .help("重试")
            }
        }
        .padding(.horizontal, 12)
        .frame(minHeight: 38)
        .solidModule()
    }

    private func compactCommand(
        title: String,
        icon: String,
        emphasized: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 5) {
                appIcon(icon)
                Text(title)
                    .font(.system(size: 11, weight: .semibold))
            }
            .foregroundStyle(emphasized ? Color.black : Color.white.opacity(0.84))
            .padding(.horizontal, 10)
            .frame(height: 28)
            .background(emphasized ? Color.white : Color.white.opacity(0.1))
            .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    private func headerButton(
        assetName: String,
        rendersOriginal: Bool = false,
        help: String,
        accessibilityLabel: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(assetName)
                .renderingMode(rendersOriginal ? .original : .template)
                .resizable()
                .interpolation(.high)
                .aspectRatio(contentMode: .fit)
                .frame(width: 16, height: 16)
                .frame(width: 28, height: 28)
                .background(.white.opacity(0.08))
                .clipShape(Circle())
        }
        .buttonStyle(.plain)
        .help(help)
        .accessibilityLabel(accessibilityLabel)
    }

    private var quitHeaderButton: some View {
        Button(action: { model.onQuit?() }) {
            HStack(spacing: 6) {
                Image("退出图标")
                    .renderingMode(.original)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 16, height: 16)
                Text("退出")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.82))
            }
            .padding(.horizontal, 9)
            .frame(height: 28)
            .background(.white.opacity(0.08))
            .clipShape(Capsule())
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .keyboardShortcut("q")
        .help("退出 Friday")
        .accessibilityLabel("退出 Friday")
    }

    private func settingsSection<Content: View>(
        _ title: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.white.opacity(0.38))
                .padding(.leading, 4)

            VStack(spacing: 0) {
                content()
            }
            .solidModule()
        }
    }

    private func permissionRow(
        title: String,
        detail: String,
        icon: String,
        isGranted: Bool,
        actionTitle: String,
        showsDivider: Bool = true,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 11) {
                settingsIcon(icon, color: isGranted ? .green : .orange)
                settingsLabels(title: title, detail: detail)
                Spacer(minLength: 10)

                if isGranted {
                    HStack(spacing: 4) {
                        appIcon("完成图标")
                        Text("已开启")
                            .font(.system(size: 10, weight: .medium))
                    }
                    .foregroundStyle(.green)
                } else {
                    Text(actionTitle)
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.white.opacity(0.6))
                    appIcon("右箭头图标")
                        .foregroundStyle(.white.opacity(0.3))
                }
            }
            .padding(.horizontal, 14)
            .frame(height: 48)
            .contentShape(Rectangle())
            .overlay(alignment: .bottom) {
                if showsDivider { settingsRowDivider }
            }
        }
        .buttonStyle(.plain)
        .allowsHitTesting(!isGranted)
    }

    private func informationRow(
        title: String,
        detail: String,
        icon: String,
        trailing: String?,
        trailingColor: Color = .white.opacity(0.5),
        showsDivider: Bool = true
    ) -> some View {
        HStack(spacing: 11) {
            settingsIcon(icon, color: .white.opacity(0.72))
            settingsLabels(title: title, detail: detail)
            Spacer(minLength: 10)
            if let trailing {
                Text(trailing)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(trailingColor)
            }
        }
        .padding(.horizontal, 14)
        .frame(height: 48)
        .overlay(alignment: .bottom) {
            if showsDivider { settingsRowDivider }
        }
    }

    private func commandRow(
        title: String,
        detail: String,
        icon: String,
        showsDivider: Bool = true,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 11) {
                settingsIcon(icon, color: .white.opacity(0.7))
                settingsLabels(title: title, detail: detail)
                Spacer(minLength: 10)
                appIcon("右箭头图标")
                    .foregroundStyle(.white.opacity(0.3))
            }
            .padding(.horizontal, 14)
            .frame(height: 48)
            .contentShape(Rectangle())
            .overlay(alignment: .bottom) {
                if showsDivider { settingsRowDivider }
            }
        }
        .buttonStyle(.plain)
    }

    private func settingsIcon(_ icon: String, color: Color) -> some View {
        appIcon(icon)
            .foregroundStyle(color)
            .frame(width: 20)
    }

    private func appIcon(_ assetName: String, size: CGFloat = 16) -> some View {
        Image(assetName)
            .renderingMode(.template)
            .resizable()
            .interpolation(.high)
            .aspectRatio(contentMode: .fit)
            .frame(width: size, height: size)
    }

    private func settingsLabels(title: String, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.white.opacity(0.9))
                .lineLimit(1)
            Text(detail)
                .font(.system(size: 10))
                .foregroundStyle(.white.opacity(0.4))
                .lineLimit(1)
                .minimumScaleFactor(0.72)
        }
    }

    private var settingsRowDivider: some View {
        Rectangle()
            .fill(.white.opacity(0.08))
            .frame(height: 1)
            .padding(.leading, 45)
            .padding(.trailing, 14)
    }

    private var sectionDivider: some View {
        Divider()
            .overlay(.white.opacity(0.1))
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
            .frame(
                width: InputOverlaySizing.expandedSize.width,
                height: InputOverlaySizing.expandedSize.height
            )
            .background(.black)
    }
}
