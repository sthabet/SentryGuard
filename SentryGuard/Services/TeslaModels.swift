import Foundation

// MARK: - Vehicle command

enum VehicleCommand: Equatable {
    case honkHorn
    case flashLights
    case lockDoors
    case unlockDoors
    case setChargeLimit(percent: Int)

    /// Tesla Fleet API command path segment: `POST /api/1/vehicles/{vin}/command/{endpoint}`.
    var endpoint: String {
        switch self {
        case .honkHorn: return "honk_horn"
        case .flashLights: return "flash_lights"
        case .lockDoors: return "door_lock"
        case .unlockDoors: return "door_unlock"
        case .setChargeLimit: return "set_charge_limit"
        }
    }

    var jsonBody: [String: Any]? {
        switch self {
        case .setChargeLimit(let percent):
            return ["percent": percent]
        case .honkHorn, .flashLights, .lockDoors, .unlockDoors:
            return nil
        }
    }
}

// MARK: - DTOs

struct TeslaVehicle: Decodable, Identifiable, Equatable {
    let id: Int
    let vehicleID: Int
    let vin: String
    let displayName: String
    let state: String

    enum CodingKeys: String, CodingKey {
        case id
        case vehicleID = "vehicle_id"
        case vin
        case displayName = "display_name"
        case state
    }

    init(id: Int, vehicleID: Int, vin: String, displayName: String, state: String) {
        self.id = id
        self.vehicleID = vehicleID
        self.vin = vin
        self.displayName = displayName
        self.state = state
    }

    /// Tesla VINs encode the model at position 4 (0-indexed 3); the Fleet API doesn't
    /// otherwise expose a model name on this endpoint.
    var modelName: String {
        guard vin.count == 17 else { return "Tesla Vehicle" }
        switch vin[vin.index(vin.startIndex, offsetBy: 3)] {
        case "S": return "Model S"
        case "3": return "Model 3"
        case "X": return "Model X"
        case "Y": return "Model Y"
        default: return "Tesla Vehicle"
        }
    }
}

struct TeslaVehicleState: Codable, Equatable {
    enum ChargePortLatch: String, Codable, Equatable {
        case engaged = "Engaged"
        case disengaged = "Disengaged"
        case unknown

        init(from decoder: Decoder) throws {
            let raw = try decoder.singleValueContainer().decode(String.self)
            self = ChargePortLatch(rawValue: raw) ?? .unknown
        }

        func encode(to encoder: Encoder) throws {
            var container = encoder.singleValueContainer()
            try container.encode(rawValue)
        }
    }

    let batteryLevel: Int
    let locked: Bool
    let sentryModeEnabled: Bool
    let chargePortLatch: ChargePortLatch
    let chargingState: String
    let estimatedRangeMiles: Double

    private enum RootKeys: String, CodingKey {
        case vehicleState = "vehicle_state"
        case chargeState = "charge_state"
    }

    private enum VehicleStateKeys: String, CodingKey {
        case locked
        case sentryModeEnabled = "sentry_mode"
    }

    private enum ChargeStateKeys: String, CodingKey {
        case batteryLevel = "battery_level"
        case chargePortLatch = "charge_port_latch"
        case chargingState = "charging_state"
        case estimatedRangeMiles = "est_battery_range"
    }

    init(from decoder: Decoder) throws {
        let root = try decoder.container(keyedBy: RootKeys.self)
        let vehicleState = try root.nestedContainer(keyedBy: VehicleStateKeys.self, forKey: .vehicleState)
        let chargeState = try root.nestedContainer(keyedBy: ChargeStateKeys.self, forKey: .chargeState)

        locked = try vehicleState.decode(Bool.self, forKey: .locked)
        sentryModeEnabled = try vehicleState.decode(Bool.self, forKey: .sentryModeEnabled)
        batteryLevel = try chargeState.decode(Int.self, forKey: .batteryLevel)
        chargePortLatch = try chargeState.decode(ChargePortLatch.self, forKey: .chargePortLatch)
        chargingState = try chargeState.decode(String.self, forKey: .chargingState)
        estimatedRangeMiles = try chargeState.decode(Double.self, forKey: .estimatedRangeMiles)
    }

    init(
        batteryLevel: Int,
        locked: Bool,
        sentryModeEnabled: Bool,
        chargePortLatch: ChargePortLatch,
        chargingState: String,
        estimatedRangeMiles: Double
    ) {
        self.batteryLevel = batteryLevel
        self.locked = locked
        self.sentryModeEnabled = sentryModeEnabled
        self.chargePortLatch = chargePortLatch
        self.chargingState = chargingState
        self.estimatedRangeMiles = estimatedRangeMiles
    }

    /// Mirrors the same nested shape `init(from:)` reads, so this type round-trips
    /// symmetrically — used to persist a snapshot to the widget's shared cache.
    func encode(to encoder: Encoder) throws {
        var root = encoder.container(keyedBy: RootKeys.self)

        var vehicleStateContainer = root.nestedContainer(keyedBy: VehicleStateKeys.self, forKey: .vehicleState)
        try vehicleStateContainer.encode(locked, forKey: .locked)
        try vehicleStateContainer.encode(sentryModeEnabled, forKey: .sentryModeEnabled)

        var chargeStateContainer = root.nestedContainer(keyedBy: ChargeStateKeys.self, forKey: .chargeState)
        try chargeStateContainer.encode(batteryLevel, forKey: .batteryLevel)
        try chargeStateContainer.encode(chargePortLatch, forKey: .chargePortLatch)
        try chargeStateContainer.encode(chargingState, forKey: .chargingState)
        try chargeStateContainer.encode(estimatedRangeMiles, forKey: .estimatedRangeMiles)
    }
}

// MARK: - Errors

enum TeslaApiError: Error, LocalizedError, Equatable {
    case notAuthenticated
    case invalidResponse
    case httpError(statusCode: Int, body: String)
    case decodingFailed(String)
    /// Tesla Fleet API returns HTTP 408 for `vehicle_data`/`command` requests when the
    /// car is asleep — a normal, expected vehicle state (it sleeps to save battery), not
    /// a real failure. Callers should offer a "Wake Vehicle" action rather than treating
    /// this like `.httpError`.
    case vehicleAsleep

    var errorDescription: String? {
        switch self {
        case .notAuthenticated:
            return "No stored session. Sign in first."
        case .invalidResponse:
            return "The server returned an unexpected response."
        case .httpError(let statusCode, let body):
            return "Tesla Fleet API returned HTTP \(statusCode): \(body)"
        case .decodingFailed(let reason):
            return "Could not decode the Tesla Fleet API response: \(reason)"
        case .vehicleAsleep:
            return "The vehicle is asleep."
        }
    }
}
