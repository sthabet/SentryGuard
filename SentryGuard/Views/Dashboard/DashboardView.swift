import SwiftUI

/// Primary vehicle control center: status header, quick-action grid, and the
/// `ConfirmationModalView` security interlock (CLAUDE.md rule 2) for every command.
struct DashboardView: View {
    @State private var viewModel: DashboardViewModel
    private let securityManager: any SecurityManaging
    private let apiClient: any TeslaApiClienting
    private let settingsStore: any AppSettingsStoring

    /// Takes a pre-built `viewModel` (rather than constructing one internally) so the
    /// app root can own a single shared instance and drive refreshes into it — e.g. on
    /// `scenePhase == .active` — while this exact same instance stays on screen.
    init(
        viewModel: DashboardViewModel,
        apiClient: any TeslaApiClienting,
        securityManager: any SecurityManaging,
        settingsStore: any AppSettingsStoring = AppSettingsStore()
    ) {
        _viewModel = State(initialValue: viewModel)
        self.apiClient = apiClient
        self.securityManager = securityManager
        self.settingsStore = settingsStore
    }

    var body: some View {
        NavigationStack {
            content
                .navigationTitle("SentryGuard")
                .task {
                    if viewModel.loadState == .idle {
                        await viewModel.loadData()
                    }
                }
                .sheet(item: activeCommandBinding) { pending in
                    ConfirmationModalView(viewModel: ConfirmationModalViewModel(
                        command: pending.command,
                        vin: viewModel.vehicle?.vin ?? "",
                        securityManager: securityManager,
                        apiClient: apiClient,
                        settingsStore: settingsStore
                    ))
                }
        }
    }

    private var activeCommandBinding: Binding<DashboardViewModel.PendingCommand?> {
        Binding(
            get: { viewModel.activeCommand },
            set: { newValue in
                guard newValue == nil else { return }
                viewModel.dismissActiveCommand()
                Task { await viewModel.refresh() }
            }
        )
    }

    @ViewBuilder
    private var content: some View {
        switch viewModel.loadState {
        case .idle, .loading:
            if viewModel.vehicle == nil {
                ProgressView("Loading vehicle…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                dashboardBody
            }
        case .loaded:
            dashboardBody
        case .offline:
            StatusMessageView(
                systemImage: "wifi.slash",
                title: "You're Offline",
                message: "Connect to the internet to see the latest vehicle status.",
                retryAction: { Task { await viewModel.refresh() } }
            )
        case .unauthenticated:
            StatusMessageView(
                systemImage: "person.crop.circle.badge.exclamationmark",
                title: "Sign-In Required",
                message: "Your Tesla session has expired. Please sign in again.",
                retryAction: { Task { await viewModel.refresh() } }
            )
        case .error(let message):
            StatusMessageView(
                systemImage: "exclamationmark.triangle.fill",
                title: "Something Went Wrong",
                message: message,
                retryAction: { Task { await viewModel.refresh() } }
            )
        }
    }

    private var dashboardBody: some View {
        ScrollView {
            VStack(spacing: 24) {
                header
                controlGrid
            }
            .padding()
        }
        .refreshable { await viewModel.refresh() }
    }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 2) {
                Text(viewModel.vehicle?.displayName ?? "My Tesla")
                    .font(.title2.bold())
                Text(viewModel.vehicle?.modelName ?? "Tesla Vehicle")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            batteryBar

            HStack {
                Label(rangeText, systemImage: "road.lanes")
                Spacer()
                sentryModeIndicator
            }
            .font(.footnote)
            .foregroundStyle(.secondary)
        }
        .padding()
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 20))
    }

    private var batteryBar: some View {
        let level = viewModel.batteryStatusLevel
        let percent = viewModel.vehicleState?.batteryLevel ?? 0

        return VStack(alignment: .leading, spacing: 6) {
            HStack {
                Image(systemName: level == .charging ? "bolt.fill" : "battery.100")
                    .foregroundStyle(batteryColor(for: level))
                Text("\(percent)%")
                    .font(.headline)
                Spacer()
                if level == .charging {
                    Text("Charging")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.gray.opacity(0.2))
                    Capsule()
                        .fill(batteryColor(for: level))
                        .frame(width: geometry.size.width * CGFloat(min(max(percent, 0), 100)) / 100)
                }
            }
            .frame(height: 10)
        }
    }

    private var sentryModeIndicator: some View {
        let isActive = viewModel.vehicleState?.sentryModeEnabled == true
        return Label(
            isActive ? "Sentry Active" : "Sentry Off",
            systemImage: isActive ? "shield.fill" : "shield.slash"
        )
        .foregroundStyle(isActive ? .green : .secondary)
    }

    private var rangeText: String {
        guard let range = viewModel.vehicleState?.estimatedRangeMiles else { return "-- mi" }
        return "\(Int(range)) mi"
    }

    private func batteryColor(for level: BatteryStatusLevel) -> Color {
        switch level {
        case .charging: return .blue
        case .normal: return .green
        case .low: return .orange
        case .critical: return .red
        }
    }

    // MARK: - Control grid

    private var controlGrid: some View {
        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 16) {
            ControlButton(
                title: viewModel.vehicleState?.locked == false ? "Lock" : "Unlock",
                systemImage: viewModel.vehicleState?.locked == false ? "lock.fill" : "lock.open.fill",
                isDisabled: viewModel.vehicle == nil
            ) {
                viewModel.selectCommand(viewModel.lockToggleCommand)
            }
            ControlButton(title: "Honk", systemImage: "megaphone.fill", isDisabled: viewModel.vehicle == nil) {
                viewModel.selectCommand(.honkHorn)
            }
            ControlButton(title: "Flash", systemImage: "lightbulb.fill", isDisabled: viewModel.vehicle == nil) {
                viewModel.selectCommand(.flashLights)
            }
            ControlButton(
                title: "Charge Limit",
                systemImage: "bolt.fill",
                isDisabled: viewModel.vehicle == nil
            ) {
                // Matches the PRD's default Home charge limit (80%).
                viewModel.selectCommand(.setChargeLimit(percent: 80))
            }
        }
    }
}

// MARK: - Previews

@MainActor
private func makePreviewDashboard(apiClient: any TeslaApiClienting) -> DashboardView {
    let securityManager = MockSecurityManager()
    return DashboardView(
        viewModel: DashboardViewModel(apiClient: apiClient, securityManager: securityManager),
        apiClient: apiClient,
        securityManager: securityManager,
        settingsStore: MockAppSettingsStore()
    )
}

#Preview("Normal") {
    makePreviewDashboard(apiClient: MockTeslaApiClient())
}

#Preview("Low Battery") {
    makePreviewDashboard(apiClient: MockTeslaApiClient(vehicleStates: [
        TeslaVehicle.preview.vin: TeslaVehicleState(
            batteryLevel: 12,
            locked: true,
            sentryModeEnabled: true,
            chargePortLatch: .disengaged,
            chargingState: "Disconnected",
            estimatedRangeMiles: 34
        )
    ]))
}

#Preview("Charging") {
    makePreviewDashboard(apiClient: MockTeslaApiClient(vehicleStates: [
        TeslaVehicle.preview.vin: TeslaVehicleState(
            batteryLevel: 65,
            locked: true,
            sentryModeEnabled: false,
            chargePortLatch: .engaged,
            chargingState: "Charging",
            estimatedRangeMiles: 210
        )
    ]))
}

#Preview("Offline") {
    makePreviewDashboard(apiClient: MockTeslaApiClient(errorToThrow: URLError(.notConnectedToInternet)))
}

#Preview("Unauthenticated") {
    makePreviewDashboard(apiClient: MockTeslaApiClient(errorToThrow: TeslaAuthError.notAuthenticated))
}
