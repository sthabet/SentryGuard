import XCTest
@testable import SentryGuard

/// Tests the App Group cache that bridges `DashboardViewModel` (main app) and the
/// widget's `TimelineProvider`. Lives in `SentryGuardTests` (not `SentryGuardWidgetTests`)
/// because it needs `DashboardViewModel`, which isn't shared into the widget target.
@MainActor
final class WidgetVehicleStoreTests: XCTestCase {
    override func tearDown() {
        WidgetVehicleStore.clear()
        super.tearDown()
    }

    // MARK: - DashboardViewModel writes, WidgetVehicleStore reads

    func test_dashboardViewModel_afterSuccessfulLoad_snapshotIsReadableViaWidgetVehicleStore() async {
        let api = MockTeslaApiClient(vehicles: [.preview], vehicleStates: [TeslaVehicle.preview.vin: .preview])
        let viewModel = DashboardViewModel(apiClient: api, securityManager: MockSecurityManager())

        await viewModel.loadData()

        let cached = WidgetVehicleStore.load()
        XCTAssertEqual(cached?.vin, TeslaVehicle.preview.vin)
        XCTAssertEqual(cached?.vehicleDisplayName, TeslaVehicle.preview.displayName)
        XCTAssertEqual(cached?.vehicleModelName, TeslaVehicle.preview.modelName)
        XCTAssertEqual(cached?.vehicleState, .preview)
    }

    func test_dashboardViewModel_withNoVehicles_doesNotWriteToCache() async {
        let api = MockTeslaApiClient(vehicles: [], vehicleStates: [:])
        let viewModel = DashboardViewModel(apiClient: api, securityManager: MockSecurityManager())

        await viewModel.loadData()

        XCTAssertNil(WidgetVehicleStore.load())
    }

    func test_dashboardViewModel_onLoadFailure_doesNotOverwriteExistingCache() async {
        // A failed refresh shouldn't clobber a prior good snapshot — stale-but-present
        // data is still what the widget should fall back to (Task 3.1's offline handling).
        let goodSnapshot = CachedVehicleSnapshot(
            vin: TeslaVehicle.preview.vin,
            vehicleDisplayName: "Cached Tesla",
            vehicleModelName: "Model 3",
            vehicleState: .preview,
            lastUpdated: Date()
        )
        WidgetVehicleStore.save(goodSnapshot)

        let api = MockTeslaApiClient(errorToThrow: URLError(.notConnectedToInternet))
        let viewModel = DashboardViewModel(apiClient: api, securityManager: MockSecurityManager())
        await viewModel.loadData()

        XCTAssertEqual(WidgetVehicleStore.load(), goodSnapshot)
    }

    func test_dashboardViewModel_secondSuccessfulLoad_overwritesPriorSnapshot() async {
        let staleState = TeslaVehicleState(
            batteryLevel: 40, locked: true, sentryModeEnabled: false,
            chargePortLatch: .engaged, chargingState: "Disconnected", estimatedRangeMiles: 100
        )
        let api = MockTeslaApiClient(vehicles: [.preview], vehicleStates: [TeslaVehicle.preview.vin: staleState])
        let viewModel = DashboardViewModel(apiClient: api, securityManager: MockSecurityManager())
        await viewModel.loadData()
        XCTAssertEqual(WidgetVehicleStore.load()?.vehicleState.batteryLevel, 40)

        api.vehicleStates[TeslaVehicle.preview.vin] = .preview
        await viewModel.loadData()

        XCTAssertEqual(WidgetVehicleStore.load()?.vehicleState, .preview)
    }

    // MARK: - Cache staleness thresholds

    func test_isStale_freshlyWritten_isNotStale() {
        let snapshot = CachedVehicleSnapshot(
            vin: TeslaVehicle.preview.vin, vehicleDisplayName: "My Tesla", vehicleModelName: "Model 3",
            vehicleState: .preview, lastUpdated: Date()
        )
        XCTAssertFalse(snapshot.isStale())
    }

    func test_isStale_wellWithinFifteenMinutes_isNotStale() {
        let snapshot = CachedVehicleSnapshot(
            vin: TeslaVehicle.preview.vin, vehicleDisplayName: "My Tesla", vehicleModelName: "Model 3",
            vehicleState: .preview, lastUpdated: Date().addingTimeInterval(-10 * 60)
        )
        XCTAssertFalse(snapshot.isStale())
    }

    func test_isStale_exactlyAtFifteenMinuteThreshold_isNotStale() {
        let now = Date()
        let snapshot = CachedVehicleSnapshot(
            vin: TeslaVehicle.preview.vin, vehicleDisplayName: "My Tesla", vehicleModelName: "Model 3",
            vehicleState: .preview, lastUpdated: now.addingTimeInterval(-15 * 60)
        )
        XCTAssertFalse(snapshot.isStale(asOf: now))
    }

    func test_isStale_justOverFifteenMinutes_isStale() {
        let now = Date()
        let snapshot = CachedVehicleSnapshot(
            vin: TeslaVehicle.preview.vin, vehicleDisplayName: "My Tesla", vehicleModelName: "Model 3",
            vehicleState: .preview, lastUpdated: now.addingTimeInterval(-16 * 60)
        )
        XCTAssertTrue(snapshot.isStale(asOf: now))
    }

    func test_isStale_wellBeyondFifteenMinutes_isStale() {
        let snapshot = CachedVehicleSnapshot(
            vin: TeslaVehicle.preview.vin, vehicleDisplayName: "My Tesla", vehicleModelName: "Model 3",
            vehicleState: .preview, lastUpdated: Date().addingTimeInterval(-3 * 60 * 60)
        )
        XCTAssertTrue(snapshot.isStale())
    }

    func test_isStale_withCustomThreshold_overridesDefault() {
        let snapshot = CachedVehicleSnapshot(
            vin: TeslaVehicle.preview.vin, vehicleDisplayName: "My Tesla", vehicleModelName: "Model 3",
            vehicleState: .preview, lastUpdated: Date().addingTimeInterval(-5 * 60)
        )
        XCTAssertTrue(snapshot.isStale(threshold: 60), "5-minute-old data should be stale under a 1-minute threshold")
        XCTAssertFalse(snapshot.isStale(threshold: 30 * 60), "5-minute-old data should not be stale under a 30-minute threshold")
    }

    // MARK: - Corrupted / unparseable cache data

    func test_load_withCorruptedJSONData_returnsNilRatherThanCrashing() {
        let defaults = UserDefaults(suiteName: WidgetVehicleStore.appGroupID)
        defaults?.set(Data("this is not valid JSON {{{".utf8), forKey: WidgetVehicleStore.cacheKey)

        XCTAssertNil(WidgetVehicleStore.load())
    }

    func test_load_withValidJSONButWrongShape_returnsNilRatherThanCrashing() {
        let defaults = UserDefaults(suiteName: WidgetVehicleStore.appGroupID)
        let wrongShapeJSON = Data("""
        {"someUnrelatedField": 42, "anotherField": "hello"}
        """.utf8)
        defaults?.set(wrongShapeJSON, forKey: WidgetVehicleStore.cacheKey)

        XCTAssertNil(WidgetVehicleStore.load())
    }

    func test_load_withEmptyData_returnsNilRatherThanCrashing() {
        let defaults = UserDefaults(suiteName: WidgetVehicleStore.appGroupID)
        defaults?.set(Data(), forKey: WidgetVehicleStore.cacheKey)

        XCTAssertNil(WidgetVehicleStore.load())
    }

    func test_load_withWrongTypeStoredUnderKey_returnsNilRatherThanCrashing() {
        // e.g. some future bug writes a String/Int under this key instead of Data.
        let defaults = UserDefaults(suiteName: WidgetVehicleStore.appGroupID)
        defaults?.set("not even data", forKey: WidgetVehicleStore.cacheKey)

        XCTAssertNil(WidgetVehicleStore.load())
    }

    func test_save_afterPriorCorruptedData_recoversCleanly() {
        let defaults = UserDefaults(suiteName: WidgetVehicleStore.appGroupID)
        defaults?.set(Data("garbage".utf8), forKey: WidgetVehicleStore.cacheKey)
        XCTAssertNil(WidgetVehicleStore.load())

        let snapshot = CachedVehicleSnapshot(
            vin: "DIFFERENTVIN000001",
            vehicleDisplayName: "Recovered Tesla", vehicleModelName: "Model Y",
            vehicleState: .preview, lastUpdated: Date()
        )
        WidgetVehicleStore.save(snapshot)

        XCTAssertEqual(WidgetVehicleStore.load(), snapshot)
    }

    func test_dashboardViewModel_afterCorruptedCache_overwritesWithValidSnapshot() async {
        let defaults = UserDefaults(suiteName: WidgetVehicleStore.appGroupID)
        defaults?.set(Data("garbage".utf8), forKey: WidgetVehicleStore.cacheKey)

        let api = MockTeslaApiClient(vehicles: [.preview], vehicleStates: [TeslaVehicle.preview.vin: .preview])
        let viewModel = DashboardViewModel(apiClient: api, securityManager: MockSecurityManager())
        await viewModel.loadData()

        XCTAssertEqual(WidgetVehicleStore.load()?.vehicleState, .preview)
    }
}
