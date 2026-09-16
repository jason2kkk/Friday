// 功能：维护 Talk 当前一轮的内存字幕，并测量用户转写首字、增量更新和定稿延迟。
// 职责：按 Friday TurnID 与 Provider item_id 过滤迟到事件，拼接临时字幕，并向桌面悬浮对话层提供无持久化快照。
// 边界：不解析网络 JSON、不保存或记录对话正文、不创建转写会话，也不参与模型回复和 Work 决策。

import Foundation

struct ConversationLiveTranscriptSnapshot: Equatable {
    var userText = ""
    var assistantText = ""
    var userTextIsFinal = false
    var firstTextLatencyMilliseconds: Int?
    var deltaIntervalMilliseconds: Int?
    var finalizationLatencyMilliseconds: Int?

    static let empty = ConversationLiveTranscriptSnapshot()
}

struct ConversationLiveTranscriptTracker {
    private let clock = ContinuousClock()
    private(set) var snapshot = ConversationLiveTranscriptSnapshot.empty

    private var pendingAudioForwardedAt: ContinuousClock.Instant?
    private var userAudioIsOpen = false
    private var userTurnID: ConversationTurnID?
    private var userItemID: ConversationProviderItemID?
    private var userAudioForwardedAt: ContinuousClock.Instant?
    private var userSpeechStoppedAt: ContinuousClock.Instant?
    private var firstUserDeltaAt: ContinuousClock.Instant?
    private var lastUserDeltaAt: ContinuousClock.Instant?
    private var assistantTurnID: ConversationTurnID?

    mutating func reset() {
        snapshot = .empty
        pendingAudioForwardedAt = nil
        userAudioIsOpen = false
        userTurnID = nil
        userItemID = nil
        userAudioForwardedAt = nil
        userSpeechStoppedAt = nil
        firstUserDeltaAt = nil
        lastUserDeltaAt = nil
        assistantTurnID = nil
    }

    mutating func recordAudioForwarded() {
        guard !userAudioIsOpen, pendingAudioForwardedAt == nil else { return }
        pendingAudioForwardedAt = clock.now
    }

    mutating func beginUserTurn(_ turn: ConversationTurnCorrelationSnapshot) {
        guard turn.source == .userSpeech else { return }
        userAudioIsOpen = true

        guard userTurnID != turn.turnID else {
            userItemID = userItemID ?? turn.providerUserItemID
            pendingAudioForwardedAt = nil
            return
        }

        userTurnID = turn.turnID
        userItemID = turn.providerUserItemID
        userAudioForwardedAt = pendingAudioForwardedAt ?? clock.now
        pendingAudioForwardedAt = nil
        userSpeechStoppedAt = nil
        firstUserDeltaAt = nil
        lastUserDeltaAt = nil

        snapshot.userText = ""
        snapshot.userTextIsFinal = false
        snapshot.firstTextLatencyMilliseconds = nil
        snapshot.deltaIntervalMilliseconds = nil
        snapshot.finalizationLatencyMilliseconds = nil
    }

    mutating func attachUserItem(
        _ itemID: ConversationProviderItemID,
        to turn: ConversationTurnCorrelationSnapshot?
    ) {
        guard let turn,
              turn.source == .userSpeech,
              turn.turnID == userTurnID else { return }
        guard userItemID == nil || userItemID == itemID else { return }
        userItemID = itemID
    }

    mutating func markUserSpeechStopped(
        _ turn: ConversationTurnCorrelationSnapshot
    ) {
        guard turn.turnID == userTurnID else { return }
        userAudioIsOpen = false
        userSpeechStoppedAt = clock.now
    }

    @discardableResult
    mutating func appendUserDelta(
        _ delta: ConversationInputTranscriptionDelta,
        turn: ConversationTurnCorrelationSnapshot
    ) -> Bool {
        guard matchesActiveUserTurn(turn, itemID: delta.itemID) else { return false }
        let now = clock.now
        if firstUserDeltaAt == nil {
            firstUserDeltaAt = now
            snapshot.firstTextLatencyMilliseconds = milliseconds(
                from: userAudioForwardedAt,
                to: now
            )
        }
        snapshot.deltaIntervalMilliseconds = milliseconds(from: lastUserDeltaAt, to: now)
        lastUserDeltaAt = now
        snapshot.userText = limited(snapshot.userText + delta.delta)
        snapshot.userTextIsFinal = false
        return true
    }

    @discardableResult
    mutating func finishUserTranscript(
        text: String,
        itemID: ConversationProviderItemID,
        turn: ConversationTurnCorrelationSnapshot
    ) -> Bool {
        guard matchesActiveUserTurn(turn, itemID: itemID) else { return false }
        snapshot.userText = limited(text)
        snapshot.userTextIsFinal = true
        snapshot.finalizationLatencyMilliseconds = milliseconds(
            from: userSpeechStoppedAt,
            to: clock.now
        )
        return true
    }

    @discardableResult
    mutating func appendAssistantDelta(
        _ delta: String,
        turn: ConversationTurnCorrelationSnapshot
    ) -> Bool {
        if assistantTurnID != turn.turnID {
            assistantTurnID = turn.turnID
            snapshot.assistantText = ""
        }
        snapshot.assistantText = limited(snapshot.assistantText + delta)
        return true
    }

    private mutating func matchesActiveUserTurn(
        _ turn: ConversationTurnCorrelationSnapshot,
        itemID: ConversationProviderItemID
    ) -> Bool {
        guard turn.source == .userSpeech,
              turn.turnID == userTurnID,
              userItemID == nil || userItemID == itemID else { return false }
        userItemID = itemID
        return true
    }

    private func milliseconds(
        from start: ContinuousClock.Instant?,
        to end: ContinuousClock.Instant
    ) -> Int? {
        guard let start else { return nil }
        let components = start.duration(to: end).components
        let seconds = Double(components.seconds)
            + Double(components.attoseconds) / 1_000_000_000_000_000_000
        return Int(max(0, seconds) * 1_000)
    }

    private func limited(_ text: String) -> String {
        String(text.suffix(800))
    }
}

@MainActor
extension ConversationCoordinator {
    func resetLiveTranscript() {
        liveTranscriptTracker.reset()
        liveTranscript = liveTranscriptTracker.snapshot
    }

    func recordLiveTranscriptAudioForwarded() {
        liveTranscriptTracker.recordAudioForwarded()
    }

    func beginLiveUserTranscript(_ turn: ConversationTurnCorrelationSnapshot) {
        liveTranscriptTracker.beginUserTurn(turn)
        liveTranscript = liveTranscriptTracker.snapshot
    }

    func attachLiveUserTranscriptItem(
        _ itemID: ConversationProviderItemID,
        to turn: ConversationTurnCorrelationSnapshot?
    ) {
        liveTranscriptTracker.attachUserItem(itemID, to: turn)
    }

    func stopLiveUserTranscript(_ turn: ConversationTurnCorrelationSnapshot) {
        liveTranscriptTracker.markUserSpeechStopped(turn)
    }

    func appendLiveUserTranscript(
        _ delta: ConversationInputTranscriptionDelta,
        turn: ConversationTurnCorrelationSnapshot
    ) {
        guard liveTranscriptTracker.appendUserDelta(delta, turn: turn) else { return }
        liveTranscript = liveTranscriptTracker.snapshot
    }

    func finishLiveUserTranscript(
        text: String,
        itemID: ConversationProviderItemID,
        turn: ConversationTurnCorrelationSnapshot
    ) {
        guard liveTranscriptTracker.finishUserTranscript(
            text: text,
            itemID: itemID,
            turn: turn
        ) else { return }
        liveTranscript = liveTranscriptTracker.snapshot
    }

    func appendLiveAssistantTranscript(
        _ delta: String,
        turn: ConversationTurnCorrelationSnapshot
    ) {
        guard liveTranscriptTracker.appendAssistantDelta(delta, turn: turn) else { return }
        liveTranscript = liveTranscriptTracker.snapshot
    }
}
