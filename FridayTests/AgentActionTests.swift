// 功能：验证语音 Agent 的应用名称解析、应用启动、可撤销输入框动作执行和重复工具调用幂等性。
// 职责：使用纯本地替身覆盖 Codex 别名、后台应用激活、显式应用优先、会话目标兜底、失败回执和工具参数契约。
// 边界：不访问真实 Accessibility、麦克风、网络或 Realtime，不写入任何真实应用，也不产生模型费用。

import ApplicationServices
import XCTest
@testable import Friday

@MainActor
final class AgentActionTests: XCTestCase {
    func testPointerFocusRecoveryOnlyClicksValidatedTargetInFrontmostApp() {
        let source = InputTargetCaptureSource.pointer(CGPoint(x: 120, y: 240))

        XCTAssertTrue(
            InputFocusRecoveryPolicy.allowsPointerClick(
                captureSource: source,
                targetProcessIdentifier: 41,
                frontmostProcessIdentifier: 41,
                pointerStillMatchesTarget: true
            )
        )
        XCTAssertFalse(
            InputFocusRecoveryPolicy.allowsPointerClick(
                captureSource: source,
                targetProcessIdentifier: 41,
                frontmostProcessIdentifier: 42,
                pointerStillMatchesTarget: true
            )
        )
        XCTAssertFalse(
            InputFocusRecoveryPolicy.allowsPointerClick(
                captureSource: source,
                targetProcessIdentifier: 41,
                frontmostProcessIdentifier: 41,
                pointerStillMatchesTarget: false
            )
        )
        XCTAssertFalse(
            InputFocusRecoveryPolicy.allowsPointerClick(
                captureSource: .keyboardFocus,
                targetProcessIdentifier: 41,
                frontmostProcessIdentifier: 41,
                pointerStillMatchesTarget: true
            )
        )
    }

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

    func testChineseWeChatAliasResolvesRunningWeChatBundle() {
        let resolver = RunningApplicationResolver(candidateProvider: {
            [
                Self.candidate(
                    pid: 52,
                    name: "WeChat",
                    bundleIdentifier: "com.tencent.xinWeChat"
                )
            ]
        })

        XCTAssertEqual(
            resolver.resolve("微信"),
            .resolved(
                RunningApplicationReference(
                    processIdentifier: 52,
                    localizedName: "WeChat",
                    bundleIdentifier: "com.tencent.xinWeChat"
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

    func testNamedApplicationWriteActivatesAppBeforeCapturingInput() async {
        let textEdit = RunningApplicationReference(
            processIdentifier: 66,
            localizedName: "TextEdit",
            bundleIdentifier: "com.apple.TextEdit"
        )
        let target = Self.target(pid: 66, name: "TextEdit")
        let inputService = StubAccessibilityActionAccess(
            captureResult: .target(target),
            insertionResult: .verified(.pasteboard)
        )
        let resolver = StubRunningApplicationResolver(
            resolution: .notRunning("文本编辑"),
            activationResolution: .activated(textEdit, wasAlreadyRunning: false)
        )
        let executor = FocusedInputActionExecutor(
            inputService: inputService,
            applicationResolver: resolver
        )

        let receipt = await executor.execute(
            Self.proposal(applicationHint: "文本编辑")
        )

        XCTAssertEqual(receipt.status, .succeeded)
        XCTAssertEqual(resolver.activatedHints, ["文本编辑"])
        XCTAssertEqual(inputService.capturedProcessIdentifiers, [66])
        XCTAssertEqual(inputService.insertedProcessIdentifiers, [66])
    }

    func testOpenApplicationExecutesWithoutReadingAccessibility() async {
        let safari = RunningApplicationReference(
            processIdentifier: 67,
            localizedName: "Safari",
            bundleIdentifier: "com.apple.Safari"
        )
        let inputService = StubAccessibilityActionAccess(
            captureResult: .noFocusedElement,
            insertionResult: .targetUnavailable
        )
        let resolver = StubRunningApplicationResolver(
            resolution: .notRunning("Safari"),
            activationResolution: .activated(safari, wasAlreadyRunning: false)
        )
        let executor = FocusedInputActionExecutor(
            inputService: inputService,
            applicationResolver: resolver
        )

        let receipt = await executor.execute(Self.openProposal(application: "Safari"))

        XCTAssertEqual(receipt.status, .succeeded)
        XCTAssertEqual(resolver.activatedHints, ["Safari"])
        XCTAssertTrue(inputService.capturedProcessIdentifiers.isEmpty)
        XCTAssertTrue(inputService.insertedProcessIdentifiers.isEmpty)
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

    func testExplicitApplicationUsesActionTargetRecovery() async {
        let codexTarget = Self.target(pid: 63, name: "ChatGPT")
        let inputService = StubAccessibilityActionAccess(
            captureResult: .target(codexTarget),
            insertionResult: .verified(.pasteboard)
        )
        let executor = FocusedInputActionExecutor(
            inputService: inputService,
            applicationResolver: StubRunningApplicationResolver(
                resolution: .resolved(
                    RunningApplicationReference(
                        processIdentifier: 63,
                        localizedName: "ChatGPT",
                        bundleIdentifier: "com.openai.codex"
                    )
                )
            )
        )

        let receipt = await executor.execute(Self.proposal(applicationHint: "Codex"))

        XCTAssertEqual(receipt.status, .succeeded)
        XCTAssertEqual(inputService.capturedProcessIdentifiers, [63])
        XCTAssertEqual(inputService.insertedProcessIdentifiers, [63])
    }

    func testExplicitApplicationRecapturesCurrentTargetInsteadOfUsingSameAppLock() async {
        let earlierCodexTarget = Self.target(pid: 65, name: "ChatGPT")
        let currentCodexTarget = Self.target(pid: 65, name: "ChatGPT")
        let inputService = StubAccessibilityActionAccess(
            captureResult: .target(currentCodexTarget),
            insertionResult: .verified(.pasteboard)
        )
        let executor = FocusedInputActionExecutor(
            inputService: inputService,
            applicationResolver: StubRunningApplicationResolver(
                resolution: .resolved(
                    RunningApplicationReference(
                        processIdentifier: 65,
                        localizedName: "ChatGPT",
                        bundleIdentifier: "com.openai.codex"
                    )
                )
            )
        )
        executor.lockSessionTarget(earlierCodexTarget)

        let receipt = await executor.execute(Self.proposal(applicationHint: "Codex"))

        XCTAssertEqual(receipt.status, .succeeded)
        XCTAssertEqual(inputService.capturedProcessIdentifiers, [65])
        XCTAssertEqual(inputService.insertedProcessIdentifiers, [65])
    }

    func testMissingExplicitApplicationTargetReturnsRedactedFailureCode() async {
        let inputService = StubAccessibilityActionAccess(
            captureResult: .noFocusedElement,
            insertionResult: .verified(.pasteboard)
        )
        let executor = FocusedInputActionExecutor(
            inputService: inputService,
            applicationResolver: StubRunningApplicationResolver(
                resolution: .resolved(
                    RunningApplicationReference(
                        processIdentifier: 64,
                        localizedName: "ChatGPT",
                        bundleIdentifier: "com.openai.codex"
                    )
                )
            )
        )

        let receipt = await executor.execute(Self.proposal(applicationHint: "Codex"))

        XCTAssertEqual(receipt.status, .failed)
        XCTAssertEqual(receipt.errorCode, "target_not_focused")
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
        XCTAssertTrue(first.output.contains(#""accessibility_permission":"granted""#))
        XCTAssertEqual(executor.proposals.count, 1)
        XCTAssertEqual(executor.proposals.first?.target, "Codex")
        XCTAssertEqual(executor.proposals.first?.parameters["application_hint"], "Codex")
        XCTAssertEqual(executor.proposals.first?.risk, .reversibleLocalWrite)
        XCTAssertEqual(
            executor.proposals.first?.requiredPermission,
            ActionPermissionRequirement.none
        )
    }

    func testBridgeCreatesLowRiskOpenApplicationProposal() async throws {
        let executor = StubLocalActionExecutor()
        let bridge = ConversationActionBridge(executor: executor)
        bridge.beginConversationSession()
        let call = ConversationToolCall(
            callID: try XCTUnwrap(ConversationToolCallID("call_open_safari")),
            name: ConversationActionBridge.openApplicationToolName,
            argumentsJSON: #"{"application":"Safari"}"#,
            responseID: nil
        )

        let resolution = await bridge.resolve(call)

        XCTAssertTrue(resolution.output.contains(#""status":"succeeded""#))
        XCTAssertTrue(
            resolution.output.contains(#""accessibility_permission":"not_required""#)
        )
        XCTAssertTrue(resolution.output.contains("write_focused_input"))
        XCTAssertEqual(executor.proposals.count, 1)
        XCTAssertEqual(executor.proposals.first?.kind, "open_application")
        XCTAssertEqual(executor.proposals.first?.target, "Safari")
        XCTAssertEqual(executor.proposals.first?.risk, .localNavigation)
        XCTAssertEqual(
            executor.proposals.first?.requiredPermission,
            ActionPermissionRequirement.none
        )
    }

    func testBridgeReportsDeniedAccessibilityForWriteFailure() async throws {
        let application = RunningApplicationReference(
            processIdentifier: 68,
            localizedName: "WeChat",
            bundleIdentifier: "com.tencent.xinWeChat"
        )
        let inputService = StubAccessibilityActionAccess(
            isTrusted: false,
            captureResult: .accessibilityDenied,
            insertionResult: .targetUnavailable
        )
        let executor = FocusedInputActionExecutor(
            inputService: inputService,
            applicationResolver: StubRunningApplicationResolver(
                resolution: .resolved(application)
            )
        )
        let bridge = ConversationActionBridge(executor: executor)
        bridge.beginConversationSession()
        let call = ConversationToolCall(
            callID: try XCTUnwrap(ConversationToolCallID("call_write_wechat")),
            name: ConversationActionBridge.focusedInputWriteToolName,
            argumentsJSON: #"{"text":"你好","application":"微信"}"#,
            responseID: nil
        )

        let resolution = await bridge.resolve(call)

        XCTAssertTrue(resolution.output.contains(#""status":"failed""#))
        XCTAssertTrue(resolution.output.contains(#""error_code":"accessibility_denied""#))
        XCTAssertTrue(resolution.output.contains(#""accessibility_permission":"denied""#))
        XCTAssertEqual(
            diagnosticToolAccessibilityPermission(from: resolution.output),
            "denied"
        )
    }

    func testActivationFailureKeepsSpecificStageCode() async {
        let executor = FocusedInputActionExecutor(
            inputService: StubAccessibilityActionAccess(
                captureResult: .noFocusedElement,
                insertionResult: .targetUnavailable
            ),
            applicationResolver: StubRunningApplicationResolver(
                resolution: .notRunning("微信"),
                activationResolution: .failed("微信", .frontmostTimeout)
            )
        )

        let receipt = await executor.execute(Self.openProposal(application: "微信"))

        XCTAssertEqual(receipt.status, .failed)
        XCTAssertEqual(receipt.errorCode, "application_frontmost_timeout")
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

    private static func openProposal(application: String) -> ActionProposal {
        ActionProposal(
            id: .make(),
            workID: WorkID("work_bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb")!,
            kind: ConversationActionBridge.openApplicationToolName,
            target: application,
            parameters: ["application": application],
            preview: "打开 \(application)",
            risk: .localNavigation,
            reversibility: .reversible,
            requiredPermission: .none
        )
    }
}

@MainActor
private final class StubRunningApplicationResolver: RunningApplicationResolving {
    private let resolution: RunningApplicationResolution
    private let activationResolution: ApplicationActivationResolution?
    private(set) var activatedHints: [String] = []

    init(
        resolution: RunningApplicationResolution,
        activationResolution: ApplicationActivationResolution? = nil
    ) {
        self.resolution = resolution
        self.activationResolution = activationResolution
    }

    func resolve(_ applicationHint: String) -> RunningApplicationResolution {
        resolution
    }

    func activate(_ applicationHint: String) async -> ApplicationActivationResolution {
        activatedHints.append(applicationHint)
        if let activationResolution {
            return activationResolution
        }
        switch resolution {
        case .resolved(let application):
            return .activated(application, wasAlreadyRunning: true)
        case .notRunning:
            return .notFound(applicationHint)
        case .ambiguous:
            return .ambiguous(applicationHint)
        }
    }
}

@MainActor
private final class StubAccessibilityActionAccess: AccessibilityActionAccessing {
    let isTrusted: Bool
    private let captureResult: InputTargetResult
    private let insertionResult: TextInsertionResult
    private(set) var capturedProcessIdentifiers: [pid_t] = []
    private(set) var insertedProcessIdentifiers: [pid_t] = []

    init(
        isTrusted: Bool = true,
        captureResult: InputTargetResult,
        insertionResult: TextInsertionResult
    ) {
        self.isTrusted = isTrusted
        self.captureResult = captureResult
        self.insertionResult = insertionResult
    }

    func captureActionTarget(
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
    let accessibilityPermissionGranted: Bool? = true
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
