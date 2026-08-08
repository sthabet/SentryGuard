import Foundation

/// `AppSettingsStoring` stand-in for SwiftUI Previews and unit tests — an in-memory
/// value, no `UserDefaults` touched.
@MainActor
final class MockAppSettingsStore: AppSettingsStoring {
    var requireStrictBiometrics: Bool

    init(requireStrictBiometrics: Bool = true) {
        self.requireStrictBiometrics = requireStrictBiometrics
    }
}
