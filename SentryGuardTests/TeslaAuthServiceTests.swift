import XCTest
@testable import SentryGuard

@MainActor
final class TeslaAuthServiceTests: XCTestCase {
    private var keychain: KeychainService!

    override func setUp() async throws {
        try await super.setUp()
        keychain = KeychainService(service: "com.sentryguard.app.tests")
        try? keychain.delete(for: .accessToken)
        try? keychain.delete(for: .refreshToken)
    }

    override func tearDown() async throws {
        try? keychain.delete(for: .accessToken)
        try? keychain.delete(for: .refreshToken)
        keychain = nil
        try await super.tearDown()
    }

    private func stubbedSession(
        handler: @escaping @Sendable (URLRequest) throws -> (HTTPURLResponse, Data)
    ) -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [URLProtocolStub.self]
        URLProtocolStub.requestHandler = handler
        return URLSession(configuration: configuration)
    }

    // MARK: - Initial state derived from Keychain

    func test_init_withNoStoredTokens_startsSignedOut() {
        let service = TeslaAuthService(
            keychain: keychain,
            urlSession: stubbedSession { _ in XCTFail("Network should not be hit"); fatalError() }
        )

        XCTAssertEqual(service.state, .signedOut)
    }

    func test_init_withStoredAccessToken_startsAuthenticated() throws {
        try keychain.save("cached-access-token", for: .accessToken)

        let service = TeslaAuthService(
            keychain: keychain,
            urlSession: stubbedSession { _ in XCTFail("Network should not be hit"); fatalError() }
        )

        XCTAssertEqual(service.state, .authenticated)
    }

    // MARK: - Sign out

    func test_signOut_clearsKeychainAndResetsState() throws {
        try keychain.save("access", for: .accessToken)
        try keychain.save("refresh", for: .refreshToken)
        let service = TeslaAuthService(
            keychain: keychain,
            urlSession: stubbedSession { _ in XCTFail("Network should not be hit"); fatalError() }
        )

        try service.signOut()

        XCTAssertEqual(service.state, .signedOut)
        XCTAssertThrowsError(try keychain.readString(for: .accessToken))
        XCTAssertThrowsError(try keychain.readString(for: .refreshToken))
    }

    // MARK: - Current access token

    func test_currentAccessToken_withStoredToken_returnsIt() throws {
        try keychain.save("stored-access-token", for: .accessToken)
        let service = TeslaAuthService(
            keychain: keychain,
            urlSession: stubbedSession { _ in XCTFail("Network should not be hit"); fatalError() }
        )

        XCTAssertEqual(try service.currentAccessToken(), "stored-access-token")
    }

    func test_currentAccessToken_withNoStoredToken_throwsNotAuthenticated() {
        let service = TeslaAuthService(
            keychain: keychain,
            urlSession: stubbedSession { _ in XCTFail("Network should not be hit"); fatalError() }
        )

        XCTAssertThrowsError(try service.currentAccessToken()) { error in
            XCTAssertEqual(error as? TeslaAuthError, .notAuthenticated)
        }
    }

    // MARK: - Refresh

    func test_refreshTokensIfNeeded_withNoStoredRefreshToken_throwsNotAuthenticated() async {
        let service = TeslaAuthService(
            keychain: keychain,
            urlSession: stubbedSession { _ in XCTFail("Network should not be hit"); fatalError() }
        )

        do {
            try await service.refreshTokensIfNeeded()
            XCTFail("Expected TeslaAuthError.notAuthenticated")
        } catch let error as TeslaAuthError {
            XCTAssertEqual(error, .notAuthenticated)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func test_refreshTokensIfNeeded_withValidResponse_persistsTokensAndUpdatesState() async throws {
        try keychain.save("stale-refresh-token", for: .refreshToken)

        let responseJSON = Data("""
        {"access_token":"new-access","refresh_token":"new-refresh","expires_in":3600,"token_type":"Bearer"}
        """.utf8)

        let session = stubbedSession { request in
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (response, responseJSON)
        }
        let service = TeslaAuthService(keychain: keychain, urlSession: session)

        try await service.refreshTokensIfNeeded()

        XCTAssertEqual(service.state, .authenticated)
        XCTAssertEqual(try keychain.readString(for: .accessToken), "new-access")
        XCTAssertEqual(try keychain.readString(for: .refreshToken), "new-refresh")
    }

    func test_refreshTokensIfNeeded_withServerError_throwsTokenExchangeFailedAndSetsErrorState() async throws {
        try keychain.save("stale-refresh-token", for: .refreshToken)

        let session = stubbedSession { request in
            let response = HTTPURLResponse(url: request.url!, statusCode: 400, httpVersion: nil, headerFields: nil)!
            return (response, Data("invalid_grant".utf8))
        }
        let service = TeslaAuthService(keychain: keychain, urlSession: session)

        do {
            try await service.refreshTokensIfNeeded()
            XCTFail("Expected TeslaAuthError.tokenExchangeFailed")
        } catch let error as TeslaAuthError {
            guard case .tokenExchangeFailed = error else {
                XCTFail("Expected .tokenExchangeFailed, got \(error)")
                return
            }
        }

        guard case .error = service.state else {
            XCTFail("Expected service.state to be .error, got \(service.state)")
            return
        }
    }

    // MARK: - MockTeslaAuthService state transitions

    func test_mockService_signIn_endsInAuthenticatedState() async throws {
        let mock = MockTeslaAuthService(signInDelayNanoseconds: 0)
        XCTAssertEqual(mock.state, .signedOut)

        try await mock.signIn()

        XCTAssertEqual(mock.state, .authenticated)
    }

    func test_mockService_signIn_withInjectedError_setsErrorStateAndThrows() async {
        let mock = MockTeslaAuthService(
            signInError: .tokenExchangeFailed("invalid_grant"),
            signInDelayNanoseconds: 0
        )

        do {
            try await mock.signIn()
            XCTFail("Expected injected error to be thrown")
        } catch let error as TeslaAuthError {
            XCTAssertEqual(error, .tokenExchangeFailed("invalid_grant"))
        } catch {
            XCTFail("Unexpected error: \(error)")
        }

        guard case .error = mock.state else {
            XCTFail("Expected mock.state to be .error, got \(mock.state)")
            return
        }
    }

    func test_mockService_signOut_resetsStateToSignedOut() throws {
        let mock = MockTeslaAuthService(initialState: .authenticated)

        try mock.signOut()

        XCTAssertEqual(mock.state, .signedOut)
    }

    func test_mockService_refreshTokensIfNeeded_whenNotAuthenticated_throws() async {
        let mock = MockTeslaAuthService(initialState: .signedOut)

        do {
            try await mock.refreshTokensIfNeeded()
            XCTFail("Expected TeslaAuthError.notAuthenticated")
        } catch let error as TeslaAuthError {
            XCTAssertEqual(error, .notAuthenticated)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }
}

/// Intercepts `URLSession` traffic so token-exchange logic can be tested without
/// reaching Tesla's live OAuth servers.
private final class URLProtocolStub: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var requestHandler: (@Sendable (URLRequest) throws -> (HTTPURLResponse, Data))?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let handler = URLProtocolStub.requestHandler else {
            fatalError("URLProtocolStub.requestHandler not set")
        }
        do {
            let (response, data) = try handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}
