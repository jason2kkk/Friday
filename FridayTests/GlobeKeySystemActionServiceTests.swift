// 功能：验证 Friday 自动接管并恢复 macOS Globe/Fn 单击动作时的状态与恢复凭据行为。
// 职责：用内存 Bridge 和 Store 覆盖接管、正常恢复、崩溃凭据续接及原本无操作场景。
// 边界：不调用 Carbon 私有接口、不修改真实系统偏好，也不创建 CGEventTap。

import XCTest
@testable import Friday

final class GlobeKeySystemActionServiceTests: XCTestCase {
    @MainActor
    func testTakeOverPersistsOriginalBeforeChangingSystemAction() throws {
        let events = GlobeKeyTestEvents()
        let bridge = GlobeKeyTestBridge(
            effectiveUsage: 2,
            storedPreference: nil,
            events: events
        )
        let store = GlobeKeyTestReceiptStore(events: events)
        let service = makeService(bridge: bridge, store: store)

        try service.takeOver()

        XCTAssertEqual(bridge.currentUsage, 0)
        XCTAssertEqual(
            store.receipt,
            GlobeKeySystemActionReceipt(
                originalUsage: 2,
                originalStoredPreference: nil
            )
        )
        XCTAssertEqual(Array(events.values.prefix(2)), ["save:2", "update:0"])
    }

    @MainActor
    func testRestoreReturnsEffectiveAndStoredSystemState() throws {
        let events = GlobeKeyTestEvents()
        let bridge = GlobeKeyTestBridge(
            effectiveUsage: 2,
            storedPreference: 2,
            events: events
        )
        let store = GlobeKeyTestReceiptStore(events: events)
        let service = makeService(bridge: bridge, store: store)

        try service.takeOver()
        try service.restore()

        XCTAssertEqual(bridge.currentUsage, 2)
        XCTAssertEqual(bridge.currentStoredPreference, 2)
        XCTAssertNil(store.receipt)
        XCTAssertEqual(
            events.values,
            ["save:2", "update:0", "update:2", "preference:2", "clear"]
        )
    }

    @MainActor
    func testExistingRecoveryReceiptIsNotOverwrittenOnNextLaunch() throws {
        let events = GlobeKeyTestEvents()
        let bridge = GlobeKeyTestBridge(
            effectiveUsage: 0,
            storedPreference: 0,
            events: events
        )
        let originalReceipt = GlobeKeySystemActionReceipt(
            originalUsage: 2,
            originalStoredPreference: nil
        )
        let store = GlobeKeyTestReceiptStore(
            receipt: originalReceipt,
            events: events
        )
        let service = makeService(bridge: bridge, store: store)

        try service.takeOver()
        try service.restore()

        XCTAssertEqual(bridge.currentUsage, 2)
        XCTAssertNil(bridge.currentStoredPreference)
        XCTAssertNil(store.receipt)
        XCTAssertFalse(events.values.contains("save:0"))
    }

    @MainActor
    func testAlreadyUnassignedGlobeKeyIsNotChangedOrRestored() throws {
        let events = GlobeKeyTestEvents()
        let bridge = GlobeKeyTestBridge(
            effectiveUsage: 0,
            storedPreference: 0,
            events: events
        )
        let store = GlobeKeyTestReceiptStore(events: events)
        let service = makeService(bridge: bridge, store: store)

        try service.takeOver()
        try service.restore()

        XCTAssertEqual(bridge.currentUsage, 0)
        XCTAssertNil(store.receipt)
        XCTAssertTrue(events.values.isEmpty)
    }

    @MainActor
    func testFailedTakeoverRollsBackAndClearsRecoveryReceipt() throws {
        let events = GlobeKeyTestEvents()
        let bridge = GlobeKeyTestBridge(
            effectiveUsage: 2,
            storedPreference: nil,
            events: events,
            failingUpdates: [0]
        )
        let store = GlobeKeyTestReceiptStore(events: events)
        let service = makeService(bridge: bridge, store: store)

        XCTAssertThrowsError(try service.takeOver())

        XCTAssertEqual(bridge.currentUsage, 2)
        XCTAssertNil(bridge.currentStoredPreference)
        XCTAssertNil(store.receipt)
        XCTAssertEqual(
            events.values,
            ["save:2", "update:0", "update:2", "preference:nil", "clear"]
        )
    }

    @MainActor
    func testFailedRestoreKeepsRecoveryReceiptForNextLaunch() throws {
        let events = GlobeKeyTestEvents()
        let bridge = GlobeKeyTestBridge(
            effectiveUsage: 2,
            storedPreference: nil,
            events: events,
            failingUpdates: [2]
        )
        let store = GlobeKeyTestReceiptStore(events: events)
        let service = makeService(bridge: bridge, store: store)

        try service.takeOver()
        XCTAssertThrowsError(try service.restore())

        XCTAssertEqual(bridge.currentUsage, 0)
        XCTAssertEqual(store.receipt?.originalUsage, 2)
        XCTAssertFalse(events.values.contains("clear"))
    }

    @MainActor
    private func makeService(
        bridge: GlobeKeyTestBridge,
        store: GlobeKeyTestReceiptStore
    ) -> GlobeKeySystemActionService {
        GlobeKeySystemActionService(
            bridgeFactory: { bridge },
            receiptStore: store
        )
    }
}

private final class GlobeKeyTestEvents {
    var values: [String] = []
}

private enum GlobeKeyTestError: Error {
    case updateFailed
}

private final class GlobeKeyTestBridge: GlobeKeySystemActionBridging {
    private let events: GlobeKeyTestEvents
    private var failingUpdates: Set<Int>
    private(set) var currentUsage: Int
    private(set) var currentStoredPreference: Int?

    init(
        effectiveUsage: Int,
        storedPreference: Int?,
        events: GlobeKeyTestEvents,
        failingUpdates: Set<Int> = []
    ) {
        currentUsage = effectiveUsage
        currentStoredPreference = storedPreference
        self.events = events
        self.failingUpdates = failingUpdates
    }

    func effectiveUsage() throws -> Int {
        currentUsage
    }

    func updateEffectiveUsage(_ usage: Int) throws {
        events.values.append("update:\(usage)")
        if failingUpdates.remove(usage) != nil {
            throw GlobeKeyTestError.updateFailed
        }
        currentUsage = usage
    }

    func storedUsagePreference() throws -> Int? {
        currentStoredPreference
    }

    func restoreStoredUsagePreference(_ usage: Int?) throws {
        events.values.append("preference:\(usage.map(String.init) ?? "nil")")
        currentStoredPreference = usage
    }
}

private final class GlobeKeyTestReceiptStore: GlobeKeySystemActionReceiptStoring {
    private let events: GlobeKeyTestEvents
    private(set) var receipt: GlobeKeySystemActionReceipt?

    init(
        receipt: GlobeKeySystemActionReceipt? = nil,
        events: GlobeKeyTestEvents
    ) {
        self.receipt = receipt
        self.events = events
    }

    func load() throws -> GlobeKeySystemActionReceipt? {
        receipt
    }

    func save(_ receipt: GlobeKeySystemActionReceipt) throws {
        events.values.append("save:\(receipt.originalUsage)")
        self.receipt = receipt
    }

    func clear() throws {
        events.values.append("clear")
        receipt = nil
    }
}
