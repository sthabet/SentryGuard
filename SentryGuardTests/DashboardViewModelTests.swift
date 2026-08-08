import XCTest
@testable import SentryGuard

@MainActor
final class DashboardViewModelTests: XCTestCase {
    // MARK: - Vehicle list loading

    func test_loadData_withSingleVehicle_populatesVehicleAndState() async {
        let api = MockTeslaApiClient(vehicles: [.preview], vehicleStates: [TeslaVehicle.preview.vin: .preview])
        let viewModel = DashboardViewModel(apiClient: api, securityManager: MockSecurityManager())

        await viewModel.loadData()

        XCTAssertEqual(viewModel.loadState, .loaded)
        XCTAssertEqual(viewModel.vehicle, .preview)
        XCTAssertEqual(viewModel.vehicleState, .preview)
    }

    func test_loadData_withNoVehicles_setsLoadedStateWithNilVehicle() async {
        let api = MockTeslaApiClient(vehicles: [], vehicleStates: [:])
        let viewModel = DashboardViewModel(apiClient: api, securityManager: MockSecurityManager())

        await viewModel.loadData()

        XCTAssertEqual(viewModel.loadState, .loaded)
        XCTAssertNil(viewModel.vehicle)
        XCTAssertNil(viewModel.vehicleState)
    }

    // MARK: - Active vehicle selection

    func test_loadData_withMultipleVehicles_selectsFirstAsActiveVehicleAndFetchesItsTelemetry() async {
        let secondVehicle = TeslaVehicle(
            id: 2, vehicleID: 2, vin: "SECONDVIN0000001", displayName: "Second Car", state: "online"
        )
        let api = MockTeslaApiClient(
            vehicles: [.preview, secondVehicle],
            vehicleStates: [TeslaVehicle.preview.vin: .preview]
        )
        let viewModel = DashboardViewModel(apiClient: api, securityManager: MockSecurityManager())

        await viewModel.loadData()

        XCTAssertEqual(viewModel.vehicle, .preview)
        XCTAssertEqual(viewModel.loadState, .loaded)
        XCTAssertEqual(viewModel.vehicleState, .preview)
    }

    // MARK: - Telemetry state mapping

    func test_lockToggleCommand_whenLocked_offersUnlock() async {
        let state = TeslaVehicleState(
            batteryLevel: 50, locked: true, sentryModeEnabled: false,
            chargePortLatch: .engaged, chargingState: "Disconnected", estimatedRangeMiles: 100
        )
        let api = MockTeslaApiClient(vehicles: [.preview], vehicleStates: [TeslaVehicle.preview.vin: state])
        let viewModel = DashboardViewModel(apiClient: api, securityManager: MockSecurityManager())
        await viewModel.loadData()

        XCTAssertEqual(viewModel.lockToggleCommand, .unlockDoors)
    }

    func test_lockToggleCommand_whenUnlocked_offersLock() async {
        let state = TeslaVehicleState(
            batteryLevel: 50, locked: false, sentryModeEnabled: false,
            chargePortLatch: .engaged, chargingState: "Disconnected", estimatedRangeMiles: 100
        )
        let api = MockTeslaApiClient(vehicles: [.preview], vehicleStates: [TeslaVehicle.preview.vin: state])
        let viewModel = DashboardViewModel(apiClient: api, securityManager: MockSecurityManager())
        await viewModel.loadData()

        XCTAssertEqual(viewModel.lockToggleCommand, .lockDoors)
    }

    func test_batteryStatusLevel_whenCharging_isChargingRegardlessOfPercentage() async {
        let state = TeslaVehicleState(
            batteryLevel: 5, locked: true, sentryModeEnabled: false,
            chargePortLatch: .engaged, chargingState: "Charging", estimatedRangeMiles: 20
        )
        let api = MockTeslaApiClient(vehicles: [.preview], vehicleStates: [TeslaVehicle.preview.vin: state])
        let viewModel = DashboardViewModel(apiClient: api, securityManager: MockSecurityManager())
        await viewModel.loadData()

        XCTAssertEqual(viewModel.batteryStatusLevel, .charging)
    }

    func test_batteryStatusLevel_belowFifteenPercent_isCritical() async {
        let state = TeslaVehicleState(
            batteryLevel: 10, locked: true, sentryModeEnabled: false,
            chargePortLatch: .engaged, chargingState: "Disconnected", estimatedRangeMiles: 20
        )
        let api = MockTeslaApiClient(vehicles: [.preview], vehicleStates: [TeslaVehicle.preview.vin: state])
        let viewModel = DashboardViewModel(apiClient: api, securityManager: MockSecurityManager())
        await viewModel.loadData()

        XCTAssertEqual(viewModel.batteryStatusLevel, .critical)
    }

    func test_batteryStatusLevel_between15And34Percent_isLow() async {
        let state = TeslaVehicleState(
            batteryLevel: 25, locked: true, sentryModeEnabled: false,
            chargePortLatch: .engaged, chargingState: "Disconnected", estimatedRangeMiles: 60
        )
        let api = MockTeslaApiClient(vehicles: [.preview], vehicleStates: [TeslaVehicle.preview.vin: state])
        let viewModel = DashboardViewModel(apiClient: api, securityManager: MockSecurityManager())
        await viewModel.loadData()

        XCTAssertEqual(viewModel.batteryStatusLevel, .low)
    }

    func test_batteryStatusLevel_35PercentOrAbove_isNormal() async {
        let state = TeslaVehicleState(
            batteryLevel: 80, locked: true, sentryModeEnabled: false,
            chargePortLatch: .engaged, chargingState: "Disconnected", estimatedRangeMiles: 200
        )
        let api = MockTeslaApiClient(vehicles: [.preview], vehicleStates: [TeslaVehicle.preview.vin: state])
        let viewModel = DashboardViewModel(apiClient: api, securityManager: MockSecurityManager())
        await viewModel.loadData()

        XCTAssertEqual(viewModel.batteryStatusLevel, .normal)
    }

    func test_batteryStatusLevel_beforeAnyLoad_defaultsToNormal() {
        let viewModel = DashboardViewModel(apiClient: MockTeslaApiClient(), securityManager: MockSecurityManager())

        XCTAssertEqual(viewModel.batteryStatusLevel, .normal)
    }

    // MARK: - Error state handling

    func test_loadData_onOfflineError_setsOfflineState() async {
        let api = MockTeslaApiClient(errorToThrow: URLError(.notConnectedToInternet))
        let viewModel = DashboardViewModel(apiClient: api, securityManager: MockSecurityManager())

        await viewModel.loadData()

        XCTAssertEqual(viewModel.loadState, .offline)
    }

    func test_loadData_onTeslaAuthErrorNotAuthenticated_setsUnauthenticatedState() async {
        let api = MockTeslaApiClient(errorToThrow: TeslaAuthError.notAuthenticated)
        let viewModel = DashboardViewModel(apiClient: api, securityManager: MockSecurityManager())

        await viewModel.loadData()

        XCTAssertEqual(viewModel.loadState, .unauthenticated)
    }

    func test_loadData_onTeslaApiErrorNotAuthenticated_setsUnauthenticatedState() async {
        let api = MockTeslaApiClient(errorToThrow: TeslaApiError.notAuthenticated)
        let viewModel = DashboardViewModel(apiClient: api, securityManager: MockSecurityManager())

        await viewModel.loadData()

        XCTAssertEqual(viewModel.loadState, .unauthenticated)
    }

    func test_loadData_onGenericError_setsErrorStateWithMessage() async {
        let api = MockTeslaApiClient(errorToThrow: TeslaApiError.httpError(statusCode: 500, body: "boom"))
        let viewModel = DashboardViewModel(apiClient: api, securityManager: MockSecurityManager())

        await viewModel.loadData()

        guard case .error(let message) = viewModel.loadState else {
            return XCTFail("Expected .error, got \(viewModel.loadState)")
        }
        XCTAssertTrue(message.contains("500"))
    }

    func test_loadData_afterPriorFailure_recoversToLoadedOnRetry() async {
        let api = MockTeslaApiClient(
            vehicles: [.preview],
            vehicleStates: [TeslaVehicle.preview.vin: .preview],
            errorToThrow: URLError(.notConnectedToInternet)
        )
        let viewModel = DashboardViewModel(apiClient: api, securityManager: MockSecurityManager())

        await viewModel.loadData()
        XCTAssertEqual(viewModel.loadState, .offline)

        api.errorToThrow = nil
        await viewModel.refresh()

        XCTAssertEqual(viewModel.loadState, .loaded)
        XCTAssertEqual(viewModel.vehicle, .preview)
    }

    // MARK: - Active command sheet state

    func test_selectCommand_setsActiveCommand() {
        let viewModel = DashboardViewModel(apiClient: MockTeslaApiClient(), securityManager: MockSecurityManager())

        viewModel.selectCommand(.honkHorn)

        XCTAssertEqual(viewModel.activeCommand?.command, .honkHorn)
    }

    func test_dismissActiveCommand_clearsActiveCommand() {
        let viewModel = DashboardViewModel(apiClient: MockTeslaApiClient(), securityManager: MockSecurityManager())
        viewModel.selectCommand(.flashLights)

        viewModel.dismissActiveCommand()

        XCTAssertNil(viewModel.activeCommand)
    }
}
