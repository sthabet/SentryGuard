import SwiftUI
import XCTest

/// Tests the widget's `TimelineProvider`, entry-formatting helpers, and shared cache.
///
/// This file is compiled into the dedicated `SentryGuardWidgetTests` target, which builds
/// the widget's own sources directly (see project.yml) rather than linking against the
/// `SentryGuardWidget` app-extension product — extension targets don't link into test
/// bundles the way normal app/framework targets do, so `@testable import` alone doesn't work.
///
/// `TimelineProviderContext` (WidgetKit's `Context`) has no public initializer, so these
/// tests exercise `VehicleStatusTimelineProvider.currentEntry()` directly rather than the
/// `TimelineProvider` protocol methods themselves — `getSnapshot`/`getTimeline` are thin,
/// untestable-in-isolation wrappers around it.
final class WidgetTimelineProviderTests: XCTestCase {
    override func tearDown() {
        WidgetVehicleStore.clear()
        super.tearDown()
    }

    // MARK: - Provider: authentication gates everything

    func test_currentEntry_whenNotAuthenticated_returnsUnauthenticated_evenWithValidCache() {
        let provider = VehicleStatusTimelineProvider(
            loadCachedSnapshot: { .fixture() },
            isAuthenticated: { false }
        )

        XCTAssertEqual(provider.currentEntry().status, .unauthenticated)
    }

    func test_currentEntry_whenAuthenticatedWithNoCache_returnsOffline() {
        let provider = VehicleStatusTimelineProvider(
            loadCachedSnapshot: { nil },
            isAuthenticated: { true }
        )

        XCTAssertEqual(provider.currentEntry().status, .offline)
    }

    func test_currentEntry_whenAuthenticatedWithCache_returnsAvailableSnapshot() {
        let snapshot = CachedVehicleSnapshot.fixture(batteryLevel: 55)
        let provider = VehicleStatusTimelineProvider(
            loadCachedSnapshot: { snapshot },
            isAuthenticated: { true }
        )

        XCTAssertEqual(provider.currentEntry().status, .available(snapshot))
    }

    func test_placeholderFixture_isWellFormedForWidgetKitsPlaceholderRendering() {
        // `placeholder(in:)` itself can't be called directly (Context is unconstructable),
        // but it just wraps this fixture — verifying the fixture covers the same ground.
        let placeholder = CachedVehicleSnapshot.placeholder

        XCTAssertFalse(placeholder.vehicleDisplayName.isEmpty)
        XCTAssertTrue((0...100).contains(placeholder.vehicleState.batteryLevel))
    }

    func test_nextRefreshDate_isFourHoursAfterTheGivenDate() {
        let now = Date()

        let next = VehicleStatusTimelineProvider.nextRefreshDate(after: now)

        XCTAssertEqual(next.timeIntervalSince(now), 4 * 60 * 60, accuracy: 1)
    }

    // MARK: - Extreme / corrupted telemetry: battery

    func test_batteryText_zeroPercent_rendersZeroPercent() {
        let state = TeslaVehicleState.fixture(batteryLevel: 0)
        XCTAssertEqual(batteryText(for: state), "0%")
    }

    func test_batteryText_negativePercent_clampsToZero() {
        let state = TeslaVehicleState.fixture(batteryLevel: -5)
        XCTAssertEqual(batteryText(for: state), "0%")
    }

    func test_batteryText_over100Percent_clampsTo100() {
        let state = TeslaVehicleState.fixture(batteryLevel: 150)
        XCTAssertEqual(batteryText(for: state), "100%")
    }

    func test_batteryColor_whileCharging_isBlueRegardlessOfPercent() {
        let state = TeslaVehicleState.fixture(batteryLevel: 3, chargingState: "Charging")
        XCTAssertEqual(WidgetBatteryColor.color(forState: state), .blue)
    }

    func test_batteryColor_belowTenPercent_isCritical() {
        let state = TeslaVehicleState.fixture(batteryLevel: 9, chargingState: "Disconnected")
        XCTAssertEqual(WidgetBatteryColor.color(forState: state), .red)
    }

    func test_batteryColor_betweenTenAndNineteenPercent_isLow() {
        let state = TeslaVehicleState.fixture(batteryLevel: 15, chargingState: "Disconnected")
        XCTAssertEqual(WidgetBatteryColor.color(forState: state), .orange)
    }

    func test_batteryColor_twentyPercentOrAbove_isNormal() {
        let state = TeslaVehicleState.fixture(batteryLevel: 20, chargingState: "Disconnected")
        XCTAssertEqual(WidgetBatteryColor.color(forState: state), .green)
    }

    // MARK: - Extreme / corrupted telemetry: range

    func test_rangeText_zeroValue_formatsCleanly() {
        let state = TeslaVehicleState.fixture(estimatedRangeMiles: 0)
        XCTAssertEqual(rangeText(for: state), "0 mi")
    }

    func test_rangeText_negativeValue_returnsPlaceholderRatherThanNegativeNumber() {
        let state = TeslaVehicleState.fixture(estimatedRangeMiles: -12)
        XCTAssertEqual(rangeText(for: state), "-- mi")
    }

    func test_rangeText_nanValue_returnsPlaceholderRatherThanCrashing() {
        let state = TeslaVehicleState.fixture(estimatedRangeMiles: .nan)
        XCTAssertEqual(rangeText(for: state), "-- mi")
    }

    func test_rangeText_validValue_formatsAsWholeNumberMiles() {
        let state = TeslaVehicleState.fixture(estimatedRangeMiles: 215.9)
        XCTAssertEqual(rangeText(for: state), "215 mi")
    }

    // MARK: - Extreme / corrupted telemetry: latch & unknown states

    func test_unlatchedChargePort_doesNotAffectBatteryOrRangeFormatting() {
        let state = TeslaVehicleState.fixture(
            chargePortLatch: .disengaged,
            estimatedRangeMiles: 40
        )
        XCTAssertEqual(batteryText(for: state), "72%")
        XCTAssertEqual(rangeText(for: state), "40 mi")
    }

    func test_unknownChargePortLatchString_decodesToUnknownCaseWithoutThrowing() throws {
        let json = Data("""
        {"vehicle_state":{"locked":true,"sentry_mode":false},
         "charge_state":{"battery_level":50,"charge_port_latch":"SomeFutureLatchValue","charging_state":"Disconnected","est_battery_range":100}}
        """.utf8)

        let decoded = try JSONDecoder().decode(TeslaVehicleState.self, from: json)

        XCTAssertEqual(decoded.chargePortLatch, .unknown)
    }

    func test_unrecognizedChargingStateString_fallsBackToNonChargingColorAndIcon() {
        let state = TeslaVehicleState.fixture(batteryLevel: 50, chargingState: "SomeFutureState")

        XCTAssertEqual(batteryIcon(for: state), "battery.100")
        XCTAssertEqual(WidgetBatteryColor.color(forState: state), .green)
    }

    // MARK: - Shared cache

    func test_widgetVehicleStore_saveThenLoad_roundTrips() {
        let snapshot = CachedVehicleSnapshot.fixture(batteryLevel: 33)

        WidgetVehicleStore.save(snapshot)

        XCTAssertEqual(WidgetVehicleStore.load(), snapshot)
    }

    func test_widgetVehicleStore_clear_removesCachedSnapshot() {
        WidgetVehicleStore.save(.fixture())
        XCTAssertNotNil(WidgetVehicleStore.load())

        WidgetVehicleStore.clear()

        XCTAssertNil(WidgetVehicleStore.load())
    }

    func test_widgetVehicleStore_load_withNothingCached_returnsNilNotCrash() {
        XCTAssertNil(WidgetVehicleStore.load())
    }
}

// MARK: - Fixtures

private extension TeslaVehicleState {
    static func fixture(
        batteryLevel: Int = 72,
        locked: Bool = true,
        sentryModeEnabled: Bool = false,
        chargePortLatch: ChargePortLatch = .engaged,
        chargingState: String = "Disconnected",
        estimatedRangeMiles: Double = 187
    ) -> TeslaVehicleState {
        TeslaVehicleState(
            batteryLevel: batteryLevel,
            locked: locked,
            sentryModeEnabled: sentryModeEnabled,
            chargePortLatch: chargePortLatch,
            chargingState: chargingState,
            estimatedRangeMiles: estimatedRangeMiles
        )
    }
}

private extension CachedVehicleSnapshot {
    static func fixture(
        vin: String = "5YJ3E1EA0PF000000",
        vehicleDisplayName: String = "My Tesla",
        vehicleModelName: String = "Model 3",
        batteryLevel: Int = 72
    ) -> CachedVehicleSnapshot {
        CachedVehicleSnapshot(
            vin: vin,
            vehicleDisplayName: vehicleDisplayName,
            vehicleModelName: vehicleModelName,
            vehicleState: .fixture(batteryLevel: batteryLevel),
            lastUpdated: Date()
        )
    }
}
