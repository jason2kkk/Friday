// 功能：在 Friday 使用单独 Fn 快捷键期间，临时关闭 macOS 的 Globe/Fn 单击系统动作。
// 职责：动态调用 Carbon 的 Fn usage 接口，先持久化原始动作恢复凭据，再接管系统动作，并在退出时恢复原状态。
// 边界：不监听键盘、不请求辅助功能权限、不修改其他快捷键；未公开 Carbon 接口不可用时必须失败，不能假装已接管。

import Darwin
import Foundation
import OSLog

struct GlobeKeySystemActionReceipt: Codable, Equatable {
    let originalUsage: Int
    let originalStoredPreference: Int?
}

protocol GlobeKeySystemActionBridging: AnyObject {
    func effectiveUsage() throws -> Int
    func updateEffectiveUsage(_ usage: Int) throws
    func storedUsagePreference() throws -> Int?
    func restoreStoredUsagePreference(_ usage: Int?) throws
}

protocol GlobeKeySystemActionReceiptStoring: AnyObject {
    func load() throws -> GlobeKeySystemActionReceipt?
    func save(_ receipt: GlobeKeySystemActionReceipt) throws
    func clear() throws
}

enum GlobeKeySystemActionError: LocalizedError {
    case privateAPIUnavailable
    case unsupportedUsage(Int)
    case preferenceSynchronizationFailed
    case recoveryStateInvalid
    case recoveryStatePersistenceFailed
    case takeoverVerificationFailed(Int)
    case restoreVerificationFailed(Int)

    var errorDescription: String? {
        switch self {
        case .privateAPIUnavailable:
            return "此 macOS 版本暂不支持 Olli 接管 Fn 键"
        case .unsupportedUsage:
            return "无法识别当前 Fn 系统动作"
        case .preferenceSynchronizationFailed,
             .recoveryStateInvalid,
             .recoveryStatePersistenceFailed:
            return "无法安全保存 Fn 键原始设置"
        case .takeoverVerificationFailed:
            return "Olli 未能接管 Fn 键，请重新启动 App"
        case .restoreVerificationFailed:
            return "Olli 未能恢复 Fn 键原始设置"
        }
    }
}

final class CarbonGlobeKeySystemActionBridge: GlobeKeySystemActionBridging {
    private typealias GetUsage = @convention(c) () -> Int32
    private typealias UpdateUsage = @convention(c) (Int32) -> Void

    private static let carbonPath = "/System/Library/Frameworks/Carbon.framework/Carbon"
    private static let preferenceDomain = "com.apple.HIToolbox" as CFString
    private static let preferenceKey = "AppleFnUsageType" as CFString
    private static let validUsages = 0...3

    private let handle: UnsafeMutableRawPointer
    private let getUsage: GetUsage
    private let updateUsage: UpdateUsage

    init() throws {
        guard let handle = dlopen(Self.carbonPath, RTLD_NOW | RTLD_LOCAL),
              let getSymbol = dlsym(handle, "TISGetFnUsageType"),
              let updateSymbol = dlsym(handle, "TISUpdateFnUsageType") else {
            throw GlobeKeySystemActionError.privateAPIUnavailable
        }
        self.handle = handle
        getUsage = unsafeBitCast(getSymbol, to: GetUsage.self)
        updateUsage = unsafeBitCast(updateSymbol, to: UpdateUsage.self)
    }

    deinit {
        dlclose(handle)
    }

    func effectiveUsage() throws -> Int {
        let usage = Int(getUsage())
        guard Self.validUsages.contains(usage) else {
            throw GlobeKeySystemActionError.unsupportedUsage(usage)
        }
        return usage
    }

    func updateEffectiveUsage(_ usage: Int) throws {
        guard Self.validUsages.contains(usage) else {
            throw GlobeKeySystemActionError.unsupportedUsage(usage)
        }
        updateUsage(Int32(usage))
    }

    func storedUsagePreference() throws -> Int? {
        CFPreferencesSynchronize(
            Self.preferenceDomain,
            kCFPreferencesCurrentUser,
            kCFPreferencesAnyHost
        )
        guard let number = CFPreferencesCopyValue(
            Self.preferenceKey,
            Self.preferenceDomain,
            kCFPreferencesCurrentUser,
            kCFPreferencesAnyHost
        ) as? NSNumber else {
            return nil
        }
        let usage = number.intValue
        guard Self.validUsages.contains(usage) else { return nil }
        return usage
    }

    func restoreStoredUsagePreference(_ usage: Int?) throws {
        if let usage {
            CFPreferencesSetValue(
                Self.preferenceKey,
                NSNumber(value: usage),
                Self.preferenceDomain,
                kCFPreferencesCurrentUser,
                kCFPreferencesAnyHost
            )
        } else {
            CFPreferencesSetValue(
                Self.preferenceKey,
                nil,
                Self.preferenceDomain,
                kCFPreferencesCurrentUser,
                kCFPreferencesAnyHost
            )
        }
        guard CFPreferencesSynchronize(
            Self.preferenceDomain,
            kCFPreferencesCurrentUser,
            kCFPreferencesAnyHost
        ) else {
            throw GlobeKeySystemActionError.preferenceSynchronizationFailed
        }
    }
}

final class UserDefaultsGlobeKeySystemActionReceiptStore:
    GlobeKeySystemActionReceiptStoring {
    private static let receiptKey = "Friday.GlobeKeySystemActionReceipt"
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func load() throws -> GlobeKeySystemActionReceipt? {
        guard let data = defaults.data(forKey: Self.receiptKey) else { return nil }
        do {
            return try PropertyListDecoder().decode(
                GlobeKeySystemActionReceipt.self,
                from: data
            )
        } catch {
            throw GlobeKeySystemActionError.recoveryStateInvalid
        }
    }

    func save(_ receipt: GlobeKeySystemActionReceipt) throws {
        do {
            defaults.set(
                try PropertyListEncoder().encode(receipt),
                forKey: Self.receiptKey
            )
        } catch {
            throw GlobeKeySystemActionError.recoveryStatePersistenceFailed
        }
        guard defaults.synchronize() else {
            throw GlobeKeySystemActionError.recoveryStatePersistenceFailed
        }
    }

    func clear() throws {
        defaults.removeObject(forKey: Self.receiptKey)
        guard defaults.synchronize() else {
            throw GlobeKeySystemActionError.recoveryStatePersistenceFailed
        }
    }
}

@MainActor
final class GlobeKeySystemActionService {
    private static let fridayUsage = 0

    private let logger = Logger(
        subsystem: "com.example.Friday",
        category: "GlobeKey"
    )
    private let bridgeFactory: () throws -> GlobeKeySystemActionBridging
    private let receiptStore: GlobeKeySystemActionReceiptStoring
    private var bridge: GlobeKeySystemActionBridging?

    convenience init() {
        self.init(
            bridgeFactory: { try CarbonGlobeKeySystemActionBridge() },
            receiptStore: UserDefaultsGlobeKeySystemActionReceiptStore()
        )
    }

    init(
        bridgeFactory: @escaping () throws -> GlobeKeySystemActionBridging,
        receiptStore: GlobeKeySystemActionReceiptStoring
    ) {
        self.bridgeFactory = bridgeFactory
        self.receiptStore = receiptStore
    }

    func takeOver() throws {
        let bridge = try resolvedBridge()

        if try receiptStore.load() != nil {
            try setAndVerify(Self.fridayUsage, using: bridge, restoring: false)
            logger.info("Reasserted Friday Globe/Fn system action takeover")
            return
        }

        let originalUsage = try bridge.effectiveUsage()
        guard originalUsage != Self.fridayUsage else {
            logger.info("Globe/Fn system action already set to do nothing")
            return
        }

        let receipt = GlobeKeySystemActionReceipt(
            originalUsage: originalUsage,
            originalStoredPreference: try bridge.storedUsagePreference()
        )
        try receiptStore.save(receipt)

        do {
            try setAndVerify(Self.fridayUsage, using: bridge, restoring: false)
            logger.info("Friday temporarily took over the Globe/Fn system action")
        } catch {
            let takeoverError = error
            do {
                try restore(receipt, using: bridge)
                try receiptStore.clear()
            } catch {
                logger.error(
                    "Failed to roll back Globe/Fn takeover: \(error.localizedDescription, privacy: .public)"
                )
            }
            throw takeoverError
        }
    }

    func restore() throws {
        guard let receipt = try receiptStore.load() else { return }
        let bridge = try resolvedBridge()
        try restore(receipt, using: bridge)
        try receiptStore.clear()
        logger.info("Restored the original Globe/Fn system action")
    }

    func restoreBestEffort() {
        do {
            try restore()
        } catch {
            logger.error(
                "Failed to restore Globe/Fn system action: \(error.localizedDescription, privacy: .public)"
            )
        }
    }

    private func resolvedBridge() throws -> GlobeKeySystemActionBridging {
        if let bridge { return bridge }
        let bridge = try bridgeFactory()
        self.bridge = bridge
        return bridge
    }

    private func setAndVerify(
        _ usage: Int,
        using bridge: GlobeKeySystemActionBridging,
        restoring: Bool
    ) throws {
        try bridge.updateEffectiveUsage(usage)
        let actualUsage = try bridge.effectiveUsage()
        guard actualUsage == usage else {
            if restoring {
                throw GlobeKeySystemActionError.restoreVerificationFailed(actualUsage)
            }
            throw GlobeKeySystemActionError.takeoverVerificationFailed(actualUsage)
        }
    }

    private func restore(
        _ receipt: GlobeKeySystemActionReceipt,
        using bridge: GlobeKeySystemActionBridging
    ) throws {
        try setAndVerify(receipt.originalUsage, using: bridge, restoring: true)
        try bridge.restoreStoredUsagePreference(receipt.originalStoredPreference)
    }
}
