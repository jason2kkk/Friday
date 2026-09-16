// 功能：截取用户明确框选的屏幕区域，并生成适合 Realtime Talk 使用的压缩图片上下文。
// 职责：检查屏幕录制权限，把 AppKit 全局坐标转换为 ScreenCaptureKit 坐标，选择目标显示器并在内存中完成裁剪和 JPEG 编码。
// 边界：不主动选择区域、不持续监控屏幕、不写入磁盘或日志，也不负责把图片发送给模型。

import AppKit
import CoreVideo
import ScreenCaptureKit

struct ScreenRegionSelection: Equatable {
    let displayID: CGDirectDisplayID
    let screenFrame: CGRect
    let selectedFrame: CGRect
}

enum ScreenRegionGeometry {
    static func sourceRect(for selection: ScreenRegionSelection) -> CGRect {
        CGRect(
            x: selection.selectedFrame.minX - selection.screenFrame.minX,
            y: selection.screenFrame.maxY - selection.selectedFrame.maxY,
            width: selection.selectedFrame.width,
            height: selection.selectedFrame.height
        )
    }
}

@MainActor
protocol ScreenRegionCapturing: AnyObject {
    var isAuthorized: Bool { get }

    func requestAuthorization() -> Bool
    func capture(_ selection: ScreenRegionSelection) async throws -> ConversationImage
    func openPrivacySettings()
}

@MainActor
final class ScreenRegionCaptureService: ScreenRegionCapturing {
    enum CaptureError: LocalizedError {
        case permissionDenied
        case displayUnavailable
        case invalidSelection
        case captureFailed
        case encodingFailed

        var errorDescription: String? {
            switch self {
            case .permissionDenied:
                return "请先允许 Olli 录制屏幕。"
            case .displayUnavailable:
                return "刚才选择的屏幕已不可用，请重新选择。"
            case .invalidSelection:
                return "选择区域太小，请重新框选。"
            case .captureFailed:
                return "Olli 暂时无法读取这个屏幕区域。"
            case .encodingFailed:
                return "Olli 无法处理这张屏幕图片。"
            }
        }
    }

    private static let minimumSelectionLength: CGFloat = 12
    private static let maximumImageLongEdge = 1_800
    private static let jpegQuality = 0.82

    var isAuthorized: Bool {
        CGPreflightScreenCaptureAccess()
    }

    func requestAuthorization() -> Bool {
        isAuthorized || CGRequestScreenCaptureAccess()
    }

    func capture(_ selection: ScreenRegionSelection) async throws -> ConversationImage {
        guard isAuthorized else { throw CaptureError.permissionDenied }
        guard selection.selectedFrame.width >= Self.minimumSelectionLength,
              selection.selectedFrame.height >= Self.minimumSelectionLength else {
            throw CaptureError.invalidSelection
        }

        let content: SCShareableContent
        do {
            content = try await SCShareableContent.excludingDesktopWindows(
                false,
                onScreenWindowsOnly: true
            )
        } catch {
            throw CaptureError.captureFailed
        }

        guard let display = content.displays.first(where: {
            $0.displayID == selection.displayID
        }) else {
            throw CaptureError.displayUnavailable
        }

        let ownApplication = content.applications.first(where: {
            $0.processID == ProcessInfo.processInfo.processIdentifier
        })
        let filter: SCContentFilter
        if let ownApplication {
            filter = SCContentFilter(
                display: display,
                excludingApplications: [ownApplication],
                exceptingWindows: []
            )
        } else {
            filter = SCContentFilter(display: display, excludingWindows: [])
        }

        let sourceRect = ScreenRegionGeometry.sourceRect(for: selection)
        let pointPixelScale = max(1, CGFloat(filter.pointPixelScale))
        let naturalPixelSize = CGSize(
            width: sourceRect.width * pointPixelScale,
            height: sourceRect.height * pointPixelScale
        )
        let longEdge = max(naturalPixelSize.width, naturalPixelSize.height)
        let outputScale = min(1, CGFloat(Self.maximumImageLongEdge) / max(1, longEdge))
        let outputSize = CGSize(
            width: max(1, floor(naturalPixelSize.width * outputScale)),
            height: max(1, floor(naturalPixelSize.height * outputScale))
        )

        let configuration = SCStreamConfiguration()
        configuration.sourceRect = sourceRect
        configuration.width = Int(outputSize.width)
        configuration.height = Int(outputSize.height)
        configuration.scalesToFit = true
        configuration.showsCursor = false
        configuration.capturesAudio = false
        configuration.pixelFormat = kCVPixelFormatType_32BGRA

        let image: CGImage
        do {
            image = try await SCScreenshotManager.captureImage(
                contentFilter: filter,
                configuration: configuration
            )
        } catch {
            throw CaptureError.captureFailed
        }

        let representation = NSBitmapImageRep(cgImage: image)
        guard let data = representation.representation(
            using: .jpeg,
            properties: [.compressionFactor: Self.jpegQuality]
        ), !data.isEmpty else {
            throw CaptureError.encodingFailed
        }

        return ConversationImage(
            data: data,
            mimeType: "image/jpeg",
            pixelWidth: image.width,
            pixelHeight: image.height
        )
    }

    func openPrivacySettings() {
        guard let url = URL(
            string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture"
        ) else { return }
        NSWorkspace.shared.open(url)
    }
}
