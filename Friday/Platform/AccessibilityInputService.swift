// 功能：在其他 macOS 应用中识别并锁定可编辑输入目标，再把 Friday 的最终文本写回正确位置。
// 职责：管理 Accessibility 授权，分层解析和复验目标，恢复应用与控件焦点，并通过剪贴板和模拟粘贴完成可撤销写入与剪贴板恢复。
// 边界：禁止向密码控件写入；不负责录音或文本生成，无法验证目标时返回明确结果而不猜测写入。

import AppKit
import ApplicationServices
import OSLog

struct FocusedInputTarget {
    let element: AXUIElement
    let processIdentifier: pid_t
    let applicationName: String
    let role: String
}

enum InputTargetResult {
    case target(FocusedInputTarget)
    case accessibilityDenied
    case fridayFocused
    case noFocusedElement
    case secureInput
    case notEditable
    case systemError(AXError)
}

enum TextInsertionMethod {
    case pasteboard

    var description: String {
        switch self {
        case .pasteboard:
            return "剪贴板"
        }
    }
}

enum TextInsertionResult {
    case verified(TextInsertionMethod)
    case dispatched(TextInsertionMethod)
    case targetUnavailable
    case focusChanged
    case pasteEventUnavailable
    case systemError(AXError)
}

struct AccessibilityElementProfile: Equatable {
    let role: String?
    let subrole: String?
    let isEnabled: Bool
    let isExplicitlyEditable: Bool
    let selectedTextIsSettable: Bool
    let valueIsSettable: Bool
}

enum AccessibilityElementDisposition: Equatable {
    case editable
    case secure
    case notEditable
}

enum InputTargetClassifier {
    private static let editableRoles: Set<String> = [
        "AXTextField",
        "AXTextArea",
        "AXComboBox"
    ]

    static func classify(_ profile: AccessibilityElementProfile) -> AccessibilityElementDisposition {
        if profile.subrole == "AXSecureTextField" {
            return .secure
        }
        guard profile.isEnabled else { return .notEditable }
        if profile.isExplicitlyEditable
            || profile.selectedTextIsSettable
            || profile.valueIsSettable
            || profile.role.map(editableRoles.contains) == true {
            return .editable
        }
        return .notEditable
    }
}

final class AccessibilityInputService {
    private enum ResolvedElement {
        case editable(AXUIElement)
        case secure
    }

    private let logger = Logger(subsystem: "com.example.Friday", category: "InputTarget")

    var isTrusted: Bool {
        AXIsProcessTrusted()
    }

    var frontmostApplicationName: String {
        NSWorkspace.shared.frontmostApplication?.localizedName ?? "当前应用"
    }

    @discardableResult
    func requestPermission() -> Bool {
        let promptKey = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        return AXIsProcessTrustedWithOptions([promptKey: true] as CFDictionary)
    }

    func captureFocusedTarget(promptIfNeeded: Bool) -> InputTargetResult {
        let trusted = promptIfNeeded ? requestPermission() : isTrusted
        guard trusted else { return .accessibilityDenied }

        let frontmostApplication = NSWorkspace.shared.frontmostApplication
        if frontmostApplication?.processIdentifier == ProcessInfo.processInfo.processIdentifier {
            return .fridayFocused
        }

        let lookup = focusedElementCandidates(frontmostApplication: frontmostApplication)
        var foundNonEditableElement = false

        for candidate in lookup.elements {
            switch resolveEditableElement(startingAt: candidate) {
            case .editable(let element):
                return makeTarget(from: element)
            case .secure:
                return .secureInput
            case nil:
                foundNonEditableElement = true
            }
        }

        if let focusedWindow = lookup.focusedWindow {
            switch focusedEditableDescendant(in: focusedWindow) {
            case .editable(let element):
                return makeTarget(from: element)
            case .secure:
                return .secureInput
            case nil:
                break
            }
        }

        let applicationName = frontmostApplication?.localizedName ?? "未知应用"
        logger.notice(
            "No editable focus in \(applicationName, privacy: .public); system AXError=\(lookup.systemResult.rawValue, privacy: .public)"
        )

        if foundNonEditableElement {
            return .notEditable
        }
        if let error = lookup.firstUnexpectedError {
            return .systemError(error)
        }
        return .noFocusedElement
    }

    private func makeTarget(from element: AXUIElement) -> InputTargetResult {
        var processIdentifier: pid_t = 0
        let processResult = AXUIElementGetPid(element, &processIdentifier)
        guard processResult == .success else {
            return .systemError(processResult)
        }

        if processIdentifier == ProcessInfo.processInfo.processIdentifier {
            return .fridayFocused
        }

        let application = NSRunningApplication(processIdentifier: processIdentifier)
        let applicationName = application?.localizedName ?? "未知应用"
        let role = stringAttribute(kAXRoleAttribute, from: element) ?? "文本输入框"
        logger.debug(
            "Resolved input target in \(applicationName, privacy: .public), role=\(role, privacy: .public)"
        )
        return .target(
            FocusedInputTarget(
                element: element,
                processIdentifier: processIdentifier,
                applicationName: applicationName,
                role: role
            )
        )
    }

    func insert(_ text: String, into target: FocusedInputTarget) async -> TextInsertionResult {
        guard NSRunningApplication(processIdentifier: target.processIdentifier) != nil else {
            return .targetUnavailable
        }
        return await insertWithPasteboard(text, into: target)
    }

    private func resolveEditableElement(startingAt element: AXUIElement) -> ResolvedElement? {
        var currentElement: AXUIElement? = element

        for _ in 0..<8 {
            guard let current = currentElement else { return nil }
            switch InputTargetClassifier.classify(profile(for: current)) {
            case .editable:
                return .editable(current)
            case .secure:
                return .secure
            case .notEditable:
                let parent = elementAttribute(kAXParentAttribute, from: current).element
                if let parent, !CFEqual(parent, current) {
                    currentElement = parent
                } else {
                    return nil
                }
            }
        }
        return nil
    }

    private func profile(for element: AXUIElement) -> AccessibilityElementProfile {
        var selectedTextIsSettable = DarwinBoolean(false)
        let selectedTextResult = AXUIElementIsAttributeSettable(
            element,
            kAXSelectedTextAttribute as CFString,
            &selectedTextIsSettable
        )

        var valueIsSettable = DarwinBoolean(false)
        let valueResult = AXUIElementIsAttributeSettable(
            element,
            kAXValueAttribute as CFString,
            &valueIsSettable
        )

        return AccessibilityElementProfile(
            role: stringAttribute(kAXRoleAttribute, from: element),
            subrole: stringAttribute(kAXSubroleAttribute, from: element),
            isEnabled: boolAttribute(kAXEnabledAttribute, from: element) ?? true,
            isExplicitlyEditable: boolAttribute("AXEditable", from: element) ?? false,
            selectedTextIsSettable: selectedTextResult == .success && selectedTextIsSettable.boolValue,
            valueIsSettable: valueResult == .success && valueIsSettable.boolValue
        )
    }

    private func stringAttribute(_ attribute: String, from element: AXUIElement) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else {
            return nil
        }
        return value as? String
    }

    private func boolAttribute(_ attribute: String, from element: AXUIElement) -> Bool? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success,
              let number = value as? NSNumber else {
            return nil
        }
        return number.boolValue
    }

    @MainActor
    private func insertWithPasteboard(
        _ text: String,
        into target: FocusedInputTarget
    ) async -> TextInsertionResult {
        guard let application = NSRunningApplication(processIdentifier: target.processIdentifier) else {
            return .targetUnavailable
        }

        application.activate()
        try? await Task.sleep(for: .milliseconds(100))

        let focusResult = AXUIElementSetAttributeValue(
            target.element,
            kAXFocusedAttribute as CFString,
            kCFBooleanTrue
        )

        try? await Task.sleep(for: .milliseconds(50))
        guard isStillFocused(target.element) else {
            return focusResult == .success ? .focusChanged : .systemError(focusResult)
        }

        let valueBeforePaste = stringAttribute(kAXValueAttribute, from: target.element)
        let pasteboard = NSPasteboard.general
        let snapshot = PasteboardSnapshot(pasteboard: pasteboard)
        pasteboard.clearContents()
        guard pasteboard.setString(text, forType: .string) else {
            return .pasteEventUnavailable
        }
        let temporaryChangeCount = pasteboard.changeCount

        guard postPasteShortcut() else {
            if pasteboard.changeCount == temporaryChangeCount {
                snapshot.restore(to: pasteboard)
            }
            return .pasteEventUnavailable
        }

        try? await Task.sleep(for: .milliseconds(250))
        if pasteboard.changeCount == temporaryChangeCount {
            snapshot.restore(to: pasteboard)
        }
        let valueAfterPaste = stringAttribute(kAXValueAttribute, from: target.element)
        if let valueBeforePaste,
           let valueAfterPaste,
           valueBeforePaste != valueAfterPaste,
           valueAfterPaste.contains(text) {
            return .verified(.pasteboard)
        }
        return .dispatched(.pasteboard)
    }

    private func isStillFocused(_ target: AXUIElement) -> Bool {
        let lookup = focusedElementCandidates(frontmostApplication: NSWorkspace.shared.frontmostApplication)
        for candidate in lookup.elements {
            if CFEqual(candidate, target) {
                return true
            }
            if case .editable(let resolved)? = resolveEditableElement(startingAt: candidate),
               CFEqual(resolved, target) {
                return true
            }
        }
        if let focusedWindow = lookup.focusedWindow,
           case .editable(let resolved)? = focusedEditableDescendant(in: focusedWindow),
           CFEqual(resolved, target) {
            return true
        }
        return false
    }

    private func focusedElementCandidates(
        frontmostApplication: NSRunningApplication?
    ) -> (
        elements: [AXUIElement],
        focusedWindow: AXUIElement?,
        systemResult: AXError,
        firstUnexpectedError: AXError?
    ) {
        var elements: [AXUIElement] = []
        var unexpectedErrors: [AXError] = []
        var focusedWindow: AXUIElement?

        let systemLookup = elementAttribute(
            kAXFocusedUIElementAttribute,
            from: AXUIElementCreateSystemWide()
        )
        appendUnique(systemLookup.element, to: &elements)
        collectUnexpected(systemLookup.result, into: &unexpectedErrors)

        if let frontmostApplication {
            let applicationElement = AXUIElementCreateApplication(frontmostApplication.processIdentifier)
            let applicationLookup = elementAttribute(
                kAXFocusedUIElementAttribute,
                from: applicationElement
            )
            appendUnique(applicationLookup.element, to: &elements)
            collectUnexpected(applicationLookup.result, into: &unexpectedErrors)

            let windowLookup = elementAttribute(kAXFocusedWindowAttribute, from: applicationElement)
            focusedWindow = windowLookup.element
            collectUnexpected(windowLookup.result, into: &unexpectedErrors)
            if let window = windowLookup.element {
                let windowFocusLookup = elementAttribute(kAXFocusedUIElementAttribute, from: window)
                appendUnique(windowFocusLookup.element, to: &elements)
                collectUnexpected(windowFocusLookup.result, into: &unexpectedErrors)
            }
        }

        return (elements, focusedWindow, systemLookup.result, unexpectedErrors.first)
    }

    // Some Web and Electron apps omit AXFocusedUIElement but mark one descendant as focused.
    private func focusedEditableDescendant(in root: AXUIElement) -> ResolvedElement? {
        var queue: [(element: AXUIElement, depth: Int)] = [(root, 0)]
        var index = 0
        var editableMatches: [AXUIElement] = []
        var foundSecureInput = false

        while index < queue.count, index < 240 {
            let item = queue[index]
            index += 1

            if boolAttribute(kAXFocusedAttribute, from: item.element) == true {
                switch resolveEditableElement(startingAt: item.element) {
                case .editable(let element):
                    appendUnique(element, to: &editableMatches)
                case .secure:
                    foundSecureInput = true
                case nil:
                    break
                }
            }

            guard item.depth < 10 else { continue }
            for child in elementArrayAttribute(kAXChildrenAttribute, from: item.element) {
                queue.append((child, item.depth + 1))
            }
        }

        if foundSecureInput {
            return .secure
        }
        guard editableMatches.count == 1, let match = editableMatches.first else {
            return nil
        }
        return .editable(match)
    }

    private func elementAttribute(
        _ attribute: String,
        from element: AXUIElement
    ) -> (result: AXError, element: AXUIElement?) {
        var value: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(element, attribute as CFString, &value)
        guard result == .success,
              let value,
              CFGetTypeID(value) == AXUIElementGetTypeID() else {
            return (result, nil)
        }
        return (result, unsafeBitCast(value, to: AXUIElement.self))
    }

    private func elementArrayAttribute(_ attribute: String, from element: AXUIElement) -> [AXUIElement] {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success,
              let elements = value as? [AXUIElement] else {
            return []
        }
        return elements
    }

    private func appendUnique(_ element: AXUIElement?, to elements: inout [AXUIElement]) {
        guard let element, !elements.contains(where: { CFEqual($0, element) }) else { return }
        elements.append(element)
    }

    private func collectUnexpected(_ error: AXError, into errors: inout [AXError]) {
        guard error != .success,
              error != .noValue,
              error != .attributeUnsupported else { return }
        errors.append(error)
    }

    private func postPasteShortcut() -> Bool {
        guard let source = CGEventSource(stateID: .hidSystemState),
              let keyDown = CGEvent(keyboardEventSource: source, virtualKey: 0x09, keyDown: true),
              let keyUp = CGEvent(keyboardEventSource: source, virtualKey: 0x09, keyDown: false) else {
            return false
        }

        keyDown.flags = .maskCommand
        keyUp.flags = .maskCommand
        keyDown.post(tap: .cghidEventTap)
        keyUp.post(tap: .cghidEventTap)
        return true
    }
}

private struct PasteboardSnapshot {
    private let items: [[NSPasteboard.PasteboardType: Data]]

    init(pasteboard: NSPasteboard) {
        items = (pasteboard.pasteboardItems ?? []).map { item in
            Dictionary(uniqueKeysWithValues: item.types.compactMap { type in
                item.data(forType: type).map { (type, $0) }
            })
        }
    }

    func restore(to pasteboard: NSPasteboard) {
        pasteboard.clearContents()
        let restoredItems = items.map { dataByType in
            let item = NSPasteboardItem()
            for (type, data) in dataByType {
                item.setData(data, forType: type)
            }
            return item
        }
        if !restoredItems.isEmpty {
            pasteboard.writeObjects(restoredItems)
        }
    }
}
