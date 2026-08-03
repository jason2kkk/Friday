// 功能：为每轮 Talk 建立稳定会话身份、无内容用量账本和响应循环保护。
// 职责：维护会话快照、拒绝迟到用量，并区分正常用户回合与没有新用户输入的自主响应风暴。
// 边界：不记录用户内容、不跨重启持久化，也不直接控制 Provider、音频、诊断文件或界面。

import Foundation

struct ConversationSessionID: Hashable, Sendable, CustomStringConvertible {
    let rawValue: UUID

    init(rawValue: UUID = UUID()) {
        self.rawValue = rawValue
    }

    var description: String {
        rawValue.uuidString.lowercased()
    }
}

struct ConversationSessionSnapshot: Equatable, Sendable {
    let id: ConversationSessionID?
    let isActive: Bool
    let completedResponses: Int
    let totalTokens: Int
    let estimatedCostUSD: Double

    static let idle = ConversationSessionSnapshot(
        id: nil,
        isActive: false,
        completedResponses: 0,
        totalTokens: 0,
        estimatedCostUSD: 0
    )
}

struct ConversationUsageUpdate: Equatable, Sendable {
    let didRecord: Bool
    let responseCostUSD: Double
    let snapshot: ConversationSessionSnapshot
}

struct ConversationSessionLedger {
    private(set) var snapshot = ConversationSessionSnapshot.idle

    @discardableResult
    mutating func beginSession() -> ConversationSessionSnapshot {
        snapshot = ConversationSessionSnapshot(
            id: ConversationSessionID(),
            isActive: true,
            completedResponses: 0,
            totalTokens: 0,
            estimatedCostUSD: 0
        )
        return snapshot
    }

    @discardableResult
    mutating func record(_ usage: DictationUsage) -> ConversationUsageUpdate {
        guard snapshot.isActive else {
            return ConversationUsageUpdate(
                didRecord: false,
                responseCostUSD: 0,
                snapshot: snapshot
            )
        }

        let responseCost = RealtimeTalkPricing.estimatedCostUSD(for: usage)
        snapshot = ConversationSessionSnapshot(
            id: snapshot.id,
            isActive: true,
            completedResponses: snapshot.completedResponses + 1,
            totalTokens: snapshot.totalTokens + usage.totalTokens,
            estimatedCostUSD: snapshot.estimatedCostUSD + responseCost
        )
        return ConversationUsageUpdate(
            didRecord: true,
            responseCostUSD: responseCost,
            snapshot: snapshot
        )
    }

    @discardableResult
    mutating func endSession() -> ConversationSessionSnapshot {
        snapshot = ConversationSessionSnapshot(
            id: snapshot.id,
            isActive: false,
            completedResponses: snapshot.completedResponses,
            totalTokens: snapshot.totalTokens,
            estimatedCostUSD: snapshot.estimatedCostUSD
        )
        return snapshot
    }
}

struct ConversationResponseLoopGuard: Equatable, Sendable {
    let maximumResponses: Int
    let window: TimeInterval
    private(set) var responseTimes: [Date] = []

    var consecutiveResponseCount: Int {
        responseTimes.count
    }

    static let safety = ConversationResponseLoopGuard(
        maximumResponses: 4,
        window: 30
    )

    mutating func recordResponse(at date: Date = Date()) -> Bool {
        let cutoff = date.addingTimeInterval(-window)
        responseTimes.removeAll { $0 < cutoff }
        responseTimes.append(date)
        return responseTimes.count >= maximumResponses
    }

    mutating func reset() {
        responseTimes.removeAll(keepingCapacity: true)
    }

    mutating func recordUserTurn() {
        reset()
    }
}
