import Foundation
import WidgetKit

/// Outcome of the most recent Settings action (Clear Cache / Log Out), for a brief
/// confirmation or error message in the UI.
enum SettingsActionState: Equatable {
    case idle
    case success(String)
    case failed(String)
}

/// Account management and security controls: current session/vehicle info, the
/// biometric-strictness toggle consumed by `ConfirmationModalViewModel`, cache
/// clearing, and sign-out.
@Observable
@MainActor
final class SettingsViewModel {
    private let authService: any TeslaAuthServicing
    private let settingsStore: any AppSettingsStoring

    let appVersion: String

    private(set) var actionState: SettingsActionState = .idle

    var authState: AuthState { authService.state }

    /// The vehicle currently cached for the widget — Settings reads this rather than
    /// independently fetching from Tesla, consistent with the app's cached-data flow.
    var vehicleVIN: String? { WidgetVehicleStore.load()?.vin }

    /// See `AppSettingsStoring.requireStrictBiometrics` — always required either way,
    /// this only chooses which authentication tier `ConfirmationModalViewModel` uses.
    var requireStrictBiometrics: Bool {
        get { settingsStore.requireStrictBiometrics }
        set { settingsStore.requireStrictBiometrics = newValue }
    }

    init(
        authService: any TeslaAuthServicing,
        settingsStore: any AppSettingsStoring,
        appVersion: String = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "Unknown"
    ) {
        self.authService = authService
        self.settingsStore = settingsStore
        self.appVersion = appVersion
    }

    func clearCacheAndRefreshTimelines() {
        WidgetVehicleStore.clear()
        WidgetCenter.shared.reloadAllTimelines()
        actionState = .success("Cache cleared.")
    }

    func logOut() {
        do {
            try authService.signOut()
            WidgetVehicleStore.clear()
            WidgetCenter.shared.reloadAllTimelines()
            actionState = .success("Signed out.")
        } catch {
            actionState = .failed((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)
        }
    }
}
