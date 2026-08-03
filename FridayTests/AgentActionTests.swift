// 功能：验证语音 Agent 的应用名称解析、可撤销输入框动作执行和重复工具调用幂等性。
// 职责：使用纯本地替身覆盖 Codex 别名、显式应用优先、会话目标兜底、失败回执和工具参数契约。
// 边界：不访问真实 Accessibility、麦克风、网络或 Realtime，不写入任何真实应用，也不产生模型费用。

import ApplicationServices
import XCTest
@testable import Friday

@MainActor
final class AgentActionTests: XCTestCase {
    func testCodexAliasResolvesInstalledChatGPTBundle() {
        let resolver = RunningApplicationResolver(candidateProvider: {
            [
                Self.candidate(
                    pid: 41,
                    name: "ChatGPT",
                    bundleIdentifier: "com.openai.codex"
                ),
                Self.candidate(
                    pid: 42,
                    name: "Xcode",
                    bundleIdentifier: "com.apple.dt.Xcode"
                )
            ]
        })

        XCTAssertEqual(
            resolver.resolve("Codex"),
            .resolved(
                RunningApplicationReference(
                    processIdentifier: 41,
                    localizedName: "ChatGPT",
                    bundleIdentifier: "com.openai.codex"
                )
            )
        )
    }

    func testGenericInstalledApplicationNameResolvesWithoutHardcodedAlias() {
        let resolver = RunningApplicationResolver(candidateProvider: {
            [Self.candidate(pid: 51, name: "Linear", bundleIdentifier: "com.linear")]
        })

        XCTAssertEqual(
            resolver.resolve("Linear 应用"),
            .resolved(
                RunningApplicationReference(
                    processIdentifier: 51,
                    localizedName: "Linear",
                    bundleIdentifier: "com.linear"
                )
            )
        )
    }

    func testExplicitApplicationTargetOverridesDifferentSessionTarget() async {
        let lockedTarget = Self.target(pid: 61, name: "TextEdit")
        let codexTarget = Self.target(pid: 62, name: "ChatGPT")
        let inputService = StubAccessibilityActionAccess(
            captureResult: .target(codexTarget),
            insertionResult: .verified(.pasteboard)
        )
        let resolver = StubRunningApplicationResolver(
            resolution: .resolved(
                RunningApplicationReference(
                    processIdentifier: 62,
                    localizedName: "ChatGPT",
                    bundleIdentifier: "com.openai.codex"
                )
            )
        )
        let executor = FocusedInputActionExecutor(
            inputService: inputService,
            applicationResolver: resolver
        )
        executor.lockSessionTarget(lockedTarget)

        let receipt = await executor.execute(Self.proposal(applicationHint: "Codex"))

        XCTAssertEqual(receipt.status, .succeeded)
        XCTAssertEqual(inputService.capturedProcessIdentifiers, [62])
        XCTAssertEqual(inputService.insertedProcessIdentifiers, [62])
        XCTAssertNotNil(receipt.undoToken)
    }

    func testSessionTargetRemainsFallbackWhenApplicationWasNotSpecified() async {
        let lockedTarget = Self.target(pid: 71, name: "TextEdit")
        let inputService = StubAccessibilityActionAccess(
            captureResult: .noFocusedElement,
            insertionResult: .verified(.pasteboard)
        )
        let executor = FocusedInputActionExecutor(
            inputService: inputService,
            applicationResolver: StubRunningApplicationResolver(
                resolution: .notRunning("unused")
            )
        )
        executor.lockSessionTarget(lockedTarget)

        let receipt = await executor.execute(Self.proposal(applicationHint: nil))

        XCTAssertEqual(receipt.status, .succeeded)
        XCTAssertTrue(inputService.capturedProcessIdentifiers.isEmpty)
        XCTAssertEqual(inputService.insertedProcessIdentifiers, [71])
    }

    func testUnknownApplicationFailsWithoutWritingElsewhere() async {
        let inputService = StubAccessibilityActionAccess(
            captureResult: .noFocusedElement,
            insertionResult: .verified(.pasteboard)
        )
        let executor = FocusedInputActionExecutor(
            inputService: inputService,
            applicationResolver: StubRunningApplicationResolver(
                resolution: .notRunning("Unknown")
            )
        )

        let receipt = await executor.execute(Self.proposal(applicationHint: "Unknown"))

        XCTAssertEqual(receipt.status, .failed)
        XCTAssertTrue(inputService.capturedProcessIdentifiers.isEmpty)
        XCTAssertTrue(inputService.insertedProcessIdentifiers.isEmpty)
    }

    func testDispatchedPasteReturnsUnknownInsteadOfClaimingSuccess() async {
        let target = Self.target(pid: 81, name: "TextEdit")
        let inputService = StubAccessibilityActionAccess(
            captureResult: .noFocusedElement,
            insertionResult: .dispatched(.pasteboard)
        )
        let executor = FocusedInputActionExecutor(
            inputService: inputService,
            applicationResolver: StubRunningApplicationResolver(
                resolution: .notRunning("unused")
            )
        )
        executor.lockSessionTarget(target)

        let receipt = await executor.execute(Self.proposal(applicationHint: nil))

        XCTAssertEqual(receipt.status, .unknown)
        XCTAssertNotNil(receipt.undoToken)
        XCTAssertEqual(inputService.insertedProcessIdentifiers, [81])
    }

    func testBridgePreservesApplicationHintAndDoesNotExecuteDuplicateToolCall() async {
        let executor = StubLocalActionExecutor()
        let bridge = ConversationActionBridge(executor: executor)
        bridge.beginConversationSession()
        let call = ConversationToolCall(
            callID: ConversationToolCallID("call_write_codex")!,
            name: ConversationActionBridge.focusedInputWriteToolName,
            argumentsJSON: #"{"text":"1、2、3、4","application":"Codex"}"#,
            responseID: nil
        )

        let first = await bridge.resolve(call)
        let duplicate = await bridge.resolve(call)

        XCTAssertEqual(first.output, duplicate.output)
        XCTAssertTrue(first.output.contains(#""status":"succeeded""#))
        XCTAssertEqual(executor.proposals.count, 1)
        XCTAssertEqual(executor.proposals.first?.target, "Codex")
        XCTAssertEqual(executor.proposals.first?.parameters["application_hint"], "Codex")
        XCTAssertEqual(executor.proposals.first?.risk, .reversibleLocalWrite)
        XCTAssertEqual(
            executor.proposals.first?.requiredPermission,
            ActionPermissionRequirement.none
        )
    }

    private static func candidate(
        pid: pid_t,
        name: String,
        bundleIdentifier: String
    ) -> RunningApplicationResolver.Candidate {
        RunningApplicationResolver.Candidate(
            reference: RunningApplicationReference(
                processIdentifier: pid,
                localizedName: name,
                bundleIdentifier: bundleIdentifier
            ),
            searchableNames: [name, bundleIdentifier]
        )
    }

    private static func target(pid: pid_t, name: String) -> FocusedInputTarget {
        FocusedInputTarget(
            element: AXUIElementCreateApplication(pid),
            processIdentifier: pid,
            applicationName: name,
            role: "AXTextArea"
        )
    }

    private static func proposal(applicationHint: String?) -> ActionProposal {
        ActionProposal(
            id: .make(),
            workID: WorkID("work_aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa")!,
            kind: ConversationActionBridge.focusedInputWriteToolName,
            target: applicationHint ?? "session_input",
            parameters: [
                "text": "1、2、3、4",
                "application_hint": applicationHint ?? ""
            ],
            preview: "测试写入",
            risk: .reversibleLocalWrite,
            reversibility: .reversible,
            requiredPermission: .none
        )
    }
}

@MainActor
private final class StubRunningApplicationResolver: RunningApplicationResolving {
    private let resolution: RunningApplicationResolution

    init(resolution: RunningApplicationResolution) {
        self.resolution = resolution
    }

    func resolve(_ applicationHint: String) -> RunningApplicationResolution {
        resolution
    }
}

@MainActor
private final class StubAccessibilityActionAccess: AccessibilityActionAccessing {
    private let captureResult: InputTargetResult
    private let insertionResult: TextInsertionResult
    private(set) var capturedProcessIdentifiers: [pid_t] = []
    private(set) var insertedProcessIdentifiers: [pid_t] = []

    init(captureResult: InputTargetResult, insertionResult: TextInsertionResult) {
        self.captureResult = captureResult
        self.insertionResult = insertionResult
    }

    func captureFocusedTarget(
        processIdentifier: pid_t,
        applicationName: String
    ) -> InputTargetResult {
        capturedProcessIdentifiers.append(processIdentifier)
        return captureResult
    }

    func insert(_ text: String, into target: FocusedInputTarget) async -> TextInsertionResult {
        insertedProcessIdentifiers.append(target.processIdentifier)
        return insertionResult
    }
}

@MainActor
private final class StubLocalActionExecutor: LocalActionExecuting {
    private(set) var proposals: [ActionProposal] = []

    func lockSessionTarget(_ target: FocusedInputTarget?) {}

    func execute(_ proposal: ActionProposal) async -> ActionReceipt {
        proposals.append(proposal)
        return ActionReceipt(
            id: .make(),
            workID: proposal.workID,
            actionID: proposal.id,
            status: .succeeded,
            targetRevision: "target_test",
            observedResult: "测试写入已复验",
            undoToken: "system_undo:test",
            executedAt: Date(),
            error: nil
        )
    }

    func clearSessionTarget() {}
}
