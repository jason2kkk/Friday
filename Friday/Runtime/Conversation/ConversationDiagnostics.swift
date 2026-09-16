// 功能：把最近一轮 Talk 的无内容生命周期轨迹保存为本地 JSONL，便于真机问题定位。
// 职责：定义结构化结束原因、身份上下文与可替换记录接口，并管理诊断文件的覆盖、追加和关闭。
// 边界：不记录用户音频、对话文本、截图、Prompt 或密钥；每次新 Talk 覆盖上一轮，写入失败也不影响对话主流程。

import Foundation
import OSLog

enum ConversationEndReason: String, Sendable {
    case userRequested = "user_requested"
    case dictationStarted = "dictation_started"
    case startupFailure = "startup_failure"
    case audioFailure = "audio_failure"
    case providerFailure = "provider_failure"
    case responseLoopGuard = "response_loop_guard"
    case idleTimeout = "idle_timeout"
    case appStopped = "app_stopped"
}

struct ConversationDiagnosticContext: Sendable {
    var turnID: String?
    var responseID: String?
    var assistantItemID: String?
    var playbackID: String?
    var providerUserItemID: String?
    var providerResponseID: String?
    var providerAssistantItemID: String?

    static let empty = ConversationDiagnosticContext()
}

@MainActor
protocol ConversationDiagnosticsRecording: AnyObject {
    func beginSession(_ sessionID: ConversationSessionID, state: String)
    func record(
        _ event: String,
        state: String,
        context: ConversationDiagnosticContext,
        attributes: [String: String]
    )
    func finishSession(
        reason: ConversationEndReason,
        state: String,
        notice: String?
    )
}

extension ConversationDiagnosticsRecording {
    func record(
        _ event: String,
        state: String,
        context: ConversationDiagnosticContext = .empty,
        attributes: [String: String] = [:]
    ) {
        record(event, state: state, context: context, attributes: attributes)
    }
}

@MainActor
final class NoopConversationDiagnosticsRecorder: ConversationDiagnosticsRecording {
    func beginSession(_ sessionID: ConversationSessionID, state: String) {}

    func record(
        _ event: String,
        state: String,
        context: ConversationDiagnosticContext,
        attributes: [String: String]
    ) {}

    func finishSession(
        reason: ConversationEndReason,
        state: String,
        notice: String?
    ) {}
}

@MainActor
final class ConversationJSONLDiagnosticsRecorder: ConversationDiagnosticsRecording {
    static var defaultFileURL: URL {
        let applicationSupport = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first ?? FileManager.default.temporaryDirectory
        return applicationSupport
            .appendingPathComponent("Friday", isDirectory: true)
            .appendingPathComponent("Diagnostics", isDirectory: true)
            .appendingPathComponent("latest-talk.jsonl", isDirectory: false)
    }

    private let fileURL: URL
    private let logger = Logger(
        subsystem: "com.example.Friday",
        category: "TalkDiagnostics"
    )
    private let timestampFormatter: ISO8601DateFormatter
    private var fileHandle: FileHandle?
    private var sessionID: ConversationSessionID?
    private var sequence = 0

    init(fileURL: URL? = nil) {
        self.fileURL = fileURL ?? Self.defaultFileURL
        timestampFormatter = ISO8601DateFormatter()
        timestampFormatter.formatOptions = [
            .withInternetDateTime,
            .withFractionalSeconds
        ]
    }

    func beginSession(_ sessionID: ConversationSessionID, state: String) {
        closeFile()
        self.sessionID = sessionID
        sequence = 0

        do {
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try Data().write(to: fileURL, options: .atomic)
            fileHandle = try FileHandle(forWritingTo: fileURL)
            record("session.started", state: state)
        } catch {
            self.sessionID = nil
            closeFile()
            logger.error("Unable to open the Talk diagnostics trace")
        }
    }

    func record(
        _ event: String,
        state: String,
        context: ConversationDiagnosticContext,
        attributes: [String: String]
    ) {
        guard let sessionID, let fileHandle else { return }
        sequence += 1

        var object: [String: Any] = [
            "timestamp": timestampFormatter.string(from: Date()),
            "sequence": sequence,
            "event": event,
            "session_id": sessionID.description,
            "state": state
        ]
        Self.set(context.turnID, for: "turn_id", in: &object)
        Self.set(context.responseID, for: "response_id", in: &object)
        Self.set(context.assistantItemID, for: "assistant_item_id", in: &object)
        Self.set(context.playbackID, for: "playback_id", in: &object)
        Self.set(context.providerUserItemID, for: "provider_user_item_id", in: &object)
        Self.set(context.providerResponseID, for: "provider_response_id", in: &object)
        Self.set(
            context.providerAssistantItemID,
            for: "provider_assistant_item_id",
            in: &object
        )
        if !attributes.isEmpty {
            object["attributes"] = attributes
        }

        do {
            var data = try JSONSerialization.data(
                withJSONObject: object,
                options: [.sortedKeys]
            )
            data.append(0x0A)
            try fileHandle.write(contentsOf: data)
        } catch {
            logger.error("Unable to append to the Talk diagnostics trace")
        }
    }

    func finishSession(
        reason: ConversationEndReason,
        state: String,
        notice: String?
    ) {
        var attributes = ["reason": reason.rawValue]
        if let notice, !notice.isEmpty {
            attributes["notice"] = notice
        }
        record("session.finished", state: state, attributes: attributes)
        sessionID = nil
        closeFile()
    }

    private static func set(
        _ value: String?,
        for key: String,
        in object: inout [String: Any]
    ) {
        if let value, !value.isEmpty {
            object[key] = value
        }
    }

    private func closeFile() {
        try? fileHandle?.close()
        fileHandle = nil
    }
}
