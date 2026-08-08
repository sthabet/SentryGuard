import SwiftUI

struct SettingsView: View {
    @State private var viewModel: SettingsViewModel
    @State private var showLogoutConfirmation = false

    init(viewModel: SettingsViewModel) {
        _viewModel = State(initialValue: viewModel)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Vehicle") {
                    LabeledContent("VIN", value: viewModel.vehicleVIN ?? "No vehicle linked")
                }

                Section("Account") {
                    LabeledContent("Session", value: sessionStatusText)
                }

                Section {
                    Toggle("Require Face ID / Touch ID Only", isOn: $viewModel.requireStrictBiometrics)
                } footer: {
                    Text(
                        viewModel.requireStrictBiometrics
                            ? "Every command requires Face ID or Touch ID. If biometrics fail, the command is blocked."
                            : "Every command still requires authentication — if Face ID or Touch ID fails, "
                                + "your device passcode can be used instead."
                    )
                }

                Section {
                    Button("Clear Cache & Refresh Widgets") {
                        viewModel.clearCacheAndRefreshTimelines()
                    }
                } footer: {
                    actionStateFooter
                }

                Section {
                    Button("Log Out", role: .destructive) {
                        showLogoutConfirmation = true
                    }
                }

                Section {
                    LabeledContent("App Version", value: viewModel.appVersion)
                }
            }
            .navigationTitle("Settings")
            .confirmationDialog(
                "Log out of SentryGuard?",
                isPresented: $showLogoutConfirmation,
                titleVisibility: .visible
            ) {
                Button("Log Out", role: .destructive) {
                    viewModel.logOut()
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("This removes your saved Tesla credentials from this device.")
            }
        }
    }

    @ViewBuilder
    private var actionStateFooter: some View {
        switch viewModel.actionState {
        case .idle:
            EmptyView()
        case .success(let message):
            Text(message).foregroundStyle(.secondary)
        case .failed(let message):
            Text(message).foregroundStyle(.red)
        }
    }

    private var sessionStatusText: String {
        switch viewModel.authState {
        case .signedOut: return "Signed Out"
        case .authenticating: return "Signing In…"
        case .authenticated: return "Connected"
        case .error(let message): return "Error: \(message)"
        }
    }
}

// MARK: - Previews

#Preview("Authenticated") {
    SettingsView(viewModel: SettingsViewModel(
        authService: MockTeslaAuthService(initialState: .authenticated),
        settingsStore: MockAppSettingsStore(),
        appVersion: "1.0"
    ))
}

#Preview("Signed Out") {
    SettingsView(viewModel: SettingsViewModel(
        authService: MockTeslaAuthService(initialState: .signedOut),
        settingsStore: MockAppSettingsStore(),
        appVersion: "1.0"
    ))
}

#Preview("Fallback Allowed") {
    SettingsView(viewModel: SettingsViewModel(
        authService: MockTeslaAuthService(initialState: .authenticated),
        settingsStore: MockAppSettingsStore(requireStrictBiometrics: false),
        appVersion: "1.0"
    ))
}
