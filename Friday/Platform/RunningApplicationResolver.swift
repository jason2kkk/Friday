// 功能：把用户或模型给出的应用名称解析为本机唯一应用，并按本地 Agent 请求启动或激活它。
// 职责：统一名称规范化、常用别名、Bundle ID、运行列表和已安装 Bundle 匹配，启动后复验目标进程位于前台。
// 边界：不读取 Accessibility 树、不选择输入控件，也不根据歧义名称或模糊坐标猜测目标应用。

import AppKit
import Foundation
import OSLog

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

enum ApplicationActivationResolution: Equatable, Sendable {
    case activated(RunningApplicationReference, wasAlreadyRunning: Bool)
    case notFound(String)
    case ambiguous(String)
    case failed(String, ApplicationActivationFailure)
}

enum ApplicationActivationFailure: String, Equatable, Sendable {
    case processUnavailable = "application_process_unavailable"
    case launchServicesFailed = "application_launch_failed"
    case frontmostTimeout = "application_frontmost_timeout"
}

@MainActor
protocol RunningApplicationResolving: AnyObject {
    func resolve(_ applicationHint: String) -> RunningApplicationResolution
    func activate(_ applicationHint: String) async -> ApplicationActivationResolution
}

extension RunningApplicationResolving {
    func activate(_ applicationHint: String) async -> ApplicationActivationResolution {
        switch resolve(applicationHint) {
        case .resolved(let application):
            return .activated(application, wasAlreadyRunning: true)
        case .notRunning:
            return .notFound(applicationHint)
        case .ambiguous:
            return .ambiguous(applicationHint)
        }
    }
}

@MainActor
final class RunningApplicationResolver: RunningApplicationResolving {
    struct Candidate: Equatable {
        let reference: RunningApplicationReference
        let searchableNames: [String]
    }

    struct InstalledCandidate: Equatable {
        let bundleURL: URL
        let localizedName: String
        let bundleIdentifier: String?
        let searchableNames: [String]
    }

    private let candidateProvider: () -> [Candidate]
    private let installedCandidateProvider: () -> [InstalledCandidate]
    private let logger = Logger(
        subsystem: "com.example.Friday",
        category: "ApplicationActivation"
    )

    init(
        candidateProvider: (() -> [Candidate])? = nil,
        installedCandidateProvider: (() -> [InstalledCandidate])? = nil
    ) {
        self.candidateProvider = candidateProvider ?? Self.currentCandidates
        self.installedCandidateProvider = installedCandidateProvider
            ?? Self.currentInstalledCandidates
    }

    func resolve(_ applicationHint: String) -> RunningApplicationResolution {
        let normalizedHint = Self.normalize(applicationHint)
        guard !normalizedHint.isEmpty else { return .notRunning(applicationHint) }

        let candidates = candidateProvider()
        let scored = candidates.compactMap { candidate -> (Candidate, Int)? in
            guard let score = Self.matchScore(
                normalizedHint: normalizedHint,
                bundleIdentifier: candidate.reference.bundleIdentifier,
                searchableNames: candidate.searchableNames
            ) else { return nil }
            return (candidate, score)
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

    func activate(_ applicationHint: String) async -> ApplicationActivationResolution {
        switch resolve(applicationHint) {
        case .resolved(let reference):
            return await activateRunning(reference, wasAlreadyRunning: true)
        case .ambiguous:
            return .ambiguous(applicationHint)
        case .notRunning:
            break
        }

        switch resolveInstalled(applicationHint) {
        case .notFound:
            return .notFound(applicationHint)
        case .ambiguous:
            return .ambiguous(applicationHint)
        case .resolved(let candidate):
            do {
                let configuration = NSWorkspace.OpenConfiguration()
                configuration.activates = true
                configuration.createsNewApplicationInstance = false
                let application = try await openApplication(
                    at: candidate.bundleURL,
                    configuration: configuration
                )
                let reference = RunningApplicationReference(
                    processIdentifier: application.processIdentifier,
                    localizedName: application.localizedName ?? candidate.localizedName,
                    bundleIdentifier: application.bundleIdentifier
                        ?? candidate.bundleIdentifier
                )
                return await activateRunning(reference, wasAlreadyRunning: false)
            } catch {
                logger.error("LaunchServices could not start the resolved application bundle")
                return .failed(applicationHint, .launchServicesFailed)
            }
        }
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

    private func resolveInstalled(_ applicationHint: String) -> InstalledResolution {
        let normalizedHint = Self.normalize(applicationHint)
        guard !normalizedHint.isEmpty else { return .notFound }

        let scored = installedCandidateProvider().compactMap {
            candidate -> (InstalledCandidate, Int)? in
            guard let score = Self.matchScore(
                normalizedHint: normalizedHint,
                bundleIdentifier: candidate.bundleIdentifier,
                searchableNames: candidate.searchableNames
            ) else { return nil }
            return (candidate, score)
        }
        guard let topScore = scored.map(\.1).max() else { return .notFound }
        let matches = scored.filter { $0.1 == topScore }.map(\.0)
        let uniqueMatches = Dictionary(
            grouping: matches,
            by: { $0.bundleURL.standardizedFileURL }
        ).compactMap(\.value.first)
        guard uniqueMatches.count == 1, let match = uniqueMatches.first else {
            return .ambiguous
        }
        return .resolved(match)
    }

    private func activateRunning(
        _ reference: RunningApplicationReference,
        wasAlreadyRunning: Bool
    ) async -> ApplicationActivationResolution {
        guard let application = NSRunningApplication(
            processIdentifier: reference.processIdentifier
        ), !application.isTerminated else {
            logger.notice(
                "Resolved application process is unavailable; pid=\(reference.processIdentifier, privacy: .public)"
            )
            return .failed(reference.localizedName, .processUnavailable)
        }

        if let activatedReference = frontmostReference(matching: reference) {
            return .activated(activatedReference, wasAlreadyRunning: wasAlreadyRunning)
        }

        _ = application.unhide()
        let activationAccepted = application.activate(options: [.activateAllWindows])
        logger.info(
            "Requested application activation; pid=\(reference.processIdentifier, privacy: .public), accepted=\(activationAccepted, privacy: .public)"
        )
        if let activatedReference = await waitForFrontmostApplication(
            matching: reference,
            attempts: 12
        ) {
            return .activated(activatedReference, wasAlreadyRunning: wasAlreadyRunning)
        }

        guard !application.isTerminated else {
            logger.notice(
                "Application terminated while activation was pending; pid=\(reference.processIdentifier, privacy: .public)"
            )
            return .failed(reference.localizedName, .processUnavailable)
        }
        guard let bundleURL = application.bundleURL else {
            logger.notice(
                "Application did not become frontmost and has no Bundle URL; pid=\(reference.processIdentifier, privacy: .public)"
            )
            return .failed(reference.localizedName, .frontmostTimeout)
        }

        do {
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.activates = true
            configuration.createsNewApplicationInstance = false
            configuration.addsToRecentItems = false
            let reopenedApplication = try await openApplication(
                at: bundleURL,
                configuration: configuration
            )
            _ = reopenedApplication.unhide()
            _ = reopenedApplication.activate(options: [.activateAllWindows])
            let reopenedReference = RunningApplicationReference(
                processIdentifier: reopenedApplication.processIdentifier,
                localizedName: reopenedApplication.localizedName ?? reference.localizedName,
                bundleIdentifier: reopenedApplication.bundleIdentifier ?? reference.bundleIdentifier
            )
            logger.info(
                "Retried application activation through LaunchServices; pid=\(reopenedReference.processIdentifier, privacy: .public)"
            )
            if let activatedReference = await waitForFrontmostApplication(
                matching: reopenedReference,
                attempts: 28
            ) {
                return .activated(activatedReference, wasAlreadyRunning: wasAlreadyRunning)
            }
        } catch {
            logger.error("LaunchServices activation retry failed for the resolved application")
            return .failed(reference.localizedName, .launchServicesFailed)
        }

        logger.notice(
            "Application did not become frontmost before timeout; pid=\(reference.processIdentifier, privacy: .public), bundle=\(reference.bundleIdentifier ?? "unknown", privacy: .public)"
        )
        return .failed(reference.localizedName, .frontmostTimeout)
    }

    private func waitForFrontmostApplication(
        matching reference: RunningApplicationReference,
        attempts: Int
    ) async -> RunningApplicationReference? {
        for _ in 0..<attempts {
            if let frontmost = frontmostReference(matching: reference) {
                return frontmost
            }
            try? await Task.sleep(for: .milliseconds(100))
        }
        return frontmostReference(matching: reference)
    }

    private func frontmostReference(
        matching reference: RunningApplicationReference
    ) -> RunningApplicationReference? {
        guard let frontmost = NSWorkspace.shared.frontmostApplication else { return nil }
        let hasMatchingProcess = frontmost.processIdentifier == reference.processIdentifier
        let hasMatchingBundle: Bool
        if let expectedBundle = reference.bundleIdentifier?.lowercased(),
           let frontmostBundle = frontmost.bundleIdentifier?.lowercased() {
            hasMatchingBundle = expectedBundle == frontmostBundle
        } else {
            hasMatchingBundle = false
        }
        guard hasMatchingProcess || hasMatchingBundle else { return nil }
        return RunningApplicationReference(
            processIdentifier: frontmost.processIdentifier,
            localizedName: frontmost.localizedName ?? reference.localizedName,
            bundleIdentifier: frontmost.bundleIdentifier ?? reference.bundleIdentifier
        )
    }

    private func openApplication(
        at url: URL,
        configuration: NSWorkspace.OpenConfiguration
    ) async throws -> NSRunningApplication {
        try await withCheckedThrowingContinuation { continuation in
            NSWorkspace.shared.openApplication(
                at: url,
                configuration: configuration
            ) { application, error in
                if let application {
                    continuation.resume(returning: application)
                } else {
                    continuation.resume(
                        throwing: error ?? ApplicationLaunchError.noRunningApplication
                    )
                }
            }
        }
    }

    private static func matchScore(
        normalizedHint: String,
        bundleIdentifier: String?,
        searchableNames: [String]
    ) -> Int? {
        let knownBundleIDs = bundleAliases[normalizedHint] ?? []
        if let bundleIdentifier,
           knownBundleIDs.contains(bundleIdentifier.lowercased()) {
            return 300
        }

        let names = searchableNames.map(normalize).filter { !$0.isEmpty }
        if names.contains(normalizedHint) {
            return 200
        }
        guard normalizedHint.count >= 4,
              names.contains(where: {
                  $0.count >= 4
                      && ($0.contains(normalizedHint) || normalizedHint.contains($0))
              }) else { return nil }
        return 100
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

    private static func currentInstalledCandidates() -> [InstalledCandidate] {
        let fileManager = FileManager.default
        let applicationDirectories = [
            URL(fileURLWithPath: "/Applications", isDirectory: true),
            URL(fileURLWithPath: "/System/Applications", isDirectory: true),
            URL(fileURLWithPath: "/System/Applications/Utilities", isDirectory: true),
            fileManager.homeDirectoryForCurrentUser
                .appendingPathComponent("Applications", isDirectory: true)
        ]
        var seenURLs = Set<URL>()
        var candidates: [InstalledCandidate] = []

        for directory in applicationDirectories where fileManager.fileExists(atPath: directory.path) {
            guard let enumerator = fileManager.enumerator(
                at: directory,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles, .skipsPackageDescendants]
            ) else { continue }

            for case let url as URL in enumerator where url.pathExtension.lowercased() == "app" {
                let standardizedURL = url.standardizedFileURL
                guard seenURLs.insert(standardizedURL).inserted,
                      let bundle = Bundle(url: standardizedURL) else { continue }
                let bundleName = standardizedURL.deletingPathExtension().lastPathComponent
                let localizedName = bundle.object(
                    forInfoDictionaryKey: "CFBundleDisplayName"
                ) as? String
                    ?? bundle.object(forInfoDictionaryKey: "CFBundleName") as? String
                    ?? bundleName
                let bundleIdentifier = bundle.bundleIdentifier
                let executableName = bundle.executableURL?.lastPathComponent ?? ""
                let bundleTail = bundleIdentifier?.split(separator: ".").last.map(String.init)
                    ?? ""
                candidates.append(
                    InstalledCandidate(
                        bundleURL: standardizedURL,
                        localizedName: localizedName,
                        bundleIdentifier: bundleIdentifier,
                        searchableNames: [
                            localizedName,
                            bundleName,
                            executableName,
                            bundleIdentifier ?? "",
                            bundleTail
                        ]
                    )
                )
            }
        }
        return candidates
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
        "wechat": ["com.tencent.xinwechat"],
        "微信": ["com.tencent.xinwechat"],
        "备忘录": ["com.apple.notes"],
        "便签": ["com.apple.stickies"],
        "文本编辑": ["com.apple.textedit"],
        "textedit": ["com.apple.textedit"]
    ]
}

private enum InstalledResolution {
    case resolved(RunningApplicationResolver.InstalledCandidate)
    case notFound
    case ambiguous
}

private enum ApplicationLaunchError: Error {
    case noRunningApplication
}
