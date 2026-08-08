import LocalAuthentication
import XCTest
@testable import SentryGuard

@MainActor
final class SecurityManagerTests: XCTestCase {
    // MARK: - Biometric evaluation states

    func test_authenticateWithBiometrics_whenCanEvaluateSucceedsAndPolicySucceeds_returnsWithoutThrowing() async throws {
        let stub = StubBiometricContext(canEvaluateResult: true, evaluateResult: .success(true))
        let manager = SecurityManager(keyTag: uniqueKeyTag(), contextProvider: { stub })

        try await manager.authenticateWithBiometrics(reason: "Confirm Unlock")
    }

    func test_authenticateWithBiometrics_whenPolicyReturnsFalse_throwsAuthenticationFailed() async {
        let stub = StubBiometricContext(canEvaluateResult: true, evaluateResult: .success(false))
        let manager = SecurityManager(keyTag: uniqueKeyTag(), contextProvider: { stub })

        await assertThrows(.authenticationFailed) {
            try await manager.authenticateWithBiometrics(reason: "Confirm Unlock")
        }
    }

    func test_authenticateWithBiometrics_whenBiometryNotEnrolled_throwsBiometryNotEnrolled() async {
        let stub = StubBiometricContext(canEvaluateResult: false, canEvaluateError: LAError(.biometryNotEnrolled))
        let manager = SecurityManager(keyTag: uniqueKeyTag(), contextProvider: { stub })

        await assertThrows(.biometryNotEnrolled) {
            try await manager.authenticateWithBiometrics(reason: "Confirm Unlock")
        }
    }

    func test_authenticateWithBiometrics_whenBiometryLockedOut_throwsBiometryLockedOut() async {
        let stub = StubBiometricContext(canEvaluateResult: false, canEvaluateError: LAError(.biometryLockout))
        let manager = SecurityManager(keyTag: uniqueKeyTag(), contextProvider: { stub })

        await assertThrows(.biometryLockedOut) {
            try await manager.authenticateWithBiometrics(reason: "Confirm Unlock")
        }
    }

    func test_authenticateWithBiometrics_whenUserCancels_throwsUserCancelled() async {
        let stub = StubBiometricContext(canEvaluateResult: true, evaluateResult: .failure(LAError(.userCancel)))
        let manager = SecurityManager(keyTag: uniqueKeyTag(), contextProvider: { stub })

        await assertThrows(.userCancelled) {
            try await manager.authenticateWithBiometrics(reason: "Confirm Unlock")
        }
    }

    func test_authenticateWithBiometrics_whenPasscodeNotSet_throwsPasscodeNotSet() async {
        let stub = StubBiometricContext(canEvaluateResult: false, canEvaluateError: LAError(.passcodeNotSet))
        let manager = SecurityManager(keyTag: uniqueKeyTag(), contextProvider: { stub })

        await assertThrows(.passcodeNotSet) {
            try await manager.authenticateWithBiometrics(reason: "Confirm Unlock")
        }
    }

    // MARK: - Biometrics-or-passcode fallback

    func test_authenticateWithBiometricsOrPasscode_whenPolicySucceeds_returnsWithoutThrowing() async throws {
        let stub = StubBiometricContext(canEvaluateResult: true, evaluateResult: .success(true))
        let manager = SecurityManager(keyTag: uniqueKeyTag(), contextProvider: { stub })

        try await manager.authenticateWithBiometricsOrPasscode(reason: "Confirm Unlock")
    }

    func test_authenticateWithBiometricsOrPasscode_whenPasscodeNotSet_throwsPasscodeNotSet() async {
        let stub = StubBiometricContext(canEvaluateResult: false, canEvaluateError: LAError(.passcodeNotSet))
        let manager = SecurityManager(keyTag: uniqueKeyTag(), contextProvider: { stub })

        await assertThrows(.passcodeNotSet) {
            try await manager.authenticateWithBiometricsOrPasscode(reason: "Confirm Unlock")
        }
    }

    func test_authenticateWithBiometricsOrPasscode_whenUserCancels_throwsUserCancelled() async {
        let stub = StubBiometricContext(canEvaluateResult: true, evaluateResult: .failure(LAError(.userCancel)))
        let manager = SecurityManager(keyTag: uniqueKeyTag(), contextProvider: { stub })

        await assertThrows(.userCancelled) {
            try await manager.authenticateWithBiometricsOrPasscode(reason: "Confirm Unlock")
        }
    }

    // MARK: - Secure Enclave key generation

    func test_generateVehicleKeyPairIfNeeded_whenNoKeyExists_createsOne() throws {
        let manager = SecurityManager(keyTag: uniqueKeyTag())
        defer { try? manager.deleteVehicleKeyPair() }

        XCTAssertNoThrow(try manager.generateVehicleKeyPairIfNeeded())
    }

    func test_generateVehicleKeyPairIfNeeded_calledTwice_reusesTheSamePersistedKey() throws {
        let manager = SecurityManager(keyTag: uniqueKeyTag())
        defer { try? manager.deleteVehicleKeyPair() }

        _ = try manager.generateVehicleKeyPairIfNeeded()
        let firstPublicKey = try manager.exportPublicKeyRawRepresentation()

        _ = try manager.generateVehicleKeyPairIfNeeded()
        let secondPublicKey = try manager.exportPublicKeyRawRepresentation()

        XCTAssertEqual(firstPublicKey, secondPublicKey)
    }

    func test_exportPublicKeyRawRepresentation_returnsUncompressedP256Point() throws {
        let manager = SecurityManager(keyTag: uniqueKeyTag())
        defer { try? manager.deleteVehicleKeyPair() }

        _ = try manager.generateVehicleKeyPairIfNeeded()
        let publicKeyData = try manager.exportPublicKeyRawRepresentation()

        // Uncompressed EC point: 0x04 prefix + 32-byte X + 32-byte Y.
        XCTAssertEqual(publicKeyData.count, 65)
        XCTAssertEqual(publicKeyData.first, 0x04)
    }

    func test_exportPublicKeyRawRepresentation_withNoGeneratedKey_throwsKeyNotFound() {
        let manager = SecurityManager(keyTag: uniqueKeyTag())

        XCTAssertThrowsError(try manager.exportPublicKeyRawRepresentation()) { error in
            XCTAssertEqual(error as? SecureEnclaveError, .keyNotFound)
        }
    }

    func test_deleteVehicleKeyPair_removesKeySoExportThrowsKeyNotFoundAfterward() throws {
        let manager = SecurityManager(keyTag: uniqueKeyTag())

        _ = try manager.generateVehicleKeyPairIfNeeded()
        try manager.deleteVehicleKeyPair()

        XCTAssertThrowsError(try manager.exportPublicKeyRawRepresentation()) { error in
            XCTAssertEqual(error as? SecureEnclaveError, .keyNotFound)
        }
    }

    func test_deleteVehicleKeyPair_whenNoKeyExists_doesNotThrow() {
        let manager = SecurityManager(keyTag: uniqueKeyTag())

        XCTAssertNoThrow(try manager.deleteVehicleKeyPair())
    }

    // MARK: - MockSecurityManager

    func test_mockSecurityManager_defaultsToSuccessfulBiometrics() async throws {
        let mock = MockSecurityManager()

        try await mock.authenticateWithBiometrics(reason: "Confirm Unlock")
    }

    func test_mockSecurityManager_withInjectedFailure_throwsConfiguredError() async {
        let mock = MockSecurityManager(biometricOutcome: .failure(.biometryLockedOut))

        await assertThrows(.biometryLockedOut) {
            try await mock.authenticateWithBiometrics(reason: "Confirm Unlock")
        }
    }

    func test_mockSecurityManager_generateAndExportKeyPair_roundTrips() throws {
        let mock = MockSecurityManager()

        _ = try mock.generateVehicleKeyPairIfNeeded()
        let exported = try mock.exportPublicKeyRawRepresentation()

        XCTAssertTrue(mock.didGenerateKeyPair)
        XCTAssertFalse(exported.isEmpty)
    }

    func test_mockSecurityManager_deleteKeyPair_clearsGeneratedKey() throws {
        let mock = MockSecurityManager()
        _ = try mock.generateVehicleKeyPairIfNeeded()

        try mock.deleteVehicleKeyPair()

        XCTAssertTrue(mock.didDeleteKeyPair)
        XCTAssertThrowsError(try mock.exportPublicKeyRawRepresentation())
    }

    func test_mockSecurityManager_withInjectedKeyGenerationError_throwsOnGenerate() {
        let mock = MockSecurityManager(keyGenerationError: .keyGenerationFailed("simulated failure"))

        XCTAssertThrowsError(try mock.generateVehicleKeyPairIfNeeded()) { error in
            XCTAssertEqual(error as? SecureEnclaveError, .keyGenerationFailed("simulated failure"))
        }
    }

    // MARK: - Helpers

    private func uniqueKeyTag() -> String {
        "com.sentryguard.app.tests.vehiclekey.\(UUID().uuidString)"
    }

    private func assertThrows(
        _ expected: BiometricAuthError,
        file: StaticString = #filePath,
        line: UInt = #line,
        _ operation: () async throws -> Void
    ) async {
        do {
            try await operation()
            XCTFail("Expected \(expected) to be thrown", file: file, line: line)
        } catch let error as BiometricAuthError {
            XCTAssertEqual(error, expected, file: file, line: line)
        } catch {
            XCTFail("Unexpected error: \(error)", file: file, line: line)
        }
    }
}

// MARK: - Stub

private final class StubBiometricContext: BiometricContext {
    private let canEvaluateResult: Bool
    private let canEvaluateError: LAError?
    private let evaluateResult: Result<Bool, Error>

    init(
        canEvaluateResult: Bool,
        canEvaluateError: LAError? = nil,
        evaluateResult: Result<Bool, Error> = .success(true)
    ) {
        self.canEvaluateResult = canEvaluateResult
        self.canEvaluateError = canEvaluateError
        self.evaluateResult = evaluateResult
    }

    func canEvaluatePolicy(_ policy: LAPolicy, error: NSErrorPointer) -> Bool {
        if let canEvaluateError {
            error?.pointee = canEvaluateError as NSError
        }
        return canEvaluateResult
    }

    func evaluatePolicy(_ policy: LAPolicy, localizedReason: String) async throws -> Bool {
        switch evaluateResult {
        case .success(let value):
            return value
        case .failure(let error):
            throw error
        }
    }
}
