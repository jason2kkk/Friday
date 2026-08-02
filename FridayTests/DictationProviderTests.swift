// 功能：用零成本自动测试验证 Dictate 主链路及其共享基础组件的确定性行为。
// 职责：覆盖 Mock Provider、输出防护、Realtime 事件解析、状态机、快捷键、音频判定、界面尺寸、屏幕上下文和 Talk 后台 Work 交付等契约。
// 边界：不请求真实系统权限，不采集麦克风或屏幕内容，也不连接 OpenAI 或产生模型费用。

import AppKit
import XCTest
@testable import Friday

@MainActor
private func testConversationPresentation() -> any ConversationPresenting {
    testConversationPresentation(model: InputOverlayModel())
}

@MainActor
private func testConversationPresentation(
    model: InputOverlayModel
) -> any ConversationPresenting {
    InputOverlayConversationPresenter(model: model, controller: nil)
}

@MainActor
final class DictationProviderTests: XCTestCase {
    func testMockProviderReturnsTrimmedStructuredResult() async throws {
        let provider = MockDictationProvider()
        try await provider.begin(
            context: DictationContext(
                targetApplication: "TextEdit",
                targetRole: "AXTextArea",
                mockOutputText: "  Project update.  \n"
            )
        )

        provider.append(
            AudioChunk(
                pcm16: Data(repeating: 0, count: 4_800),
                sampleRate: 24_000,
                channelCount: 1,
                frameCount: 2_400
            )
        )

        let result = try await provider.finish()

        XCTAssertEqual(result.finalText, "Project update.")
        XCTAssertNil(result.rawTranscript)
        XCTAssertFalse(result.hasUncertainty)
        XCTAssertEqual(result.usage, .zero)
    }

    func testMockProviderRejectsEmptyOutput() async throws {
        let provider = MockDictationProvider()
        try await provider.begin(
            context: DictationContext(
                targetApplication: "TextEdit",
                targetRole: "AXTextArea",
                mockOutputText: "   \n"
            )
        )

        do {
            _ = try await provider.finish()
            XCTFail("Expected an empty-output error.")
        } catch let error as MockDictationProvider.MockError {
            guard case .emptyOutput = error else {
                return XCTFail("Expected emptyOutput, received \(error).")
            }
        }
    }

    func testMockProviderCanFailOnceThenSucceedForRecoveryTesting() async throws {
        let provider = MockDictationProvider(failFirstFinish: true)
        let context = DictationContext(
            targetApplication: "TextEdit",
            targetRole: "AXTextArea",
            mockOutputText: "恢复后的文字"
        )

        try await provider.begin(context: context)
        do {
            _ = try await provider.finish()
            XCTFail("Expected the injected first-attempt failure.")
        } catch let error as MockDictationProvider.MockError {
            guard case .injectedFailure = error else {
                return XCTFail("Expected injectedFailure, received \(error).")
            }
        }

        try await provider.begin(context: context)
        let result = try await provider.finish()

        XCTAssertEqual(result.finalText, "恢复后的文字")
    }

    func testRealtimeParserStreamsAndCompletesText() throws {
        var parser = RealtimeEventParser()

        XCTAssertEqual(
            try parser.consume([
                "type": "response.output_text.delta",
                "delta": "项目"
            ]),
            .partial("项目")
        )
        XCTAssertEqual(
            try parser.consume([
                "type": "response.output_text.delta",
                "delta": "将在周五交付。"
            ]),
            .partial("项目将在周五交付。")
        )

        let completed = try parser.consume([
            "type": "response.done",
            "response": [
                "status": "completed",
                "output": [
                    [
                        "content": [
                            ["type": "output_text", "text": "项目将在周五交付。"]
                        ]
                    ]
                ],
                "usage": [
                    "total_tokens": 42,
                    "input_token_details": ["audio_tokens": 30, "text_tokens": 4],
                    "output_token_details": ["text_tokens": 8]
                ]
            ]
        ])

        XCTAssertEqual(
            completed,
            .completed(
                DictationResult(
                    rawTranscript: nil,
                    finalText: "项目将在周五交付。",
                    hasUncertainty: false,
                    usage: DictationUsage(
                        inputTextTokens: 4,
                        inputAudioTokens: 30,
                        outputTextTokens: 8,
                        totalTokens: 42
                    )
                )
            )
        )
    }

    func testRealtimeParserRejectsIncompleteResponse() throws {
        var parser = RealtimeEventParser()

        XCTAssertThrowsError(
            try parser.consume([
                "type": "response.done",
                "response": [
                    "status": "incomplete",
                    "status_details": ["reason": "max_output_tokens"]
                ]
            ])
        ) { error in
            guard case RealtimeDictationProvider.RealtimeError.service(let message) = error else {
                return XCTFail("Expected service error, received \(error).")
            }
            XCTAssertEqual(message, "max_output_tokens")
        }
    }

    func testRealtimeParserRejectsNoSpeechMarker() throws {
        var parser = RealtimeEventParser()

        XCTAssertThrowsError(
            try parser.consume([
                "type": "response.done",
                "response": [
                    "status": "completed",
                    "output": [
                        [
                            "content": [
                                [
                                    "type": "output_text",
                                    "text": DictationPrompt.noSpeechMarker
                                ]
                            ]
                        ]
                    ]
                ]
            ])
        ) { error in
            guard case RealtimeDictationProvider.RealtimeError.noSpeech = error else {
                return XCTFail("Expected noSpeech, received \(error).")
            }
        }
    }

    func testRealtimeParserRecoversSpeechFromConfirmationWrapper() throws {
        var parser = RealtimeEventParser()

        let completed = try parser.consume([
            "type": "response.done",
            "response": [
                "status": "completed",
                "output": [
                    [
                        "content": [
                            [
                                "type": "output_text",
                                "text": "Hey, just wanted to confirm: did you mean to say, “Hey, just wanted to confirm:”? Let me know what comes next."
                            ]
                        ]
                    ]
                ]
            ]
        ])

        guard case .completed(let result) = completed else {
            return XCTFail("Expected a completed result.")
        }
        XCTAssertEqual(result.finalText, "Hey, just wanted to confirm:")
    }

    func testRealtimeParserRejectsAssistantReadinessChatter() throws {
        var parser = RealtimeEventParser()

        XCTAssertThrowsError(
            try parser.consume([
                "type": "response.done",
                "response": [
                    "status": "completed",
                    "output": [
                        [
                            "content": [
                                [
                                    "type": "output_text",
                                    "text": "Sure, please go ahead and start speaking. I'll be ready to transcribe everything accurately."
                                ]
                            ]
                        ]
                    ]
                ]
            ])
        ) { error in
            guard case RealtimeDictationProvider.RealtimeError.noSpeech = error else {
                return XCTFail("Expected noSpeech, received \(error).")
            }
        }
    }

    func testRealtimeParserWaitsForOptionalRawTranscriptAndUsesItAsFallback() throws {
        var parser = RealtimeEventParser(expectsInputTranscript: true)

        let responseProgress = try parser.consume([
            "type": "response.done",
            "response": [
                "status": "completed",
                "output": [
                    [
                        "content": [
                            [
                                "type": "output_text",
                                "text": "Sure, please go ahead and start speaking. I'll be ready to transcribe everything accurately."
                            ]
                        ]
                    ]
                ]
            ]
        ])
        XCTAssertEqual(responseProgress, .ignored)

        let transcriptProgress = try parser.consume([
            "type": "conversation.item.input_audio_transcription.completed",
            "item_id": "item_1",
            "transcript": "项目会在周五交付"
        ])
        guard case .completed(let result) = transcriptProgress else {
            return XCTFail("Expected raw transcript fallback to complete the result.")
        }
        XCTAssertEqual(result.rawTranscript, "项目会在周五交付")
        XCTAssertEqual(result.finalText, "项目会在周五交付")
        XCTAssertTrue(result.hasUncertainty)
    }

    func testRealtimeParserCompletesWhenInputTranscriptionFailsBeforeResponse() throws {
        var parser = RealtimeEventParser(expectsInputTranscript: true)

        let transcriptionProgress = try parser.consume([
            "type": "conversation.item.input_audio_transcription.failed",
            "item_id": "item_1"
        ])
        XCTAssertEqual(transcriptionProgress, .ignored)

        let responseProgress = try parser.consume([
            "type": "response.done",
            "response": [
                "status": "completed",
                "output": [
                    [
                        "content": [
                            ["type": "output_text", "text": "项目会在周五交付。"]
                        ]
                    ]
                ]
            ]
        ])

        guard case .completed(let result) = responseProgress else {
            return XCTFail("Expected the valid model output to complete without a raw transcript.")
        }
        XCTAssertNil(result.rawTranscript)
        XCTAssertEqual(result.finalText, "项目会在周五交付。")
        XCTAssertFalse(result.hasUncertainty)
    }

    func testDeterministicDictationQualityCases() throws {
        let bundle = Bundle(for: type(of: self))
        let url = try XCTUnwrap(
            bundle.url(forResource: "DictationQualityCases", withExtension: "json")
        )
        let cases = try JSONDecoder().decode(
            [DictationQualityCase].self,
            from: Data(contentsOf: url)
        )

        for qualityCase in cases {
            let resolution = DictationPrompt.resolveOutput(
                modelOutput: qualityCase.modelOutput,
                rawTranscript: qualityCase.rawTranscript
            )
            XCTAssertEqual(
                resolution?.text,
                qualityCase.expectedText,
                qualityCase.name
            )
            XCTAssertEqual(
                resolution?.usedRawTranscriptFallback ?? false,
                qualityCase.usedRawTranscriptFallback,
                qualityCase.name
            )
        }
    }

    func testDictationPromptKeepsNoSpeechContract() {
        XCTAssertTrue(DictationPrompt.instructions.contains(DictationPrompt.noSpeechMarker))
        XCTAssertTrue(DictationPrompt.instructions.contains("non-interactive dictation transformer"))
        XCTAssertTrue(DictationPrompt.instructions.contains("Never address the speaker"))
        XCTAssertTrue(
            DictationPrompt.isNoSpeechOutput("  \(DictationPrompt.noSpeechMarker)\n")
        )
        XCTAssertFalse(DictationPrompt.isNoSpeechOutput("这是正常口述内容。"))
        XCTAssertEqual(
            DictationPrompt.sanitizedOutput("Let me know what comes next."),
            "Let me know what comes next."
        )
    }

    func testWorkflowStateDerivesStatusAndActivityFromSingleSource() {
        XCTAssertEqual(DictationWorkflowState.ready.statusText, "已就绪")
        XCTAssertTrue(DictationWorkflowState.ready.isReady)
        XCTAssertFalse(DictationWorkflowState.ready.isWorking)

        let processing = DictationWorkflowState.processing(partialText: "项目更新")
        XCTAssertEqual(processing.statusText, "正在整理文字")
        XCTAssertTrue(processing.isWorking)
        XCTAssertTrue(processing.canCancel)

        let failure = DictationWorkflowState.recoverableFailure("网络暂时不可用")
        XCTAssertEqual(failure.statusText, "网络暂时不可用")
        XCTAssertFalse(failure.isWorking)
    }

    func testRetainedAudioTracksDurationAndClearsMemoryState() {
        var audio = RetainedAudio()
        audio.append(
            AudioChunk(
                pcm16: Data(repeating: 0, count: 48_000),
                sampleRate: 24_000,
                channelCount: 1,
                frameCount: 24_000
            )
        )

        XCTAssertEqual(audio.duration, 1, accuracy: 0.001)
        XCTAssertEqual(audio.frameCount, 24_000)
        XCTAssertFalse(audio.isEmpty)

        audio.removeAll()

        XCTAssertEqual(audio.duration, 0)
        XCTAssertEqual(audio.frameCount, 0)
        XCTAssertTrue(audio.isEmpty)
    }

    func testRetainedAudioRejectsSilenceAndAcceptsBriefSpeech() {
        var silentAudio = RetainedAudio()
        silentAudio.append(
            AudioChunk(
                pcm16: Data(repeating: 0, count: 48_000),
                sampleRate: 24_000,
                channelCount: 1,
                frameCount: 24_000,
                normalizedLevel: 0.12
            )
        )
        XCTAssertFalse(silentAudio.hasLikelySpeech)

        var spokenAudio = RetainedAudio()
        for _ in 0..<4 {
            spokenAudio.append(
                AudioChunk(
                    pcm16: Data(repeating: 1, count: 2_400),
                    sampleRate: 24_000,
                    channelCount: 1,
                    frameCount: 1_200,
                    normalizedLevel: 0.52
                )
            )
        }

        XCTAssertTrue(spokenAudio.hasLikelySpeech)
        XCTAssertEqual(spokenAudio.voicedDuration, 0.2, accuracy: 0.001)
    }

    func testSpeechLevelThresholdAcceptsQuieterVoiceInput() {
        XCTAssertFalse(RetainedAudio.isSpeechLevel(0.17))
        XCTAssertTrue(RetainedAudio.isSpeechLevel(0.18))
    }

    func testWaveformVisualActivityRespondsBeforeModelSpeechGate() {
        XCTAssertFalse(AudioLevelMeter.hasVisualActivity(0.12))
        XCTAssertTrue(AudioLevelMeter.hasVisualActivity(0.13))
        XCTAssertFalse(RetainedAudio.isSpeechLevel(0.13))
    }

    func testAudioLevelMeterBuildsIndependentWaveformSegments() {
        let amplitudes: [Float] = [0.001, 0.003, 0.008, 0.025, 0.07, 0.16, 0.4, 1]
        let samples = amplitudes.flatMap { amplitude in
            Array(repeating: amplitude, count: 128)
        }

        let levels = samples.withUnsafeBufferPointer { buffer in
            AudioLevelMeter.waveformLevels(
                samples: buffer.baseAddress!,
                count: buffer.count
            )
        }

        XCTAssertEqual(levels.count, AudioChunk.waveformLevelCount)
        XCTAssertEqual(Set(levels).count, AudioChunk.waveformLevelCount)
        XCTAssertLessThan(levels.first ?? 1, levels.last ?? 0)
    }

    func testWaveformBarsStayEqualUntilVoiceIsDetected() {
        let heights = IslandWaveformMetrics.barHeights(
            level: 0.24,
            waveformLevels: Array(repeating: 0.24, count: AudioChunk.waveformLevelCount),
            isVoiceActive: false
        )

        XCTAssertEqual(heights.count, AudioChunk.waveformLevelCount)
        XCTAssertTrue(heights.allSatisfy { $0 == IslandWaveformMetrics.idleBarHeight })
    }

    func testWaveformBarsVaryWithActiveVoiceLevel() {
        let heights = IslandWaveformMetrics.barHeights(
            level: 0.72,
            waveformLevels: [0.18, 0.58, 0.26, 0.7, 0.32, 0.62, 0.22, 0.54],
            isVoiceActive: true
        )

        XCTAssertEqual(heights.count, AudioChunk.waveformLevelCount)
        XCTAssertGreaterThan(Set(heights).count, 1)
        XCTAssertGreaterThan(heights.max() ?? 0, heights.min() ?? 0)
        XCTAssertGreaterThan((heights.max() ?? 0) - (heights.min() ?? 0), 4)
        XCTAssertLessThan((heights.max() ?? 0) - (heights.min() ?? 0), 10)
        XCTAssertEqual(IslandWaveformMetrics.barWidth, 2)
        XCTAssertEqual(IslandWaveformMetrics.barSpacing, 2)
        XCTAssertEqual(IslandWaveformMetrics.maximumBarHeight, 16)
        XCTAssertGreaterThanOrEqual(IslandWaveformMetrics.animationDuration, 0.04)
        XCTAssertLessThanOrEqual(IslandWaveformMetrics.animationDuration, 0.05)
        XCTAssertEqual(MicrophoneCaptureService.bufferSize, 1_024)
    }

    func testWaveformBarsKeepSmallPerSegmentDifferencesVisibleButModerated() {
        let heights = IslandWaveformMetrics.barHeights(
            level: 0.52,
            waveformLevels: [0.50, 0.54, 0.51, 0.58, 0.52, 0.56, 0.53, 0.55],
            isVoiceActive: true
        )

        XCTAssertEqual(heights.count, AudioChunk.waveformLevelCount)
        XCTAssertGreaterThan((heights.max() ?? 0) - (heights.min() ?? 0), 2)
        XCTAssertLessThan((heights.max() ?? 0) - (heights.min() ?? 0), 7)
    }

    func testAuthorizedMicrophoneRefreshesAStalePermissionBlocker() {
        XCTAssertTrue(
            AppState.shouldRefreshStaleMicrophonePermission(
                .unavailable(AppState.microphonePermissionRequiredMessage),
                microphonePermissionGranted: true
            )
        )
        XCTAssertFalse(
            AppState.shouldRefreshStaleMicrophonePermission(
                .unavailable(AppState.microphonePermissionRequiredMessage),
                microphonePermissionGranted: false
            )
        )
        XCTAssertFalse(
            AppState.shouldRefreshStaleMicrophonePermission(
                .unavailable("语音服务未连接"),
                microphonePermissionGranted: true
            )
        )
    }

    func testSessionHealthDecodesLocalUsageAndBillingVisibility() throws {
        let data = Data(
            """
            {
              "status": "ok",
              "model": "gpt-realtime",
              "sessions_issued": 97,
              "burst_protection_enabled": true,
              "account_balance_readable": false,
              "billing_status": "blocked",
              "billing_issue_code": "credit_balance_exhausted",
              "input_transcription_enabled": true,
              "input_transcription_model": "gpt-realtime-whisper"
            }
            """.utf8
        )

        let health = try JSONDecoder().decode(SessionServiceHealth.self, from: data)

        XCTAssertEqual(health.model, "gpt-realtime")
        XCTAssertEqual(health.sessionsIssued, 97)
        XCTAssertEqual(health.burstProtectionEnabled, true)
        XCTAssertEqual(health.accountBalanceReadable, false)
        XCTAssertEqual(health.billingStatus, "blocked")
        XCTAssertEqual(health.billingIssueCode, "credit_balance_exhausted")
        XCTAssertEqual(health.inputTranscriptionEnabled, true)
        XCTAssertEqual(health.inputTranscriptionModel, "gpt-realtime-whisper")
        XCTAssertTrue(SessionServiceAvailability.available(health).isAvailable)
    }

    func testInputTargetClassifierRecognizesCommonEditableElements() {
        let nativeTextArea = AccessibilityElementProfile(
            role: "AXTextArea",
            subrole: nil,
            isEnabled: true,
            isExplicitlyEditable: false,
            selectedTextIsSettable: false,
            valueIsSettable: false
        )
        let webEditableContainer = AccessibilityElementProfile(
            role: "AXGroup",
            subrole: nil,
            isEnabled: true,
            isExplicitlyEditable: true,
            selectedTextIsSettable: false,
            valueIsSettable: false
        )

        XCTAssertEqual(InputTargetClassifier.classify(nativeTextArea), .editable)
        XCTAssertEqual(InputTargetClassifier.classify(webEditableContainer), .editable)
    }

    func testInputTargetClassifierRejectsSecureAndNonEditableElements() {
        let secureField = AccessibilityElementProfile(
            role: "AXTextField",
            subrole: "AXSecureTextField",
            isEnabled: true,
            isExplicitlyEditable: true,
            selectedTextIsSettable: true,
            valueIsSettable: true
        )
        let button = AccessibilityElementProfile(
            role: "AXButton",
            subrole: nil,
            isEnabled: true,
            isExplicitlyEditable: false,
            selectedTextIsSettable: false,
            valueIsSettable: false
        )

        XCTAssertEqual(InputTargetClassifier.classify(secureField), .secure)
        XCTAssertEqual(InputTargetClassifier.classify(button), .notEditable)
    }

    func testIslandSizingBalancesContentAroundTheNotchGap() {
        let sizing = InputOverlaySizing.fromScreen(nil)

        XCTAssertEqual(
            sizing.compactSize.width,
            sizing.centerGapWidth + InputOverlaySizing.compactWingWidth * 2,
            accuracy: 0.001
        )
        XCTAssertEqual(InputOverlaySizing.compactWingWidth, 82)
    }

    func testPersistentIslandUsesCompactAndExpandedDashboardSizes() {
        let model = InputOverlayModel()

        model.phase = .idle
        XCTAssertEqual(model.currentSize, model.compactSize)

        model.phase = .result(text: "结果", message: "请复制", canRetry: false)
        model.isDashboardExpanded = true
        XCTAssertEqual(model.currentSize, InputOverlaySizing.expandedSize)
    }

    func testOverlayAtmosphereTracksWorkflowPhase() {
        XCTAssertEqual(
            InputOverlayAtmosphereKind(phase: .hidden),
            .hidden
        )
        XCTAssertEqual(
            InputOverlayAtmosphereKind(phase: .listening),
            .listening
        )
        XCTAssertEqual(
            InputOverlayAtmosphereKind(
                phase: .processing(title: "正在整理文字", detail: nil, canCancel: true)
            ),
            .processing
        )
        XCTAssertEqual(
            InputOverlayAtmosphereKind(phase: .failure("暂时不可用", canRetry: true)),
            .failure
        )
        XCTAssertEqual(
            InputOverlayAtmosphereKind(
                phase: .result(text: "结果", message: "请复制", canRetry: false)
            ),
            .result
        )
        XCTAssertEqual(
            InputOverlayAtmosphereKind(phase: .notice("未收听到声音")),
            .result
        )
        XCTAssertEqual(
            InputOverlayAtmosphereKind(
                phase: .conversation(expression: .attentive, source: .microphone)
            ),
            .conversationListening
        )
        XCTAssertEqual(
            InputOverlayAtmosphereKind(
                phase: .conversation(expression: .speaking, source: .assistant)
            ),
            .conversationSpeaking
        )
        XCTAssertEqual(InputOverlayAtmosphereLayout.sideFraction, 0.18)
        XCTAssertEqual(InputOverlayAtmosphereLayout.centerClearFraction, 0.64)
    }

    func testWakePhraseMatcherRequiresCompleteHeyFridayPhrase() {
        XCTAssertTrue(WakePhraseMatcher.matches("Hey Friday"))
        XCTAssertTrue(WakePhraseMatcher.matches("Could you wake up, hey, Friday?"))
        XCTAssertTrue(WakePhraseMatcher.matches("HEY FRIDAY, are you there?"))
        XCTAssertFalse(WakePhraseMatcher.matches("Friday"))
        XCTAssertFalse(WakePhraseMatcher.matches("Hey there"))
        XCTAssertFalse(WakePhraseMatcher.matches("Friday, hey"))
    }

    func testConversationEventParserTracksSpeechAudioAndUsage() {
        var parser = ConversationEventParser()
        let userItemID = ConversationProviderItemID("user_item_1")
        let responseID = ConversationProviderResponseID("resp_1")
        let assistantItemID = ConversationProviderItemID("assistant_item_1")
        let identity = ConversationProviderEventIdentity(
            responseID: responseID,
            itemID: assistantItemID
        )

        XCTAssertEqual(parser.consume(["type": "session.created"]), [.sessionReady])
        XCTAssertEqual(
            parser.consume([
                "type": "input_audio_buffer.speech_started",
                "item_id": "user_item_1"
            ]),
            [.userSpeechStarted(itemID: userItemID)]
        )
        XCTAssertEqual(
            parser.consume([
                "type": "input_audio_buffer.speech_stopped",
                "item_id": "user_item_1"
            ]),
            [.userSpeechStopped(itemID: userItemID)]
        )
        XCTAssertEqual(
            parser.consume([
                "type": "response.created",
                "response": ["id": "resp_1"]
            ]),
            [.assistantResponseStarted(responseID: responseID)]
        )
        XCTAssertEqual(
            parser.consume([
                "type": "response.output_item.added",
                "response_id": "resp_1",
                "item": ["id": "assistant_item_1"]
            ]),
            [.assistantItemStarted(identity)]
        )

        let audio = Data([0x00, 0x01, 0x02, 0x03])
        XCTAssertEqual(
            parser.consume([
                "type": "response.output_audio.delta",
                "response_id": "resp_1",
                "item_id": "assistant_item_1",
                "delta": audio.base64EncodedString()
            ]),
            [.assistantAudio(identity: identity, data: audio)]
        )
        XCTAssertEqual(
            parser.consume([
                "type": "response.output_audio.done",
                "response_id": "resp_1",
                "item_id": "assistant_item_1"
            ]),
            [.assistantAudioFinished(identity)]
        )

        XCTAssertEqual(
            parser.consume([
                "type": "response.done",
                "response": [
                    "id": "resp_1",
                    "status": "completed",
                    "usage": [
                        "total_tokens": 48,
                        "input_token_details": [
                            "audio_tokens": 30,
                            "text_tokens": 3,
                            "cached_tokens_details": ["audio_tokens": 10, "text_tokens": 2]
                        ],
                        "output_token_details": ["text_tokens": 5, "audio_tokens": 10]
                    ]
                ]
            ]),
            [
                .responseCompleted(
                    responseID: responseID,
                    usage: DictationUsage(
                        inputTextTokens: 3,
                        inputAudioTokens: 30,
                        cachedInputTextTokens: 2,
                        cachedInputAudioTokens: 10,
                        outputTextTokens: 5,
                        outputAudioTokens: 10,
                        totalTokens: 48
                    )
                )
            ]
        )
    }

    func testConversationParserKeepsTalkAliveWhenReplyHitsOutputLimit() {
        var parser = ConversationEventParser()

        XCTAssertEqual(
            parser.consume([
                "type": "response.done",
                "response": [
                    "id": "resp_limited",
                    "status": "incomplete",
                    "status_details": ["reason": "max_output_tokens"],
                    "usage": [
                        "total_tokens": 320,
                        "output_token_details": ["audio_tokens": 280, "text_tokens": 40]
                    ]
                ]
            ]),
            [
                .responseCompleted(
                    responseID: ConversationProviderResponseID("resp_limited"),
                    usage: DictationUsage(
                        outputTextTokens: 40,
                        outputAudioTokens: 280,
                        totalTokens: 320
                    )
                )
            ]
        )
    }

    func testConversationParserEmitsCompletedFunctionCallWithoutAudioItem() {
        var parser = ConversationEventParser()
        let responseID = ConversationProviderResponseID("resp_tool_1")
        let callID = ConversationToolCallID("call_tool_1")

        XCTAssertEqual(
            parser.consume([
                "type": "response.output_item.added",
                "response_id": "resp_tool_1",
                "item": [
                    "id": "item_tool_1",
                    "type": "function_call",
                    "name": "submit_work"
                ]
            ]),
            []
        )

        XCTAssertEqual(
            parser.consume([
                "type": "response.done",
                "response": [
                    "id": "resp_tool_1",
                    "status": "completed",
                    "output": [[
                        "type": "function_call",
                        "name": "submit_work",
                        "call_id": "call_tool_1",
                        "arguments": #"{"objective":"整理当前任务"}"#
                    ]],
                    "usage": ["total_tokens": 24]
                ]
            ]),
            [
                .toolCall(
                    ConversationToolCall(
                        callID: callID!,
                        name: "submit_work",
                        argumentsJSON: #"{"objective":"整理当前任务"}"#,
                        responseID: responseID
                    )
                ),
                .responseCompleted(
                    responseID: responseID,
                    usage: DictationUsage(totalTokens: 24)
                )
            ]
        )
    }

    func testConversationWorkBridgeRoutesSubmitStatusAndCancel() async throws {
        let service = TestWorkService()
        let bridge = ConversationWorkBridge(service: service)

        let submit = await bridge.resolve(
            ConversationToolCall(
                callID: ConversationToolCallID("call_submit")!,
                name: "submit_work",
                argumentsJSON: #"{"objective":"  验证后台任务   不阻塞对话  "}"#,
                responseID: nil
            )
        )
        XCTAssertEqual(service.submittedObjective, "验证后台任务 不阻塞对话")
        XCTAssertEqual(service.submissionKey, "realtime:call_submit")
        XCTAssertEqual(submit.workToObserve, service.workID)
        XCTAssertTrue(submit.output.contains(#""status":"accepted""#))

        let status = await bridge.resolve(
            ConversationToolCall(
                callID: ConversationToolCallID("call_status")!,
                name: "get_work_status",
                argumentsJSON: "{}",
                responseID: nil
            )
        )
        XCTAssertEqual(service.statusRequestIDs, [service.workID])
        XCTAssertTrue(status.output.contains(#""state":"running""#))

        let cancellation = await bridge.resolve(
            ConversationToolCall(
                callID: ConversationToolCallID("call_cancel")!,
                name: "cancel_work",
                argumentsJSON: "{}",
                responseID: nil
            )
        )
        XCTAssertEqual(service.cancelRequestIDs, [service.workID])
        XCTAssertTrue(cancellation.output.contains(#""state":"cancelled""#))
    }

    func testTurnCorrelatorActivatesProviderContinuationAfterToolResponse() {
        var correlator = ConversationTurnCorrelator()
        correlator.beginSession(ConversationSessionID())

        let userTurn = correlator.beginUserTurn(
            providerItemID: ConversationProviderItemID("user_tool_turn")
        )!
        correlator.markActiveTurnAwaitingResponse()
        let toolResponseID = ConversationProviderResponseID("resp_tool")!
        XCTAssertEqual(
            correlator.beginResponse(providerResponseID: toolResponseID)?.turnID,
            userTurn.turnID
        )
        correlator.finishResponse(providerResponseID: toolResponseID, cancelled: false)

        let followUp = correlator.beginResponse(
            providerResponseID: ConversationProviderResponseID("resp_tool_follow_up")
        )!
        XCTAssertEqual(followUp.source, .providerInitiated)
        XCTAssertEqual(correlator.activeTurnID, followUp.turnID)
    }

    func testRealtime21TalkPricingUsesModalityAndCachedRates() {
        let usage = DictationUsage(
            inputTextTokens: 100,
            inputAudioTokens: 100,
            cachedInputTextTokens: 50,
            cachedInputAudioTokens: 20,
            outputTextTokens: 20,
            outputAudioTokens: 40,
            totalTokens: 260
        )

        XCTAssertEqual(
            RealtimeTalkPricing.estimatedCostUSD(for: usage),
            0.005828,
            accuracy: 0.0000001
        )
    }

    func testRealtime21TalkPricingIncludesSelectedScreenImageTokens() {
        let usage = DictationUsage(
            inputImageTokens: 1_000,
            cachedInputImageTokens: 400,
            totalTokens: 1_000
        )

        XCTAssertEqual(
            RealtimeTalkPricing.estimatedCostUSD(for: usage),
            0.0032,
            accuracy: 0.0000001
        )
    }

    func testConversationPCM16MeterProducesVisibleLevels() {
        let samples: [Int16] = (0..<2_400).map { index in
            index.isMultiple(of: 2) ? 16_000 : -16_000
        }
        let data = samples.withUnsafeBytes { Data($0) }

        let levels = ConversationPCM16Meter.levels(for: data)

        XCTAssertGreaterThan(levels.level, 0.1)
        XCTAssertEqual(levels.waveformLevels.count, AudioChunk.waveformLevelCount)
        XCTAssertTrue(levels.waveformLevels.allSatisfy { $0 > 0.1 })
    }

    func testConversationAudioFormatValidatorRejectsUnavailableDevices() {
        XCTAssertFalse(
            ConversationAudioFormatValidator.isUsable(
                sampleRate: 0,
                channelCount: 2
            )
        )
        XCTAssertFalse(
            ConversationAudioFormatValidator.isUsable(
                sampleRate: 48_000,
                channelCount: 0
            )
        )
        XCTAssertTrue(
            ConversationAudioFormatValidator.isUsable(
                sampleRate: 48_000,
                channelCount: 2
            )
        )
    }

    func testRealConversationAudioEngineCanRestartWhenExplicitlyEnabled() async throws {
        guard ProcessInfo.processInfo.environment["FRIDAY_TEST_REAL_AUDIO"] == "1" else {
            throw XCTSkip("Set FRIDAY_TEST_REAL_AUDIO=1 for the real Mac audio check.")
        }

        let audioService = ConversationAudioService()
        let microphoneExpectation = expectation(description: "Microphone produces PCM16 input")
        audioService.onInputChunk = { _ in
            microphoneExpectation.fulfill()
            audioService.onInputChunk = nil
        }
        try await audioService.start()
        XCTAssertTrue(audioService.isRunning)
        await fulfillment(of: [microphoneExpectation], timeout: 2)

        let playbackExpectation = expectation(description: "Assistant audio reaches output")
        audioService.onPlaybackFinished = {
            playbackExpectation.fulfill()
        }
        audioService.beginAssistantResponse()
        audioService.enqueueAssistantAudio(Data(repeating: 0, count: 4_800))
        audioService.markAssistantAudioFinished()
        await fulfillment(of: [playbackExpectation], timeout: 2)
        audioService.stop()
        XCTAssertFalse(audioService.isRunning)

        try await audioService.start()
        XCTAssertTrue(audioService.isRunning)
        try await Task.sleep(for: .milliseconds(250))
        audioService.stop()
        XCTAssertFalse(audioService.isRunning)
    }

    func testTalkStartsLocalAudioBeforeConnectingProviderAndKeepsOpeningSpeech() async {
        let recorder = ConversationLifecycleRecorder()
        let audioService = TestConversationAudioService(recorder: recorder)
        audioService.emitsChunkOnStart = true
        let conversationProvider = TestConversationProvider(recorder: recorder)
        let coordinator = ConversationCoordinator(
            activationMode: .shortcut,
            wakeWordProvider: MockWakeWordService(),
            conversationProvider: conversationProvider,
            audioService: audioService,
            presentation: testConversationPresentation()
        )

        coordinator.start()
        coordinator.startConversationFromShortcut()
        await waitUntil { conversationProvider.isConnected }

        XCTAssertEqual(
            Array(recorder.events.prefix(2)),
            ["audio.start", "provider.connect"]
        )
        XCTAssertEqual(conversationProvider.appendedChunkCount, 1)
        XCTAssertEqual(coordinator.state, .listening)
        coordinator.stop()
    }

    func testTalkPublishesCompleteIslandContentBeforeAsyncStartup() {
        let recorder = ConversationLifecycleRecorder()
        let overlayModel = InputOverlayModel()
        let coordinator = ConversationCoordinator(
            activationMode: .shortcut,
            wakeWordProvider: MockWakeWordService(),
            conversationProvider: TestConversationProvider(recorder: recorder),
            audioService: TestConversationAudioService(recorder: recorder),
            presentation: testConversationPresentation(model: overlayModel)
        )

        coordinator.startConversationFromShortcut()

        XCTAssertEqual(
            overlayModel.phase,
            .conversation(expression: .awake, source: .idle)
        )
        coordinator.stop()
    }

    func testTalkGreetsOnceAfterOpeningSilence() async throws {
        let recorder = ConversationLifecycleRecorder()
        let provider = TestConversationProvider(recorder: recorder)
        let coordinator = ConversationCoordinator(
            activationMode: .shortcut,
            wakeWordProvider: MockWakeWordService(),
            conversationProvider: provider,
            audioService: TestConversationAudioService(recorder: recorder),
            presentation: testConversationPresentation(),
            openingGreetingDelay: .milliseconds(10)
        )

        coordinator.startConversationFromShortcut()
        await waitUntil { coordinator.state == .listening }
        try await Task.sleep(for: .milliseconds(40))

        XCTAssertEqual(provider.openingGreetingRequestCount, 1)
        try await Task.sleep(for: .milliseconds(30))
        XCTAssertEqual(provider.openingGreetingRequestCount, 1)
        coordinator.stop()
    }

    func testTalkCancelsOpeningGreetingAfterLocalSpeech() async throws {
        let recorder = ConversationLifecycleRecorder()
        let audioService = TestConversationAudioService(recorder: recorder)
        let provider = TestConversationProvider(recorder: recorder)
        let coordinator = ConversationCoordinator(
            activationMode: .shortcut,
            wakeWordProvider: MockWakeWordService(),
            conversationProvider: provider,
            audioService: audioService,
            presentation: testConversationPresentation(),
            openingGreetingDelay: .milliseconds(20)
        )

        coordinator.startConversationFromShortcut()
        await waitUntil { coordinator.state == .listening }
        audioService.emitInput(level: 0.32, frameCount: 2_400)
        try await Task.sleep(for: .milliseconds(50))

        XCTAssertEqual(provider.openingGreetingRequestCount, 0)
        coordinator.stop()
    }

    func testTalkSubmitsBackgroundWorkWithoutDisconnectingConversation() async throws {
        let recorder = ConversationLifecycleRecorder()
        let provider = TestConversationProvider(recorder: recorder)
        let workService = TestWorkService()
        let coordinator = ConversationCoordinator(
            activationMode: .shortcut,
            wakeWordProvider: MockWakeWordService(),
            conversationProvider: provider,
            audioService: TestConversationAudioService(recorder: recorder),
            presentation: testConversationPresentation(),
            workBridge: ConversationWorkBridge(service: workService)
        )
        let userItemID = try XCTUnwrap(ConversationProviderItemID("user_work"))
        let toolResponseID = try XCTUnwrap(
            ConversationProviderResponseID("response_work_tool")
        )
        let acknowledgementResponseID = try XCTUnwrap(
            ConversationProviderResponseID("response_work_acknowledgement")
        )

        coordinator.startConversationFromShortcut()
        await waitUntilEventually { provider.isConnected }
        provider.emit(.userSpeechStarted(itemID: userItemID))
        provider.emit(.userSpeechStopped(itemID: userItemID))
        provider.emit(.assistantResponseStarted(responseID: toolResponseID))
        provider.emit(
            .toolCall(
                ConversationToolCall(
                    callID: ConversationToolCallID("call_background_work")!,
                    name: "submit_work",
                    argumentsJSON: #"{"objective":"验证后台任务不阻塞语音对话"}"#,
                    responseID: toolResponseID
                )
            )
        )
        provider.emit(
            .responseCompleted(responseID: toolResponseID, usage: .zero)
        )

        await waitUntilEventually { provider.toolOutputs.count == 1 }
        XCTAssertTrue(provider.isConnected)
        XCTAssertTrue(coordinator.isConversationActive)
        XCTAssertTrue(provider.toolOutputs[0].1.contains(#""status":"accepted""#))

        provider.emit(.assistantResponseStarted(responseID: acknowledgementResponseID))
        provider.emit(
            .responseCompleted(responseID: acknowledgementResponseID, usage: .zero)
        )
        workService.complete()

        await waitUntilEventually { provider.completedWorkResults.count == 1 }
        XCTAssertTrue(provider.isConnected)
        XCTAssertTrue(coordinator.isConversationActive)
        XCTAssertEqual(coordinator.latestWork?.state, .completed)
        XCTAssertTrue(
            provider.completedWorkResults[0].contains("没有访问或修改任何外部内容")
        )
        coordinator.stop()
    }

    func testCompletedWorkWaitsForUserAndRetriesAfterInterruptedDelivery() async throws {
        let recorder = ConversationLifecycleRecorder()
        let audioService = TestConversationAudioService(recorder: recorder)
        let provider = TestConversationProvider(recorder: recorder)
        let workService = TestWorkService()
        let coordinator = ConversationCoordinator(
            activationMode: .shortcut,
            wakeWordProvider: MockWakeWordService(),
            conversationProvider: provider,
            audioService: audioService,
            presentation: testConversationPresentation(),
            workBridge: ConversationWorkBridge(service: workService)
        )
        let firstUserItemID = try XCTUnwrap(
            ConversationProviderItemID("user_submit_work")
        )
        let toolResponseID = try XCTUnwrap(
            ConversationProviderResponseID("response_submit_work")
        )
        let acknowledgementResponseID = try XCTUnwrap(
            ConversationProviderResponseID("response_work_ack")
        )

        coordinator.startConversationFromShortcut()
        await waitUntilEventually { provider.isConnected }
        provider.emit(.userSpeechStarted(itemID: firstUserItemID))
        provider.emit(.userSpeechStopped(itemID: firstUserItemID))
        provider.emit(.assistantResponseStarted(responseID: toolResponseID))
        provider.emit(
            .toolCall(
                ConversationToolCall(
                    callID: ConversationToolCallID("call_interruptible_work")!,
                    name: "submit_work",
                    argumentsJSON: #"{"objective":"验证结果交付不会抢话"}"#,
                    responseID: toolResponseID
                )
            )
        )
        provider.emit(
            .responseCompleted(responseID: toolResponseID, usage: .zero)
        )
        await waitUntilEventually { provider.toolOutputs.count == 1 }
        provider.emit(.assistantResponseStarted(responseID: acknowledgementResponseID))
        provider.emit(
            .responseCompleted(responseID: acknowledgementResponseID, usage: .zero)
        )

        let busyUserItemID = try XCTUnwrap(
            ConversationProviderItemID("user_busy_during_work_completion")
        )
        provider.emit(.userSpeechStarted(itemID: busyUserItemID))
        workService.complete()
        await waitUntilEventually { coordinator.latestWork?.state == .completed }
        try await Task.sleep(for: .milliseconds(350))

        XCTAssertEqual(provider.completedWorkResults.count, 0)
        XCTAssertEqual(coordinator.state, .userSpeaking)

        provider.emit(.userSpeechStopped(itemID: busyUserItemID))
        let busyTurnResponseID = try XCTUnwrap(
            ConversationProviderResponseID("response_busy_user")
        )
        provider.emit(.assistantResponseStarted(responseID: busyTurnResponseID))
        provider.emit(
            .responseCompleted(responseID: busyTurnResponseID, usage: .zero)
        )
        await waitUntilEventually { provider.completedWorkResults.count == 1 }

        let deliveryResponseID = try XCTUnwrap(
            ConversationProviderResponseID("response_work_delivery")
        )
        provider.emit(.assistantResponseStarted(responseID: deliveryResponseID))
        let interruptingUserItemID = try XCTUnwrap(
            ConversationProviderItemID("user_interrupts_work_delivery")
        )
        provider.emit(.userSpeechStarted(itemID: interruptingUserItemID))
        provider.emit(.responseCancelled(responseID: deliveryResponseID))

        XCTAssertEqual(provider.assistantCancellationCount, 1)
        XCTAssertEqual(coordinator.state, .userSpeaking)

        provider.emit(.userSpeechStopped(itemID: interruptingUserItemID))
        let interruptingTurnResponseID = try XCTUnwrap(
            ConversationProviderResponseID("response_after_interruption")
        )
        provider.emit(.assistantResponseStarted(responseID: interruptingTurnResponseID))
        provider.emit(
            .responseCompleted(responseID: interruptingTurnResponseID, usage: .zero)
        )
        await waitUntilEventually { provider.completedWorkResults.count == 2 }

        XCTAssertTrue(provider.isConnected)
        XCTAssertTrue(coordinator.isConversationActive)
        coordinator.stop()
    }

    func testTalkDoesNotPlayLateAudioAfterUserStartsNextTurn() async throws {
        let recorder = ConversationLifecycleRecorder()
        let audioService = TestConversationAudioService(recorder: recorder)
        let provider = TestConversationProvider(recorder: recorder)
        let coordinator = ConversationCoordinator(
            activationMode: .shortcut,
            wakeWordProvider: MockWakeWordService(),
            conversationProvider: provider,
            audioService: audioService,
            presentation: testConversationPresentation()
        )
        let firstUserItemID = try XCTUnwrap(ConversationProviderItemID("user_1"))
        let firstResponseID = try XCTUnwrap(ConversationProviderResponseID("resp_1"))
        let firstAssistantItemID = try XCTUnwrap(
            ConversationProviderItemID("assistant_1")
        )
        let firstIdentity = ConversationProviderEventIdentity(
            responseID: firstResponseID,
            itemID: firstAssistantItemID
        )

        coordinator.startConversationFromShortcut()
        await waitUntil { provider.isConnected }
        provider.emit(.userSpeechStarted(itemID: firstUserItemID))
        provider.emit(.userSpeechStopped(itemID: firstUserItemID))
        provider.emit(.assistantResponseStarted(responseID: firstResponseID))
        provider.emit(.assistantItemStarted(firstIdentity))
        provider.emit(.assistantAudio(identity: firstIdentity, data: Data([0, 1])))
        XCTAssertEqual(audioService.enqueuedAssistantAudioCount, 1)

        provider.emit(
            .userSpeechStarted(
                itemID: ConversationProviderItemID("user_2")
            )
        )
        provider.emit(.assistantAudio(identity: firstIdentity, data: Data([2, 3])))

        XCTAssertEqual(audioService.enqueuedAssistantAudioCount, 1)
        XCTAssertEqual(coordinator.state, .userSpeaking)
        coordinator.stop()
    }

    func testTalkIgnoresOldCancellationWhileCurrentResponseIsPlaying() async throws {
        let recorder = ConversationLifecycleRecorder()
        let audioService = TestConversationAudioService(recorder: recorder)
        let provider = TestConversationProvider(recorder: recorder)
        let coordinator = ConversationCoordinator(
            activationMode: .shortcut,
            wakeWordProvider: MockWakeWordService(),
            conversationProvider: provider,
            audioService: audioService,
            presentation: testConversationPresentation()
        )
        let oldResponseID = try XCTUnwrap(ConversationProviderResponseID("response_old"))
        let oldIdentity = ConversationProviderEventIdentity(
            responseID: oldResponseID,
            itemID: ConversationProviderItemID("assistant_old")
        )
        let currentResponseID = try XCTUnwrap(
            ConversationProviderResponseID("response_current")
        )
        let currentIdentity = ConversationProviderEventIdentity(
            responseID: currentResponseID,
            itemID: ConversationProviderItemID("assistant_current")
        )

        coordinator.startConversationFromShortcut()
        await waitUntil { provider.isConnected }
        provider.emit(.userSpeechStarted(itemID: ConversationProviderItemID("user_old")))
        provider.emit(.userSpeechStopped(itemID: ConversationProviderItemID("user_old")))
        provider.emit(.assistantResponseStarted(responseID: oldResponseID))
        provider.emit(.assistantItemStarted(oldIdentity))
        provider.emit(.assistantAudio(identity: oldIdentity, data: Data([0, 1])))

        provider.emit(.userSpeechStarted(itemID: ConversationProviderItemID("user_current")))
        provider.emit(.userSpeechStopped(itemID: ConversationProviderItemID("user_current")))
        provider.emit(.assistantResponseStarted(responseID: currentResponseID))
        provider.emit(.assistantItemStarted(currentIdentity))
        provider.emit(.assistantAudio(identity: currentIdentity, data: Data([2, 3])))
        let stopCountBeforeOldCancellation = audioService.assistantPlaybackStopCount

        provider.emit(.responseCancelled(responseID: oldResponseID))

        XCTAssertEqual(coordinator.state, .assistantSpeaking)
        XCTAssertEqual(
            audioService.assistantPlaybackStopCount,
            stopCountBeforeOldCancellation
        )
        coordinator.stop()
    }

    func testFnOnlyDictationTriggersOnRelease() {
        var recognizer = ModifierChordRecognizer()

        XCTAssertNil(recognizer.handleFlagsChanged([.function]))
        let action = recognizer.handleFlagsChanged([])
        XCTAssertEqual(action, .dictation)
        XCTAssertTrue(action?.suppressesSystemReleaseEvent == true)
        XCTAssertFalse(GlobalHotKeyAction.conversation.suppressesSystemReleaseEvent)
        XCTAssertFalse(GlobalHotKeyAction.screenRegion.suppressesSystemReleaseEvent)
    }

    func testVoiceAgentChordSupportsBothModifierOrders() {
        var recognizer = ModifierChordRecognizer()

        XCTAssertNil(recognizer.handleFlagsChanged([.control]))
        XCTAssertNil(recognizer.handleFlagsChanged([.control, .option]))
        XCTAssertNil(recognizer.handleFlagsChanged([.control]))
        XCTAssertEqual(recognizer.handleFlagsChanged([]), .conversation)

        XCTAssertNil(recognizer.handleFlagsChanged([.option]))
        XCTAssertNil(recognizer.handleFlagsChanged([.option, .control]))
        XCTAssertNil(recognizer.handleFlagsChanged([.option]))
        XCTAssertEqual(recognizer.handleFlagsChanged([]), .conversation)
    }

    func testModifierOnlyScreenRegionChordTriggersOnRelease() {
        var recognizer = ModifierChordRecognizer()

        XCTAssertNil(recognizer.handleFlagsChanged([.control]))
        XCTAssertNil(recognizer.handleFlagsChanged([.control, .command]))
        XCTAssertNil(recognizer.handleFlagsChanged([.control]))
        XCTAssertEqual(recognizer.handleFlagsChanged([]), .screenRegion)
    }

    func testModifierChordDoesNotStealShortcutContainingRegularKey() {
        var recognizer = ModifierChordRecognizer()

        XCTAssertNil(recognizer.handleFlagsChanged([.function]))
        recognizer.handleKeyDown(modifierFlags: [.function])
        XCTAssertNil(recognizer.handleFlagsChanged([]))

        XCTAssertNil(recognizer.handleFlagsChanged([.control]))
        XCTAssertNil(recognizer.handleFlagsChanged([.control, .option]))
        recognizer.handleKeyDown(modifierFlags: [.control, .option])
        XCTAssertNil(recognizer.handleFlagsChanged([.control]))
        XCTAssertNil(recognizer.handleFlagsChanged([]))
    }

    func testModifierChordDoesNotTriggerAfterAddingThirdModifier() {
        var recognizer = ModifierChordRecognizer()

        XCTAssertNil(recognizer.handleFlagsChanged([.control, .option]))
        XCTAssertNil(recognizer.handleFlagsChanged([.control, .option, .shift]))
        XCTAssertNil(recognizer.handleFlagsChanged([.control, .option]))
        XCTAssertNil(recognizer.handleFlagsChanged([]))
    }

    func testFnDictationDoesNotTriggerAfterAddingAnotherModifier() {
        var recognizer = ModifierChordRecognizer()

        XCTAssertNil(recognizer.handleFlagsChanged([.function]))
        XCTAssertNil(recognizer.handleFlagsChanged([.function, .command]))
        XCTAssertNil(recognizer.handleFlagsChanged([.function]))
        XCTAssertNil(recognizer.handleFlagsChanged([]))
    }

    func testConversationExpressionsUseProductKaomoji() {
        XCTAssertEqual(ConversationExpression.awake.glyph, "^ω^")
        XCTAssertEqual(ConversationExpression.attentive.glyph, "(´▽｀)")
        XCTAssertEqual(ConversationExpression.observing.glyph, "(◉_◉)")
        XCTAssertEqual(ConversationExpression.speaking.glyph, "~_^")
        XCTAssertEqual(ConversationExpression.interrupted.glyph, "-_-#")
        XCTAssertEqual(ConversationExpression.uncertain.glyph, "(・_・?)")
        XCTAssertEqual(ConversationExpression.resting.glyph, "(u_u)")
    }

    func testLocalAudioFailureDoesNotConnectRealtimeProvider() async {
        let recorder = ConversationLifecycleRecorder()
        let audioService = TestConversationAudioService(recorder: recorder)
        audioService.startError = ConversationAudioService.AudioError.unavailableOutput
        let conversationProvider = TestConversationProvider(recorder: recorder)
        let coordinator = ConversationCoordinator(
            activationMode: .shortcut,
            wakeWordProvider: MockWakeWordService(),
            conversationProvider: conversationProvider,
            audioService: audioService,
            presentation: testConversationPresentation()
        )

        coordinator.start()
        coordinator.startConversationFromShortcut()
        await waitUntil { recorder.events.contains("audio.stop") }

        XCTAssertFalse(conversationProvider.isConnected)
        XCTAssertFalse(recorder.events.contains("provider.connect"))
        XCTAssertFalse(audioService.isRunning)
        coordinator.stop()
    }

    func testReadinessResumeDoesNotResetAnActiveShortcutConversation() async {
        let recorder = ConversationLifecycleRecorder()
        let audioService = TestConversationAudioService(recorder: recorder)
        let conversationProvider = TestConversationProvider(recorder: recorder)
        let coordinator = ConversationCoordinator(
            activationMode: .shortcut,
            wakeWordProvider: MockWakeWordService(),
            conversationProvider: conversationProvider,
            audioService: audioService,
            presentation: testConversationPresentation()
        )

        coordinator.start()
        coordinator.startConversationFromShortcut()
        await waitUntil { coordinator.state == .listening }

        coordinator.resumeAfterDictation()

        XCTAssertEqual(coordinator.state, .listening)
        XCTAssertTrue(audioService.isRunning)
        XCTAssertTrue(conversationProvider.isConnected)
        coordinator.stop()
    }

    func testNoticeUsesTheExpandedIslandInsteadOfASeparateToast() {
        let model = InputOverlayModel()
        model.phase = .notice("没有找到可用于播放 Friday 声音的设备。")
        model.isDashboardExpanded = true

        XCTAssertEqual(model.currentSize, InputOverlaySizing.expandedSize)
    }

    func testConversationPhaseUsesCompactIslandWithoutDevelopmentSessionLimits() {
        let model = InputOverlayModel()
        model.phase = .conversation(expression: .awake, source: .idle)

        XCTAssertEqual(model.currentSize, model.compactSize)
        XCTAssertEqual(ConversationResponseLoopGuard.safety.maximumResponses, 10)
        XCTAssertEqual(ConversationResponseLoopGuard.safety.window, 30)
    }

    func testScreenRegionGeometryConvertsAppKitCoordinatesForScreenCaptureKit() {
        let selection = ScreenRegionSelection(
            displayID: 42,
            screenFrame: CGRect(x: 100, y: 50, width: 1_200, height: 800),
            selectedFrame: CGRect(x: 300, y: 500, width: 400, height: 120)
        )

        XCTAssertEqual(
            ScreenRegionGeometry.sourceRect(for: selection),
            CGRect(x: 200, y: 230, width: 400, height: 120)
        )
    }

    func testTalkAttachesSelectedScreenRegionWithoutCreatingAResponse() async {
        let recorder = ConversationLifecycleRecorder()
        let provider = TestConversationProvider(recorder: recorder)
        let captureService = TestScreenRegionCaptureService()
        let selectionController = TestScreenRegionSelectionController()
        let coordinator = ConversationCoordinator(
            activationMode: .shortcut,
            wakeWordProvider: MockWakeWordService(),
            conversationProvider: provider,
            audioService: TestConversationAudioService(recorder: recorder),
            screenCaptureService: captureService,
            screenSelectionController: selectionController,
            presentation: testConversationPresentation()
        )

        coordinator.startConversationFromShortcut()
        await waitUntil { coordinator.state == .listening }
        coordinator.beginScreenRegionSelection()
        XCTAssertEqual(coordinator.state, .selectingScreenRegion)

        selectionController.complete(
            ScreenRegionSelection(
                displayID: 7,
                screenFrame: CGRect(x: 0, y: 0, width: 1_000, height: 800),
                selectedFrame: CGRect(x: 100, y: 200, width: 300, height: 80)
            )
        )
        try? await Task.sleep(for: .milliseconds(140))

        XCTAssertEqual(captureService.captureCount, 1)
        XCTAssertEqual(provider.screenContexts.first?.mimeType, "image/jpeg")
        XCTAssertEqual(coordinator.state, .listening)
        coordinator.stop()
    }

    func testWakeMonitoringDoesNotCreateTalkSessionBeforeDetection() async {
        let wakeProvider = MockWakeWordService()
        let conversationProvider = MockConversationProvider()
        let coordinator = ConversationCoordinator(
            activationMode: .wakeWord,
            wakeWordProvider: wakeProvider,
            conversationProvider: conversationProvider,
            audioService: ConversationAudioService(),
            presentation: testConversationPresentation()
        )

        coordinator.start()
        await Task.yield()

        XCTAssertEqual(coordinator.state, .waitingForWakeWord)
        XCTAssertFalse(conversationProvider.isConnected)
        XCTAssertEqual(conversationProvider.appendedChunkCount, 0)
        coordinator.stop()
    }

    func testShortcutConversationModeDoesNotMonitorMicrophoneWhileIdle() async {
        let wakeProvider = MockWakeWordService()
        let conversationProvider = MockConversationProvider()
        let coordinator = ConversationCoordinator(
            activationMode: .shortcut,
            wakeWordProvider: wakeProvider,
            conversationProvider: conversationProvider,
            audioService: ConversationAudioService(),
            presentation: testConversationPresentation()
        )

        coordinator.start()
        await Task.yield()

        XCTAssertEqual(coordinator.state, .dormant)
        XCTAssertEqual(coordinator.wakeWordState, .stopped)
        XCTAssertFalse(conversationProvider.isConnected)
        coordinator.stop()
    }

    func testExpandedIslandWindowLeavesStableShadowPadding() {
        XCTAssertEqual(
            InputOverlaySizing.windowSize.width,
            InputOverlaySizing.expandedSize.width + InputOverlaySizing.shadowPadding * 2
        )
        XCTAssertEqual(
            InputOverlaySizing.windowSize.height,
            InputOverlaySizing.expandedSize.height + InputOverlaySizing.shadowPadding * 2
        )
    }

    private func waitUntil(
        _ condition: @escaping @MainActor () -> Bool
    ) async {
        for _ in 0..<50 {
            if condition() { return }
            await Task.yield()
        }
    }

    private func waitUntilEventually(
        _ condition: @escaping @MainActor () -> Bool
    ) async {
        for _ in 0..<200 {
            if condition() { return }
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

}

@MainActor
private final class ConversationLifecycleRecorder {
    var events: [String] = []
}

@MainActor
private final class TestConversationAudioService: ConversationAudioServicing {
    var onInputChunk: ((AudioChunk) -> Void)?
    var onInputLevels: ((ConversationAudioLevels) -> Void)?
    var onOutputLevels: ((ConversationAudioLevels) -> Void)?
    var onPlaybackFinished: (() -> Void)?
    var onFailure: ((Error) -> Void)?
    private(set) var isRunning = false
    var startError: Error?
    var emitsChunkOnStart = false
    private(set) var enqueuedAssistantAudioCount = 0
    private(set) var assistantPlaybackStopCount = 0

    private let recorder: ConversationLifecycleRecorder

    init(recorder: ConversationLifecycleRecorder) {
        self.recorder = recorder
    }

    func start() async throws {
        recorder.events.append("audio.start")
        if let startError { throw startError }
        isRunning = true
        if emitsChunkOnStart {
            onInputChunk?(
                AudioChunk(
                    pcm16: Data(repeating: 0, count: 4_800),
                    sampleRate: 24_000,
                    channelCount: 1,
                    frameCount: 2_400
                )
            )
        }
    }

    func beginAssistantResponse() {}
    func enqueueAssistantAudio(_ data: Data) {
        enqueuedAssistantAudioCount += 1
    }
    func markAssistantAudioFinished() {}
    func stopAssistantPlayback() -> Int {
        assistantPlaybackStopCount += 1
        return 0
    }

    func emitInput(level: Float, frameCount: Int) {
        let levels = ConversationAudioLevels(
            level: level,
            waveformLevels: Array(
                repeating: level,
                count: AudioChunk.waveformLevelCount
            )
        )
        onInputChunk?(
            AudioChunk(
                pcm16: Data(repeating: 0, count: frameCount * 2),
                sampleRate: 24_000,
                channelCount: 1,
                frameCount: frameCount,
                normalizedLevel: level,
                waveformLevels: levels.waveformLevels
            )
        )
        onInputLevels?(levels)
    }

    func stop() {
        recorder.events.append("audio.stop")
        isRunning = false
    }
}

@MainActor
private final class TestConversationProvider: ConversationProviding {
    var onEvent: ((ConversationEvent) -> Void)?
    private(set) var isConnected = false
    private(set) var appendedChunkCount = 0
    private(set) var openingGreetingRequestCount = 0
    private(set) var screenContexts: [ConversationImage] = []
    private(set) var toolOutputs: [(ConversationToolCallID, String)] = []
    private(set) var completedWorkResults: [String] = []
    private(set) var assistantCancellationCount = 0

    private let recorder: ConversationLifecycleRecorder

    init(recorder: ConversationLifecycleRecorder) {
        self.recorder = recorder
    }

    func connect() async throws {
        recorder.events.append("provider.connect")
        isConnected = true
        onEvent?(.sessionReady)
    }

    func append(_ chunk: AudioChunk) {
        guard isConnected else { return }
        appendedChunkCount += 1
    }

    func setScreenContext(_ image: ConversationImage) async throws {
        screenContexts.append(image)
    }

    func requestOpeningGreeting() {
        guard isConnected else { return }
        openingGreetingRequestCount += 1
        onEvent?(.assistantResponseStarted(responseID: nil))
    }

    func provideToolOutput(
        callID: ConversationToolCallID,
        output: String
    ) async throws {
        toolOutputs.append((callID, output))
    }

    func presentCompletedWork(_ result: String) async throws {
        completedWorkResults.append(result)
    }

    func cancelAssistantResponse() {
        assistantCancellationCount += 1
    }

    func truncateAssistantResponse(
        itemID: ConversationProviderItemID,
        audioEndMilliseconds: Int
    ) {}

    func disconnect() {
        recorder.events.append("provider.disconnect")
        isConnected = false
    }

    func emit(_ event: ConversationEvent) {
        onEvent?(event)
    }
}

@MainActor
private final class TestScreenRegionCaptureService: ScreenRegionCapturing {
    var isAuthorized = true
    private(set) var captureCount = 0

    func requestAuthorization() -> Bool { isAuthorized }

    func capture(_ selection: ScreenRegionSelection) async throws -> ConversationImage {
        captureCount += 1
        return ConversationImage(
            data: Data([0xFF, 0xD8, 0xFF, 0xD9]),
            mimeType: "image/jpeg",
            pixelWidth: 300,
            pixelHeight: 80
        )
    }

    func openPrivacySettings() {}
}

@MainActor
private final class TestScreenRegionSelectionController: ScreenRegionSelecting {
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
private final class TestWorkService: WorkServicing {
    let workID = WorkID("work_11111111111111111111111111111111")!
    private(set) var submittedObjective: String?
    private(set) var submissionKey: String?
    private(set) var statusRequestIDs: [WorkID] = []
    private(set) var cancelRequestIDs: [WorkID] = []
    private var currentState: WorkState = .running

    func complete() {
        currentState = .completed
    }

    func submit(
        objective: String,
        submissionKey: String,
        objectiveSource: String
    ) async throws -> WorkRecord {
        submittedObjective = objective
        self.submissionKey = submissionKey
        return record(state: .running)
    }

    func status(for workID: WorkID) async throws -> WorkRecord {
        statusRequestIDs.append(workID)
        return record(state: currentState)
    }

    func cancel(_ workID: WorkID) async throws -> WorkRecord {
        cancelRequestIDs.append(workID)
        return record(state: .cancelled)
    }

    private func record(state: WorkState) -> WorkRecord {
        WorkRecord(
            id: workID,
            objective: submittedObjective ?? "测试任务",
            objectiveSource: "model_derived",
            executor: "mock_read_only",
            state: state,
            publicActivity: state == .cancelled
                ? "已取消"
                : state == .completed ? "已完成" : "正在执行",
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

private struct DictationQualityCase: Decodable {
    let name: String
    let modelOutput: String
    let rawTranscript: String?
    let expectedText: String?
    let usedRawTranscriptFallback: Bool
}
