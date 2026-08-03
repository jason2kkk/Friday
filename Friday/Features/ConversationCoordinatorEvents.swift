// 功能：处理 Talk Provider 事件、本地动作或后台 Work 工具调用及结果回传。
// 职责：关联用户轮次和模型回复，执行受控插话、播放状态转换、Action/Work 路由、工具回执与完成结果播报。
// 边界：不负责会话启动、音频采集实现、屏幕捕获实现或诊断持久化。

import Foundation
import OSLog

@MainActor
extension ConversationCoordinator {
    func handleConversationEvent(_ event: ConversationEvent) {
        guard isConversationActive else { return }

        switch event {
        case .sessionReady:
            recordDiagnostic("provider.session_ready")
            if state == .connecting {
                state = .listening
                presentation.show(expression: .attentive, source: .microphone)
            }
        case .userSpeechStarted(let providerItemID):
            guard state != .selectingScreenRegion,
                  state != .capturingScreenRegion else { return }
            let interruptedTurn = turnCorrelator.activeTurn
            let hasActivePlayback = turnCorrelator.activePlaybackID != nil
            let requiresLocalConfirmation = hasActivePlayback
                || (state == .assistantPreparing && isProviderResponseOutstanding)
            if requiresLocalConfirmation, !audioService.hasConfirmedInterruption {
                if let providerItemID {
                    suppressedPlaybackSpeechItemIDs.insert(providerItemID)
                }
                logger.notice(
                    "Ignored an unconfirmed speech-start event while an assistant response was active"
                )
                recordDiagnostic(
                    "interruption.rejected",
                    turn: interruptedTurn,
                    providerUserItemID: providerItemID,
                    attributes: [
                        "local_confirmation": "false",
                        "active_playback": String(hasActivePlayback),
                        "response_preparing": String(!hasActivePlayback),
                        "playback_id": turnCorrelator.activePlaybackID?.description ?? "unknown"
                    ]
                )
                return
            }

            let cancelledScheduledTurn = cancelScheduledUserResponse(
                reason: "user_continued_speaking"
            )
            var interruptedPlayback: (
                turn: ConversationTurnCorrelationSnapshot?,
                playedMilliseconds: Int
            )?
            if hasActivePlayback {
                let playedMilliseconds = audioService.stopAssistantPlayback()
                if let interruptedAssistantItemID = interruptedTurn?.providerAssistantItemID {
                    conversationProvider.truncateAssistantResponse(
                        itemID: interruptedAssistantItemID,
                        audioEndMilliseconds: playedMilliseconds
                    )
                }
                let finishedTurn = turnCorrelator.finishActivePlayback(interrupted: true)
                conversationProvider.cancelAssistantResponse()
                isProviderResponseOutstanding = false
                interruptedPlayback = (finishedTurn ?? interruptedTurn, playedMilliseconds)
            } else if state == .assistantPreparing, isProviderResponseOutstanding {
                recordDiagnostic(
                    "response.cancelled_before_playback",
                    turn: interruptedTurn,
                    providerUserItemID: providerItemID,
                    attributes: [
                        "cause": "user_continued_speaking",
                        "active_playback": "false"
                    ]
                )
                if interruptedTurn?.providerResponseID == nil {
                    uncorrelatedCancelledResponseCount += 1
                }
                conversationProvider.cancelAssistantResponse()
                audioService.finishAssistantPreparation(preserveActiveSpeech: true)
                isProviderResponseOutstanding = false
            }

            let previousTurnID = turnCorrelator.activeTurnID
            guard let turn = turnCorrelator.beginUserTurn(providerItemID: providerItemID),
                  turn.turnID == turnCorrelator.activeTurnID,
                  turn.responseState == .awaitingResponse else { return }
            if turn.turnID != previousTurnID {
                responseLoopGuard.recordUserTurn()
                recordDiagnostic(
                    "loop_guard.reset_for_user_turn",
                    turn: turn,
                    providerUserItemID: providerItemID
                )
            }
            var speechAttributes = diagnosticTimeline.recordUserSpeechStarted(
                turnID: turn.turnID
            )
            speechAttributes["active_playback"] = String(hasActivePlayback)
            speechAttributes["continued_after_endpoint"] = String(
                cancelledScheduledTurn != nil
            )
            recordDiagnostic(
                "turn.user_speech_started",
                turn: turn,
                providerUserItemID: providerItemID,
                attributes: speechAttributes
            )
            markUserSpeechDetected()
            idleTimeoutTask?.cancel()
            if let interruptedPlayback {
                logger.info("Confirmed intentional barge-in during assistant response")
                recordDiagnostic(
                    "interruption.confirmed",
                    turn: interruptedPlayback.turn,
                    providerUserItemID: providerItemID,
                    attributes: [
                        "local_confirmation": "true",
                        "active_playback": "true",
                        "interrupting_turn_id": turn.turnID.description,
                        "played_ms": String(interruptedPlayback.playedMilliseconds)
                    ]
                )
                state = .userSpeaking
                presentation.show(expression: .interrupted, source: .microphone)
                scheduleAttentiveExpression()
            } else {
                state = .userSpeaking
                presentation.show(expression: .attentive, source: .microphone)
            }
        case .userSpeechStopped(let providerItemID):
            guard state != .selectingScreenRegion,
                  state != .capturingScreenRegion else { return }
            if let providerItemID,
               suppressedPlaybackSpeechItemIDs.contains(providerItemID) {
                conversationProvider.discardUserAudioItem(providerItemID)
                recordDiagnostic(
                    "turn.suppressed_audio_discarded",
                    providerUserItemID: providerItemID,
                    attributes: [
                        "response_requested": "false",
                        "reason": "unconfirmed_during_playback"
                    ]
                )
                return
            }
            let previousTurnID = turnCorrelator.activeTurnID
            guard let turn = turnCorrelator.beginUserTurn(providerItemID: providerItemID),
                  turn.turnID == turnCorrelator.activeTurnID,
                  turn.responseState == .awaitingResponse else { return }
            if turn.turnID != previousTurnID {
                responseLoopGuard.recordUserTurn()
                recordDiagnostic(
                    "loop_guard.reset_for_user_turn",
                    turn: turn,
                    providerUserItemID: providerItemID
                )
            }
            let stopAttributes = diagnosticTimeline.recordUserSpeechStopped(
                turnID: turn.turnID
            )
            if let rawDuration = stopAttributes["provider_speech_duration_ms"],
               let duration = Int(rawDuration) {
                providerSpeechDurationMillisecondsByTurn[turn.turnID] = duration
            }
            recordDiagnostic(
                "turn.user_speech_stopped",
                turn: turn,
                providerUserItemID: providerItemID,
                attributes: stopAttributes
            )
            turnCorrelator.markActiveTurnAwaitingResponse()
            state = .assistantPreparing
            presentation.show(expression: .awake, source: .idle)
            scheduleUserResponse(for: turn)
        case .userTranscriptionCompleted(let providerTranscript):
            if suppressedPlaybackSpeechItemIDs.remove(providerTranscript.itemID) != nil {
                recordDiagnostic(
                    "provider.user_transcription_suppressed",
                    providerUserItemID: providerTranscript.itemID
                )
                return
            }
            let correlatedTurn = turnCorrelator.snapshot(
                for: providerTranscript.itemID
            ) ?? turnCorrelator.beginUserTurn(providerItemID: providerTranscript.itemID)
            guard let correlatedTurn,
                  correlatedTurn.source == .userSpeech else { return }
            recordDiagnostic(
                "provider.user_transcription_completed",
                turn: correlatedTurn,
                providerUserItemID: providerTranscript.itemID,
                attributes: ["has_text": String(!providerTranscript.text.isEmpty)]
            )
            let text = providerTranscript.text.trimmingCharacters(
                in: .whitespacesAndNewlines
            )
            guard !text.isEmpty else {
                workBridge.markFinalTranscriptUnavailable(for: correlatedTurn.turnID)
                return
            }
            workBridge.recordFinalTranscript(
                FinalUserTranscript(
                    turnID: correlatedTurn.turnID,
                    text: text,
                    source: .realtimeInput,
                    language: providerTranscript.language,
                    confidence: providerTranscript.confidence,
                    completedAt: Date(),
                    usage: providerTranscript.usage
                )
            )
        case .userTranscriptionFailed(let failure):
            if suppressedPlaybackSpeechItemIDs.remove(failure.itemID) != nil {
                recordDiagnostic(
                    "provider.user_transcription_suppressed",
                    providerUserItemID: failure.itemID
                )
                return
            }
            let correlatedTurn = turnCorrelator.snapshot(for: failure.itemID)
                ?? turnCorrelator.beginUserTurn(providerItemID: failure.itemID)
            guard let correlatedTurn,
                  correlatedTurn.source == .userSpeech else { return }
            recordDiagnostic(
                "provider.user_transcription_failed",
                turn: correlatedTurn,
                providerUserItemID: failure.itemID,
                attributes: ["has_error_code": String(failure.code != nil)]
            )
            workBridge.markFinalTranscriptUnavailable(for: correlatedTurn.turnID)
        case .assistantResponseStarted(let providerResponseID):
            if uncorrelatedCancelledResponseCount > 0 {
                uncorrelatedCancelledResponseCount -= 1
                recordDiagnostic(
                    "response.rejected_after_preplayback_cancel",
                    providerResponseID: providerResponseID,
                    attributes: ["active_playback": "false"]
                )
                conversationProvider.cancelAssistantResponse()
                return
            }
            if state == .selectingScreenRegion || state == .capturingScreenRegion {
                recordDiagnostic(
                    "response.rejected_during_screen_selection",
                    providerResponseID: providerResponseID
                )
                conversationProvider.cancelAssistantResponse()
                return
            }
            if state == .userSpeaking {
                recordDiagnostic(
                    "response.rejected_while_user_speaking",
                    providerResponseID: providerResponseID
                )
                conversationProvider.cancelAssistantResponse()
                return
            }
            guard let turn = turnCorrelator.beginResponse(
                providerResponseID: providerResponseID
            ), turn.turnID == turnCorrelator.activeTurnID else { return }
            userResponseRequestTask?.cancel()
            userResponseRequestTask = nil
            pendingResponseTurnID = nil
            recordDiagnostic(
                "assistant.response_correlated",
                turn: turn,
                providerResponseID: providerResponseID
            )
            var responseAttributes = diagnosticTimeline.recordResponseStarted(
                turnID: turn.turnID
            )
            responseAttributes["source"] = turn.source.diagnosticName
            recordDiagnostic(
                "response.started",
                turn: turn,
                providerResponseID: providerResponseID,
                attributes: responseAttributes
            )
            idleTimeoutTask?.cancel()
            isProviderResponseOutstanding = true
            state = .assistantPreparing
            presentation.show(expression: .awake, source: .idle)
        case .assistantItemStarted(let identity):
            guard state != .selectingScreenRegion,
                  state != .capturingScreenRegion else { return }
            guard let turn = turnCorrelator.beginAssistantItem(identity: identity),
                  turn.turnID == turnCorrelator.activeTurnID else { return }
            recordDiagnostic(
                "assistant.item_started",
                turn: turn,
                providerResponseID: identity.responseID,
                providerAssistantItemID: identity.itemID,
                attributes: diagnosticTimeline.recordAssistantItemStarted(
                    turnID: turn.turnID
                )
            )
            audioService.beginAssistantResponse()
        case .assistantAudio(let identity, let data):
            guard state != .selectingScreenRegion,
                  state != .capturingScreenRegion else { return }
            let playbackWasActive = turnCorrelator.activePlaybackID != nil
            guard let turn = turnCorrelator.beginPlayback(identity: identity),
                  turn.turnID == turnCorrelator.activeTurnID else { return }
            if !playbackWasActive {
                recordDiagnostic(
                    "audio.playback_started",
                    turn: turn,
                    providerResponseID: identity.responseID,
                    providerAssistantItemID: identity.itemID,
                    attributes: diagnosticTimeline.recordPlaybackStarted(
                        turnID: turn.turnID
                    )
                )
            }
            state = .assistantSpeaking
            presentation.show(expression: .speaking, source: .assistant)
            audioService.enqueueAssistantAudio(data)
        case .assistantAudioFinished(let identity):
            guard state != .selectingScreenRegion,
                  state != .capturingScreenRegion else { return }
            guard turnCorrelator.snapshot(for: identity)?.turnID
                    == turnCorrelator.activeTurnID else { return }
            let audioFinishedTurn = turnCorrelator.snapshot(for: identity)
            recordDiagnostic(
                "provider.assistant_audio_finished",
                turn: audioFinishedTurn,
                providerResponseID: identity.responseID,
                providerAssistantItemID: identity.itemID,
                attributes: audioFinishedTurn.map {
                    diagnosticTimeline.recordProviderAudioFinished(turnID: $0.turnID)
                } ?? [:]
            )
            audioService.markAssistantAudioFinished()
        case .assistantTranscriptDelta:
            break
        case .toolCall(let call):
            diagnosticTimeline.recordToolCall(call.callID)
            recordDiagnostic(
                "provider.tool_call",
                providerResponseID: call.responseID,
                attributes: [
                    "call_id": call.callID.description,
                    "tool": call.name
                ]
            )
            let sourceTurnID = call.responseID
                .flatMap { turnCorrelator.snapshot(for: $0)?.turnID }
                ?? turnCorrelator.activeTurn?.turnID
            handleToolCall(call, sourceTurnID: sourceTurnID)
        case .responseCompleted(let providerResponseID, let usage):
            let correlatedTurn = turnCorrelator.finishResponse(
                providerResponseID: providerResponseID,
                cancelled: false
            )
            if correlatedTurn?.turnID == turnCorrelator.activeTurnID {
                isProviderResponseOutstanding = false
            }
            var completionAttributes: [String: String] = [
                "total_tokens": String(usage.totalTokens),
                "output_audio_tokens": String(usage.outputAudioTokens)
            ]
            if let correlatedTurn {
                completionAttributes.merge(
                    diagnosticTimeline.responseCompleted(turnID: correlatedTurn.turnID),
                    uniquingKeysWith: { _, new in new }
                )
            }
            recordDiagnostic(
                "provider.response_completed",
                turn: correlatedTurn,
                providerResponseID: providerResponseID,
                attributes: completionAttributes
            )
            if correlatedTurn?.playbackState == .idle,
               state != .userSpeaking,
               state != .selectingScreenRegion,
               state != .capturingScreenRegion {
                audioService.finishAssistantPreparation(preserveActiveSpeech: false)
                state = .listening
                presentation.show(expression: .attentive, source: .microphone)
                scheduleIdleTimeout()
            }
            let update = sessionLedger.record(usage)
            if update.didRecord {
                sessionSnapshot = update.snapshot
                let responseCostMicroUSD = Int(update.responseCostUSD * 1_000_000)
                let sessionCostMicroUSD = Int(update.snapshot.estimatedCostUSD * 1_000_000)
                let sessionID = update.snapshot.id?.description ?? "unknown"
                let turnID = correlatedTurn?.turnID.description ?? "unmatched"
                logger.info(
                    "Talk usage session_id=\(sessionID, privacy: .public) turn_id=\(turnID, privacy: .public) total_tokens=\(usage.totalTokens, privacy: .public) output_audio_tokens=\(usage.outputAudioTokens, privacy: .public) response_cost_micro_usd=\(responseCostMicroUSD, privacy: .public) session_cost_micro_usd=\(sessionCostMicroUSD, privacy: .public)"
                )
                let didTriggerLoopGuard = responseLoopGuard.recordResponse()
                recordDiagnostic(
                    "loop_guard.response_recorded",
                    turn: correlatedTurn,
                    providerResponseID: providerResponseID,
                    attributes: [
                        "consecutive_responses": String(
                            responseLoopGuard.consecutiveResponseCount
                        ),
                        "triggered": String(didTriggerLoopGuard)
                    ]
                )
                if didTriggerLoopGuard {
                    finishConversation(
                        reason: .responseLoopGuard,
                        showToast: "检测到异常连续响应，已自动停止对话",
                        resumeWakeWord: true
                    )
                    return
                }
            }
            deliverNextCompletedWorkIfPossible()
        case .responseCancelled(let providerResponseID):
            let activePlaybackID = turnCorrelator.activePlaybackID
            let correlatedTurn = turnCorrelator.finishResponse(
                providerResponseID: providerResponseID,
                cancelled: true
            )
            if correlatedTurn?.turnID == turnCorrelator.activeTurnID {
                isProviderResponseOutstanding = false
            }
            recordDiagnostic(
                "provider.response_cancelled",
                turn: correlatedTurn,
                providerResponseID: providerResponseID,
                attributes: [
                    "had_active_playback": String(
                        activePlaybackID != nil
                            && correlatedTurn?.playbackID == activePlaybackID
                    )
                ]
            )
            if let presentingWork {
                pendingCompletedWorks.insert(presentingWork, at: 0)
                self.presentingWork = nil
            }
            guard correlatedTurn?.turnID == turnCorrelator.activeTurnID else { return }
            guard state != .selectingScreenRegion,
                  state != .capturingScreenRegion else { return }
            if activePlaybackID != nil,
               correlatedTurn?.playbackID == activePlaybackID {
                _ = audioService.stopAssistantPlayback()
                _ = turnCorrelator.finishActivePlayback(interrupted: true)
            } else {
                audioService.finishAssistantPreparation(
                    preserveActiveSpeech: state == .userSpeaking
                )
            }
            if state != .userSpeaking {
                state = .listening
                presentation.show(expression: .attentive, source: .microphone)
            }
        case .assistantCancellationIgnored(let code):
            recordDiagnostic(
                "response.cancellation_noop",
                attributes: ["code": code ?? "unknown"]
            )
        case .failed(let message):
            let notice = sanitizedServiceMessage(message)
            recordDiagnostic(
                "provider.failed",
                attributes: ["notice": notice]
            )
            finishConversation(
                reason: .providerFailure,
                showToast: notice,
                resumeWakeWord: true
            )
        }
    }

    private func handleToolCall(
        _ call: ConversationToolCall,
        sourceTurnID: ConversationTurnID?
    ) {
        guard handledToolCallIDs.insert(call.callID).inserted else { return }
        if call.name == "wait_for_user" {
            handleSilentWaitToolCall(call, sourceTurnID: sourceTurnID)
            return
        }

        toolCallTasks[call.callID] = Task { [weak self] in
            guard let self else { return }
            let resolution: ConversationToolResolution
            if actionBridge.canResolve(call.name) {
                resolution = await actionBridge.resolve(call)
            } else {
                resolution = await workBridge.resolve(
                    call,
                    sourceTurnID: sourceTurnID
                )
            }
            var resolutionAttributes = diagnosticTimeline.recordToolResolution(call.callID)
            resolutionAttributes["call_id"] = call.callID.description
            resolutionAttributes["tool"] = call.name
            resolutionAttributes["status"] = diagnosticToolStatus(
                from: resolution.output
            )
            recordDiagnostic(
                "tool.resolved",
                providerResponseID: call.responseID,
                attributes: resolutionAttributes
            )
            if let workID = resolution.workToObserve {
                workBridge.observe(workID)
            }
            defer { toolCallTasks.removeValue(forKey: call.callID) }
            guard isConversationActive, isProviderConnected else { return }
            let createsResponse = state != .userSpeaking
                && userResponseRequestTask == nil
                && !isProviderResponseOutstanding
            do {
                if createsResponse {
                    isProviderResponseOutstanding = true
                }
                try await conversationProvider.provideToolOutput(
                    callID: resolution.callID,
                    output: resolution.output,
                    createsResponse: createsResponse
                )
                recordDiagnostic(
                    "tool.output_sent",
                    providerResponseID: call.responseID,
                    attributes: [
                        "call_id": call.callID.description,
                        "tool": call.name,
                        "creates_response": String(createsResponse)
                    ]
                )
            } catch {
                if createsResponse {
                    isProviderResponseOutstanding = false
                }
                recordDiagnostic(
                    "tool.output_failed",
                    providerResponseID: call.responseID,
                    attributes: [
                        "call_id": call.callID.description,
                        "tool": call.name
                    ]
                )
                presentation.showToast(
                    "操作结果暂时无法同步到语音对话",
                    hidesOverlay: false
                )
                if state != .userSpeaking {
                    state = .listening
                    presentation.show(expression: .attentive, source: .microphone)
                    scheduleIdleTimeout()
                }
            }
        }
    }

    private func handleSilentWaitToolCall(
        _ call: ConversationToolCall,
        sourceTurnID: ConversationTurnID?
    ) {
        toolCallTasks[call.callID] = Task { [weak self] in
            guard let self else { return }
            defer { toolCallTasks.removeValue(forKey: call.callID) }
            guard isConversationActive, isProviderConnected else { return }

            let speechDurationMilliseconds = sourceTurnID.flatMap {
                self.providerSpeechDurationMillisecondsByTurn[$0]
            }
            let requiresClarification = (speechDurationMilliseconds ?? 0) >= 700
            let output = requiresClarification
                ? #"{"status":"clarification_required","reason":"sustained_user_speech"}"#
                : #"{"status":"waiting"}"#
            var didSendToolOutput = false

            do {
                try await conversationProvider.provideToolOutput(
                    callID: call.callID,
                    output: output,
                    createsResponse: requiresClarification
                )
                var attributes = diagnosticTimeline.recordToolResolution(call.callID)
                attributes["call_id"] = call.callID.description
                attributes["tool"] = call.name
                attributes["status"] = requiresClarification
                    ? "clarification_required"
                    : "waiting"
                attributes["creates_response"] = String(requiresClarification)
                if let speechDurationMilliseconds {
                    attributes["provider_speech_duration_ms"] = String(
                        speechDurationMilliseconds
                    )
                }
                recordDiagnostic(
                    "tool.output_sent",
                    providerResponseID: call.responseID,
                    attributes: attributes
                )
                didSendToolOutput = true
            } catch {
                logger.warning("Unable to acknowledge wait_for_user tool call")
                recordDiagnostic(
                    "tool.output_failed",
                    providerResponseID: call.responseID,
                    attributes: [
                        "call_id": call.callID.description,
                        "tool": call.name
                    ]
                )
            }

            guard didSendToolOutput else {
                isProviderResponseOutstanding = false
                guard state != .userSpeaking,
                      state != .selectingScreenRegion,
                      state != .capturingScreenRegion else { return }
                state = .listening
                presentation.show(expression: .attentive, source: .microphone)
                scheduleIdleTimeout()
                return
            }

            if requiresClarification {
                isProviderResponseOutstanding = true
                guard state != .userSpeaking,
                      state != .selectingScreenRegion,
                      state != .capturingScreenRegion else { return }
                state = .assistantPreparing
                presentation.show(expression: .uncertain, source: .idle)
                return
            }

            isProviderResponseOutstanding = false
            guard state != .userSpeaking,
                  state != .selectingScreenRegion,
                  state != .capturingScreenRegion else { return }
            state = .listening
            presentation.show(expression: .attentive, source: .microphone)
            scheduleIdleTimeout()
            deliverNextCompletedWorkIfPossible()
        }
    }

    func handleTerminalWork(_ work: WorkRecord) {
        latestWork = work
        switch work.state {
        case .completed:
            guard work.result != nil else {
                presentation.showToast("后台任务已完成，但没有可展示结果", hidesOverlay: false)
                return
            }
            guard isConversationActive, isProviderConnected else {
                presentation.showToast(
                    work.result?.summary ?? "后台任务已完成",
                    hidesOverlay: true
                )
                return
            }
            pendingCompletedWorks.append(work)
            deliverNextCompletedWorkIfPossible()
        case .failed:
            presentation.showToast(
                work.error ?? "后台任务没有完成",
                hidesOverlay: !isConversationActive
            )
        case .cancelled:
            presentation.showToast("后台任务已取消", hidesOverlay: !isConversationActive)
        case .queued, .running:
            break
        }
    }

    func deliverNextCompletedWorkIfPossible() {
        guard workDeliveryTask == nil,
              presentingWork == nil,
              !pendingCompletedWorks.isEmpty,
              isConversationActive,
              isProviderConnected,
              !isProviderResponseOutstanding,
              state == .listening else { return }

        workDeliveryTask = Task { [weak self] in
            guard let self else { return }
            try? await Task.sleep(for: .milliseconds(280))
            guard !Task.isCancelled,
                  isConversationActive,
                  isProviderConnected,
                  !isProviderResponseOutstanding,
                  state == .listening,
                  !pendingCompletedWorks.isEmpty else {
                workDeliveryTask = nil
                return
            }

            let work = pendingCompletedWorks.removeFirst()
            guard let result = work.result else {
                workDeliveryTask = nil
                deliverNextCompletedWorkIfPossible()
                return
            }
            presentingWork = work
            isProviderResponseOutstanding = true
            state = .assistantPreparing
            presentation.show(expression: .awake, source: .idle)
            do {
                try await conversationProvider.presentCompletedWork(
                    "\(result.summary) \(result.detail)"
                )
            } catch {
                presentingWork = nil
                isProviderResponseOutstanding = false
                presentation.showToast(result.summary, hidesOverlay: false)
                state = .listening
                presentation.show(expression: .attentive, source: .microphone)
                scheduleIdleTimeout()
            }
            workDeliveryTask = nil
        }
    }

}
