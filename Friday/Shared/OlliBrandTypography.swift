// 功能：注册 Olli 随应用分发的 Mali 字体，并为 SwiftUI 与 AppKit 提供统一的品牌字形入口。
// 职责：在进程范围注册 Mali-Bold 和 Mali-BoldItalic，构造只替换 Olli 子串的混排文本，并提供品牌字体回退。
// 边界：不决定页面字号、颜色或布局，不管理字体文件下载，也不改变中文和其他正文的系统字体。

import AppKit
import CoreText
import SwiftUI

enum OlliBrandTypography {
    static let boldPostScriptName = "Mali-Bold"
    static let boldItalicPostScriptName = "Mali-BoldItalic"

    private static var registrationAttempted = false

    /// 注册 App Bundle 内的字体；重复调用只执行一次。
    static func registerBundledFonts() {
        guard !registrationAttempted else { return }
        registrationAttempted = true

        for resourceName in ["Mali-Bold", "Mali-BoldItalic"] {
            guard let url = Bundle.main.url(forResource: resourceName, withExtension: "ttf") else {
                continue
            }
            _ = CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
        }
    }

    static func font(size: CGFloat) -> Font {
        registerBundledFonts()
        return .custom(boldItalicPostScriptName, size: size)
    }

    static func boldFont(size: CGFloat) -> Font {
        registerBundledFonts()
        return .custom(boldPostScriptName, size: size)
    }

    static func nsFont(size: CGFloat) -> NSFont {
        registerBundledFonts()
        return NSFont(name: boldItalicPostScriptName, size: size)
            ?? NSFont.systemFont(ofSize: size, weight: .bold)
    }
}

/// 保留中文和其他正文的原有字体，只把可见的 Olli 品牌字样换成 Mali-BoldItalic。
struct OlliBrandText: View {
    private let value: String
    private let brandSize: CGFloat

    init(_ value: String, brandSize: CGFloat = 14) {
        self.value = value
        self.brandSize = brandSize
    }

    var body: some View {
        renderedText
    }

    private var renderedText: Text {
        let components = value.components(separatedBy: "Olli")
        guard components.count > 1 else {
            return Text(verbatim: value)
        }

        var result = Text(verbatim: "")
        for (index, component) in components.enumerated() {
            if !component.isEmpty {
                result = result + Text(verbatim: component)
            }
            if index < components.count - 1 {
                result = result + Text(verbatim: "Olli")
                    .font(OlliBrandTypography.font(size: brandSize))
            }
        }
        return result
    }
}
