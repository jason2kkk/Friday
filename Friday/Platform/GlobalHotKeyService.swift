// 功能：在系统范围识别 Friday 的 Dictate、Talk 和屏幕框选修饰键手势。
// 职责：建立 CGEventTap，跟踪修饰键按下与释放顺序，识别纯 `Fn`、`Control + Option`、`Control + Command`，并上报对应动作。
// 边界：包含额外修饰键或普通按键时不触发且尽量不吞事件；本服务不直接开始录音、对话或截图。

import AppKit
import OSLog

private func globalHotKeyEventTapCallback(
    proxy: CGEventTapProxy,
    type: CGEventType,
    event: CGEvent,
    userInfo: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    guard let userInfo else { return Unmanaged.passUnretained(event) }
    let service = Unmanaged<GlobalHotKeyService>
        .fromOpaque(userInfo)
        .takeUnretainedValue()
    return MainActor.assumeIsolated {
        service.handleEventTap(type: type, event: event)
    }
}

enum GlobalHotKeyAction: Equatable {
    case dictation
    case conversation
    case screenRegion
}

struct ModifierChordRecognizer {
    private static let relevantModifiers: NSEvent.ModifierFlags = [
        .command,
        .option,
        .function,
        .shift,
        .control
    ]

    private var armedAction: GlobalHotKeyAction?
    private var pendingAction: GlobalHotKeyAction?
    private var isBlockedUntilRelease = false
    private var isConsumingFunctionGesture = false
    private var consumesTrailingFunctionKeyUp = false
    private(set) var suppressesCurrentFlagsEvent = false

    var shouldConsumeFunctionKeyEvent: Bool {
        isConsumingFunctionGesture || consumesTrailingFunctionKeyUp
    }

    mutating func handleFlagsChanged(
        _ flags: NSEvent.ModifierFlags
    ) -> GlobalHotKeyAction? {
        let current = flags.intersection(Self.relevantModifiers)
        suppressesCurrentFlagsEvent = false

        if current == [.function],
           armedAction == nil,
           pendingAction == nil,
           !isBlockedUntilRelease {
            consumesTrailingFunctionKeyUp = false
            isConsumingFunctionGesture = true
        }
        if isConsumingFunctionGesture,
           current == [.function] || current.isEmpty {
            suppressesCurrentFlagsEvent = true
        }

        guard !current.isEmpty else {
            let action = isBlockedUntilRelease ? nil : (pendingAction ?? armedAction)
            let completedPureFunctionGesture = isConsumingFunctionGesture
                && action == .dictation
            armedAction = nil
            pendingAction = nil
            isBlockedUntilRelease = false
            isConsumingFunctionGesture = false
            consumesTrailingFunctionKeyUp = completedPureFunctionGesture
            return action
        }

        guard !isBlockedUntilRelease else { return nil }

        if let pendingAction {
            let expectedModifiers = modifiers(for: pendingAction)
            if current.isSubset(of: expectedModifiers), current != expectedModifiers {
                return nil
            }
            self.pendingAction = nil
            isBlockedUntilRelease = true
            return nil
        }

        if let armedAction {
            let armedModifiers = modifiers(for: armedAction)
            if current == armedModifiers {
                return nil
            }
            self.armedAction = nil
            if current.isSubset(of: armedModifiers) {
                pendingAction = armedAction
            } else {
                isBlockedUntilRelease = true
            }
            return nil
        }

        if let matchingAction = Self.actions.first(where: {
            current == modifiers(for: $0)
        }) {
            armedAction = matchingAction
        } else if !Self.actions.contains(where: {
            current.isSubset(of: modifiers(for: $0))
        }) {
            isBlockedUntilRelease = true
        }
        return nil
    }

    mutating func handleKeyDown(modifierFlags: NSEvent.ModifierFlags) {
        consumesTrailingFunctionKeyUp = false
        let current = modifierFlags.intersection(Self.relevantModifiers)
        guard armedAction != nil || !current.isEmpty else { return }
        armedAction = nil
        pendingAction = nil
        isBlockedUntilRelease = true
    }

    mutating func consumeFunctionKeyUpIfNeeded() -> Bool {
        let shouldConsume = shouldConsumeFunctionKeyEvent
        consumesTrailingFunctionKeyUp = false
        return shouldConsume
    }

    mutating func reset() {
        armedAction = nil
        pendingAction = nil
        isBlockedUntilRelease = false
        isConsumingFunctionGesture = false
        consumesTrailingFunctionKeyUp = false
        suppressesCurrentFlagsEvent = false
    }

    private func modifiers(
        for action: GlobalHotKeyAction
    ) -> NSEvent.ModifierFlags {
        switch action {
        case .dictation:
            return [.function]
        case .conversation:
            return [.control, .option]
        case .screenRegion:
            return [.control, .command]
        }
    }

    private static let actions: [GlobalHotKeyAction] = [
        .dictation,
        .conversation,
        .screenRegion
    ]
}

@MainActor
final class GlobalHotKeyService {
    private let logger = Logger(subsystem: "com.example.Friday", category: "HotKey")

    enum RegistrationError: LocalizedError {
        case eventMonitor

        var errorDescription: String? {
            "无法启用全局快捷键监听，请检查辅助功能权限。"
        }
    }

    var onPressed: (@MainActor (GlobalHotKeyAction) -> Void)?

    private var eventTap: CFMachPort?
    private var eventTapSource: CFRunLoopSource?
    private var recognizer = ModifierChordRecognizer()

    func register() throws {
        guard eventTap == nil else { return }
        let eventMask = (CGEventMask(1) << CGEventType.flagsChanged.rawValue)
            | (CGEventMask(1) << CGEventType.keyDown.rawValue)
            | (CGEventMask(1) << CGEventType.keyUp.rawValue)
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: eventMask,
            callback: globalHotKeyEventTapCallback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            throw RegistrationError.eventMonitor
        }
        guard let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0) else {
            CFMachPortInvalidate(tap)
            throw RegistrationError.eventMonitor
        }
        eventTap = tap
        eventTapSource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        logger.info(
            "Registered Fn, Control + Option, and Control + Command modifier chords"
        )
    }

    func unregister() {
        recognizer.reset()
        if let eventTapSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), eventTapSource, .commonModes)
        }
        if let eventTap {
            CGEvent.tapEnable(tap: eventTap, enable: false)
            CFMachPortInvalidate(eventTap)
        }
        eventTapSource = nil
        eventTap = nil
    }

    fileprivate func handleEventTap(
        type: CGEventType,
        event: CGEvent
    ) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            recognizer.reset()
            if let eventTap {
                CGEvent.tapEnable(tap: eventTap, enable: true)
            }
            logger.error(
                "Global hot key event tap re-enabled after disable type=\(type.rawValue, privacy: .public)"
            )
            return Unmanaged.passUnretained(event)
        }

        guard let nsEvent = NSEvent(cgEvent: event) else {
            return Unmanaged.passUnretained(event)
        }
        let action: GlobalHotKeyAction?
        var suppressEvent = false
        switch type {
        case .flagsChanged:
            action = recognizer.handleFlagsChanged(nsEvent.modifierFlags)
            suppressEvent = recognizer.suppressesCurrentFlagsEvent
        case .keyDown:
            if event.getIntegerValueField(.keyboardEventKeycode) == 63,
               recognizer.shouldConsumeFunctionKeyEvent {
                suppressEvent = true
            } else {
                recognizer.handleKeyDown(modifierFlags: nsEvent.modifierFlags)
            }
            action = nil
        case .keyUp:
            suppressEvent = event.getIntegerValueField(.keyboardEventKeycode) == 63
                && recognizer.consumeFunctionKeyUpIfNeeded()
            action = nil
        default:
            action = nil
        }

        if let action {
            logger.debug("Global modifier chord received")
            // Return from CGEventTap before microphone start/stop or UI work runs.
            DispatchQueue.main.async { [weak self] in
                self?.onPressed?(action)
            }
        }

        if suppressEvent || action == .dictation {
            logger.info(
                "Fn gesture event type=\(type.rawValue, privacy: .public) flags=\(nsEvent.modifierFlags.rawValue, privacy: .public) consumed=\(suppressEvent, privacy: .public) action=\(action == .dictation, privacy: .public)"
            )
        }

        // macOS starts recognizing the configured Globe/Fn single-press action
        // on press. Consume both boundaries of a pure-Fn candidate; events that
        // include another modifier or regular key still pass through.
        return suppressEvent ? nil : Unmanaged.passUnretained(event)
    }

    deinit {
        if let eventTapSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), eventTapSource, .commonModes)
        }
        if let eventTap {
            CGEvent.tapEnable(tap: eventTap, enable: false)
            CFMachPortInvalidate(eventTap)
        }
    }
}
