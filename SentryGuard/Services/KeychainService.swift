import Foundation
import Security

/// Identifies a piece of sensitive data stored in the Keychain.
/// Raw values double as the `kSecAttrAccount` for each item.
enum KeychainKey: String {
    case accessToken = "com.sentryguard.app.accessToken"
    case refreshToken = "com.sentryguard.app.refreshToken"
    case privateKey = "com.sentryguard.app.privateKey"
}

enum KeychainServiceError: Error, LocalizedError, Equatable {
    case itemNotFound
    case invalidItemData
    case unexpectedStatus(OSStatus)

    var errorDescription: String? {
        switch self {
        case .itemNotFound:
            return "The requested item was not found in the Keychain."
        case .invalidItemData:
            return "The item's data could not be encoded or decoded."
        case .unexpectedStatus(let status):
            let message = SecCopyErrorMessageString(status, nil) as String? ?? "unknown error"
            return "Keychain operation failed with status \(status): \(message)"
        }
    }
}

/// Reads and writes sensitive data (OAuth tokens, private key material) to the iOS Keychain.
///
/// This is the ONLY approved storage mechanism for credentials in SentryGuard — see
/// CLAUDE.md rule 4. Never persist tokens or key material in `UserDefaults`.
struct KeychainService {
    private let service: String

    init(service: String = "com.sentryguard.app") {
        self.service = service
    }

    // MARK: - Data

    /// Saves `data` for `key`, overwriting any existing value (upsert).
    func save(_ data: Data, for key: KeychainKey) throws {
        var addQuery = baseQuery(for: key)
        addQuery[kSecValueData as String] = data
        addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly

        let status = SecItemAdd(addQuery as CFDictionary, nil)

        switch status {
        case errSecSuccess:
            return
        case errSecDuplicateItem:
            try update(data, for: key)
        default:
            throw KeychainServiceError.unexpectedStatus(status)
        }
    }

    /// Reads the raw `Data` stored for `key`. Throws `.itemNotFound` if absent.
    func readData(for key: KeychainKey) throws -> Data {
        var query = baseQuery(for: key)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        switch status {
        case errSecSuccess:
            guard let data = result as? Data else {
                throw KeychainServiceError.invalidItemData
            }
            return data
        case errSecItemNotFound:
            throw KeychainServiceError.itemNotFound
        default:
            throw KeychainServiceError.unexpectedStatus(status)
        }
    }

    /// Updates the value stored for an existing `key`. Falls back to `save` if the item doesn't exist yet.
    func update(_ data: Data, for key: KeychainKey) throws {
        let query = baseQuery(for: key)
        let attributes: [String: Any] = [kSecValueData as String: data]

        let status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)

        switch status {
        case errSecSuccess:
            return
        case errSecItemNotFound:
            try save(data, for: key)
        default:
            throw KeychainServiceError.unexpectedStatus(status)
        }
    }

    /// Deletes the item for `key`. Succeeds silently if no item exists.
    func delete(for key: KeychainKey) throws {
        let status = SecItemDelete(baseQuery(for: key) as CFDictionary)

        switch status {
        case errSecSuccess, errSecItemNotFound:
            return
        default:
            throw KeychainServiceError.unexpectedStatus(status)
        }
    }

    // MARK: - String convenience

    func save(_ string: String, for key: KeychainKey) throws {
        guard let data = string.data(using: .utf8) else {
            throw KeychainServiceError.invalidItemData
        }
        try save(data, for: key)
    }

    func readString(for key: KeychainKey) throws -> String {
        let data = try readData(for: key)
        guard let string = String(data: data, encoding: .utf8) else {
            throw KeychainServiceError.invalidItemData
        }
        return string
    }

    // MARK: - Private

    private func baseQuery(for key: KeychainKey) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key.rawValue
        ]
    }
}
