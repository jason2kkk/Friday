// 功能：在 Olli 主工作台提供首个可验证 Computer Use 文字任务入口。
// 职责：展示固定 TextEdit 烟囱任务、目标路径、执行状态以及运行或取消命令，并把事件交还应用工作流。
// 边界：视图不启动应用、不发送键盘事件、不读写文件，也不展示 AX 树、截图或内部推理。

import SwiftUI

extension AppDashboardView {
    var computerUseTaskPage: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 22) {
                pageHeader(
                    title: "Agent",
                    subtitle: "首个本地可验证任务"
                )

                VStack(alignment: .leading, spacing: 18) {
                    HStack(alignment: .top, spacing: 14) {
                        templateIcon(
                            "处理器图标",
                            size: 22,
                            color: WorkspacePalette.accent
                        )
                        .frame(width: 40, height: 40)
                        .background(
                            WorkspacePalette.accent.opacity(0.10),
                            in: RoundedRectangle(cornerRadius: 8, style: .continuous)
                        )

                        VStack(alignment: .leading, spacing: 5) {
                            Text("TextEdit 文件任务")
                                .font(.system(size: 15, weight: .semibold))
                                .foregroundStyle(WorkspacePalette.ink)
                            Text("打开 TextEdit，新建文档，写入 Friday agent smoke test，并保存到指定测试目录。")
                                .font(.system(size: 11))
                                .foregroundStyle(WorkspacePalette.muted)
                                .fixedSize(horizontal: false, vertical: true)
                        }

                        Spacer(minLength: 8)
                    }

                    Divider().overlay(WorkspacePalette.line)

                    VStack(alignment: .leading, spacing: 6) {
                        Text("目标文件")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(WorkspacePalette.muted)
                        Text(model.computerUseTaskPath)
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(WorkspacePalette.ink)
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    HStack(spacing: 10) {
                        Circle()
                            .fill(computerUseTaskTint)
                            .frame(width: 7, height: 7)
                        Text(model.computerUseTaskState.userFacingText)
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(WorkspacePalette.muted)
                            .lineLimit(2)
                        Spacer(minLength: 12)

                        if computerUseTaskIsRunning {
                            Button {
                                model.onCancelComputerUseTask?()
                            } label: {
                                HStack(spacing: 7) {
                                    templateIcon("停止图标", size: 14, color: WorkspacePalette.ink)
                                    Text("取消")
                                        .font(.system(size: 10, weight: .semibold))
                                }
                                .padding(.horizontal, 12)
                                .frame(height: 34)
                            }
                            .buttonStyle(.bordered)
                        } else {
                            Button {
                                model.onRunComputerUseSmokeTask?()
                            } label: {
                                HStack(spacing: 7) {
                                    templateIcon("完成图标", size: 14, color: WorkspacePalette.ink)
                                    Text("运行任务")
                                        .font(.system(size: 10, weight: .semibold))
                                }
                                .padding(.horizontal, 13)
                                .frame(height: 34)
                            }
                            .buttonStyle(.borderedProminent)
                            .tint(WorkspacePalette.accent)
                        }
                    }
                }
                .padding(18)
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
            .padding(WorkspaceLayout.pagePadding)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var computerUseTaskIsRunning: Bool {
        if case .running = model.computerUseTaskState { return true }
        return false
    }

    private var computerUseTaskTint: Color {
        switch model.computerUseTaskState {
        case .idle:
            return WorkspacePalette.muted
        case .running:
            return .orange
        case .succeeded:
            return .green
        case .failed:
            return .red
        case .cancelled:
            return WorkspacePalette.muted
        }
    }
}
