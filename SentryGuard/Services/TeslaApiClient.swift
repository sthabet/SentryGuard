import Foundation

// MARK: - Protocol

@MainActor
protocol TeslaApiClienting: AnyObject {
    func fetchVehicles() async throws -> [TeslaVehicle]
    func fetchVehicleState(vin: String) async throws -> TeslaVehicleState
    func executeCommand(vin: String, command: VehicleCommand) async throws -> Bool
    /// `POST /api/1/vehicles/{vin}/wake_up`. Only brings the vehicle out of sleep —
    /// callers still need to re-fetch state afterward, since waking isn't instantaneous.
    func wakeVehicle(vin: String) async throws -> TeslaVehicle
}

// MARK: - Client

/// Talks to the Tesla Fleet API. Attaches the Bearer token from the injected
/// `TeslaAuthServicing`, and on a 401 response calls `refreshTokensIfNeeded()`
/// once before retrying the request with the refreshed token.
@MainActor
final class TeslaApiClient: TeslaApiClienting {
    private let baseURL: URL
    private let authService: any TeslaAuthServicing
    private let urlSession: URLSession

    init(
        baseURL: URL = URL(string: "https://fleet-api.prd.na.vn.cloud.tesla.com")!,
        authService: any TeslaAuthServicing,
        urlSession: URLSession = .shared
    ) {
        self.baseURL = baseURL
        self.authService = authService
        self.urlSession = urlSession
    }

    func fetchVehicles() async throws -> [TeslaVehicle] {
        let envelope: TeslaAPIResponse<[TeslaVehicle]> = try await send(path: "/api/1/vehicles", method: "GET")
        return envelope.response
    }

    func fetchVehicleState(vin: String) async throws -> TeslaVehicleState {
        // `endpoints` is required — Tesla's Fleet API omits `charge_state`/`vehicle_state`
        // from the response entirely without it (rather than erroring), which is what was
        // producing "Could not decode ... it is missing" on every single call, asleep or
        // not: `TeslaVehicleState.init(from:)` requires both of those nested objects.
        let envelope: TeslaAPIResponse<TeslaVehicleState> = try await send(
            path: "/api/1/vehicles/\(vin)/vehicle_data",
            method: "GET",
            queryItems: [URLQueryItem(name: "endpoints", value: "charge_state;vehicle_state")]
        )
        return envelope.response
    }

    func executeCommand(vin: String, command: VehicleCommand) async throws -> Bool {
        let envelope: TeslaAPIResponse<CommandResult> = try await send(
            path: "/api/1/vehicles/\(vin)/command/\(command.endpoint)",
            method: "POST",
            body: command.jsonBody
        )
        return envelope.response.result
    }

    func wakeVehicle(vin: String) async throws -> TeslaVehicle {
        let envelope: TeslaAPIResponse<TeslaVehicle> = try await send(
            path: "/api/1/vehicles/\(vin)/wake_up",
            method: "POST"
        )
        return envelope.response
    }

    // MARK: - Networking core

    private func send<T: Decodable>(
        path: String,
        method: String,
        body: [String: Any]? = nil,
        queryItems: [URLQueryItem]? = nil,
        isRetryAfterRefresh: Bool = false
    ) async throws -> T {
        let accessToken = try authService.currentAccessToken()

        var url = baseURL.appending(path: path)
        if let queryItems, var components = URLComponents(url: url, resolvingAgainstBaseURL: false) {
            components.queryItems = queryItems
            url = components.url ?? url
        }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
        }

        let (data, response) = try await urlSession.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw TeslaApiError.invalidResponse
        }

        if httpResponse.statusCode == 401 {
            guard !isRetryAfterRefresh else {
                throw TeslaApiError.notAuthenticated
            }
            try await authService.refreshTokensIfNeeded()
            return try await send(
                path: path, method: method, body: body, queryItems: queryItems, isRetryAfterRefresh: true
            )
        }

        if httpResponse.statusCode == 408 {
            throw TeslaApiError.vehicleAsleep
        }

        guard (200..<300).contains(httpResponse.statusCode) else {
            let bodyString = String(data: data, encoding: .utf8) ?? ""
            throw TeslaApiError.httpError(statusCode: httpResponse.statusCode, body: bodyString)
        }

        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            // Include the raw body so a mismatch between our DTOs and Tesla's actual
            // response shape is diagnosable from the on-screen error alone, without
            // needing an Xcode console attached to the device.
            let bodyString = String(data: data, encoding: .utf8) ?? "<non-UTF8 body>"
            throw TeslaApiError.decodingFailed("\(error.localizedDescription) — raw response: \(bodyString.prefix(500))")
        }
    }
}

// MARK: - Response envelope

private struct TeslaAPIResponse<T: Decodable>: Decodable {
    let response: T
}

private struct CommandResult: Decodable {
    let result: Bool
    let reason: String?
}
