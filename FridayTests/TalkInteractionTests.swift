// 功能：验证 Talk 会话身份、展示映射、音频打断、Action 路由和区域框选等高风险交互边界。
// 职责：覆盖会话账本、Provider-VAD/client-gate 端点分流、上行暂停、自管回复、迟到事件、响应保护、可撤销工具回执、屏幕指引和图片上下文等纯逻辑。
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
            .conversation(expression: .observing, source: .idle)
        )
        XCTAssertEqual(model.audioLevel, levels.level)
        XCTAssertTrue(model.isVoiceActive)
        XCTAssertEqual(model.waveformLevels, levels.waveformLevels)
    }

    func testInputGateRejectsShortAndSteadyPlaybackNoise() {
        var gate = ConversationInputGate()
        gate.beginAssistantPlayback(allowsInterruption: true)

        let shortNearbyNoise: [AudioChunk] = [Float(0.58), 0.66, 0.57, 0.69, 0.60].flatMap {
            gate.inputForRealtime(audioChunk(level: $0))
        }
        XCTAssertTrue(shortNearbyNoise.isEmpty)
        XCTAssertFalse(gate.hasConfirmedInterruption)

        gate = ConversationInputGate()
        gate.beginAssistantPlayback(allowsInterruption: true)
        let steadyLoudNoise = (0..<12).flatMap { _ in
            gate.inputForRealtime(audioChunk(level: 0.64))
        }
        XCTAssertTrue(steadyLoudNoise.isEmpty)
        XCTAssertFalse(gate.hasConfirmedInterruption)
    }

    func testInputGateAcceptsSustainedDynamicNearFieldSpeech() {
        var gate = ConversationInputGate()
        gate.beginAssistantPlayback(allowsInterruption: true)

        let nearbySpeech: [Float] = [0.56, 0.64, 0.58, 0.69, 0.57, 0.66, 0.59, 0.63]
        var releasedChunks: [AudioChunk] = []
        for level in nearbySpeech {
            releasedChunks.append(
                contentsOf: gate.inputForRealtime(audioChunk(level: level))
            )
        }

        XCTAssertGreaterThan(releasedChunks.count, 1)
        XCTAssertTrue(gate.hasConfirmedSpeech)
        XCTAssertTrue(gate.hasConfirmedInterruption)
        XCTAssertEqual(gate.inputForRealtime(audioChunk(level: 0.52)).count, 1)
    }

    func testInputGateAcceptsSyllabicInterruptionAcrossShortGaps() {
        var gate = ConversationInputGate()
        gate.beginAssistantPlayback(allowsInterruption: true)

        let syllabicSpeech: [Float] = [
            0.56, 0.64, 0.18,
            0.58, 0.69, 0.20,
            0.57, 0.66
        ]
        let released = syllabicSpeech.flatMap {
            gate.inputForRealtime(audioChunk(level: $0))
        }

        XCTAssertGreaterThan(released.count, 1)
        XCTAssertTrue(gate.hasConfirmedInterruption)
        XCTAssertTrue(
            gate.takeTransitions().contains(.speechConfirmed(interruption: true))
        )
    }

    func testInputGateResetsCandidateAfterLongGapWithBoundedDiagnostics() {
        var gate = ConversationInputGate()
        gate.beginAssistantPlayback(allowsInterruption: true)

        _ = gate.inputForRealtime(audioChunk(level: 0.58))
        _ = gate.inputForRealtime(audioChunk(level: 0.66))
        for _ in 0..<4 {
            _ = gate.inputForRealtime(audioChunk(level: 0.10))
        }

        let snapshots: [ConversationInputGateCandidateSnapshot] = gate
            .takeTransitions()
            .compactMap { transition in
            guard case .candidateReset(let snapshot) = transition else { return nil }
            return snapshot
        }
        let reset = snapshots.first
        XCTAssertEqual(reset?.reason, .gapToleranceExceeded)
        XCTAssertEqual(reset?.interruption, true)
        XCTAssertEqual(reset?.voicedMilliseconds, 100)
        XCTAssertGreaterThanOrEqual(reset?.gapMilliseconds ?? 0, 180)
        XCTAssertFalse(gate.hasConfirmedInterruption)
    }

    func testInputGateTurnsStableRaisedNoiseIntoEndpointSilence() {
        var gate = ConversationInputGate()
        let openingSpeech: [Float] = [0.31, 0.46, 0.34, 0.52, 0.37]
        let openingOutput = openingSpeech.flatMap {
            gate.inputForRealtime(audioChunk(level: $0))
        }
        XCTAssertFalse(openingOutput.isEmpty)
        XCTAssertTrue(gate.hasConfirmedSpeech)

        var stableTailOutput: [AudioChunk] = []
        for _ in 0..<24 {
            stableTailOutput.append(
                contentsOf: gate.inputForRealtime(audioChunk(level: 0.28))
            )
        }

        XCTAssertTrue(stableTailOutput.contains { $0.normalizedLevel == 0 })
        XCTAssertTrue(
            gate.takeTransitions().contains {
                $0 == .speechReleased(reason: .stableBackground)
            }
        )
    }

    func testInputGateContinuesBoundedSilenceAfterLocalSpeechRelease() {
        var gate = ConversationInputGate()
        let openingSpeech: [Float] = [0.31, 0.46, 0.34, 0.52, 0.37]
        _ = openingSpeech.flatMap {
            gate.inputForRealtime(audioChunk(level: $0))
        }
        _ = gate.takeTransitions()

        for _ in 0..<11 {
            _ = gate.inputForRealtime(audioChunk(level: 0.05))
        }
        XCTAssertTrue(
            gate.takeTransitions().contains {
                $0 == .speechReleased(reason: .acousticSilence)
            }
        )

        let endpointSilence = gate.inputForRealtime(audioChunk(level: 0.05))

        XCTAssertEqual(endpointSilence.count, 1)
        XCTAssertEqual(endpointSilence.first?.normalizedLevel, 0)
        XCTAssertEqual(
            endpointSilence.first?.pcm16,
            Data(repeating: 0, count: 2_400)
        )
    }

    func testInputGateEndpointSilenceIsBoundedAndReportsExhaustion() {
        var gate = ConversationInputGate()
        let openingSpeech: [Float] = [0.31, 0.46, 0.34, 0.52, 0.37]
        _ = openingSpeech.flatMap {
            gate.inputForRealtime(audioChunk(level: $0))
        }
        for _ in 0..<11 {
            _ = gate.inputForRealtime(audioChunk(level: 0.05))
        }
        _ = gate.takeTransitions()

        var forwardedEndpointChunks = 0
        for _ in 0..<100 {
            forwardedEndpointChunks += gate.inputForRealtime(
                audioChunk(level: 0.05)
            ).count
        }

        XCTAssertEqual(forwardedEndpointChunks, 80)
        XCTAssertTrue(
            gate.takeTransitions().contains(.endpointSilenceExhausted)
        )
        XCTAssertTrue(gate.inputForRealtime(audioChunk(level: 0.05)).isEmpty)
    }

    func testInputGateResumedSpeechCancelsEndpointSilenceAndPreservesPreRoll() {
        var gate = ConversationInputGate()
        let openingSpeech: [Float] = [0.31, 0.46, 0.34, 0.52, 0.37]
        _ = openingSpeech.flatMap {
            gate.inputForRealtime(audioChunk(level: $0))
        }
        for _ in 0..<11 {
            _ = gate.inputForRealtime(audioChunk(level: 0.05))
        }
        _ = gate.takeTransitions()

        let resumedSpeech: [Float] = [0.32, 0.48, 0.35, 0.53]
        let resumedOutput = resumedSpeech.flatMap {
            gate.inputForRealtime(audioChunk(level: $0))
        }

        XCTAssertGreaterThan(resumedOutput.count, 1)
        XCTAssertTrue(resumedOutput.contains { $0.normalizedLevel > 0 })
        XCTAssertTrue(gate.hasConfirmedSpeech)
        XCTAssertFalse(
            gate.takeTransitions().contains(.endpointSilenceExhausted)
        )
    }

    func testInputGateDoesNotConfirmSteadyListeningNoiseAsSpeech() {
        var gate = ConversationInputGate()

        let forwarded = (0..<20).flatMap { _ in
            gate.inputForRealtime(audioChunk(level: 0.31))
        }

        XCTAssertTrue(forwarded.isEmpty)
        XCTAssertFalse(gate.hasConfirmedSpeech)
    }

    func testHalfDuplexInputGateNeverForwardsAudioDuringPlayback() {
        var gate = ConversationInputGate()
        gate.beginAssistantPlayback(allowsInterruption: false)

        for _ in 0..<4 {
            XCTAssertTrue(gate.inputForRealtime(audioChunk(level: 0.90)).isEmpty)
        }
        XCTAssertFalse(gate.hasConfirmedSpeech)

        gate.finishAssistantPlayback()
        XCTAssertTrue(gate.inputForRealtime(audioChunk(level: 0.55)).isEmpty)
        XCTAssertTrue(gate.inputForRealtime(audioChunk(level: 0.63)).isEmpty)
        XCTAssertGreaterThan(
            gate.inputForRealtime(audioChunk(level: 0.57)).count,
            1
        )
    }

    func testProviderVADForwardsListeningAudioAndConfirmedAECSpeechDuringPlayback() {
        let captured = audioChunk(level: 0.34)
        let gated = [audioChunk(level: 0.51)]

        let providerListening = ConversationInputForwardingPolicy.realtimeChunks(
            endpointMode: .providerVAD,
            assistantIsActive: false,
            supportsEchoCancelledInterruption: true,
            capturedChunk: captured,
            gatedChunks: gated
        )
        XCTAssertEqual(providerListening.count, 1)
        XCTAssertEqual(providerListening.first?.pcm16, captured.pcm16)
        XCTAssertEqual(providerListening.first?.normalizedLevel, captured.normalizedLevel)
        let fullDuplexPlayback = ConversationInputForwardingPolicy.realtimeChunks(
                endpointMode: .providerVAD,
                assistantIsActive: true,
                supportsEchoCancelledInterruption: true,
                capturedChunk: captured,
                gatedChunks: gated
            )
        XCTAssertEqual(fullDuplexPlayback.count, 1)
        XCTAssertEqual(fullDuplexPlayback.first?.pcm16, gated.first?.pcm16)
        XCTAssertTrue(
            ConversationInputForwardingPolicy.realtimeChunks(
                endpointMode: .providerVAD,
                assistantIsActive: true,
                supportsEchoCancelledInterruption: false,
                capturedChunk: captured,
                gatedChunks: gated
            ).isEmpty
        )
        let clientGate = ConversationInputForwardingPolicy.realtimeChunks(
            endpointMode: .clientGate,
            assistantIsActive: false,
            supportsEchoCancelledInterruption: false,
            capturedChunk: captured,
            gatedChunks: gated
        )
        XCTAssertEqual(clientGate.count, 1)
        XCTAssertEqual(clientGate.first?.pcm16, gated.first?.pcm16)
        XCTAssertEqual(clientGate.first?.normalizedLevel, gated.first?.normalizedLevel)
    }

    func testScreenContextItemIDAlwaysFitsRealtimeLimit() {
        for _ in 0..<100 {
            let itemID = RealtimeConversationProvider.makeScreenContextItemID()
            XCTAssertLessThanOrEqual(itemID.count, 32)
            XCTAssertTrue(itemID.hasPrefix("scr_"))
        }
    }

    func testCommittedInputAudioIsExposedAsAUserItemEvent() throws {
        var parser = ConversationEventParser()

        let events = parser.consume([
            "type": "input_audio_buffer.committed",
            "item_id": "item_client_endpoint"
        ])

        XCTAssertEqual(
            events,
            [
                .userAudioCommitted(
                    itemID: try XCTUnwrap(
                        ConversationProviderItemID("item_client_endpoint")
                    )
                )
            ]
        )
    }

    func testInputTranscriptionDeltaIsExposedWithItsItemIdentity() throws {
        var parser = ConversationEventParser()

        let events = parser.consume([
            "type": "conversation.item.input_audio_transcription.delta",
            "item_id": "item_live_transcript",
            "delta": "你好"
        ])

        XCTAssertEqual(
            events,
            [
                .userTranscriptionDelta(
                    ConversationInputTranscriptionDelta(
                        itemID: try XCTUnwrap(
                            ConversationProviderItemID("item_live_transcript")
                        ),
                        delta: "你好"
                    )
                )
            ]
        )
    }

    func testClientEndpointCommandsSendAudioBeforeCommitAndResponse() {
        let commands: [RealtimeInputCommand] = [
            .audio(Data([0x01, 0x02])),
            .commitAndRequest(UUID())
        ]

        let eventTypes = commands
            .flatMap(\.payloads)
            .compactMap { $0["type"] as? String }

        XCTAssertEqual(
            eventTypes,
            [
                "input_audio_buffer.append",
                "input_audio_buffer.commit",
                "response.create"
            ]
        )
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

        let transcriptionUpdate = ledger.recordTranscription(
            UserTurnTranscriptionUsage(
                inputTokens: nil,
                outputTokens: nil,
                totalTokens: nil,
                audioSeconds: 60
            )
        )
        XCTAssertTrue(transcriptionUpdate.didRecord)
        XCTAssertEqual(transcriptionUpdate.costUSD, 0.017, accuracy: 0.000_001)
        XCTAssertEqual(
            transcriptionUpdate.snapshot.estimatedCostUSD,
            secondUpdate.snapshot.estimatedCostUSD + 0.017,
            accuracy: 0.000_001
        )
    }

    func testTalkTranscriptionDurationIsIncludedOnceInDisplayedSessionCost() async throws {
        let provider = MockConversationProvider()
        let coordinator = makeConversationCoordinator(
            provider: provider,
            audioService: WorkTestAudioService(),
            responseGrace: .milliseconds(20)
        )

        coordinator.startConversationFromShortcut()
        await waitUntil { provider.isConnected }
        let itemID = try XCTUnwrap(ConversationProviderItemID("costed_user_turn"))
        let transcript = ConversationInputTranscription(
            itemID: itemID,
            text: "测试",
            language: "zh",
            confidence: nil,
            usage: UserTurnTranscriptionUsage(
                inputTokens: nil,
                outputTokens: nil,
                totalTokens: nil,
                audioSeconds: 60
            )
        )
        provider.simulate(.userSpeechStarted(itemID: itemID))
        provider.simulate(.userSpeechStopped(itemID: itemID))
        provider.simulate(.userTranscriptionCompleted(transcript))
        provider.simulate(.userTranscriptionCompleted(transcript))

        XCTAssertEqual(coordinator.estimatedCostUSD, 0.017, accuracy: 0.000_001)
        coordinator.stop()
    }

    func testConversationResponseLoopGuardOnlyTripsWithoutANewUserTurn() {
        var guardrail = ConversationResponseLoopGuard(
            maximumResponses: 3,
            window: 10
        )
        let start = Date(timeIntervalSince1970: 1_000)

        XCTAssertFalse(guardrail.recordResponse(at: start))
        XCTAssertFalse(guardrail.recordResponse(at: start.addingTimeInterval(2)))

        guardrail.recordUserTurn()
        XCTAssertEqual(guardrail.consecutiveResponseCount, 0)
        XCTAssertFalse(guardrail.recordResponse(at: start.addingTimeInterval(3)))
        XCTAssertFalse(guardrail.recordResponse(at: start.addingTimeInterval(4)))
        XCTAssertTrue(guardrail.recordResponse(at: start.addingTimeInterval(4)))

        guardrail.reset()
        XCTAssertFalse(guardrail.recordResponse(at: start.addingTimeInterval(20)))
    }

    func testRapidUserTurnsDoNotStopConversation() async throws {
        let provider = MockConversationProvider()
        let coordinator = ConversationCoordinator(
            activationMode: .shortcut,
            wakeWordProvider: MockWakeWordService(),
            conversationProvider: provider,
            audioService: WorkTestAudioService(),
            presentation: InputOverlayConversationPresenter(
                model: InputOverlayModel(),
                controller: nil
            )
        )

        coordinator.startConversationFromShortcut()
        await waitUntil { provider.isConnected }

        for index in 0..<12 {
            let itemID = try XCTUnwrap(
                ConversationProviderItemID("rapid_user_\(index)")
            )
            let responseID = try XCTUnwrap(
                ConversationProviderResponseID("rapid_response_\(index)")
            )
            provider.simulate(.userSpeechStarted(itemID: itemID))
            provider.simulate(.userSpeechStopped(itemID: itemID))
            provider.simulate(.assistantResponseStarted(responseID: responseID))
            provider.simulate(
                .responseCompleted(responseID: responseID, usage: .zero)
            )

            XCTAssertTrue(provider.isConnected)
            XCTAssertTrue(coordinator.isConversationActive)
        }

        XCTAssertEqual(coordinator.turnCount, 12)
        coordinator.stop()
    }

    func testLiveTranscriptReplacesPartialWithFinalAndRejectsOldItemDelta() async throws {
        let provider = MockConversationProvider()
        let coordinator = makeConversationCoordinator(
            provider: provider,
            audioService: WorkTestAudioService(),
            responseGrace: .seconds(2)
        )

        coordinator.startConversationFromShortcut()
        await waitUntil { provider.isConnected }
        let firstItemID = try XCTUnwrap(ConversationProviderItemID("live_user_1"))
        provider.simulate(.userSpeechStarted(itemID: firstItemID))
        provider.simulate(
            .userTranscriptionDelta(
                ConversationInputTranscriptionDelta(itemID: firstItemID, delta: "你")
            )
        )
        provider.simulate(
            .userTranscriptionDelta(
                ConversationInputTranscriptionDelta(itemID: firstItemID, delta: "好")
            )
        )

        XCTAssertEqual(coordinator.liveTranscript.userText, "你好")
        XCTAssertFalse(coordinator.liveTranscript.userTextIsFinal)
        XCTAssertNotNil(coordinator.liveTranscript.firstTextLatencyMilliseconds)

        provider.simulate(.userSpeechStopped(itemID: firstItemID))
        provider.simulate(
            .userTranscriptionCompleted(
                ConversationInputTranscription(
                    itemID: firstItemID,
                    text: "你好。",
                    language: "zh",
                    confidence: nil,
                    usage: nil
                )
            )
        )
        XCTAssertEqual(coordinator.liveTranscript.userText, "你好。")
        XCTAssertTrue(coordinator.liveTranscript.userTextIsFinal)
        XCTAssertNotNil(coordinator.liveTranscript.finalizationLatencyMilliseconds)

        let responseID = try XCTUnwrap(ConversationProviderResponseID("live_response_1"))
        let assistantItemID = try XCTUnwrap(
            ConversationProviderItemID("live_assistant_1")
        )
        let identity = ConversationProviderEventIdentity(
            responseID: responseID,
            itemID: assistantItemID
        )
        provider.simulate(.assistantResponseStarted(responseID: responseID))
        provider.simulate(.assistantItemStarted(identity))
        provider.simulate(.assistantTranscriptDelta(identity: identity, delta: "你好呀"))
        provider.simulate(.responseCompleted(responseID: responseID, usage: .zero))
        XCTAssertEqual(coordinator.liveTranscript.assistantText, "你好呀")

        let secondItemID = try XCTUnwrap(ConversationProviderItemID("live_user_2"))
        provider.simulate(.userSpeechStarted(itemID: secondItemID))
        XCTAssertEqual(coordinator.liveTranscript.userText, "")
        XCTAssertEqual(coordinator.liveTranscript.assistantText, "你好呀")

        provider.simulate(
            .userTranscriptionDelta(
                ConversationInputTranscriptionDelta(itemID: firstItemID, delta: "迟到")
            )
        )
        XCTAssertEqual(coordinator.liveTranscript.userText, "")
        coordinator.stop()
    }

    func testProviderVADSpeechStopUsesAutomaticResponseCreation() async throws {
        let provider = MockConversationProvider()
        let audioService = WorkTestAudioService()
        let coordinator = makeConversationCoordinator(
            provider: provider,
            audioService: audioService,
            responseGrace: .milliseconds(20)
        )

        coordinator.startConversationFromShortcut()
        await waitUntil { provider.isConnected }
        let itemID = try XCTUnwrap(ConversationProviderItemID("user_single_turn"))
        provider.simulate(.userSpeechStarted(itemID: itemID))
        provider.simulate(.userSpeechStopped(itemID: itemID))

        XCTAssertEqual(provider.userResponseRequestCount, 0)
        XCTAssertEqual(audioService.completedUserTurnEndpointCount, 0)
        XCTAssertEqual(audioService.assistantPreparationCount, 1)
        XCTAssertEqual(coordinator.state, .assistantPreparing)
        coordinator.stop()
    }

    func testProviderVADUsesLocalSpeechOnlyToSuppressOpeningGreeting() async throws {
        let provider = MockConversationProvider()
        let audioService = WorkTestAudioService()
        let coordinator = ConversationCoordinator(
            activationMode: .shortcut,
            wakeWordProvider: MockWakeWordService(),
            conversationProvider: provider,
            audioService: audioService,
            presentation: InputOverlayConversationPresenter(
                model: InputOverlayModel(),
                controller: nil
            ),
            openingGreetingDelay: .milliseconds(30),
            userTurnResponseGrace: .milliseconds(10)
        )

        coordinator.startConversationFromShortcut()
        await waitUntil { provider.isConnected }
        audioService.onInputGateTransition?(.candidateStarted(interruption: false))
        audioService.onInputGateTransition?(.speechConfirmed(interruption: false))
        audioService.onInputGateTransition?(.speechReleased(reason: .stableBackground))
        audioService.onInputGateTransition?(.endpointSilenceExhausted)
        try await Task.sleep(for: .milliseconds(80))

        XCTAssertEqual(provider.userResponseRequestCount, 0)
        XCTAssertEqual(provider.clearedUserAudioCount, 0)
        XCTAssertEqual(provider.openingGreetingRequestCount, 0)
        XCTAssertEqual(audioService.lastConfiguredEndpointMode, .providerVAD)
        XCTAssertEqual(audioService.lastAllowsResponseInterruption, false)
        XCTAssertTrue(provider.isConnected)
        coordinator.stop()
    }

    func testLocalSpeechCancelsOpeningGreetingAlreadyBeingPrepared() async throws {
        let provider = MockConversationProvider()
        let audioService = WorkTestAudioService()
        let coordinator = ConversationCoordinator(
            activationMode: .shortcut,
            wakeWordProvider: MockWakeWordService(),
            conversationProvider: provider,
            audioService: audioService,
            presentation: InputOverlayConversationPresenter(
                model: InputOverlayModel(),
                controller: nil
            ),
            openingGreetingDelay: .milliseconds(10),
            userTurnResponseGrace: .milliseconds(10)
        )

        coordinator.startConversationFromShortcut()
        await waitUntil { provider.openingGreetingRequestCount == 1 }
        audioService.onInputGateTransition?(.speechConfirmed(interruption: false))

        XCTAssertEqual(provider.assistantCancellationCount, 1)
        XCTAssertEqual(coordinator.state, .listening)
        XCTAssertTrue(provider.isConnected)
        coordinator.stop()
    }

    func testClientGateCreatesOneResponseWithoutProviderSpeechEvents() async {
        let provider = MockConversationProvider(endpointMode: .clientGate)
        let audioService = WorkTestAudioService()
        let coordinator = makeConversationCoordinator(
            provider: provider,
            audioService: audioService,
            responseGrace: .milliseconds(20)
        )

        coordinator.startConversationFromShortcut()
        await waitUntil { provider.isConnected }

        audioService.onInputGateTransition?(.speechConfirmed(interruption: false))
        XCTAssertEqual(coordinator.state, .userSpeaking)
        audioService.onInputGateTransition?(.speechReleased(reason: .acousticSilence))

        await waitUntil { provider.userResponseRequestCount == 1 }
        XCTAssertEqual(audioService.completedUserTurnEndpointCount, 1)
        XCTAssertEqual(coordinator.state, .assistantPreparing)
        XCTAssertTrue(provider.isConnected)
        coordinator.stop()
    }

    func testClientGateContinuationCancelsTheEarlyResponse() async throws {
        let provider = MockConversationProvider(endpointMode: .clientGate)
        let audioService = WorkTestAudioService()
        let coordinator = makeConversationCoordinator(
            provider: provider,
            audioService: audioService,
            responseGrace: .milliseconds(80)
        )

        coordinator.startConversationFromShortcut()
        await waitUntil { provider.isConnected }
        audioService.onInputGateTransition?(.speechConfirmed(interruption: false))
        audioService.onInputGateTransition?(.speechReleased(reason: .acousticSilence))
        try await Task.sleep(for: .milliseconds(20))
        audioService.onInputGateTransition?(.speechConfirmed(interruption: false))
        try await Task.sleep(for: .milliseconds(100))

        XCTAssertEqual(provider.userResponseRequestCount, 0)
        XCTAssertEqual(audioService.completedUserTurnEndpointCount, 0)
        XCTAssertEqual(coordinator.state, .userSpeaking)

        audioService.onInputGateTransition?(.speechReleased(reason: .acousticSilence))
        await waitUntil { provider.userResponseRequestCount == 1 }
        XCTAssertEqual(audioService.completedUserTurnEndpointCount, 1)
        coordinator.stop()
    }

    func testClientGateReplaysSpeechAfterScreenContextAttachment() async {
        let provider = MockConversationProvider(endpointMode: .clientGate)
        let audioService = WorkTestAudioService()
        let captureService = TalkTestScreenRegionCaptureService()
        let selectionController = TalkTestScreenRegionSelectionController()
        let coordinator = ConversationCoordinator(
            activationMode: .shortcut,
            wakeWordProvider: MockWakeWordService(),
            conversationProvider: provider,
            audioService: audioService,
            screenCaptureService: captureService,
            screenSelectionController: selectionController,
            presentation: InputOverlayConversationPresenter(
                model: InputOverlayModel(),
                controller: nil
            ),
            userTurnResponseGrace: .milliseconds(20)
        )

        coordinator.startConversationFromShortcut()
        await waitUntil { provider.isConnected }
        coordinator.beginScreenRegionSelection()
        selectionController.complete(
            ScreenRegionSelection(
                displayID: 7,
                screenFrame: CGRect(x: 0, y: 0, width: 1_000, height: 800),
                selectedFrame: CGRect(x: 100, y: 200, width: 300, height: 80)
            )
        )
        XCTAssertEqual(coordinator.state, .capturingScreenRegion)

        audioService.onInputChunk?(
            AudioChunk(
                pcm16: Data(repeating: 1, count: 4_800),
                sampleRate: 24_000,
                channelCount: 1,
                frameCount: 2_400,
                normalizedLevel: 0.5
            )
        )
        audioService.onInputGateTransition?(.speechConfirmed(interruption: false))
        audioService.onInputGateTransition?(.speechReleased(reason: .acousticSilence))

        XCTAssertEqual(provider.appendedChunkCount, 0)
        XCTAssertEqual(provider.userResponseRequestCount, 0)
        await waitUntil { provider.screenContexts.count == 1 }
        await waitUntil { provider.userResponseRequestCount == 1 }

        XCTAssertEqual(provider.appendedChunkCount, 1)
        XCTAssertEqual(audioService.completedUserTurnEndpointCount, 1)
        XCTAssertEqual(coordinator.state, .assistantPreparing)
        coordinator.stop()
    }

    func testEndpointSilenceExhaustionRecoversWithoutEndingConversation() async throws {
        let provider = MockConversationProvider(endpointMode: .clientGate)
        let audioService = WorkTestAudioService()
        let coordinator = makeConversationCoordinator(
            provider: provider,
            audioService: audioService,
            responseGrace: .milliseconds(20)
        )

        coordinator.startConversationFromShortcut()
        await waitUntil { provider.isConnected }
        let itemID = try XCTUnwrap(
            ConversationProviderItemID("user_without_provider_endpoint")
        )
        provider.simulate(.userSpeechStarted(itemID: itemID))

        audioService.onInputGateTransition?(.endpointSilenceExhausted)

        await waitUntil { provider.clearedUserAudioCount == 1 }
        XCTAssertEqual(coordinator.state, .listening)
        XCTAssertTrue(provider.isConnected)
        XCTAssertTrue(coordinator.isProviderConnected)
        XCTAssertTrue(coordinator.isConversationActive)
        XCTAssertEqual(audioService.resetUserInputCount, 1)
        coordinator.stop()
    }

    func testSpeechResumeWithinGraceDoesNotCreateAnEarlyResponse() async throws {
        let provider = MockConversationProvider(endpointMode: .clientGate)
        let audioService = WorkTestAudioService()
        let coordinator = makeConversationCoordinator(
            provider: provider,
            audioService: audioService,
            responseGrace: .milliseconds(60)
        )

        coordinator.startConversationFromShortcut()
        await waitUntil { provider.isConnected }
        audioService.onInputGateTransition?(.speechConfirmed(interruption: false))
        audioService.onInputGateTransition?(.speechReleased(reason: .acousticSilence))
        try await Task.sleep(for: .milliseconds(20))
        audioService.onInputGateTransition?(.speechConfirmed(interruption: false))
        try await Task.sleep(for: .milliseconds(80))

        XCTAssertEqual(provider.userResponseRequestCount, 0)
        XCTAssertEqual(coordinator.state, .userSpeaking)

        audioService.onInputGateTransition?(.speechReleased(reason: .acousticSilence))
        await waitUntil { provider.userResponseRequestCount == 1 }
        XCTAssertEqual(provider.userResponseRequestCount, 1)
        coordinator.stop()
    }

    func testSpeechDuringResponsePreparationCancelsWithoutStalePlaybackTruncation() async throws {
        let provider = MockConversationProvider(allowsResponseInterruption: true)
        let audioService = WorkTestAudioService()
        audioService.stopAssistantPlaybackResult = 6_250
        let coordinator = makeConversationCoordinator(
            provider: provider,
            audioService: audioService,
            responseGrace: .seconds(1)
        )

        coordinator.startConversationFromShortcut()
        await waitUntil { provider.isConnected }
        let firstItemID = try XCTUnwrap(ConversationProviderItemID("user_before_response"))
        let responseID = try XCTUnwrap(
            ConversationProviderResponseID("response_without_audio")
        )
        provider.simulate(.userSpeechStarted(itemID: firstItemID))
        provider.simulate(.userSpeechStopped(itemID: firstItemID))
        provider.simulate(.assistantResponseStarted(responseID: responseID))

        audioService.hasConfirmedInterruption = true
        let continuingItemID = try XCTUnwrap(
            ConversationProviderItemID("user_continues_before_audio")
        )
        provider.simulate(.userSpeechStarted(itemID: continuingItemID))

        XCTAssertEqual(provider.assistantCancellationCount, 1)
        XCTAssertEqual(audioService.stopAssistantPlaybackCount, 0)
        XCTAssertTrue(provider.truncations.isEmpty)
        XCTAssertEqual(coordinator.state, .userSpeaking)
        coordinator.stop()
    }

    func testUnconfirmedNoiseDuringResponsePreparationDoesNotCancelReply() async throws {
        let provider = MockConversationProvider()
        let audioService = WorkTestAudioService()
        let coordinator = makeConversationCoordinator(
            provider: provider,
            audioService: audioService,
            responseGrace: .milliseconds(10)
        )

        coordinator.startConversationFromShortcut()
        await waitUntil { provider.isConnected }
        let firstItemID = try XCTUnwrap(
            ConversationProviderItemID("user_before_preparation_noise")
        )
        provider.simulate(.userSpeechStarted(itemID: firstItemID))
        provider.simulate(.userSpeechStopped(itemID: firstItemID))
        await waitUntil { coordinator.state == .assistantPreparing }

        let noiseItemID = try XCTUnwrap(
            ConversationProviderItemID("unconfirmed_preparation_noise")
        )
        provider.simulate(.userSpeechStarted(itemID: noiseItemID))
        provider.simulate(.userSpeechStopped(itemID: noiseItemID))

        XCTAssertEqual(provider.assistantCancellationCount, 0)
        XCTAssertEqual(provider.discardedUserAudioItemIDs, [noiseItemID.rawValue])
        XCTAssertEqual(provider.userResponseRequestCount, 0)
        XCTAssertEqual(audioService.assistantPreparationCount, 1)
        XCTAssertEqual(coordinator.state, .assistantPreparing)
        coordinator.stop()
    }

    func testCancellationNoopKeepsConversationActiveAndRecordsDiagnostic() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let fileURL = directory.appendingPathComponent("latest-talk.jsonl")
        defer { try? FileManager.default.removeItem(at: directory) }

        let provider = MockConversationProvider()
        let coordinator = makeConversationCoordinator(
            provider: provider,
            audioService: WorkTestAudioService(),
            responseGrace: .milliseconds(10),
            diagnostics: ConversationJSONLDiagnosticsRecorder(fileURL: fileURL)
        )

        coordinator.startConversationFromShortcut()
        await waitUntil { provider.isConnected }
        provider.simulate(
            .assistantCancellationIgnored(code: "response_cancel_not_active")
        )

        XCTAssertTrue(provider.isConnected)
        XCTAssertTrue(coordinator.isConversationActive)
        let contents = try String(contentsOf: fileURL, encoding: .utf8)
        XCTAssertTrue(contents.contains("response.cancellation_noop"))
        XCTAssertFalse(contents.contains("provider.failed"))
        coordinator.stop()
    }

    func testLateCancelledResponseDoesNotCancelTheNextTurnRequest() async throws {
        let provider = MockConversationProvider(endpointMode: .clientGate)
        let audioService = WorkTestAudioService()
        let coordinator = makeConversationCoordinator(
            provider: provider,
            audioService: audioService,
            responseGrace: .milliseconds(30)
        )

        coordinator.startConversationFromShortcut()
        await waitUntil { provider.isConnected }
        audioService.onInputGateTransition?(.speechConfirmed(interruption: false))
        audioService.onInputGateTransition?(.speechReleased(reason: .acousticSilence))
        await waitUntil { provider.userResponseRequestCount == 1 }

        audioService.hasConfirmedInterruption = true
        audioService.onInputGateTransition?(.speechConfirmed(interruption: true))
        audioService.onInputGateTransition?(.speechReleased(reason: .acousticSilence))
        provider.simulate(
            .assistantResponseStarted(
                responseID: ConversationProviderResponseID("cancelled_response_arrived_late")
            )
        )

        await waitUntil { provider.userResponseRequestCount == 2 }
        XCTAssertEqual(provider.userResponseRequestCount, 2)
        XCTAssertEqual(coordinator.state, .assistantPreparing)
        coordinator.stop()
    }

    func testRejectedPlaybackNoiseIsDiscardedWithoutCreatingAResponse() async throws {
        let provider = MockConversationProvider()
        let audioService = WorkTestAudioService()
        let coordinator = makeConversationCoordinator(
            provider: provider,
            audioService: audioService,
            responseGrace: .milliseconds(20)
        )

        coordinator.startConversationFromShortcut()
        await waitUntil { provider.isConnected }
        let responseID = try XCTUnwrap(ConversationProviderResponseID("assistant_reply"))
        let assistantItemID = try XCTUnwrap(ConversationProviderItemID("assistant_audio"))
        let identity = ConversationProviderEventIdentity(
            responseID: responseID,
            itemID: assistantItemID
        )
        provider.simulate(.assistantResponseStarted(responseID: responseID))
        provider.simulate(.assistantItemStarted(identity))
        provider.simulate(.assistantAudio(identity: identity, data: Data([0, 1])))

        let noiseItemID = try XCTUnwrap(ConversationProviderItemID("playback_noise"))
        provider.simulate(.userSpeechStarted(itemID: noiseItemID))
        provider.simulate(.userSpeechStopped(itemID: noiseItemID))
        provider.simulate(.userAudioCommitted(itemID: noiseItemID))
        let unsolicitedResponseID = try XCTUnwrap(
            ConversationProviderResponseID("playback_noise_response")
        )
        let unsolicitedIdentity = ConversationProviderEventIdentity(
            responseID: unsolicitedResponseID,
            itemID: ConversationProviderItemID("playback_noise_reply")
        )
        provider.simulate(.assistantResponseStarted(responseID: unsolicitedResponseID))
        provider.simulate(.assistantItemStarted(unsolicitedIdentity))
        provider.simulate(
            .assistantAudio(identity: unsolicitedIdentity, data: Data([2, 3]))
        )
        provider.simulate(.responseCancelled(responseID: unsolicitedResponseID))
        try await Task.sleep(for: .milliseconds(50))

        XCTAssertEqual(provider.discardedUserAudioItemIDs, [noiseItemID.rawValue])
        XCTAssertEqual(provider.userResponseRequestCount, 0)
        XCTAssertEqual(provider.assistantCancellationCount, 1)
        XCTAssertTrue(provider.truncations.isEmpty)
        XCTAssertEqual(coordinator.state, .assistantSpeaking)
        coordinator.stop()
    }

    func testExpiredSuppressedResponseRejectionDoesNotCancelALaterReply() async throws {
        let provider = MockConversationProvider()
        let audioService = WorkTestAudioService()
        let coordinator = makeConversationCoordinator(
            provider: provider,
            audioService: audioService,
            responseGrace: .milliseconds(20)
        )

        coordinator.startConversationFromShortcut()
        await waitUntil { provider.isConnected }
        let activeResponseID = try XCTUnwrap(
            ConversationProviderResponseID("active_response_before_expiry")
        )
        let activeIdentity = ConversationProviderEventIdentity(
            responseID: activeResponseID,
            itemID: ConversationProviderItemID("active_item_before_expiry")
        )
        provider.simulate(.assistantResponseStarted(responseID: activeResponseID))
        provider.simulate(.assistantItemStarted(activeIdentity))
        provider.simulate(.assistantAudio(identity: activeIdentity, data: Data([0, 1])))

        let noiseItemID = try XCTUnwrap(
            ConversationProviderItemID("expired_playback_noise")
        )
        provider.simulate(.userSpeechStarted(itemID: noiseItemID))
        provider.simulate(.userSpeechStopped(itemID: noiseItemID))
        coordinator.pendingSuppressedResponseRejections[noiseItemID] = .distantPast
        provider.simulate(.responseCompleted(responseID: activeResponseID, usage: .zero))
        audioService.onPlaybackFinished?()

        let laterResponseID = try XCTUnwrap(
            ConversationProviderResponseID("legitimate_later_response")
        )
        provider.simulate(.assistantResponseStarted(responseID: laterResponseID))

        XCTAssertEqual(provider.assistantCancellationCount, 0)
        XCTAssertEqual(coordinator.state, .assistantPreparing)
        coordinator.stop()
    }

    func testAutonomousResponseStormStillStopsConversation() async throws {
        let provider = MockConversationProvider()
        let coordinator = ConversationCoordinator(
            activationMode: .shortcut,
            wakeWordProvider: MockWakeWordService(),
            conversationProvider: provider,
            audioService: WorkTestAudioService(),
            presentation: InputOverlayConversationPresenter(
                model: InputOverlayModel(),
                controller: nil
            )
        )

        coordinator.startConversationFromShortcut()
        await waitUntil { provider.isConnected }

        for index in 0..<ConversationResponseLoopGuard.safety.maximumResponses {
            let responseID = try XCTUnwrap(
                ConversationProviderResponseID("autonomous_response_\(index)")
            )
            provider.simulate(.assistantResponseStarted(responseID: responseID))
            provider.simulate(
                .responseCompleted(responseID: responseID, usage: .zero)
            )
        }

        XCTAssertFalse(provider.isConnected)
        XCTAssertEqual(coordinator.state, .ending)
        coordinator.stop()
    }

    func testConfirmedBargeInResetsAutonomousResponseGuard() async throws {
        let provider = MockConversationProvider(allowsResponseInterruption: true)
        let audioService = WorkTestAudioService()
        let coordinator = ConversationCoordinator(
            activationMode: .shortcut,
            wakeWordProvider: MockWakeWordService(),
            conversationProvider: provider,
            audioService: audioService,
            presentation: InputOverlayConversationPresenter(
                model: InputOverlayModel(),
                controller: nil
            )
        )

        coordinator.startConversationFromShortcut()
        await waitUntil { provider.isConnected }

        for index in 0..<3 {
            let responseID = try XCTUnwrap(
                ConversationProviderResponseID("before_barge_in_\(index)")
            )
            provider.simulate(.assistantResponseStarted(responseID: responseID))
            provider.simulate(
                .responseCompleted(responseID: responseID, usage: .zero)
            )
        }

        let interruptedResponseID = try XCTUnwrap(
            ConversationProviderResponseID("interrupted_response")
        )
        let interruptedItemID = try XCTUnwrap(
            ConversationProviderItemID("interrupted_assistant_item")
        )
        let interruptedIdentity = ConversationProviderEventIdentity(
            responseID: interruptedResponseID,
            itemID: interruptedItemID
        )
        provider.simulate(
            .assistantResponseStarted(responseID: interruptedResponseID)
        )
        provider.simulate(.assistantItemStarted(interruptedIdentity))
        provider.simulate(
            .assistantAudio(identity: interruptedIdentity, data: Data([0, 1]))
        )

        audioService.hasConfirmedInterruption = true
        let userItemID = try XCTUnwrap(
            ConversationProviderItemID("barge_in_user")
        )
        provider.simulate(.userSpeechStarted(itemID: userItemID))

        XCTAssertEqual(audioService.stopAssistantPlaybackCount, 1)
        XCTAssertEqual(provider.truncations.count, 1)
        XCTAssertEqual(provider.truncations.first?.itemID, interruptedItemID.rawValue)
        provider.simulate(.responseCancelled(responseID: interruptedResponseID))
        provider.simulate(.userSpeechStopped(itemID: userItemID))

        let responseAfterBargeIn = try XCTUnwrap(
            ConversationProviderResponseID("response_after_barge_in")
        )
        provider.simulate(
            .assistantResponseStarted(responseID: responseAfterBargeIn)
        )
        provider.simulate(
            .responseCompleted(responseID: responseAfterBargeIn, usage: .zero)
        )

        XCTAssertTrue(provider.isConnected)
        XCTAssertTrue(coordinator.isConversationActive)
        coordinator.stop()
    }

    func testTalkDiagnosticsWritesInspectableLifecycleWithoutConversationContent() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let fileURL = directory.appendingPathComponent("latest-talk.jsonl")
        defer { try? FileManager.default.removeItem(at: directory) }

        let recorder = ConversationJSONLDiagnosticsRecorder(fileURL: fileURL)
        let sessionID = ConversationSessionID()
        recorder.beginSession(sessionID, state: "dormant")
        recorder.record(
            "interruption.confirmed",
            state: "user_speaking",
            attributes: ["local_confirmation": "true"]
        )
        recorder.finishSession(
            reason: .userRequested,
            state: "dormant",
            notice: nil
        )

        let contents = try String(contentsOf: fileURL, encoding: .utf8)
        let lines = contents.split(separator: "\n")
        XCTAssertEqual(lines.count, 3)
        XCTAssertTrue(contents.contains("interruption.confirmed"))
        XCTAssertTrue(contents.contains("user_requested"))
        XCTAssertTrue(contents.contains(sessionID.description))
        XCTAssertFalse(contents.contains("transcript"))
        XCTAssertFalse(contents.contains("audio_data"))
    }

    func testTalkDiagnosticsCorrelatesOneTurnFromSpeechThroughPlayback() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let fileURL = directory.appendingPathComponent("latest-talk.jsonl")
        defer { try? FileManager.default.removeItem(at: directory) }

        let provider = MockConversationProvider()
        let audioService = WorkTestAudioService()
        let coordinator = makeConversationCoordinator(
            provider: provider,
            audioService: audioService,
            responseGrace: .milliseconds(10),
            diagnostics: ConversationJSONLDiagnosticsRecorder(fileURL: fileURL)
        )

        coordinator.startConversationFromShortcut()
        await waitUntil { provider.isConnected }
        let userItemID = try XCTUnwrap(
            ConversationProviderItemID("diagnostic_user_turn")
        )
        let responseID = try XCTUnwrap(
            ConversationProviderResponseID("diagnostic_response")
        )
        let assistantItemID = try XCTUnwrap(
            ConversationProviderItemID("diagnostic_assistant_item")
        )
        let identity = ConversationProviderEventIdentity(
            responseID: responseID,
            itemID: assistantItemID
        )

        provider.simulate(.userSpeechStarted(itemID: userItemID))
        provider.simulate(.userSpeechStopped(itemID: userItemID))
        provider.simulate(.assistantResponseStarted(responseID: responseID))
        provider.simulate(.assistantItemStarted(identity))
        provider.simulate(.assistantAudio(identity: identity, data: Data([0, 1])))
        provider.simulate(.assistantAudioFinished(identity))
        provider.simulate(.responseCompleted(responseID: responseID, usage: .zero))
        audioService.onPlaybackFinished?()
        coordinator.stop()

        let records = try String(contentsOf: fileURL, encoding: .utf8)
            .split(separator: "\n")
            .map { line -> [String: Any] in
                let data = try XCTUnwrap(String(line).data(using: .utf8))
                return try XCTUnwrap(
                    JSONSerialization.jsonObject(with: data) as? [String: Any]
                )
            }
        let expectedEvents = [
            "turn.user_speech_started",
            "turn.user_speech_stopped",
            "response.provider_managed",
            "response.started",
            "assistant.item_started",
            "audio.playback_started",
            "provider.assistant_audio_finished",
            "provider.response_completed",
            "audio.playback_finished"
        ]
        let turnRecords = try expectedEvents.map { event in
            try XCTUnwrap(records.first { $0["event"] as? String == event })
        }
        let turnIDs = Set(turnRecords.compactMap { $0["turn_id"] as? String })

        XCTAssertEqual(turnIDs.count, 1)
        XCTAssertEqual(turnRecords.count, expectedEvents.count)
        assertDiagnosticAttribute(
            "provider_speech_duration_ms",
            event: "turn.user_speech_stopped",
            records: records
        )
        assertDiagnosticAttribute(
            "endpoint_to_request_ms",
            event: "response.provider_managed",
            records: records
        )
        assertDiagnosticAttribute(
            "request_to_response_ms",
            event: "response.started",
            records: records
        )
        assertDiagnosticAttribute(
            "endpoint_to_first_audio_ms",
            event: "audio.playback_started",
            records: records
        )
        assertDiagnosticAttribute(
            "response_generation_ms",
            event: "provider.response_completed",
            records: records
        )
        assertDiagnosticAttribute(
            "playback_duration_ms",
            event: "audio.playback_finished",
            records: records
        )
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

    func testCommittedProviderItemAttachesToClientOwnedTurn() throws {
        var correlator = ConversationTurnCorrelator()
        correlator.beginSession(ConversationSessionID())
        let localTurn = try XCTUnwrap(correlator.beginUserTurn(providerItemID: nil))
        let itemID = try XCTUnwrap(ConversationProviderItemID("item_after_commit"))

        let attached = try XCTUnwrap(
            correlator.attachProviderUserItemID(itemID, to: localTurn.turnID)
        )

        XCTAssertEqual(attached.turnID, localTurn.turnID)
        XCTAssertEqual(attached.providerUserItemID, itemID)
        XCTAssertEqual(correlator.snapshot(for: itemID)?.turnID, localTurn.turnID)
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

    func testBackgroundWorkDoesNotDisconnectConversation() async throws {
        let provider = MockConversationProvider()
        let workService = ControlledWorkService()
        let coordinator = makeWorkCoordinator(
            provider: provider,
            workService: workService
        )

        coordinator.startConversationFromShortcut()
        await waitUntil { provider.isConnected }
        await submitWork(
            callID: "call_background_work",
            objective: "验证后台任务不阻塞语音对话",
            provider: provider
        )

        XCTAssertTrue(provider.isConnected)
        XCTAssertTrue(coordinator.isConversationActive)
        XCTAssertTrue(provider.toolOutputs[0].output.contains(#""status":"awaiting_confirmation""#))
        XCTAssertTrue(provider.toolOutputs[1].output.contains(#""status":"accepted""#))

        workService.complete()
        await waitUntil { provider.completedWorkResults.count == 1 }

        XCTAssertTrue(provider.isConnected)
        XCTAssertTrue(coordinator.isConversationActive)
        XCTAssertEqual(coordinator.latestWork?.state, .completed)
        XCTAssertTrue(
            provider.completedWorkResults[0].contains("没有访问或修改任何外部内容")
        )
        coordinator.stop()
    }

    func testWaitForUserToolEndsBackgroundAudioTurnWithoutSpokenFollowUp() async throws {
        let provider = MockConversationProvider()
        let coordinator = makeWorkCoordinator(
            provider: provider,
            workService: ControlledWorkService()
        )

        coordinator.startConversationFromShortcut()
        await waitUntil { provider.isConnected }
        let responseID = ConversationProviderResponseID("response_background_audio")
        provider.simulate(.assistantResponseStarted(responseID: responseID))
        provider.simulate(
            .toolCall(
                ConversationToolCall(
                    callID: ConversationToolCallID("call_wait_for_user")!,
                    name: "wait_for_user",
                    argumentsJSON: "{}",
                    responseID: responseID
                )
            )
        )
        provider.simulate(.responseCompleted(responseID: responseID, usage: .zero))

        await waitUntil { provider.toolOutputs.count == 1 }
        XCTAssertEqual(provider.toolOutputs[0].callID, "call_wait_for_user")
        XCTAssertFalse(provider.toolOutputs[0].createsResponse)
        XCTAssertEqual(coordinator.state, .listening)
        XCTAssertTrue(provider.isConnected)
        coordinator.stop()
    }

    func testWaitForUserCannotSilenceASustainedUserTurn() async throws {
        let provider = MockConversationProvider()
        let coordinator = makeWorkCoordinator(
            provider: provider,
            workService: ControlledWorkService()
        )

        coordinator.startConversationFromShortcut()
        await waitUntil { provider.isConnected }
        let userItemID = try XCTUnwrap(
            ConversationProviderItemID("sustained_user_for_clarification")
        )
        provider.simulate(.userSpeechStarted(itemID: userItemID))
        provider.simulate(.userSpeechStopped(itemID: userItemID))
        let turnID = try XCTUnwrap(coordinator.turnCorrelator.activeTurnID)
        coordinator.providerSpeechDurationMillisecondsByTurn[turnID] = 1_400

        let responseID = ConversationProviderResponseID(
            "response_sustained_user_wait_override"
        )
        provider.simulate(.assistantResponseStarted(responseID: responseID))
        provider.simulate(
            .toolCall(
                ConversationToolCall(
                    callID: ConversationToolCallID("call_wait_override")!,
                    name: "wait_for_user",
                    argumentsJSON: "{}",
                    responseID: responseID
                )
            )
        )

        await waitUntil { provider.toolOutputs.count == 1 }
        XCTAssertTrue(provider.toolOutputs[0].createsResponse)
        XCTAssertTrue(
            provider.toolOutputs[0].output.contains("clarification_required")
        )
        XCTAssertEqual(coordinator.state, .assistantPreparing)
        coordinator.stop()
    }

    func testFocusedInputWriteReturnsReceiptWithoutEndingConversation() async {
        let provider = MockConversationProvider()
        let executor = TalkTestLocalActionExecutor()
        let coordinator = ConversationCoordinator(
            activationMode: .shortcut,
            wakeWordProvider: MockWakeWordService(),
            conversationProvider: provider,
            audioService: WorkTestAudioService(),
            presentation: InputOverlayConversationPresenter(
                model: InputOverlayModel(),
                controller: nil
            ),
            actionBridge: ConversationActionBridge(executor: executor)
        )

        coordinator.startConversationFromShortcut()
        await waitUntil { provider.isConnected }
        let responseID = ConversationProviderResponseID("response_write_codex")
        provider.simulate(.assistantResponseStarted(responseID: responseID))
        provider.simulate(
            .toolCall(
                ConversationToolCall(
                    callID: ConversationToolCallID("call_write_codex")!,
                    name: ConversationActionBridge.focusedInputWriteToolName,
                    argumentsJSON: #"{"text":"1、2、3、4","application":"Codex"}"#,
                    responseID: responseID
                )
            )
        )
        provider.simulate(.responseCompleted(responseID: responseID, usage: .zero))

        XCTAssertEqual(coordinator.state, .assistantPreparing)

        await waitUntil { provider.toolOutputs.count == 1 }

        XCTAssertEqual(executor.proposals.count, 1)
        XCTAssertEqual(executor.proposals[0].target, "Codex")
        XCTAssertTrue(provider.toolOutputs[0].output.contains(#""status":"succeeded""#))
        XCTAssertTrue(provider.toolOutputs[0].createsResponse)
        XCTAssertEqual(coordinator.state, .assistantPreparing)
        XCTAssertTrue(provider.isConnected)
        XCTAssertTrue(coordinator.isConversationActive)
        coordinator.stop()
    }

    func testPlaybackFinishingBeforeToolResolutionKeepsAssistantPreparing() async {
        let provider = MockConversationProvider()
        let executor = ControlledTalkTestLocalActionExecutor()
        let audioService = WorkTestAudioService()
        let coordinator = ConversationCoordinator(
            activationMode: .shortcut,
            wakeWordProvider: MockWakeWordService(),
            conversationProvider: provider,
            audioService: audioService,
            presentation: InputOverlayConversationPresenter(
                model: InputOverlayModel(),
                controller: nil
            ),
            actionBridge: ConversationActionBridge(executor: executor)
        )

        coordinator.startConversationFromShortcut()
        await waitUntil { provider.isConnected }

        let responseID = ConversationProviderResponseID("response_audio_and_tool")
        let identity = ConversationProviderEventIdentity(
            responseID: responseID,
            itemID: ConversationProviderItemID("item_audio_and_tool")
        )
        provider.simulate(.assistantResponseStarted(responseID: responseID))
        provider.simulate(.assistantItemStarted(identity))
        provider.simulate(.assistantAudio(identity: identity, data: Data([0, 0])))
        provider.simulate(
            .toolCall(
                ConversationToolCall(
                    callID: ConversationToolCallID("call_audio_and_tool")!,
                    name: ConversationActionBridge.focusedInputWriteToolName,
                    argumentsJSON: #"{"text":"测试"}"#,
                    responseID: responseID
                )
            )
        )
        provider.simulate(.responseCompleted(responseID: responseID, usage: .zero))

        XCTAssertEqual(coordinator.state, .assistantSpeaking)
        audioService.onPlaybackFinished?()
        XCTAssertEqual(coordinator.state, .assistantPreparing)

        executor.resolve()
        await waitUntil { provider.toolOutputs.count == 1 }

        XCTAssertEqual(coordinator.state, .assistantPreparing)
        XCTAssertTrue(provider.toolOutputs[0].createsResponse)
        XCTAssertTrue(coordinator.isConversationActive)

        let followUpResponseID = ConversationProviderResponseID(
            "response_after_audio_and_tool"
        )
        provider.simulate(.assistantResponseStarted(responseID: followUpResponseID))
        provider.simulate(
            .responseCompleted(responseID: followUpResponseID, usage: .zero)
        )
        XCTAssertEqual(coordinator.state, .listening)
        coordinator.stop()
    }

    func testPlaybackFinishingBeforeResponseCompletionReturnsToListening() async {
        let provider = MockConversationProvider()
        let audioService = WorkTestAudioService()
        let coordinator = ConversationCoordinator(
            activationMode: .shortcut,
            wakeWordProvider: MockWakeWordService(),
            conversationProvider: provider,
            audioService: audioService,
            presentation: InputOverlayConversationPresenter(
                model: InputOverlayModel(),
                controller: nil
            )
        )

        coordinator.startConversationFromShortcut()
        await waitUntil { provider.isConnected }

        let responseID = ConversationProviderResponseID("response_audio_first")
        let identity = ConversationProviderEventIdentity(
            responseID: responseID,
            itemID: ConversationProviderItemID("item_audio_first")
        )
        provider.simulate(.assistantResponseStarted(responseID: responseID))
        provider.simulate(.assistantItemStarted(identity))
        provider.simulate(.assistantAudio(identity: identity, data: Data([0, 0])))

        audioService.onPlaybackFinished?()
        XCTAssertEqual(coordinator.state, .assistantPreparing)

        provider.simulate(.responseCompleted(responseID: responseID, usage: .zero))
        XCTAssertEqual(coordinator.state, .listening)
        XCTAssertTrue(coordinator.isConversationActive)
        coordinator.stop()
    }

    func testCompletedWorkWaitsForUserAndRetriesAfterInterruption() async throws {
        let provider = MockConversationProvider(allowsResponseInterruption: true)
        let workService = ControlledWorkService()
        let audioService = WorkTestAudioService()
        let coordinator = makeWorkCoordinator(
            provider: provider,
            workService: workService,
            audioService: audioService
        )

        coordinator.startConversationFromShortcut()
        await waitUntil { provider.isConnected }
        await submitWork(
            callID: "call_interruptible_work",
            objective: "验证结果交付不会抢话",
            provider: provider
        )

        let busyUserItemID = try XCTUnwrap(
            ConversationProviderItemID("user_busy_during_work_completion")
        )
        provider.simulate(.userSpeechStarted(itemID: busyUserItemID))
        workService.complete()
        await waitUntil { coordinator.latestWork?.state == .completed }
        try await Task.sleep(for: .milliseconds(350))

        XCTAssertEqual(provider.completedWorkResults.count, 0)
        XCTAssertEqual(coordinator.state, .userSpeaking)

        finishUserTurn(
            itemID: busyUserItemID,
            responseID: "response_busy_user",
            provider: provider
        )
        await waitUntil { provider.completedWorkResults.count == 1 }

        let deliveryResponseID = try XCTUnwrap(
            ConversationProviderResponseID("response_work_delivery")
        )
        provider.simulate(.assistantResponseStarted(responseID: deliveryResponseID))
        let interruptingUserItemID = try XCTUnwrap(
            ConversationProviderItemID("user_interrupts_work_delivery")
        )
        audioService.hasConfirmedInterruption = true
        provider.simulate(.userSpeechStarted(itemID: interruptingUserItemID))
        provider.simulate(.responseCancelled(responseID: deliveryResponseID))

        XCTAssertEqual(provider.assistantCancellationCount, 1)
        XCTAssertEqual(coordinator.state, .userSpeaking)

        finishUserTurn(
            itemID: interruptingUserItemID,
            responseID: "response_after_interruption",
            provider: provider
        )
        await waitUntil { provider.completedWorkResults.count == 2 }

        XCTAssertTrue(provider.isConnected)
        XCTAssertTrue(coordinator.isConversationActive)
        coordinator.stop()
    }

    private func makeWorkCoordinator(
        provider: MockConversationProvider,
        workService: ControlledWorkService,
        audioService: WorkTestAudioService? = nil
    ) -> ConversationCoordinator {
        ConversationCoordinator(
            activationMode: .shortcut,
            wakeWordProvider: MockWakeWordService(),
            conversationProvider: provider,
            audioService: audioService ?? WorkTestAudioService(),
            presentation: InputOverlayConversationPresenter(
                model: InputOverlayModel(),
                controller: nil
            ),
            workBridge: ConversationWorkBridge(service: workService)
        )
    }

    private func makeConversationCoordinator(
        provider: MockConversationProvider,
        audioService: WorkTestAudioService,
        responseGrace: Duration,
        diagnostics: (any ConversationDiagnosticsRecording)? = nil
    ) -> ConversationCoordinator {
        ConversationCoordinator(
            activationMode: .shortcut,
            wakeWordProvider: MockWakeWordService(),
            conversationProvider: provider,
            audioService: audioService,
            presentation: InputOverlayConversationPresenter(
                model: InputOverlayModel(),
                controller: nil
            ),
            diagnostics: diagnostics,
            userTurnResponseGrace: responseGrace
        )
    }

    private func assertDiagnosticAttribute(
        _ attribute: String,
        event: String,
        records: [[String: Any]],
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let record = records.first { $0["event"] as? String == event }
        let attributes = record?["attributes"] as? [String: String]
        XCTAssertNotNil(attributes?[attribute], file: file, line: line)
    }

    private func submitWork(
        callID: String,
        objective: String,
        provider: MockConversationProvider
    ) async {
        let userItemID = ConversationProviderItemID("user_\(callID)")!
        let toolResponseID = ConversationProviderResponseID("response_\(callID)")
        provider.simulate(.userSpeechStarted(itemID: userItemID))
        provider.simulate(.userSpeechStopped(itemID: userItemID))
        provider.simulate(
            .userTranscriptionCompleted(
                ConversationInputTranscription(
                    itemID: userItemID,
                    text: "创建后台测试任务：\(objective)",
                    language: "zh",
                    confidence: nil,
                    usage: nil
                )
            )
        )
        provider.simulate(.assistantResponseStarted(responseID: toolResponseID))
        provider.simulate(
            .toolCall(
                ConversationToolCall(
                    callID: ConversationToolCallID(callID)!,
                    name: "submit_work",
                    argumentsJSON: #"{"objective":"\#(objective)"}"#,
                    responseID: toolResponseID
                )
            )
        )
        provider.simulate(
            .responseCompleted(responseID: toolResponseID, usage: .zero)
        )
        await waitUntil { provider.toolOutputs.count == 1 }
        XCTAssertTrue(
            provider.toolOutputs[0].output.contains(#""status":"awaiting_confirmation""#)
        )

        let acknowledgementResponseID = ConversationProviderResponseID(
            "response_draft_ack_\(callID)"
        )
        provider.simulate(
            .assistantResponseStarted(responseID: acknowledgementResponseID)
        )
        provider.simulate(
            .responseCompleted(responseID: acknowledgementResponseID, usage: .zero)
        )

        let confirmationItemID = ConversationProviderItemID("user_confirm_\(callID)")!
        let confirmationResponseID = ConversationProviderResponseID(
            "response_confirm_\(callID)"
        )
        provider.simulate(.userSpeechStarted(itemID: confirmationItemID))
        provider.simulate(.userSpeechStopped(itemID: confirmationItemID))
        provider.simulate(
            .userTranscriptionCompleted(
                ConversationInputTranscription(
                    itemID: confirmationItemID,
                    text: "确认提交。",
                    language: "zh",
                    confidence: nil,
                    usage: nil
                )
            )
        )
        provider.simulate(.assistantResponseStarted(responseID: confirmationResponseID))
        provider.simulate(
            .toolCall(
                ConversationToolCall(
                    callID: ConversationToolCallID("confirm_\(callID)")!,
                    name: "confirm_work",
                    argumentsJSON: "{}",
                    responseID: confirmationResponseID
                )
            )
        )
        provider.simulate(
            .responseCompleted(responseID: confirmationResponseID, usage: .zero)
        )
        await waitUntil { provider.toolOutputs.count == 2 }

        let submittedResponseID = ConversationProviderResponseID(
            "response_submitted_ack_\(callID)"
        )
        provider.simulate(
            .assistantResponseStarted(responseID: submittedResponseID)
        )
        provider.simulate(
            .responseCompleted(responseID: submittedResponseID, usage: .zero)
        )
    }

    private func finishUserTurn(
        itemID: ConversationProviderItemID,
        responseID: String,
        provider: MockConversationProvider
    ) {
        let providerResponseID = ConversationProviderResponseID(responseID)
        provider.simulate(.userSpeechStopped(itemID: itemID))
        provider.simulate(.assistantResponseStarted(responseID: providerResponseID))
        provider.simulate(
            .responseCompleted(responseID: providerResponseID, usage: .zero)
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

@MainActor
private final class TalkTestLocalActionExecutor: LocalActionExecuting {
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
            observedResult: "目标输入框的文本变化已复验",
            undoToken: "system_undo:test",
            executedAt: Date(),
            error: nil
        )
    }

    func clearSessionTarget() {}
}

@MainActor
private final class ControlledTalkTestLocalActionExecutor: LocalActionExecuting {
    private var isResolved = false

    func lockSessionTarget(_ target: FocusedInputTarget?) {}

    func execute(_ proposal: ActionProposal) async -> ActionReceipt {
        while !isResolved, !Task.isCancelled {
            try? await Task.sleep(for: .milliseconds(10))
        }
        return ActionReceipt(
            id: .make(),
            workID: proposal.workID,
            actionID: proposal.id,
            status: .succeeded,
            targetRevision: "target_test",
            observedResult: "目标输入框的文本变化已复验",
            undoToken: "system_undo:test",
            executedAt: Date(),
            error: nil
        )
    }

    func resolve() {
        isResolved = true
    }

    func clearSessionTarget() {}
}

@MainActor
private final class WorkTestAudioService: ConversationAudioServicing {
    var onInputChunk: ((AudioChunk) -> Void)?
    var onInputLevels: ((ConversationAudioLevels) -> Void)?
    var onInputGateTransition: ((ConversationInputGateTransition) -> Void)?
    var onOutputLevels: ((ConversationAudioLevels) -> Void)?
    var onPlaybackFinished: (() -> Void)?
    var onFailure: ((Error) -> Void)?
    private(set) var isRunning = false
    var hasConfirmedInterruption = false
    var stopAssistantPlaybackResult = 0
    private(set) var stopAssistantPlaybackCount = 0
    private(set) var assistantPreparationCount = 0
    private(set) var completedUserTurnEndpointCount = 0
    private(set) var resetUserInputCount = 0
    private(set) var lastConfiguredEndpointMode: ConversationEndpointMode?
    private(set) var lastAllowsResponseInterruption: Bool?

    func configureInputForwarding(
        endpointMode: ConversationEndpointMode,
        allowsResponseInterruption: Bool
    ) {
        lastConfiguredEndpointMode = endpointMode
        lastAllowsResponseInterruption = allowsResponseInterruption
    }
    func start() async throws { isRunning = true }
    func completeUserTurnEndpoint() { completedUserTurnEndpointCount += 1 }
    func resetUserInput() { resetUserInputCount += 1 }
    func prepareForAssistantResponse() { assistantPreparationCount += 1 }
    func beginAssistantResponse() {}
    func enqueueAssistantAudio(_ data: Data) {}
    func markAssistantAudioFinished() {}
    func stopAssistantPlayback() -> Int {
        stopAssistantPlaybackCount += 1
        return stopAssistantPlaybackResult
    }
    func stop() { isRunning = false }
}

@MainActor
private final class TalkTestScreenRegionCaptureService: ScreenRegionCapturing {
    var isAuthorized = true

    func requestAuthorization() -> Bool { isAuthorized }

    func capture(_ selection: ScreenRegionSelection) async throws -> ConversationImage {
        ConversationImage(
            data: Data([0xFF, 0xD8, 0xFF, 0xD9]),
            mimeType: "image/jpeg",
            pixelWidth: 300,
            pixelHeight: 80
        )
    }

    func openPrivacySettings() {}
}

@MainActor
private final class TalkTestScreenRegionSelectionController: ScreenRegionSelecting {
    var onSelection: ((ScreenRegionSelection) -> Void)?
    var onCancel: (() -> Void)?
    private(set) var isSelecting = false

    func beginSelection() { isSelecting = true }

    func cancelSelection() {
        guard isSelecting else { return }
        isSelecting = false
        onCancel?()
    }

    func complete(_ selection: ScreenRegionSelection) {
        guard isSelecting else { return }
        isSelecting = false
        onSelection?(selection)
    }
}

@MainActor
private final class ControlledWorkService: WorkServicing {
    private let workID = WorkID("work_22222222222222222222222222222222")!
    private var state: WorkState = .running
    private var objective = "测试任务"

    func complete() {
        state = .completed
    }

    func submit(
        objective: String,
        submissionKey: String,
        objectiveSource: String
    ) async throws -> WorkRecord {
        self.objective = objective
        return record()
    }

    func status(for workID: WorkID) async throws -> WorkRecord {
        record()
    }

    func cancel(_ workID: WorkID) async throws -> WorkRecord {
        state = .cancelled
        return record()
    }

    private func record() -> WorkRecord {
        WorkRecord(
            id: workID,
            objective: objective,
            objectiveSource: "model_derived",
            executor: "mock_read_only",
            state: state,
            publicActivity: state == .completed ? "已完成" : "正在执行",
            result: state == .completed
                ? WorkResult(
                    summary: "Agent 主干已完成一次只读验证。",
                    detail: "本次没有访问或修改任何外部内容。"
                )
                : nil,
            error: nil,
            createdAt: "2026-08-02T00:00:00.000Z",
            updatedAt: "2026-08-02T00:00:00.000Z"
        )
    }
}
