import SwiftUI

/// Modal that forces a confirmation + Face ID/Touch ID (or passcode fallback) check before
/// any vehicle command reaches `TeslaApiClienting`. Per CLAUDE.md rule 2, this is the only
/// approved path from a UI action to `executeCommand`.
struct ConfirmationModalView: View {
    @State private var viewModel: ConfirmationModalViewModel
    @Environment(\.dismiss) private var dismiss

    init(viewModel: ConfirmationModalViewModel) {
        _viewModel = State(initialValue: viewModel)
    }

    var body: some View {
        VStack(spacing: 24) {
            Image(systemName: viewModel.command.symbolName)
                .font(.system(size: 44))
                .foregroundStyle(.tint)

            VStack(spacing: 8) {
                Text(viewModel.command.confirmationTitle)
                    .font(.title2.bold())
                Text(viewModel.command.confirmationSummary)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }

            statusView

            actionButtons
        }
        .padding(24)
        .interactiveDismissDisabled(viewModel.isBusy)
    }

    @ViewBuilder
    private var statusView: some View {
        switch viewModel.phase {
        case .idle:
            EmptyView()
        case .authenticating:
            Label("Waiting for Face ID / Touch ID…", systemImage: "faceid")
                .font(.footnote)
                .foregroundStyle(.secondary)
        case .executing:
            HStack(spacing: 8) {
                ProgressView()
                Text("Sending command…")
            }
            .font(.footnote)
            .foregroundStyle(.secondary)
        case .success:
            Label("Command sent", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
        case .failed(let message):
            Label(message, systemImage: "exclamationmark.triangle.fill")
                .font(.footnote)
                .foregroundStyle(.red)
                .multilineTextAlignment(.center)
        }
    }

    @ViewBuilder
    private var actionButtons: some View {
        switch viewModel.phase {
        case .success:
            Button("Done") { dismiss() }
                .buttonStyle(.borderedProminent)

        case .authenticating, .executing:
            EmptyView()

        case .idle, .failed:
            VStack(spacing: 12) {
                Button("Confirm \(viewModel.command.confirmationTitle)") {
                    Task { await viewModel.confirm() }
                }
                .buttonStyle(.borderedProminent)

                Button("Cancel", role: .cancel) { dismiss() }
                    .buttonStyle(.bordered)
            }
        }
    }
}

// MARK: - Previews

#Preview("Idle") {
    ConfirmationModalView(viewModel: ConfirmationModalViewModel(
        command: .unlockDoors,
        vin: "5YJ3E1EA0PF000000",
        securityManager: MockSecurityManager(),
        apiClient: MockTeslaApiClient(),
        settingsStore: MockAppSettingsStore()
    ))
}

#Preview("Authenticating") {
    ConfirmationModalView(viewModel: ConfirmationModalViewModel(
        command: .honkHorn,
        vin: "5YJ3E1EA0PF000000",
        securityManager: MockSecurityManager(),
        apiClient: MockTeslaApiClient(),
        settingsStore: MockAppSettingsStore(),
        initialPhase: .authenticating
    ))
}

#Preview("Executing") {
    ConfirmationModalView(viewModel: ConfirmationModalViewModel(
        command: .flashLights,
        vin: "5YJ3E1EA0PF000000",
        securityManager: MockSecurityManager(),
        apiClient: MockTeslaApiClient(),
        settingsStore: MockAppSettingsStore(),
        initialPhase: .executing
    ))
}

#Preview("Success") {
    ConfirmationModalView(viewModel: ConfirmationModalViewModel(
        command: .lockDoors,
        vin: "5YJ3E1EA0PF000000",
        securityManager: MockSecurityManager(),
        apiClient: MockTeslaApiClient(),
        settingsStore: MockAppSettingsStore(),
        initialPhase: .success
    ))
}

#Preview("Biometric Failure") {
    ConfirmationModalView(viewModel: ConfirmationModalViewModel(
        command: .setChargeLimit(percent: 80),
        vin: "5YJ3E1EA0PF000000",
        securityManager: MockSecurityManager(
            biometricOutcome: .failure(.biometryLockedOut),
            passcodeFallbackOutcome: .failure(.userCancelled)
        ),
        apiClient: MockTeslaApiClient(),
        settingsStore: MockAppSettingsStore(),
        initialPhase: .failed(BiometricAuthError.userCancelled.localizedDescription)
    ))
}
