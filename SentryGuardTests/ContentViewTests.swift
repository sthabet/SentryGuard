import XCTest
@testable import SentryGuard

/// `ContentView` itself is a thin switcher with no logic of its own — its whole root
/// navigation decision is `if authService.isAuthenticated { MainTabView } else { TeslaOAuthView }`.
/// This project has no snapshot/view-hosting test library, so rendering the SwiftUI
/// hierarchy directly isn't practical here. These tests instead exercise the exact state
/// machine that decision depends on — `TeslaAuthServicing.isAuthenticated` through real
/// sign-in/sign-out transitions — which is what actually drives ContentView's behavior.
@MainActor
final class ContentViewTests: XCTestCase {
    // MARK: - isAuthenticated reflects every AuthState case

    func test_isAuthenticated_whenSignedOut_isFalse() {
        let auth = MockTeslaAuthService(initialState: .signedOut)
        XCTAssertFalse(auth.isAuthenticated)
    }

    func test_isAuthenticated_whenAuthenticating_isFalse() {
        let auth = MockTeslaAuthService(initialState: .authenticating)
        XCTAssertFalse(auth.isAuthenticated)
    }

    func test_isAuthenticated_whenAuthenticated_isTrue() {
        let auth = MockTeslaAuthService(initialState: .authenticated)
        XCTAssertTrue(auth.isAuthenticated)
    }

    func test_isAuthenticated_whenError_isFalse() {
        let auth = MockTeslaAuthService(initialState: .error("network unreachable"))
        XCTAssertFalse(auth.isAuthenticated)
    }

    // MARK: - Root transition: unauthenticated -> authenticated -> logged out

    func test_rootTransition_startsOnAuthViewBranch() {
        let auth = MockTeslaAuthService(initialState: .signedOut)

        XCTAssertFalse(auth.isAuthenticated, "ContentView should start on the TeslaOAuthView branch")
    }

    func test_rootTransition_signInSuccess_switchesToAuthenticatedBranch() async throws {
        let auth = MockTeslaAuthService(initialState: .signedOut, signInDelayNanoseconds: 0)
        XCTAssertFalse(auth.isAuthenticated)

        try await auth.signIn()

        XCTAssertTrue(auth.isAuthenticated, "ContentView should now switch to the MainTabView branch")
    }

    func test_rootTransition_signInFailure_staysOnAuthViewBranch() async {
        let auth = MockTeslaAuthService(
            initialState: .signedOut,
            signInError: .tokenExchangeFailed("invalid_grant"),
            signInDelayNanoseconds: 0
        )

        do {
            try await auth.signIn()
            XCTFail("Expected signIn to throw")
        } catch {
            // expected
        }

        XCTAssertFalse(auth.isAuthenticated, "A failed sign-in must keep ContentView on the TeslaOAuthView branch")
    }

    func test_rootTransition_logOutFromSettings_fallsBackToAuthViewBranch() {
        let auth = MockTeslaAuthService(initialState: .authenticated)
        XCTAssertTrue(auth.isAuthenticated)

        let settingsViewModel = SettingsViewModel(
            authService: auth, settingsStore: MockAppSettingsStore(), appVersion: "1.0"
        )
        settingsViewModel.logOut()

        XCTAssertFalse(auth.isAuthenticated, "Logging out from SettingsView must fall ContentView back to TeslaOAuthView")
    }

    func test_rootTransition_fullCycle_unauthenticatedToAuthenticatedToLoggedOut() async throws {
        let auth = MockTeslaAuthService(initialState: .signedOut, signInDelayNanoseconds: 0)
        XCTAssertFalse(auth.isAuthenticated, "1. Starts unauthenticated")

        try await auth.signIn()
        XCTAssertTrue(auth.isAuthenticated, "2. Signs in successfully")

        let settingsViewModel = SettingsViewModel(
            authService: auth, settingsStore: MockAppSettingsStore(), appVersion: "1.0"
        )
        settingsViewModel.logOut()
        XCTAssertFalse(auth.isAuthenticated, "3. Logs out and falls back to unauthenticated")
    }

    func test_rootTransition_logOut_whenSignOutFails_remainsAuthenticated() {
        // If the underlying sign-out itself fails, ContentView should NOT silently show
        // the auth screen over a still-valid session.
        let auth = MockTeslaAuthService(initialState: .authenticated, signOutError: .notAuthenticated)
        let settingsViewModel = SettingsViewModel(
            authService: auth, settingsStore: MockAppSettingsStore(), appVersion: "1.0"
        )

        settingsViewModel.logOut()

        XCTAssertTrue(auth.isAuthenticated, "A failed sign-out must not flip ContentView to the AuthView branch")
    }

    // MARK: - Real TeslaAuthService + Keychain integration

    func test_rootTransition_withRealTeslaAuthService_reflectsStoredKeychainSession() throws {
        let keychain = KeychainService(service: "com.sentryguard.app.tests.contentview.\(UUID().uuidString)")

        let freshInstall = TeslaAuthService(keychain: keychain, urlSession: .shared)
        XCTAssertFalse(freshInstall.isAuthenticated, "No stored token -> ContentView shows TeslaOAuthView")

        try keychain.save("access-token", for: .accessToken)
        let returningSession = TeslaAuthService(keychain: keychain, urlSession: .shared)
        XCTAssertTrue(returningSession.isAuthenticated, "Stored token -> ContentView shows MainTabView")

        try returningSession.signOut()
        XCTAssertFalse(returningSession.isAuthenticated, "signOut() -> ContentView falls back to TeslaOAuthView")
    }
}
