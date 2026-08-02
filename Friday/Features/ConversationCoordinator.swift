// 功能：编排 Talk 从快捷键或可选唤醒入口到双向语音交流、图片上下文和结束清理的完整用户流程。
// 职责：协调 Provider、全双工音频与 Presentation，管理连接缓冲、开场问候、轮次身份、插话截断、空闲回收、响应循环保护和错误恢复。
// 边界：不直接实现 WebSocket、AVAudioEngine、屏幕截图或窗口绘制，也不持有长期 API Key 和用户内容持久化。

import Foundation
import OSLog

enum ConversationActivationMode {
    case shortcut
    case wakeWord
}

@MainActor
final class ConversationCoordinator: ObservableObject {
    @Published private(set) var state: ConversationState = .dormant
    @Published private(set) var wakeWordState: WakeWordListeningState = .stopped
    @Published private(set) var sessionSnapshot = ConversationSessionSnapshot.idle
    @Published private(set) var latestWork: WorkRecord?

    var turnCount: Int {
        sessionSnapshot.completedResponses
    }

    var totalTokens: Int {
        sessionSnapshot.totalTokens
    }

    var estimatedCostUSD: Double {
        sessionSnapshot.estimatedCostUSD
    }

    var isConversationActive: Bool {
        state.isConversationActive
    }

    var statusText: String {
        state.statusText
    }

    var authorizationState: WakeWordAuthorizationState {
        wakeWordProvider.authorizationState
    }

    var permissionNeedsAttention: Bool {
        activationMode == .wakeWord && authorizationState != .authorized
    }

    var permissionCanRequest: Bool {
        activationMode == .wakeWord && authorizationState == .notDetermined
    }

    var screenCapturePermissionGranted: Bool {
        screenCaptureService.isAuthorized
    }

    private let activationMode: ConversationActivationMode
    private let wakeWordProvider: WakeWordProviding
    private let conversationProvider: ConversationProviding
    private let audioService: any ConversationAudioServicing
    private let screenCaptureService: ScreenRegionCapturing
    private let screenSelectionController: ScreenRegionSelecting
    private let presentation: any ConversationPresenting
    private let workBridge: ConversationWorkBridge
    private let openingGreetingDelay: Duration

    private var isPausedForDictation = false
    private var sessionLedger = ConversationSessionLedger()
    private var responseLoopGuard = ConversationResponseLoopGuard.safety
    private var turnCorrelator = ConversationTurnCorrelator()
    private var conversationTask: Task<Void, Never>?
    private var idleTimeoutTask: Task<Void, Never>?
    private var openingGreetingTask: Task<Void, Never>?
    private var expressionTask: Task<Void, Never>?
    private var screenCaptureTask: Task<Void, Never>?
    private var workDeliveryTask: Task<Void, Never>?
    private var toolCallTasks: [ConversationToolCallID: Task<Void, Never>] = [:]
    private var handledToolCallIDs: Set<ConversationToolCallID> = []
    private var pendingCompletedWorks: [WorkRecord] = []
    private var presentingWork: WorkRecord?
    private var isProviderResponseOutstanding = false
    private var pendingInputChunks: [AudioChunk] = []
    private var pendingInputFrameCount = 0
    private var pendingScreenInputChunks: [AudioChunk] = []
    private var pendingScreenInputFrameCount = 0
    private var isProviderConnected = false
    private var lastLocalVoiceActivityAt: ContinuousClock.Instant?
    private var serverSpeechStoppedAt: ContinuousClock.Instant?
    private var recordedFirstAudioForCurrentTurn = false
    private var openingSpeech = RetainedAudio()
    private var hasDetectedUserSpeech = false
    private var hasRequestedOpeningGreeting = false
    private var isScreenContextAttached = false
    private let clock = ContinuousClock()
    private let logger = Logger(subsystem: "com.example.Friday", category: "TalkMetrics")
    private static let maximumPendingInputFrames = 24_000 * 5

    init(
        activationMode: ConversationActivationMode,
        wakeWordProvider: WakeWordProviding,
        conversationProvider: ConversationProviding,
        audioService: any ConversationAudioServicing,
        screenCaptureService: ScreenRegionCapturing? = nil,
        screenSelectionController: ScreenRegionSelecting? = nil,
        presentation: any ConversationPresenting,
        workBridge: ConversationWorkBridge? = nil,
        openingGreetingDelay: Duration = ConversationLimits.openingGreetingDelay
    ) {
        self.activationMode = activationMode
        self.wakeWordProvider = wakeWordProvider
        self.conversationProvider = conversationProvider
        self.audioService = audioService
        self.screenCaptureService = screenCaptureService ?? ScreenRegionCaptureService()
        self.screenSelectionController = screenSelectionController
            ?? ScreenRegionSelectionController()
        self.presentation = presentation
        self.workBridge = workBridge ?? ConversationWorkBridge()
        self.openingGreetingDelay = openingGreetingDelay
        configureCallbacks()
    }

    func start() {
        if activationMode == .wakeWord {
            resumeWakeMonitoring()
        } else {
            state = .dormant
        }
    }

    func stop() {
        isPausedForDictation = true
        conversationTask?.cancel()
        idleTimeoutTask?.cancel()
        openingGreetingTask?.cancel()
        expressionTask?.cancel()
        screenCaptureTask?.cancel()
        workDeliveryTask?.cancel()
        screenSelectionController.cancelSelection()
        wakeWordProvider.stop()
        conversationProvider.disconnect()
        audioService.stop()
        sessionSnapshot = sessionLedger.endSession()
        turnCorrelator.endSession()
        presentation.hide()
        isProviderResponseOutstanding = false
        state = .dormant
    }

    func pauseForDictation() {
        isPausedForDictation = true
        wakeWordProvider.stop()
        if isConversationActive {
            finishConversation(showToast: nil, resumeWakeWord: false)
        }
    }

    func resumeAfterDictation() {
        isPausedForDictation = false
        if activationMode == .wakeWord {
            resumeWakeMonitoring()
        }
    }

    func requestPermission() {
        guard activationMode == .wakeWord else { return }
        conversationTask?.cancel()
        state = .requestingPermission
        conversationTask = Task { [weak self] in
            guard let self else { return }
            let granted = await wakeWordProvider.requestAuthorization()
            guard !Task.isCancelled else { return }
            if granted {
                resumeWakeMonitoring()
            } else {
                state = .unavailable("需要语音识别权限才能使用 Hey Friday")
            }
        }
    }

    func endConversation() {
        finishConversation(showToast: nil, resumeWakeWord: true)
    }

    func startConversationFromShortcut() {
        guard !isPausedForDictation, !isConversationActive else { return }
        startConversation()
    }

    func beginScreenRegionSelection() {
        guard isConversationActive, isProviderConnected else {
            presentation.showToast("请先开始语音对话", hidesOverlay: true)
            return
        }
        guard !screenSelectionController.isSelecting else { return }
        guard screenCaptureService.isAuthorized
                || screenCaptureService.requestAuthorization() else {
            presentation.showToast("需要屏幕录制权限才能框选内容", hidesOverlay: true)
            screenCaptureService.openPrivacySettings()
            objectWillChange.send()
            return
        }

        idleTimeoutTask?.cancel()
        openingGreetingTask?.cancel()
        if state == .assistantSpeaking || state == .assistantPreparing {
            let playedMilliseconds = audioService.stopAssistantPlayback()
            if let currentAssistantItemID = turnCorrelator.activeTurn?.providerAssistantItemID {
                conversationProvider.truncateAssistantResponse(
                    itemID: currentAssistantItemID,
                    audioEndMilliseconds: playedMilliseconds
                )
            }
            turnCorrelator.finishActivePlayback(interrupted: true)
            conversationProvider.cancelAssistantResponse()
        }
        state = .selectingScreenRegion
        presentation.show(expression: .observing, source: .idle)
        presentation.hide()
        screenSelectionController.beginSelection()
    }

    func requestScreenCapturePermission() {
        if !screenCaptureService.requestAuthorization() {
            screenCaptureService.openPrivacySettings()
        }
        objectWillChange.send()
    }

    func openScreenCaptureSettings() {
        screenCaptureService.openPrivacySettings()
    }

    func cancelScreenRegionSelection() {
        if screenSelectionController.isSelecting {
            screenSelectionController.cancelSelection()
        } else if state == .capturingScreenRegion {
            screenCaptureTask?.cancel()
            screenCaptureTask = nil
            resumeConversationAfterScreenSelection()
        }
    }

    private func configureCallbacks() {
        wakeWordProvider.onDetected = { [weak self] in
            self?.handleWakeWordDetected()
        }
        wakeWordProvider.onStateChanged = { [weak self] newState in
            guard let self else { return }
            wakeWordState = newState
            switch newState {
            case .listening where !isConversationActive:
                state = .waitingForWakeWord
            case .requestingPermission:
                state = .requestingPermission
            case .unavailable(let message):
                state = .unavailable(message)
            case .stopped, .listening:
                break
            }
        }
        conversationProvider.onEvent = { [weak self] event in
            self?.handleConversationEvent(event)
        }
        workBridge.onTerminalWork = { [weak self] work in
            self?.handleTerminalWork(work)
        }
        screenSelectionController.onSelection = { [weak self] selection in
            self?.handleScreenRegionSelection(selection)
        }
        screenSelectionController.onCancel = { [weak self] in
            guard let self, state == .selectingScreenRegion else { return }
            resumeConversationAfterScreenSelection()
        }
        audioService.onInputChunk = { [weak self] chunk in
            self?.handleInputChunk(chunk)
        }
        audioService.onInputLevels = { [weak self] levels in
            guard let self,
                  state == .listening || state == .userSpeaking else { return }
            presentation.updateWaveform(levels, source: .microphone)
        }
        audioService.onOutputLevels = { [weak self] levels in
            guard let self, state == .assistantSpeaking else { return }
            presentation.updateWaveform(levels, source: .assistant)
        }
        audioService.onPlaybackFinished = { [weak self] in
            guard let self, isConversationActive else { return }
            turnCorrelator.finishActivePlayback(interrupted: false)
            presentingWork = nil
            state = .listening
            presentation.show(expression: .awake, source: .idle)
            scheduleIdleTimeout()
            deliverNextCompletedWorkIfPossible()
        }
        audioService.onFailure = { [weak self] error in
            guard let self, isConversationActive else { return }
            finishConversation(
                showToast: userFacingMessage(for: error),
                resumeWakeWord: true
            )
        }
    }

    private func resumeWakeMonitoring() {
        guard activationMode == .wakeWord else {
            return
        }
        guard !isPausedForDictation, !isConversationActive else { return }
        conversationTask?.cancel()
        conversationTask = Task { [weak self] in
            guard let self else { return }
            do {
                try await wakeWordProvider.start()
                guard !Task.isCancelled else { return }
                state = .waitingForWakeWord
            } catch {
                guard !Task.isCancelled else { return }
                let message = (error as? LocalizedError)?.errorDescription
                    ?? "Hey Friday 暂时不可用"
                state = .unavailable(message)
            }
        }
    }

    private func handleWakeWordDetected() {
        guard !isPausedForDictation, !isConversationActive else { return }
        wakeWordProvider.stop()
        startConversation()
    }

    private func startConversation() {
        conversationTask?.cancel()
        idleTimeoutTask?.cancel()
        openingGreetingTask?.cancel()
        expressionTask?.cancel()
        screenCaptureTask?.cancel()
        sessionSnapshot = sessionLedger.beginSession()
        responseLoopGuard.reset()
        if let sessionID = sessionSnapshot.id {
            turnCorrelator.beginSession(sessionID)
        } else {
            turnCorrelator.endSession()
        }
        pendingInputChunks.removeAll(keepingCapacity: true)
        pendingInputFrameCount = 0
        pendingScreenInputChunks.removeAll(keepingCapacity: true)
        pendingScreenInputFrameCount = 0
        isScreenContextAttached = false
        isProviderConnected = false
        lastLocalVoiceActivityAt = nil
        serverSpeechStoppedAt = nil
        recordedFirstAudioForCurrentTurn = false
        openingSpeech.removeAll()
        hasDetectedUserSpeech = false
        hasRequestedOpeningGreeting = false
        handledToolCallIDs.removeAll(keepingCapacity: true)
        isProviderResponseOutstanding = false
        state = .connecting
        presentation.show(expression: .awake, source: .idle)
        scheduleOpeningGreeting()

        conversationTask = Task { [weak self] in
            guard let self else { return }
            do {
                try await audioService.start()
                try Task.checkCancellation()
                try await conversationProvider.connect()
                try Task.checkCancellation()
                isProviderConnected = true
                flushPendingInput()
                state = .listening
                presentation.show(expression: .attentive, source: .microphone)
                scheduleIdleTimeout()
            } catch {
                guard !Task.isCancelled else { return }
                finishConversation(
                    showToast: userFacingMessage(for: error),
                    resumeWakeWord: true
                )
            }
        }
    }

    private func handleConversationEvent(_ event: ConversationEvent) {
        guard isConversationActive else { return }

        switch event {
        case .sessionReady:
            if state == .connecting {
                state = .listening
                presentation.show(expression: .attentive, source: .microphone)
            }
        case .userSpeechStarted(let providerItemID):
            guard state != .selectingScreenRegion,
                  state != .capturingScreenRegion else { return }
            let interruptedAssistantItemID = turnCorrelator.activeTurn?.providerAssistantItemID
            guard let turn = turnCorrelator.beginUserTurn(providerItemID: providerItemID),
                  turn.turnID == turnCorrelator.activeTurnID,
                  turn.responseState == .awaitingResponse else { return }
            markUserSpeechDetected()
            idleTimeoutTask?.cancel()
            let wasAssistantSpeaking = state == .assistantSpeaking
                || state == .assistantPreparing
            if wasAssistantSpeaking {
                let playedMilliseconds = audioService.stopAssistantPlayback()
                if let interruptedAssistantItemID {
                    conversationProvider.truncateAssistantResponse(
                        itemID: interruptedAssistantItemID,
                        audioEndMilliseconds: playedMilliseconds
                    )
                }
                turnCorrelator.finishActivePlayback(interrupted: true)
                conversationProvider.cancelAssistantResponse()
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
            guard let turn = turnCorrelator.beginUserTurn(providerItemID: providerItemID),
                  turn.turnID == turnCorrelator.activeTurnID,
                  turn.responseState == .awaitingResponse else { return }
            turnCorrelator.markActiveTurnAwaitingResponse()
            serverSpeechStoppedAt = clock.now
            recordedFirstAudioForCurrentTurn = false
            state = .assistantPreparing
            presentation.show(expression: .awake, source: .idle)
        case .assistantResponseStarted(let providerResponseID):
            if state == .selectingScreenRegion || state == .capturingScreenRegion {
                conversationProvider.cancelAssistantResponse()
                return
            }
            if state == .userSpeaking {
                conversationProvider.cancelAssistantResponse()
                return
            }
            guard let turn = turnCorrelator.beginResponse(
                providerResponseID: providerResponseID
            ), turn.turnID == turnCorrelator.activeTurnID else { return }
            idleTimeoutTask?.cancel()
            isProviderResponseOutstanding = true
            state = .assistantPreparing
            presentation.show(expression: .awake, source: .idle)
        case .assistantItemStarted(let identity):
            guard state != .selectingScreenRegion,
                  state != .capturingScreenRegion else { return }
            guard let turn = turnCorrelator.beginAssistantItem(identity: identity),
                  turn.turnID == turnCorrelator.activeTurnID else { return }
            audioService.beginAssistantResponse()
        case .assistantAudio(let identity, let data):
            guard state != .selectingScreenRegion,
                  state != .capturingScreenRegion else { return }
            guard let turn = turnCorrelator.beginPlayback(identity: identity),
                  turn.turnID == turnCorrelator.activeTurnID else { return }
            recordFirstAudioLatencyIfNeeded()
            state = .assistantSpeaking
            presentation.show(expression: .speaking, source: .assistant)
            audioService.enqueueAssistantAudio(data)
        case .assistantAudioFinished(let identity):
            guard state != .selectingScreenRegion,
                  state != .capturingScreenRegion else { return }
            guard turnCorrelator.snapshot(for: identity)?.turnID
                    == turnCorrelator.activeTurnID else { return }
            audioService.markAssistantAudioFinished()
        case .assistantTranscriptDelta:
            break
        case .toolCall(let call):
            handleToolCall(call)
        case .responseCompleted(let providerResponseID, let usage):
            let correlatedTurn = turnCorrelator.finishResponse(
                providerResponseID: providerResponseID,
                cancelled: false
            )
            isProviderResponseOutstanding = false
            if correlatedTurn?.playbackState == .idle,
               state != .userSpeaking,
               state != .selectingScreenRegion,
               state != .capturingScreenRegion {
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
                if responseLoopGuard.recordResponse() {
                    finishConversation(
                        showToast: "检测到异常连续响应，已自动停止对话",
                        resumeWakeWord: true
                    )
                    return
                }
            }
            deliverNextCompletedWorkIfPossible()
        case .responseCancelled(let providerResponseID):
            let correlatedTurn = turnCorrelator.finishResponse(
                providerResponseID: providerResponseID,
                cancelled: true
            )
            isProviderResponseOutstanding = false
            if let presentingWork {
                pendingCompletedWorks.insert(presentingWork, at: 0)
                self.presentingWork = nil
            }
            guard correlatedTurn?.turnID == turnCorrelator.activeTurnID else { return }
            guard state != .selectingScreenRegion,
                  state != .capturingScreenRegion else { return }
            if state == .assistantSpeaking || state == .assistantPreparing {
                let playedMilliseconds = audioService.stopAssistantPlayback()
                if let currentAssistantItemID = turnCorrelator.activeTurn?.providerAssistantItemID {
                    conversationProvider.truncateAssistantResponse(
                        itemID: currentAssistantItemID,
                        audioEndMilliseconds: playedMilliseconds
                    )
                }
                turnCorrelator.finishActivePlayback(interrupted: true)
            }
            if state != .userSpeaking {
                state = .listening
                presentation.show(expression: .attentive, source: .microphone)
            }
        case .failed(let message):
            finishConversation(
                showToast: sanitizedServiceMessage(message),
                resumeWakeWord: true
            )
        }
    }

    private func handleToolCall(_ call: ConversationToolCall) {
        guard handledToolCallIDs.insert(call.callID).inserted else { return }
        toolCallTasks[call.callID] = Task { [weak self] in
            guard let self else { return }
            let resolution = await workBridge.resolve(call)
            if let workID = resolution.workToObserve {
                workBridge.observe(workID)
            }
            defer { toolCallTasks.removeValue(forKey: call.callID) }
            guard isConversationActive, isProviderConnected else { return }
            do {
                isProviderResponseOutstanding = true
                try await conversationProvider.provideToolOutput(
                    callID: resolution.callID,
                    output: resolution.output
                )
            } catch {
                isProviderResponseOutstanding = false
                presentation.showToast(
                    "任务状态已保留，但语音确认没有发出",
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

    private func handleTerminalWork(_ work: WorkRecord) {
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

    private func deliverNextCompletedWorkIfPossible() {
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

    private func handleInputChunk(_ chunk: AudioChunk) {
        guard isConversationActive else { return }
        guard state != .selectingScreenRegion else { return }
        if state == .capturingScreenRegion {
            pendingScreenInputChunks.append(chunk)
            pendingScreenInputFrameCount += chunk.frameCount
            while pendingScreenInputFrameCount > Self.maximumPendingInputFrames,
                  !pendingScreenInputChunks.isEmpty {
                pendingScreenInputFrameCount -= pendingScreenInputChunks.removeFirst().frameCount
            }
            return
        }
        if !hasDetectedUserSpeech, !hasRequestedOpeningGreeting {
            openingSpeech.append(chunk)
            if openingSpeech.hasLikelySpeech {
                markUserSpeechDetected()
            }
        }
        if RetainedAudio.isSpeechLevel(chunk.normalizedLevel) {
            lastLocalVoiceActivityAt = clock.now
        }
        if !isProviderConnected {
            pendingInputChunks.append(chunk)
            pendingInputFrameCount += chunk.frameCount
            while pendingInputFrameCount > Self.maximumPendingInputFrames,
                  !pendingInputChunks.isEmpty {
                pendingInputFrameCount -= pendingInputChunks.removeFirst().frameCount
            }
            return
        }
        conversationProvider.append(chunk)
    }

    private func flushPendingInput() {
        for chunk in pendingInputChunks {
            conversationProvider.append(chunk)
        }
        pendingInputChunks.removeAll(keepingCapacity: true)
        pendingInputFrameCount = 0
    }

    private func recordFirstAudioLatencyIfNeeded() {
        guard !recordedFirstAudioForCurrentTurn else { return }
        recordedFirstAudioForCurrentTurn = true

        let localMilliseconds = lastLocalVoiceActivityAt.map {
            Self.milliseconds($0.duration(to: clock.now))
        } ?? -1
        let serverMilliseconds = serverSpeechStoppedAt.map {
            Self.milliseconds($0.duration(to: clock.now))
        } ?? -1
        logger.info(
            "Talk first-audio latency local_silence_ms=\(localMilliseconds, privacy: .public) server_endpoint_ms=\(serverMilliseconds, privacy: .public)"
        )
    }

    private static func milliseconds(_ duration: Duration) -> Int {
        let components = duration.components
        let seconds = Double(components.seconds)
            + Double(components.attoseconds) / 1_000_000_000_000_000_000
        return Int(max(0, seconds) * 1_000)
    }

    private func scheduleIdleTimeout() {
        idleTimeoutTask?.cancel()
        idleTimeoutTask = Task { [weak self] in
            try? await Task.sleep(for: ConversationLimits.idleTimeout)
            guard !Task.isCancelled else { return }
            self?.finishConversation(showToast: nil, resumeWakeWord: true)
        }
    }

    private func scheduleOpeningGreeting() {
        openingGreetingTask?.cancel()
        guard !hasDetectedUserSpeech, !hasRequestedOpeningGreeting else { return }
        openingGreetingTask = Task { [weak self] in
            guard let self else { return }
            try? await Task.sleep(for: self.openingGreetingDelay)
            while !Task.isCancelled,
                  isConversationActive,
                  !isProviderConnected,
                  !hasDetectedUserSpeech {
                try? await Task.sleep(for: .milliseconds(100))
            }
            guard !Task.isCancelled,
                  isProviderConnected,
                  state == .listening,
                  !hasDetectedUserSpeech,
                  !hasRequestedOpeningGreeting else { return }

            hasRequestedOpeningGreeting = true
            openingGreetingTask = nil
            idleTimeoutTask?.cancel()
            state = .assistantPreparing
            presentation.show(expression: .awake, source: .idle)
            turnCorrelator.beginOpeningGreeting()
            conversationProvider.requestOpeningGreeting()
        }
    }

    private func markUserSpeechDetected() {
        guard !hasDetectedUserSpeech else { return }
        hasDetectedUserSpeech = true
        openingSpeech.removeAll()
        openingGreetingTask?.cancel()
        openingGreetingTask = nil
    }

    private func scheduleAttentiveExpression() {
        expressionTask?.cancel()
        expressionTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(220))
            guard !Task.isCancelled, let self, state == .userSpeaking else { return }
            presentation.show(expression: .attentive, source: .microphone)
        }
    }

    private func finishConversation(showToast: String?, resumeWakeWord: Bool) {
        guard state != .dormant && state != .waitingForWakeWord else {
            if resumeWakeWord { resumeWakeMonitoring() }
            return
        }

        state = .ending
        conversationTask?.cancel()
        conversationTask = nil
        idleTimeoutTask?.cancel()
        idleTimeoutTask = nil
        openingGreetingTask?.cancel()
        openingGreetingTask = nil
        expressionTask?.cancel()
        expressionTask = nil
        screenCaptureTask?.cancel()
        screenCaptureTask = nil
        workDeliveryTask?.cancel()
        workDeliveryTask = nil
        if let presentingWork {
            pendingCompletedWorks.insert(presentingWork, at: 0)
            self.presentingWork = nil
        }
        screenSelectionController.cancelSelection()
        presentation.show(expression: .resting, source: .idle)
        conversationProvider.disconnect()
        audioService.stop()
        sessionSnapshot = sessionLedger.endSession()
        turnCorrelator.endSession()
        isProviderConnected = false
        pendingInputChunks.removeAll(keepingCapacity: false)
        pendingInputFrameCount = 0
        pendingScreenInputChunks.removeAll(keepingCapacity: false)
        pendingScreenInputFrameCount = 0
        isScreenContextAttached = false
        lastLocalVoiceActivityAt = nil
        serverSpeechStoppedAt = nil
        recordedFirstAudioForCurrentTurn = false
        openingSpeech.removeAll()
        hasDetectedUserSpeech = false
        hasRequestedOpeningGreeting = false
        isProviderResponseOutstanding = false

        conversationTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(180))
            guard let self, !Task.isCancelled else { return }
            presentation.hide()
            if let showToast, !showToast.isEmpty {
                presentation.showToast(showToast, hidesOverlay: true)
            }
            state = .dormant
            if resumeWakeWord {
                try? await Task.sleep(for: .milliseconds(320))
                guard !Task.isCancelled else { return }
                resumeWakeMonitoring()
            }
        }
    }

    private func handleScreenRegionSelection(_ selection: ScreenRegionSelection) {
        guard isConversationActive else { return }
        state = .capturingScreenRegion
        presentation.show(expression: .observing, source: .idle)

        screenCaptureTask?.cancel()
        screenCaptureTask = Task { [weak self] in
            guard let self else { return }
            do {
                guard screenCaptureService.isAuthorized
                        || screenCaptureService.requestAuthorization() else {
                    throw ScreenRegionCaptureService.CaptureError.permissionDenied
                }
                try await Task.sleep(for: .milliseconds(80))
                try Task.checkCancellation()
                let image = try await screenCaptureService.capture(selection)
                try Task.checkCancellation()
                try await conversationProvider.setScreenContext(image)
                try Task.checkCancellation()
                screenCaptureTask = nil
                isScreenContextAttached = true
                resumeConversationAfterScreenSelection(flushCapturedAudio: true)
            } catch is CancellationError {
                screenCaptureTask = nil
                resumeConversationAfterScreenSelection()
            } catch {
                screenCaptureTask = nil
                resumeConversationAfterScreenSelection()
                let message = (error as? LocalizedError)?.errorDescription
                    ?? "Friday 暂时无法读取所选区域。"
                presentation.showToast(
                    message,
                    hidesOverlay: false
                )
                if case ScreenRegionCaptureService.CaptureError.permissionDenied = error {
                    screenCaptureService.openPrivacySettings()
                }
            }
        }
    }

    private func resumeConversationAfterScreenSelection(flushCapturedAudio: Bool = false) {
        guard isConversationActive else { return }
        state = .listening
        presentation.show(
            expression: isScreenContextAttached ? .observing : .attentive,
            source: .microphone
        )
        if flushCapturedAudio {
            for chunk in pendingScreenInputChunks {
                conversationProvider.append(chunk)
            }
        }
        pendingScreenInputChunks.removeAll(keepingCapacity: true)
        pendingScreenInputFrameCount = 0
        scheduleIdleTimeout()
    }

    private func userFacingMessage(for error: Error) -> String {
        if let conversationError = error as? RealtimeConversationProvider.ConversationError {
            return conversationError.localizedDescription
        }
        if let audioError = error as? ConversationAudioService.AudioError {
            return audioError.localizedDescription
        }
        if error is URLError {
            return "Friday 语音服务未连接"
        }
        return "Friday 暂时无法开始语音对话"
    }

    private func sanitizedServiceMessage(_ message: String) -> String {
        let lowercased = message.lowercased()
        if lowercased.contains("api key") || lowercased.contains("bearer") {
            return "Friday 语音服务配置不可用"
        }
        return message.isEmpty ? "Friday 语音服务暂时不可用" : message
    }
}
