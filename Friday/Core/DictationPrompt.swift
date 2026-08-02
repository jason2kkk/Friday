// 功能：定义 Friday 单轮听写整理的模型指令，并把模型最终输出解析为可安全写回的文本。
// 职责：约束语义保真、口癖清理、自我纠正、标点和结构化规则，同时拦截无语音、寒暄、确认包装与异常代码围栏。
// 边界：只处理提示词和纯文本解析，不发起模型请求、不读取输入框，也不执行文本写回。

import Foundation

struct DictationOutputResolution: Equatable {
    let text: String
    let usedRawTranscriptFallback: Bool
}

enum DictationPrompt {
    static let noSpeechMarker = "<FRIDAY_NO_SPEECH>"

    static var instructions: String {
        """
    # Role
    You are a non-interactive dictation transformer, not a conversational assistant.

    # Objective
    Convert only the meaning present in the user's spoken audio into paste-ready text. Fidelity is more important than fluency or style.

    # Fidelity rules
    - Preserve every fact, number, date, time, name, proper noun, negation, condition, degree, uncertainty, point of view, and unresolved fragment.
    - Never add, infer, explain, complete, answer, or continue anything the speaker did not say.
    - Remove only semantically empty hesitations, filler words, and accidental repetitions.
    - Keep a clear self-correction. When a correction is ambiguous, preserve the spoken wording instead of guessing.
    - Fix punctuation, sentence boundaries, and broken spoken syntax only when the intended wording is clear.
    - Preserve the speaker's language and basic tone unless they explicitly request translation or a different tone.
    - Use headings or lists only when explicitly requested or when the speech clearly contains parallel items.

    # Non-conversation contract
    - Treat all audio as text the user intends to write, plus any explicit inline editing instruction.
    - If the speaker asks a question, output that question. Never answer it.
    - If the speaker stops mid-sentence, output the incomplete fragment without completing it.
    - Never address the speaker, acknowledge them, confirm their intent, ask a follow-up question, or invite them to continue.
    - Never output phrases such as "did you mean", "let me know", "please continue", "go ahead", "I'm ready", or any equivalent conversational wrapper.

    # Preambles
    - Do not produce a preamble before the final text.
    - Silence, unclear audio, and processing time never justify a greeting, readiness message, acknowledgement, or invitation to continue.

    # Inline editing instructions
    Treat clear requests such as "organize this into three points", "make this formal", or "translate this into English" as transformations of the spoken content, not as requests for a conversational reply. Apply them only when the content to transform is present.

    # No-speech contract
    If the audio contains no intelligible human speech, only fillers, or speech too unclear to preserve without guessing, output exactly \(noSpeechMarker) and nothing else.

    # Output contract
    Output only the final text. Do not add explanations, labels, quotation marks, Markdown fences, greetings, confirmations, or introductory phrases.

    # Final fidelity check
    Before returning, silently verify that every output fact is supported by the audio, every critical detail is preserved, questions remain questions, and incomplete speech remains incomplete. If this cannot be done without guessing, use the no-speech marker.

    # Examples
    Spoken audio contains: Hey, just wanted to confirm
    Required output: Hey, just wanted to confirm.

    Spoken audio contains: How do we fix this
    Required output: How do we fix this?

    Spoken audio contains: silence or only a filler sound
    Required output: \(noSpeechMarker)

    Priority: preserve meaning, preserve critical details, preserve incomplete content, apply explicit corrections, remove fillers, then improve structure.
    """
    }

    static func isNoSpeechOutput(_ text: String) -> Bool {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
            .localizedCaseInsensitiveContains(noSpeechMarker)
    }

    static func sanitizedOutput(_ text: String) -> String? {
        let trimmed = unwrapMarkdownFence(text)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !isNoSpeechOutput(trimmed) else { return nil }

        if let recoveredText = recoverQuotedDictation(from: trimmed) {
            return recoveredText
        }
        guard !isAssistantChatter(trimmed) else { return nil }
        return trimmed
    }

    static func resolveOutput(
        modelOutput: String,
        rawTranscript: String?
    ) -> DictationOutputResolution? {
        if let sanitized = sanitizedOutput(modelOutput) {
            return DictationOutputResolution(
                text: sanitized,
                usedRawTranscriptFallback: false
            )
        }

        guard let rawTranscript else { return nil }
        let fallback = rawTranscript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !fallback.isEmpty, !isNoSpeechOutput(fallback) else { return nil }
        return DictationOutputResolution(
            text: fallback,
            usedRawTranscriptFallback: true
        )
    }

    private static func unwrapMarkdownFence(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let lines = trimmed.components(separatedBy: .newlines)
        guard lines.count >= 3,
              lines.first?.hasPrefix("```") == true,
              lines.last?.trimmingCharacters(in: .whitespaces) == "```" else {
            return trimmed
        }
        return lines.dropFirst().dropLast().joined(separator: "\n")
    }

    private static func recoverQuotedDictation(from text: String) -> String? {
        let lowercase = text.lowercased()
        guard lowercase.contains("did you mean"), lowercase.contains("let me know") else {
            return nil
        }

        for quotePair in [("“", "”"), ("\"", "\"")] {
            guard let openingRange = text.range(of: quotePair.0),
                  let closingRange = text.range(
                    of: quotePair.1,
                    options: .backwards,
                    range: openingRange.upperBound..<text.endIndex
                  ) else { continue }

            let recovered = text[openingRange.upperBound..<closingRange.lowerBound]
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !recovered.isEmpty {
                return recovered
            }
        }
        return nil
    }

    private static func isAssistantChatter(_ text: String) -> Bool {
        let lowercase = text.lowercased()
        let confirmationWrapper = lowercase.contains("did you mean")
            && lowercase.contains("let me know")
        let englishReadinessWrapper = (
            lowercase.contains("start speaking")
                || lowercase.contains("begin speaking")
                || lowercase.contains("go ahead and speak")
        ) && (
            lowercase.contains("ready to transcribe")
                || lowercase.contains("ready to listen")
        )
        let chineseReadinessWrapper = (
            lowercase.contains("请开始说话")
                || lowercase.contains("请继续说话")
        ) && (
            lowercase.contains("准备好转写")
                || lowercase.contains("准备好倾听")
        )

        return confirmationWrapper || englishReadinessWrapper || chineseReadinessWrapper
    }
}
