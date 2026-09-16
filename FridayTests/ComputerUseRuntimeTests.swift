// 功能：验证首个 Computer Use 中立契约、固定 TextEdit 执行循环、取消和最终读回门槛。
// 职责：使用纯内存 Runtime 覆盖能力注册、逐步重观察、不可验证动作、拒绝、unknown 和成功终态。
// 边界：不启动 TextEdit、不发送键盘事件、不读写用户文件、不访问网络，也不产生模型费用。

import XCTest
@testable import Friday

@MainActor
final class ComputerUseRuntimeTests: XCTestCase {
    func testCapabilityRegistryUsesUniqueStableIdentifiers() {
        let capabilities = ComputerUseCapabilityRegistry.smokeTaskCapabilities

        XCTAssertEqual(Set(capabilities.map(\.id)).count, capabilities.count)
        XCTAssertTrue(capabilities.contains { $0.kind == .launchApplication })
        XCTAssertTrue(capabilities.contains { $0.kind == .typeText })
        XCTAssertTrue(capabilities.contains { $0.kind == .hotkey })
        XCTAssertTrue(capabilities.contains { $0.kind == .verifyFileContent })
        XCTAssertFalse(capabilities.contains { $0.requiresScreenRecording })
    }

    func testSmokeTaskCompletesOnlyAfterSatisfiedFileVerification() async {
        let runtime = StubComputerUseRuntime(
            actionEffect: .unverifiable,
            verification: ComputerUseVerification(
                status: .satisfied,
                evidence: "exact readback",
                errorCode: nil
            )
        )
        let runner = TextEditSmokeTaskRunner(runtime: runtime)

        let result = await runner.run(makeTask())

        guard case .succeeded = result.state else {
            return XCTFail("Expected verified task success")
        }
        XCTAssertEqual(result.actionReceipts.count, 4)
        XCTAssertEqual(result.observations.count, 5)
        XCTAssertEqual(result.verification?.status, .satisfied)
        XCTAssertEqual(runtime.performedActions.count, 4)
    }

    func testUnknownFileVerificationNeverBecomesSuccess() async {
        let runtime = StubComputerUseRuntime(
            actionEffect: .confirmed,
            verification: ComputerUseVerification(
                status: .unknown,
                evidence: "readback unavailable",
                errorCode: "file_read_failed"
            )
        )
        let runner = TextEditSmokeTaskRunner(runtime: runtime)

        let result = await runner.run(makeTask())

        guard case .failed(let message) = result.state else {
            return XCTFail("Expected unknown verification to fail the task")
        }
        XCTAssertTrue(message.contains("未报告任务完成"))
        XCTAssertEqual(result.verification?.status, .unknown)
    }

    func testRefusedActionStopsRemainingSteps() async {
        let runtime = StubComputerUseRuntime(
            actionEffect: .refused,
            verification: ComputerUseVerification(
                status: .satisfied,
                evidence: "unused",
                errorCode: nil
            )
        )
        let runner = TextEditSmokeTaskRunner(runtime: runtime)

        let result = await runner.run(makeTask())

        guard case .failed = result.state else {
            return XCTFail("Expected refused action to fail the task")
        }
        XCTAssertEqual(runtime.performedActions.count, 1)
        XCTAssertNil(result.verification)
    }

    func testCancellationStopsBeforeSecondAction() async {
        let runtime = StubComputerUseRuntime(
            actionEffect: .confirmed,
            verification: ComputerUseVerification(
                status: .satisfied,
                evidence: "unused",
                errorCode: nil
            ),
            actionDelay: .milliseconds(100)
        )
        let runner = TextEditSmokeTaskRunner(runtime: runtime)
        let execution = Task { await runner.run(makeTask()) }

        try? await Task.sleep(for: .milliseconds(20))
        runner.cancel()
        let result = await execution.value

        XCTAssertEqual(result.state, .cancelled)
        XCTAssertEqual(runtime.cancelCount, 1)
        XCTAssertLessThanOrEqual(runtime.performedActions.count, 1)
    }

    private func makeTask() -> TextEditSmokeTask {
        TextEditSmokeTask(
            content: "Friday agent smoke test",
            outputURL: FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString)
                .appendingPathExtension("txt")
        )
    }
}

@MainActor
private final class StubComputerUseRuntime: ComputerUseRuntime {
    let actionEffect: ComputerUseActionEffect
    let verificationResult: ComputerUseVerification
    let actionDelay: Duration?
    private(set) var performedActions: [ComputerUseAction] = []
    private(set) var cancelCount = 0

    init(
        actionEffect: ComputerUseActionEffect,
        verification: ComputerUseVerification,
        actionDelay: Duration? = nil
    ) {
        self.actionEffect = actionEffect
        verificationResult = verification
        self.actionDelay = actionDelay
    }

    func begin() {}

    func observe(targetPath: URL?) async -> ComputerUseObservation {
        ComputerUseObservation(
            focusedApplication: "TextEdit",
            focusedProcessIdentifier: 42,
            runningApplications: ["TextEdit"],
            targetPathExists: false,
            note: "stub"
        )
    }

    func perform(_ action: ComputerUseAction) async -> ComputerUseActionReceipt {
        performedActions.append(action)
        if let actionDelay {
            try? await Task.sleep(for: actionDelay)
        }
        return ComputerUseActionReceipt(
            actionID: "cu_test_\(performedActions.count)",
            capability: capability(for: action),
            effect: actionEffect,
            observedResult: "stub",
            errorCode: actionEffect == .refused ? "refused" : nil
        )
    }

    func verify(_ expectation: ComputerUseExpectation) async -> ComputerUseVerification {
        verificationResult
    }

    func cancel() {
        cancelCount += 1
    }

    private func capability(for action: ComputerUseAction) -> ComputerUseCapabilityKind {
        switch action {
        case .launchApplication: return .launchApplication
        case .typeText: return .typeText
        case .hotkey: return .hotkey
        case .saveDocument: return .saveDocument
        }
    }
}
