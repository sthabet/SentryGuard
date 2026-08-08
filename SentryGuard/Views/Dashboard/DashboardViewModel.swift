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

    private let apiClient: any TeslaApiClienting
    private let securityManager: any SecurityManaging

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

    init(apiClient: any TeslaApiClienting, securityManager: any SecurityManaging) {
        self.apiClient = apiClient
        self.securityManager = securityManager
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
            vehicleState = fetchedState
            loadState = .loaded

            // Widgets are 100% read-only (CLAUDE.md rule 1) and never poll the vehicle
            // themselves (rule 3) — this is the only channel that refreshes their cache.
            WidgetVehicleStore.save(CachedVehicleSnapshot(
                vin: activeVehicle.vin,
                vehicleDisplayName: activeVehicle.displayName,
                vehicleModelName: activeVehicle.modelName,
                vehicleState: fetchedState,
                lastUpdated: Date()
            ))
            WidgetCenter.shared.reloadAllTimelines()
        } catch {
            loadState = Self.mapError(error)
        }
    }

    func refresh() async {
        await loadData()
    }

    func selectCommand(_ command: VehicleCommand) {
        activeCommand = PendingCommand(command: command)
    }

    func dismissActiveCommand() {
        activeCommand = nil
    }

    // MARK: - Private

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
        return .error((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)
    }
}
