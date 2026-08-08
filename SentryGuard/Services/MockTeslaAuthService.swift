import Foundation

/// `TeslaAuthServicing` stand-in for SwiftUI Previews and unit tests, so auth states
/// can be exercised without hitting Tesla's live OAuth servers.
@Observable
@MainActor
final class MockTeslaAuthService: TeslaAuthServicing {
    private(set) var state: AuthState

    private let signInError: TeslaAuthError?
    private let signInDelayNanoseconds: UInt64

    /// Token handed back by `currentAccessToken()` while `state == .authenticated`.
    var accessToken: String
    /// When set, `signOut()` throws this instead of succeeding.
    var signOutError: TeslaAuthError?

    init(
        initialState: AuthState = .signedOut,
        signInError: TeslaAuthError? = nil,
        signInDelayNanoseconds: UInt64 = 300_000_000,
        accessToken: String = "mock-access-token",
        signOutError: TeslaAuthError? = nil
    ) {
        self.state = initialState
        self.signInError = signInError
        self.signInDelayNanoseconds = signInDelayNanoseconds
        self.accessToken = accessToken
        self.signOutError = signOutError
    }

    func signIn() async throws {
        state = .authenticating
        if signInDelayNanoseconds > 0 {
            try? await Task.sleep(nanoseconds: signInDelayNanoseconds)
        }
        if let signInError {
            state = .error(signInError.localizedDescription)
            throw signInError
        }
        state = .authenticated
    }

    func signOut() throws {
        if let signOutError {
            throw signOutError
        }
        state = .signedOut
    }

    func refreshTokensIfNeeded() async throws {
        guard state == .authenticated else {
            throw TeslaAuthError.notAuthenticated
        }
    }

    func currentAccessToken() throws -> String {
        guard state == .authenticated else {
            throw TeslaAuthError.notAuthenticated
        }
        return accessToken
    }
}
