import AuthenticationServices
import CryptoKit
import Foundation
import Security
import UIKit

/// Observable authentication lifecycle surfaced to the UI.
enum AuthState: Equatable {
    case signedOut
    case authenticating
    case authenticated
    case error(String)
}

struct AuthTokens: Equatable {
    let accessToken: String
    let refreshToken: String
    let expiresAt: Date
}

enum TeslaAuthError: Error, LocalizedError, Equatable {
    case userCancelled
    case invalidCallbackURL
    case missingAuthorizationCode
    case stateMismatch
    case notAuthenticated
    case tokenExchangeFailed(String)
    case signInAlreadyInProgress

    var errorDescription: String? {
        switch self {
        case .userCancelled:
            return "Sign-in was cancelled."
        case .invalidCallbackURL:
            return "The authorization callback URL was invalid."
        case .missingAuthorizationCode:
            return "Tesla did not return an authorization code."
        case .stateMismatch:
            return "The authorization response failed CSRF validation."
        case .notAuthenticated:
            return "No stored session. Sign in first."
        case .tokenExchangeFailed(let reason):
            return "Token exchange failed: \(reason)"
        case .signInAlreadyInProgress:
            return "A sign-in is already in progress."
        }
    }
}

/// Abstraction over Tesla OAuth so views and tests can depend on a mockable type
/// instead of the concrete `ASWebAuthenticationSession`-backed implementation.
@MainActor
protocol TeslaAuthServicing: AnyObject {
    var state: AuthState { get }
    func signIn() async throws
    func signOut() throws
    func refreshTokensIfNeeded() async throws
    /// The current OAuth access token to attach to Fleet API requests.
    /// Throws `.notAuthenticated` if no session is stored.
    func currentAccessToken() throws -> String
}

extension TeslaAuthServicing {
    /// Convenience used by the app's root view to decide between the auth flow and
    /// the main tab flow — equivalent to `state == .authenticated`.
    var isAuthenticated: Bool { state == .authenticated }
}

/// Handles the Tesla Fleet API OAuth 2.0 authorization-code + PKCE flow via
/// `ASWebAuthenticationSession`, and persists the resulting tokens with `KeychainService`
/// per CLAUDE.md rule 4 (never `UserDefaults`).
@Observable
@MainActor
final class TeslaAuthService: NSObject, TeslaAuthServicing {
    private(set) var state: AuthState

    private let clientID: String
    private let redirectURI: String
    /// Must match a `CFBundleURLSchemes` entry registered in Info.plist, so
    /// `ASWebAuthenticationSession` can intercept the redirect. See the comment on
    /// `beginAuthorizationSession` for why this is a custom scheme rather than the
    /// `redirectURI` host directly.
    private let callbackURLScheme: String
    private let scopes: [String]
    private let keychain: KeychainService
    private let urlSession: URLSession

    private static let authorizeURL = URL(string: "https://auth.tesla.com/oauth2/v3/authorize")!
    private static let tokenURL = URL(string: "https://auth.tesla.com/oauth2/v3/token")!

    /// Created once, for `self`'s entire lifetime — not per sign-in attempt — so there's
    /// no window where it could be absent while `ASWebAuthenticationSession` needs it.
    private let presentationContextProvider = OAuthPresentationContextProvider()

    /// Kept alive for the duration of the interactive session; ARC would otherwise tear
    /// this down before the completion handler fires. Critically, it must also survive a
    /// little past the callback firing — see the deferred cleanup in
    /// `beginAuthorizationSession` for why clearing it synchronously inside the completion
    /// handler crashes on physical devices.
    private var authSession: ASWebAuthenticationSession?

    /// Deliberate self-retain for the duration of `signIn()`. `authSession`/
    /// `presentationContextProvider` above are only as safe as `self` staying alive to
    /// hold them — and `self` here is otherwise only kept alive by whatever the caller
    /// (ultimately a SwiftUI view hierarchy) happens to be holding at the time. On a
    /// physical device, presenting `ASWebAuthenticationSession`'s system UI churns
    /// `scenePhase` (inactive while it has focus, active again after) in a way the
    /// simulator doesn't reproduce identically; rather than trust that every view in that
    /// chain keeps its reference stable across that churn, this makes survival
    /// unconditional for as long as a sign-in is actually in flight. Cleared once
    /// `signIn()` returns or throws, so it never leaks past one attempt.
    private var selfRetainDuringSignIn: TeslaAuthService?

    init(
        clientID: String = "ee13f116-a983-4e30-9bdc-5e83230a1f24",
        redirectURI: String = "https://sthabet.github.io/SentryGuard/callback/",
        callbackURLScheme: String = "com.safwan.sentryguard.app",
        scopes: [String] = [
            "openid", "offline_access", "vehicle_device_data",
            "vehicle_cmds", "vehicle_charging_cmds"
        ],
        keychain: KeychainService = KeychainService(),
        urlSession: URLSession = .shared
    ) {
        self.clientID = clientID
        self.redirectURI = redirectURI
        self.callbackURLScheme = callbackURLScheme
        self.scopes = scopes
        self.keychain = keychain
        self.urlSession = urlSession
        self.state = (try? keychain.readString(for: .accessToken)) != nil ? .authenticated : .signedOut
        super.init()
    }

    func signIn() async throws {
        // Defense in depth: `TeslaOAuthView` disables its button while signing in, but
        // that's a UI-layer guard, not a service-layer invariant. A second concurrent
        // `signIn()` call — a double-tap racing the button's disabled state, or any future
        // caller — would spin up a second `ASWebAuthenticationSession` while the first is
        // still presenting/dismissing, which is exactly the shape of "attempting to load
        // the view of a view controller while it is deallocating" (two overlapping
        // `SFAuthenticationViewController` presentations stepping on each other).
        guard state != .authenticating else {
            throw TeslaAuthError.signInAlreadyInProgress
        }
        state = .authenticating
        selfRetainDuringSignIn = self
        defer { selfRetainDuringSignIn = nil }
        do {
            let pkce = PKCE()
            let csrfState = UUID().uuidString
            let callbackURL = try await beginAuthorizationSession(pkce: pkce, csrfState: csrfState)
            let code = try authorizationCode(from: callbackURL, expectedState: csrfState)
            let tokens = try await exchangeCodeForTokens(code: code, codeVerifier: pkce.verifier)
            try persist(tokens)
            state = .authenticated
        } catch {
            state = .error(error.localizedDescription)
            throw error
        }
    }

    func signOut() throws {
        try keychain.delete(for: .accessToken)
        try keychain.delete(for: .refreshToken)
        state = .signedOut
    }

    func currentAccessToken() throws -> String {
        guard let token = try? keychain.readString(for: .accessToken) else {
            throw TeslaAuthError.notAuthenticated
        }
        return token
    }

    func refreshTokensIfNeeded() async throws {
        guard let refreshToken = try? keychain.readString(for: .refreshToken) else {
            throw TeslaAuthError.notAuthenticated
        }
        do {
            let tokens = try await exchangeRefreshToken(refreshToken)
            try persist(tokens)
            state = .authenticated
        } catch {
            state = .error(error.localizedDescription)
            throw error
        }
    }

    // MARK: - Authorization session

    @MainActor
    private func beginAuthorizationSession(pkce: PKCE, csrfState: String) async throws -> URL {
        guard var components = URLComponents(url: Self.authorizeURL, resolvingAgainstBaseURL: false) else {
            throw TeslaAuthError.invalidCallbackURL
        }
        components.queryItems = [
            URLQueryItem(name: "client_id", value: clientID),
            URLQueryItem(name: "redirect_uri", value: redirectURI),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "scope", value: scopes.joined(separator: " ")),
            URLQueryItem(name: "state", value: csrfState),
            URLQueryItem(name: "code_challenge", value: pkce.challenge),
            URLQueryItem(name: "code_challenge_method", value: "S256")
        ]

        guard let authorizeRequestURL = components.url else {
            throw TeslaAuthError.invalidCallbackURL
        }
        // Tesla's OAuth server requires an https `redirect_uri` it can validate, but this
        // app has no control over the root of that domain (`sthabet.github.io`) to host an
        // `apple-app-site-association` file, so `ASWebAuthenticationSession.Callback.https`
        // (which depends on the Associated Domains entitlement + that file) isn't viable
        // here — it fails closed as `.canceledLogin` before any UI even shows. Instead,
        // `redirectURI` points at a static page (see `docs/callback/index.html`) that
        // JS-redirects to this custom scheme, which `Info.plist`'s `CFBundleURLTypes`
        // registers and this session intercepts directly, no domain ownership required.
        let callback = ASWebAuthenticationSession.Callback.customScheme(callbackURLScheme)

        return try await withCheckedThrowingContinuation { continuation in
            let session = ASWebAuthenticationSession(
                url: authorizeRequestURL,
                callback: callback
            ) { [weak self] callbackURL, error in
                // Do NOT clear `authSession` synchronously here: ASWebAuthenticationSession
                // invokes this completion handler as part of its own internal dismissal of
                // SFAuthenticationViewController. Dropping our last strong reference in the
                // same call frame races with that teardown and crashes on physical devices
                // ("SFAuthenticationViewController ... while it is deallocating") — it
                // doesn't reproduce in the simulator. Deferring by one run-loop turn lets
                // the session finish tearing down itself first.
                Task { @MainActor [weak self] in
                    self?.authSession = nil
                }

                if let error = error as? ASWebAuthenticationSessionError, error.code == .canceledLogin {
                    continuation.resume(throwing: TeslaAuthError.userCancelled)
                    return
                }
                if let error {
                    continuation.resume(throwing: error)
                    return
                }
                guard let callbackURL else {
                    continuation.resume(throwing: TeslaAuthError.invalidCallbackURL)
                    return
                }
                continuation.resume(returning: callbackURL)
            }

            session.presentationContextProvider = presentationContextProvider
            session.prefersEphemeralWebBrowserSession = true
            authSession = session
            session.start()
        }
    }

    private func authorizationCode(from callbackURL: URL, expectedState: String) throws -> String {
        guard let components = URLComponents(url: callbackURL, resolvingAgainstBaseURL: false) else {
            throw TeslaAuthError.invalidCallbackURL
        }
        guard components.queryItems?.first(where: { $0.name == "state" })?.value == expectedState else {
            throw TeslaAuthError.stateMismatch
        }
        guard let code = components.queryItems?.first(where: { $0.name == "code" })?.value else {
            throw TeslaAuthError.missingAuthorizationCode
        }
        return code
    }

    // MARK: - Token exchange

    private func exchangeCodeForTokens(code: String, codeVerifier: String) async throws -> AuthTokens {
        try await requestTokens(parameters: [
            "grant_type": "authorization_code",
            "client_id": clientID,
            "code": code,
            "redirect_uri": redirectURI,
            "code_verifier": codeVerifier
        ])
    }

    private func exchangeRefreshToken(_ refreshToken: String) async throws -> AuthTokens {
        try await requestTokens(parameters: [
            "grant_type": "refresh_token",
            "client_id": clientID,
            "refresh_token": refreshToken
        ])
    }

    private func requestTokens(parameters: [String: String]) async throws -> AuthTokens {
        var request = URLRequest(url: Self.tokenURL)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = parameters
            .map { "\($0.key)=\($0.value.addingPercentEncoding(withAllowedCharacters: .urlQueryValueAllowed) ?? $0.value)" }
            .joined(separator: "&")
            .data(using: .utf8)

        let (data, response) = try await urlSession.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse, (200..<300).contains(httpResponse.statusCode) else {
            let body = String(data: data, encoding: .utf8) ?? "no response body"
            throw TeslaAuthError.tokenExchangeFailed(body)
        }

        let decoded = try JSONDecoder().decode(TokenResponse.self, from: data)
        return AuthTokens(
            accessToken: decoded.accessToken,
            refreshToken: decoded.refreshToken,
            expiresAt: Date().addingTimeInterval(TimeInterval(decoded.expiresIn))
        )
    }

    private func persist(_ tokens: AuthTokens) throws {
        try keychain.save(tokens.accessToken, for: .accessToken)
        try keychain.save(tokens.refreshToken, for: .refreshToken)
    }
}

// MARK: - Presentation context

@MainActor
private final class OAuthPresentationContextProvider: NSObject, ASWebAuthenticationPresentationContextProviding {
    @MainActor
    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        let windows = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows)

        if let keyWindow = windows.first(where: \.isKeyWindow) {
            return keyWindow
        }

        // No window currently reports `isKeyWindow` — can happen if this is queried
        // mid scene-transition. `ASPresentationAnchor` is a plain type alias for
        // `UIWindow`, so a naive `?? ASPresentationAnchor()`/`?? UIWindow()` fallback
        // here fabricates a brand-new, unattached window — itself an invalid
        // presentation anchor, and a plausible contributor to
        // "SFAuthenticationViewController ... while it is deallocating" if
        // `SFAuthenticationViewController` ever gets presented against it. Prefer any
        // real, attached window in an active scene first.
        if let anyAttachedWindow = windows.first {
            return anyAttachedWindow
        }

        // Last resort — should be unreachable, since the user just tapped a button,
        // meaning some window must currently be on screen.
        return ASPresentationAnchor()
    }
}

// MARK: - Token response DTO

private struct TokenResponse: Decodable {
    let accessToken: String
    let refreshToken: String
    let expiresIn: Int

    enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case refreshToken = "refresh_token"
        case expiresIn = "expires_in"
    }
}

// MARK: - PKCE

private struct PKCE {
    let verifier: String
    let challenge: String

    init() {
        var bytes = [UInt8](repeating: 0, count: 32)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        verifier = Data(bytes).base64URLEncodedString()
        let hash = SHA256.hash(data: Data(verifier.utf8))
        challenge = Data(hash).base64URLEncodedString()
    }
}

private extension Data {
    func base64URLEncodedString() -> String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

private extension CharacterSet {
    static let urlQueryValueAllowed: CharacterSet = {
        var allowed = CharacterSet.urlQueryAllowed
        allowed.remove(charactersIn: "+&=")
        return allowed
    }()
}
