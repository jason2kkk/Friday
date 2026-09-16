// 功能：通过不抢焦点的顶部灵动岛持续展示 Dictate 与 Talk 的录音、处理、结果和恢复反馈。
// 职责：定义浮层状态模型、原生玻璃窗口层级、NSPanel 生命周期与 SwiftUI 内容，并处理展开收起和用户事件。
// 边界：不采集音频、不调用模型、不查找输入目标；所有业务操作均通过模型回调交还应用工作流。

import AppKit
import SwiftUI

enum InputOverlayPhase: Equatable {
    case hidden
    case idle
    case listening
    case processing(title: String, detail: String?, canCancel: Bool)
    case conversation(
        expression: ConversationExpression,
        source: ConversationWaveformSource
    )
    case failure(String, canRetry: Bool)
    case result(text: String, message: String, canRetry: Bool)
    case notice(String)

    var acceptsMouseEvents: Bool {
        switch self {
        case .failure, .result, .notice:
            return true
        default:
            return false
        }
    }
}

enum InputOverlayExpandedPage: Equatable {
    case dashboard
    case settings
}

/// 功能：根据当前屏幕的刘海和菜单栏计算灵动岛尺寸。
/// 职责：让紧凑态内容只使用刘海两侧的安全区域，并为主页与设置形态提供固定目标尺寸。
struct InputOverlaySizing {
    static let expandedSize = NSSize(width: 520, height: 300)
    static let settingsSize = NSSize(width: 400, height: 480)
    static let compactWingWidth: CGFloat = 52
    static let shadowPadding: CGFloat = 10
    static let windowSize = NSSize(
        width: max(expandedSize.width, settingsSize.width),
        height: max(expandedSize.height, settingsSize.height) + shadowPadding
    )

    let compactSize: CGSize
    let centerGapWidth: CGFloat

    static func fromScreen(_ screen: NSScreen?) -> InputOverlaySizing {
        guard let screen else {
            return fallbackSizing(menuBarHeight: 32)
        }

        let topInset = screen.safeAreaInsets.top
        if topInset > 0,
           let leftArea = screen.auxiliaryTopLeftArea,
           let rightArea = screen.auxiliaryTopRightArea {
            let notchWidth = screen.frame.width - leftArea.width - rightArea.width + 4
            return InputOverlaySizing(
                compactSize: CGSize(
                    width: notchWidth + compactWingWidth * 2,
                    height: topInset
                ),
                centerGapWidth: notchWidth
            )
        }

        let menuBarHeight = screen.frame.maxY - screen.visibleFrame.maxY
        return fallbackSizing(menuBarHeight: max(menuBarHeight, 28))
    }

    private static func fallbackSizing(menuBarHeight: CGFloat) -> InputOverlaySizing {
        let simulatedCenterGap: CGFloat = 160
        return InputOverlaySizing(
            compactSize: CGSize(
                width: simulatedCenterGap + compactWingWidth * 2,
                height: menuBarHeight
            ),
            centerGapWidth: simulatedCenterGap
        )
    }
}

@MainActor
final class InputOverlayModel: ObservableObject {
    static let silentWaveformLevels = Array(
        repeating: Float(0),
        count: AudioChunk.waveformLevelCount
    )

    @Published var phase: InputOverlayPhase = .hidden
    @Published var audioLevel: Float = 0
    @Published var isVoiceActive = false
    @Published var waveformLevels = silentWaveformLevels
    @Published var compactSize = CGSize(width: 264, height: 32)
    @Published var centerGapWidth: CGFloat = 160
    @Published var isAppearing = false
    @Published var isCollapsing = false
    @Published var isDashboardExpanded = false
    @Published var expandedPage: InputOverlayExpandedPage = .dashboard
    @Published var dashboard = AppDashboardSnapshot()
    @Published var computerUseTaskState: ComputerUseTaskState = .idle
    @Published var computerUseTaskPath = TextEditSmokeTask.makeDefault().outputURL.path

    var isExpanded: Bool {
        if isDashboardExpanded { return true }
        switch phase {
        case .failure, .result, .notice:
            return true
        default:
            return false
        }
    }

    var isConversation: Bool {
        if case .conversation = phase { return true }
        return false
    }

    var currentExpandedSize: CGSize {
        switch expandedPage {
        case .dashboard:
            return InputOverlaySizing.expandedSize
        case .settings:
            return InputOverlaySizing.settingsSize
        }
    }

    var currentSize: CGSize {
        isExpanded ? currentExpandedSize : compactSize
    }

    var onRetry: (() -> Void)?
    var onCopy: (() -> Void)?
    var onDismiss: (() -> Void)?
    var onToggleDictation: (() -> Void)?
    var onToggleConversation: (() -> Void)?
    var onSelectScreenRegion: (() -> Void)?
    var onRequestAccessibility: (() -> Void)?
    var onRequestMicrophone: (() -> Void)?
    var onRequestScreenCapture: (() -> Void)?
    var onClearLastOutput: (() -> Void)?
    var onRefresh: (() -> Void)?
    var onQuit: (() -> Void)?
    var onOpenWorkspace: (() -> Void)?
    var onRunComputerUseSmokeTask: (() -> Void)?
    var onCancelComputerUseTask: (() -> Void)?
    var onCollapseDashboard: (() -> Void)?
    var onPresentSettings: (() -> Void)?
    var onPresentDashboard: (() -> Void)?
}

private final class InputOverlayPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

private enum InputOverlayShapeMetrics {
    static let compactTopCornerRadius: CGFloat = 6
    static let compactBottomCornerRadius: CGFloat = 14
    static let expandedTopCornerRadius: CGFloat = 10
    static let expandedBottomCornerRadius: CGFloat = 28

    static func path(
        in rect: CGRect,
        topCornerRadius: CGFloat,
        bottomCornerRadius: CGFloat
    ) -> CGPath {
        let path = CGMutablePath()
        let top = topCornerRadius
        let bottom = bottomCornerRadius

        path.move(to: CGPoint(x: rect.minX, y: rect.maxY))
        path.addQuadCurve(
            to: CGPoint(x: rect.minX + top, y: rect.maxY - top),
            control: CGPoint(x: rect.minX + top, y: rect.maxY)
        )
        path.addLine(to: CGPoint(x: rect.minX + top, y: rect.minY + bottom))
        path.addQuadCurve(
            to: CGPoint(x: rect.minX + top + bottom, y: rect.minY),
            control: CGPoint(x: rect.minX + top, y: rect.minY)
        )
        path.addLine(to: CGPoint(x: rect.maxX - top - bottom, y: rect.minY))
        path.addQuadCurve(
            to: CGPoint(x: rect.maxX - top, y: rect.minY + bottom),
            control: CGPoint(x: rect.maxX - top, y: rect.minY)
        )
        path.addLine(to: CGPoint(x: rect.maxX - top, y: rect.maxY - top))
        path.addQuadCurve(
            to: CGPoint(x: rect.maxX, y: rect.maxY),
            control: CGPoint(x: rect.maxX - top, y: rect.maxY)
        )
        path.closeSubpath()
        return path
    }
}

/// 承载不带独立轮廓的原生玻璃，由根视图统一裁切玻璃、渐变和内容。
private final class InputOverlayBackdropView: NSView {
    private let effectView: NSView

    override init(frame frameRect: NSRect) {
        if #available(macOS 26.0, *) {
            let glassView = NSGlassEffectView()
            glassView.appearance = NSAppearance(named: .darkAqua)
            glassView.style = .clear
            glassView.tintColor = NSColor.black.withAlphaComponent(0.68)
            glassView.cornerRadius = 0
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
}

/// 让原生玻璃直接位于窗口根层，SwiftUI 只负责玻璃上方的内容与遮罩。
private final class InputOverlayRootView: NSView {
    private let backdropView: InputOverlayBackdropView
    private let shapeMaskLayer = CAShapeLayer()
    private var compactSize = CGSize(width: 264, height: 32)
    private var expandedSize = InputOverlaySizing.expandedSize
    private var isExpanded = false
    private var isTransitioning = false
    private var transitionGeneration = 0

    override init(frame frameRect: NSRect) {
        backdropView = InputOverlayBackdropView(frame: .zero)

        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
        shapeMaskLayer.fillColor = NSColor.white.cgColor
        shapeMaskLayer.frame = bounds
        shapeMaskLayer.path = currentMaskPath
        layer?.mask = shapeMaskLayer
        backdropView.alphaValue = 0
        backdropView.isHidden = true
        addSubview(backdropView)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layout() {
        super.layout()
        guard !isTransitioning else { return }
        backdropView.frame = isExpanded ? expandedFrame : compactFrame
        shapeMaskLayer.frame = bounds
        shapeMaskLayer.path = currentMaskPath
    }

    func setExpanded(
        _ expanded: Bool,
        expandedSize: CGSize,
        compactSize: CGSize,
        animated: Bool
    ) {
        let previousExpandedSize = self.expandedSize
        self.compactSize = compactSize
        self.expandedSize = expandedSize
        let wasExpanded = isExpanded
        let sizeChanged = previousExpandedSize != expandedSize
        let previousMaskPath = shapeMaskLayer.presentation()?.path
            ?? shapeMaskLayer.path
        isExpanded = expanded
        transitionGeneration += 1
        let currentGeneration = transitionGeneration

        backdropView.layer?.removeAllAnimations()
        backdropView.isHidden = false

        if expanded && !wasExpanded {
            backdropView.frame = compactFrame
        }
        backdropView.alphaValue = 1

        let targetFrame = expanded ? expandedFrame : compactFrame
        let targetMaskPath = currentMaskPath
        guard animated, wasExpanded != expanded || (expanded && sizeChanged) else {
            isTransitioning = false
            backdropView.frame = targetFrame
            shapeMaskLayer.path = targetMaskPath
            backdropView.alphaValue = expanded ? 1 : 0
            backdropView.isHidden = !expanded
            return
        }

        isTransitioning = true
        shapeMaskLayer.path = targetMaskPath
        let maskAnimation = CABasicAnimation(keyPath: "path")
        maskAnimation.fromValue = previousMaskPath
        maskAnimation.toValue = targetMaskPath
        maskAnimation.duration = expanded ? 0.36 : 0.3
        maskAnimation.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        shapeMaskLayer.add(maskAnimation, forKey: "islandShape")
        NSAnimationContext.runAnimationGroup { context in
            context.duration = expanded ? 0.36 : 0.3
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            backdropView.animator().frame = targetFrame
        } completionHandler: { [weak self] in
            guard let self,
                  self.isExpanded == expanded,
                  self.transitionGeneration == currentGeneration else { return }
            self.isTransitioning = false
            self.backdropView.frame = targetFrame
            self.shapeMaskLayer.path = targetMaskPath
            self.backdropView.alphaValue = expanded ? 1 : 0
            self.backdropView.isHidden = !expanded
            self.needsLayout = true
        }
    }

    private var expandedFrame: NSRect {
        NSRect(
            x: (bounds.width - expandedSize.width) / 2,
            y: bounds.height - expandedSize.height,
            width: expandedSize.width,
            height: expandedSize.height
        )
    }

    private var compactFrame: NSRect {
        NSRect(
            x: (bounds.width - compactSize.width) / 2,
            y: bounds.height - compactSize.height,
            width: compactSize.width,
            height: compactSize.height
        )
    }

    private var currentMaskPath: CGPath {
        let size = isExpanded ? expandedSize : compactSize
        let rect = NSRect(
            x: (bounds.width - size.width) / 2,
            y: bounds.height - size.height,
            width: size.width,
            height: size.height
        )
        let topRadius = isExpanded
            ? InputOverlayShapeMetrics.expandedTopCornerRadius
            : InputOverlayShapeMetrics.compactTopCornerRadius
        let bottomRadius = isExpanded
            ? InputOverlayShapeMetrics.expandedBottomCornerRadius
            : InputOverlayShapeMetrics.compactBottomCornerRadius
        return InputOverlayShapeMetrics.path(
            in: rect,
            topCornerRadius: topRadius,
            bottomCornerRadius: bottomRadius
        )
    }
}

@MainActor
final class InputOverlayController {
    private let model: InputOverlayModel
    private let panel: InputOverlayPanel
    private let rootView: InputOverlayRootView
    private var activeScreen: NSScreen?
    private var globalEscapeMonitor: Any?
    private var localEscapeMonitor: Any?
    private var globalMouseMonitor: Any?
    private var localMouseMonitor: Any?
    private var screenObserver: NSObjectProtocol?
    private var appearanceTask: Task<Void, Never>?
    private var dismissalTask: Task<Void, Never>?
    private var noticeTask: Task<Void, Never>?

    init(model: InputOverlayModel) {
        self.model = model

        panel = InputOverlayPanel(
            contentRect: NSRect(origin: .zero, size: InputOverlaySizing.windowSize),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        rootView = InputOverlayRootView(
            frame: NSRect(origin: .zero, size: InputOverlaySizing.windowSize)
        )
        let hostingView = NSHostingView(rootView: InputOverlayView(model: model))
        hostingView.frame = NSRect(origin: .zero, size: InputOverlaySizing.windowSize)
        hostingView.autoresizingMask = [.width, .height]
        hostingView.wantsLayer = true
        hostingView.layer?.backgroundColor = NSColor.clear.cgColor
        rootView.addSubview(hostingView, positioned: .above, relativeTo: nil)
        panel.contentView = rootView
        panel.isFloatingPanel = true
        panel.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.mainMenuWindow)) + 3)
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.isMovable = false
        panel.isExcludedFromWindowsMenu = true
        panel.animationBehavior = .utilityWindow

        model.onCollapseDashboard = { [weak self] in
            self?.collapseDashboard()
        }
        model.onPresentSettings = { [weak self] in
            self?.presentExpandedPage(.settings)
        }
        model.onPresentDashboard = { [weak self] in
            self?.presentExpandedPage(.dashboard)
        }
        installEventMonitors()
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.repositionForCurrentScreen()
            }
        }

        Task { @MainActor in
            if !self.showConfiguredPreviewIfNeeded() {
                self.show(.idle)
            }
        }
    }

    deinit {
        appearanceTask?.cancel()
        dismissalTask?.cancel()
        noticeTask?.cancel()
        if let globalEscapeMonitor {
            NSEvent.removeMonitor(globalEscapeMonitor)
        }
        if let localEscapeMonitor {
            NSEvent.removeMonitor(localEscapeMonitor)
        }
        if let globalMouseMonitor {
            NSEvent.removeMonitor(globalMouseMonitor)
        }
        if let localMouseMonitor {
            NSEvent.removeMonitor(localMouseMonitor)
        }
        if let screenObserver {
            NotificationCenter.default.removeObserver(screenObserver)
        }
    }

    func show(_ phase: InputOverlayPhase) {
        let shouldAnimateAppearance = !panel.isVisible
        appearanceTask?.cancel()
        dismissalTask?.cancel()
        appearanceTask = nil
        dismissalTask = nil
        model.isAppearing = shouldAnimateAppearance
        model.isCollapsing = false
        model.phase = phase
        switch phase {
        case .failure, .result, .notice:
            model.expandedPage = .dashboard
            model.isDashboardExpanded = true
        case .idle, .hidden:
            break
        default:
            model.expandedPage = .dashboard
            model.isDashboardExpanded = false
        }
        panel.hasShadow = model.isExpanded
        panel.invalidateShadow()
        panel.ignoresMouseEvents = !model.isExpanded
        if case .failure = phase {
            model.onRefresh?()
        }
        let screen = activeScreen ?? screenForCurrentPointer()
        activeScreen = screen
        let sizing = InputOverlaySizing.fromScreen(screen)
        model.compactSize = sizing.compactSize
        model.centerGapWidth = sizing.centerGapWidth
        rootView.setExpanded(
            model.isExpanded,
            expandedSize: model.currentExpandedSize,
            compactSize: sizing.compactSize,
            animated: panel.isVisible
        )
        let targetFrame = frame(for: InputOverlaySizing.windowSize, on: screen)
        panel.setFrame(targetFrame, display: true)

        if shouldAnimateAppearance {
            // Keep the window transparent until SwiftUI has rendered the new phase.
            // This prevents the black shell from appearing one frame before its content.
            panel.alphaValue = 0
            panel.orderFrontRegardless()
            appearanceTask = Task { @MainActor [weak self] in
                await Task.yield()
                guard let self, !Task.isCancelled else { return }
                panel.contentView?.layoutSubtreeIfNeeded()
                panel.displayIfNeeded()
                panel.alphaValue = 1
                try? await Task.sleep(for: .milliseconds(20))
                guard !Task.isCancelled else { return }
                model.isAppearing = false
                appearanceTask = nil
            }
        } else {
            panel.alphaValue = 1
            panel.orderFrontRegardless()
        }
    }

    func hide() {
        appearanceTask?.cancel()
        appearanceTask = nil
        dismissalTask?.cancel()
        noticeTask?.cancel()
        noticeTask = nil
        panel.ignoresMouseEvents = true

        guard panel.isVisible else {
            finishCollapsing()
            show(.idle)
            return
        }

        model.isDashboardExpanded = false
        rootView.setExpanded(
            false,
            expandedSize: model.currentExpandedSize,
            compactSize: model.compactSize,
            animated: true
        )
        model.expandedPage = .dashboard
        model.isCollapsing = true
        dismissalTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(180))
            guard !Task.isCancelled else { return }
            self?.finishCollapsing()
        }
    }

    func showBottomToast(
        _ message: String,
        duration: Duration = .milliseconds(1_800),
        hidesOverlay: Bool = true
    ) {
        noticeTask?.cancel()
        let previousPhase = model.phase
        show(.notice(message))
        noticeTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: duration)
            guard !Task.isCancelled else { return }
            guard let self else { return }
            noticeTask = nil
            if hidesOverlay {
                hide()
            } else {
                show(previousPhase)
            }
        }
    }

    private func finishCollapsing() {
        dismissalTask = nil
        model.phase = .idle
        model.audioLevel = 0
        model.isVoiceActive = false
        model.waveformLevels = InputOverlayModel.silentWaveformLevels
        model.isAppearing = false
        model.isCollapsing = false
        model.expandedPage = .dashboard
        rootView.setExpanded(
            false,
            expandedSize: model.currentExpandedSize,
            compactSize: model.compactSize,
            animated: false
        )
        panel.hasShadow = false
        panel.invalidateShadow()
        panel.alphaValue = 1
        panel.ignoresMouseEvents = true
        panel.orderFrontRegardless()
    }

    private func expandDashboard() {
        guard panel.isVisible, !model.isExpanded else { return }
        model.expandedPage = .dashboard
        model.isDashboardExpanded = true
        rootView.setExpanded(
            true,
            expandedSize: model.currentExpandedSize,
            compactSize: model.compactSize,
            animated: true
        )
        panel.hasShadow = true
        panel.invalidateShadow()
        panel.ignoresMouseEvents = false
        panel.makeKeyAndOrderFront(nil)
        model.onRefresh?()
    }

    private func collapseDashboard() {
        guard model.isExpanded else { return }
        noticeTask?.cancel()
        noticeTask = nil
        if case .failure = model.phase {
            model.phase = .idle
        } else if case .result = model.phase {
            model.phase = .idle
        } else if case .notice = model.phase {
            model.phase = .idle
        }
        model.isDashboardExpanded = false
        rootView.setExpanded(
            false,
            expandedSize: model.currentExpandedSize,
            compactSize: model.compactSize,
            animated: true
        )
        model.expandedPage = .dashboard
        panel.hasShadow = false
        panel.invalidateShadow()
        panel.resignKey()
        panel.ignoresMouseEvents = true
    }

    private func presentExpandedPage(_ page: InputOverlayExpandedPage) {
        guard model.isExpanded, model.expandedPage != page else { return }
        model.expandedPage = page
        rootView.setExpanded(
            true,
            expandedSize: model.currentExpandedSize,
            compactSize: model.compactSize,
            animated: true
        )
    }

    private func installEventMonitors() {
        globalEscapeMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard event.keyCode == 53 else { return }
            Task { @MainActor [weak self] in
                self?.handleEscape()
            }
        }

        localEscapeMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard event.keyCode == 53,
                  let self,
                  self.panel.isVisible else { return event }
            self.handleEscape()
            return nil
        }

        globalMouseMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown]
        ) { [weak self] _ in
            let location = NSEvent.mouseLocation
            Task { @MainActor [weak self] in
                self?.handleGlobalClick(at: location)
            }
        }

        localMouseMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown]
        ) { [weak self] event in
            guard let self, model.isExpanded else { return event }
            if !expandedFrameInScreen.contains(NSEvent.mouseLocation) {
                collapseDashboard()
            }
            return event
        }
    }

    private func handleEscape() {
        guard panel.isVisible else { return }
        if model.isExpanded {
            collapseDashboard()
        } else if model.phase != .idle && model.phase != .hidden {
            model.onDismiss?()
        }
    }

    private func handleGlobalClick(at location: NSPoint) {
        guard panel.isVisible else { return }
        if model.isExpanded {
            if !expandedFrameInScreen.contains(location) {
                collapseDashboard()
            }
        } else if compactFrameInScreen.contains(location) {
            expandDashboard()
        }
    }

    private func screenForCurrentPointer() -> NSScreen? {
        let mouseLocation = NSEvent.mouseLocation
        return NSScreen.screens.first { NSMouseInRect(mouseLocation, $0.frame, false) }
            ?? NSScreen.main
    }

    private func frame(for size: NSSize, on screen: NSScreen?) -> NSRect {
        guard let screenFrame = screen?.frame else {
            return NSRect(origin: .zero, size: size)
        }
        return NSRect(
            x: screenFrame.midX - size.width / 2,
            y: screenFrame.maxY - size.height,
            width: size.width,
            height: size.height
        )
    }

    private var compactFrameInScreen: NSRect {
        visibleFrameInScreen(size: model.compactSize)
    }

    private var expandedFrameInScreen: NSRect {
        visibleFrameInScreen(size: model.currentExpandedSize)
    }

    private func visibleFrameInScreen(size: CGSize) -> NSRect {
        guard let screen = activeScreen ?? panel.screen ?? NSScreen.main else { return .zero }
        return NSRect(
            x: screen.frame.midX - size.width / 2,
            y: screen.frame.maxY - size.height,
            width: size.width,
            height: size.height
        )
    }

    private func repositionForCurrentScreen() {
        guard panel.isVisible else { return }
        activeScreen = screenForCurrentPointer() ?? panel.screen ?? NSScreen.main
        let sizing = InputOverlaySizing.fromScreen(activeScreen)
        model.compactSize = sizing.compactSize
        model.centerGapWidth = sizing.centerGapWidth
        rootView.setExpanded(
            model.isExpanded,
            expandedSize: model.currentExpandedSize,
            compactSize: sizing.compactSize,
            animated: false
        )
        panel.setFrame(
            frame(for: InputOverlaySizing.windowSize, on: activeScreen),
            display: true
        )
    }

    @discardableResult
    private func showConfiguredPreviewIfNeeded() -> Bool {
        guard let preview = ProcessInfo.processInfo.environment["FRIDAY_OVERLAY_PREVIEW"] else {
            return false
        }
        model.dashboard = .preview
        switch preview.lowercased() {
        case "dashboard":
            show(.idle)
            Task { @MainActor [weak self] in
                await Task.yield()
                self?.expandDashboard()
            }
        case "listening-idle":
            model.audioLevel = 0.12
            model.isVoiceActive = false
            model.waveformLevels = InputOverlayModel.silentWaveformLevels
            show(.listening)
        case "listening":
            model.audioLevel = 0.72
            model.isVoiceActive = true
            model.waveformLevels = [0.24, 0.56, 0.34, 0.7, 0.42, 0.64, 0.3, 0.58]
            show(.listening)
        case "thinking":
            show(.processing(title: "正在整理文字", detail: nil, canCancel: true))
        case "result":
            show(
                .result(
                    text: "这是 Olli 整理后的示例文字，用于检查灵动岛展开状态。",
                    message: "未找到可安全写入的输入框",
                    canRetry: true
                )
            )
        case "failure":
            show(.failure("语音服务暂时不可用，请稍后再试。", canRetry: true))
        case "toast":
            showBottomToast("未收听到声音", duration: .seconds(5))
        default:
            show(.idle)
        }
        return true
    }
}

private struct InputOverlayView: View {
    @ObservedObject var model: InputOverlayModel

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .topLeading) {
                ZStack(alignment: .top) {
                    InputOverlayAtmosphereView(
                        phase: model.phase,
                        isExpanded: model.isExpanded
                    )
                    .zIndex(0)

                    VStack(spacing: 0) {
                        compactContent
                            .frame(height: model.isExpanded ? 6 : model.compactSize.height)
                            .opacity(model.isExpanded ? 0 : 1)

                        if model.isExpanded {
                            expandedContent
                                .transition(
                                    .scale(scale: 0.96, anchor: .top)
                                        .combined(with: .opacity)
                                )
                        }
                    }
                    .zIndex(1)
                }
                .frame(
                    width: model.currentSize.width,
                    height: model.currentSize.height,
                    alignment: .top
                )
                .overlay(alignment: .top) {
                    if !model.isExpanded {
                        Rectangle()
                            .fill(.black)
                            .frame(height: 1)
                            .padding(
                                .horizontal,
                                InputOverlayShapeMetrics.compactTopCornerRadius
                            )
                    }
                }
                .scaleEffect(
                    x: model.isCollapsing ? 0.72 : (model.isAppearing ? 0.84 : 1),
                    y: model.isCollapsing ? 0.82 : (model.isAppearing ? 0.88 : 1),
                    anchor: .top
                )
                .opacity(model.isCollapsing || model.isAppearing ? 0 : 1)
                .animation(
                    .spring(response: 0.32, dampingFraction: 0.86),
                    value: model.isAppearing
                )
                .animation(
                    .easeIn(duration: 0.18),
                    value: model.isCollapsing
                )
                .position(
                    x: geometry.size.width / 2,
                    y: model.currentSize.height / 2
                )
            }
            .frame(
                width: geometry.size.width,
                height: geometry.size.height,
                alignment: .topLeading
            )
            .animation(
                .easeInOut(duration: model.isExpanded ? 0.36 : 0.3),
                value: model.isExpanded
            )
            .animation(
                .easeInOut(duration: 0.36),
                value: model.expandedPage
            )
        }
        .ignoresSafeArea()
        .preferredColorScheme(.dark)
        .environment(\.controlActiveState, .active)
    }

    @ViewBuilder
    private var compactContent: some View {
        switch model.phase {
        case .idle, .hidden, .failure, .result, .notice:
            idleContent
        case .listening:
            listeningContent
        case .processing:
            thinkingContent
        case .conversation(let expression, let source):
            conversationContent(expression: expression, source: source)
        }
    }

    private var expandedContent: some View {
        ContentView(model: model)
    }

    private var idleContent: some View {
        HStack(spacing: 0) {
            compactWing {
                Image("灵动岛紧凑图标")
                    .renderingMode(.original)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 22, height: 22)
                    .offset(x: 4)
                    .accessibilityLabel("Olli")
            }

            Color.clear
                .frame(width: model.centerGapWidth)

            compactWing {
                Circle()
                    .fill(model.dashboard.serviceAvailable ? Color.green : Color.orange)
                    .frame(width: 7, height: 7)
                    .shadow(
                        color: (model.dashboard.serviceAvailable ? Color.green : Color.orange)
                            .opacity(0.7),
                        radius: 5
                    )
                    .offset(x: -4)
            }
        }
    }

    private var listeningContent: some View {
        HStack(spacing: 0) {
            compactWing {
                statusLabel("聆听中")
                    .offset(x: 4)
            }

            Color.clear
                .frame(width: model.centerGapWidth)

            compactWing {
                IslandWaveformView(
                    level: model.audioLevel,
                    waveformLevels: model.waveformLevels,
                    isVoiceActive: model.isVoiceActive
                )
                    .frame(width: 36, height: 18)
                    .offset(x: -4)
                    .shadow(color: Color.cyan.opacity(0.54), radius: 4)
            }
        }
    }

    private var thinkingContent: some View {
        HStack(spacing: 0) {
            compactWing {
                statusLabel("整理中")
            }

            Color.clear
                .frame(width: model.centerGapWidth)

            compactWing {
                ThinkingDotsView()
                    .frame(width: 32, height: 20)
            }
        }
    }

    private func conversationContent(
        expression: ConversationExpression,
        source: ConversationWaveformSource
    ) -> some View {
        HStack(spacing: 0) {
            compactWing {
                Text(expression.glyph)
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .minimumScaleFactor(0.72)
                    .frame(width: 48, height: 18)
                    .contentTransition(.interpolate)
                    .accessibilityLabel(expression.accessibilityLabel)
            }

            Color.clear
                .frame(width: model.centerGapWidth)

            compactWing {
                ConversationWaveformView(
                    source: source,
                    level: model.audioLevel,
                    waveformLevels: model.waveformLevels,
                    isVoiceActive: model.isVoiceActive
                )
                .frame(width: 38, height: 18)
                .shadow(
                    color: source == .assistant
                        ? Color.pink.opacity(0.48)
                        : Color.cyan.opacity(0.5),
                    radius: 4
                )
            }
        }
    }

    private func statusLabel(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(.white)
            .lineLimit(1)
    }

    private func compactWing<Content: View>(
        @ViewBuilder content: () -> Content
    ) -> some View {
        content()
            .frame(width: InputOverlaySizing.compactWingWidth, alignment: .center)
            .frame(maxHeight: .infinity, alignment: .center)
    }

}
