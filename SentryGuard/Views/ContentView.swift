import SwiftUI

/// App root: switches between the Tesla sign-in flow and the main tab flow purely
/// based on `authService.isAuthenticated`. Logging out from `SettingsView` calls
/// `TeslaAuthService.signOut()` on this same shared instance, which flips its
/// `state` back to `.signedOut` and — since this view observes it — automatically
/// falls back to `TeslaOAuthView` with an animated transition.
struct ContentView: View {
    let authService: any TeslaAuthServicing
    let apiClient: any TeslaApiClienting
    let securityManager: any SecurityManaging
    let settingsStore: any AppSettingsStoring
    let dashboardViewModel: DashboardViewModel

    var body: some View {
        Group {
            if authService.isAuthenticated {
                MainTabView(
                    dashboardViewModel: dashboardViewModel,
                    apiClient: apiClient,
                    securityManager: securityManager,
                    settingsStore: settingsStore,
                    authService: authService
                )
            } else {
                TeslaOAuthView(authService: authService)
            }
        }
        .animation(.default, value: authService.isAuthenticated)
    }
}

/// Authenticated main flow: vehicle dashboard + account/security settings.
private struct MainTabView: View {
    let dashboardViewModel: DashboardViewModel
    let apiClient: any TeslaApiClienting
    let securityManager: any SecurityManaging
    let settingsStore: any AppSettingsStoring
    let authService: any TeslaAuthServicing

    var body: some View {
        TabView {
            DashboardView(
                viewModel: dashboardViewModel,
                apiClient: apiClient,
                securityManager: securityManager,
                settingsStore: settingsStore
            )
            .tabItem {
                Label("Dashboard", systemImage: "car.side.fill")
            }

            SettingsView(viewModel: SettingsViewModel(
                authService: authService,
                settingsStore: settingsStore
            ))
            .tabItem {
                Label("Settings", systemImage: "gearshape.fill")
            }
        }
    }
}

// MARK: - Previews

@MainActor
private func makePreviewContent(authService: any TeslaAuthServicing) -> ContentView {
    let securityManager = MockSecurityManager()
    let apiClient = MockTeslaApiClient()
    return ContentView(
        authService: authService,
        apiClient: apiClient,
        securityManager: securityManager,
        settingsStore: MockAppSettingsStore(),
        dashboardViewModel: DashboardViewModel(apiClient: apiClient, securityManager: securityManager)
    )
}

#Preview("Unauthenticated") {
    makePreviewContent(authService: MockTeslaAuthService(initialState: .signedOut))
}

#Preview("Authenticated") {
    makePreviewContent(authService: MockTeslaAuthService(initialState: .authenticated))
}
