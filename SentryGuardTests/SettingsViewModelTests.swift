import XCTest
@testable import SentryGuard

@MainActor
final class SettingsViewModelTests: XCTestCase {
    override func tearDown() {
        WidgetVehicleStore.clear()
        super.tearDown()
    }

    // MARK: - Display: VIN, session, app version

    func test_vehicleVIN_withCachedSnapshot_returnsVIN() {
        WidgetVehicleStore.save(CachedVehicleSnapshot(
            vin: "5YJ3E1EA0PF000000",
            vehicleDisplayName: "My Tesla",
            vehicleModelName: "Model 3",
            vehicleState: .preview,
            lastUpdated: Date()
        ))
        let viewModel = SettingsViewModel(
            authService: MockTeslaAuthService(), settingsStore: MockAppSettingsStore(), appVersion: "1.0"
        )

        XCTAssertEqual(viewModel.vehicleVIN, "5YJ3E1EA0PF000000")
    }

    func test_vehicleVIN_withNoCachedSnapshot_returnsNil() {
        let viewModel = SettingsViewModel(
            authService: MockTeslaAuthService(), settingsStore: MockAppSettingsStore(), appVersion: "1.0"
        )

        XCTAssertNil(viewModel.vehicleVIN)
    }

    func test_authState_reflectsAuthServiceState() {
        let auth = MockTeslaAuthService(initialState: .authenticated)
        let viewModel = SettingsViewModel(authService: auth, settingsStore: MockAppSettingsStore(), appVersion: "1.0")

        XCTAssertEqual(viewModel.authState, .authenticated)

        try? auth.signOut()

        XCTAssertEqual(viewModel.authState, .signedOut)
    }

    func test_appVersion_returnsInjectedValue() {
        let viewModel = SettingsViewModel(
            authService: MockTeslaAuthService(), settingsStore: MockAppSettingsStore(), appVersion: "2.5"
        )

        XCTAssertEqual(viewModel.appVersion, "2.5")
    }

    // MARK: - Biometric strictness toggle

    func test_requireStrictBiometrics_reflectsSettingsStoreValue() {
        let settingsStore = MockAppSettingsStore(requireStrictBiometrics: false)
        let viewModel = SettingsViewModel(authService: MockTeslaAuthService(), settingsStore: settingsStore, appVersion: "1.0")

        XCTAssertFalse(viewModel.requireStrictBiometrics)
    }

    func test_requireStrictBiometrics_settingUpdatesSettingsStore() {
        let settingsStore = MockAppSettingsStore(requireStrictBiometrics: true)
        let viewModel = SettingsViewModel(authService: MockTeslaAuthService(), settingsStore: settingsStore, appVersion: "1.0")

        viewModel.requireStrictBiometrics = false

        XCTAssertFalse(settingsStore.requireStrictBiometrics)
    }

    // MARK: - Clear Cache & Refresh Timelines

    func test_clearCacheAndRefreshTimelines_clearsWidgetCache() {
        WidgetVehicleStore.save(CachedVehicleSnapshot(
            vin: "5YJ3E1EA0PF000000", vehicleDisplayName: "My Tesla", vehicleModelName: "Model 3",
            vehicleState: .preview, lastUpdated: Date()
        ))
        let viewModel = SettingsViewModel(
            authService: MockTeslaAuthService(), settingsStore: MockAppSettingsStore(), appVersion: "1.0"
        )

        viewModel.clearCacheAndRefreshTimelines()

        XCTAssertNil(WidgetVehicleStore.load())
    }

    func test_clearCacheAndRefreshTimelines_setsSuccessActionState() {
        let viewModel = SettingsViewModel(
            authService: MockTeslaAuthService(), settingsStore: MockAppSettingsStore(), appVersion: "1.0"
        )

        viewModel.clearCacheAndRefreshTimelines()

        guard case .success = viewModel.actionState else {
            return XCTFail("Expected .success, got \(viewModel.actionState)")
        }
    }

    // MARK: - Log Out / Revoke Credentials

    func test_logOut_callsAuthServiceSignOut() {
        let auth = MockTeslaAuthService(initialState: .authenticated)
        let viewModel = SettingsViewModel(authService: auth, settingsStore: MockAppSettingsStore(), appVersion: "1.0")

        viewModel.logOut()

        XCTAssertEqual(auth.state, .signedOut)
    }

    func test_logOut_clearsWidgetCache() {
        WidgetVehicleStore.save(CachedVehicleSnapshot(
            vin: "5YJ3E1EA0PF000000", vehicleDisplayName: "My Tesla", vehicleModelName: "Model 3",
            vehicleState: .preview, lastUpdated: Date()
        ))
        let viewModel = SettingsViewModel(
            authService: MockTeslaAuthService(initialState: .authenticated),
            settingsStore: MockAppSettingsStore(),
            appVersion: "1.0"
        )

        viewModel.logOut()

        XCTAssertNil(WidgetVehicleStore.load())
    }

    func test_logOut_setsSuccessActionState() {
        let viewModel = SettingsViewModel(
            authService: MockTeslaAuthService(initialState: .authenticated),
            settingsStore: MockAppSettingsStore(),
            appVersion: "1.0"
        )

        viewModel.logOut()

        guard case .success = viewModel.actionState else {
            return XCTFail("Expected .success, got \(viewModel.actionState)")
        }
    }

    func test_logOut_whenSignOutThrows_setsFailedActionStateAndDoesNotClearCache() {
        WidgetVehicleStore.save(CachedVehicleSnapshot(
            vin: "5YJ3E1EA0PF000000", vehicleDisplayName: "My Tesla", vehicleModelName: "Model 3",
            vehicleState: .preview, lastUpdated: Date()
        ))
        let auth = MockTeslaAuthService(initialState: .authenticated, signOutError: .notAuthenticated)
        let viewModel = SettingsViewModel(authService: auth, settingsStore: MockAppSettingsStore(), appVersion: "1.0")

        viewModel.logOut()

        guard case .failed = viewModel.actionState else {
            return XCTFail("Expected .failed, got \(viewModel.actionState)")
        }
        XCTAssertNotNil(WidgetVehicleStore.load(), "Cache should be left untouched if sign-out itself failed")
    }

    // MARK: - Log Out with the real TeslaAuthService: proves Keychain wiping end-to-end

    func test_logOut_withRealTeslaAuthService_wipesKeychainTokens() throws {
        let keychain = KeychainService(service: "com.sentryguard.app.tests.settings.\(UUID().uuidString)")
        try keychain.save("access-token", for: .accessToken)
        try keychain.save("refresh-token", for: .refreshToken)
        let authService = TeslaAuthService(keychain: keychain, urlSession: .shared)
        XCTAssertEqual(authService.state, .authenticated)

        let viewModel = SettingsViewModel(
            authService: authService, settingsStore: MockAppSettingsStore(), appVersion: "1.0"
        )
        viewModel.logOut()

        XCTAssertThrowsError(try keychain.readString(for: .accessToken))
        XCTAssertThrowsError(try keychain.readString(for: .refreshToken))
        XCTAssertEqual(authService.state, .signedOut)
        XCTAssertEqual(viewModel.authState, .signedOut)
    }
}
