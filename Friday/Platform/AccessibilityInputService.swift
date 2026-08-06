// 功能：在其他 macOS 应用中识别并锁定可编辑输入目标，再把 Friday 的最终文本写回正确位置。
// 职责：管理 Accessibility 授权，分层解析和复验焦点目标或目标窗口内唯一可编辑控件，恢复应用与控件焦点，并通过受约束点击、剪贴板和模拟粘贴完成可撤销写入与剪贴板恢复。
// 边界：禁止向密码控件写入；仅点击仍命中原可编辑目标的指针位置，不在多个可编辑控件之间猜测，不负责录音或文本生成。

import AppKit
import ApplicationServices
import OSLog

enum InputTargetCaptureSource: Equatable {
    case keyboardFocus
    case uniqueEditableControl
    case pointer(CGPoint)
}

struct FocusedInputTarget {
    let element: AXUIElement
    let processIdentifier: pid_t
    let applicationName: String
    let role: String
    let identifier: String?
    let position: CGPoint?
    let size: CGSize?
    let captureSource: InputTargetCaptureSource

    init(
        element: AXUIElement,
        processIdentifier: pid_t,
        applicationName: String,
        role: String,
        identifier: String? = nil,
        position: CGPoint? = nil,
        size: CGSize? = nil,
        captureSource: InputTargetCaptureSource = .keyboardFocus
    ) {
        self.element = element
        self.processIdentifier = processIdentifier
        self.applicationName = applicationName
        self.role = role
        self.identifier = identifier
        self.position = position
        self.size = size
        self.captureSource = captureSource
    }
}

enum InputFocusRecoveryPolicy {
    static func allowsPointerClick(
        captureSource: InputTargetCaptureSource,
        targetProcessIdentifier: pid_t,
        frontmostProcessIdentifier: pid_t?,
        pointerStillMatchesTarget: Bool
    ) -> Bool {
        guard case .pointer = captureSource else { return false }
        return frontmostProcessIdentifier == targetProcessIdentifier
            && pointerStillMatchesTarget
    }
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
        return captureTarget(
            in: frontmostApplication,
            fallbackApplicationName: "未知应用",
            includeSystemWideCandidate: true,
            includeUniqueEditableCandidate: false
        )
    }

    /// Resolves the target used by Dictate without treating a missing keyboard
    /// focus as permission to guess. Some Web/Electron surfaces expose the
    /// editable control under the pointer before they expose AXFocusedUIElement.
    func captureDictationTarget(promptIfNeeded: Bool) -> InputTargetResult {
        let focusedResult = captureFocusedTarget(promptIfNeeded: promptIfNeeded)
        switch focusedResult {
        case .target, .secureInput, .accessibilityDenied:
            return focusedResult
        case .fridayFocused, .noFocusedElement, .notEditable, .systemError:
            break
        }

        let pointerResult = captureTargetAtPointer()
        switch pointerResult {
        case .target(let target):
            logger.info(
                "Resolved Dictate target under pointer in \(target.applicationName, privacy: .public), role=\(target.role, privacy: .public)"
            )
            return pointerResult
        case .secureInput:
            logger.info("Pointer is over a secure Dictate target; refusing write")
            return pointerResult
        case .accessibilityDenied, .fridayFocused, .noFocusedElement, .notEditable, .systemError:
            return focusedResult
        }
    }

    func captureFocusedTarget(
        processIdentifier: pid_t,
        applicationName: String
    ) -> InputTargetResult {
        guard isTrusted else { return .accessibilityDenied }
        guard let application = NSRunningApplication(processIdentifier: processIdentifier),
              !application.isTerminated else {
            return .noFocusedElement
        }
        return captureTarget(
            in: application,
            fallbackApplicationName: applicationName,
            includeSystemWideCandidate: false,
            includeUniqueEditableCandidate: false
        )
    }

    /// Resolves an Agent write target inside one explicit application. Pointer
    /// fallback is allowed only while that exact application is frontmost and
    /// the element under the pointer belongs to the same process.
    func captureActionTarget(
        processIdentifier: pid_t,
        applicationName: String
    ) -> InputTargetResult {
        guard isTrusted else { return .accessibilityDenied }
        guard let application = NSRunningApplication(processIdentifier: processIdentifier),
              !application.isTerminated else {
            return .noFocusedElement
        }
        let focusedResult = captureTarget(
            in: application,
            fallbackApplicationName: applicationName,
            includeSystemWideCandidate: false,
            includeUniqueEditableCandidate: true
        )
        switch focusedResult {
        case .target, .secureInput, .accessibilityDenied:
            return focusedResult
        case .fridayFocused, .noFocusedElement, .notEditable, .systemError:
            break
        }

        guard NSWorkspace.shared.frontmostApplication?.processIdentifier
                == processIdentifier,
              let point = CGEvent(source: nil)?.location else {
            return focusedResult
        }

        let pointerResult = captureTarget(
            at: point,
            captureSource: .pointer(point),
            expectedProcessIdentifier: processIdentifier
        )
        switch pointerResult {
        case .target(let target):
            logger.info(
                "Resolved Agent target under pointer in \(target.applicationName, privacy: .public), role=\(target.role, privacy: .public)"
            )
            return pointerResult
        case .secureInput:
            logger.info("Pointer is over a secure Agent target; refusing write")
            return pointerResult
        case .accessibilityDenied, .fridayFocused, .noFocusedElement, .notEditable, .systemError:
            return focusedResult
        }
    }

    private func captureTarget(
        in application: NSRunningApplication?,
        fallbackApplicationName: String,
        includeSystemWideCandidate: Bool,
        includeUniqueEditableCandidate: Bool
    ) -> InputTargetResult {
        if application?.processIdentifier == ProcessInfo.processInfo.processIdentifier {
            return .fridayFocused
        }

        let lookup = focusedElementCandidates(
            application: application,
            includeSystemWideCandidate: includeSystemWideCandidate
        )
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
            if includeUniqueEditableCandidate {
                switch uniqueEditableDescendant(in: focusedWindow) {
                case .editable(let element):
                    return makeTarget(
                        from: element,
                        captureSource: .uniqueEditableControl
                    )
                case .secure:
                    return .secureInput
                case nil:
                    break
                }
            }
        }

        let applicationName = application?.localizedName ?? fallbackApplicationName
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

    private func captureTargetAtPointer() -> InputTargetResult {
        guard isTrusted else { return .accessibilityDenied }
        guard let point = CGEvent(source: nil)?.location else {
            return .noFocusedElement
        }
        return captureTarget(at: point, captureSource: .pointer(point))
    }

    private func makeTarget(
        from element: AXUIElement,
        captureSource: InputTargetCaptureSource = .keyboardFocus
    ) -> InputTargetResult {
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
        let identifier = stringAttribute(kAXIdentifierAttribute, from: element)
        logger.debug(
            "Resolved input target in \(applicationName, privacy: .public), role=\(role, privacy: .public)"
        )
        return .target(
            FocusedInputTarget(
                element: element,
                processIdentifier: processIdentifier,
                applicationName: applicationName,
                role: role,
                identifier: identifier,
                position: pointAttribute(kAXPositionAttribute, from: element),
                size: sizeAttribute(kAXSizeAttribute, from: element),
                captureSource: captureSource
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

        guard NSWorkspace.shared.frontmostApplication?.processIdentifier == target.processIdentifier else {
            logger.notice(
                "Refusing insertion because target app did not become frontmost; source=\(self.captureSourceLabel(target.captureSource), privacy: .public)"
            )
            return .focusChanged
        }

        let focusResult = AXUIElementSetAttributeValue(
            target.element,
            kAXFocusedAttribute as CFString,
            kCFBooleanTrue
        )

        try? await Task.sleep(for: .milliseconds(50))
        var focusObserved = isStillFocused(target)
        logger.debug(
            "AX focus restore result=\(focusResult.rawValue, privacy: .public), observed=\(focusObserved, privacy: .public), source=\(self.captureSourceLabel(target.captureSource), privacy: .public)"
        )

        if !focusObserved {
            switch await recoverPointerFocus(for: target) {
            case .recovered(let postClickFocusObserved):
                focusObserved = postClickFocusObserved
            case .targetChanged:
                return .focusChanged
            case .eventUnavailable:
                return .pasteEventUnavailable
            case .notApplicable:
                return focusResult == .success ? .focusChanged : .systemError(focusResult)
            }
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
            logger.info(
                "Paste verified in target; source=\(self.captureSourceLabel(target.captureSource), privacy: .public), focus_observed=\(focusObserved, privacy: .public)"
            )
            return .verified(.pasteboard)
        }
        logger.info(
            "Paste dispatched to validated target without readable value change; source=\(self.captureSourceLabel(target.captureSource), privacy: .public), focus_observed=\(focusObserved, privacy: .public)"
        )
        return .dispatched(.pasteboard)
    }

    private enum PointerFocusRecoveryResult {
        case recovered(postClickFocusObserved: Bool)
        case targetChanged
        case eventUnavailable
        case notApplicable
    }

    @MainActor
    private func recoverPointerFocus(
        for target: FocusedInputTarget
    ) async -> PointerFocusRecoveryResult {
        guard case .pointer = target.captureSource else {
            return .notApplicable
        }
        guard let pointer = CGEvent(source: nil)?.location else {
            logger.notice("Pointer focus recovery failed because pointer location is unavailable")
            return .targetChanged
        }

        let pointerResult = captureTarget(at: pointer, captureSource: .pointer(pointer))
        let pointerMatchesTarget: Bool
        if case .target(let currentTarget) = pointerResult {
            pointerMatchesTarget = matchesTarget(currentTarget.element, target)
        } else {
            pointerMatchesTarget = false
        }
        let frontmostProcessIdentifier = NSWorkspace.shared.frontmostApplication?.processIdentifier
        guard InputFocusRecoveryPolicy.allowsPointerClick(
            captureSource: target.captureSource,
            targetProcessIdentifier: target.processIdentifier,
            frontmostProcessIdentifier: frontmostProcessIdentifier,
            pointerStillMatchesTarget: pointerMatchesTarget
        ) else {
            logger.notice(
                "Pointer focus recovery refused; frontmost_matches=\(frontmostProcessIdentifier == target.processIdentifier, privacy: .public), pointer_matches=\(pointerMatchesTarget, privacy: .public)"
            )
            return .targetChanged
        }

        guard let source = CGEventSource(stateID: .hidSystemState),
              let mouseDown = CGEvent(
                mouseEventSource: source,
                mouseType: .leftMouseDown,
                mouseCursorPosition: pointer,
                mouseButton: .left
              ),
              let mouseUp = CGEvent(
                mouseEventSource: source,
                mouseType: .leftMouseUp,
                mouseCursorPosition: pointer,
                mouseButton: .left
              ) else {
            logger.error("Pointer focus recovery could not create mouse events")
            return .eventUnavailable
        }

        mouseDown.post(tap: .cghidEventTap)
        try? await Task.sleep(for: .milliseconds(24))
        mouseUp.post(tap: .cghidEventTap)
        try? await Task.sleep(for: .milliseconds(100))

        let postClickFocusObserved = isStillFocused(target)
        logger.info(
            "Pointer click dispatched to locked editable target; post_click_focus_observed=\(postClickFocusObserved, privacy: .public)"
        )
        return .recovered(postClickFocusObserved: postClickFocusObserved)
    }

    private func isStillFocused(_ target: FocusedInputTarget) -> Bool {
        if boolAttribute(kAXFocusedAttribute, from: target.element) == true {
            return true
        }

        let lookup = focusedElementCandidates(
            application: NSRunningApplication(processIdentifier: target.processIdentifier),
            includeSystemWideCandidate: true
        )
        for candidate in lookup.elements {
            if matchesTarget(candidate, target) {
                return true
            }
            if case .editable(let resolved)? = resolveEditableElement(startingAt: candidate),
               matchesTarget(resolved, target) {
                return true
            }
        }
        if let focusedWindow = lookup.focusedWindow,
           case .editable(let resolved)? = focusedEditableDescendant(in: focusedWindow),
           matchesTarget(resolved, target) {
            return true
        }
        return false
    }

    private func matchesTarget(_ candidate: AXUIElement, _ target: FocusedInputTarget) -> Bool {
        var processIdentifier: pid_t = 0
        guard AXUIElementGetPid(candidate, &processIdentifier) == .success,
              processIdentifier == target.processIdentifier else {
            return false
        }

        if CFEqual(candidate, target.element) {
            return true
        }

        if let targetIdentifier = target.identifier,
           !targetIdentifier.isEmpty,
           stringAttribute(kAXIdentifierAttribute, from: candidate) == targetIdentifier {
            return true
        }

        guard stringAttribute(kAXRoleAttribute, from: candidate) == target.role,
              let targetPosition = target.position,
              let targetSize = target.size,
              let candidatePosition = pointAttribute(kAXPositionAttribute, from: candidate),
              let candidateSize = sizeAttribute(kAXSizeAttribute, from: candidate) else {
            return false
        }

        return abs(targetPosition.x - candidatePosition.x) <= 8
            && abs(targetPosition.y - candidatePosition.y) <= 8
            && abs(targetSize.width - candidateSize.width) <= 12
            && abs(targetSize.height - candidateSize.height) <= 12
    }

    private func captureSourceLabel(_ source: InputTargetCaptureSource) -> String {
        switch source {
        case .keyboardFocus:
            return "keyboard_focus"
        case .uniqueEditableControl:
            return "unique_editable_control"
        case .pointer:
            return "pointer"
        }
    }

    private func focusedElementCandidates(
        application: NSRunningApplication?,
        includeSystemWideCandidate: Bool
    ) -> (
        elements: [AXUIElement],
        focusedWindow: AXUIElement?,
        systemResult: AXError,
        firstUnexpectedError: AXError?
    ) {
        var elements: [AXUIElement] = []
        var unexpectedErrors: [AXError] = []
        var focusedWindow: AXUIElement?
        var systemResult: AXError = .success

        if includeSystemWideCandidate {
            let systemLookup = elementAttribute(
                kAXFocusedUIElementAttribute,
                from: AXUIElementCreateSystemWide()
            )
            systemResult = systemLookup.result
            appendUnique(systemLookup.element, to: &elements)
            collectUnexpected(systemLookup.result, into: &unexpectedErrors)
        }

        if let application {
            let applicationElement = AXUIElementCreateApplication(application.processIdentifier)
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

        return (elements, focusedWindow, systemResult, unexpectedErrors.first)
    }

    private func pointAttribute(_ attribute: String, from element: AXUIElement) -> CGPoint? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success,
              let value,
              CFGetTypeID(value) == AXValueGetTypeID() else {
            return nil
        }

        let axValue = unsafeBitCast(value, to: AXValue.self)
        guard AXValueGetType(axValue) == .cgPoint else { return nil }
        var point = CGPoint.zero
        guard AXValueGetValue(axValue, .cgPoint, &point) else { return nil }
        return point
    }

    private func sizeAttribute(_ attribute: String, from element: AXUIElement) -> CGSize? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success,
              let value,
              CFGetTypeID(value) == AXValueGetTypeID() else {
            return nil
        }

        let axValue = unsafeBitCast(value, to: AXValue.self)
        guard AXValueGetType(axValue) == .cgSize else { return nil }
        var size = CGSize.zero
        guard AXValueGetValue(axValue, .cgSize, &size) else { return nil }
        return size
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

    // An explicit Agent application target may have lost keyboard focus while in the
    // background. Selecting is safe only when its front window exposes exactly one
    // enabled, non-password editable control.
    private func uniqueEditableDescendant(in root: AXUIElement) -> ResolvedElement? {
        var queue: [(element: AXUIElement, depth: Int)] = [(root, 0)]
        var index = 0
        var editableMatches: [AXUIElement] = []
        var foundSecureInput = false

        while index < queue.count, index < 320 {
            let item = queue[index]
            index += 1

            switch InputTargetClassifier.classify(profile(for: item.element)) {
            case .editable:
                appendUnique(item.element, to: &editableMatches)
            case .secure:
                foundSecureInput = true
            case .notEditable:
                break
            }

            guard item.depth < 12 else { continue }
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

    private func captureTarget(
        at point: CGPoint,
        captureSource: InputTargetCaptureSource,
        expectedProcessIdentifier: pid_t? = nil
    ) -> InputTargetResult {
        var element: AXUIElement?
        let result = AXUIElementCopyElementAtPosition(
            AXUIElementCreateSystemWide(),
            Float(point.x),
            Float(point.y),
            &element
        )
        guard result == .success, let element else {
            if result == .noValue || result == .attributeUnsupported {
                return .noFocusedElement
            }
            return .systemError(result)
        }

        if let expectedProcessIdentifier {
            var actualProcessIdentifier: pid_t = 0
            guard AXUIElementGetPid(element, &actualProcessIdentifier) == .success,
                  actualProcessIdentifier == expectedProcessIdentifier else {
                logger.notice("Pointer target does not belong to the requested application")
                return .notEditable
            }
        }

        switch resolveEditableElement(startingAt: element) {
        case .editable(let resolvedElement):
            return makeTarget(from: resolvedElement, captureSource: captureSource)
        case .secure:
            return .secureInput
        case nil:
            return .notEditable
        }
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
