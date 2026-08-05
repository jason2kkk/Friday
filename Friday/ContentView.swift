// 功能：提供 Friday 独立主工作台，让用户在原生浅色玻璃界面中集中查看状态、监控、权限、结果和设置。
// 职责：在原生标题栏和交通灯下方提供悬浮圆角 Liquid Glass 侧边栏，使用 macOS sidebar List 呈现概览、运行监控和设置，并把用户命令转发给应用级工作流。
// 边界：视图不直接读取系统权限、访问网络、管理凭证或控制音频设备，也不持久化用户内容。

import SwiftUI
private enum WorkspaceSection: String, CaseIterable, Identifiable {
    case overview = "概览"
    case monitoring = "运行监控"
    case settings = "设置"

    var id: Self { self }
    var symbol: String {
        switch self {
        case .overview: return "square.grid.2x2"
        case .monitoring: return "waveform.path.ecg"
        case .settings: return "gearshape"
        }
    }
    static var configuredPreview: WorkspaceSection {
        let preview = ProcessInfo.processInfo.environment["FRIDAY_WORKSPACE_PREVIEW"]?.lowercased()
        if preview?.hasPrefix("monitoring") == true { return .monitoring }
        if preview?.hasPrefix("settings") == true { return .settings }
        return .overview
    }
}

struct ContentView: View {
    @ObservedObject var model: InputOverlayModel
    @State private var selectedSection = WorkspaceSection.configuredPreview
    var body: some View {
        NavigationSplitView {
            sidebar
                .navigationSplitViewColumnWidth(min: 190, ideal: 220, max: 250)
        } detail: {
            detail
        }
        .navigationSplitViewStyle(.balanced)
        .frame(minWidth: 760, minHeight: 560)
        .background(Color.white.opacity(0.42))
        .tint(.blue)
        .preferredColorScheme(.light)
    }
    private var sidebar: some View {
        VStack(spacing: 0) {
            brand

            List(WorkspaceSection.allCases, selection: $selectedSection) { section in
                Label(section.rawValue, systemImage: section.symbol)
                    .font(.system(size: 13, weight: .medium))
                    .tag(section)
            }
            .listStyle(.sidebar)
            .scrollContentBackground(.hidden)
            .padding(.horizontal, 8)

            Divider()
                .padding(.horizontal, 14)
            sidebarStatus
        }
        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        .background(
            Color.white.opacity(0.2),
            in: RoundedRectangle(cornerRadius: 22, style: .continuous)
        )
        .nativeGlassSurface(cornerRadius: 22)
        .shadow(color: .black.opacity(0.09), radius: 14, y: 5)
        .padding(12)
    }

    private var brand: some View {
        HStack(spacing: 11) {
            Image("灵动岛图标")
                .renderingMode(.original)
                .resizable()
                .interpolation(.high)
                .aspectRatio(contentMode: .fit)
                .frame(width: 32, height: 32)

            VStack(alignment: .leading, spacing: 1) {
                Text("Friday")
                    .font(.system(size: 17, weight: .semibold))
                Text("Mac 助手")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
        .frame(height: 72)
    }

    private var sidebarStatus: some View {
        HStack(spacing: 9) {
            Circle()
                .fill(statusColor)
                .frame(width: 8, height: 8)
                .shadow(color: statusColor.opacity(0.45), radius: 4)
            VStack(alignment: .leading, spacing: 2) {
                Text(model.dashboard.serviceLabel)
                    .font(.system(size: 10, weight: .semibold))
                    .lineLimit(2)
                Text("空闲时不使用麦克风")
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
        .frame(minHeight: 66)
    }

    private var detail: some View {
        VStack(spacing: 0) {
            detailHeader
            Divider()

            Group {
                switch selectedSection {
                case .overview:
                    overviewPage
                case .monitoring:
                    monitoringPage
                case .settings:
                    settingsPage
                }
            }
        }
        .background(Color.white.opacity(0.18))
    }

    private var detailHeader: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(selectedSection.rawValue)
                    .font(.system(size: 20, weight: .semibold))
                Text(headerSubtitle)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 16)

            HStack(spacing: 7) {
                Circle()
                    .fill(statusColor)
                    .frame(width: 7, height: 7)
                Text(model.dashboard.status)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .padding(.horizontal, 11)
            .frame(height: 30)
            .nativeGlassSurface(cornerRadius: 15)

            Button(action: { model.onRefresh?() }) {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 12, weight: .semibold))
                    .frame(width: 30, height: 30)
            }
            .buttonStyle(.glassIcon)
            .help("刷新 Friday 状态")
            .accessibilityLabel("刷新 Friday 状态")
        }
        .padding(.horizontal, 24)
        .frame(height: 72)
        .background(.ultraThinMaterial)
    }

    private var overviewPage: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 22) {
                currentStatusBand
                quickActions
                attentionSection
                recentResultSection
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var currentStatusBand: some View {
        HStack(spacing: 18) {
            Image(systemName: currentStatusSymbol)
                .font(.system(size: 22, weight: .medium))
                .foregroundStyle(statusColor)
                .frame(width: 52, height: 52)
                .background(statusColor.opacity(0.1), in: RoundedRectangle(cornerRadius: 12))

            VStack(alignment: .leading, spacing: 4) {
                Text(model.dashboard.status)
                    .font(.system(size: 18, weight: .semibold))
                Text(currentStatusDetail)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }

            Spacer(minLength: 16)

            VStack(alignment: .trailing, spacing: 4) {
                Text(model.dashboard.model)
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    .lineLimit(1)
                Text(model.dashboard.serviceLabel)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .nativeGlassSurface()
    }

    private var quickActions: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionTitle("快捷操作", detail: "也可以继续使用全局快捷键")

            HStack(spacing: 10) {
                commandButton(
                    title: model.dashboard.isDictationActive ? "结束转写" : "开始转写",
                    detail: "Fn",
                    symbol: model.dashboard.isDictationActive ? "stop.fill" : "text.cursor",
                    tint: .cyan,
                    action: { model.onToggleDictation?() }
                )
                commandButton(
                    title: model.dashboard.isConversationActive ? "结束对话" : "语音 Agent",
                    detail: "Control + Option",
                    symbol: model.dashboard.isConversationActive ? "stop.fill" : "waveform",
                    tint: .pink,
                    action: { model.onToggleConversation?() }
                )
                commandButton(
                    title: "框选屏幕",
                    detail: "Talk 期间可用",
                    symbol: "viewfinder",
                    tint: .orange,
                    action: { model.onSelectScreenRegion?() }
                )
                .disabled(!model.dashboard.isConversationActive)
                .opacity(model.dashboard.isConversationActive ? 1 : 0.48)
            }
        }
    }

    @ViewBuilder
    private var attentionSection: some View {
        let items = attentionItems
        if !items.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                sectionTitle("需要处理", detail: "只显示当前可恢复的问题")
                VStack(spacing: 0) {
                    ForEach(items.indices, id: \.self) { index in
                        attentionRow(items[index])
                        if index < items.count - 1 { rowDivider }
                    }
                }
                .nativeGlassSurface()
            }
        }
    }

    private var recentResultSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionTitle("最近结果", detail: "只保留当前内存中的恢复内容")

            if let output = model.dashboard.lastOutput, !output.isEmpty {
                VStack(alignment: .leading, spacing: 14) {
                    Text(output)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .lineLimit(7)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)

                    HStack(spacing: 8) {
                        Spacer()
                        if model.dashboard.canRetry {
                            Button("重试", systemImage: "arrow.clockwise") {
                                model.onRetry?()
                            }
                        }
                        Button("复制", systemImage: "doc.on.doc") {
                            model.onCopy?()
                        }
                        .buttonStyle(.borderedProminent)
                    }
                    .controlSize(.small)
                }
                .padding(16)
                .nativeGlassSurface()
            } else {
                Label("没有需要恢复的结果", systemImage: "checkmark.circle")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 16)
                    .frame(maxWidth: .infinity, minHeight: 50, alignment: .leading)
                    .nativeGlassSurface()
            }
        }
    }

    private var monitoringPage: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 22) {
                serviceMonitor

                VStack(alignment: .leading, spacing: 10) {
                    sectionTitle("本次运行", detail: "本地可验证的使用信号")
                    LazyVGrid(
                        columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: 4),
                        spacing: 10
                    ) {
                        metricCard(
                            value: "\(model.dashboard.talkResponses)",
                            label: "Talk 回复",
                            symbol: "bubble.left.and.waveform"
                        )
                        metricCard(
                            value: formattedCount(model.dashboard.talkTokens),
                            label: "Talk token",
                            symbol: "number"
                        )
                        metricCard(
                            value: formattedCost(model.dashboard.talkEstimatedCostUSD),
                            label: "费用估算",
                            symbol: "dollarsign"
                        )
                        metricCard(
                            value: model.dashboard.sessionsIssued.map(String.init) ?? "--",
                            label: "本地签发",
                            symbol: "key.horizontal"
                        )
                    }
                }

                informationBand(
                    symbol: "textformat",
                    title: "最近 Dictate",
                    detail: "\(formattedCount(model.dashboard.dictationTokens)) token",
                    tint: .cyan
                )
                informationBand(
                    symbol: "creditcard",
                    title: "账户额度",
                    detail: model.dashboard.quotaLabel,
                    tint: .orange
                )
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var serviceMonitor: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionTitle("语音服务", detail: "健康检查不会创建模型响应")

            HStack(spacing: 14) {
                Image(systemName: "point.3.connected.trianglepath.dotted")
                    .font(.system(size: 18, weight: .medium))
                    .foregroundStyle(statusColor)
                    .frame(width: 44, height: 44)
                    .background(statusColor.opacity(0.1), in: RoundedRectangle(cornerRadius: 11))

                VStack(alignment: .leading, spacing: 3) {
                    Text(model.dashboard.serviceLabel)
                        .font(.system(size: 13, weight: .semibold))
                    Text("模型：\(model.dashboard.model)")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.secondary)
                }

                Spacer(minLength: 12)

                Text(model.dashboard.serviceAvailable ? "可用" : "需检查")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(statusColor)
            }
            .padding(16)
            .nativeGlassSurface()
        }
    }

    private var settingsPage: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 22) {
                VStack(alignment: .leading, spacing: 10) {
                    sectionTitle("系统权限", detail: "权限仍由 macOS 管理")
                    VStack(spacing: 0) {
                        permissionRow(
                            title: "辅助功能",
                            detail: "写回当前输入框",
                            symbol: "cursorarrow.click.2",
                            isGranted: model.dashboard.accessibilityGranted,
                            actionTitle: "去设置",
                            action: { model.onRequestAccessibility?() }
                        )
                        rowDivider
                        permissionRow(
                            title: "麦克风",
                            detail: "仅在 Dictate 或 Talk 期间使用",
                            symbol: "mic",
                            isGranted: model.dashboard.microphoneGranted,
                            actionTitle: model.dashboard.microphoneCanRequest ? "允许" : "去设置",
                            action: { model.onRequestMicrophone?() }
                        )
                        rowDivider
                        permissionRow(
                            title: "屏幕录制",
                            detail: "仅在 Talk 中主动框选时使用",
                            symbol: "rectangle.dashed",
                            isGranted: model.dashboard.screenCaptureGranted,
                            actionTitle: "去设置",
                            action: { model.onRequestScreenCapture?() }
                        )
                    }
                    .nativeGlassSurface()
                }

                VStack(alignment: .leading, spacing: 10) {
                    sectionTitle("通用", detail: "本地状态与进程管理")
                    VStack(spacing: 0) {
                        settingsCommandRow(
                            title: "刷新状态",
                            detail: "重新检查权限、服务与模型",
                            symbol: "arrow.clockwise",
                            action: { model.onRefresh?() }
                        )
                        if model.dashboard.lastOutput?.isEmpty == false {
                            rowDivider
                            settingsCommandRow(
                                title: "清除最近结果",
                                detail: "移除内存中保留的转写结果",
                                symbol: "trash",
                                action: { model.onClearLastOutput?() }
                            )
                        }
                        rowDivider
                        settingsCommandRow(
                            title: "退出 Friday",
                            detail: "结束语音任务、快捷键和后台进程",
                            symbol: "power",
                            tint: .pink,
                            action: { model.onQuit?() }
                        )
                        .keyboardShortcut("q")
                    }
                    .nativeGlassSurface()
                }
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func commandButton(
        title: String,
        detail: String,
        symbol: String,
        tint: Color,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 12) {
                Image(systemName: symbol)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(tint)
                    .frame(width: 32, height: 32)
                    .background(tint.opacity(0.1), in: RoundedRectangle(cornerRadius: 9))
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.system(size: 12, weight: .semibold))
                    Text(detail)
                        .font(.system(size: 9))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, minHeight: 94, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .nativeGlassSurface()
    }

    private func metricCard(value: String, label: String, symbol: String) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
            Text(value)
                .font(.system(size: 17, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.68)
            Text(label)
                .font(.system(size: 9, weight: .medium))
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .padding(14)
        .frame(maxWidth: .infinity, minHeight: 100, alignment: .leading)
        .nativeGlassSurface()
    }

    private func informationBand(
        symbol: String,
        title: String,
        detail: String,
        tint: Color
    ) -> some View {
        HStack(spacing: 12) {
            Image(systemName: symbol)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(tint)
                .frame(width: 34, height: 34)
                .background(tint.opacity(0.1), in: RoundedRectangle(cornerRadius: 9))
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 11, weight: .semibold))
                Text(detail)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            Spacer(minLength: 0)
        }
        .padding(14)
        .nativeGlassSurface()
    }

    private func permissionRow(
        title: String,
        detail: String,
        symbol: String,
        isGranted: Bool,
        actionTitle: String,
        action: @escaping () -> Void
    ) -> some View {
        HStack(spacing: 12) {
            Image(systemName: symbol)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(isGranted ? Color.green : Color.orange)
                .frame(width: 34, height: 34)
                .background(
                    (isGranted ? Color.green : Color.orange).opacity(0.1),
                    in: RoundedRectangle(cornerRadius: 9)
                )
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 12, weight: .semibold))
                Text(detail)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 12)
            if isGranted {
                Label("已开启", systemImage: "checkmark.circle.fill")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.green)
            } else {
                Button(actionTitle, action: action)
                    .font(.system(size: 10, weight: .semibold))
                    .buttonStyle(.bordered)
                    .controlSize(.small)
            }
        }
        .padding(.horizontal, 14)
        .frame(height: 62)
    }

    private func settingsCommandRow(
        title: String,
        detail: String,
        symbol: String,
        tint: Color = .secondary,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: symbol)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(tint)
                    .frame(width: 34, height: 34)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.system(size: 12, weight: .semibold))
                    Text(detail)
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 12)
                Image(systemName: "chevron.right")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 14)
            .frame(height: 58)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func attentionRow(_ item: AttentionItem) -> some View {
        HStack(spacing: 12) {
            Image(systemName: item.symbol)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.orange)
                .frame(width: 28, height: 28)
            Text(item.title)
                .font(.system(size: 11, weight: .medium))
            Spacer(minLength: 12)
            Button(item.actionTitle, action: item.action)
                .font(.system(size: 10, weight: .semibold))
                .buttonStyle(.bordered)
                .controlSize(.small)
        }
        .padding(.horizontal, 14)
        .frame(height: 52)
    }

    private func sectionTitle(_ title: String, detail: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(title)
                .font(.system(size: 13, weight: .semibold))
            Text(detail)
                .font(.system(size: 9))
                .foregroundStyle(.secondary)
            Spacer(minLength: 0)
        }
    }

    private var rowDivider: some View {
        Divider()
            .padding(.leading, 58)
            .padding(.trailing, 14)
    }

    private var attentionItems: [AttentionItem] {
        var items: [AttentionItem] = []
        let dashboard = model.dashboard

        if !dashboard.accessibilityGranted {
            items.append(
                AttentionItem(
                    id: "accessibility",
                    title: "辅助功能尚未开启",
                    symbol: "cursorarrow.click.2",
                    actionTitle: "处理",
                    action: { model.onRequestAccessibility?() }
                )
            )
        }
        if !dashboard.microphoneGranted {
            items.append(
                AttentionItem(
                    id: "microphone",
                    title: "麦克风权限尚未开启",
                    symbol: "mic.slash",
                    actionTitle: dashboard.microphoneCanRequest ? "允许" : "设置",
                    action: { model.onRequestMicrophone?() }
                )
            )
        }
        if !dashboard.screenCaptureGranted {
            items.append(
                AttentionItem(
                    id: "screen-capture",
                    title: "框选屏幕需要录屏权限",
                    symbol: "rectangle.dashed",
                    actionTitle: "设置",
                    action: { model.onRequestScreenCapture?() }
                )
            )
        }
        if dashboard.serviceNeedsAttention {
            items.append(
                AttentionItem(
                    id: "service",
                    title: dashboard.serviceLabel,
                    symbol: "network.slash",
                    actionTitle: "重试",
                    action: { model.onRefresh?() }
                )
            )
        }
        if dashboard.canRetry {
            items.append(
                AttentionItem(
                    id: "retry",
                    title: "上一次操作可以恢复",
                    symbol: "arrow.clockwise",
                    actionTitle: "重试",
                    action: { model.onRetry?() }
                )
            )
        }
        return items
    }

    private var headerSubtitle: String {
        switch selectedSection {
        case .overview: return "即时状态与常用操作"
        case .monitoring: return "服务、用量与费用信号"
        case .settings: return "权限与本地管理"
        }
    }

    private var currentStatusDetail: String {
        if model.dashboard.isConversationActive {
            return "Talk 正在运行，主窗口与顶部灵动岛使用同一状态。"
        }
        if model.dashboard.isDictationActive {
            return "Dictate 正在运行，完成后会优先写回原输入位置。"
        }
        return "Friday 在后台等待快捷键，当前不会持续读取麦克风或屏幕。"
    }

    private var currentStatusSymbol: String {
        if model.dashboard.isConversationActive { return "waveform" }
        if model.dashboard.isDictationActive { return "text.cursor" }
        if model.dashboard.serviceChecking { return "arrow.triangle.2.circlepath" }
        return model.dashboard.serviceAvailable ? "checkmark" : "exclamationmark"
    }

    private var statusColor: Color {
        if model.dashboard.isConversationActive { return .pink }
        if model.dashboard.isDictationActive { return .cyan }
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

private struct AttentionItem {
    let id: String
    let title: String
    let symbol: String
    let actionTitle: String
    let action: () -> Void
}

private extension View {
    @ViewBuilder
    func nativeGlassSurface(cornerRadius: CGFloat = 14) -> some View {
        if #available(macOS 26.0, *) {
            glassEffect(
                .regular.tint(.white.opacity(0.42)),
                in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            )
        } else {
            background(
                .regularMaterial,
                in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            )
            .overlay {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(.white.opacity(0.58), lineWidth: 1)
            }
        }
    }
}

private struct GlassIconButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(.primary)
            .nativeGlassSurface(cornerRadius: 15)
            .opacity(configuration.isPressed ? 0.72 : 1)
    }
}

private extension ButtonStyle where Self == GlassIconButtonStyle {
    static var glassIcon: GlassIconButtonStyle { GlassIconButtonStyle() }
}

@MainActor
struct ContentView_Previews: PreviewProvider {
    static var previews: some View {
        let model = InputOverlayModel()
        model.dashboard = .preview
        return ContentView(model: model)
            .frame(width: 920, height: 640)
    }
}
