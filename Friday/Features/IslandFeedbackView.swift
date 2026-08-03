// 功能：在顶部灵动岛中呈现需要立即处理的轻提示、失败和转写结果恢复操作。
// 职责：根据 InputOverlayModel 的反馈阶段显示摘要、复制、重试、关闭和打开主工作台入口，并保持固定紧凑布局。
// 边界：不展示完整监控或设置，不直接访问权限、网络、音频和输入目标，也不持久化结果内容。

import SwiftUI

struct IslandFeedbackView: View {
    @ObservedObject var model: InputOverlayModel

    var body: some View {
        VStack(spacing: 0) {
            header
            Rectangle()
                .fill(.white.opacity(0.1))
                .frame(height: 1)
            feedback
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .foregroundStyle(.white)
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image("灵动岛图标")
                .renderingMode(.original)
                .resizable()
                .interpolation(.high)
                .aspectRatio(contentMode: .fit)
                .frame(width: 18, height: 18)

            VStack(alignment: .leading, spacing: 1) {
                Text("Friday")
                    .font(.system(size: 13, weight: .semibold))
                Text(feedbackTitle)
                    .font(.system(size: 9))
                    .foregroundStyle(.white.opacity(0.45))
                    .lineLimit(1)
            }

            Spacer(minLength: 12)

            iconButton(
                symbol: "rectangle.on.rectangle",
                help: "打开 Friday 主界面",
                action: { model.onOpenWorkspace?() }
            )
            iconButton(
                symbol: "xmark",
                help: "收起",
                action: { model.onCollapseFeedback?() }
            )
        }
        .padding(.horizontal, 16)
        .frame(height: 50)
    }

    @ViewBuilder
    private var feedback: some View {
        switch model.phase {
        case .failure(let message, let canRetry):
            messageFeedback(
                message: message,
                symbol: "exclamationmark.triangle.fill",
                tint: Color(red: 0.96, green: 0.63, blue: 0.29),
                canRetry: canRetry
            )
        case .result(let text, let message, let canRetry):
            resultFeedback(text: text, message: message, canRetry: canRetry)
        case .notice(let message):
            messageFeedback(
                message: message,
                symbol: "checkmark.circle.fill",
                tint: Color(red: 0.36, green: 0.80, blue: 0.50),
                canRetry: false
            )
        default:
            EmptyView()
        }
    }

    private func messageFeedback(
        message: String,
        symbol: String,
        tint: Color,
        canRetry: Bool
    ) -> some View {
        VStack(spacing: 14) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: symbol)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(tint)
                    .frame(width: 20)
                Text(message)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.white.opacity(0.82))
                    .lineLimit(3)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            if canRetry {
                HStack {
                    Spacer()
                    commandButton("重试", symbol: "arrow.clockwise", emphasized: true) {
                        model.onRetry?()
                    }
                }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func resultFeedback(text: String, message: String, canRetry: Bool) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(message)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.white.opacity(0.5))
                .lineLimit(1)

            Text(text)
                .font(.system(size: 12))
                .foregroundStyle(.white.opacity(0.82))
                .lineLimit(5)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)

            Spacer(minLength: 0)

            HStack(spacing: 8) {
                Spacer()
                if canRetry {
                    commandButton("重试写入", symbol: "arrow.clockwise") {
                        model.onRetry?()
                    }
                }
                commandButton("复制", symbol: "doc.on.doc", emphasized: true) {
                    model.onCopy?()
                }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func iconButton(
        symbol: String,
        help: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.white.opacity(0.72))
                .frame(width: 26, height: 26)
                .background(.white.opacity(0.08))
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        }
        .buttonStyle(.plain)
        .help(help)
        .accessibilityLabel(help)
    }

    private func commandButton(
        _ title: String,
        symbol: String,
        emphasized: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Label(title, systemImage: symbol)
                .font(.system(size: 10, weight: .semibold))
                .padding(.horizontal, 10)
                .frame(height: 28)
                .foregroundStyle(emphasized ? Color.black : Color.white.opacity(0.78))
                .background(emphasized ? Color.white : Color.white.opacity(0.1))
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    private var feedbackTitle: String {
        switch model.phase {
        case .failure: return "需要处理"
        case .result: return "结果待恢复"
        case .notice: return "提示"
        default: return "即时状态"
        }
    }
}

@MainActor
struct IslandFeedbackView_Previews: PreviewProvider {
    static var previews: some View {
        let model = InputOverlayModel()
        model.phase = .result(
            text: "这是 Friday 整理后的示例文字。",
            message: "未找到可安全写入的输入框",
            canRetry: true
        )
        return IslandFeedbackView(model: model)
            .frame(
                width: InputOverlaySizing.feedbackSize.width,
                height: InputOverlaySizing.feedbackSize.height
            )
            .background(.black)
    }
}
