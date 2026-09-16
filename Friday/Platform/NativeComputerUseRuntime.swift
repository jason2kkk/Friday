// 功能：为首个 Computer Use 纵向任务提供原生 macOS 观察、键盘动作、TextEdit 保存和文件读回。
// 职责：把 AppKit、LaunchServices、CGEvent、AppleScript 和 FileManager 适配到中立 Runtime，并在每一步返回结构化证据。
// 边界：只允许本地、可撤销的 TextEdit 烟囱任务；不执行 Shell、网络、发送、删除或任意应用脚本，不替代后续通用 Planner。

import AppKit
import Foundation

@MainActor
final class NativeComputerUseRuntime: ComputerUseRuntime {
    private let applicationResolver: any RunningApplicationResolving
    private let inputDriver: any ComputerUseInputDriving
    private let fileManager: FileManager
    private var isCancelled = false

    init(
        applicationResolver: (any RunningApplicationResolving)? = nil,
        inputDriver: (any ComputerUseInputDriving)? = nil,
        fileManager: FileManager = .default
    ) {
        self.applicationResolver = applicationResolver ?? RunningApplicationResolver()
        self.inputDriver = inputDriver ?? CGEventComputerUseInputDriver()
        self.fileManager = fileManager
    }

    func begin() {
        isCancelled = false
    }

    func observe(targetPath: URL?) async -> ComputerUseObservation {
        let frontmost = NSWorkspace.shared.frontmostApplication
        let runningNames = NSWorkspace.shared.runningApplications
            .compactMap(\.localizedName)
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
        return ComputerUseObservation(
            focusedApplication: frontmost?.localizedName,
            focusedProcessIdentifier: frontmost?.processIdentifier,
            runningApplications: runningNames,
            targetPathExists: targetPath.map {
                fileManager.fileExists(atPath: $0.path)
            },
            note: "仅读取应用列表、前台应用和目标文件存在性"
        )
    }

    func perform(_ action: ComputerUseAction) async -> ComputerUseActionReceipt {
        let actionID = "cu_\(UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased())"
        guard !isCancelled else {
            return receipt(
                actionID: actionID,
                action: action,
                effect: .refused,
                observedResult: "任务已取消，没有发送后续动作。",
                errorCode: "cancelled"
            )
        }

        switch action {
        case .launchApplication(let applicationHint):
            switch await applicationResolver.activate(applicationHint) {
            case .activated(let application, _):
                return receipt(
                    actionID: actionID,
                    action: action,
                    effect: .confirmed,
                    observedResult: "\(application.localizedName) 已位于前台。",
                    errorCode: nil
                )
            case .notFound, .ambiguous:
                return receipt(
                    actionID: actionID,
                    action: action,
                    effect: .refused,
                    observedResult: "没有找到唯一的目标应用。",
                    errorCode: "application_not_found"
                )
            case .failed:
                return receipt(
                    actionID: actionID,
                    action: action,
                    effect: .unverifiable,
                    observedResult: "应用启动请求已发出，但没有确认它位于前台。",
                    errorCode: "application_activation_unknown"
                )
            }

        case .typeText(let text):
            guard !text.isEmpty, inputDriver.typeText(text) else {
                return receipt(
                    actionID: actionID,
                    action: action,
                    effect: .refused,
                    observedResult: "系统没有接受文字输入事件。",
                    errorCode: "type_text_failed"
                )
            }
            return receipt(
                actionID: actionID,
                action: action,
                effect: .unverifiable,
                observedResult: "文字输入事件已发送，最终结果仍需文件读回。",
                errorCode: nil
            )

        case .hotkey(let keys):
            guard !keys.isEmpty, inputDriver.sendHotKey(keys) else {
                return receipt(
                    actionID: actionID,
                    action: action,
                    effect: .refused,
                    observedResult: "系统没有接受快捷键事件。",
                    errorCode: "hotkey_failed"
                )
            }
            try? await Task.sleep(for: .milliseconds(250))
            return receipt(
                actionID: actionID,
                action: action,
                effect: .unverifiable,
                observedResult: "快捷键事件已发送，最终结果仍需文件读回。",
                errorCode: nil
            )

        case .saveDocument(let application, let path):
            return saveTextEditDocument(
                application: application,
                path: path,
                actionID: actionID
            )
        }
    }

    func verify(_ expectation: ComputerUseExpectation) async -> ComputerUseVerification {
        guard !isCancelled else {
            return ComputerUseVerification(
                status: .unknown,
                evidence: "验证前任务已取消。",
                errorCode: "cancelled"
            )
        }

        switch expectation {
        case .fileContent(let path, let exactContent):
            guard fileManager.fileExists(atPath: path) else {
                return ComputerUseVerification(
                    status: .unsatisfied,
                    evidence: "目标文件不存在。",
                    errorCode: "file_not_found"
                )
            }
            do {
                let actualContent = try String(contentsOfFile: path, encoding: .utf8)
                guard actualContent == exactContent else {
                    return ComputerUseVerification(
                        status: .unsatisfied,
                        evidence: "目标文件已读回，但内容不完全一致。",
                        errorCode: "file_content_mismatch"
                    )
                }
                return ComputerUseVerification(
                    status: .satisfied,
                    evidence: "文件存在且 UTF-8 内容精确匹配。",
                    errorCode: nil
                )
            } catch {
                return ComputerUseVerification(
                    status: .unknown,
                    evidence: "目标文件存在，但无法以 UTF-8 读回。",
                    errorCode: "file_read_failed"
                )
            }
        }
    }

    func cancel() {
        isCancelled = true
    }

    private func saveTextEditDocument(
        application: String,
        path: String,
        actionID: String
    ) -> ComputerUseActionReceipt {
        guard RunningApplicationResolver.normalize(application) == "textedit" else {
            return receipt(
                actionID: actionID,
                action: .saveDocument(application: application, path: path),
                effect: .refused,
                observedResult: "首个烟囱任务只允许保存 TextEdit 文档。",
                errorCode: "unsupported_document_app"
            )
        }

        let outputURL = URL(fileURLWithPath: path).standardizedFileURL
        let allowedDirectory = TextEditSmokeTask.makeDefault(fileManager: fileManager)
            .outputURL
            .deletingLastPathComponent()
            .standardizedFileURL
        guard outputURL.path.hasPrefix(allowedDirectory.path + "/") else {
            return receipt(
                actionID: actionID,
                action: .saveDocument(application: application, path: path),
                effect: .refused,
                observedResult: "保存路径不在 Olli 的本地烟囱测试目录内。",
                errorCode: "path_outside_smoke_directory"
            )
        }

        do {
            try fileManager.createDirectory(
                at: allowedDirectory,
                withIntermediateDirectories: true
            )
        } catch {
            return receipt(
                actionID: actionID,
                action: .saveDocument(application: application, path: path),
                effect: .refused,
                observedResult: "无法创建任务测试目录。",
                errorCode: "directory_create_failed"
            )
        }

        guard !fileManager.fileExists(atPath: outputURL.path) else {
            return receipt(
                actionID: actionID,
                action: .saveDocument(application: application, path: path),
                effect: .refused,
                observedResult: "目标文件已存在，拒绝覆盖。",
                errorCode: "file_already_exists"
            )
        }

        let script = """
        tell application "TextEdit"
            activate
            if (count of documents) is 0 then make new document
            set targetDocument to front document
            save targetDocument in POSIX file \(appleScriptString(outputURL.path)) as "text"
            return "saved"
        end tell
        """
        var errorInfo: NSDictionary?
        guard let result = NSAppleScript(source: script)?
            .executeAndReturnError(&errorInfo),
              result.stringValue == "saved" else {
            return receipt(
                actionID: actionID,
                action: .saveDocument(application: application, path: path),
                effect: .unverifiable,
                observedResult: "TextEdit 保存请求失败或 Automation 权限尚未完成。",
                errorCode: "textedit_save_unknown"
            )
        }

        return receipt(
            actionID: actionID,
            action: .saveDocument(application: application, path: path),
            effect: .confirmed,
            observedResult: "TextEdit 已返回保存成功，下一步仍需读回文件内容。",
            errorCode: nil
        )
    }

    private func appleScriptString(_ value: String) -> String {
        "\"" + value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n") + "\""
    }

    private func receipt(
        actionID: String,
        action: ComputerUseAction,
        effect: ComputerUseActionEffect,
        observedResult: String,
        errorCode: String?
    ) -> ComputerUseActionReceipt {
        ComputerUseActionReceipt(
            actionID: actionID,
            capability: action.capability,
            effect: effect,
            observedResult: observedResult,
            errorCode: errorCode
        )
    }
}

private extension ComputerUseAction {
    var capability: ComputerUseCapabilityKind {
        switch self {
        case .launchApplication: return .launchApplication
        case .typeText: return .typeText
        case .hotkey: return .hotkey
        case .saveDocument: return .saveDocument
        }
    }
}

@MainActor
protocol ComputerUseInputDriving: AnyObject {
    func typeText(_ text: String) -> Bool
    func sendHotKey(_ keys: [String]) -> Bool
}

@MainActor
final class CGEventComputerUseInputDriver: ComputerUseInputDriving {
    private let keyCodes: [String: CGKeyCode] = [
        "a": 0x00, "n": 0x2D, "s": 0x01,
        "command": 0x37, "shift": 0x38, "option": 0x3A,
        "control": 0x3B, "return": 0x24, "escape": 0x35
    ]
    private let modifierFlags: [String: CGEventFlags] = [
        "command": .maskCommand,
        "shift": .maskShift,
        "option": .maskAlternate,
        "control": .maskControl
    ]

    func typeText(_ text: String) -> Bool {
        guard !text.isEmpty,
              let source = CGEventSource(stateID: .hidSystemState),
              let keyDown = CGEvent(
                  keyboardEventSource: source,
                  virtualKey: 0,
                  keyDown: true
              ),
              let keyUp = CGEvent(
                  keyboardEventSource: source,
                  virtualKey: 0,
                  keyDown: false
              ) else { return false }
        var utf16 = Array(text.utf16)
        keyDown.keyboardSetUnicodeString(
            stringLength: utf16.count,
            unicodeString: &utf16
        )
        keyUp.keyboardSetUnicodeString(
            stringLength: utf16.count,
            unicodeString: &utf16
        )
        keyDown.post(tap: .cghidEventTap)
        keyUp.post(tap: .cghidEventTap)
        return true
    }

    func sendHotKey(_ keys: [String]) -> Bool {
        let normalized = keys.map { $0.lowercased() }
        guard let mainKey = normalized.last,
              let mainKeyCode = keyCodes[mainKey],
              let source = CGEventSource(stateID: .hidSystemState) else { return false }

        let modifierNames = Set(normalized.dropLast())
        let flags = modifierNames.compactMap { modifierFlags[$0] }
        guard flags.count == modifierNames.count else { return false }
        guard let keyDown = CGEvent(
            keyboardEventSource: source,
            virtualKey: mainKeyCode,
            keyDown: true
        ), let keyUp = CGEvent(
            keyboardEventSource: source,
            virtualKey: mainKeyCode,
            keyDown: false
        ) else { return false }
        let combinedFlags = flags.reduce(into: CGEventFlags()) { result, flag in
            result.insert(flag)
        }
        keyDown.flags = combinedFlags
        keyUp.flags = combinedFlags
        keyDown.post(tap: .cghidEventTap)
        keyUp.post(tap: .cghidEventTap)
        return true
    }
}
