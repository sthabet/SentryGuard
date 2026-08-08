import XCTest
@testable import SentryGuard

@MainActor
final class TeslaApiClientTests: XCTestCase {
    private func stubbedSession(
        handler: @escaping @Sendable (URLRequest) throws -> (HTTPURLResponse, Data)
    ) -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [URLProtocolStub.self]
        URLProtocolStub.requestHandler = handler
        return URLSession(configuration: configuration)
    }

    // MARK: - fetchVehicles

    func test_fetchVehicles_attachesBearerTokenAndDecodesResponse() async throws {
        let capturedRequest = RequestCapture()
        let json = Data("""
        {"response":[{"id":1,"vehicle_id":2,"vin":"VIN123","display_name":"My Model 3","state":"online"}],"count":1}
        """.utf8)

        let session = stubbedSession { request in
            capturedRequest.request = request
            return (makeResponse(for: request, statusCode: 200), json)
        }
        let auth = SpyTeslaAuthService(accessToken: "seed-token")
        let client = TeslaApiClient(authService: auth, urlSession: session)

        let vehicles = try await client.fetchVehicles()

        XCTAssertEqual(vehicles, [TeslaVehicle(id: 1, vehicleID: 2, vin: "VIN123", displayName: "My Model 3", state: "online")])
        XCTAssertEqual(capturedRequest.request?.url?.path, "/api/1/vehicles")
        XCTAssertEqual(capturedRequest.request?.httpMethod, "GET")
        XCTAssertEqual(capturedRequest.request?.value(forHTTPHeaderField: "Authorization"), "Bearer seed-token")
    }

    // MARK: - fetchVehicleState

    func test_fetchVehicleState_decodesNestedVehicleAndChargeState() async throws {
        let capturedRequest = RequestCapture()
        let json = Data("""
        {"response":{
            "vehicle_state":{"locked":true,"sentry_mode":false},
            "charge_state":{"battery_level":81,"charge_port_latch":"Engaged","charging_state":"Disconnected","est_battery_range":215.5}
        }}
        """.utf8)

        let session = stubbedSession { request in
            capturedRequest.request = request
            return (makeResponse(for: request, statusCode: 200), json)
        }
        let auth = SpyTeslaAuthService(accessToken: "seed-token")
        let client = TeslaApiClient(authService: auth, urlSession: session)

        let state = try await client.fetchVehicleState(vin: "VIN123")

        XCTAssertEqual(state.batteryLevel, 81)
        XCTAssertTrue(state.locked)
        XCTAssertFalse(state.sentryModeEnabled)
        XCTAssertEqual(state.chargePortLatch, .engaged)
        XCTAssertEqual(state.chargingState, "Disconnected")
        XCTAssertEqual(state.estimatedRangeMiles, 215.5)
        XCTAssertEqual(capturedRequest.request?.url?.path, "/api/1/vehicles/VIN123/vehicle_data")
    }

    // MARK: - executeCommand

    func test_executeCommand_honkHorn_postsToCorrectEndpointWithNoBody() async throws {
        let capturedRequest = RequestCapture()
        let json = Data("""
        {"response":{"result":true,"reason":""}}
        """.utf8)

        let session = stubbedSession { request in
            capturedRequest.request = request
            capturedRequest.bodyData = request.httpBodyStreamData() ?? request.httpBody
            return (makeResponse(for: request, statusCode: 200), json)
        }
        let auth = SpyTeslaAuthService(accessToken: "seed-token")
        let client = TeslaApiClient(authService: auth, urlSession: session)

        let result = try await client.executeCommand(vin: "VIN123", command: .honkHorn)

        XCTAssertTrue(result)
        XCTAssertEqual(capturedRequest.request?.url?.path, "/api/1/vehicles/VIN123/command/honk_horn")
        XCTAssertEqual(capturedRequest.request?.httpMethod, "POST")
    }

    func test_executeCommand_setChargeLimit_encodesPercentInJSONBody() async throws {
        let capturedRequest = RequestCapture()
        let json = Data("""
        {"response":{"result":true,"reason":""}}
        """.utf8)

        let session = stubbedSession { request in
            capturedRequest.request = request
            capturedRequest.bodyData = request.httpBodyStreamData() ?? request.httpBody
            return (makeResponse(for: request, statusCode: 200), json)
        }
        let auth = SpyTeslaAuthService(accessToken: "seed-token")
        let client = TeslaApiClient(authService: auth, urlSession: session)

        _ = try await client.executeCommand(vin: "VIN123", command: .setChargeLimit(percent: 80))

        XCTAssertEqual(capturedRequest.request?.url?.path, "/api/1/vehicles/VIN123/command/set_charge_limit")
        let bodyJSON = try XCTUnwrap(capturedRequest.bodyData.flatMap {
            try? JSONSerialization.jsonObject(with: $0) as? [String: Any]
        })
        XCTAssertEqual(bodyJSON["percent"] as? Int, 80)
    }

    func test_executeCommand_whenTeslaRejectsCommand_returnsFalse() async throws {
        let json = Data("""
        {"response":{"result":false,"reason":"already_locked"}}
        """.utf8)

        let session = stubbedSession { request in
            (makeResponse(for: request, statusCode: 200), json)
        }
        let auth = SpyTeslaAuthService(accessToken: "seed-token")
        let client = TeslaApiClient(authService: auth, urlSession: session)

        let result = try await client.executeCommand(vin: "VIN123", command: .lockDoors)

        XCTAssertFalse(result)
    }

    // MARK: - Authentication

    func test_send_withNoStoredAccessToken_throwsNotAuthenticatedWithoutHittingNetwork() async {
        let session = stubbedSession { _ in
            XCTFail("Network should not be hit when there is no access token")
            fatalError()
        }
        let auth = SpyTeslaAuthService(state: .signedOut)
        let client = TeslaApiClient(authService: auth, urlSession: session)

        do {
            _ = try await client.fetchVehicles()
            XCTFail("Expected TeslaApiError.notAuthenticated")
        } catch let error as TeslaAuthError {
            XCTAssertEqual(error, .notAuthenticated)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func test_send_on401_callsRefreshTokensIfNeededAndRetriesWithNewToken() async throws {
        let auth = SpyTeslaAuthService(accessToken: "stale-token")
        auth.onRefresh = { auth.accessToken = "refreshed-token" }

        let capturedTokens = TokenCapture()
        let json = Data("""
        {"response":[]}
        """.utf8)

        let session = stubbedSession { request in
            let isFirstCall = capturedTokens.tokens.isEmpty
            capturedTokens.tokens.append(request.value(forHTTPHeaderField: "Authorization") ?? "")
            if isFirstCall {
                return (makeResponse(for: request, statusCode: 401), Data())
            }
            return (makeResponse(for: request, statusCode: 200), json)
        }
        let client = TeslaApiClient(authService: auth, urlSession: session)

        let vehicles = try await client.fetchVehicles()

        XCTAssertEqual(vehicles, [])
        XCTAssertEqual(auth.refreshCallCount, 1)
        XCTAssertEqual(capturedTokens.tokens, ["Bearer stale-token", "Bearer refreshed-token"])
    }

    func test_send_on401_whenRefreshFails_propagatesRefreshError() async {
        let auth = SpyTeslaAuthService(accessToken: "stale-token")
        auth.refreshError = TeslaAuthError.notAuthenticated

        let session = stubbedSession { request in
            (makeResponse(for: request, statusCode: 401), Data())
        }
        let client = TeslaApiClient(authService: auth, urlSession: session)

        do {
            _ = try await client.fetchVehicles()
            XCTFail("Expected TeslaAuthError.notAuthenticated to propagate")
        } catch let error as TeslaAuthError {
            XCTAssertEqual(error, .notAuthenticated)
            XCTAssertEqual(auth.refreshCallCount, 1)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func test_send_on401Twice_doesNotLoopForever() async {
        let auth = SpyTeslaAuthService(accessToken: "stale-token")
        auth.onRefresh = { auth.accessToken = "still-stale-token" }

        let session = stubbedSession { request in
            (makeResponse(for: request, statusCode: 401), Data())
        }
        let client = TeslaApiClient(authService: auth, urlSession: session)

        do {
            _ = try await client.fetchVehicles()
            XCTFail("Expected TeslaApiError.notAuthenticated after single retry")
        } catch let error as TeslaApiError {
            XCTAssertEqual(error, .notAuthenticated)
            XCTAssertEqual(auth.refreshCallCount, 1, "Should only attempt one refresh, not loop")
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    // MARK: - Error handling

    func test_send_onServerError_throwsHttpError() async {
        let session = stubbedSession { request in
            (makeResponse(for: request, statusCode: 500), Data("server exploded".utf8))
        }
        let auth = SpyTeslaAuthService(accessToken: "seed-token")
        let client = TeslaApiClient(authService: auth, urlSession: session)

        do {
            _ = try await client.fetchVehicles()
            XCTFail("Expected TeslaApiError.httpError")
        } catch let error as TeslaApiError {
            XCTAssertEqual(error, .httpError(statusCode: 500, body: "server exploded"))
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func test_send_onMalformedJSON_throwsDecodingFailed() async {
        let session = stubbedSession { request in
            (makeResponse(for: request, statusCode: 200), Data("not json".utf8))
        }
        let auth = SpyTeslaAuthService(accessToken: "seed-token")
        let client = TeslaApiClient(authService: auth, urlSession: session)

        do {
            _ = try await client.fetchVehicles()
            XCTFail("Expected TeslaApiError.decodingFailed")
        } catch let error as TeslaApiError {
            guard case .decodingFailed = error else {
                XCTFail("Expected .decodingFailed, got \(error)")
                return
            }
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }
}

// MARK: - Test helpers

/// Free function (not a method) so it can be called from `@Sendable` stub closures
/// without capturing the non-`Sendable`, `@MainActor`-isolated `XCTestCase`.
private func makeResponse(for request: URLRequest, statusCode: Int) -> HTTPURLResponse {
    HTTPURLResponse(url: request.url!, statusCode: statusCode, httpVersion: nil, headerFields: nil)!
}

// MARK: - Test doubles

@MainActor
private final class SpyTeslaAuthService: TeslaAuthServicing {
    private(set) var state: AuthState
    var accessToken: String
    var refreshError: Error?
    var onRefresh: (() -> Void)?
    private(set) var refreshCallCount = 0

    init(state: AuthState = .authenticated, accessToken: String = "mock-access-token") {
        self.state = state
        self.accessToken = accessToken
    }

    func signIn() async throws {}
    func signOut() throws { state = .signedOut }

    func refreshTokensIfNeeded() async throws {
        refreshCallCount += 1
        if let refreshError {
            throw refreshError
        }
        onRefresh?()
    }

    func currentAccessToken() throws -> String {
        guard state == .authenticated else {
            throw TeslaAuthError.notAuthenticated
        }
        return accessToken
    }
}

private final class RequestCapture: @unchecked Sendable {
    var request: URLRequest?
    var bodyData: Data?
}

private final class TokenCapture: @unchecked Sendable {
    var tokens: [String] = []
}

private extension URLRequest {
    /// `URLProtocol` delivers the body via `httpBodyStream` for some request configurations;
    /// this reads it back so tests can inspect it regardless of which path was used.
    func httpBodyStreamData() -> Data? {
        guard let stream = httpBodyStream else { return nil }
        stream.open()
        defer { stream.close() }

        var data = Data()
        let bufferSize = 4096
        var buffer = [UInt8](repeating: 0, count: bufferSize)
        while stream.hasBytesAvailable {
            let read = stream.read(&buffer, maxLength: bufferSize)
            if read <= 0 { break }
            data.append(buffer, count: read)
        }
        return data.isEmpty ? nil : data
    }
}

/// Intercepts `URLSession` traffic so Fleet API request/response handling can be tested
/// without reaching Tesla's live servers.
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
