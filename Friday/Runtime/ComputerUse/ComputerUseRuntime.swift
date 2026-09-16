// 功能：定义 Olli Computer Use 的中立观察、动作、验证和固定任务契约。
// 职责：把 Observe -> Plan -> Act -> Verify 的状态、能力目录和 TextEdit 烟囱任务与具体 macOS API 解耦。
// 边界：不访问 AppKit、Accessibility、Realtime 或文件系统；不把动作发送成功当作任务完成证据。

import Foundation

enum ComputerUseCapabilityKind: String, Codable, Equatable, Sendable {
    case observeApplications = "observe_applications"
    case observeWindow = "observe_window"
    case launchApplication = "launch_application"
    case typeText = "type_text"
    case hotkey
    case saveDocument = "save_document"
    case verifyFileContent = "verify_file_content"
}

struct ComputerUseCapability: Codable, Equatable, Sendable, Identifiable {
    let id: String
    let kind: ComputerUseCapabilityKind
    let summary: String
    let risk: ActionRisk
    let requiresAccessibility: Bool
    let requiresScreenRecording: Bool
}

enum ComputerUseCapabilityRegistry {
    static let smokeTaskCapabilities: [ComputerUseCapability] = [
        ComputerUseCapability(
            id: "observe.applications",
            kind: .observeApplications,
            summary: "读取运行中的应用名称和进程身份",
            risk: .readOnly,
            requiresAccessibility: false,
            requiresScreenRecording: false
        ),
        ComputerUseCapability(
            id: "app.launch",
            kind: .launchApplication,
            summary: "启动或激活用户明确指定的应用",
            risk: .localNavigation,
            requiresAccessibility: false,
            requiresScreenRecording: false
        ),
        ComputerUseCapability(
            id: "keyboard.type_text",
            kind: .typeText,
            summary: "向当前已确认的前台窗口输入可撤销文字",
            risk: .reversibleLocalWrite,
            requiresAccessibility: true,
            requiresScreenRecording: false
        ),
        ComputerUseCapability(
            id: "keyboard.hotkey",
            kind: .hotkey,
            summary: "向当前已确认的前台窗口发送快捷键",
            risk: .reversibleLocalWrite,
            requiresAccessibility: true,
            requiresScreenRecording: false
        ),
        ComputerUseCapability(
            id: "document.save",
            kind: .saveDocument,
            summary: "将已创建的本地文档保存到任务目录",
            risk: .reversibleLocalWrite,
            requiresAccessibility: false,
            requiresScreenRecording: false
        ),
        ComputerUseCapability(
            id: "verify.file_content",
            kind: .verifyFileContent,
            summary: "读取指定文件并精确比较内容",
            risk: .readOnly,
            requiresAccessibility: false,
            requiresScreenRecording: false
        )
    ]
}

struct ComputerUseObservation: Equatable, Sendable {
    let focusedApplication: String?
    let focusedProcessIdentifier: Int32?
    let runningApplications: [String]
    let targetPathExists: Bool?
    let note: String
}

enum ComputerUseAction: Equatable, Sendable {
    case launchApplication(String)
    case typeText(String)
    case hotkey([String])
    case saveDocument(application: String, path: String)
}

enum ComputerUseActionEffect: String, Equatable, Sendable {
    case confirmed
    case partial
    case unverifiable
    case suspectedNoop = "suspected_noop"
    case refused
}

struct ComputerUseActionReceipt: Equatable, Sendable {
    let actionID: String
    let capability: ComputerUseCapabilityKind
    let effect: ComputerUseActionEffect
    let observedResult: String
    let errorCode: String?
}

enum ComputerUseVerificationStatus: String, Equatable, Sendable {
    case satisfied
    case unsatisfied
    case unknown
}

enum ComputerUseExpectation: Equatable, Sendable {
    case fileContent(path: String, exactContent: String)
}

struct ComputerUseVerification: Equatable, Sendable {
    let status: ComputerUseVerificationStatus
    let evidence: String
    let errorCode: String?
}

@MainActor
protocol ComputerUseRuntime: AnyObject {
    func begin()
    func observe(targetPath: URL?) async -> ComputerUseObservation
    func perform(_ action: ComputerUseAction) async -> ComputerUseActionReceipt
    func verify(_ expectation: ComputerUseExpectation) async -> ComputerUseVerification
    func cancel()
}

enum ComputerUseTaskState: Equatable, Sendable {
    case idle
    case running(step: String)
    case succeeded(path: String)
    case failed(message: String)
    case cancelled

    var userFacingText: String {
        switch self {
        case .idle:
            return "等待任务"
        case .running(let step):
            return step
        case .succeeded(let path):
            return "已完成并验证：\(path)"
        case .failed(let message):
            return message
        case .cancelled:
            return "任务已取消"
        }
    }
}

struct TextEditSmokeTask: Equatable, Sendable {
    let content: String
    let outputURL: URL

    static func makeDefault(fileManager: FileManager = .default) -> TextEditSmokeTask {
        let supportDirectory = fileManager.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first ?? fileManager.temporaryDirectory
        let outputDirectory = supportDirectory
            .appendingPathComponent("Friday", isDirectory: true)
            .appendingPathComponent("AgentSmokeTests", isDirectory: true)
        return TextEditSmokeTask(
            content: "Friday agent smoke test",
            outputURL: outputDirectory.appendingPathComponent("textedit-smoke.txt")
        )
    }
}

struct ComputerUseTaskResult: Equatable, Sendable {
    let state: ComputerUseTaskState
    let observations: [ComputerUseObservation]
    let actionReceipts: [ComputerUseActionReceipt]
    let verification: ComputerUseVerification?
}

@MainActor
protocol ComputerUseTaskRunning: AnyObject {
    func run(_ task: TextEditSmokeTask) async -> ComputerUseTaskResult
    func cancel()
}

@MainActor
final class TextEditSmokeTaskRunner: ComputerUseTaskRunning {
    private let runtime: any ComputerUseRuntime
    private var isCancelled = false
    private var observations: [ComputerUseObservation] = []
    private var actionReceipts: [ComputerUseActionReceipt] = []
    var onStateChange: ((ComputerUseTaskState) -> Void)?

    init(runtime: any ComputerUseRuntime) {
        self.runtime = runtime
    }

    func run(_ task: TextEditSmokeTask) async -> ComputerUseTaskResult {
        isCancelled = false
        runtime.begin()
        observations.removeAll(keepingCapacity: true)
        actionReceipts.removeAll(keepingCapacity: true)
        let fileManager = FileManager.default

        guard !fileManager.fileExists(atPath: task.outputURL.path) else {
            return finish(.failed(message: "测试文件已存在，请先删除后再运行。"))
        }

        update(.running(step: "观察桌面状态"))
        let initialObservation = await runtime.observe(targetPath: task.outputURL)
        observations.append(initialObservation)
        guard initialObservation.targetPathExists != true else {
            return finish(.failed(message: "目标文件已存在，已停止以避免覆盖。"))
        }
        guard !isCancelled else { return finish(.cancelled) }

        let steps: [(ComputerUseTaskState, ComputerUseAction)] = [
            (.running(step: "打开 TextEdit"), .launchApplication("TextEdit")),
            (.running(step: "新建文档"), .hotkey(["command", "n"])),
            (.running(step: "写入测试内容"), .typeText(task.content)),
            (
                .running(step: "保存到测试目录"),
                .saveDocument(application: "TextEdit", path: task.outputURL.path)
            )
        ]

        for (state, action) in steps {
            guard !isCancelled else { return finish(.cancelled) }
            update(state)
            let receipt = await runtime.perform(action)
            actionReceipts.append(receipt)
            let followUpObservation = await runtime.observe(targetPath: task.outputURL)
            observations.append(followUpObservation)
            guard receipt.effect != .refused,
                  receipt.effect != .suspectedNoop else {
                let message = "任务在“\(state.userFacingText)”步骤停止：\(receipt.observedResult)"
                return finish(.failed(message: message))
            }
        }

        guard !isCancelled else { return finish(.cancelled) }
        update(.running(step: "读回文件内容"))
        let verification = await runtime.verify(
            .fileContent(path: task.outputURL.path, exactContent: task.content)
        )
        guard verification.status == .satisfied else {
            return finish(
                .failed(message: "文件没有通过精确读回验证，未报告任务完成。"),
                verification: verification
            )
        }

        return finish(
            .succeeded(path: task.outputURL.path),
            verification: verification
        )
    }

    func cancel() {
        isCancelled = true
        runtime.cancel()
    }

    private func update(_ state: ComputerUseTaskState) {
        onStateChange?(state)
    }

    private func finish(
        _ state: ComputerUseTaskState,
        verification: ComputerUseVerification? = nil
    ) -> ComputerUseTaskResult {
        update(state)
        return ComputerUseTaskResult(
            state: state,
            observations: observations,
            actionReceipts: actionReceipts,
            verification: verification
        )
    }
}
