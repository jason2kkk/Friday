// 功能：为 Talk 的用户轮次、模型回复、助手消息和实际播放建立 Friday 自有的稳定身份链。
// 职责：关联 Realtime committed 用户 Item、`response_id` 与助手 `item_id`，跟踪回复和播放状态，并判断语音、音频、取消等事件是否仍属于当前轮次。
// 边界：只维护内存身份与状态，不解析网络 JSON、不播放音频，也不决定灵动岛或会话生命周期。

import Foundation

struct ConversationTurnID: Hashable, Sendable, CustomStringConvertible {
    let rawValue: UUID

    init(rawValue: UUID = UUID()) {
        self.rawValue = rawValue
    }

    var description: String {
        rawValue.uuidString.lowercased()
    }
}

struct ConversationResponseID: Hashable, Sendable, CustomStringConvertible {
    let rawValue: UUID

    init(rawValue: UUID = UUID()) {
        self.rawValue = rawValue
    }

    var description: String {
        rawValue.uuidString.lowercased()
    }
}

struct ConversationAssistantItemID: Hashable, Sendable, CustomStringConvertible {
    let rawValue: UUID

    init(rawValue: UUID = UUID()) {
        self.rawValue = rawValue
    }

    var description: String {
        rawValue.uuidString.lowercased()
    }
}

struct ConversationPlaybackID: Hashable, Sendable, CustomStringConvertible {
    let rawValue: UUID

    init(rawValue: UUID = UUID()) {
        self.rawValue = rawValue
    }

    var description: String {
        rawValue.uuidString.lowercased()
    }
}

enum ConversationTurnSource: Equatable, Sendable {
    case userSpeech
    case openingGreeting
    case providerInitiated
}

enum ConversationResponseState: Equatable, Sendable {
    case awaitingResponse
    case responding
    case completed
    case cancelled
}

enum ConversationPlaybackState: Equatable, Sendable {
    case idle
    case playing
    case delivered
    case interrupted
}

struct ConversationTurnCorrelationSnapshot: Equatable, Sendable {
    let sessionID: ConversationSessionID
    let turnID: ConversationTurnID
    let source: ConversationTurnSource
    let providerUserItemID: ConversationProviderItemID?
    let responseID: ConversationResponseID?
    let providerResponseID: ConversationProviderResponseID?
    let assistantItemID: ConversationAssistantItemID?
    let providerAssistantItemID: ConversationProviderItemID?
    let playbackID: ConversationPlaybackID?
    let responseState: ConversationResponseState
    let playbackState: ConversationPlaybackState
}

struct ConversationTurnCorrelator {
    private(set) var sessionID: ConversationSessionID?
    private(set) var activeTurnID: ConversationTurnID?
    private(set) var activePlaybackID: ConversationPlaybackID?

    private var turns: [ConversationTurnID: ConversationTurnCorrelationSnapshot] = [:]
    private var turnByProviderUserItemID: [ConversationProviderItemID: ConversationTurnID] = [:]
    private var turnByProviderResponseID: [ConversationProviderResponseID: ConversationTurnID] = [:]
    private var turnByProviderAssistantItemID: [ConversationProviderItemID: ConversationTurnID] = [:]
    private var turnByPlaybackID: [ConversationPlaybackID: ConversationTurnID] = [:]
    private var awaitingResponseTurnIDs: [ConversationTurnID] = []

    var activeTurn: ConversationTurnCorrelationSnapshot? {
        activeTurnID.flatMap { turns[$0] }
    }

    mutating func beginSession(_ sessionID: ConversationSessionID) {
        endSession()
        self.sessionID = sessionID
    }

    @discardableResult
    mutating func beginUserTurn(
        providerItemID: ConversationProviderItemID?
    ) -> ConversationTurnCorrelationSnapshot? {
        guard let sessionID else { return nil }
        if let providerItemID,
           let existingTurnID = turnByProviderUserItemID[providerItemID] {
            return turns[existingTurnID]
        }
        if providerItemID == nil,
           let activeTurn,
           activeTurn.source == .userSpeech,
           activeTurn.responseState == .awaitingResponse {
            return activeTurn
        }

        cancelUnansweredOpeningGreetings()
        let turn = ConversationTurnCorrelationSnapshot(
            sessionID: sessionID,
            turnID: ConversationTurnID(),
            source: .userSpeech,
            providerUserItemID: providerItemID,
            responseID: nil,
            providerResponseID: nil,
            assistantItemID: nil,
            providerAssistantItemID: nil,
            playbackID: nil,
            responseState: .awaitingResponse,
            playbackState: .idle
        )
        store(turn)
        if let providerItemID {
            turnByProviderUserItemID[providerItemID] = turn.turnID
        }
        activeTurnID = turn.turnID
        return turn
    }

    @discardableResult
    mutating func beginOpeningGreeting() -> ConversationTurnCorrelationSnapshot? {
        guard let sessionID else { return nil }
        let turn = ConversationTurnCorrelationSnapshot(
            sessionID: sessionID,
            turnID: ConversationTurnID(),
            source: .openingGreeting,
            providerUserItemID: nil,
            responseID: nil,
            providerResponseID: nil,
            assistantItemID: nil,
            providerAssistantItemID: nil,
            playbackID: nil,
            responseState: .awaitingResponse,
            playbackState: .idle
        )
        store(turn)
        awaitingResponseTurnIDs.append(turn.turnID)
        activeTurnID = turn.turnID
        return turn
    }

    mutating func markActiveTurnAwaitingResponse() {
        guard let activeTurnID,
              turns[activeTurnID]?.responseState == .awaitingResponse,
              !awaitingResponseTurnIDs.contains(activeTurnID) else { return }
        awaitingResponseTurnIDs.append(activeTurnID)
    }

    @discardableResult
    mutating func attachProviderUserItemID(
        _ providerItemID: ConversationProviderItemID,
        to turnID: ConversationTurnID? = nil
    ) -> ConversationTurnCorrelationSnapshot? {
        if let existingTurnID = turnByProviderUserItemID[providerItemID] {
            return turns[existingTurnID]
        }
        guard let resolvedTurnID = turnID ?? activeTurnID,
              var turn = turns[resolvedTurnID],
              turn.source == .userSpeech,
              turn.providerUserItemID == nil else { return nil }
        turn = replacing(turn, providerUserItemID: providerItemID)
        store(turn)
        turnByProviderUserItemID[providerItemID] = resolvedTurnID
        return turn
    }

    @discardableResult
    mutating func cancelAwaitingResponse(
        for turnID: ConversationTurnID
    ) -> ConversationTurnCorrelationSnapshot? {
        guard var turn = turns[turnID],
              turn.responseState == .awaitingResponse else { return nil }
        turn = replacing(turn, responseState: .cancelled)
        store(turn)
        awaitingResponseTurnIDs.removeAll { $0 == turnID }
        return turn
    }

    @discardableResult
    mutating func beginResponse(
        providerResponseID: ConversationProviderResponseID?
    ) -> ConversationTurnCorrelationSnapshot? {
        if let providerResponseID,
           let existingTurnID = turnByProviderResponseID[providerResponseID] {
            return turns[existingTurnID]
        }
        guard let sessionID else { return nil }

        let awaitingTurnID = nextAwaitingResponseTurnID()
        let isProviderContinuation = awaitingTurnID == nil
        let turnID = awaitingTurnID
            ?? createProviderInitiatedTurn(sessionID: sessionID).turnID
        guard var turn = turns[turnID] else { return nil }

        if let existingProviderResponseID = turn.providerResponseID,
           existingProviderResponseID != providerResponseID {
            return nil
        }
        turn = replacing(
            turn,
            responseID: turn.responseID ?? ConversationResponseID(),
            providerResponseID: providerResponseID ?? turn.providerResponseID,
            responseState: .responding
        )
        store(turn)
        if let providerResponseID {
            turnByProviderResponseID[providerResponseID] = turnID
        }
        if activeTurnID == nil || isProviderContinuation {
            activeTurnID = turnID
        }
        return turn
    }

    @discardableResult
    mutating func beginAssistantItem(
        identity: ConversationProviderEventIdentity
    ) -> ConversationTurnCorrelationSnapshot? {
        guard let providerItemID = identity.itemID else { return nil }
        if let existingTurnID = turnByProviderAssistantItemID[providerItemID] {
            return turns[existingTurnID]
        }
        guard var turn = resolveTurn(for: identity)
                ?? beginResponse(providerResponseID: identity.responseID) else { return nil }

        turn = replacing(
            turn,
            assistantItemID: turn.assistantItemID ?? ConversationAssistantItemID(),
            providerAssistantItemID: providerItemID
        )
        store(turn)
        turnByProviderAssistantItemID[providerItemID] = turn.turnID
        return turn
    }

    @discardableResult
    mutating func beginPlayback(
        identity: ConversationProviderEventIdentity
    ) -> ConversationTurnCorrelationSnapshot? {
        guard var turn = resolveTurn(for: identity),
              turn.turnID == activeTurnID else { return nil }

        let playbackID = turn.playbackID ?? ConversationPlaybackID()
        turn = replacing(
            turn,
            playbackID: playbackID,
            playbackState: .playing
        )
        store(turn)
        turnByPlaybackID[playbackID] = turn.turnID
        activePlaybackID = playbackID
        return turn
    }

    @discardableResult
    mutating func finishResponse(
        providerResponseID: ConversationProviderResponseID?,
        cancelled: Bool
    ) -> ConversationTurnCorrelationSnapshot? {
        guard var turn = resolveTurn(providerResponseID: providerResponseID) else { return nil }
        turn = replacing(
            turn,
            responseState: cancelled ? .cancelled : .completed,
            playbackState: cancelled && turn.playbackState == .playing
                ? .interrupted
                : turn.playbackState
        )
        store(turn)
        if cancelled, activePlaybackID == turn.playbackID {
            activePlaybackID = nil
        }
        return turn
    }

    @discardableResult
    mutating func finishActivePlayback(
        interrupted: Bool
    ) -> ConversationTurnCorrelationSnapshot? {
        guard let playbackID = activePlaybackID,
              let turnID = turnByPlaybackID[playbackID],
              var turn = turns[turnID] else { return nil }
        turn = replacing(
            turn,
            playbackState: interrupted ? .interrupted : .delivered
        )
        store(turn)
        activePlaybackID = nil
        return turn
    }

    func snapshot(
        for providerResponseID: ConversationProviderResponseID
    ) -> ConversationTurnCorrelationSnapshot? {
        turnByProviderResponseID[providerResponseID].flatMap { turns[$0] }
    }

    func snapshot(
        for providerUserItemID: ConversationProviderItemID
    ) -> ConversationTurnCorrelationSnapshot? {
        turnByProviderUserItemID[providerUserItemID].flatMap { turns[$0] }
    }

    func snapshot(
        for identity: ConversationProviderEventIdentity
    ) -> ConversationTurnCorrelationSnapshot? {
        resolveTurn(for: identity)
    }

    mutating func endSession() {
        sessionID = nil
        activeTurnID = nil
        activePlaybackID = nil
        turns.removeAll(keepingCapacity: false)
        turnByProviderUserItemID.removeAll(keepingCapacity: false)
        turnByProviderResponseID.removeAll(keepingCapacity: false)
        turnByProviderAssistantItemID.removeAll(keepingCapacity: false)
        turnByPlaybackID.removeAll(keepingCapacity: false)
        awaitingResponseTurnIDs.removeAll(keepingCapacity: false)
    }

    private mutating func cancelUnansweredOpeningGreetings() {
        let greetingTurnIDs = awaitingResponseTurnIDs.filter {
            turns[$0]?.source == .openingGreeting
        }
        for turnID in greetingTurnIDs {
            guard let turn = turns[turnID] else { continue }
            store(replacing(turn, responseState: .cancelled))
        }
        awaitingResponseTurnIDs.removeAll { greetingTurnIDs.contains($0) }
    }

    private mutating func nextAwaitingResponseTurnID() -> ConversationTurnID? {
        while !awaitingResponseTurnIDs.isEmpty {
            let turnID = awaitingResponseTurnIDs.removeFirst()
            if turns[turnID]?.responseState == .awaitingResponse {
                return turnID
            }
        }
        return nil
    }

    private mutating func createProviderInitiatedTurn(
        sessionID: ConversationSessionID
    ) -> ConversationTurnCorrelationSnapshot {
        let turn = ConversationTurnCorrelationSnapshot(
            sessionID: sessionID,
            turnID: ConversationTurnID(),
            source: .providerInitiated,
            providerUserItemID: nil,
            responseID: nil,
            providerResponseID: nil,
            assistantItemID: nil,
            providerAssistantItemID: nil,
            playbackID: nil,
            responseState: .awaitingResponse,
            playbackState: .idle
        )
        store(turn)
        return turn
    }

    private func resolveTurn(
        for identity: ConversationProviderEventIdentity
    ) -> ConversationTurnCorrelationSnapshot? {
        if let itemID = identity.itemID,
           let turnID = turnByProviderAssistantItemID[itemID] {
            return turns[turnID]
        }
        if let turn = resolveTurn(providerResponseID: identity.responseID) {
            return turn
        }
        guard identity.responseID == nil, identity.itemID == nil else { return nil }
        return activeTurn
    }

    private func resolveTurn(
        providerResponseID: ConversationProviderResponseID?
    ) -> ConversationTurnCorrelationSnapshot? {
        if let providerResponseID,
           let turnID = turnByProviderResponseID[providerResponseID] {
            return turns[turnID]
        }
        guard providerResponseID == nil,
              let activeTurn,
              activeTurn.responseID != nil else { return nil }
        return activeTurn
    }

    private mutating func store(_ turn: ConversationTurnCorrelationSnapshot) {
        turns[turn.turnID] = turn
    }

    private func replacing(
        _ turn: ConversationTurnCorrelationSnapshot,
        providerUserItemID: ConversationProviderItemID? = nil,
        responseID: ConversationResponseID? = nil,
        providerResponseID: ConversationProviderResponseID? = nil,
        assistantItemID: ConversationAssistantItemID? = nil,
        providerAssistantItemID: ConversationProviderItemID? = nil,
        playbackID: ConversationPlaybackID? = nil,
        responseState: ConversationResponseState? = nil,
        playbackState: ConversationPlaybackState? = nil
    ) -> ConversationTurnCorrelationSnapshot {
        ConversationTurnCorrelationSnapshot(
            sessionID: turn.sessionID,
            turnID: turn.turnID,
            source: turn.source,
            providerUserItemID: providerUserItemID ?? turn.providerUserItemID,
            responseID: responseID ?? turn.responseID,
            providerResponseID: providerResponseID ?? turn.providerResponseID,
            assistantItemID: assistantItemID ?? turn.assistantItemID,
            providerAssistantItemID: providerAssistantItemID ?? turn.providerAssistantItemID,
            playbackID: playbackID ?? turn.playbackID,
            responseState: responseState ?? turn.responseState,
            playbackState: playbackState ?? turn.playbackState
        )
    }
}
