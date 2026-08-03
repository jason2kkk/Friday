// 功能：把用户或模型给出的应用名称解析为当前 Mac 上唯一、正在运行的应用进程。
// 职责：统一应用名规范化、常用别名、Bundle ID 和动态运行列表匹配，并对未运行或歧义结果明确失败。
// 边界：不启动或激活应用、不读取 Accessibility 树，也不根据模糊匹配猜测多个候选中的一个。

import AppKit
import Foundation

struct RunningApplicationReference: Equatable, Sendable {
    let processIdentifier: pid_t
    let localizedName: String
    let bundleIdentifier: String?
}

enum RunningApplicationResolution: Equatable, Sendable {
    case resolved(RunningApplicationReference)
    case notRunning(String)
    case ambiguous(String)
}

@MainActor
protocol RunningApplicationResolving: AnyObject {
    func resolve(_ applicationHint: String) -> RunningApplicationResolution
}

@MainActor
final class RunningApplicationResolver: RunningApplicationResolving {
    struct Candidate: Equatable {
        let reference: RunningApplicationReference
        let searchableNames: [String]
    }

    private let candidateProvider: () -> [Candidate]

    init(candidateProvider: (() -> [Candidate])? = nil) {
        self.candidateProvider = candidateProvider ?? Self.currentCandidates
    }

    func resolve(_ applicationHint: String) -> RunningApplicationResolution {
        let normalizedHint = Self.normalize(applicationHint)
        guard !normalizedHint.isEmpty else { return .notRunning(applicationHint) }

        let knownBundleIDs = Self.bundleAliases[normalizedHint] ?? []
        let candidates = candidateProvider()
        let scored = candidates.compactMap { candidate -> (Candidate, Int)? in
            if let bundleIdentifier = candidate.reference.bundleIdentifier,
               knownBundleIDs.contains(bundleIdentifier.lowercased()) {
                return (candidate, 300)
            }

            let names = candidate.searchableNames.map(Self.normalize).filter { !$0.isEmpty }
            if names.contains(normalizedHint) {
                return (candidate, 200)
            }
            guard normalizedHint.count >= 4,
                  names.contains(where: {
                      $0.count >= 4
                          && ($0.contains(normalizedHint) || normalizedHint.contains($0))
                  }) else { return nil }
            return (candidate, 100)
        }

        guard let topScore = scored.map(\.1).max() else {
            return .notRunning(applicationHint)
        }
        let topMatches = scored.filter { $0.1 == topScore }.map(\.0)
        let uniqueMatches = Dictionary(
            grouping: topMatches,
            by: { $0.reference.processIdentifier }
        ).compactMap(\.value.first)

        guard uniqueMatches.count == 1, let match = uniqueMatches.first else {
            return .ambiguous(applicationHint)
        }
        return .resolved(match.reference)
    }

    static func normalize(_ rawValue: String) -> String {
        var value = rawValue.folding(
            options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive],
            locale: Locale(identifier: "en_US_POSIX")
        ).lowercased()
        for suffix in ["application", "客户端", "应用", "app"] {
            if value.hasSuffix(suffix) {
                value.removeLast(suffix.count)
            }
        }
        return String(value.unicodeScalars.filter {
            CharacterSet.alphanumerics.contains($0)
        })
    }

    private static func currentCandidates() -> [Candidate] {
        NSWorkspace.shared.runningApplications.compactMap { application in
            guard !application.isTerminated,
                  application.activationPolicy == .regular,
                  application.processIdentifier != ProcessInfo.processInfo.processIdentifier else {
                return nil
            }
            let name = application.localizedName ?? ""
            let bundleIdentifier = application.bundleIdentifier
            let bundleName = application.bundleURL?
                .deletingPathExtension()
                .lastPathComponent ?? ""
            let executableName = application.executableURL?.lastPathComponent ?? ""
            let bundleTail = bundleIdentifier?.split(separator: ".").last.map(String.init) ?? ""
            return Candidate(
                reference: RunningApplicationReference(
                    processIdentifier: application.processIdentifier,
                    localizedName: name.isEmpty ? bundleName : name,
                    bundleIdentifier: bundleIdentifier
                ),
                searchableNames: [name, bundleName, executableName, bundleIdentifier ?? "", bundleTail]
            )
        }
    }

    private static let bundleAliases: [String: Set<String>] = [
        "codex": ["com.openai.codex"],
        "chatgpt": ["com.openai.codex", "com.openai.chat"],
        "xcode": ["com.apple.dt.xcode"],
        "vscode": ["com.microsoft.vscode"],
        "visualstudiocode": ["com.microsoft.vscode"],
        "safari": ["com.apple.safari"],
        "chrome": ["com.google.chrome"],
        "googlechrome": ["com.google.chrome"],
        "备忘录": ["com.apple.notes"],
        "便签": ["com.apple.stickies"],
        "文本编辑": ["com.apple.textedit"],
        "textedit": ["com.apple.textedit"]
    ]
}
