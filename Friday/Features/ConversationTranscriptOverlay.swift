// 功能：在 Talk 期间把用户与 Friday 的实时字幕作为聊天气泡悬浮在当前屏幕右上角。
// 职责：管理独立非激活 NSPanel 的显示器定位、生命周期与 AppKit 原生玻璃气泡，并随内存字幕快照实时更新。
// 边界：不创建转写会话、不保存对话内容、不控制灵动岛，也不接收鼠标或键盘输入。

import AppKit
import SwiftUI

@MainActor
final class ConversationTranscriptOverlayModel: ObservableObject {
    @Published var isPresented = false
    @Published var transcript = ConversationLiveTranscriptSnapshot.empty
}

private final class ConversationTranscriptOverlayPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// 使用和展开灵动岛相同的原生玻璃参数，并直接挂在 AppKit 视图树中。
private final class ConversationTranscriptGlassView: NSView {
    private let effectView: NSView

    override init(frame frameRect: NSRect) {
        if #available(macOS 26.0, *) {
            let glassView = NSGlassEffectView()
            glassView.appearance = NSAppearance(named: .darkAqua)
            glassView.style = .clear
            glassView.tintColor = NSColor.black.withAlphaComponent(0.38)
            glassView.cornerRadius = 16
            effectView = glassView
        } else {
            let visualEffectView = NSVisualEffectView()
            visualEffectView.material = .hudWindow
            visualEffectView.blendingMode = .behindWindow
            visualEffectView.state = .active
            effectView = visualEffectView
        }

        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
        layer?.cornerRadius = 16
        layer?.cornerCurve = .continuous
        layer?.masksToBounds = true
        effectView.frame = bounds
        effectView.autoresizingMask = [.width, .height]
        addSubview(effectView)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layout() {
        super.layout()
        effectView.frame = bounds
    }

    func setCornerRadius(_ radius: CGFloat) {
        layer?.cornerRadius = radius
        if #available(macOS 26.0, *), let glassView = effectView as? NSGlassEffectView {
            glassView.cornerRadius = radius
        }
    }
}

private final class ConversationTranscriptBubbleView: NSView {
    enum Alignment {
        case leading
        case trailing

        var textAlignment: NSTextAlignment {
            switch self {
            case .leading: .left
            case .trailing: .right
            }
        }
    }

    static let maximumWidth: CGFloat = 320

    private static let minimumTextWidth: CGFloat = 26
    private static let horizontalTextPadding: CGFloat = 14
    private static let verticalTextPadding: CGFloat = 10
    private static let speakerHeight: CGFloat = 12
    private static let speakerSpacing: CGFloat = 4
    private static let maximumLineCount = 5
    private static let textFont = NSFont.systemFont(ofSize: 14)

    private let glassView = ConversationTranscriptGlassView(frame: .zero)
    private let speakerLabel = NSTextField(labelWithString: "")
    private let textLabel = NSTextField(wrappingLabelWithString: "")
    private let alignment: Alignment

    init(alignment: Alignment) {
        self.alignment = alignment
        super.init(frame: .zero)

        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor

        speakerLabel.font = .systemFont(ofSize: 10, weight: .medium)
        speakerLabel.textColor = NSColor.white.withAlphaComponent(0.55)
        speakerLabel.alignment = alignment.textAlignment
        speakerLabel.lineBreakMode = .byClipping

        textLabel.font = Self.textFont
        textLabel.textColor = NSColor.white.withAlphaComponent(0.94)
        textLabel.alignment = alignment.textAlignment
        textLabel.lineBreakMode = .byWordWrapping
        textLabel.maximumNumberOfLines = Self.maximumLineCount

        addSubview(glassView)
        addSubview(speakerLabel, positioned: .above, relativeTo: glassView)
        addSubview(textLabel, positioned: .above, relativeTo: glassView)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    @discardableResult
    func update(speaker: String, text: String) -> NSSize {
        speakerLabel.stringValue = speaker
        textLabel.stringValue = text

        let maximumTextWidth = Self.maximumWidth
            - Self.horizontalTextPadding * 2
        let textWidth = min(
            max(singleLineWidth(for: text), Self.minimumTextWidth),
            maximumTextWidth
        )
        let isSingleLine = !text.contains("\n")
            && singleLineWidth(for: text) <= maximumTextWidth
        let textHeight = measuredTextHeight(for: text, width: textWidth)
        let bubbleWidth = textWidth + Self.horizontalTextPadding * 2
        let bubbleHeight = textHeight + Self.verticalTextPadding * 2
        let totalHeight = bubbleHeight + Self.speakerSpacing + Self.speakerHeight

        frame.size = NSSize(width: bubbleWidth, height: totalHeight)
        glassView.frame = NSRect(x: 0, y: 0, width: bubbleWidth, height: bubbleHeight)
        glassView.setCornerRadius(isSingleLine ? bubbleHeight / 2 : 16)
        textLabel.frame = NSRect(
            x: Self.horizontalTextPadding,
            y: Self.verticalTextPadding,
            width: textWidth,
            height: textHeight
        )
        speakerLabel.frame = NSRect(
            x: 0,
            y: bubbleHeight + Self.speakerSpacing,
            width: bubbleWidth,
            height: Self.speakerHeight
        )
        return frame.size
    }

    private func singleLineWidth(for text: String) -> CGFloat {
        text
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { line in
                ceil(
                    (String(line) as NSString).size(
                        withAttributes: [.font: Self.textFont]
                    ).width
                )
            }
            .max() ?? 0
    }

    private func measuredTextHeight(for text: String, width: CGFloat) -> CGFloat {
        let measuredHeight = ceil(
            (text as NSString).boundingRect(
                with: NSSize(width: width, height: 10_000),
                options: [.usesLineFragmentOrigin, .usesFontLeading],
                attributes: [.font: Self.textFont]
            ).height
        )
        let lineHeight = ceil(Self.textFont.boundingRectForFont.height)
        return min(max(measuredHeight, lineHeight), lineHeight * CGFloat(Self.maximumLineCount))
    }
}

/// 玻璃与文字都处于 AppKit 根视图中，避免 SwiftUI 背景合成产生灰色可读性底板。
private final class ConversationTranscriptRootView: NSView {
    private static let leadingInset: CGFloat = 20
    private static let trailingInset: CGFloat = 4
    private static let topInset: CGFloat = 8
    private static let bubbleSpacing: CGFloat = 10
    private static let assistantEntranceOffset: CGFloat = 14
    private static let assistantEntranceDuration: TimeInterval = 0.28

    private let assistantBubble = ConversationTranscriptBubbleView(alignment: .leading)
    private let userBubble = ConversationTranscriptBubbleView(alignment: .trailing)
    private var assistantEntranceGeneration = 0
    private var isAssistantEntering = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
        addSubview(assistantBubble)
        addSubview(userBubble)
        apply(transcript: .empty)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layout() {
        super.layout()
        layoutBubbles()
    }

    func apply(transcript: ConversationLiveTranscriptSnapshot) {
        let wasAssistantHidden = assistantBubble.isHidden
        let hasAssistantText = !transcript.assistantText.isEmpty
        assistantBubble.isHidden = !hasAssistantText
        if hasAssistantText {
            assistantBubble.update(
                speaker: "Olli",
                text: transcript.assistantText
            )
        }
        userBubble.update(
            speaker: "你",
            text: transcript.userText.isEmpty ? "..." : transcript.userText
        )
        layoutBubbles()

        guard hasAssistantText else {
            assistantEntranceGeneration += 1
            isAssistantEntering = false
            assistantBubble.layer?.removeAllAnimations()
            assistantBubble.layer?.setAffineTransform(.identity)
            assistantBubble.layer?.opacity = 0
            return
        }

        guard wasAssistantHidden else {
            if !isAssistantEntering {
                assistantBubble.layer?.opacity = 1
            }
            return
        }

        animateAssistantEntrance()
    }

    private func layoutBubbles() {
        let leadingX = bounds.minX + Self.leadingInset
        let trailingX = bounds.maxX - Self.trailingInset
        var topY = bounds.maxY - Self.topInset

        if !assistantBubble.isHidden {
            topY -= assistantBubble.frame.height
            assistantBubble.frame.origin = NSPoint(x: leadingX, y: topY)
            topY -= Self.bubbleSpacing
        }

        topY -= userBubble.frame.height
        userBubble.frame.origin = NSPoint(
            x: trailingX - userBubble.frame.width,
            y: topY
        )
    }

    private func animateAssistantEntrance() {
        guard let layer = assistantBubble.layer else { return }
        assistantEntranceGeneration += 1
        let generation = assistantEntranceGeneration
        isAssistantEntering = true

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.removeAllAnimations()
        layer.setAffineTransform(
            CGAffineTransform(translationX: 0, y: Self.assistantEntranceOffset)
        )
        layer.opacity = 0
        layer.setAffineTransform(.identity)
        layer.opacity = 1
        CATransaction.commit()

        let transformAnimation = CABasicAnimation(keyPath: "transform")
        transformAnimation.fromValue = CATransform3DMakeTranslation(
            0,
            Self.assistantEntranceOffset,
            0
        )
        transformAnimation.toValue = CATransform3DIdentity

        let opacityAnimation = CABasicAnimation(keyPath: "opacity")
        opacityAnimation.fromValue = 0
        opacityAnimation.toValue = 1

        let animationGroup = CAAnimationGroup()
        animationGroup.animations = [transformAnimation, opacityAnimation]
        animationGroup.duration = Self.assistantEntranceDuration
        animationGroup.timingFunction = CAMediaTimingFunction(name: .easeOut)
        layer.add(animationGroup, forKey: "assistantEntrance")

        DispatchQueue.main.asyncAfter(
            deadline: .now() + Self.assistantEntranceDuration
        ) { [weak self] in
            guard let self,
                  self.assistantEntranceGeneration == generation else { return }
            self.isAssistantEntering = false
            self.assistantBubble.layer?.removeAnimation(forKey: "assistantEntrance")
        }
    }
}

@MainActor
final class ConversationTranscriptOverlayController {
    fileprivate static let panelSize = NSSize(width: 400, height: 260)
    private static let trailingMargin: CGFloat = 12
    private static let topMargin: CGFloat = 18

    private let model: ConversationTranscriptOverlayModel
    private let panel: ConversationTranscriptOverlayPanel
    private let rootView: ConversationTranscriptRootView
    private var activeScreen: NSScreen?
    private var screenObserver: NSObjectProtocol?

    init(model: ConversationTranscriptOverlayModel) {
        self.model = model
        panel = ConversationTranscriptOverlayPanel(
            contentRect: NSRect(origin: .zero, size: Self.panelSize),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        rootView = ConversationTranscriptRootView(
            frame: NSRect(origin: .zero, size: Self.panelSize)
        )

        panel.contentView = rootView
        panel.level = NSWindow.Level(
            rawValue: Int(CGWindowLevelForKey(.mainMenuWindow)) + 2
        )
        panel.collectionBehavior = [
            .canJoinAllSpaces,
            .fullScreenAuxiliary,
            .stationary,
            .ignoresCycle
        ]
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.ignoresMouseEvents = true
        panel.isMovable = false
        panel.isExcludedFromWindowsMenu = true
        panel.animationBehavior = .none

        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.repositionAfterScreenChange()
            }
        }
    }

    deinit {
        if let screenObserver {
            NotificationCenter.default.removeObserver(screenObserver)
        }
    }

    func update(
        isPresented: Bool,
        transcript: ConversationLiveTranscriptSnapshot
    ) {
        model.transcript = transcript
        model.isPresented = isPresented
        rootView.apply(transcript: transcript)

        guard isPresented else {
            panel.orderOut(nil)
            activeScreen = nil
            return
        }

        if !panel.isVisible {
            activeScreen = screenForCurrentPointer() ?? NSScreen.main
        }
        reposition(on: activeScreen ?? panel.screen ?? NSScreen.main)
        rootView.layoutSubtreeIfNeeded()
        rootView.displayIfNeeded()
        panel.orderFrontRegardless()
    }

    private func repositionAfterScreenChange() {
        guard panel.isVisible else { return }
        activeScreen = panel.screen ?? screenForCurrentPointer() ?? NSScreen.main
        reposition(on: activeScreen)
    }

    private func reposition(on screen: NSScreen?) {
        guard let visibleFrame = screen?.visibleFrame else { return }
        panel.setFrame(
            NSRect(
                x: visibleFrame.maxX - Self.panelSize.width - Self.trailingMargin,
                y: visibleFrame.maxY - Self.panelSize.height - Self.topMargin,
                width: Self.panelSize.width,
                height: Self.panelSize.height
            ),
            display: panel.isVisible
        )
    }

    private func screenForCurrentPointer() -> NSScreen? {
        let mouseLocation = NSEvent.mouseLocation
        return NSScreen.screens.first {
            NSMouseInRect(mouseLocation, $0.frame, false)
        }
    }
}
