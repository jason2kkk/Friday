// 功能：定义 Friday 对用户单轮语音最终转写的中立数据契约与可替换 Provider 边界。
// 职责：表达音频格式、最终转写来源、用量和健康状态，并提供零费用 Mock 与明确不可用实现。
// 边界：不决定 Talk 回复、不生成 Work，也不把 partial transcript 写入历史或记忆。

import Foundation

struct UserTurnAudioFormat: Equatable, Sendable {
    let sampleRate: Int
    let channelCount: Int
}

enum FinalUserTranscriptSource: String, Equatable, Sendable {
    case realtimeInput
    case localASR
    case dedicatedProvider
}

struct UserTurnTranscriptionUsage: Equatable, Sendable {
    let inputTokens: Int?
    let outputTokens: Int?
    let totalTokens: Int?
    let audioSeconds: Double?

    static let unavailable = UserTurnTranscriptionUsage(
        inputTokens: nil,
        outputTokens: nil,
        totalTokens: nil,
        audioSeconds: nil
    )
}

struct FinalUserTranscript: Equatable, Sendable {
    let turnID: ConversationTurnID
    let text: String
    let source: FinalUserTranscriptSource
    let language: String?
    let confidence: Double?
    let completedAt: Date
    let usage: UserTurnTranscriptionUsage?
}

enum UserTurnTranscriptionHealth: Equatable, Sendable {
    case ready
    case unavailable(String)
}

enum UserTurnTranscriptionError: LocalizedError {
    case unavailable
    case missingFinalTranscript

    var errorDescription: String? {
        switch self {
        case .unavailable:
            return "最终语音转写尚未启用。"
        case .missingFinalTranscript:
            return "这一轮没有得到可靠的最终语音转写。"
        }
    }
}

@MainActor
protocol UserTurnTranscriptionProviding: AnyObject {
    func begin(turnID: ConversationTurnID, audioFormat: UserTurnAudioFormat)
    func append(_ chunk: AudioChunk)
    func finalize(turnID: ConversationTurnID) async throws -> FinalUserTranscript
    func cancel(turnID: ConversationTurnID)
    func health() -> UserTurnTranscriptionHealth
}

@MainActor
final class UnavailableUserTurnTranscriptionProvider: UserTurnTranscriptionProviding {
    func begin(turnID: ConversationTurnID, audioFormat: UserTurnAudioFormat) {}
    func append(_ chunk: AudioChunk) {}

    func finalize(turnID: ConversationTurnID) async throws -> FinalUserTranscript {
        throw UserTurnTranscriptionError.unavailable
    }

    func cancel(turnID: ConversationTurnID) {}

    func health() -> UserTurnTranscriptionHealth {
        .unavailable("最终语音转写尚未启用")
    }
}

@MainActor
final class MockUserTurnTranscriptionProvider: UserTurnTranscriptionProviding {
    private var transcripts: [ConversationTurnID: FinalUserTranscript] = [:]

    func setTranscript(_ transcript: FinalUserTranscript) {
        transcripts[transcript.turnID] = transcript
    }

    func begin(turnID: ConversationTurnID, audioFormat: UserTurnAudioFormat) {}
    func append(_ chunk: AudioChunk) {}

    func finalize(turnID: ConversationTurnID) async throws -> FinalUserTranscript {
        guard let transcript = transcripts[turnID] else {
            throw UserTurnTranscriptionError.missingFinalTranscript
        }
        return transcript
    }

    func cancel(turnID: ConversationTurnID) {
        transcripts.removeValue(forKey: turnID)
    }

    func health() -> UserTurnTranscriptionHealth {
        .ready
    }
}
