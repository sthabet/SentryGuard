import Foundation

/// Non-sensitive user preferences. `UserDefaults` is the correct store here — CLAUDE.md
/// rule 4 only restricts OAuth tokens, refresh tokens, and private keys to the Keychain;
/// a UI preference like this one carries no secret material.
@MainActor
protocol AppSettingsStoring: AnyObject {
    /// Controls which authentication tier `ConfirmationModalViewModel` uses for every
    /// vehicle command (CLAUDE.md rule 2 — biometric/passcode confirmation is always
    /// required either way; this only chooses how strict that requirement is):
    /// - `true`: Face ID / Touch ID only (`authenticateWithBiometrics`) — no fallback.
    /// - `false`: Face ID / Touch ID with a system passcode fallback allowed
    ///   (`authenticateWithBiometricsOrPasscode`).
    var requireStrictBiometrics: Bool { get set }
}

@Observable
@MainActor
final class AppSettingsStore: AppSettingsStoring {
    private static let requireStrictBiometricsKey = "com.sentryguard.app.settings.requireStrictBiometrics"

    private let defaults: UserDefaults

    var requireStrictBiometrics: Bool {
        didSet { defaults.set(requireStrictBiometrics, forKey: Self.requireStrictBiometricsKey) }
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if defaults.object(forKey: Self.requireStrictBiometricsKey) != nil {
            requireStrictBiometrics = defaults.bool(forKey: Self.requireStrictBiometricsKey)
        } else {
            // Secure by default: strict Face ID / Touch ID until the user opts into the
            // more lenient passcode-fallback tier.
            requireStrictBiometrics = true
        }
    }
}
