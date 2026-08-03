// 功能：验证语音 Agent 的输入框写入提议必须经过视觉确认并产生结构化本地回执。
// 职责：覆盖一次性 Permission 绑定、允许与拒绝、重复工具调用、无目标、目标 revision 失效和未知执行结果。
// 边界：不连接 Realtime、不请求 Accessibility 权限、不操作真实输入框，也不记录或发送用户正文。

import ApplicationServices
import XCTest
@testable import Friday

@MainActor
final class AgentActionTests: XCTestCase {
    func testBridgeExecutesExactlyOnceAfterVisualPermission() async {
        let executor = StubLocalActionExecutor(status: .succeeded)
        let bridge = ConversationActionBridge(executor: executor)
        bridge.beginConversationSession()
        var permissionWasPresented = false
        bridge.onPermissionRequest = { request in
            permissionWasPresented = true
            XCTAssertEqual(executor.executionCount, 0)
            XCTAssertTrue(
                bridge.respond(
                    permissionID: request.id,
                    actionID: request.proposal.id,
                    allow: true
                )
            )
        }

        let call = writeCall(id: "call-write-once", text: "明天下午三点开会")
        let first = await bridge.resolve(call)
        let duplicate = await bridge.resolve(call)

        XCTAssertTrue(permissionWasPresented)
        XCTAssertEqual(executor.executionCount, 1)
        XCTAssertEqual(first.output, duplicate.output)
        XCTAssertTrue(first.output.contains(#""status":"succeeded""#))
        XCTAssertFalse(first.output.contains("明天下午三点开会"))
    }

    func testBridgeRejectsPermissionWithoutExecuting() async {
        let executor = StubLocalActionExecutor(status: .succeeded)
        let bridge = ConversationActionBridge(executor: executor)
        bridge.beginConversationSession()
        bridge.onPermissionRequest = { request in
            XCTAssertTrue(
                bridge.respond(
                    permissionID: request.id,
                    actionID: request.proposal.id,
                    allow: false
                )
            )
        }

        let result = await bridge.resolve(
            writeCall(id: "call-reject", text: "不要写入这段内容")
        )

        XCTAssertEqual(executor.executionCount, 0)
        XCTAssertTrue(result.output.contains(#""status":"rejected_by_user""#))
    }

    func testBridgeWithoutLockedTargetNeverPresentsPermission() async {
        let executor = StubLocalActionExecutor(status: .succeeded, hasTarget: false)
        let bridge = ConversationActionBridge(executor: executor)
        bridge.beginConversationSession()
        var permissionWasPresented = false
        bridge.onPermissionRequest = { _ in permissionWasPresented = true }

        let result = await bridge.resolve(
            writeCall(id: "call-no-target", text: "无法定位目标")
        )

        XCTAssertFalse(permissionWasPresented)
        XCTAssertEqual(executor.executionCount, 0)
        XCTAssertTrue(result.output.contains(#""status":"target_unavailable""#))
    }

    func testPermissionCannotBeCrossBoundOrConsumedTwice() async throws {
        let runtime = ActionPermissionRuntime()
        let proposal = makeProposal(text: "一次性确认")
        var permissionID: ActionPermissionID?
        var wrongActionWasAccepted = true

        let decision = try await runtime.requestPermission(for: proposal) { request in
            permissionID = request.id
            wrongActionWasAccepted = runtime.respond(
                permissionID: request.id,
                actionID: .make(),
                decision: .allowOnce
            )
            XCTAssertTrue(
                runtime.respond(
                    permissionID: request.id,
                    actionID: proposal.id,
                    decision: .allowOnce
                )
            )
        }

        XCTAssertFalse(wrongActionWasAccepted)
        XCTAssertEqual(decision, .allowOnce)
        XCTAssertFalse(
            runtime.respond(
                permissionID: permissionID!,
                actionID: proposal.id,
                decision: .allowOnce
            )
        )
    }

    func testExecutorRejectsAChangedTargetRevision() async {
        let inserter = StubAccessibilityTextInserter(result: .verified(.pasteboard))
        let executor = FocusedInputActionExecutor(inputService: inserter)
        executor.lockSessionTarget(makeFocusedTarget())
        var proposal = makeProposal(
            text: "不能写到新目标",
            target: executor.focusedInputTarget!
        )
        proposal = ActionProposal(
            id: proposal.id,
            workID: proposal.workID,
            kind: proposal.kind,
            target: ActionTargetDescriptor(
                revision: "target_changed",
                applicationName: proposal.target.applicationName,
                role: proposal.target.role
            ),
            parameters: proposal.parameters,
            preview: proposal.preview,
            risk: proposal.risk,
            reversibility: proposal.reversibility,
            requiredPermission: proposal.requiredPermission
        )

        let receipt = await executor.execute(proposal)

        XCTAssertEqual(receipt.status, .failed)
        XCTAssertEqual(inserter.insertCount, 0)
        XCTAssertNil(receipt.undoToken)
    }

    func testExecutorReturnsUnknownWhenTheTargetCannotExposeAResult() async {
        let inserter = StubAccessibilityTextInserter(result: .dispatched(.pasteboard))
        let executor = FocusedInputActionExecutor(inputService: inserter)
        executor.lockSessionTarget(makeFocusedTarget())
        let proposal = makeProposal(
            text: "已发送但无法复验",
            target: executor.focusedInputTarget!
        )

        let receipt = await executor.execute(proposal)

        XCTAssertEqual(receipt.status, .unknown)
        XCTAssertEqual(inserter.insertCount, 1)
        XCTAssertNotNil(receipt.undoToken)
    }

    func testPendingVisualPermissionKeepsTalkConnectedUntilDecision() async {
        let provider = MockConversationProvider()
        let executor = StubLocalActionExecutor(status: .succeeded)
        let bridge = ConversationActionBridge(executor: executor)
        var pendingRequest: ActionPermissionRequest?
        bridge.onPermissionRequest = { request in
            pendingRequest = request
        }
        let coordinator = ConversationCoordinator(
            activationMode: .shortcut,
            wakeWordProvider: MockWakeWordService(),
            conversationProvider: provider,
            audioService: ActionTestAudioService(),
            presentation: InputOverlayConversationPresenter(
                model: InputOverlayModel(),
                controller: nil
            ),
            actionBridge: bridge
        )

        coordinator.startConversationFromShortcut()
        await waitUntil { provider.isConnected }
        let responseID = ConversationProviderResponseID("response_action_permission")
        provider.simulate(.assistantResponseStarted(responseID: responseID))
        provider.simulate(
            .toolCall(
                ConversationToolCall(
                    callID: ConversationToolCallID("call_action_permission")!,
                    name: ConversationActionBridge.focusedInputWriteToolName,
                    argumentsJSON: #"{"text":"确认后写入"}"#,
                    responseID: responseID
                )
            )
        )
        provider.simulate(
            .responseCompleted(responseID: responseID, usage: .zero)
        )
        await waitUntil { pendingRequest != nil }

        XCTAssertTrue(provider.isConnected)
        XCTAssertTrue(coordinator.isConversationActive)
        XCTAssertTrue(provider.toolOutputs.isEmpty)
        XCTAssertEqual(executor.executionCount, 0)

        let request = pendingRequest!
        XCTAssertTrue(
            bridge.respond(
                permissionID: request.id,
                actionID: request.proposal.id,
                allow: true
            )
        )
        await waitUntil { provider.toolOutputs.count == 1 }

        XCTAssertEqual(executor.executionCount, 1)
        XCTAssertTrue(provider.toolOutputs[0].createsResponse)
        XCTAssertTrue(provider.isConnected)
        XCTAssertTrue(coordinator.isConversationActive)
        coordinator.stop()
    }

    func testActionDecisionDuringUserSpeechAvoidsConcurrentFollowUp() async {
        let provider = MockConversationProvider()
        let executor = StubLocalActionExecutor(status: .succeeded)
        let bridge = ConversationActionBridge(executor: executor)
        var pendingRequest: ActionPermissionRequest?
        bridge.onPermissionRequest = { request in
            pendingRequest = request
        }
        let coordinator = ConversationCoordinator(
            activationMode: .shortcut,
            wakeWordProvider: MockWakeWordService(),
            conversationProvider: provider,
            audioService: ActionTestAudioService(),
            presentation: InputOverlayConversationPresenter(
                model: InputOverlayModel(),
                controller: nil
            ),
            actionBridge: bridge,
            userTurnResponseGrace: .milliseconds(20)
        )

        coordinator.startConversationFromShortcut()
        await waitUntil { provider.isConnected }
        let actionResponseID = ConversationProviderResponseID(
            "response_action_then_user"
        )
        provider.simulate(.assistantResponseStarted(responseID: actionResponseID))
        provider.simulate(
            .toolCall(
                ConversationToolCall(
                    callID: ConversationToolCallID("call_action_then_user")!,
                    name: ConversationActionBridge.focusedInputWriteToolName,
                    argumentsJSON: #"{"text":"用户继续说话时写入"}"#,
                    responseID: actionResponseID
                )
            )
        )
        provider.simulate(
            .responseCompleted(responseID: actionResponseID, usage: .zero)
        )
        await waitUntil { pendingRequest != nil }

        let userItemID = ConversationProviderItemID("user_during_action_permission")!
        provider.simulate(.userSpeechStarted(itemID: userItemID))
        let request = pendingRequest!
        XCTAssertTrue(
            bridge.respond(
                permissionID: request.id,
                actionID: request.proposal.id,
                allow: true
            )
        )
        await waitUntil { provider.toolOutputs.count == 1 }

        XCTAssertFalse(provider.toolOutputs[0].createsResponse)
        XCTAssertEqual(executor.executionCount, 1)
        XCTAssertTrue(provider.isConnected)
        XCTAssertEqual(coordinator.state, .userSpeaking)

        provider.simulate(.userSpeechStopped(itemID: userItemID))
        await waitUntil { provider.userResponseRequestCount == 1 }
        XCTAssertTrue(coordinator.isConversationActive)
        coordinator.stop()
    }

    private func writeCall(id: String, text: String) -> ConversationToolCall {
        let data = try! JSONSerialization.data(withJSONObject: ["text": text])
        return ConversationToolCall(
            callID: ConversationToolCallID(id)!,
            name: ConversationActionBridge.focusedInputWriteToolName,
            argumentsJSON: String(data: data, encoding: .utf8)!,
            responseID: nil
        )
    }

    private func makeProposal(
        text: String,
        target: ActionTargetDescriptor = ActionTargetDescriptor(
            revision: "target_11111111111111111111111111111111",
            applicationName: "TextEdit",
            role: "AXTextArea"
        )
    ) -> ActionProposal {
        ActionProposal(
            id: .make(),
            workID: .make(),
            kind: .writeFocusedInput,
            target: target,
            parameters: FocusedInputWriteParameters(text: text),
            preview: text,
            risk: .reversibleLocalWrite,
            reversibility: .systemUndo,
            requiredPermission: .allowOnce
        )
    }

    private func makeFocusedTarget() -> FocusedInputTarget {
        FocusedInputTarget(
            element: AXUIElementCreateSystemWide(),
            processIdentifier: 123,
            applicationName: "TextEdit",
            role: "AXTextArea"
        )
    }

    private func waitUntil(
        _ condition: @escaping @MainActor () -> Bool
    ) async {
        for _ in 0..<200 {
            if condition() { return }
            try? await Task.sleep(for: .milliseconds(10))
        }
    }
}

@MainActor
private final class StubLocalActionExecutor: LocalActionExecuting {
    private(set) var executionCount = 0
    var focusedInputTarget: ActionTargetDescriptor?
    private let status: ActionReceiptStatus

    init(status: ActionReceiptStatus, hasTarget: Bool = true) {
        self.status = status
        focusedInputTarget = hasTarget
            ? ActionTargetDescriptor(
                revision: "target_22222222222222222222222222222222",
                applicationName: "TextEdit",
                role: "AXTextArea"
            )
            : nil
    }

    func execute(_ proposal: ActionProposal) async -> ActionReceipt {
        executionCount += 1
        return ActionReceipt(
            id: .make(),
            workID: proposal.workID,
            actionID: proposal.id,
            status: status,
            targetRevision: proposal.target.revision,
            observedResult: "测试回执",
            undoToken: status == .succeeded ? "system_undo:test" : nil,
            executedAt: Date(),
            error: status == .failed ? "测试失败" : nil
        )
    }

    func clearSessionTarget() {
        focusedInputTarget = nil
    }
}

@MainActor
private final class StubAccessibilityTextInserter: AccessibilityTextInserting {
    private(set) var insertCount = 0
    private let result: TextInsertionResult

    init(result: TextInsertionResult) {
        self.result = result
    }

    func insert(_ text: String, into target: FocusedInputTarget) async -> TextInsertionResult {
        insertCount += 1
        return result
    }
}

@MainActor
private final class ActionTestAudioService: ConversationAudioServicing {
    var onInputChunk: ((AudioChunk) -> Void)?
    var onInputLevels: ((ConversationAudioLevels) -> Void)?
    var onInputGateTransition: ((ConversationInputGateTransition) -> Void)?
    var onOutputLevels: ((ConversationAudioLevels) -> Void)?
    var onPlaybackFinished: (() -> Void)?
    var onFailure: ((Error) -> Void)?
    private(set) var isRunning = false
    var hasConfirmedInterruption = false

    func start() async throws { isRunning = true }
    func prepareForAssistantResponse() {}
    func beginAssistantResponse() {}
    func enqueueAssistantAudio(_ data: Data) {}
    func markAssistantAudioFinished() {}
    func stopAssistantPlayback() -> Int { 0 }
    func stop() { isRunning = false }
}
