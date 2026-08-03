// 功能：管理 Friday 的 AppKit 窗口生命周期，使带 Dock 入口的后台助手可以按需显示唯一原生主工作台。
// 职责：声明关窗后继续运行和 Dock 重开行为，配置 NSWindow、原生玻璃、尺寸与 SwiftUI ContentView 宿主，并负责激活和聚焦窗口。
// 边界：不持有业务工作流、不读取权限或网络状态、不改变 LSUIElement 策略；关闭窗口不会退出 Friday。

import AppKit
import SwiftUI

extension Notification.Name {
    static let fridayOpenWorkspace = Notification.Name("Friday.openWorkspace")
}

@MainActor
final class FridayApplicationDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationShouldHandleReopen(
        _ sender: NSApplication,
        hasVisibleWindows flag: Bool
    ) -> Bool {
        NotificationCenter.default.post(name: .fridayOpenWorkspace, object: nil)
        return true
    }
}

enum AppWorkspaceSizing {
    static let defaultSize = NSSize(width: 920, height: 640)
    static let minimumSize = NSSize(width: 760, height: 560)

    static var configuredInitialSize: NSSize {
        let preview = ProcessInfo.processInfo.environment["FRIDAY_WORKSPACE_PREVIEW"]
        return preview?.hasSuffix("-minimum") == true ? minimumSize : defaultSize
    }
}

private final class AppWorkspaceRootView: NSView {
    private let backdropView: NSView
    private let hostingView: NSView

    init(frame frameRect: NSRect, hostingView: NSView) {
        self.hostingView = hostingView

        if #available(macOS 26.0, *) {
            let glassView = NSGlassEffectView()
            glassView.appearance = NSAppearance(named: .aqua)
            glassView.style = .regular
            glassView.tintColor = NSColor.white.withAlphaComponent(0.3)
            backdropView = glassView
        } else {
            let visualEffectView = NSVisualEffectView()
            visualEffectView.appearance = NSAppearance(named: .aqua)
            visualEffectView.material = .underWindowBackground
            visualEffectView.blendingMode = .behindWindow
            visualEffectView.state = .active
            backdropView = visualEffectView
        }

        super.init(frame: frameRect)

        appearance = NSAppearance(named: .aqua)
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
        addSubview(backdropView)
        addSubview(hostingView, positioned: .above, relativeTo: backdropView)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layout() {
        super.layout()
        backdropView.frame = bounds
        hostingView.frame = bounds
    }
}

@MainActor
final class AppWorkspaceWindowController: NSObject, NSWindowDelegate {
    private let window: NSWindow

    init(model: InputOverlayModel) {
        let initialSize = AppWorkspaceSizing.configuredInitialSize
        window = NSWindow(
            contentRect: NSRect(origin: .zero, size: initialSize),
            styleMask: [
                .titled,
                .closable,
                .miniaturizable,
                .resizable,
                .fullSizeContentView
            ],
            backing: .buffered,
            defer: false
        )

        super.init()

        let hostingView = NSHostingView(
            rootView: ContentView(model: model)
                .preferredColorScheme(.light)
        )
        hostingView.frame = NSRect(origin: .zero, size: initialSize)
        hostingView.autoresizingMask = [.width, .height]
        hostingView.wantsLayer = true
        hostingView.layer?.backgroundColor = NSColor.clear.cgColor
        window.contentView = AppWorkspaceRootView(
            frame: NSRect(origin: .zero, size: initialSize),
            hostingView: hostingView
        )
        window.delegate = self
        window.title = "Friday"
        window.appearance = NSAppearance(named: .aqua)
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.titlebarSeparatorStyle = .none
        window.backgroundColor = .clear
        window.isOpaque = false
        window.isReleasedWhenClosed = false
        window.minSize = AppWorkspaceSizing.minimumSize
        window.collectionBehavior = [.managed, .participatesInCycle]
        window.animationBehavior = .documentWindow
        window.center()
    }

    func show() {
        if !window.isVisible {
            window.center()
        }
        NSApplication.shared.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        window.resignKey()
    }
}
