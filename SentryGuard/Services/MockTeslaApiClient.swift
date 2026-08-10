import Foundation

/// `TeslaApiClienting` stand-in for SwiftUI Previews and unit tests, so vehicle data
/// and command execution can be exercised without hitting the live Tesla Fleet API.
@MainActor
final class MockTeslaApiClient: TeslaApiClienting {
    struct ExecutedCommand: Equatable {
        let vin: String
        let command: VehicleCommand
    }

    var vehicles: [TeslaVehicle]
    var vehicleStates: [String: TeslaVehicleState]
    var commandResult: Bool
    var errorToThrow: Error?
    /// Set > 0 to have `fetchVehicleState` throw `.vehicleAsleep` this many times before
    /// falling through to the normal (possibly still-erroring) response — lets tests
    /// exercise the wake-vehicle retry loop without a real network round trip.
    var asleepUntilWakeCallCount = 0

    private(set) var executedCommands: [ExecutedCommand] = []
    private(set) var wokeVehicles: [String] = []

    init(
        vehicles: [TeslaVehicle] = [.preview],
        vehicleStates: [String: TeslaVehicleState] = [TeslaVehicle.preview.vin: .preview],
        commandResult: Bool = true,
        errorToThrow: Error? = nil
    ) {
        self.vehicles = vehicles
        self.vehicleStates = vehicleStates
        self.commandResult = commandResult
        self.errorToThrow = errorToThrow
    }

    func fetchVehicles() async throws -> [TeslaVehicle] {
        if let errorToThrow {
            throw errorToThrow
        }
        return vehicles
    }

    func fetchVehicleState(vin: String) async throws -> TeslaVehicleState {
        if let errorToThrow {
            throw errorToThrow
        }
        if asleepUntilWakeCallCount > 0 {
            asleepUntilWakeCallCount -= 1
            throw TeslaApiError.vehicleAsleep
        }
        guard let state = vehicleStates[vin] else {
            throw TeslaApiError.httpError(statusCode: 404, body: "Vehicle \(vin) not found.")
        }
        return state
    }

    func executeCommand(vin: String, command: VehicleCommand) async throws -> Bool {
        if let errorToThrow {
            throw errorToThrow
        }
        executedCommands.append(ExecutedCommand(vin: vin, command: command))
        return commandResult
    }

    func wakeVehicle(vin: String) async throws -> TeslaVehicle {
        if let errorToThrow {
            throw errorToThrow
        }
        wokeVehicles.append(vin)
        guard let vehicle = vehicles.first(where: { $0.vin == vin }) else {
            throw TeslaApiError.httpError(statusCode: 404, body: "Vehicle \(vin) not found.")
        }
        return vehicle
    }
}

// MARK: - Preview fixtures

extension TeslaVehicle {
    static let preview = TeslaVehicle(
        id: 1_234_567_890,
        vehicleID: 987_654_321,
        vin: "5YJ3E1EA0PF000000",
        displayName: "SentryGuard Demo",
        state: "online"
    )
}

extension TeslaVehicleState {
    static let preview = TeslaVehicleState(
        batteryLevel: 72,
        locked: true,
        sentryModeEnabled: false,
        chargePortLatch: .engaged,
        chargingState: "Disconnected",
        estimatedRangeMiles: 187
    )
}
