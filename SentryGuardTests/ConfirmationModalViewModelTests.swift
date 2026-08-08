import XCTest
@testable import SentryGuard

@MainActor
final class ConfirmationModalViewModelTests: XCTestCase {
    private let vin = "5YJ3E1EA0PF000000"

    // MARK: - Happy path (strict biometrics — the default)

    func test_confirm_strictMode_biometricSuccess_executesCommandAndSetsSuccessPhase() async {
        let security = MockSecurityManager()
        let api = MockTeslaApiClient(commandResult: true)
        let viewModel = ConfirmationModalViewModel(
            command: .honkHorn, vin: vin, securityManager: security, apiClient: api,
            settingsStore: MockAppSettingsStore(requireStrictBiometrics: true)
        )

        await viewModel.confirm()

        XCTAssertEqual(viewModel.phase, .success)
        XCTAssertEqual(api.executedCommands, [.init(vin: vin, command: .honkHorn)])
        XCTAssertEqual(security.biometricAttemptCount, 1)
        XCTAssertEqual(security.passcodeFallbackAttemptCount, 0, "Strict mode must never touch the fallback path")
    }

    func test_confirm_passesExactVinAndCommandToApiClient() async {
        let security = MockSecurityManager()
        let api = MockTeslaApiClient(commandResult: true)
        let viewModel = ConfirmationModalViewModel(
            command: .setChargeLimit(percent: 80), vin: "VIN999", securityManager: security, apiClient: api,
            settingsStore: MockAppSettingsStore()
        )

        await viewModel.confirm()

        XCTAssertEqual(api.executedCommands, [.init(vin: "VIN999", command: .setChargeLimit(percent: 80))])
    }

    // MARK: - Strict mode: any biometric failure blocks the command, never falls back

    func test_confirm_strictMode_whenUserCancelsBiometrics_neverCallsExecuteCommandAndNeverFallsBack() async {
        let security = MockSecurityManager(biometricOutcome: .failure(.userCancelled))
        let api = MockTeslaApiClient()
        let viewModel = ConfirmationModalViewModel(
            command: .unlockDoors, vin: vin, securityManager: security, apiClient: api,
            settingsStore: MockAppSettingsStore(requireStrictBiometrics: true)
        )

        await viewModel.confirm()

        XCTAssertTrue(api.executedCommands.isEmpty, "executeCommand must never be called after a user cancellation")
        XCTAssertEqual(security.passcodeFallbackAttemptCount, 0, "Strict mode should never attempt the fallback")
        guard case .failed = viewModel.phase else {
            return XCTFail("Expected .failed, got \(viewModel.phase)")
        }
    }

    func test_confirm_strictMode_whenBiometricsUnavailable_neverCallsExecuteCommandAndNeverFallsBack() async {
        let security = MockSecurityManager(biometricOutcome: .failure(.biometryNotEnrolled))
        let api = MockTeslaApiClient()
        let viewModel = ConfirmationModalViewModel(
            command: .lockDoors, vin: vin, securityManager: security, apiClient: api,
            settingsStore: MockAppSettingsStore(requireStrictBiometrics: true)
        )

        await viewModel.confirm()

        XCTAssertTrue(api.executedCommands.isEmpty)
        XCTAssertEqual(security.passcodeFallbackAttemptCount, 0)
        guard case .failed = viewModel.phase else {
            return XCTFail("Expected .failed, got \(viewModel.phase)")
        }
    }

    // MARK: - Passcode-fallback-allowed mode: goes straight to authenticateWithBiometricsOrPasscode

    func test_confirm_fallbackAllowed_success_callsPasscodeFallbackDirectlyAndExecutesCommand() async {
        let security = MockSecurityManager(passcodeFallbackOutcome: .success)
        let api = MockTeslaApiClient(commandResult: true)
        let viewModel = ConfirmationModalViewModel(
            command: .honkHorn, vin: vin, securityManager: security, apiClient: api,
            settingsStore: MockAppSettingsStore(requireStrictBiometrics: false)
        )

        await viewModel.confirm()

        XCTAssertEqual(security.biometricAttemptCount, 0, "Non-strict mode should never call the strict method")
        XCTAssertEqual(security.passcodeFallbackAttemptCount, 1)
        XCTAssertEqual(api.executedCommands, [.init(vin: vin, command: .honkHorn)])
        XCTAssertEqual(viewModel.phase, .success)
    }

    func test_confirm_fallbackAllowed_whenBothTiersFail_neverCallsExecuteCommand() async {
        let security = MockSecurityManager(passcodeFallbackOutcome: .failure(.authenticationFailed))
        let api = MockTeslaApiClient()
        let viewModel = ConfirmationModalViewModel(
            command: .flashLights, vin: vin, securityManager: security, apiClient: api,
            settingsStore: MockAppSettingsStore(requireStrictBiometrics: false)
        )

        await viewModel.confirm()

        XCTAssertTrue(api.executedCommands.isEmpty)
        XCTAssertEqual(security.biometricAttemptCount, 0)
        XCTAssertEqual(security.passcodeFallbackAttemptCount, 1)
        guard case .failed = viewModel.phase else {
            return XCTFail("Expected .failed, got \(viewModel.phase)")
        }
    }

    func test_confirm_fallbackAllowed_whenDeviceHasNoPasscodeConfigured_neverCallsExecuteCommand() async {
        let security = MockSecurityManager(passcodeFallbackOutcome: .failure(.passcodeNotSet))
        let api = MockTeslaApiClient()
        let viewModel = ConfirmationModalViewModel(
            command: .lockDoors, vin: vin, securityManager: security, apiClient: api,
            settingsStore: MockAppSettingsStore(requireStrictBiometrics: false)
        )

        await viewModel.confirm()

        XCTAssertTrue(api.executedCommands.isEmpty)
        guard case .failed = viewModel.phase else {
            return XCTFail("Expected .failed, got \(viewModel.phase)")
        }
    }

    // MARK: - API-layer failures (biometrics already passed)

    func test_confirm_whenTeslaRejectsCommand_setsFailedPhaseWithoutError() async {
        let security = MockSecurityManager()
        let api = MockTeslaApiClient(commandResult: false)
        let viewModel = ConfirmationModalViewModel(
            command: .lockDoors, vin: vin, securityManager: security, apiClient: api,
            settingsStore: MockAppSettingsStore()
        )

        await viewModel.confirm()

        XCTAssertEqual(api.executedCommands, [.init(vin: vin, command: .lockDoors)])
        guard case .failed = viewModel.phase else {
            return XCTFail("Expected .failed, got \(viewModel.phase)")
        }
    }

    func test_confirm_whenApiClientThrows_setsFailedPhase() async {
        let security = MockSecurityManager()
        let api = MockTeslaApiClient(errorToThrow: TeslaApiError.httpError(statusCode: 500, body: "boom"))
        let viewModel = ConfirmationModalViewModel(
            command: .flashLights, vin: vin, securityManager: security, apiClient: api,
            settingsStore: MockAppSettingsStore()
        )

        await viewModel.confirm()

        guard case .failed = viewModel.phase else {
            return XCTFail("Expected .failed, got \(viewModel.phase)")
        }
    }

    // MARK: - Re-entrancy / busy guard

    func test_confirm_whileAlreadyExecuting_isIgnored() async {
        let security = MockSecurityManager()
        let api = MockTeslaApiClient()
        let viewModel = ConfirmationModalViewModel(
            command: .honkHorn, vin: vin, securityManager: security, apiClient: api,
            settingsStore: MockAppSettingsStore(), initialPhase: .executing
        )

        await viewModel.confirm()

        XCTAssertEqual(viewModel.phase, .executing)
        XCTAssertEqual(security.biometricAttemptCount, 0)
        XCTAssertTrue(api.executedCommands.isEmpty)
    }

    // MARK: - Reset

    func test_reset_fromFailedState_returnsToIdle() {
        let viewModel = ConfirmationModalViewModel(
            command: .honkHorn,
            vin: vin,
            securityManager: MockSecurityManager(),
            apiClient: MockTeslaApiClient(),
            settingsStore: MockAppSettingsStore(),
            initialPhase: .failed("boom")
        )

        viewModel.reset()

        XCTAssertEqual(viewModel.phase, .idle)
    }

    func test_reset_whileBusy_isIgnored() {
        let viewModel = ConfirmationModalViewModel(
            command: .honkHorn,
            vin: vin,
            securityManager: MockSecurityManager(),
            apiClient: MockTeslaApiClient(),
            settingsStore: MockAppSettingsStore(),
            initialPhase: .executing
        )

        viewModel.reset()

        XCTAssertEqual(viewModel.phase, .executing)
    }
}
