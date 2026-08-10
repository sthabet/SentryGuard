import Foundation
import WidgetKit

/// Coarse-grained battery presentation state; the View maps this to a color/icon.
enum BatteryStatusLevel: Equatable {
    case charging
    case normal
    case low
    case critical
}

/// Primary vehicle control center's loading/error lifecycle.
enum DashboardLoadState: Equatable {
    case idle
    case loading
    case loaded
    case offline
    case unauthenticated
    /// Tesla Fleet API returned HTTP 408 — the car is asleep, a normal battery-saving
    /// state, not an error. The dashboard offers a "Wake Vehicle" action instead of the
    /// generic `.error` retry.
    case asleep
    case error(String)
}

/// Coordinates fetching vehicle data from `TeslaApiClienting` and presenting the
/// `ConfirmationModalView` sheet used for every quick-action command.
@Observable
@MainActor
final class DashboardViewModel {
    /// Identifies a quick-action command selected by the user, awaiting confirmation.
    struct PendingCommand: Identifiable, Equatable {
        let id = UUID()
        let command: VehicleCommand
    }

    private(set) var loadState: DashboardLoadState = .idle
    private(set) var vehicle: TeslaVehicle?
    private(set) var vehicleState: TeslaVehicleState?
    private(set) var activeCommand: PendingCommand?
    private(set) var isWaking = false

    private let apiClient: any TeslaApiClienting
    private let securityManager: any SecurityManaging
    /// Overridable only so tests can drive the wake-retry loop without real wall-clock
    /// delays; production always uses the default.
    private let wakePollIntervalNanoseconds: UInt64
    private let maxWakePollAttempts: Int

    var isLoading: Bool { loadState == .loading }

    /// Tapping the lock control should offer whichever action changes the current state.
    var lockToggleCommand: VehicleCommand {
        (vehicleState?.locked ?? true) ? .unlockDoors : .lockDoors
    }

    var batteryStatusLevel: BatteryStatusLevel {
        guard let vehicleState else { return .normal }
        if vehicleState.chargingState == "Charging" {
            return .charging
        }
        switch vehicleState.batteryLevel {
        case ..<15: return .critical
        case 15..<35: return .low
        default: return .normal
        }
    }

    init(
        apiClient: any TeslaApiClienting,
        securityManager: any SecurityManaging,
        wakePollIntervalNanoseconds: UInt64 = 3_000_000_000,
        maxWakePollAttempts: Int = 10
    ) {
        self.apiClient = apiClient
        self.securityManager = securityManager
        self.wakePollIntervalNanoseconds = wakePollIntervalNanoseconds
        self.maxWakePollAttempts = maxWakePollAttempts
    }

    func loadData() async {
        loadState = .loading
        do {
            let vehicles = try await apiClient.fetchVehicles()
            guard let activeVehicle = vehicles.first else {
                vehicle = nil
                vehicleState = nil
                loadState = .loaded
                return
            }
            vehicle = activeVehicle
            let fetchedState = try await apiClient.fetchVehicleState(vin: activeVehicle.vin)
            applyFetchedState(fetchedState, for: activeVehicle)
        } catch {
            loadState = Self.mapError(error)
        }
    }

    func refresh() async {
        await loadData()
    }

    /// Not gated behind Face ID/confirmation like `VehicleCommand`s — waking the car
    /// isn't security-sensitive (it can't unlock, move, or expose the vehicle), it just
    /// lets the dashboard show live data, matching Tesla's own app.
    func wakeVehicle() async {
        guard let activeVehicle = vehicle else { return }
        isWaking = true
        defer { isWaking = false }

        do {
            _ = try await apiClient.wakeVehicle(vin: activeVehicle.vin)
        } catch {
            loadState = Self.mapError(error)
            return
        }

        // Waking isn't instantaneous — poll a bounded number of times, backing off only
        // while the vehicle is still coming online. Right after `wake_up`, Tesla's
        // `vehicle_data` is known to intermittently 408 *or* return a sparse/malformed
        // body before telemetry fully populates — both `.vehicleAsleep` and
        // `.decodingFailed` are treated as "still waking" here, not a hard failure. Any
        // other error ends the loop immediately.
        for attempt in 1...maxWakePollAttempts {
            do {
                let fetchedState = try await apiClient.fetchVehicleState(vin: activeVehicle.vin)
                applyFetchedState(fetchedState, for: activeVehicle)
                return
            } catch TeslaApiError.vehicleAsleep {
                // fall through to retry below
            } catch TeslaApiError.decodingFailed {
                // fall through to retry below
            } catch {
                loadState = Self.mapError(error)
                return
            }

            if attempt < maxWakePollAttempts {
                try? await Task.sleep(nanoseconds: wakePollIntervalNanoseconds)
            } else {
                loadState = .asleep
            }
        }
    }

    func selectCommand(_ command: VehicleCommand) {
        activeCommand = PendingCommand(command: command)
    }

    func dismissActiveCommand() {
        activeCommand = nil
    }

    // MARK: - Private

    private func applyFetchedState(_ state: TeslaVehicleState, for activeVehicle: TeslaVehicle) {
        vehicleState = state
        loadState = .loaded

        // Widgets are 100% read-only (CLAUDE.md rule 1) and never poll the vehicle
        // themselves (rule 3) — this is the only channel that refreshes their cache.
        WidgetVehicleStore.save(CachedVehicleSnapshot(
            vin: activeVehicle.vin,
            vehicleDisplayName: activeVehicle.displayName,
            vehicleModelName: activeVehicle.modelName,
            vehicleState: state,
            lastUpdated: Date()
        ))
        WidgetCenter.shared.reloadAllTimelines()
    }

    private static func mapError(_ error: Error) -> DashboardLoadState {
        if let urlError = error as? URLError, urlError.code == .notConnectedToInternet {
            return .offline
        }
        if let authError = error as? TeslaAuthError, authError == .notAuthenticated {
            return .unauthenticated
        }
        if let apiError = error as? TeslaApiError, apiError == .notAuthenticated {
            return .unauthenticated
        }
        if let apiError = error as? TeslaApiError, apiError == .vehicleAsleep {
            return .asleep
        }
        return .error((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)
    }
}
