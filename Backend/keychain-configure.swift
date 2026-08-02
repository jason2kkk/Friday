// 功能：为本地开发安全配置完整的 OpenAI API Key，并将其保存到 macOS 钥匙串。
// 职责：通过终端隐藏输入或原生安全对话框读取 Secret，完成格式校验后新增或更新指定钥匙串项。
// 边界：不回显、记录或联网发送 Secret，也不参与 Friday App 运行时和 Realtime 会话。

import Darwin
import AppKit
import Foundation
import Security

enum KeychainConfigurationError: LocalizedError {
    case invalidArguments
    case inputFailed
    case valuesDoNotMatch
    case invalidFormat
    case keychain(OSStatus)

    var errorDescription: String? {
        switch self {
        case .invalidArguments:
            return "Keychain account and service are required."
        case .inputFailed:
            return "API Key input was cancelled or could not be read."
        case .valuesDoNotMatch:
            return "The two API Key entries did not match."
        case .invalidFormat:
            return "The API Key format is invalid."
        case let .keychain(status):
            let message = SecCopyErrorMessageString(status, nil) as String?
            return message ?? "Keychain returned status \(status)."
        }
    }
}

func readSecret(prompt: String) throws -> String {
    var buffer = [CChar](repeating: 0, count: 4_096)
    defer {
        _ = buffer.withUnsafeMutableBytes { bytes in
            bytes.initializeMemory(as: UInt8.self, repeating: 0)
        }
    }

    let result = prompt.withCString { promptPointer in
        readpassphrase(promptPointer, &buffer, buffer.count, 0)
    }
    guard result != nil else {
        throw KeychainConfigurationError.inputFailed
    }
    return String(cString: buffer)
}

func saveSecret(_ secret: String, account: String, service: String) throws {
    let query: [CFString: Any] = [
        kSecClass: kSecClassGenericPassword,
        kSecAttrAccount: account,
        kSecAttrService: service
    ]
    let valueData = Data(secret.utf8)
    let attributes: [CFString: Any] = [
        kSecValueData: valueData,
        kSecAttrLabel: "Friday OpenAI API Key",
        kSecAttrComment: "Friday local Realtime session service"
    ]

    let updateStatus = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
    if updateStatus == errSecSuccess {
        return
    }
    guard updateStatus == errSecItemNotFound else {
        throw KeychainConfigurationError.keychain(updateStatus)
    }

    let newItem = query.merging(attributes) { _, newValue in newValue }
    let addStatus = SecItemAdd(newItem as CFDictionary, nil)
    guard addStatus == errSecSuccess else {
        throw KeychainConfigurationError.keychain(addStatus)
    }
}

@MainActor
func readSecretsFromDialog() throws -> (String, String) {
    let application = NSApplication.shared
    application.setActivationPolicy(.accessory)
    installEditMenu(on: application)
    application.activate()

    let apiKeyField = NSSecureTextField(frame: NSRect(x: 0, y: 44, width: 440, height: 24))
    apiKeyField.placeholderString = "sk-proj-..."
    apiKeyField.setAccessibilityLabel("OpenAI API Key")
    apiKeyField.menu = makePasteMenu()

    let confirmationField = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 440, height: 24))
    confirmationField.placeholderString = "再次输入完整 Key"
    confirmationField.setAccessibilityLabel("确认 OpenAI API Key")
    confirmationField.menu = makePasteMenu()

    let accessoryView = NSView(frame: NSRect(x: 0, y: 0, width: 440, height: 68))
    accessoryView.addSubview(apiKeyField)
    accessoryView.addSubview(confirmationField)

    let alert = NSAlert()
    alert.alertStyle = .informational
    alert.messageText = "配置 Friday 语音服务"
    alert.informativeText = "输入完整 OpenAI Project Secret。Key 只会保存在本机钥匙串中。"
    alert.accessoryView = accessoryView
    alert.addButton(withTitle: "保存并验证")
    alert.addButton(withTitle: "取消")
    alert.window.initialFirstResponder = apiKeyField

    guard alert.runModal() == .alertFirstButtonReturn else {
        throw KeychainConfigurationError.inputFailed
    }
    return (apiKeyField.stringValue, confirmationField.stringValue)
}

@MainActor
func installEditMenu(on application: NSApplication) {
    let mainMenu = NSMenu()
    let editMenuItem = NSMenuItem()
    let editMenu = NSMenu(title: "编辑")

    let pasteItem = NSMenuItem(
        title: "粘贴",
        action: #selector(NSText.paste(_:)),
        keyEquivalent: "v"
    )
    pasteItem.keyEquivalentModifierMask = [.command]
    editMenu.addItem(pasteItem)

    let selectAllItem = NSMenuItem(
        title: "全选",
        action: #selector(NSText.selectAll(_:)),
        keyEquivalent: "a"
    )
    selectAllItem.keyEquivalentModifierMask = [.command]
    editMenu.addItem(selectAllItem)

    editMenuItem.submenu = editMenu
    mainMenu.addItem(editMenuItem)
    application.mainMenu = mainMenu
}

@MainActor
func makePasteMenu() -> NSMenu {
    let menu = NSMenu()
    menu.addItem(
        NSMenuItem(
            title: "粘贴",
            action: #selector(NSText.paste(_:)),
            keyEquivalent: ""
        )
    )
    return menu
}

do {
    guard CommandLine.arguments.count == 4,
          ["store", "store-gui"].contains(CommandLine.arguments[1]) else {
        throw KeychainConfigurationError.invalidArguments
    }
    let account = CommandLine.arguments[2]
    let service = CommandLine.arguments[3]
    let apiKey: String
    let confirmation: String
    if CommandLine.arguments[1] == "store-gui" {
        (apiKey, confirmation) = try MainActor.assumeIsolated {
            try readSecretsFromDialog()
        }
    } else {
        apiKey = try readSecret(prompt: "OpenAI API Key: ")
        confirmation = try readSecret(prompt: "Retype OpenAI API Key: ")
    }
    guard apiKey == confirmation else {
        throw KeychainConfigurationError.valuesDoNotMatch
    }
    guard apiKey.hasPrefix("sk-"), apiKey.count >= 20,
          !apiKey.contains(where: { $0.isWhitespace }) else {
        throw KeychainConfigurationError.invalidFormat
    }
    try saveSecret(apiKey, account: account, service: service)
} catch {
    let message = (error as? LocalizedError)?.errorDescription ?? String(describing: error)
    FileHandle.standardError.write(Data("\(message)\n".utf8))
    exit(1)
}
