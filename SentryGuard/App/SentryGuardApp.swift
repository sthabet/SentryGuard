import SwiftUI
import WidgetKit

@main
struct SentryGuardApp: App {
    @State private var authService: any TeslaAuthServicing
    @State private var securityManager: any SecurityManaging
    @State private var apiClient: any TeslaApiClienting
    @State private var settingsStore: any AppSettingsStoring
    @State private var dashboardViewModel: DashboardViewModel

    @Environment(\.scenePhase) private var scenePhase

    init() {
        let authService = TeslaAuthService()
        let securityManager = SecurityManager()
        let apiClient = TeslaApiClient(authService: authService)

        _authService = State(initialValue: authService)
        _securityManager = State(initialValue: securityManager)
        _apiClient = State(initialValue: apiClient)
        _settingsStore = State(initialValue: AppSettingsStore())
        _dashboardViewModel = State(initialValue: DashboardViewModel(
            apiClient: apiClient,
            securityManager: securityManager
        ))
    }

    var body: some Scene {
        WindowGroup {
            ContentView(
                authService: authService,
                apiClient: apiClient,
                securityManager: securityManager,
                settingsStore: settingsStore,
                dashboardViewModel: dashboardViewModel
            )
        }
        .onChange(of: scenePhase) { _, newPhase in
            guard newPhase == .active else { return }
            Task {
                await dashboardViewModel.refresh()
                // Belt-and-suspenders: reload even if the refresh above failed, so a
                // staleness indicator (or any other time-relative rendering) still
                // reflects the current moment.
                WidgetCenter.shared.reloadAllTimelines()
            }
        }
    }
}
