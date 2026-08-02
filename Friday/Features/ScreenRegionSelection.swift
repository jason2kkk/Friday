// 功能：在所有显示器上提供透明、可取消的拖拽框选界面，让用户明确选择要交给 Talk 的屏幕区域。
// 职责：创建跨屏幕选择窗口，跟踪鼠标起止位置，约束最小选区与指引位置，并输出包含显示器信息的全局坐标。
// 边界：只收集几何选择，不读取像素、不保存屏幕内容，也不向 Realtime Provider 发送图片。

import AppKit

@MainActor
protocol ScreenRegionSelecting: AnyObject {
    var onSelection: ((ScreenRegionSelection) -> Void)? { get set }
    var onCancel: (() -> Void)? { get set }
    var isSelecting: Bool { get }

    func beginSelection()
    func cancelSelection()
}

private final class ScreenRegionSelectionPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

private final class ScreenRegionSelectionView: NSView {
    var onSelection: ((CGRect) -> Void)?

    private var startPoint: CGPoint?
    private var selectedRect: CGRect = .zero
    private var pointerLocation: CGPoint = .zero
    private var isPointerInside = false
    private var trackingArea: NSTrackingArea?

    override var acceptsFirstResponder: Bool { true }
    override var isFlipped: Bool { false }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .crosshair)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea {
            removeTrackingArea(trackingArea)
        }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.activeAlways, .mouseEnteredAndExited, .mouseMoved],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) {
        isPointerInside = true
        updatePointer(with: event)
    }

    override func mouseExited(with event: NSEvent) {
        isPointerInside = false
        needsDisplay = true
    }

    override func mouseMoved(with event: NSEvent) {
        updatePointer(with: event)
    }

    override func mouseDown(with event: NSEvent) {
        let location = convert(event.locationInWindow, from: nil)
        isPointerInside = true
        pointerLocation = location
        startPoint = location
        selectedRect = .zero
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        guard let startPoint else { return }
        pointerLocation = convert(event.locationInWindow, from: nil)
        selectedRect = Self.normalizedRect(
            from: startPoint,
            to: pointerLocation
        ).intersection(bounds)
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        guard let startPoint else { return }
        pointerLocation = convert(event.locationInWindow, from: nil)
        selectedRect = Self.normalizedRect(
            from: startPoint,
            to: pointerLocation
        ).intersection(bounds)
        self.startPoint = nil
        needsDisplay = true
        guard selectedRect.width >= 12, selectedRect.height >= 12 else { return }
        onSelection?(selectedRect)
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        if !selectedRect.isEmpty {
            let selectionPath = NSBezierPath(
                roundedRect: selectedRect,
                xRadius: 4,
                yRadius: 4
            )
            NSColor(calibratedRed: 0.30, green: 0.84, blue: 1, alpha: 0.10).setFill()
            selectionPath.fill()
            selectionPath.lineWidth = 1.5
            NSColor(calibratedRed: 0.36, green: 0.88, blue: 1, alpha: 1).setStroke()
            selectionPath.stroke()
        }
        drawInstruction()
    }

    private func drawInstruction() {
        guard isPointerInside else { return }
        let frame = ScreenRegionSelectionLayout.instructionFrame(
            pointer: pointerLocation,
            bounds: bounds
        )
        let bubble = NSBezierPath(
            roundedRect: frame,
            xRadius: ScreenRegionSelectionLayout.bubbleCornerRadius,
            yRadius: ScreenRegionSelectionLayout.bubbleCornerRadius
        )
        NSColor.black.withAlphaComponent(0.88).setFill()
        bubble.fill()
        NSColor.white.withAlphaComponent(0.10).setStroke()
        bubble.lineWidth = 1
        bubble.stroke()

        let iconFrame = CGRect(x: frame.minX + 10, y: frame.midY - 8, width: 16, height: 16)
        if let icon = NSImage(
            systemSymbolName: "viewfinder",
            accessibilityDescription: "框选"
        )?.withSymbolConfiguration(
            NSImage.SymbolConfiguration(pointSize: 12, weight: .semibold)
                .applying(
                    NSImage.SymbolConfiguration(
                        hierarchicalColor: NSColor.white.withAlphaComponent(0.90)
                    )
                )
        ) {
            icon.draw(in: iconFrame)
        }

        let titleAttributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 11, weight: .semibold),
            .foregroundColor: NSColor.white.withAlphaComponent(0.96)
        ]
        let detailAttributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 9.5, weight: .regular),
            .foregroundColor: NSColor.white.withAlphaComponent(0.62)
        ]
        "拖动框选".draw(
            at: CGPoint(x: frame.minX + 32, y: frame.minY + 20),
            withAttributes: titleAttributes
        )
        "Esc 取消".draw(
            at: CGPoint(x: frame.minX + 32, y: frame.minY + 7),
            withAttributes: detailAttributes
        )
    }

    private func updatePointer(with event: NSEvent) {
        pointerLocation = convert(event.locationInWindow, from: nil)
        needsDisplay = true
    }

    func preparePointer(at point: CGPoint) {
        pointerLocation = point
        isPointerInside = bounds.contains(point)
        needsDisplay = true
    }

    private static func normalizedRect(from start: CGPoint, to end: CGPoint) -> CGRect {
        CGRect(
            x: min(start.x, end.x),
            y: min(start.y, end.y),
            width: abs(end.x - start.x),
            height: abs(end.y - start.y)
        )
    }
}

enum ScreenRegionSelectionLayout {
    static let bubbleSize = CGSize(width: 96, height: 44)
    static let bubbleCornerRadius: CGFloat = 11
    private static let pointerGap: CGFloat = 16
    private static let edgeInset: CGFloat = 8

    static func instructionFrame(pointer: CGPoint, bounds: CGRect) -> CGRect {
        var origin = CGPoint(
            x: pointer.x + pointerGap,
            y: pointer.y - bubbleSize.height - pointerGap
        )
        if origin.x + bubbleSize.width > bounds.maxX - edgeInset {
            origin.x = pointer.x - bubbleSize.width - pointerGap
        }
        if origin.y < bounds.minY + edgeInset {
            origin.y = pointer.y + pointerGap
        }
        origin.x = min(
            max(origin.x, bounds.minX + edgeInset),
            bounds.maxX - bubbleSize.width - edgeInset
        )
        origin.y = min(
            max(origin.y, bounds.minY + edgeInset),
            bounds.maxY - bubbleSize.height - edgeInset
        )
        return CGRect(origin: origin, size: bubbleSize)
    }
}

@MainActor
final class ScreenRegionSelectionController: ScreenRegionSelecting {
    var onSelection: ((ScreenRegionSelection) -> Void)?
    var onCancel: (() -> Void)?

    private(set) var isSelecting = false
    private var panels: [ScreenRegionSelectionPanel] = []
    private var globalEscapeMonitor: Any?
    private var localEscapeMonitor: Any?

    init() {
        guard ProcessInfo.processInfo.environment[
            "FRIDAY_SCREEN_SELECTION_PREVIEW"
        ] == "1" else { return }
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(350))
            self?.beginSelection()
        }
    }

    func beginSelection() {
        guard !isSelecting else { return }
        isSelecting = true
        installEscapeMonitors()

        let pointerLocation = NSEvent.mouseLocation
        var keyPanel: ScreenRegionSelectionPanel?
        for screen in NSScreen.screens {
            guard let displayID = screen.deviceDescription[
                NSDeviceDescriptionKey("NSScreenNumber")
            ] as? NSNumber else { continue }

            let panel = ScreenRegionSelectionPanel(
                contentRect: screen.frame,
                styleMask: [.borderless, .nonactivatingPanel],
                backing: .buffered,
                defer: false
            )
            let selectionView = ScreenRegionSelectionView(frame: CGRect(origin: .zero, size: screen.frame.size))
            selectionView.autoresizingMask = [.width, .height]
            selectionView.preparePointer(
                at: CGPoint(
                    x: pointerLocation.x - screen.frame.minX,
                    y: pointerLocation.y - screen.frame.minY
                )
            )
            selectionView.onSelection = { [weak self, weak panel] localRect in
                guard let self, let panel else { return }
                let globalRect = CGRect(
                    x: panel.frame.minX + localRect.minX,
                    y: panel.frame.minY + localRect.minY,
                    width: localRect.width,
                    height: localRect.height
                )
                complete(
                    ScreenRegionSelection(
                        displayID: CGDirectDisplayID(displayID.uint32Value),
                        screenFrame: panel.frame,
                        selectedFrame: globalRect
                    )
                )
            }

            panel.contentView = selectionView
            panel.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.mainMenuWindow)) + 8)
            panel.collectionBehavior = [
                .canJoinAllSpaces,
                .fullScreenAuxiliary,
                .stationary,
                .ignoresCycle
            ]
            panel.backgroundColor = .clear
            panel.isOpaque = false
            panel.hasShadow = false
            panel.acceptsMouseMovedEvents = true
            panel.hidesOnDeactivate = false
            panel.isReleasedWhenClosed = false
            panel.isMovable = false
            panel.isExcludedFromWindowsMenu = true
            panel.orderFrontRegardless()
            panels.append(panel)

            if NSMouseInRect(pointerLocation, screen.frame, false) {
                keyPanel = panel
            }
        }
        (keyPanel ?? panels.first)?.makeKey()
    }

    func cancelSelection() {
        guard isSelecting else { return }
        tearDown()
        onCancel?()
    }

    private func complete(_ selection: ScreenRegionSelection) {
        guard isSelecting else { return }
        tearDown()
        onSelection?(selection)
    }

    private func tearDown() {
        isSelecting = false
        panels.forEach { $0.orderOut(nil) }
        panels.removeAll(keepingCapacity: false)
        removeEscapeMonitors()
    }

    private func installEscapeMonitors() {
        globalEscapeMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) {
            [weak self] event in
            guard event.keyCode == 53 else { return }
            Task { @MainActor [weak self] in self?.cancelSelection() }
        }
        localEscapeMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) {
            [weak self] event in
            guard event.keyCode == 53 else { return event }
            self?.cancelSelection()
            return nil
        }
    }

    private func removeEscapeMonitors() {
        if let globalEscapeMonitor {
            NSEvent.removeMonitor(globalEscapeMonitor)
            self.globalEscapeMonitor = nil
        }
        if let localEscapeMonitor {
            NSEvent.removeMonitor(localEscapeMonitor)
            self.localEscapeMonitor = nil
        }
    }

    deinit {
        if let globalEscapeMonitor { NSEvent.removeMonitor(globalEscapeMonitor) }
        if let localEscapeMonitor { NSEvent.removeMonitor(localEscapeMonitor) }
    }
}
