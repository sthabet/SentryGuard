import SwiftUI

struct TeslaOAuthView: View {
    @State private var authService: any TeslaAuthServicing
    @State private var isSigningIn = false

    private let onAuthenticated: () -> Void

    /// `authService` has no default value deliberately — always inject the app's one
    /// shared instance (see `SentryGuardApp`/`ContentView`) rather than letting a call
    /// site accidentally construct a fresh, throwaway `TeslaAuthService()`.
    init(
        authService: any TeslaAuthServicing,
        onAuthenticated: @escaping () -> Void = {}
    ) {
        _authService = State(initialValue: authService)
        self.onAuthenticated = onAuthenticated
    }

    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: "car.side")
                .font(.system(size: 56))
                .foregroundStyle(.tint)

            Text("Connect Your Tesla")
                .font(.title2.bold())

            Text("Sign in with your Tesla account to enable Scarecrow Mode and vehicle alerts.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal)

            statusView

            Button(action: signIn) {
                if isSigningIn {
                    ProgressView()
                        .frame(maxWidth: .infinity)
                } else {
                    Text("Sign in with Tesla")
                        .frame(maxWidth: .infinity)
                }
            }
            .buttonStyle(.borderedProminent)
            .disabled(isSigningIn)
            .padding(.horizontal)
        }
        .padding()
    }

    @ViewBuilder
    private var statusView: some View {
        switch authService.state {
        case .error(let message):
            Label(message, systemImage: "exclamationmark.triangle.fill")
                .font(.footnote)
                .foregroundStyle(.red)
                .padding(.horizontal)
        case .authenticated:
            Label("Connected", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
        default:
            EmptyView()
        }
    }

    private func signIn() {
        isSigningIn = true
        Task {
            defer { isSigningIn = false }
            do {
                try await authService.signIn()
                onAuthenticated()
            } catch {
                // authService.state already reflects the failure; nothing further to do.
            }
        }
    }
}

#Preview("Signed Out") {
    TeslaOAuthView(authService: MockTeslaAuthService(initialState: .signedOut))
}

#Preview("Authenticated") {
    TeslaOAuthView(authService: MockTeslaAuthService(initialState: .authenticated))
}

#Preview("Error") {
    TeslaOAuthView(
        authService: MockTeslaAuthService(
            signInError: .tokenExchangeFailed("invalid_grant"),
            signInDelayNanoseconds: 0
        )
    )
}
