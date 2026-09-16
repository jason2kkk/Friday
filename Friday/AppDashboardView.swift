// 功能：提供 Olli 独立主工作台，让用户在类 Flow 的原生浅色界面中集中使用转写、监控、权限、结果和设置。
// 职责：使用 NavigationSplitView 组织全高平面侧栏和右侧圆角内容画布，消费共享状态快照并把用户命令转发给应用级工作流。
// 边界：视图不直接读取系统权限、访问网络、管理凭证或控制音频设备，也不持久化用户内容或伪造历史记录。

import SwiftUI

private enum WorkspaceSection: String, CaseIterable, Identifiable {
    case overview = "转写"
    case agent = "Agent"
    case monitoring = "运行监控"
    case settings = "设置"

    var id: Self { self }

    var iconAsset: String {
        switch self {
        case .overview: return "麦克风图标"
        case .agent: return "处理器图标"
        case .monitoring: return "处理器图标"
        case .settings: return "设置图标"
        }
    }

    static var configuredPreview: WorkspaceSection {
        let preview = ProcessInfo.processInfo.environment["FRIDAY_WORKSPACE_PREVIEW"]?.lowercased()
        if preview?.hasPrefix("agent") == true { return .agent }
        if preview?.hasPrefix("monitoring") == true { return .monitoring }
        if preview?.hasPrefix("settings") == true { return .settings }
        return .overview
    }
}

enum WorkspacePalette {
    static let chrome = Color(red: 0.958, green: 0.956, blue: 0.948)
    static let canvas = Color(red: 0.995, green: 0.994, blue: 0.991)
    static let selection = Color(red: 0.914, green: 0.906, blue: 0.886)
    static let module = Color(red: 0.973, green: 0.970, blue: 0.960)
    static let line = Color.black.opacity(0.09)
    static let ink = Color(red: 0.085, green: 0.082, blue: 0.090)
    static let muted = Color(red: 0.38, green: 0.37, blue: 0.39)
    static let accent = Color(red: 1.0, green: 0.61, blue: 0.24)
    static let hero = Color(red: 0.075, green: 0.078, blue: 0.087)
}

enum WorkspaceLayout {
    static let sidebarWidth: CGFloat = 204
    static let pagePadding: CGFloat = 26
    static let canvasCornerRadius: CGFloat = 20
    static let moduleCornerRadius: CGFloat = 12
}

struct AppDashboardView: View {
    @ObservedObject var model: InputOverlayModel
    @State private var selectedSection = WorkspaceSection.configuredPreview

    var body: some View {
        NavigationSplitView {
            sidebar
                .navigationSplitViewColumnWidth(
                    min: 184,
                    ideal: WorkspaceLayout.sidebarWidth,
                    max: 228
                )
        } detail: {
            detailCanvas
                .padding(.top, 12)
                .padding(.trailing, 12)
                .padding(.bottom, 12)
        }
        .navigationSplitViewStyle(.balanced)
        .frame(minWidth: 760, minHeight: 560)
        .background(WorkspacePalette.chrome)
        .tint(WorkspacePalette.ink)
        .preferredColorScheme(.light)
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            brand

            VStack(spacing: 4) {
                navigationRow(.overview)
                navigationRow(.agent)
                navigationRow(.monitoring)
            }

            Spacer(minLength: 16)
            sidebarServiceCard
            Divider()
                .overlay(WorkspacePalette.line)
                .padding(.vertical, 10)
            navigationRow(.settings)
                .padding(.bottom, 10)
        }
        .padding(.horizontal, 12)
        .background(WorkspacePalette.chrome)
    }

    private var brand: some View {
        HStack(spacing: 10) {
            templateIcon(
                "波形图标",
                size: 30,
                color: WorkspacePalette.ink
            )

            VStack(alignment: .leading, spacing: 1) {
                OlliBrandText("Olli", brandSize: 20)
                    .font(.system(size: 20, weight: .bold))
                    .foregroundStyle(WorkspacePalette.ink)
                Text("Mac AI 助手")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(WorkspacePalette.muted)
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 8)
        .frame(height: 86)
    }

    private func navigationRow(_ section: WorkspaceSection) -> some View {
        Button {
            selectedSection = section
        } label: {
            HStack(spacing: 11) {
                templateIcon(
                    section.iconAsset,
                    size: 20,
                    color: selectedSection == section ? WorkspacePalette.ink : WorkspacePalette.muted
                )
                Text(section.rawValue)
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 12)
            .frame(height: 42)
            .contentShape(Rectangle())
            .background(
                selectedSection == section ? WorkspacePalette.selection : Color.clear,
                in: RoundedRectangle(cornerRadius: 8, style: .continuous)
            )
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selectedSection == section ? .isSelected : [])
    }

    private var sidebarServiceCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Circle()
                    .fill(statusColor)
                    .frame(width: 7, height: 7)
                    .shadow(color: statusColor.opacity(0.42), radius: 4)
                OlliBrandText(model.dashboard.serviceLabel, brandSize: 11)
                    .font(.system(size: 11, weight: .semibold))
                    .lineLimit(2)
                Spacer(minLength: 0)
            }

            Text(model.dashboard.model)
                .font(.system(size: 9, weight: .medium, design: .monospaced))
                .foregroundStyle(WorkspacePalette.muted)
                .lineLimit(1)

            Button {
                model.onRefresh?()
            } label: {
                HStack(spacing: 7) {
                    templateIcon("刷新图标", size: 14, color: WorkspacePalette.ink)
                    Text("刷新状态")
                        .font(.system(size: 10, weight: .semibold))
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 10)
                .frame(height: 32)
                .background(
                    Color.white.opacity(0.72),
                    in: RoundedRectangle(cornerRadius: 7, style: .continuous)
                )
            }
            .buttonStyle(.plain)
        }
        .padding(13)
        .background(
            Color.white.opacity(0.48),
            in: RoundedRectangle(cornerRadius: 10, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(WorkspacePalette.line, lineWidth: 1)
        }
    }

    private var detailCanvas: some View {
        Group {
            switch selectedSection {
            case .overview:
                overviewPage
            case .agent:
                computerUseTaskPage
            case .monitoring:
                monitoringPage
            case .settings:
                settingsPage
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(WorkspacePalette.canvas)
        .clipShape(
            RoundedRectangle(
                cornerRadius: WorkspaceLayout.canvasCornerRadius,
                style: .continuous
            )
        )
        .overlay {
            RoundedRectangle(
                cornerRadius: WorkspaceLayout.canvasCornerRadius,
                style: .continuous
            )
            .strokeBorder(WorkspacePalette.line, lineWidth: 1)
        }
    }

    private var overviewPage: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 22) {
                overviewHeader

                HStack(alignment: .top, spacing: 14) {
                    heroPanel
                    runSummary
                }

                activitySection
            }
            .padding(WorkspaceLayout.pagePadding)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var overviewHeader: some View {
        HStack(spacing: 10) {
            Text("欢迎回来，按下")
                .font(.system(size: 24, weight: .semibold))
                .foregroundStyle(WorkspacePalette.ink)
                .lineLimit(1)

            Text("fn")
                .font(.system(size: 17, weight: .heavy, design: .monospaced))
                .foregroundStyle(WorkspacePalette.ink)
                .padding(.horizontal, 8)
                .frame(height: 32)
                .background(
                    WorkspacePalette.accent,
                    in: RoundedRectangle(cornerRadius: 7, style: .continuous)
                )
                .overlay {
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .strokeBorder(WorkspacePalette.ink, lineWidth: 1.5)
                }

            Text("开始转写")
                .font(.system(size: 24, weight: .semibold))
                .foregroundStyle(WorkspacePalette.ink)
                .lineLimit(1)

            Spacer(minLength: 8)
            iconButton(
                assetName: "刷新图标",
                help: "刷新 Olli 状态",
                action: { model.onRefresh?() }
            )
        }
    }

    private var heroPanel: some View {
        ZStack {
            RoundedRectangle(
                cornerRadius: WorkspaceLayout.moduleCornerRadius,
                style: .continuous
            )
            .fill(WorkspacePalette.hero)

            HeroSignalPattern()
                .clipShape(
                    RoundedRectangle(
                        cornerRadius: WorkspaceLayout.moduleCornerRadius,
                        style: .continuous
                    )
                )

            HStack(alignment: .top, spacing: 16) {
                VStack(alignment: .leading, spacing: 0) {
                    OlliBrandText(model.dashboard.status, brandSize: 19)
                        .font(.system(size: 19, weight: .semibold))
                        .foregroundStyle(.white)
                        .lineLimit(1)

                    OlliBrandText(currentStatusDetail, brandSize: 11)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.white.opacity(0.68))
                        .lineLimit(3)
                        .padding(.top, 6)

                    Spacer(minLength: 10)

                    HStack(spacing: 8) {
                        heroActionButton(
                            title: model.dashboard.isDictationActive ? "结束转写" : "开始转写",
                            assetName: model.dashboard.isDictationActive ? "停止图标" : "文字图标",
                            isPrimary: true,
                            action: { model.onToggleDictation?() }
                        )
                        heroActionButton(
                            title: model.dashboard.isConversationActive ? "结束对话" : "语音 Agent",
                            assetName: model.dashboard.isConversationActive ? "停止图标" : "语音图标",
                            isPrimary: false,
                            action: { model.onToggleConversation?() }
                        )
                    }
                }

                Spacer(minLength: 0)

                VStack(spacing: 10) {
                    heroIconChip("文字图标", color: .cyan)
                    heroIconChip("语音图标", color: .pink)
                    heroIconChip("框选图标", color: WorkspacePalette.accent)
                }
            }
            .padding(18)
        }
        .frame(maxWidth: .infinity, minHeight: 168, maxHeight: 168)
    }

    private func heroActionButton(
        title: String,
        assetName: String,
        isPrimary: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 7) {
                templateIcon(
                    assetName,
                    size: 15,
                    color: isPrimary ? WorkspacePalette.ink : .white
                )
                OlliBrandText(title, brandSize: 10)
                    .font(.system(size: 10, weight: .semibold))
                    .lineLimit(1)
            }
            .padding(.horizontal, 11)
            .frame(height: 32)
        }
        .buttonStyle(WorkspaceActionButtonStyle(isPrimary: isPrimary))
    }

    private func heroIconChip(_ assetName: String, color: Color) -> some View {
        templateIcon(assetName, size: 19, color: color)
            .frame(width: 36, height: 36)
            .background(
                Color.white.opacity(0.11),
                in: Circle()
            )
            .overlay {
                Circle()
                    .strokeBorder(Color.white.opacity(0.16), lineWidth: 1)
            }
    }

    private var runSummary: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("本次运行")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(WorkspacePalette.ink)
                .padding(.bottom, 8)

            summaryMetric(
                formattedCount(model.dashboard.talkResponses),
                label: "Talk 回复"
            )
            summaryMetric(
                formattedCount(model.dashboard.talkTokens + model.dashboard.dictationTokens),
                label: "token"
            )
            summaryMetric(
                formattedCost(model.dashboard.talkEstimatedCostUSD),
                label: "预估费用"
            )

            Spacer(minLength: 4)
            Divider().overlay(WorkspacePalette.line)
            HStack(spacing: 7) {
                Circle()
                    .fill(statusColor)
                    .frame(width: 6, height: 6)
                Text(model.dashboard.serviceAvailable ? "服务可用" : "需要检查")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(WorkspacePalette.muted)
                    .lineLimit(1)
            }
            .padding(.top, 8)
        }
        .padding(15)
        .frame(width: 170, height: 168, alignment: .topLeading)
        .background(
            WorkspacePalette.module,
            in: RoundedRectangle(
                cornerRadius: WorkspaceLayout.moduleCornerRadius,
                style: .continuous
            )
        )
        .overlay {
            RoundedRectangle(
                cornerRadius: WorkspaceLayout.moduleCornerRadius,
                style: .continuous
            )
            .strokeBorder(WorkspacePalette.line, lineWidth: 1)
        }
    }

    private func summaryMetric(_ value: String, label: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 7) {
            Text(value)
                .font(.system(size: 18, weight: .medium, design: .rounded))
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.72)
            Text(label)
                .font(.system(size: 9, weight: .medium))
                .foregroundStyle(WorkspacePalette.muted)
                .lineLimit(1)
            Spacer(minLength: 0)
        }
        .frame(height: 27)
    }

    private var activitySection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("最近结果")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(WorkspacePalette.ink)
                Text("仅保留当前内存中的内容")
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(WorkspacePalette.muted)
                Spacer(minLength: 0)
            }

            VStack(spacing: 0) {
                recentOutputRow
                rowDivider
                serviceActivityRow

                ForEach(Array(attentionItems.enumerated()), id: \.element.id) { _, item in
                    rowDivider
                    attentionActivityRow(item)
                }
            }
            .background(
                WorkspacePalette.canvas,
                in: RoundedRectangle(
                    cornerRadius: WorkspaceLayout.moduleCornerRadius,
                    style: .continuous
                )
            )
            .overlay {
                RoundedRectangle(
                    cornerRadius: WorkspaceLayout.moduleCornerRadius,
                    style: .continuous
                )
                .strokeBorder(WorkspacePalette.line, lineWidth: 1)
            }
        }
    }

    @ViewBuilder
    private var recentOutputRow: some View {
        if let output = model.dashboard.lastOutput, !output.isEmpty {
            HStack(alignment: .center, spacing: 12) {
                Text("最近")
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(WorkspacePalette.muted)
                    .frame(width: 42, alignment: .leading)

                OlliBrandText(output, brandSize: 12)
                    .font(.system(size: 12))
                    .foregroundStyle(WorkspacePalette.ink)
                    .lineLimit(3)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)

                if model.dashboard.canRetry {
                    iconButton(
                        assetName: "刷新图标",
                        help: "重试最近一次转写",
                        action: { model.onRetry?() }
                    )
                }
                iconButton(
                    assetName: "复制图标",
                    help: "复制最近结果",
                    action: { model.onCopy?() }
                )
            }
            .padding(.horizontal, 14)
            .frame(minHeight: 66)
        } else {
            HStack(spacing: 12) {
                templateIcon("完成图标", size: 18, color: WorkspacePalette.muted)
                Text("还没有可恢复的转写结果")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(WorkspacePalette.muted)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 14)
            .frame(minHeight: 58)
        }
    }

    private var serviceActivityRow: some View {
        HStack(spacing: 12) {
            templateIcon("云连接图标", size: 18, color: statusColor)
            VStack(alignment: .leading, spacing: 2) {
                Text("本地语音服务")
                    .font(.system(size: 11, weight: .semibold))
                OlliBrandText(model.dashboard.serviceLabel, brandSize: 9)
                    .font(.system(size: 9))
                    .foregroundStyle(WorkspacePalette.muted)
                    .lineLimit(1)
            }
            Spacer(minLength: 12)
            Text(model.dashboard.serviceAvailable ? "可用" : "需检查")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(statusColor)
        }
        .padding(.horizontal, 14)
        .frame(minHeight: 56)
    }

    private func attentionActivityRow(_ item: AttentionItem) -> some View {
        HStack(spacing: 12) {
            templateIcon(item.iconAsset, size: 18, color: .orange)
            OlliBrandText(item.title, brandSize: 11)
                .font(.system(size: 11, weight: .medium))
                .lineLimit(1)
            Spacer(minLength: 12)
            Button(item.actionTitle, action: item.action)
                .font(.system(size: 9, weight: .semibold))
                .buttonStyle(.bordered)
                .controlSize(.small)
        }
        .padding(.horizontal, 14)
        .frame(minHeight: 54)
    }

    func iconButton(
        assetName: String,
        help: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            templateIcon(assetName, size: 15, color: WorkspacePalette.ink)
                .frame(width: 32, height: 32)
        }
        .buttonStyle(WorkspaceIconButtonStyle())
        .help(help)
        .accessibilityLabel(help)
    }

    func templateIcon(
        _ assetName: String,
        size: CGFloat,
        color: Color
    ) -> some View {
        Image(assetName)
            .renderingMode(.template)
            .resizable()
            .interpolation(.high)
            .aspectRatio(contentMode: .fit)
            .foregroundStyle(color)
            .frame(width: size, height: size)
    }

    var rowDivider: some View {
        Divider()
            .overlay(WorkspacePalette.line)
            .padding(.leading, 54)
    }

    private var attentionItems: [AttentionItem] {
        var items: [AttentionItem] = []
        let dashboard = model.dashboard

        if !dashboard.accessibilityGranted {
            items.append(
                AttentionItem(
                    id: "accessibility",
                    title: "辅助功能尚未开启",
                    iconAsset: "鼠标图标",
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
                    iconAsset: "麦克风关闭图标",
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
                    iconAsset: "框选图标",
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
                    iconAsset: "网络图标",
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
                    iconAsset: "刷新图标",
                    actionTitle: "重试",
                    action: { model.onRetry?() }
                )
            )
        }
        return items
    }

    private var currentStatusDetail: String {
        if model.dashboard.isConversationActive {
            return "语音 Agent 正在运行，框选屏幕会附加到当前对话。"
        }
        if model.dashboard.isDictationActive {
            return "Olli 正在整理你的口述，完成后优先写回原输入位置。"
        }
        return "在当前应用中自然表达，Olli 会把整理结果送回原输入位置。"
    }

    var statusColor: Color {
        if model.dashboard.isConversationActive { return .pink }
        if model.dashboard.isDictationActive { return .cyan }
        if model.dashboard.serviceChecking { return .orange }
        return model.dashboard.serviceAvailable ? .green : .orange
    }

    func formattedCount(_ value: Int) -> String {
        value.formatted(.number.grouping(.automatic))
    }

    func formattedCost(_ value: Double) -> String {
        String(format: "$%.4f", value)
    }
}

private struct AttentionItem {
    let id: String
    let title: String
    let iconAsset: String
    let actionTitle: String
    let action: () -> Void
}

private struct HeroSignalPattern: View {
    var body: some View {
        Canvas { context, size in
            let centerY = size.height * 0.53
            let spacing = max(size.width / 28, 8)

            for index in 0...28 {
                let x = CGFloat(index) * spacing
                let phase = CGFloat(index) * 0.72
                let height = 10 + (sin(phase) + 1) * 14
                var path = Path()
                path.move(to: CGPoint(x: x, y: centerY - height))
                path.addLine(to: CGPoint(x: x, y: centerY + height))
                context.stroke(
                    path,
                    with: .color(.white.opacity(index.isMultiple(of: 3) ? 0.10 : 0.045)),
                    lineWidth: 1
                )
            }
        }
        .allowsHitTesting(false)
    }
}

private struct WorkspaceIconButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(
                configuration.isPressed
                    ? WorkspacePalette.selection
                    : WorkspacePalette.module,
                in: RoundedRectangle(cornerRadius: 8, style: .continuous)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(WorkspacePalette.line, lineWidth: 1)
            }
    }
}

private struct WorkspaceActionButtonStyle: ButtonStyle {
    let isPrimary: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(isPrimary ? WorkspacePalette.ink : Color.white)
            .background(
                isPrimary ? Color.white : Color.white.opacity(0.09),
                in: RoundedRectangle(cornerRadius: 7, style: .continuous)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .strokeBorder(
                        isPrimary ? Color.clear : Color.white.opacity(0.17),
                        lineWidth: 1
                    )
            }
            .opacity(configuration.isPressed ? 0.74 : 1)
    }
}

@MainActor
struct AppDashboardView_Previews: PreviewProvider {
    static var previews: some View {
        let model = InputOverlayModel()
        model.dashboard = .preview
        return AppDashboardView(model: model)
            .frame(width: 920, height: 640)
    }
}
