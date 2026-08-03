// 功能：启动 Friday macOS 应用，常驻顶部灵动岛，并承载应用级 Dictate 和 Talk 工作流。
// 职责：创建 App 场景与服务依赖，统一管理权限和就绪状态、快捷键分发、录音处理、目标写回、失败恢复及 Talk 协调器。
// 边界：不保存长期 API Key 或用户音频；系统访问、音频、网络和浮层细节分别委托给 Platform、Provider 与 Feature 类型。

import AppKit
import Combine
import SwiftUI

@main
struct FridayApp: App {
    @StateObject private var appState: AppState

    init() {
        let environment = ProcessInfo.processInfo.environment
        let isRunningTests = environment["XCTestConfigurationFilePath"] != nil
            || environment["XCTestBundlePath"] != nil
        _appState = StateObject(
            wrappedValue: AppState(servicesEnabled: !isRunningTests)
        )
    }

    var body: some Scene {
        Settings {
            EmptyView()
                .environmentObject(appState)
        }
    }
}

@MainActor
final class AppState: ObservableObject {
    static let microphonePermissionRequiredMessage = "需要麦克风权限"

    @Published private(set) var workflowState: DictationWorkflowState = .checkingReadiness
    @Published private(set) var serviceAvailability: SessionServiceAvailability = .checking
    @Published private(set) var accessibilityGranted = false
    @Published private(set) var microphonePermission = "首次使用时询问"
    @Published private(set) var hotKeyAvailable = false
    @Published private(set) var lastTargetName: String?
    @Published private(set) var lastOutput: String?
    @Published private(set) var lastUsage = DictationUsage.zero
    @Published private(set) var dictationMode: DictationMode

    var status: String {
        if conversationCoordinator.state != .dormant {
            return conversationCoordinator.statusText
        }
        return workflowState.statusText
    }

    var isWorking: Bool {
        workflowState.isWorking || conversationCoordinator.isConversationActive
    }

    var isListening: Bool {
        workflowState.isRecording || conversationCoordinator.isConversationActive
    }

    var canRetry: Bool {
        recoveryAction != nil
    }

    var microphonePermissionGranted: Bool {
        microphoneService.authorizationStatus == .authorized
    }

    var microphonePermissionNeedsAttention: Bool {
        !microphonePermissionGranted
    }

    var microphonePermissionCanRequest: Bool {
        microphoneService.authorizationStatus == .notDetermined
    }

    var serviceNeedsAttention: Bool {
        guard dictationMode == .live,
              microphonePermissionGranted,
              hotKeyAvailable else { return false }
        if case .unavailable = serviceAvailability {
            return true
        }
        return false
    }

    var screenCapturePermissionGranted: Bool {
        conversationCoordinator.screenCapturePermissionGranted
    }

    var screenCapturePermissionNeedsAttention: Bool {
        !screenCapturePermissionGranted
    }

    var isConversationActive: Bool {
        conversationCoordinator.isConversationActive
    }

    var conversationState: ConversationState {
        conversationCoordinator.state
    }

    private let servicesEnabled: Bool
    private let healthClient: SessionServiceHealthChecking
    private let accessibilityService = AccessibilityInputService()
    private let hotKeyService = GlobalHotKeyService()
    private let microphoneService = MicrophoneCaptureService()
    private let mockProvider: DictationProvider = MockDictationProvider()
    private let realtimeProvider: DictationProvider = RealtimeDictationProvider()
    private let overlayModel = InputOverlayModel()
    private var overlayController: InputOverlayController?
    private lazy var conversationCoordinator: ConversationCoordinator = {
        let conversationProvider: ConversationProviding
        switch ConversationMode.configured {
        case .mock:
            conversationProvider = MockConversationProvider()
        case .live:
            conversationProvider = RealtimeConversationProvider()
        }
        return ConversationCoordinator(
            activationMode: .shortcut,
            wakeWordProvider: MockWakeWordService(),
            conversationProvider: conversationProvider,
            audioService: ConversationAudioService(),
            presentation: InputOverlayConversationPresenter(
                model: overlayModel,
                controller: overlayController
            ),
            diagnostics: ConversationJSONLDiagnosticsRecorder()
        )
    }()
    private var activeProvider: DictationProvider?
    private var lockedTarget: FocusedInputTarget?
    private var activeContext: DictationContext?
    private var retainedAudio = RetainedAudio()
    private var recoveryAction: RecoveryAction?
    private var workflowTask: Task<Void, Never>?
    private var providerPreparationTask: Task<Void, Error>?
    private var readinessTask: Task<Void, Never>?
    private var recordingLimitTask: Task<Void, Never>?
    private var feedbackTask: Task<Void, Never>?
    private var activationObserver: NSObjectProtocol?
    private var conversationObservation: AnyCancellable?
    private var dashboardObservation: AnyCancellable?
    private let minimumRecordingDuration: TimeInterval = 0.35
    private let maximumDictationRecordingDuration: Duration = .seconds(600)
    private let mockOutputText = "Friday 开发测试：本轮使用 Mock 处理，不会产生 API 费用。"

    init(
        servicesEnabled: Bool = true,
        healthClient: SessionServiceHealthChecking = SessionServiceHealthClient()
    ) {
        self.servicesEnabled = servicesEnabled
        self.healthClient = healthClient
        dictationMode = DictationMode.configured

        if servicesEnabled {
            overlayController = InputOverlayController(model: overlayModel)
        }

        refreshPermissionStatus()
        overlayModel.onRetry = { [weak self] in
            self?.retryLastOperation()
        }
        overlayModel.onCopy = { [weak self] in
            self?.copyLastOutput()
        }
        overlayModel.onDismiss = { [weak self] in
            self?.dismissOverlayFromUser()
        }
        overlayModel.onToggleDictation = { [weak self] in
            self?.handleHotKey()
        }
        overlayModel.onToggleConversation = { [weak self] in
            self?.handleConversationHotKey()
        }
        overlayModel.onSelectScreenRegion = { [weak self] in
            self?.handleScreenRegionHotKey()
        }
        overlayModel.onRequestAccessibility = { [weak self] in
            self?.requestAccessibilityPermission()
        }
        overlayModel.onRequestMicrophone = { [weak self] in
            guard let self else { return }
            if microphonePermissionCanRequest {
                requestMicrophonePermission()
            } else {
                openMicrophoneSettings()
            }
        }
        overlayModel.onRequestScreenCapture = { [weak self] in
            self?.requestScreenCapturePermission()
        }
        overlayModel.onClearLastOutput = { [weak self] in
            self?.clearLastOutput()
        }
        overlayModel.onRefresh = { [weak self] in
            self?.refreshIslandStatus()
        }
        overlayModel.onQuit = {
            NSApplication.shared.terminate(nil)
        }
        microphoneService.onLevel = { [weak self] level in
            guard self?.workflowState.isRecording == true else { return }
            self?.overlayModel.audioLevel = level
            self?.overlayModel.isVoiceActive = AudioLevelMeter.hasVisualActivity(level)
        }
        microphoneService.onAudioChunk = { [weak self] chunk in
            self?.receiveAudioChunk(chunk)
        }
        mockProvider.onPartialText = { [weak self] text in
            self?.showPartialText(text)
        }
        realtimeProvider.onPartialText = { [weak self] text in
            self?.showPartialText(text)
        }
        hotKeyService.onPressed = { [weak self] action in
            switch action {
            case .dictation:
                self?.handleHotKey()
            case .conversation:
                self?.handleConversationHotKey()
            case .screenRegion:
                self?.handleScreenRegionHotKey()
            }
        }
        activationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.refreshReadiness()
            }
        }

        guard servicesEnabled else {
            workflowState = .unavailable("预览状态")
            serviceAvailability = .notRequired
            return
        }

        registerHotKeysIfPossible()

        conversationObservation = conversationCoordinator.objectWillChange.sink { [weak self] _ in
            self?.objectWillChange.send()
        }
        dashboardObservation = objectWillChange.sink { [weak self] _ in
            Task { @MainActor [weak self] in
                await Task.yield()
                self?.syncIslandDashboard()
            }
        }
        conversationCoordinator.start()
        refreshReadiness()
        syncIslandDashboard()
    }

    deinit {
        if let activationObserver {
            NotificationCenter.default.removeObserver(activationObserver)
        }
    }

    private func syncIslandDashboard() {
        let serviceLabel: String
        let serviceAvailable: Bool
        let serviceChecking: Bool
        let modelName: String
        let sessionsIssued: Int?
        let quotaLabel: String

        switch serviceAvailability {
        case .notRequired:
            serviceLabel = "Mock 模式"
            serviceAvailable = true
            serviceChecking = false
            modelName = "Mock"
            sessionsIssued = nil
            quotaLabel = "Mock 模式不使用 OpenAI 额度"
        case .checking:
            serviceLabel = "正在检查本地服务"
            serviceAvailable = false
            serviceChecking = true
            modelName = "--"
            sessionsIssued = nil
            quotaLabel = "账户额度：等待服务状态"
        case .available(let health):
            serviceLabel = "本地服务已连接"
            serviceAvailable = true
            serviceChecking = false
            modelName = health.model
            sessionsIssued = health.sessionsIssued
            quotaLabel = Self.quotaLabel(for: health.billingIssueCode)
        case .unavailable(let message):
            serviceLabel = message
            serviceAvailable = false
            serviceChecking = false
            modelName = "--"
            sessionsIssued = nil
            quotaLabel = "账户额度：服务不可用"
        }

        overlayModel.dashboard = IslandDashboardSnapshot(
            status: status,
            model: modelName,
            serviceLabel: serviceLabel,
            serviceAvailable: serviceAvailable,
            serviceChecking: serviceChecking,
            sessionsIssued: sessionsIssued,
            quotaLabel: quotaLabel,
            talkResponses: conversationCoordinator.turnCount,
            talkTokens: conversationCoordinator.totalTokens,
            talkEstimatedCostUSD: conversationCoordinator.estimatedCostUSD,
            dictationTokens: lastUsage.totalTokens,
            accessibilityGranted: accessibilityGranted,
            microphoneGranted: microphonePermissionGranted,
            microphoneCanRequest: microphonePermissionCanRequest,
            screenCaptureGranted: screenCapturePermissionGranted,
            serviceNeedsAttention: serviceNeedsAttention,
            canRetry: canRetry,
            lastOutput: lastOutput,
            isDictationActive: workflowState.isWorking,
            isConversationActive: isConversationActive
        )
    }

    private static func quotaLabel(for issueCode: String?) -> String {
        switch issueCode {
        case "credit_balance_exhausted":
            return "账户额度：预付余额已用完"
        case "organization_spend_limit_exceeded":
            return "账户额度：组织消费上限已触发"
        case "project_spend_limit_exceeded":
            return "账户额度：项目消费上限已触发"
        case "organization_usage_limit_exceeded":
            return "账户额度：组织用量上限已触发"
        default:
            return "账户余额：OpenAI 未提供可读接口"
        }
    }

    func refreshPermissionStatus() {
        refreshReadiness()
    }

    private func refreshIslandStatus() {
        guard recoveryAction != nil, dictationMode == .live else {
            refreshReadiness()
            return
        }

        refreshPermissionSnapshot()
        readinessTask?.cancel()
        serviceAvailability = .checking
        readinessTask = Task { [weak self] in
            guard let self else { return }
            do {
                serviceAvailability = .available(try await healthClient.check())
            } catch {
                guard !Task.isCancelled else { return }
                serviceAvailability = .unavailable(userFacingMessage(for: error))
            }
        }
    }

    func requestScreenCapturePermission() {
        conversationCoordinator.requestScreenCapturePermission()
    }

    func openScreenCaptureSettings() {
        conversationCoordinator.openScreenCaptureSettings()
    }

    func refreshReadiness() {
        refreshPermissionSnapshot()
        registerHotKeysIfPossible()
        guard servicesEnabled, !workflowState.isWorking else { return }
        guard recoveryAction == nil else { return }

        readinessTask?.cancel()

        guard hotKeyAvailable else {
            workflowState = .unavailable("快捷键不可用")
            return
        }
        guard microphonePermissionGranted else {
            workflowState = .unavailable(Self.microphonePermissionRequiredMessage)
            return
        }

        guard dictationMode == .live else {
            serviceAvailability = .notRequired
            workflowState = .ready
            conversationCoordinator.resumeAfterDictation()
            return
        }

        workflowState = .checkingReadiness
        serviceAvailability = .checking
        readinessTask = Task { [weak self] in
            guard let self else { return }
            do {
                let health = try await healthClient.check()
                try Task.checkCancellation()
                serviceAvailability = .available(health)
                workflowState = .ready
                conversationCoordinator.resumeAfterDictation()
            } catch {
                guard !Task.isCancelled else { return }
                let message = userFacingMessage(for: error)
                serviceAvailability = .unavailable(message)
                workflowState = .unavailable(message)
            }
        }
    }

    func requestAccessibilityPermission() {
        accessibilityGranted = accessibilityService.requestPermission()
        if !accessibilityGranted {
            openPrivacySettings(anchor: "Privacy_Accessibility")
        } else {
            registerHotKeysIfPossible()
        }
        refreshReadiness()
    }

    private func registerHotKeysIfPossible() {
        guard servicesEnabled, accessibilityGranted, !hotKeyAvailable else { return }
        do {
            try hotKeyService.register()
            hotKeyAvailable = true
        } catch {
            hotKeyAvailable = false
            workflowState = .unavailable(error.localizedDescription)
        }
    }

    func requestMicrophonePermission() {
        workflowTask?.cancel()
        workflowState = .checkingReadiness
        workflowTask = Task { [weak self] in
            guard let self else { return }
            do {
                try await microphoneService.preflight()
                refreshReadiness()
            } catch {
                refreshPermissionSnapshot()
                if microphoneService.authorizationStatus == .denied {
                    openMicrophoneSettings()
                } else {
                    workflowState = .unavailable(userFacingMessage(for: error))
                }
            }
        }
    }

    func openMicrophoneSettings() {
        workflowState = .unavailable("请在系统设置中允许 Friday 使用麦克风")
        openPrivacySettings(anchor: "Privacy_Microphone")
    }

    func retryLastOperation() {
        guard let recoveryAction else { return }
        self.recoveryAction = nil
        feedbackTask?.cancel()
        overlayModel.audioLevel = 0
        overlayModel.isVoiceActive = false
        overlayModel.waveformLevels = InputOverlayModel.silentWaveformLevels

        switch recoveryAction {
        case .process(let context, let target, let audio):
            retryProcessing(context: context, target: target, audio: audio)
        case .insert(let text, let target):
            retryInsertion(text: text, target: target)
        }
    }

    func dismissRecovery() {
        clearActiveWorkflow(clearRetainedAudio: true)
        overlayController?.hide()
        refreshReadiness()
    }

    func dismissPresentedResult() {
        feedbackTask?.cancel()
        overlayController?.hide()
        refreshReadiness()
    }

    private func dismissOverlayFromUser() {
        feedbackTask?.cancel()

        if conversationCoordinator.isConversationActive {
            if conversationCoordinator.state == .selectingScreenRegion
                || conversationCoordinator.state == .capturingScreenRegion {
                conversationCoordinator.cancelScreenRegionSelection()
                return
            }
            conversationCoordinator.endConversation()
            return
        }

        switch workflowState {
        case .preparing, .recording, .processing:
            cancelDictation()
        case .recoverableFailure:
            overlayController?.hide()
            if recoveryAction == nil {
                refreshReadiness()
            }
        case .inserting:
            overlayController?.hide()
        case .ready, .success, .checkingReadiness, .unavailable:
            overlayController?.hide()
            refreshReadiness()
        }
    }

    func copyLastOutput() {
        guard let lastOutput else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(lastOutput, forType: .string)
        overlayController?.hide()
        if recoveryAction == nil {
            refreshReadiness()
        }
    }

    func clearLastOutput() {
        lastOutput = nil
        lastUsage = .zero
        dismissRecovery()
    }

    private func handleHotKey() {
        if conversationCoordinator.isConversationActive {
            conversationCoordinator.endConversation()
            return
        }
        refreshPermissionSnapshot()
        if Self.shouldRefreshStaleMicrophonePermission(
            workflowState,
            microphonePermissionGranted: microphonePermissionGranted
        ) {
            refreshReadiness()
            return
        }

        switch workflowState {
        case .ready, .success:
            startDictation()
        case .recording:
            finishDictation()
        case .preparing, .processing:
            cancelDictation()
        case .inserting:
            break
        case .recoverableFailure:
            dismissRecovery()
        case .checkingReadiness:
            refreshReadiness()
        case .unavailable:
            showFeedback(
                .failure(workflowState.statusText, canRetry: false),
                duration: .milliseconds(2_000),
                refreshAfterwards: true
            )
        }
    }

    private func handleConversationHotKey() {
        if conversationCoordinator.isConversationActive {
            conversationCoordinator.endConversation()
            return
        }

        switch workflowState {
        case .preparing, .recording, .processing, .inserting:
            showFeedback(
                .failure("请先结束当前听写", canRetry: false),
                duration: .milliseconds(1_800),
                refreshAfterwards: false
            )
        case .recoverableFailure:
            showFeedback(
                .failure("请先处理当前转写结果", canRetry: false),
                duration: .milliseconds(1_800),
                refreshAfterwards: false
            )
        case .ready, .success, .checkingReadiness, .unavailable:
            conversationCoordinator.startConversationFromShortcut()
        }
    }

    private func handleScreenRegionHotKey() {
        guard conversationCoordinator.isConversationActive else {
            showFeedback(
                .failure("请先开始语音对话，再框选屏幕", canRetry: false),
                duration: .milliseconds(1_800),
                refreshAfterwards: false
            )
            return
        }

        if conversationCoordinator.state == .selectingScreenRegion
            || conversationCoordinator.state == .capturingScreenRegion {
            conversationCoordinator.cancelScreenRegionSelection()
        } else {
            conversationCoordinator.beginScreenRegionSelection()
        }
    }

    static func shouldRefreshStaleMicrophonePermission(
        _ state: DictationWorkflowState,
        microphonePermissionGranted: Bool
    ) -> Bool {
        guard microphonePermissionGranted,
              case .unavailable(let message) = state else { return false }
        return message == microphonePermissionRequiredMessage
    }

    private func startDictation() {
        guard workflowState.isReady || {
            if case .success = workflowState { return true }
            return false
        }() else {
            refreshReadiness()
            return
        }

        conversationCoordinator.pauseForDictation()
        feedbackTask?.cancel()
        readinessTask?.cancel()
        recoveryAction = nil
        retainedAudio.removeAll()
        overlayModel.audioLevel = 0
        overlayModel.isVoiceActive = false
        overlayModel.waveformLevels = InputOverlayModel.silentWaveformLevels
        accessibilityGranted = accessibilityService.isTrusted
        let targetResult = accessibilityService.captureFocusedTarget(promptIfNeeded: false)
        let fallbackApplicationName = accessibilityService.frontmostApplicationName
        let target: FocusedInputTarget?
        let targetRole: String

        switch targetResult {
        case .target(let resolvedTarget):
            target = resolvedTarget
            targetRole = resolvedTarget.role
        case .accessibilityDenied:
            accessibilityGranted = false
            target = nil
            targetRole = "未授权自动写入"
        case .secureInput:
            target = nil
            targetRole = "安全输入框"
        case .fridayFocused, .noFocusedElement, .notEditable, .systemError:
            target = nil
            targetRole = "未识别输入框"
        }

        let provider = selectedProvider
        let context = DictationContext(
            targetApplication: target?.applicationName ?? fallbackApplicationName,
            targetRole: targetRole,
            mockOutputText: mockOutputText
        )
        activeProvider = provider
        lockedTarget = target
        activeContext = context
        lastTargetName = target?.applicationName ?? fallbackApplicationName
        workflowState = .preparing

        workflowTask = Task { [weak self] in
            guard let self else { return }
            do {
                try await microphoneService.start()
                try Task.checkCancellation()

                workflowState = .recording
                refreshPermissionSnapshot()
                overlayController?.show(.listening)
                scheduleRecordingSafetyStop()
            } catch {
                guard !Task.isCancelled else { return }
                refreshPermissionSnapshot()
                showTransientFailure(userFacingMessage(for: error))
            }
        }
    }

    private func finishDictation() {
        guard workflowState == .recording,
              let provider = activeProvider,
              let context = activeContext else { return }

        let target = lockedTarget

        recordingLimitTask?.cancel()
        microphoneService.stop()
        overlayModel.audioLevel = 0
        overlayModel.isVoiceActive = false
        overlayModel.waveformLevels = InputOverlayModel.silentWaveformLevels

        guard retainedAudio.hasLikelySpeech else {
            showNoSpeechFeedback()
            return
        }

        guard retainedAudio.duration >= minimumRecordingDuration else {
            provider.cancel()
            showTransientFailure("录音时间太短，请重新说一遍")
            return
        }

        startProviderPreparationIfNeeded()
        guard let preparationTask = providerPreparationTask else {
            provider.cancel()
            showTransientFailure("无法启动语音处理，请重试")
            return
        }

        let audio = retainedAudio
        let recovery = RecoveryAction.process(context: context, target: target, audio: audio)
        workflowState = .processing(partialText: nil)
        overlayController?.show(
            .processing(
                title: "正在整理文字",
                detail: "请稍候",
                canCancel: true
            )
        )

        workflowTask = Task { [weak self] in
            guard let self else { return }
            do {
                try await preparationTask.value
                providerPreparationTask = nil
                try Task.checkCancellation()
                let output = try await provider.finish()
                try Task.checkCancellation()
                await completeProcessing(output, target: target)
            } catch {
                guard !Task.isCancelled else { return }
                handleProcessingFailure(error, recovery: recovery)
            }
        }
    }

    private func cancelDictation() {
        workflowTask?.cancel()
        providerPreparationTask?.cancel()
        providerPreparationTask = nil
        readinessTask?.cancel()
        recordingLimitTask?.cancel()
        microphoneService.stop()
        activeProvider?.cancel()
        clearActiveWorkflow(clearRetainedAudio: true)
        overlayController?.hide()
        workflowState = .success("已取消本次录音")
        scheduleReadinessRefresh(after: .milliseconds(900))
    }

    private func finishInsertion(
        _ result: TextInsertionResult,
        outputText: String,
        target: FocusedInputTarget
    ) {
        switch result {
        case .verified:
            clearActiveWorkflow(clearRetainedAudio: true)
            workflowState = .success("文字已写入输入框")
            overlayController?.hide()
            scheduleReadinessRefresh(after: .milliseconds(180))
        case .dispatched:
            clearActiveWorkflow(clearRetainedAudio: true)
            workflowState = .success("已发送到输入框，请确认")
            overlayController?.hide()
            scheduleReadinessRefresh(after: .milliseconds(180))
        case .targetUnavailable:
            showInsertionRecovery(
                "原来的应用已关闭，文字已保留",
                text: outputText,
                target: target
            )
        case .focusChanged:
            showInsertionRecovery(
                "输入位置发生变化，文字已保留",
                text: outputText,
                target: target
            )
        case .pasteEventUnavailable:
            showInsertionRecovery(
                "无法写入输入框，文字已保留",
                text: outputText,
                target: target
            )
        case .systemError:
            showInsertionRecovery(
                "写入失败，文字已保留",
                text: outputText,
                target: target
            )
        }
    }

    private func scheduleRecordingSafetyStop() {
        recordingLimitTask?.cancel()
        recordingLimitTask = Task { [weak self] in
            guard let self else { return }
            try? await Task.sleep(for: maximumDictationRecordingDuration)
            guard !Task.isCancelled else { return }
            finishDictation()
        }
    }

    private func showPartialText(_ text: String) {
        guard case .processing = workflowState else { return }
        let visibleText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !visibleText.isEmpty else { return }

        workflowState = .processing(partialText: visibleText)
        overlayController?.show(
            .processing(
                title: "正在整理文字",
                detail: visibleText,
                canCancel: true
            )
        )
    }

    private func showTransientFailure(_ message: String) {
        providerPreparationTask?.cancel()
        providerPreparationTask = nil
        recordingLimitTask?.cancel()
        microphoneService.stop()
        activeProvider?.cancel()
        clearActiveWorkflow(clearRetainedAudio: true)
        workflowState = .recoverableFailure(message)
        showFeedback(
            .failure(message, canRetry: false),
            duration: .milliseconds(2_400),
            refreshAfterwards: true
        )
    }

    private func showNoSpeechFeedback() {
        providerPreparationTask?.cancel()
        providerPreparationTask = nil
        recordingLimitTask?.cancel()
        microphoneService.stop()
        activeProvider?.cancel()
        clearActiveWorkflow(clearRetainedAudio: true)
        workflowState = .success("未收听到声音")
        overlayController?.showBottomToast("未收听到声音")
        scheduleReadinessRefresh(after: .milliseconds(2_200))
    }

    private func handleProcessingFailure(_ error: Error, recovery: RecoveryAction) {
        if let realtimeError = error as? RealtimeDictationProvider.RealtimeError,
           case .noSpeech = realtimeError {
            showNoSpeechFeedback()
            return
        }

        showRecoverableFailure(
            userFacingMessage(for: error),
            recovery: recovery
        )
    }

    private func showRecoverableFailure(_ message: String, recovery: RecoveryAction) {
        providerPreparationTask?.cancel()
        providerPreparationTask = nil
        recordingLimitTask?.cancel()
        microphoneService.stop()
        activeProvider?.cancel()
        activeProvider = nil
        workflowTask = nil
        recoveryAction = recovery
        workflowState = .recoverableFailure(message)
        overlayController?.show(.failure(message, canRetry: true))
    }

    private func showInsertionRecovery(
        _ message: String,
        text: String,
        target: FocusedInputTarget
    ) {
        providerPreparationTask?.cancel()
        providerPreparationTask = nil
        recordingLimitTask?.cancel()
        activeProvider?.cancel()
        activeProvider = nil
        activeContext = nil
        retainedAudio.removeAll()
        workflowTask = nil
        lockedTarget = target
        recoveryAction = .insert(text: text, target: target)
        workflowState = .recoverableFailure(message)
        overlayController?.show(
            .result(text: text, message: message, canRetry: true)
        )
    }

    private func showFeedback(
        _ phase: InputOverlayPhase,
        duration: Duration,
        refreshAfterwards: Bool
    ) {
        feedbackTask?.cancel()
        overlayController?.show(phase)
        feedbackTask = Task { [weak self] in
            try? await Task.sleep(for: duration)
            guard !Task.isCancelled else { return }
            self?.overlayController?.hide()
            if refreshAfterwards {
                self?.refreshReadiness()
            }
        }
    }

    private func retryProcessing(
        context: DictationContext,
        target: FocusedInputTarget?,
        audio: RetainedAudio
    ) {
        providerPreparationTask?.cancel()
        providerPreparationTask = nil
        let provider = selectedProvider
        activeProvider = provider
        lockedTarget = target
        activeContext = context
        retainedAudio = audio
        workflowState = .preparing
        overlayController?.show(
            .processing(title: "正在重新连接", detail: nil, canCancel: true)
        )

        workflowTask = Task { [weak self] in
            guard let self else { return }
            do {
                try await checkServiceBeforeStarting()
                try Task.checkCancellation()
                try await provider.begin(context: context)
                try Task.checkCancellation()
                for chunk in audio.chunks {
                    provider.append(chunk)
                }
                workflowState = .processing(partialText: nil)
                overlayController?.show(
                    .processing(title: "正在重新整理", detail: "请稍候", canCancel: true)
                )
                let output = try await provider.finish()
                try Task.checkCancellation()
                await completeProcessing(output, target: target)
            } catch {
                guard !Task.isCancelled else { return }
                handleProcessingFailure(
                    error,
                    recovery: .process(context: context, target: target, audio: audio)
                )
            }
        }
    }

    private func retryInsertion(text: String, target: FocusedInputTarget) {
        lockedTarget = target
        workflowState = .inserting
        overlayController?.show(
            .processing(title: "正在重新写入", detail: nil, canCancel: false)
        )
        workflowTask = Task { [weak self] in
            guard let self else { return }
            let result = await accessibilityService.insert(text, into: target)
            guard !Task.isCancelled else { return }
            finishInsertion(result, outputText: text, target: target)
        }
    }

    private func completeProcessing(
        _ output: DictationResult,
        target: FocusedInputTarget?
    ) async {
        lastOutput = output.finalText
        lastUsage = output.usage

        let insertionTarget: FocusedInputTarget?
        if let target {
            insertionTarget = target
        } else if case .target(let currentTarget) = accessibilityService.captureFocusedTarget(
            promptIfNeeded: false
        ) {
            insertionTarget = currentTarget
            lastTargetName = currentTarget.applicationName
        } else {
            insertionTarget = nil
        }

        guard let insertionTarget else {
            clearActiveWorkflow(clearRetainedAudio: true)
            workflowState = .success("转写完成，请复制文字")
            overlayController?.show(
                .result(
                    text: output.finalText,
                    message: "未找到可安全写入的输入框",
                    canRetry: false
                )
            )
            return
        }

        workflowState = .inserting
        overlayController?.show(
            .processing(title: "正在写入输入框", detail: nil, canCancel: false)
        )
        let result = await accessibilityService.insert(output.finalText, into: insertionTarget)
        guard !Task.isCancelled else { return }
        finishInsertion(result, outputText: output.finalText, target: insertionTarget)
    }

    private func receiveAudioChunk(_ chunk: AudioChunk) {
        guard workflowState.isRecording else { return }
        overlayModel.waveformLevels = chunk.waveformLevels
        retainedAudio.append(chunk)
        startProviderPreparationIfNeeded()
        activeProvider?.append(chunk)
    }

    private func startProviderPreparationIfNeeded() {
        guard retainedAudio.hasLikelySpeech,
              providerPreparationTask == nil,
              let provider = activeProvider,
              let context = activeContext else { return }

        providerPreparationTask = Task { [weak self] in
            guard let self else { throw CancellationError() }
            try await checkServiceBeforeStarting()
            try Task.checkCancellation()
            try await provider.begin(context: context)
            try Task.checkCancellation()
            for chunk in retainedAudio.chunks {
                provider.append(chunk)
            }
        }
    }

    private func checkServiceBeforeStarting() async throws {
        guard dictationMode == .live else { return }
        serviceAvailability = .checking
        let health = try await healthClient.check()
        serviceAvailability = .available(health)
    }

    private func clearActiveWorkflow(clearRetainedAudio: Bool) {
        workflowTask = nil
        providerPreparationTask?.cancel()
        providerPreparationTask = nil
        recordingLimitTask?.cancel()
        recordingLimitTask = nil
        activeProvider = nil
        activeContext = nil
        lockedTarget = nil
        recoveryAction = nil
        overlayModel.audioLevel = 0
        overlayModel.isVoiceActive = false
        overlayModel.waveformLevels = InputOverlayModel.silentWaveformLevels
        if clearRetainedAudio {
            retainedAudio.removeAll()
        }
    }

    private func scheduleReadinessRefresh(after duration: Duration) {
        feedbackTask?.cancel()
        feedbackTask = Task { [weak self] in
            try? await Task.sleep(for: duration)
            guard !Task.isCancelled else { return }
            self?.refreshReadiness()
        }
    }

    private func refreshPermissionSnapshot() {
        accessibilityGranted = accessibilityService.isTrusted
        microphonePermission = microphonePermissionLabel
    }

    private var microphonePermissionLabel: String {
        switch microphoneService.authorizationStatus {
        case .authorized:
            return "已允许"
        case .notDetermined:
            return "首次使用时询问"
        case .denied:
            return "未允许"
        case .restricted:
            return "受系统限制"
        @unknown default:
            return "未知"
        }
    }

    private func userFacingMessage(for error: Error) -> String {
        if let realtimeError = error as? RealtimeDictationProvider.RealtimeError {
            return realtimeError.localizedDescription
        }
        if let mockError = error as? MockDictationProvider.MockError {
            return mockError.localizedDescription
        }
        if let microphoneError = error as? MicrophoneCaptureService.CaptureError {
            return microphoneError.localizedDescription
        }
        if let healthError = error as? SessionServiceHealthClient.HealthError {
            return healthError.localizedDescription
        }
        if error is URLError {
            return "语音服务未连接，请启动服务后重试"
        }
        return "操作未完成，请重试"
    }

    private func openPrivacySettings(anchor: String) {
        guard let url = URL(
            string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)"
        ) else { return }
        NSWorkspace.shared.open(url)
    }

    private var selectedProvider: DictationProvider {
        switch dictationMode {
        case .mock:
            return mockProvider
        case .live:
            return realtimeProvider
        }
    }
}
