// 功能：在灵动岛展开态展示一项 Agent 输入框写入的完整视觉确认。
// 职责：呈现目标、可滚动文字预览、风险与撤销说明，并转发取消、写入或关闭命令。
// 边界：只展示不可编辑的动作快照，不持有 Permission Runtime、不执行写入，也不记录用户正文。

import SwiftUI

struct AgentActionConfirmationView: View {
    let confirmation: ActionConfirmationPresentation
    let onAllow: () -> Void
    let onReject: () -> Void
    let onDismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 11) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("写入输入框")
                    .font(.system(size: 14, weight: .semibold))
                Spacer(minLength: 12)
                Text(confirmation.targetApplication)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.white.opacity(0.55))
                    .lineLimit(1)
            }

            ScrollView(.vertical, showsIndicators: true) {
                Text(confirmation.preview)
                    .font(.system(size: 13))
                    .foregroundStyle(.white.opacity(0.88))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
            }
            .frame(maxHeight: 102)
            .background(Color.white.opacity(0.055))
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(.white.opacity(0.12), lineWidth: 1)
            }

            HStack(spacing: 7) {
                Image("鼠标图标")
                    .renderingMode(.template)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 16, height: 16)
                    .foregroundStyle(.cyan)
                Text(detail)
                    .font(.system(size: 11))
                    .foregroundStyle(detailColor)
                    .lineLimit(2)
                Spacer(minLength: 8)
            }

            commands
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var detail: String {
        switch confirmation.state {
        case .pending:
            return "只写入 \(confirmation.targetRole)，不会发送或提交；可用 Command-Z 撤销"
        case .executing:
            return "正在复验原输入目标并执行一次写入"
        case .failed(let message), .unknown(let message):
            return message
        }
    }

    private var detailColor: Color {
        switch confirmation.state {
        case .failed, .unknown:
            return .orange
        case .pending, .executing:
            return .white.opacity(0.58)
        }
    }

    @ViewBuilder
    private var commands: some View {
        HStack(spacing: 9) {
            Spacer()
            switch confirmation.state {
            case .pending:
                decisionButton(title: "取消", emphasized: false, action: onReject)
                decisionButton(title: "写入", emphasized: true, action: onAllow)
            case .executing:
                ProgressView()
                    .controlSize(.small)
                    .tint(.white)
                    .frame(width: 78, height: 30)
            case .failed, .unknown:
                decisionButton(title: "关闭", emphasized: false, action: onDismiss)
            }
        }
    }

    private func decisionButton(
        title: String,
        emphasized: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(title, action: action)
            .buttonStyle(.plain)
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(emphasized ? Color.black : Color.white.opacity(0.82))
            .frame(width: 78, height: 30)
            .background(emphasized ? Color.white : Color.white.opacity(0.09))
            .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
            .overlay {
                if !emphasized {
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .strokeBorder(.white.opacity(0.14), lineWidth: 1)
                }
            }
    }
}
