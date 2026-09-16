// 功能：用零成本自动测试验证 Dictate 与 Talk 交互音效的事件映射和 App Bundle 资源完整性。
// 职责：覆盖四个指定提示音、明确无声的失败/结束分支，并检查内置 WAV 可被运行时按名称找到。
// 边界：不实际播放扬声器、不采集麦克风、不启动 Talk 或 Dictate，也不连接任何网络与模型服务。

import XCTest
@testable import Friday

final class InteractionSoundServiceTests: XCTestCase {
    func testWorkflowEventsMapToSelectedCuelumeSounds() {
        XCTAssertEqual(
            InteractionSoundPolicy.cue(for: .dictateCaptureRequested),
            .chime
        )
        XCTAssertEqual(
            InteractionSoundPolicy.cue(for: .dictateProcessingStarted),
            .sparkle
        )
        XCTAssertEqual(
            InteractionSoundPolicy.cue(for: .talkCaptureRequested),
            .success
        )
        XCTAssertEqual(
            InteractionSoundPolicy.cue(for: .dictateProcessingFailed),
            .error
        )
    }

    func testPolicyKeepsUnrelatedWorkflowOutcomesSilent() {
        let silentEvents: [InteractionSoundEvent] = [
            .dictateNoSpeech,
            .dictateRecordingTooShort,
            .dictateCaptureFailed,
            .dictateInsertionFailed,
            .talkEnded,
            .talkFailed
        ]

        for event in silentEvents {
            XCTAssertNil(InteractionSoundPolicy.cue(for: event))
        }
    }

    func testSelectedSoundResourcesAreBundledAsPCM16WAV() throws {
        for cue in InteractionSoundCue.allCases {
            let url = try XCTUnwrap(
                Bundle.main.url(forResource: cue.rawValue, withExtension: "wav"),
                "Missing bundled sound: \(cue.rawValue).wav"
            )
            let data = try Data(contentsOf: url, options: .mappedIfSafe)

            XCTAssertGreaterThan(data.count, 44)
            XCTAssertEqual(String(data: data.prefix(4), encoding: .ascii), "RIFF")
            XCTAssertEqual(String(data: data.dropFirst(8).prefix(4), encoding: .ascii), "WAVE")
        }
    }
}
