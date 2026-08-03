// 功能：编排 Talk 从快捷键或可选唤醒入口到双向语音交流、图片上下文、诊断和结束清理的完整用户流程。
// 职责：协调可替换 Talk Runtime、Action/Work Bridge、Presentation 与屏幕上下文，管理连接缓冲、轮次身份、端点、插话和错误恢复。
// 边界：不直接实现 WebSocket、AVAudioEngine、屏幕截图或窗口绘制，也不持有长期 API Key，不把用户音频或对话文本写入诊断。

import Foundation
import OSLog

enum ConversationActivationMode {
    case shortcut
    case wakeWord
}
@MainActor
final class ConversationCoordinator: ObservableObject {
    @Published var state: ConversationState = .dormant {
        didSet {
            guard state != oldValue else { return }
            recordDiagnostic(
                "state.changed",
                attributes: [
                    "from": oldValue.diagnosticName,
                    "to": state.diagnosticName
                ]
            )
        }
    }
    @Published private(set) var wakeWordState: WakeWordListeningState = .stopped
    @Published var sessionSnapshot = ConversationSessionSnapshot.idle
    @Published var latestWork: WorkRecord?

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
    let conversationRuntime: any ConversationRuntimeSession
    let conversationProvider: ConversationProviding
    let audioService: any ConversationAudioServicing
    private let screenCaptureService: ScreenRegionCapturing
    private let screenSelectionController: ScreenRegionSelecting
    let presentation: any ConversationPresenting
    let workBridge: ConversationWorkBridge
    let actionBridge: ConversationActionBridge
    let diagnostics: any ConversationDiagnosticsRecording
    private let openingGreetingDelay: Duration
    private let userTurnResponseGrace: Duration

    private var isPausedForDictation = false
    var sessionLedger = ConversationSessionLedger()
    var responseLoopGuard = ConversationResponseLoopGuard.safety
    var turnCorrelator = ConversationTurnCorrelator()
    private var conversationTask: Task<Void, Never>?
    var idleTimeoutTask: Task<Void, Never>?
    private var openingGreetingTask: Task<Void, Never>?
    var userResponseRequestTask: Task<Void, Never>?
    var pendingResponseTurnID: ConversationTurnID?
    private var expressionTask: Task<Void, Never>?
    private var screenCaptureTask: Task<Void, Never>?
    var workDeliveryTask: Task<Void, Never>?
    var toolCallTasks: [ConversationToolCallID: Task<Void, Never>] = [:]
    var handledToolCallIDs: Set<ConversationToolCallID> = []
    var suppressedPlaybackSpeechItemIDs: Set<ConversationProviderItemID> = []
    var pendingCompletedWorks: [WorkRecord] = []
    var presentingWork: WorkRecord?
    var isProviderResponseOutstanding = false
    var uncorrelatedCancelledResponseCount = 0
    private var pendingInputChunks: [AudioChunk] = []
    private var pendingInputFrameCount = 0
    private var pendingScreenInputChunks: [AudioChunk] = []
    private var pendingScreenInputFrameCount = 0
    var isProviderConnected = false
    var diagnosticTimeline = ConversationTurnDiagnosticTimeline()
    var providerSpeechDurationMillisecondsByTurn: [ConversationTurnID: Int] = [:]
    private var openingSpeech = RetainedAudio()
    private var hasDetectedUserSpeech = false
    private var hasRequestedOpeningGreeting = false
    private var isScreenContextAttached = false
    let logger = Logger(subsystem: "com.example.Friday", category: "TalkMetrics")
    private static let maximumPendingInputFrames = 24_000 * 5

    convenience init(
        activationMode: ConversationActivationMode,
        wakeWordProvider: WakeWordProviding,
        conversationProvider: ConversationProviding,
        audioService: any ConversationAudioServicing,
        screenCaptureService: ScreenRegionCapturing? = nil,
        screenSelectionController: ScreenRegionSelecting? = nil,
        presentation: any ConversationPresenting,
        workBridge: ConversationWorkBridge? = nil,
        actionBridge: ConversationActionBridge? = nil,
        diagnostics: (any ConversationDiagnosticsRecording)? = nil,
        openingGreetingDelay: Duration = ConversationLimits.openingGreetingDelay,
        userTurnResponseGrace: Duration = ConversationLimits.userTurnResponseGrace
    ) {
        self.init(
            activationMode: activationMode,
            wakeWordProvider: wakeWordProvider,
            conversationRuntime: DirectRealtimeConversationRuntimeSession(
                conversationProvider: conversationProvider,
                audioService: audioService
            ),
            screenCaptureService: screenCaptureService,
            screenSelectionController: screenSelectionController,
            presentation: presentation,
            workBridge: workBridge,
            actionBridge: actionBridge,
            diagnostics: diagnostics,
            openingGreetingDelay: openingGreetingDelay,
            userTurnResponseGrace: userTurnResponseGrace
        )
    }

    init(
        activationMode: ConversationActivationMode,
        wakeWordProvider: WakeWordProviding,
        conversationRuntime: any ConversationRuntimeSession,
        screenCaptureService: ScreenRegionCapturing? = nil,
        screenSelectionController: ScreenRegionSelecting? = nil,
        presentation: any ConversationPresenting,
        workBridge: ConversationWorkBridge? = nil,
        actionBridge: ConversationActionBridge? = nil,
        diagnostics: (any ConversationDiagnosticsRecording)? = nil,
        openingGreetingDelay: Duration = ConversationLimits.openingGreetingDelay,
        userTurnResponseGrace: Duration = ConversationLimits.userTurnResponseGrace
    ) {
        self.activationMode = activationMode
        self.wakeWordProvider = wakeWordProvider
        self.conversationRuntime = conversationRuntime
        conversationProvider = conversationRuntime.conversationProvider
        audioService = conversationRuntime.audioService
        self.screenCaptureService = screenCaptureService ?? ScreenRegionCaptureService()
        self.screenSelectionController = screenSelectionController
            ?? ScreenRegionSelectionController()
        self.presentation = presentation
        self.workBridge = workBridge ?? ConversationWorkBridge()
        self.actionBridge = actionBridge ?? ConversationActionBridge()
        self.diagnostics = diagnostics ?? NoopConversationDiagnosticsRecorder()
        self.openingGreetingDelay = openingGreetingDelay
        self.userTurnResponseGrace = userTurnResponseGrace
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
        if sessionSnapshot.isActive || state == .ending {
            recordDiagnostic("session.stop_requested")
            diagnostics.finishSession(
                reason: .appStopped,
                state: state.diagnosticName,
                notice: nil
            )
        }
        isPausedForDictation = true
        conversationTask?.cancel()
        idleTimeoutTask?.cancel()
        openingGreetingTask?.cancel()
        userResponseRequestTask?.cancel()
        userResponseRequestTask = nil
        pendingResponseTurnID = nil
        expressionTask?.cancel()
        screenCaptureTask?.cancel()
        workDeliveryTask?.cancel()
        toolCallTasks.values.forEach { $0.cancel() }
        toolCallTasks.removeAll(keepingCapacity: false)
        suppressedPlaybackSpeechItemIDs.removeAll(keepingCapacity: false)
        screenSelectionController.cancelSelection()
        wakeWordProvider.stop()
        conversationRuntime.stop()
        sessionSnapshot = sessionLedger.endSession()
        turnCorrelator.endSession()
        workBridge.endConversationSession()
        actionBridge.endConversationSession()
        presentation.hide()
        isProviderResponseOutstanding = false
        state = .dormant
    }

    func pauseForDictation() {
        isPausedForDictation = true
        wakeWordProvider.stop()
        if isConversationActive {
            finishConversation(
                reason: .dictationStarted,
                showToast: nil,
                resumeWakeWord: false
            )
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
        finishConversation(reason: .userRequested, showToast: nil, resumeWakeWord: true)
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
        cancelScheduledUserResponse(reason: "screen_selection")
        if turnCorrelator.activePlaybackID != nil {
            let interruptedTurn = turnCorrelator.activeTurn
            let playedMilliseconds = audioService.stopAssistantPlayback()
            if let currentAssistantItemID = interruptedTurn?.providerAssistantItemID {
                conversationProvider.truncateAssistantResponse(
                    itemID: currentAssistantItemID,
                    audioEndMilliseconds: playedMilliseconds
                )
            }
            let finishedTurn = turnCorrelator.finishActivePlayback(interrupted: true)
            recordDiagnostic(
                "interruption.confirmed",
                turn: finishedTurn ?? interruptedTurn,
                attributes: [
                    "cause": "screen_selection",
                    "active_playback": "true",
                    "played_ms": String(playedMilliseconds)
                ]
            )
            conversationProvider.cancelAssistantResponse()
            isProviderResponseOutstanding = false
        } else if state == .assistantPreparing, isProviderResponseOutstanding {
            recordDiagnostic(
                "response.cancelled_before_playback",
                attributes: ["cause": "screen_selection"]
            )
            if turnCorrelator.activeTurn?.providerResponseID == nil {
                uncorrelatedCancelledResponseCount += 1
            }
            conversationProvider.cancelAssistantResponse()
            isProviderResponseOutstanding = false
        }
        state = .selectingScreenRegion
        presentation.show(expression: .observing, source: .idle)
        presentation.hide()
        screenSelectionController.beginSelection()
    }

    func requestScreenCapturePermission() {
        if !screenCaptureService.requestAuthorization() { screenCaptureService.openPrivacySettings() }
        objectWillChange.send()
    }

    func openScreenCaptureSettings() { screenCaptureService.openPrivacySettings() }

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
        conversationRuntime.onLifecycleEvent = { [weak self] event in
            self?.recordDiagnostic("runtime.\(event.rawValue)")
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
        audioService.onInputGateTransition = { [weak self] transition in
            guard let self, isConversationActive else { return }
            switch transition {
            case .candidateStarted(let interruption):
                recordDiagnostic(
                    "input_gate.candidate_started",
                    attributes: ["interruption": String(interruption)]
                )
            case .speechConfirmed(let interruption):
                recordDiagnostic(
                    "input_gate.speech_confirmed",
                    attributes: ["interruption": String(interruption)]
                )
            case .speechReleased(let reason):
                recordDiagnostic(
                    "input_gate.speech_released",
                    attributes: [
                        "reason": reason.rawValue,
                        "endpoint_silence_limit_ms": String(
                            ConversationInputGate.maximumEndpointSilenceMilliseconds
                        )
                    ]
                )
            case .endpointSilenceExhausted:
                recordDiagnostic(
                    "input_gate.endpoint_silence_exhausted",
                    attributes: [
                        "endpoint_silence_limit_ms": String(
                            ConversationInputGate.maximumEndpointSilenceMilliseconds
                        )
                    ]
                )
                guard state == .listening || state == .userSpeaking else { return }
                finishConversation(
                    reason: .providerFailure,
                    showToast: "这次语音没有正常结束，请再试一次",
                    resumeWakeWord: true
                )
            }
        }
        audioService.onOutputLevels = { [weak self] levels in
            guard let self, state == .assistantSpeaking else { return }
            presentation.updateWaveform(levels, source: .assistant)
        }
        audioService.onPlaybackFinished = { [weak self] in
            guard let self,
                  isConversationActive,
                  state == .assistantSpeaking || state == .assistantPreparing else { return }
            let completedTurn = turnCorrelator.finishActivePlayback(interrupted: false)
            let playbackAttributes = completedTurn.map {
                self.diagnosticTimeline.recordPlaybackFinished(turnID: $0.turnID)
            } ?? [:]
            recordDiagnostic(
                "audio.playback_finished",
                turn: completedTurn,
                attributes: playbackAttributes.merging(
                    ["interrupted": "false"],
                    uniquingKeysWith: { _, new in new }
                )
            )
            presentingWork = nil
            state = .listening
            presentation.show(expression: .awake, source: .idle)
            scheduleIdleTimeout()
            deliverNextCompletedWorkIfPossible()
        }
        audioService.onFailure = { [weak self] error in
            guard let self, isConversationActive else { return }
            let notice = userFacingMessage(for: error)
            recordDiagnostic(
                "audio.failed",
                attributes: ["notice": notice]
            )
            finishConversation(
                reason: .audioFailure,
                showToast: notice,
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
        startConversation(activation: "wake_word")
    }

    private func startConversation(activation: String = "shortcut") {
        conversationTask?.cancel()
        idleTimeoutTask?.cancel()
        openingGreetingTask?.cancel()
        userResponseRequestTask?.cancel()
        userResponseRequestTask = nil
        expressionTask?.cancel()
        screenCaptureTask?.cancel()
        sessionSnapshot = sessionLedger.beginSession()
        responseLoopGuard.reset()
        if let sessionID = sessionSnapshot.id {
            diagnostics.beginSession(sessionID, state: state.diagnosticName)
            turnCorrelator.beginSession(sessionID)
            workBridge.beginConversationSession()
            actionBridge.beginConversationSession()
            recordDiagnostic(
                "activation.received",
                attributes: ["source": activation]
            )
        } else {
            turnCorrelator.endSession()
            workBridge.endConversationSession()
            actionBridge.endConversationSession()
        }
        pendingInputChunks.removeAll(keepingCapacity: true)
        pendingInputFrameCount = 0
        pendingScreenInputChunks.removeAll(keepingCapacity: true)
        pendingScreenInputFrameCount = 0
        isScreenContextAttached = false
        isProviderConnected = false
        diagnosticTimeline.reset()
        providerSpeechDurationMillisecondsByTurn.removeAll(keepingCapacity: true)
        pendingResponseTurnID = nil
        uncorrelatedCancelledResponseCount = 0
        openingSpeech.removeAll()
        hasDetectedUserSpeech = false
        hasRequestedOpeningGreeting = false
        handledToolCallIDs.removeAll(keepingCapacity: true)
        suppressedPlaybackSpeechItemIDs.removeAll(keepingCapacity: true)
        isProviderResponseOutstanding = false
        state = .connecting
        recordDiagnostic(
            "runtime.selected",
            attributes: [
                "runtime": conversationRuntime.descriptor.kind.rawValue,
                "audio_owner": conversationRuntime.descriptor.audioOwner.rawValue,
                "recording": conversationRuntime.descriptor.recordingPolicy.rawValue
            ]
        )
        recordDiagnostic(
            "presentation.show_requested",
            attributes: ["expression": "awake"]
        )
        presentation.show(expression: .awake, source: .idle)
        scheduleOpeningGreeting()

        conversationTask = Task { [weak self] in
            guard let self else { return }
            do {
                try await conversationRuntime.start()
                try Task.checkCancellation()
                isProviderConnected = true
                flushPendingInput()
                state = .listening
                presentation.show(expression: .attentive, source: .microphone)
                scheduleIdleTimeout()
            } catch {
                guard !Task.isCancelled else { return }
                let notice = userFacingMessage(for: error)
                recordDiagnostic(
                    "session.startup_failed",
                    attributes: ["notice": notice]
                )
                finishConversation(
                    reason: .startupFailure,
                    showToast: notice,
                    resumeWakeWord: true
                )
            }
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
            diagnosticTimeline.recordLocalVoiceActivity()
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

    func scheduleUserResponse(
        for turn: ConversationTurnCorrelationSnapshot
    ) {
        userResponseRequestTask?.cancel()
        pendingResponseTurnID = turn.turnID
        recordDiagnostic(
            "response.request_scheduled",
            turn: turn,
            attributes: [
                "grace_ms": String(Self.milliseconds(userTurnResponseGrace))
            ]
        )

        userResponseRequestTask = Task { [weak self] in
            guard let self else { return }
            try? await Task.sleep(for: userTurnResponseGrace)
            guard !Task.isCancelled,
                  isConversationActive,
                  isProviderConnected,
                  pendingResponseTurnID == turn.turnID,
                  turnCorrelator.activeTurnID == turn.turnID,
                  state == .assistantPreparing else { return }

            userResponseRequestTask = nil
            pendingResponseTurnID = nil
            let requestAttributes = diagnosticTimeline.recordResponseRequested(
                turnID: turn.turnID
            )
            recordDiagnostic(
                "response.requested",
                turn: turnCorrelator.activeTurn,
                attributes: requestAttributes
            )
            isProviderResponseOutstanding = true
            audioService.prepareForAssistantResponse()
            do {
                try await conversationProvider.requestUserResponse()
            } catch {
                isProviderResponseOutstanding = false
                let notice = userFacingMessage(for: error)
                recordDiagnostic(
                    "response.request_failed",
                    turn: turnCorrelator.activeTurn,
                    attributes: ["notice": notice]
                )
                finishConversation(
                    reason: .providerFailure,
                    showToast: notice,
                    resumeWakeWord: true
                )
            }
        }
    }

    @discardableResult
    func cancelScheduledUserResponse(
        reason: String
    ) -> ConversationTurnCorrelationSnapshot? {
        guard userResponseRequestTask != nil else { return nil }
        userResponseRequestTask?.cancel()
        userResponseRequestTask = nil
        guard let turnID = pendingResponseTurnID else { return nil }
        pendingResponseTurnID = nil
        let cancelledTurn = turnCorrelator.cancelAwaitingResponse(for: turnID)
        recordDiagnostic(
            "response.request_cancelled",
            turn: cancelledTurn,
            attributes: ["reason": reason]
        )
        return cancelledTurn
    }

    private static func milliseconds(_ duration: Duration) -> Int {
        let components = duration.components
        let seconds = Double(components.seconds)
            + Double(components.attoseconds) / 1_000_000_000_000_000_000
        return Int(max(0, seconds) * 1_000)
    }

    func scheduleIdleTimeout() {
        idleTimeoutTask?.cancel()
        idleTimeoutTask = Task { [weak self] in
            try? await Task.sleep(for: ConversationLimits.idleTimeout)
            guard !Task.isCancelled else { return }
            self?.finishConversation(
                reason: .idleTimeout,
                showToast: nil,
                resumeWakeWord: true
            )
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
            presentation.show(expression: .awake, source: .assistant)
            let greetingTurn = turnCorrelator.beginOpeningGreeting()
            recordDiagnostic("opening_greeting.requested", turn: greetingTurn)
            isProviderResponseOutstanding = true
            conversationProvider.requestOpeningGreeting()
        }
    }

    func markUserSpeechDetected() {
        guard !hasDetectedUserSpeech else { return }
        hasDetectedUserSpeech = true
        recordDiagnostic("audio.local_speech_detected")
        openingSpeech.removeAll()
        openingGreetingTask?.cancel()
        openingGreetingTask = nil
        userResponseRequestTask?.cancel()
        userResponseRequestTask = nil
        pendingResponseTurnID = nil
    }

    func scheduleAttentiveExpression() {
        expressionTask?.cancel()
        expressionTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(220))
            guard !Task.isCancelled, let self, state == .userSpeaking else { return }
            presentation.show(expression: .attentive, source: .microphone)
        }
    }

    func finishConversation(
        reason: ConversationEndReason,
        showToast: String?,
        resumeWakeWord: Bool
    ) {
        guard state != .dormant,
              state != .waitingForWakeWord,
              state != .ending else {
            if resumeWakeWord { resumeWakeMonitoring() }
            return
        }

        recordDiagnostic(
            "session.ending",
            attributes: [
                "reason": reason.rawValue,
                "has_notice": String(showToast?.isEmpty == false)
            ]
        )
        state = .ending
        conversationTask?.cancel()
        conversationTask = nil
        idleTimeoutTask?.cancel()
        idleTimeoutTask = nil
        openingGreetingTask?.cancel()
        openingGreetingTask = nil
        userResponseRequestTask?.cancel()
        userResponseRequestTask = nil
        pendingResponseTurnID = nil
        expressionTask?.cancel()
        expressionTask = nil
        screenCaptureTask?.cancel()
        screenCaptureTask = nil
        workDeliveryTask?.cancel()
        workDeliveryTask = nil
        toolCallTasks.values.forEach { $0.cancel() }
        toolCallTasks.removeAll(keepingCapacity: false)
        if let presentingWork {
            pendingCompletedWorks.insert(presentingWork, at: 0)
            self.presentingWork = nil
        }
        screenSelectionController.cancelSelection()
        presentation.show(expression: .resting, source: .idle)
        conversationRuntime.stop()
        sessionSnapshot = sessionLedger.endSession()
        turnCorrelator.endSession()
        workBridge.endConversationSession()
        actionBridge.endConversationSession()
        isProviderConnected = false
        pendingInputChunks.removeAll(keepingCapacity: false)
        pendingInputFrameCount = 0
        pendingScreenInputChunks.removeAll(keepingCapacity: false)
        pendingScreenInputFrameCount = 0
        suppressedPlaybackSpeechItemIDs.removeAll(keepingCapacity: false)
        isScreenContextAttached = false
        diagnosticTimeline.reset()
        openingSpeech.removeAll()
        hasDetectedUserSpeech = false
        hasRequestedOpeningGreeting = false
        isProviderResponseOutstanding = false
        uncorrelatedCancelledResponseCount = 0

        conversationTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(180))
            guard let self, !Task.isCancelled else { return }
            presentation.hide()
            recordDiagnostic("presentation.hidden")
            if let showToast, !showToast.isEmpty {
                presentation.showToast(showToast, hidesOverlay: true)
                recordDiagnostic(
                    "presentation.notice_shown",
                    attributes: ["notice": showToast]
                )
            }
            state = .dormant
            diagnostics.finishSession(
                reason: reason,
                state: state.diagnosticName,
                notice: showToast
            )
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

}
