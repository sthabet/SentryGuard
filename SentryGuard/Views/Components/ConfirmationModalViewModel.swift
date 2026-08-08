import Foundation

/// Lifecycle of a single command confirmation attempt.
enum ConfirmationPhase: Equatable {
    case idle
    /// A Face ID / Touch ID (or system passcode fallback) prompt is in progress.
    case authenticating
    /// Biometric verification passed; the signed command is in flight to the Tesla Fleet API.
    case executing
    case success
    case failed(String)
}

/// UI-facing display text for a pending `VehicleCommand` confirmation.
extension VehicleCommand {
    var confirmationTitle: String {
        switch self {
        case .honkHorn: return "Honk Horn"
        case .flashLights: return "Flash Lights"
        case .lockDoors: return "Lock Doors"
        case .unlockDoors: return "Unlock Vehicle"
        case .setChargeLimit(let percent): return "Set Charge Limit to \(percent)%"
        }
    }

    var confirmationSummary: String {
        switch self {
        case .honkHorn: return "Your vehicle will honk its horn."
        case .flashLights: return "Your vehicle will flash its lights."
        case .lockDoors: return "Your vehicle's doors will lock."
        case .unlockDoors: return "Your vehicle's doors will unlock."
        case .setChargeLimit(let percent): return "Charging will stop once the battery reaches \(percent)%."
        }
    }

    var symbolName: String {
        switch self {
        case .honkHorn: return "megaphone.fill"
        case .flashLights: return "lightbulb.fill"
        case .lockDoors: return "lock.fill"
        case .unlockDoors: return "lock.open.fill"
        case .setChargeLimit: return "bolt.fill"
        }
    }
}

/// Security interlock for vehicle commands (CLAUDE.md rule 2): forces a confirmation +
/// biometric check via `SecurityManaging` before ever calling `TeslaApiClienting.executeCommand`.
///
/// Authentication is always required — the Settings screen's "Require Face ID / Touch ID
/// Only" toggle (`AppSettingsStoring.requireStrictBiometrics`) never disables it, it only
/// chooses which tier is used: strict biometrics only, or biometrics with a system passcode
/// fallback. A user-initiated cancellation never retries under a different tier.
@Observable
@MainActor
final class ConfirmationModalViewModel {
    let command: VehicleCommand
    let vin: String

    private(set) var phase: ConfirmationPhase = .idle

    private let securityManager: any SecurityManaging
    private let apiClient: any TeslaApiClienting
    private let settingsStore: any AppSettingsStoring

    var isBusy: Bool {
        switch phase {
        case .authenticating, .executing: return true
        case .idle, .success, .failed: return false
        }
    }

    init(
        command: VehicleCommand,
        vin: String,
        securityManager: any SecurityManaging,
        apiClient: any TeslaApiClienting,
        settingsStore: any AppSettingsStoring,
        initialPhase: ConfirmationPhase = .idle
    ) {
        self.command = command
        self.vin = vin
        self.securityManager = securityManager
        self.apiClient = apiClient
        self.settingsStore = settingsStore
        self.phase = initialPhase
    }

    func confirm() async {
        guard !isBusy else { return }

        phase = .authenticating
        do {
            try await authenticate()
        } catch {
            phase = .failed(Self.describe(error))
            return
        }

        phase = .executing
        do {
            let accepted = try await apiClient.executeCommand(vin: vin, command: command)
            phase = accepted ? .success : .failed("Tesla declined the command. Please try again.")
        } catch {
            phase = .failed(Self.describe(error))
        }
    }

    func reset() {
        guard !isBusy else { return }
        phase = .idle
    }

    // MARK: - Private

    private func authenticate() async throws {
        let reason = "Confirm: \(command.confirmationTitle)"
        if settingsStore.requireStrictBiometrics {
            try await securityManager.authenticateWithBiometrics(reason: reason)
        } else {
            try await securityManager.authenticateWithBiometricsOrPasscode(reason: reason)
        }
    }

    private static func describe(_ error: Error) -> String {
        (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
    }
}
