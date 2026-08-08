import SwiftUI
import WidgetKit

// MARK: - Entry

struct VehicleStatusEntry: TimelineEntry {
    enum Status: Equatable {
        case unauthenticated
        case offline
        case available(CachedVehicleSnapshot)
    }

    let date: Date
    let status: Status
}

// MARK: - Timeline provider

/// Reads only from the shared App Group cache and the Keychain (for a lightweight
/// "is there a session" check). Per CLAUDE.md rule 3, widgets must never poll the
/// vehicle or call the Tesla Fleet API directly — this provider makes no network calls.
struct VehicleStatusTimelineProvider: TimelineProvider {
    var loadCachedSnapshot: () -> CachedVehicleSnapshot? = { WidgetVehicleStore.load() }
    var isAuthenticated: () -> Bool = {
        (try? KeychainService().readString(for: .accessToken)) != nil
    }

    func placeholder(in context: Context) -> VehicleStatusEntry {
        VehicleStatusEntry(date: Date(), status: .available(.placeholder))
    }

    func getSnapshot(in context: Context, completion: @escaping (VehicleStatusEntry) -> Void) {
        completion(currentEntry())
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<VehicleStatusEntry>) -> Void) {
        let entry = currentEntry()
        completion(Timeline(entries: [entry], policy: .after(Self.nextRefreshDate(after: entry.date))))
    }

    /// Core status-resolution logic, factored out of `getSnapshot`/`getTimeline` so it's
    /// directly unit-testable — `TimelineProviderContext` has no public initializer, so
    /// tests can't call the protocol methods themselves.
    func currentEntry() -> VehicleStatusEntry {
        guard isAuthenticated() else {
            return VehicleStatusEntry(date: Date(), status: .unauthenticated)
        }
        guard let snapshot = loadCachedSnapshot() else {
            return VehicleStatusEntry(date: Date(), status: .offline)
        }
        return VehicleStatusEntry(date: Date(), status: .available(snapshot))
    }

    /// A modest courtesy re-render interval — the app is the real trigger for freshness,
    /// via `WidgetCenter.shared.reloadAllTimelines()` after every successful fetch.
    static func nextRefreshDate(after date: Date) -> Date {
        Calendar.current.date(byAdding: .hour, value: 4, to: date) ?? date.addingTimeInterval(4 * 60 * 60)
    }
}

// MARK: - Widget

struct SentryGuardVehicleWidget: Widget {
    let kind = "SentryGuardWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: VehicleStatusTimelineProvider()) { entry in
            SentryGuardWidgetEntryView(entry: entry)
                .containerBackground(.fill.tertiary, for: .widget)
        }
        .configurationDisplayName("SentryGuard")
        .description("Battery, lock, and Sentry Mode status at a glance.")
        .supportedFamilies([.systemSmall, .systemMedium, .accessoryCircular, .accessoryRectangular])
    }
}

// MARK: - Entry view

struct SentryGuardWidgetEntryView: View {
    @Environment(\.widgetFamily) private var family
    let entry: VehicleStatusEntry

    var body: some View {
        switch entry.status {
        case .unauthenticated:
            AuthRequiredView(family: family)
        case .offline:
            OfflineView(family: family)
        case .available(let snapshot):
            switch family {
            case .systemMedium:
                MediumStatusView(snapshot: snapshot)
            case .accessoryCircular:
                AccessoryCircularStatusView(snapshot: snapshot)
            case .accessoryRectangular:
                AccessoryRectangularStatusView(snapshot: snapshot)
            default:
                SmallStatusView(snapshot: snapshot)
            }
        }
    }
}

// MARK: - Unauthenticated / offline placeholders

private struct AuthRequiredView: View {
    let family: WidgetFamily

    var body: some View {
        switch family {
        case .accessoryCircular:
            Image(systemName: "person.crop.circle.badge.exclamationmark")
                .font(.title3)
                .widgetAccentable()
        case .accessoryRectangular:
            Label("Sign In Required", systemImage: "person.crop.circle.badge.exclamationmark")
                .font(.caption2)
                .widgetAccentable()
        default:
            VStack(spacing: 8) {
                Image(systemName: "person.crop.circle.badge.exclamationmark")
                    .font(.title2)
                    .foregroundStyle(.secondary)
                Text("Open SentryGuard")
                    .font(.footnote.bold())
                if family == .systemMedium {
                    Text("Sign in to see your vehicle's status.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
            }
            .padding()
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

private struct OfflineView: View {
    let family: WidgetFamily

    var body: some View {
        switch family {
        case .accessoryCircular:
            Image(systemName: "wifi.slash")
                .font(.title3)
                .widgetAccentable()
        case .accessoryRectangular:
            Label("Offline", systemImage: "wifi.slash")
                .font(.caption2)
                .widgetAccentable()
        default:
            VStack(spacing: 8) {
                Image(systemName: "wifi.slash")
                    .font(.title2)
                    .foregroundStyle(.secondary)
                Text("Offline")
                    .font(.footnote.bold())
                if family == .systemMedium {
                    Text("Open SentryGuard to refresh your vehicle's status.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
            }
            .padding()
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

// MARK: - Status views

private struct SmallStatusView: View {
    let snapshot: CachedVehicleSnapshot
    private var state: TeslaVehicleState { snapshot.vehicleState }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 4) {
                Text(snapshot.vehicleDisplayName)
                    .font(.caption.bold())
                    .lineLimit(1)
                if snapshot.isStale() {
                    Image(systemName: "clock.badge.exclamationmark")
                        .font(.caption2)
                        .foregroundStyle(.orange)
                }
            }

            Spacer(minLength: 0)

            HStack(spacing: 4) {
                Image(systemName: batteryIcon(for: state))
                    .foregroundStyle(WidgetBatteryColor.color(forState: state))
                Text(batteryText(for: state))
                    .font(.title3.bold())
            }

            HStack(spacing: 12) {
                Image(systemName: state.locked ? "lock.fill" : "lock.open.fill")
                    .foregroundStyle(state.locked ? Color.secondary : Color.orange)
                Image(systemName: state.sentryModeEnabled ? "shield.fill" : "shield.slash")
                    .foregroundStyle(state.sentryModeEnabled ? Color.green : Color.secondary)
            }
            .font(.footnote)
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
    }
}

private struct MediumStatusView: View {
    let snapshot: CachedVehicleSnapshot
    private var state: TeslaVehicleState { snapshot.vehicleState }

    var body: some View {
        HStack(spacing: 20) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 4) {
                    Text(snapshot.vehicleDisplayName)
                        .font(.headline)
                        .lineLimit(1)
                    if snapshot.isStale() {
                        Image(systemName: "clock.badge.exclamationmark")
                            .font(.caption2)
                            .foregroundStyle(.orange)
                    }
                }
                Text(snapshot.vehicleModelName)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(rangeText(for: state))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            VStack(alignment: .trailing, spacing: 8) {
                HStack(spacing: 4) {
                    Image(systemName: batteryIcon(for: state))
                        .foregroundStyle(WidgetBatteryColor.color(forState: state))
                    Text(batteryText(for: state))
                        .font(.title2.bold())
                }
                HStack(spacing: 10) {
                    Label(
                        state.locked ? "Locked" : "Unlocked",
                        systemImage: state.locked ? "lock.fill" : "lock.open.fill"
                    )
                    .foregroundStyle(state.locked ? Color.secondary : Color.orange)
                    Label(
                        state.sentryModeEnabled ? "Sentry" : "No Sentry",
                        systemImage: state.sentryModeEnabled ? "shield.fill" : "shield.slash"
                    )
                    .foregroundStyle(state.sentryModeEnabled ? Color.green : Color.secondary)
                }
                .font(.caption2)
                .labelStyle(.iconOnly)
            }
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
    }
}

// MARK: - Shared formatting helpers

/// Battery percentage is clamped and range is guarded against non-finite/negative
/// values so corrupted or extreme cached telemetry never breaks layout or crashes.
/// Not `private` so `WidgetTimelineProviderTests` can exercise the edge cases directly.
func batteryText(for state: TeslaVehicleState) -> String {
    "\(min(max(state.batteryLevel, 0), 100))%"
}

func batteryIcon(for state: TeslaVehicleState) -> String {
    state.chargingState == "Charging" ? "bolt.fill" : "battery.100"
}

func rangeText(for state: TeslaVehicleState) -> String {
    let range = state.estimatedRangeMiles
    guard range.isFinite, range >= 0 else { return "-- mi" }
    return "\(Int(range)) mi"
}

enum WidgetBatteryColor {
    static func color(forState state: TeslaVehicleState) -> Color {
        guard state.chargingState != "Charging" else { return .blue }
        switch min(max(state.batteryLevel, 0), 100) {
        case ..<10: return .red
        case 10..<20: return .orange
        default: return .green
        }
    }
}

// MARK: - Preview fixtures

extension CachedVehicleSnapshot {
    static let placeholder = CachedVehicleSnapshot(
        vin: "5YJ3E1EA0PF000000",
        vehicleDisplayName: "My Tesla",
        vehicleModelName: "Model 3",
        vehicleState: TeslaVehicleState(
            batteryLevel: 72,
            locked: true,
            sentryModeEnabled: false,
            chargePortLatch: .engaged,
            chargingState: "Disconnected",
            estimatedRangeMiles: 187
        ),
        lastUpdated: Date()
    )

    static let lowBattery = CachedVehicleSnapshot(
        vin: "5YJ3E1EA0PF000000",
        vehicleDisplayName: "My Tesla",
        vehicleModelName: "Model 3",
        vehicleState: TeslaVehicleState(
            batteryLevel: 8,
            locked: true,
            sentryModeEnabled: true,
            chargePortLatch: .disengaged,
            chargingState: "Disconnected",
            estimatedRangeMiles: 22
        ),
        lastUpdated: Date()
    )

    static let charging = CachedVehicleSnapshot(
        vin: "5YJ3E1EA0PF000000",
        vehicleDisplayName: "My Tesla",
        vehicleModelName: "Model Y",
        vehicleState: TeslaVehicleState(
            batteryLevel: 60,
            locked: true,
            sentryModeEnabled: false,
            chargePortLatch: .engaged,
            chargingState: "Charging",
            estimatedRangeMiles: 190
        ),
        lastUpdated: Date()
    )
}

// MARK: - Previews

#Preview("Normal", as: .systemSmall) {
    SentryGuardVehicleWidget()
} timeline: {
    VehicleStatusEntry(date: Date(), status: .available(.placeholder))
}

#Preview("Charging", as: .systemMedium) {
    SentryGuardVehicleWidget()
} timeline: {
    VehicleStatusEntry(date: Date(), status: .available(.charging))
}

#Preview("Low Battery", as: .systemSmall) {
    SentryGuardVehicleWidget()
} timeline: {
    VehicleStatusEntry(date: Date(), status: .available(.lowBattery))
}

#Preview("Offline", as: .systemMedium) {
    SentryGuardVehicleWidget()
} timeline: {
    VehicleStatusEntry(date: Date(), status: .offline)
}

#Preview("Unauthenticated", as: .systemSmall) {
    SentryGuardVehicleWidget()
} timeline: {
    VehicleStatusEntry(date: Date(), status: .unauthenticated)
}
