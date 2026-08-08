import Foundation
import Security

/// `SecurityManaging` stand-in for SwiftUI Previews and unit tests, so biometric
/// prompts and Secure Enclave hardware never need to be involved.
@MainActor
final class MockSecurityManager: SecurityManaging {
    enum BiometricOutcome {
        case success
        case failure(BiometricAuthError)
    }

    var biometricOutcome: BiometricOutcome
    var passcodeFallbackOutcome: BiometricOutcome
    private(set) var didGenerateKeyPair = false
    private(set) var didDeleteKeyPair = false
    private(set) var biometricAttemptCount = 0
    private(set) var passcodeFallbackAttemptCount = 0

    private let publicKeyData: Data
    private let keyGenerationError: SecureEnclaveError?
    private var mockKey: SecKey?

    init(
        biometricOutcome: BiometricOutcome = .success,
        passcodeFallbackOutcome: BiometricOutcome = .success,
        publicKeyData: Data = Data([0x04] + [UInt8](repeating: 0xAB, count: 64)),
        keyGenerationError: SecureEnclaveError? = nil
    ) {
        self.biometricOutcome = biometricOutcome
        self.passcodeFallbackOutcome = passcodeFallbackOutcome
        self.publicKeyData = publicKeyData
        self.keyGenerationError = keyGenerationError
    }

    func authenticateWithBiometrics(reason: String) async throws {
        biometricAttemptCount += 1
        switch biometricOutcome {
        case .success:
            return
        case .failure(let error):
            throw error
        }
    }

    func authenticateWithBiometricsOrPasscode(reason: String) async throws {
        passcodeFallbackAttemptCount += 1
        switch passcodeFallbackOutcome {
        case .success:
            return
        case .failure(let error):
            throw error
        }
    }

    @discardableResult
    func generateVehicleKeyPairIfNeeded() throws -> SecKey {
        if let keyGenerationError {
            throw keyGenerationError
        }
        if let mockKey {
            return mockKey
        }
        didGenerateKeyPair = true
        let key = try Self.makeEphemeralKey()
        mockKey = key
        return key
    }

    func exportPublicKeyRawRepresentation() throws -> Data {
        if let keyGenerationError {
            throw keyGenerationError
        }
        guard mockKey != nil else {
            throw SecureEnclaveError.keyNotFound
        }
        return publicKeyData
    }

    func deleteVehicleKeyPair() throws {
        mockKey = nil
        didDeleteKeyPair = true
    }

    /// A plain in-memory P-256 key (no Secure Enclave, no Keychain persistence) that
    /// only exists to satisfy the `SecKey`-returning protocol requirement in Previews/tests.
    private static func makeEphemeralKey() throws -> SecKey {
        let attributes: [String: Any] = [
            kSecAttrKeyType as String: kSecAttrKeyTypeECSECPrimeRandom,
            kSecAttrKeySizeInBits as String: 256
        ]
        var error: Unmanaged<CFError>?
        guard let key = SecKeyCreateRandomKey(attributes as CFDictionary, &error) else {
            throw SecureEnclaveError.keyGenerationFailed("Mock key generation failed.")
        }
        return key
    }
}
