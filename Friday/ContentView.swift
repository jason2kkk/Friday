// 功能：展示 Olli 灵动岛的主页与设置形态，让用户查看状态并执行所有常用操作。
// 职责：根据 InputOverlayModel 呈现快捷操作、服务、权限、用量、最近结果和纵向设置菜单，并转发页面切换与业务命令。
// 边界：视图只负责展示和事件转发，不直接读取系统权限、访问网络、管理凭证或控制音频设备。

import SwiftUI

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

    private var dashboardHeader: some View {
        HStack(spacing: 11) {
            Image("灵动岛紧凑图标")
                .renderingMode(.original)
                .resizable()
                .interpolation(.high)
                .aspectRatio(contentMode: .fit)
                .frame(width: 28, height: 28)

            VStack(alignment: .leading, spacing: 2) {
                Text("Olli")
                    .font(.system(size: 16, weight: .semibold))
                HStack(spacing: 5) {
                    Circle()
                        .fill(statusColor)
                        .frame(width: 5, height: 5)
                    Text(friendlyHeaderStatus)
                        .font(.system(size: 11))
                        .foregroundStyle(.white.opacity(0.5))
                        .lineLimit(1)
                }
            }

            Spacer(minLength: 12)

            headerButton(
                assetName: "展开图标",
                help: "打开 Olli",
                accessibilityLabel: "打开 Olli 窗口",
                action: { model.onOpenWorkspace?() }
            )

            headerButton(
                assetName: "设置图标",
                rendersOriginal: true,
                help: "设置",
                accessibilityLabel: "打开 Olli 设置",
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
                    settingsSection("能力与权限") {
                        permissionRow(
                            title: "帮你输入",
                            detail: "把整理好的文字放回当前输入框",
                            icon: "鼠标图标",
                            isGranted: model.dashboard.accessibilityGranted,
                            actionTitle: "去设置",
                            action: { model.onRequestAccessibility?() }
                        )
                        permissionRow(
                            title: "听懂你的声音",
                            detail: "只在你主动使用时开启麦克风",
                            icon: "麦克风图标",
                            isGranted: model.dashboard.microphoneGranted,
                            actionTitle: model.dashboard.microphoneCanRequest ? "允许" : "去设置",
                            action: { model.onRequestMicrophone?() }
                        )
                        permissionRow(
                            title: "看懂框选内容",
                            detail: "只有主动框选时才读取屏幕",
                            icon: "框选图标",
                            isGranted: model.dashboard.screenCaptureGranted,
                            actionTitle: "去设置",
                            showsDivider: false,
                            action: { model.onRequestScreenCapture?() }
                        )
                    }

                    settingsSection("连接与使用") {
                        informationRow(
                            title: "语音连接",
                            detail: connectionDetail,
                            icon: "云连接图标",
                            trailing: connectionState,
                            trailingColor: model.dashboard.serviceAvailable ? .green : .orange
                        )
                        informationRow(
                            title: "本次使用",
                            detail: "\(sessionUsageText) · 预计 \(formattedCost(model.dashboard.talkEstimatedCostUSD))",
                            icon: "语音图标",
                            trailing: nil
                        )
                        informationRow(
                            title: "账户余额",
                            detail: friendlyQuotaDetail,
                            icon: "额度图标",
                            trailing: nil,
                            showsDivider: false
                        )
                    }

                    settingsSection("其他") {
                        commandRow(
                            title: "重新检查",
                            detail: "更新连接和权限状态",
                            icon: "刷新图标",
                            showsDivider: model.dashboard.lastOutput?.isEmpty == false,
                            action: { model.onRefresh?() }
                        )
                        if let output = model.dashboard.lastOutput, !output.isEmpty {
                            commandRow(
                                title: "清除最近内容",
                                detail: "移除当前保留的文字",
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
                accessibilityLabel: "返回 Olli 主页",
                action: { model.onPresentDashboard?() }
            )

            Image("灵动岛紧凑图标")
                .renderingMode(.original)
                .resizable()
                .interpolation(.high)
                .aspectRatio(contentMode: .fit)
                .frame(width: 24, height: 24)

            VStack(alignment: .leading, spacing: 2) {
                Text("设置")
                    .font(.system(size: 15, weight: .semibold))
                Text("让 Olli 更适合你")
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
                            title: "再试一次",
                            icon: "刷新图标",
                            action: { model.onRetry?() }
                        )
                    }
                    compactCommand(
                        title: "复制文字",
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
        HStack(spacing: 0) {
            actionButton(
                title: model.dashboard.isDictationActive ? "完成听写" : "帮我写",
                icon: model.dashboard.isDictationActive ? "停止图标" : "文字图标",
                tint: .cyan,
                action: { model.onToggleDictation?() }
            )
            quickActionDivider
            actionButton(
                title: model.dashboard.isConversationActive ? "结束对话" : "聊一聊",
                icon: model.dashboard.isConversationActive ? "停止图标" : "语音图标",
                tint: .pink,
                action: { model.onToggleConversation?() }
            )
            quickActionDivider
            actionButton(
                title: "看一下屏幕",
                icon: "框选图标",
                tint: .purple,
                action: { model.onSelectScreenRegion?() }
            )
        }
        .padding(.horizontal, 4)
        .padding(.vertical, 6)
        .solidModule()
    }

    private var usageMonitor: some View {
        HStack(spacing: 12) {
            appIcon("语音图标", size: 18)
                .foregroundStyle(.cyan)
                .frame(width: 28)

            VStack(alignment: .leading, spacing: 3) {
                Text("本次使用")
                    .font(.system(size: 11, weight: .semibold))
                Text(sessionUsageText)
                    .font(.system(size: 10))
                    .foregroundStyle(.white.opacity(0.48))
                    .lineLimit(1)
                Text(friendlyQuotaDetail)
                    .font(.system(size: 9))
                    .foregroundStyle(.white.opacity(0.34))
                    .lineLimit(1)
                    .minimumScaleFactor(0.78)
            }

            Spacer(minLength: 10)

            VStack(alignment: .trailing, spacing: 2) {
                Text(formattedCost(model.dashboard.talkEstimatedCostUSD))
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                Text("预计费用")
                    .font(.system(size: 9))
                    .foregroundStyle(.white.opacity(0.38))
            }
        }
        .padding(.horizontal, 12)
        .frame(minHeight: 58)
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
                        title: "允许 Olli 帮你输入",
                        icon: "编辑图标",
                        actionTitle: "授权",
                        action: { model.onRequestAccessibility?() }
                    )
                }
                if !dashboard.microphoneGranted {
                    attentionRow(
                        title: "打开麦克风权限",
                        icon: "麦克风关闭图标",
                        actionTitle: dashboard.microphoneCanRequest ? "允许" : "设置",
                        action: { model.onRequestMicrophone?() }
                    )
                }
                if !dashboard.screenCaptureGranted {
                    attentionRow(
                        title: "允许 Olli 看你框选的内容",
                        icon: "框选图标",
                        actionTitle: "授权",
                        action: { model.onRequestScreenCapture?() }
                    )
                }
                if dashboard.serviceNeedsAttention {
                    attentionRow(
                        title: "语音连接暂时不可用",
                        icon: "网络图标",
                        actionTitle: "重试",
                        action: { model.onRefresh?() }
                    )
                }
                if dashboard.canRetry {
                    attentionRow(
                        title: "刚刚的内容还在",
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
            VStack(alignment: .leading, spacing: 7) {
                HStack(spacing: 8) {
                    appIcon("文档图标")
                        .foregroundStyle(.cyan)
                    Text("刚刚整理")
                        .font(.system(size: 11, weight: .semibold))
                    Spacer()

                    Button(action: { model.onCopy?() }) {
                        appIcon("复制图标")
                    }
                    .buttonStyle(.plain)
                    .help("复制文字")

                    Button(action: { model.onClearLastOutput?() }) {
                        appIcon("删除图标")
                    }
                    .buttonStyle(.plain)
                    .help("清除这段文字")
                }

                Text(output)
                    .font(.system(size: 12))
                    .foregroundStyle(.white.opacity(0.62))
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
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
            VStack(spacing: 5) {
                appIcon(icon, size: 18)
                    .foregroundStyle(tint)
                Text(title)
                    .font(.system(size: 11, weight: .semibold))
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity)
            .frame(height: 48)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var quickActionDivider: some View {
        Rectangle()
            .fill(.white.opacity(0.08))
            .frame(width: 1, height: 30)
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
        .help("退出 Olli")
        .accessibilityLabel("退出 Olli")
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

    private var friendlyHeaderStatus: String {
        switch model.phase {
        case .listening:
            return "我在听"
        case .processing:
            return "正在帮你整理"
        case .conversation:
            return "正在和你聊"
        case .failure:
            return "刚刚没有完成"
        case .result:
            return "内容已经准备好"
        case .notice:
            return "已经处理好了"
        case .hidden, .idle:
            if model.dashboard.serviceChecking { return "正在准备" }
            return model.dashboard.serviceAvailable ? "随时可以开始" : "暂时没连上"
        }
    }

    private var connectionState: String {
        if model.dashboard.serviceChecking { return "连接中" }
        return model.dashboard.serviceAvailable ? "已连接" : "需检查"
    }

    private var connectionDetail: String {
        if model.dashboard.serviceChecking {
            return "稍等一下，Olli 正在连接"
        }
        if model.dashboard.serviceAvailable {
            return "可以正常使用听写和对话"
        }
        return "暂时无法连接，请重新检查"
    }

    private var sessionUsageText: String {
        let conversations = model.dashboard.talkResponses
        let hasDictation = model.dashboard.dictationTokens > 0
        if conversations > 0, hasDictation {
            return "已聊 \(conversations) 轮，也完成了听写"
        }
        if conversations > 0 {
            return "已经和 Olli 聊了 \(conversations) 轮"
        }
        if hasDictation {
            return "已经完成一次听写"
        }
        return "还没有产生用量"
    }

    private var friendlyQuotaDetail: String {
        let label = model.dashboard.quotaLabel
        if label.contains("预付余额已用完") {
            return "余额已用完，请检查账户"
        }
        if label.contains("上限已触发") {
            return "账户用量已到上限"
        }
        if label.contains("Mock") {
            return "当前不会产生费用"
        }
        if label.contains("等待") {
            return "连接后会更新额度状态"
        }
        if label.contains("服务不可用") {
            return "暂时无法检查账户额度"
        }
        return "账户余额暂时无法直接查询"
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
