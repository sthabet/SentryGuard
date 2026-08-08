import Foundation
import LocalAuthentication
import Security

enum BiometricAuthError: Error, LocalizedError, Equatable {
    case biometryNotAvailable
    case biometryNotEnrolled
    case biometryLockedOut
    case passcodeNotSet
    case authenticationFailed
    case userCancelled
    case unknown(String)

    var errorDescription: String? {
        switch self {
        case .biometryNotAvailable:
            return "Face ID / Touch ID is not available on this device."
        case .biometryNotEnrolled:
            return "No Face ID / Touch ID identities are enrolled."
        case .biometryLockedOut:
            return "Biometric authentication is locked. Enter your device passcode to re-enable it."
        case .passcodeNotSet:
            return "A device passcode must be set to use biometric authentication."
        case .authenticationFailed:
            return "Face ID / Touch ID authentication failed."
        case .userCancelled:
            return "Authentication was cancelled."
        case .unknown(let message):
            return message
        }
    }

    init(laError: LAError) {
        switch laError.code {
        case .biometryNotAvailable:
            self = .biometryNotAvailable
        case .biometryNotEnrolled:
            self = .biometryNotEnrolled
        case .biometryLockout:
            self = .biometryLockedOut
        case .passcodeNotSet:
            self = .passcodeNotSet
        case .authenticationFailed:
            self = .authenticationFailed
        case .userCancel, .systemCancel, .appCancel:
            self = .userCancelled
        default:
            self = .unknown(laError.localizedDescription)
        }
    }
}

enum SecureEnclaveError: Error, LocalizedError, Equatable {
    case keyGenerationFailed(String)
    case keyNotFound
    case publicKeyUnavailable
    case publicKeyExportFailed(String)

    var errorDescription: String? {
        switch self {
        case .keyGenerationFailed(let reason):
            return "Vehicle key pair generation failed: \(reason)"
        case .keyNotFound:
            return "No vehicle key pair has been generated yet."
        case .publicKeyUnavailable:
            return "Could not derive the public key from the stored private key."
        case .publicKeyExportFailed(let reason):
            return "Could not export the public key: \(reason)"
        }
    }
}

/// The subset of `LAContext` SecurityManager depends on, so tests can stub biometric
/// outcomes without real enrolled Face ID / Touch ID hardware. `LAContext` already
/// implements both members with matching signatures, so it conforms for free.
protocol BiometricContext {
    func canEvaluatePolicy(_ policy: LAPolicy, error: NSErrorPointer) -> Bool
    func evaluatePolicy(_ policy: LAPolicy, localizedReason: String) async throws -> Bool
}

extension LAContext: BiometricContext {}

@MainActor
protocol SecurityManaging: AnyObject {
    func authenticateWithBiometrics(reason: String) async throws
    /// Biometrics with an automatic system passcode fallback (Apple's `.deviceOwnerAuthentication`
    /// policy) — used when a prior Face ID / Touch ID attempt failed or biometry is unavailable.
    func authenticateWithBiometricsOrPasscode(reason: String) async throws
    @discardableResult
    func generateVehicleKeyPairIfNeeded() throws -> SecKey
    func exportPublicKeyRawRepresentation() throws -> Data
    func deleteVehicleKeyPair() throws
}

/// Face ID / Touch ID verification and Secure Enclave key management for Tesla Virtual Key pairing.
///
/// Per CLAUDE.md rule 2, every vehicle command in the app must pass biometric verification
/// via `authenticateWithBiometrics` before the signed request is sent.
@MainActor
final class SecurityManager: SecurityManaging {
    private let keyTag: Data
    private let contextProvider: () -> any BiometricContext

    init(
        keyTag: String = "com.sentryguard.app.vehiclekey",
        contextProvider: @escaping () -> any BiometricContext = { LAContext() }
    ) {
        self.keyTag = Data(keyTag.utf8)
        self.contextProvider = contextProvider
    }

    // MARK: - Biometric authentication

    func authenticateWithBiometrics(reason: String) async throws {
        try await evaluate(policy: .deviceOwnerAuthenticationWithBiometrics, reason: reason)
    }

    func authenticateWithBiometricsOrPasscode(reason: String) async throws {
        try await evaluate(policy: .deviceOwnerAuthentication, reason: reason)
    }

    private func evaluate(policy: LAPolicy, reason: String) async throws {
        let context = contextProvider()
        var policyError: NSError?

        guard context.canEvaluatePolicy(policy, error: &policyError) else {
            if let laError = policyError as? LAError {
                throw BiometricAuthError(laError: laError)
            }
            throw BiometricAuthError.biometryNotAvailable
        }

        do {
            let success = try await context.evaluatePolicy(policy, localizedReason: reason)
            guard success else {
                throw BiometricAuthError.authenticationFailed
            }
        } catch let laError as LAError {
            throw BiometricAuthError(laError: laError)
        }
    }

    // MARK: - Secure Enclave key management

    @discardableResult
    func generateVehicleKeyPairIfNeeded() throws -> SecKey {
        if let existing = try? loadPrivateKey() {
            return existing
        }
        return try generateVehicleKeyPair()
    }

    func exportPublicKeyRawRepresentation() throws -> Data {
        let privateKey = try loadPrivateKey()
        guard let publicKey = SecKeyCopyPublicKey(privateKey) else {
            throw SecureEnclaveError.publicKeyUnavailable
        }
        var exportError: Unmanaged<CFError>?
        guard let data = SecKeyCopyExternalRepresentation(publicKey, &exportError) as Data? else {
            let reason = (exportError?.takeRetainedValue() as Error?)?.localizedDescription ?? "unknown error"
            throw SecureEnclaveError.publicKeyExportFailed(reason)
        }
        return data
    }

    func deleteVehicleKeyPair() throws {
        let status = SecItemDelete(keyQuery() as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw SecureEnclaveError.keyGenerationFailed("Failed to delete existing key (status \(status)).")
        }
    }

    // MARK: - Private

    private func keyQuery(returningRef: Bool = false) -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassKey,
            kSecAttrApplicationTag as String: keyTag,
            kSecAttrKeyType as String: kSecAttrKeyTypeECSECPrimeRandom
        ]
        if returningRef {
            query[kSecReturnRef as String] = true
        }
        return query
    }

    private func loadPrivateKey() throws -> SecKey {
        var item: CFTypeRef?
        let status = SecItemCopyMatching(keyQuery(returningRef: true) as CFDictionary, &item)
        guard status == errSecSuccess else {
            throw SecureEnclaveError.keyNotFound
        }
        // SecItemCopyMatching with kSecReturnRef guarantees a SecKey for a kSecClassKey query.
        return (item as! SecKey) // swiftlint:disable:this force_cast
    }

    private func generateVehicleKeyPair() throws -> SecKey {
        guard let access = SecAccessControlCreateWithFlags(
            nil,
            kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
            [.privateKeyUsage],
            nil
        ) else {
            throw SecureEnclaveError.keyGenerationFailed("Could not create access control.")
        }

        let attributes: [String: Any] = [
            kSecAttrKeyType as String: kSecAttrKeyTypeECSECPrimeRandom,
            kSecAttrKeySizeInBits as String: 256,
            kSecAttrTokenID as String: kSecAttrTokenIDSecureEnclave,
            kSecPrivateKeyAttrs as String: [
                kSecAttrIsPermanent as String: true,
                kSecAttrApplicationTag as String: keyTag,
                kSecAttrAccessControl as String: access
            ]
        ]

        var createError: Unmanaged<CFError>?
        guard let privateKey = SecKeyCreateRandomKey(attributes as CFDictionary, &createError) else {
            let reason = (createError?.takeRetainedValue() as Error?)?.localizedDescription ?? "unknown error"
            throw SecureEnclaveError.keyGenerationFailed(reason)
        }
        return privateKey
    }
}
