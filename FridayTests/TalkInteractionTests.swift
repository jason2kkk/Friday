// 功能：验证 Talk 会话身份、展示映射、音频打断和区域框选等高风险交互边界。
// 职责：覆盖会话账本、响应循环保护、迟到事件隔离、回声尾音、屏幕指引布局和图片上下文 ID 等纯逻辑。
// 边界：不启动真实音频设备，不请求屏幕权限，不连接 Realtime 服务，也不产生付费模型响应。

import XCTest
@testable import Friday

@MainActor
final class TalkInteractionTests: XCTestCase {
    func testConversationPresenterOwnsIslandStateAndWaveformMapping() {
        let model = InputOverlayModel()
        let presenter = InputOverlayConversationPresenter(
            model: model,
            controller: nil
        )
        model.audioLevel = 0.8
        model.isVoiceActive = true
        model.waveformLevels = Array(repeating: 0.8, count: AudioChunk.waveformLevelCount)

        presenter.show(expression: .observing, source: .idle)

        XCTAssertEqual(
            model.phase,
            .conversation(expression: .observing, source: .idle)
        )
        XCTAssertEqual(model.audioLevel, 0)
        XCTAssertFalse(model.isVoiceActive)
        XCTAssertEqual(model.waveformLevels, InputOverlayModel.silentWaveformLevels)

        let levels = ConversationAudioLevels(
            level: 0.72,
            waveformLevels: [0.2, 0.4, 0.6, 0.8, 0.7, 0.5, 0.3, 0.1]
        )
        presenter.updateWaveform(levels, source: .assistant)

        XCTAssertEqual(
            model.phase,
            .conversation(expression: .speaking, source: .assistant)
        )
        XCTAssertEqual(model.audioLevel, levels.level)
        XCTAssertTrue(model.isVoiceActive)
        XCTAssertEqual(model.waveformLevels, levels.waveformLevels)
    }

    func testBargeInGateSuppressesEchoButKeepsRealInterruption() {
        var gate = AssistantBargeInGate()
        gate.beginAssistantOutput()

        let echoOutputs = (0..<3).flatMap { _ in
            gate.inputForRealtime(audioChunk(level: 0.28))
        }
        XCTAssertTrue(echoOutputs.isEmpty)

        let firstNearbySpeech = gate.inputForRealtime(audioChunk(level: 0.60))
        let confirmedNearbySpeech = gate.inputForRealtime(audioChunk(level: 0.60))

        XCTAssertTrue(firstNearbySpeech.isEmpty)
        XCTAssertGreaterThan(confirmedNearbySpeech.count, 1)
        XCTAssertTrue(gate.hasDetectedNearbySpeech)
        XCTAssertEqual(gate.inputForRealtime(audioChunk(level: 0.52)).count, 1)
    }

    func testBargeInGateSuppressesPlaybackEchoTail() {
        var gate = AssistantBargeInGate()
        gate.beginAssistantOutput()
        _ = gate.inputForRealtime(audioChunk(level: 0.28))
        gate.finishAssistantOutput(suppressEchoTail: true)

        for _ in 0..<4 {
            XCTAssertTrue(gate.inputForRealtime(audioChunk(level: 0.25)).isEmpty)
        }
        XCTAssertFalse(gate.isActive)
        XCTAssertEqual(gate.inputForRealtime(audioChunk(level: 0.20)).count, 1)
    }

    func testScreenContextItemIDAlwaysFitsRealtimeLimit() {
        for _ in 0..<100 {
            let itemID = RealtimeConversationProvider.makeScreenContextItemID()
            XCTAssertLessThanOrEqual(itemID.count, 32)
            XCTAssertTrue(itemID.hasPrefix("scr_"))
        }
    }

    func testScreenSelectionGuideStaysInsideDisplayEdges() {
        let bounds = CGRect(x: 0, y: 0, width: 1_440, height: 900)
        let pointers = [
            CGPoint(x: 0, y: 0),
            CGPoint(x: bounds.maxX, y: 0),
            CGPoint(x: 0, y: bounds.maxY),
            CGPoint(x: bounds.maxX, y: bounds.maxY)
        ]

        for pointer in pointers {
            let frame = ScreenRegionSelectionLayout.instructionFrame(
                pointer: pointer,
                bounds: bounds
            )
            XCTAssertEqual(frame.size, ScreenRegionSelectionLayout.bubbleSize)
            XCTAssertGreaterThanOrEqual(frame.minX, bounds.minX + 8)
            XCTAssertGreaterThanOrEqual(frame.minY, bounds.minY + 8)
            XCTAssertLessThanOrEqual(frame.maxX, bounds.maxX - 8)
            XCTAssertLessThanOrEqual(frame.maxY, bounds.maxY - 8)
        }
    }

    func testConversationSessionLedgerCreatesIdentityAndAccumulatesUsage() {
        var ledger = ConversationSessionLedger()

        let firstSession = ledger.beginSession()
        XCTAssertNotNil(firstSession.id)
        XCTAssertTrue(firstSession.isActive)

        let firstUpdate = ledger.record(
            DictationUsage(outputAudioTokens: 10, totalTokens: 40)
        )
        XCTAssertTrue(firstUpdate.didRecord)
        XCTAssertEqual(firstUpdate.snapshot.completedResponses, 1)
        XCTAssertEqual(firstUpdate.snapshot.totalTokens, 40)
        XCTAssertGreaterThan(firstUpdate.responseCostUSD, 0)

        let secondUpdate = ledger.record(DictationUsage(totalTokens: 45))
        XCTAssertEqual(secondUpdate.snapshot.id, firstSession.id)
        XCTAssertEqual(secondUpdate.snapshot.completedResponses, 2)
        XCTAssertEqual(secondUpdate.snapshot.totalTokens, 85)
    }

    func testConversationResponseLoopGuardOnlyTripsOnAResponseStorm() {
        var guardrail = ConversationResponseLoopGuard(
            maximumResponses: 3,
            window: 10
        )
        let start = Date(timeIntervalSince1970: 1_000)

        XCTAssertFalse(guardrail.recordResponse(at: start))
        XCTAssertFalse(guardrail.recordResponse(at: start.addingTimeInterval(2)))
        XCTAssertTrue(guardrail.recordResponse(at: start.addingTimeInterval(4)))

        guardrail.reset()
        XCTAssertFalse(guardrail.recordResponse(at: start.addingTimeInterval(20)))
    }

    func testConversationSessionLedgerRejectsLateUsageAfterSessionEnds() {
        var ledger = ConversationSessionLedger()
        let active = ledger.beginSession()
        let ended = ledger.endSession()
        let lateUpdate = ledger.record(DictationUsage(totalTokens: 999))

        XCTAssertEqual(ended.id, active.id)
        XCTAssertFalse(ended.isActive)
        XCTAssertFalse(lateUpdate.didRecord)
        XCTAssertEqual(lateUpdate.snapshot.totalTokens, 0)

        let next = ledger.beginSession()
        XCTAssertNotEqual(next.id, active.id)
        XCTAssertEqual(next.completedResponses, 0)
        XCTAssertEqual(next.totalTokens, 0)
    }

    func testTurnCorrelatorBuildsStableIdentityChain() throws {
        let sessionID = ConversationSessionID()
        let userItemID = try XCTUnwrap(ConversationProviderItemID("user_1"))
        let providerResponseID = try XCTUnwrap(ConversationProviderResponseID("resp_1"))
        let assistantItemID = try XCTUnwrap(ConversationProviderItemID("assistant_1"))
        let identity = ConversationProviderEventIdentity(
            responseID: providerResponseID,
            itemID: assistantItemID
        )
        var correlator = ConversationTurnCorrelator()

        correlator.beginSession(sessionID)
        let started = try XCTUnwrap(correlator.beginUserTurn(providerItemID: userItemID))
        correlator.markActiveTurnAwaitingResponse()
        let responding = try XCTUnwrap(
            correlator.beginResponse(providerResponseID: providerResponseID)
        )
        let item = try XCTUnwrap(correlator.beginAssistantItem(identity: identity))
        let playing = try XCTUnwrap(correlator.beginPlayback(identity: identity))
        let completed = try XCTUnwrap(
            correlator.finishResponse(
                providerResponseID: providerResponseID,
                cancelled: false
            )
        )
        let delivered = try XCTUnwrap(
            correlator.finishActivePlayback(interrupted: false)
        )

        XCTAssertEqual(started.sessionID, sessionID)
        XCTAssertEqual(responding.turnID, started.turnID)
        XCTAssertEqual(item.turnID, started.turnID)
        XCTAssertEqual(playing.turnID, started.turnID)
        XCTAssertEqual(completed.turnID, started.turnID)
        XCTAssertEqual(delivered.turnID, started.turnID)
        XCTAssertNotNil(responding.responseID)
        XCTAssertNotNil(item.assistantItemID)
        XCTAssertNotNil(playing.playbackID)
        XCTAssertEqual(completed.responseState, .completed)
        XCTAssertEqual(delivered.playbackState, .delivered)
    }

    func testTurnCorrelatorRejectsLateAudioFromPreviousTurn() throws {
        let firstResponseID = try XCTUnwrap(ConversationProviderResponseID("resp_old"))
        let firstAssistantItemID = try XCTUnwrap(ConversationProviderItemID("assistant_old"))
        let firstIdentity = ConversationProviderEventIdentity(
            responseID: firstResponseID,
            itemID: firstAssistantItemID
        )
        var correlator = ConversationTurnCorrelator()
        correlator.beginSession(ConversationSessionID())

        let firstTurn = try XCTUnwrap(
            correlator.beginUserTurn(
                providerItemID: ConversationProviderItemID("user_old")
            )
        )
        correlator.markActiveTurnAwaitingResponse()
        _ = correlator.beginResponse(providerResponseID: firstResponseID)
        _ = correlator.beginAssistantItem(identity: firstIdentity)

        let secondTurn = try XCTUnwrap(
            correlator.beginUserTurn(
                providerItemID: ConversationProviderItemID("user_new")
            )
        )

        XCTAssertNotEqual(firstTurn.turnID, secondTurn.turnID)
        XCTAssertNil(correlator.beginPlayback(identity: firstIdentity))
        XCTAssertEqual(correlator.activeTurnID, secondTurn.turnID)
        XCTAssertEqual(
            correlator.finishResponse(
                providerResponseID: firstResponseID,
                cancelled: false
            )?.turnID,
            firstTurn.turnID
        )
    }

    func testUserSpeechSupersedesUnansweredOpeningGreeting() throws {
        let responseID = try XCTUnwrap(ConversationProviderResponseID("resp_user"))
        var correlator = ConversationTurnCorrelator()
        correlator.beginSession(ConversationSessionID())

        _ = correlator.beginOpeningGreeting()
        let userTurn = try XCTUnwrap(
            correlator.beginUserTurn(providerItemID: ConversationProviderItemID("user_1"))
        )
        correlator.markActiveTurnAwaitingResponse()
        let response = try XCTUnwrap(
            correlator.beginResponse(providerResponseID: responseID)
        )

        XCTAssertEqual(response.turnID, userTurn.turnID)
        XCTAssertEqual(response.source, .userSpeech)
    }

    func testDuplicateOldSpeechEventDoesNotReactivatePreviousTurn() throws {
        let oldItemID = try XCTUnwrap(ConversationProviderItemID("user_old"))
        var correlator = ConversationTurnCorrelator()
        correlator.beginSession(ConversationSessionID())

        let oldTurn = try XCTUnwrap(correlator.beginUserTurn(providerItemID: oldItemID))
        correlator.markActiveTurnAwaitingResponse()
        _ = correlator.beginResponse(
            providerResponseID: ConversationProviderResponseID("response_old")
        )
        let currentTurn = try XCTUnwrap(
            correlator.beginUserTurn(providerItemID: ConversationProviderItemID("user_current"))
        )

        let duplicateOldTurn = try XCTUnwrap(
            correlator.beginUserTurn(providerItemID: oldItemID)
        )

        XCTAssertEqual(duplicateOldTurn.turnID, oldTurn.turnID)
        XCTAssertEqual(correlator.activeTurnID, currentTurn.turnID)
    }

    func testLateOldResponseStartDoesNotReactivatePreviousTurn() throws {
        let oldResponseID = try XCTUnwrap(ConversationProviderResponseID("response_old"))
        let oldIdentity = ConversationProviderEventIdentity(
            responseID: oldResponseID,
            itemID: ConversationProviderItemID("assistant_old")
        )
        var correlator = ConversationTurnCorrelator()
        correlator.beginSession(ConversationSessionID())

        let oldTurn = try XCTUnwrap(
            correlator.beginUserTurn(providerItemID: ConversationProviderItemID("user_old"))
        )
        correlator.markActiveTurnAwaitingResponse()
        let currentTurn = try XCTUnwrap(
            correlator.beginUserTurn(providerItemID: ConversationProviderItemID("user_current"))
        )
        correlator.markActiveTurnAwaitingResponse()

        let lateResponseTurn = try XCTUnwrap(
            correlator.beginResponse(providerResponseID: oldResponseID)
        )
        _ = correlator.beginAssistantItem(identity: oldIdentity)

        XCTAssertEqual(lateResponseTurn.turnID, oldTurn.turnID)
        XCTAssertEqual(correlator.activeTurnID, currentTurn.turnID)
        XCTAssertNil(correlator.beginPlayback(identity: oldIdentity))
    }

    private func audioChunk(level: Float, frameCount: Int = 1_200) -> AudioChunk {
        AudioChunk(
            pcm16: Data(repeating: 0, count: frameCount * 2),
            sampleRate: 24_000,
            channelCount: 1,
            frameCount: frameCount,
            normalizedLevel: level,
            waveformLevels: Array(
                repeating: level,
                count: AudioChunk.waveformLevelCount
            )
        )
    }
}
