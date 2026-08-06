// 功能：提供 Olli 主工作台的运行监控与设置页面。
// 职责：使用主工作台共享样式呈现本地用量、服务、权限和进程管理命令，并把操作转发给 InputOverlayModel。
// 边界：只消费状态快照和事件闭包，不直接访问网络、系统权限、音频设备或持久化用户数据。

import SwiftUI

extension AppDashboardView {
    var monitoringPage: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 22) {
                pageHeader(
                    title: "运行监控",
                    subtitle: "服务、用量与本地可验证信号"
                )

                LazyVGrid(
                    columns: [GridItem(.adaptive(minimum: 140), spacing: 12)],
                    spacing: 12
                ) {
                    metricCard(
                        value: formattedCount(model.dashboard.talkResponses),
                        label: "Talk 回复",
                        iconAsset: "语音图标",
                        tint: .pink
                    )
                    metricCard(
                        value: formattedCount(model.dashboard.talkTokens),
                        label: "Talk token",
                        iconAsset: "处理器图标",
                        tint: .cyan
                    )
                    metricCard(
                        value: formattedCount(model.dashboard.dictationTokens),
                        label: "Dictate token",
                        iconAsset: "文字图标",
                        tint: .blue
                    )
                    metricCard(
                        value: formattedCost(model.dashboard.talkEstimatedCostUSD),
                        label: "费用估算",
                        iconAsset: "额度图标",
                        tint: .orange
                    )
                }

                tableSection(title: "服务与账户") {
                    informationRow(
                        title: "本地语音服务",
                        detail: model.dashboard.serviceLabel,
                        iconAsset: "云连接图标",
                        trailing: model.dashboard.serviceAvailable ? "可用" : "需检查",
                        trailingColor: statusColor
                    )
                    rowDivider
                    informationRow(
                        title: "当前模型",
                        detail: model.dashboard.model,
                        iconAsset: "处理器图标",
                        trailing: nil
                    )
                    rowDivider
                    informationRow(
                        title: "本地凭证签发",
                        detail: model.dashboard.sessionsIssued.map(String.init) ?? "--",
                        iconAsset: "网络图标",
                        trailing: nil
                    )
                    rowDivider
                    informationRow(
                        title: "账户额度",
                        detail: model.dashboard.quotaLabel,
                        iconAsset: "额度图标",
                        trailing: nil
                    )
                }
            }
            .padding(WorkspaceLayout.pagePadding)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    var settingsPage: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 22) {
                pageHeader(
                    title: "设置",
                    subtitle: "权限与本地管理"
                )

                tableSection(title: "系统权限") {
                    permissionRow(
                        title: "辅助功能",
                        detail: "写回当前输入框",
                        iconAsset: "鼠标图标",
                        isGranted: model.dashboard.accessibilityGranted,
                        actionTitle: "去设置",
                        action: { model.onRequestAccessibility?() }
                    )
                    rowDivider
                    permissionRow(
                        title: "麦克风",
                        detail: "Dictate 与语音 Agent",
                        iconAsset: "麦克风图标",
                        isGranted: model.dashboard.microphoneGranted,
                        actionTitle: model.dashboard.microphoneCanRequest ? "允许" : "去设置",
                        action: { model.onRequestMicrophone?() }
                    )
                    rowDivider
                    permissionRow(
                        title: "屏幕录制",
                        detail: "仅用于主动框选",
                        iconAsset: "框选图标",
                        isGranted: model.dashboard.screenCaptureGranted,
                        actionTitle: "去设置",
                        action: { model.onRequestScreenCapture?() }
                    )
                }

                tableSection(title: "通用") {
                    settingsCommandRow(
                        title: "刷新状态",
                        detail: "重新检查权限、服务与模型",
                        iconAsset: "刷新图标",
                        action: { model.onRefresh?() }
                    )

                    if model.dashboard.lastOutput?.isEmpty == false {
                        rowDivider
                        settingsCommandRow(
                            title: "清除最近结果",
                            detail: "移除内存中保留的转写结果",
                            iconAsset: "删除图标",
                            action: { model.onClearLastOutput?() }
                        )
                    }

                    rowDivider
                    settingsCommandRow(
                        title: "退出 Olli",
                        detail: "结束语音任务、快捷键和后台进程",
                        iconAsset: "退出图标",
                        tint: .pink,
                        action: { model.onQuit?() }
                    )
                    .keyboardShortcut("q")
                }
            }
            .padding(WorkspaceLayout.pagePadding)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    func pageHeader(title: String, subtitle: String) -> some View {
        HStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.system(size: 24, weight: .semibold))
                    .foregroundStyle(WorkspacePalette.ink)
                Text(subtitle)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(WorkspacePalette.muted)
            }
            Spacer(minLength: 12)
            HStack(spacing: 7) {
                Circle()
                    .fill(statusColor)
                    .frame(width: 7, height: 7)
                Text(model.dashboard.status)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(WorkspacePalette.muted)
                    .lineLimit(1)
            }
            iconButton(
                assetName: "刷新图标",
                help: "刷新 Olli 状态",
                action: { model.onRefresh?() }
            )
        }
    }

    func metricCard(
        value: String,
        label: String,
        iconAsset: String,
        tint: Color
    ) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            templateIcon(iconAsset, size: 18, color: tint)
                .frame(width: 34, height: 34)
                .background(
                    tint.opacity(0.09),
                    in: RoundedRectangle(cornerRadius: 8, style: .continuous)
                )
            Text(value)
                .font(.system(size: 22, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.72)
            Text(label)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(WorkspacePalette.muted)
                .lineLimit(1)
        }
        .padding(15)
        .frame(maxWidth: .infinity, minHeight: 122, alignment: .leading)
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

    func tableSection<Content: View>(
        title: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(WorkspacePalette.ink)

            VStack(spacing: 0) {
                content()
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

    func informationRow(
        title: String,
        detail: String,
        iconAsset: String,
        trailing: String?,
        trailingColor: Color = WorkspacePalette.muted
    ) -> some View {
        HStack(spacing: 12) {
            templateIcon(iconAsset, size: 18, color: WorkspacePalette.muted)
                .frame(width: 28, height: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 11, weight: .semibold))
                Text(detail)
                    .font(.system(size: 9))
                    .foregroundStyle(WorkspacePalette.muted)
                    .lineLimit(2)
            }
            Spacer(minLength: 12)
            if let trailing {
                Text(trailing)
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(trailingColor)
            }
        }
        .padding(.horizontal, 14)
        .frame(minHeight: 58)
    }

    func permissionRow(
        title: String,
        detail: String,
        iconAsset: String,
        isGranted: Bool,
        actionTitle: String,
        action: @escaping () -> Void
    ) -> some View {
        HStack(spacing: 12) {
            templateIcon(
                iconAsset,
                size: 18,
                color: isGranted ? .green : .orange
            )
            .frame(width: 28, height: 28)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 11, weight: .semibold))
                Text(detail)
                    .font(.system(size: 9))
                    .foregroundStyle(WorkspacePalette.muted)
                    .lineLimit(1)
            }

            Spacer(minLength: 12)

            if isGranted {
                Text("已开启")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.green)
            } else {
                Button(actionTitle, action: action)
                    .font(.system(size: 9, weight: .semibold))
                    .buttonStyle(.bordered)
                    .controlSize(.small)
            }
        }
        .padding(.horizontal, 14)
        .frame(minHeight: 58)
    }

    func settingsCommandRow(
        title: String,
        detail: String,
        iconAsset: String,
        tint: Color = WorkspacePalette.muted,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 12) {
                templateIcon(iconAsset, size: 18, color: tint)
                    .frame(width: 28, height: 28)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.system(size: 11, weight: .semibold))
                    Text(detail)
                        .font(.system(size: 9))
                        .foregroundStyle(WorkspacePalette.muted)
                        .lineLimit(1)
                }
                Spacer(minLength: 12)
                templateIcon("右箭头图标", size: 14, color: WorkspacePalette.muted)
            }
            .padding(.horizontal, 14)
            .frame(minHeight: 58)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
