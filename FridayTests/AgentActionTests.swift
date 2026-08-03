// 功能：验证语音 Agent 的明确输入框写入请求会自动执行，同时保持目标、幂等和 Talk 并发边界。
// 职责：覆盖自动写入、重复工具调用、单动作串行、无目标、目标 revision 失效、未知回执和对话结果回传。
// 边界：不连接 Realtime、不请求 Accessibility 权限、不操作真实输入框，也不记录或发送用户正文。

import ApplicationServices
import XCTest
@testable import Friday

@MainActor
final class AgentActionTests: XCTestCase {
    func testBridgeAutomaticallyExecutesAndDeduplicatesCompletedCall() async {
        let executor = StubLocalActionExecutor(status: .succeeded)
        let bridge = ConversationActionBridge(executor: executor)
        bridge.beginConversationSession()
        var observedReceipt: ActionReceipt?
        bridge.onResolution = { _, receipt in
            observedReceipt = receipt
        }
        let call = writeCall(id: "call-auto-write", text: "直接写入")

        let first = await bridge.resolve(call)
        let duplicate = await bridge.resolve(call)

        XCTAssertEqual(executor.executionCount, 1)
        XCTAssertEqual(first.output, duplicate.output)
        XCTAssertTrue(first.output.contains(#""status":"succeeded""#))
        XCTAssertEqual(observedReceipt?.status, .succeeded)
    }

    func testBridgeAllowsOnlyOneAutomaticWriteAtATime() async {
        let executor = BlockingLocalActionExecutor()
        let bridge = ConversationActionBridge(executor: executor)
        bridge.beginConversationSession()

        let firstTask = Task {
            await bridge.resolve(writeCall(id: "call-blocking", text: "第一项"))
        }
        await waitUntil { executor.executionCount == 1 }

        let second = await bridge.resolve(
            writeCall(id: "call-concurrent", text: "第二项")
        )

        XCTAssertEqual(executor.executionCount, 1)
        XCTAssertTrue(second.output.contains(#""status":"busy""#))

        executor.release()
        let first = await firstTask.value
        XCTAssertTrue(first.output.contains(#""status":"succeeded""#))
    }

    func testBridgeWithoutLockedTargetNeverExecutes() async {
        let executor = StubLocalActionExecutor(status: .succeeded, hasTarget: false)
        let bridge = ConversationActionBridge(executor: executor)
        bridge.beginConversationSession()

        let result = await bridge.resolve(
            writeCall(id: "call-no-target", text: "无法定位目标")
        )

        XCTAssertEqual(executor.executionCount, 0)
        XCTAssertTrue(result.output.contains(#""status":"target_unavailable""#))
    }

    func testBridgeRejectsEmptyTextWithoutExecuting() async {
        let executor = StubLocalActionExecutor(status: .succeeded)
        let bridge = ConversationActionBridge(executor: executor)
        bridge.beginConversationSession()

        let result = await bridge.resolve(
            writeCall(id: "call-empty-text", text: "   \n")
        )

        XCTAssertEqual(executor.executionCount, 0)
        XCTAssertTrue(result.output.contains(#""status":"rejected""#))
    }

    func testExecutorRejectsAChangedTargetRevision() async {
        let inserter = StubAccessibilityTextInserter(result: .verified(.pasteboard))
        let executor = FocusedInputActionExecutor(inputService: inserter)
        executor.lockSessionTarget(makeFocusedTarget())
        let original = makeProposal(
            text: "不能写到新目标",
            target: executor.focusedInputTarget!
        )
        let changed = ActionProposal(
            id: original.id,
            workID: original.workID,
            kind: original.kind,
            target: ActionTargetDescriptor(
                revision: "target_changed",
                applicationName: original.target.applicationName,
                role: original.target.role
            ),
            parameters: original.parameters,
            risk: original.risk,
            reversibility: original.reversibility,
            executionPolicy: original.executionPolicy
        )

        let receipt = await executor.execute(changed)

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

    func testAutomaticWriteKeepsTalkConnectedAndReturnsOneToolResult() async {
        let provider = MockConversationProvider()
        let executor = StubLocalActionExecutor(status: .succeeded)
        let bridge = ConversationActionBridge(executor: executor)
        let coordinator = makeCoordinator(
            provider: provider,
            bridge: bridge
        )

        coordinator.startConversationFromShortcut()
        await waitUntil { provider.isConnected }
        let responseID = ConversationProviderResponseID("response_auto_action")
        provider.simulate(.assistantResponseStarted(responseID: responseID))
        provider.simulate(
            .toolCall(
                ConversationToolCall(
                    callID: ConversationToolCallID("call_auto_action")!,
                    name: ConversationActionBridge.focusedInputWriteToolName,
                    argumentsJSON: #"{"text":"无需确认直接写入"}"#,
                    responseID: responseID
                )
            )
        )
        provider.simulate(
            .responseCompleted(responseID: responseID, usage: .zero)
        )
        await waitUntil { provider.toolOutputs.count == 1 }

        XCTAssertEqual(executor.executionCount, 1)
        XCTAssertTrue(provider.toolOutputs[0].createsResponse)
        XCTAssertTrue(provider.isConnected)
        XCTAssertTrue(coordinator.isConversationActive)
        coordinator.stop()
    }

    func testAutomaticWriteDuringUserSpeechAvoidsConcurrentFollowUp() async {
        let provider = MockConversationProvider()
        let executor = StubLocalActionExecutor(status: .succeeded)
        let bridge = ConversationActionBridge(executor: executor)
        let coordinator = makeCoordinator(
            provider: provider,
            bridge: bridge,
            userTurnResponseGrace: .milliseconds(20)
        )

        coordinator.startConversationFromShortcut()
        await waitUntil { provider.isConnected }
        let userItemID = ConversationProviderItemID("user_during_auto_action")!
        provider.simulate(.userSpeechStarted(itemID: userItemID))
        provider.simulate(
            .toolCall(
                ConversationToolCall(
                    callID: ConversationToolCallID("call_during_user_speech")!,
                    name: ConversationActionBridge.focusedInputWriteToolName,
                    argumentsJSON: #"{"text":"说话期间自动写入"}"#,
                    responseID: nil
                )
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

    private func makeCoordinator(
        provider: MockConversationProvider,
        bridge: ConversationActionBridge,
        userTurnResponseGrace: Duration = .milliseconds(450)
    ) -> ConversationCoordinator {
        ConversationCoordinator(
            activationMode: .shortcut,
            wakeWordProvider: MockWakeWordService(),
            conversationProvider: provider,
            audioService: ActionTestAudioService(),
            presentation: InputOverlayConversationPresenter(
                model: InputOverlayModel(),
                controller: nil
            ),
            actionBridge: bridge,
            userTurnResponseGrace: userTurnResponseGrace
        )
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
            risk: .reversibleLocalWrite,
            reversibility: .systemUndo,
            executionPolicy: .automaticWhenTargetLocked
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
        return makeReceipt(for: proposal, status: status)
    }

    func clearSessionTarget() {
        focusedInputTarget = nil
    }
}

@MainActor
private final class BlockingLocalActionExecutor: LocalActionExecuting {
    private(set) var executionCount = 0
    var focusedInputTarget: ActionTargetDescriptor? = ActionTargetDescriptor(
        revision: "target_33333333333333333333333333333333",
        applicationName: "TextEdit",
        role: "AXTextArea"
    )
    private var continuation: CheckedContinuation<Void, Never>?

    func execute(_ proposal: ActionProposal) async -> ActionReceipt {
        executionCount += 1
        await withCheckedContinuation { continuation in
            self.continuation = continuation
        }
        return makeReceipt(for: proposal, status: .succeeded)
    }

    func release() {
        continuation?.resume()
        continuation = nil
    }

    func clearSessionTarget() {
        focusedInputTarget = nil
    }
}

private func makeReceipt(
    for proposal: ActionProposal,
    status: ActionReceiptStatus
) -> ActionReceipt {
    ActionReceipt(
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
