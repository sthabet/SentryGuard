import XCTest
@testable import SentryGuard

final class KeychainServiceTests: XCTestCase {
    private var keychain: KeychainService!

    override func setUp() {
        super.setUp()
        keychain = KeychainService(service: "com.sentryguard.app.tests.\(UUID().uuidString)")
    }

    override func tearDown() {
        for key in [KeychainKey.accessToken, .refreshToken, .privateKey] {
            try? keychain.delete(for: key)
        }
        keychain = nil
        super.tearDown()
    }

    // MARK: - Data round trip

    func test_saveAndReadData_roundTrips() throws {
        let payload = Data("secret-bytes".utf8)

        try keychain.save(payload, for: .privateKey)

        XCTAssertEqual(try keychain.readData(for: .privateKey), payload)
    }

    // MARK: - String round trip

    func test_saveAndReadString_roundTrips() throws {
        try keychain.save("initial-access-token", for: .accessToken)

        XCTAssertEqual(try keychain.readString(for: .accessToken), "initial-access-token")
    }

    func test_save_calledTwiceForSameKey_upsertsRatherThanThrowing() throws {
        try keychain.save("first-value", for: .accessToken)
        try keychain.save("second-value", for: .accessToken)

        XCTAssertEqual(try keychain.readString(for: .accessToken), "second-value")
    }

    // MARK: - Update

    func test_update_onExistingItem_overwritesValue() throws {
        try keychain.save("stale-refresh-token", for: .refreshToken)

        try keychain.update(Data("fresh-refresh-token".utf8), for: .refreshToken)

        XCTAssertEqual(try keychain.readString(for: .refreshToken), "fresh-refresh-token")
    }

    func test_update_whenNoItemExists_fallsBackToSave() throws {
        try keychain.update(Data("newly-created".utf8), for: .refreshToken)

        XCTAssertEqual(try keychain.readString(for: .refreshToken), "newly-created")
    }

    // MARK: - Delete

    func test_delete_removesItemSoSubsequentReadThrowsItemNotFound() throws {
        try keychain.save("to-be-deleted", for: .accessToken)

        try keychain.delete(for: .accessToken)

        XCTAssertThrowsError(try keychain.readData(for: .accessToken)) { error in
            XCTAssertEqual(error as? KeychainServiceError, .itemNotFound)
        }
    }

    func test_delete_whenNoItemExists_doesNotThrow() {
        XCTAssertNoThrow(try keychain.delete(for: .accessToken))
    }

    // MARK: - Missing items

    func test_readData_withNoStoredItem_throwsItemNotFound() {
        XCTAssertThrowsError(try keychain.readData(for: .privateKey)) { error in
            XCTAssertEqual(error as? KeychainServiceError, .itemNotFound)
        }
    }

    // MARK: - Key isolation

    func test_differentKeys_onSameService_doNotCollide() throws {
        try keychain.save("access-value", for: .accessToken)
        try keychain.save("refresh-value", for: .refreshToken)

        XCTAssertEqual(try keychain.readString(for: .accessToken), "access-value")
        XCTAssertEqual(try keychain.readString(for: .refreshToken), "refresh-value")
    }

    func test_differentServiceInstances_doNotShareStorage() throws {
        let otherKeychain = KeychainService(service: "com.sentryguard.app.tests.\(UUID().uuidString)")

        try keychain.save("visible-to-first-instance-only", for: .accessToken)

        XCTAssertThrowsError(try otherKeychain.readString(for: .accessToken)) { error in
            XCTAssertEqual(error as? KeychainServiceError, .itemNotFound)
        }
    }
}
