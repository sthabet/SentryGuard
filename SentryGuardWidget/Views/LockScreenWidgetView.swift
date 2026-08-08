import SwiftUI
import WidgetKit

// MARK: - Lock Screen accessory views
//
// Accessory families render in the system's vibrant/monochrome Lock Screen style —
// explicit colors are ignored there, so these intentionally skip `WidgetBatteryColor`
// and use `.widgetAccentable()` to mark which elements should pick up the user's tint.

struct AccessoryCircularStatusView: View {
    let snapshot: CachedVehicleSnapshot
    private var state: TeslaVehicleState { snapshot.vehicleState }

    var body: some View {
        Gauge(
            value: Double(min(max(state.batteryLevel, 0), 100)),
            in: 0...100
        ) {
            Image(systemName: state.locked ? "lock.fill" : "lock.open.fill")
        } currentValueLabel: {
            Text(batteryText(for: state))
        }
        .gaugeStyle(.accessoryCircularCapacity)
        .widgetAccentable()
    }
}

struct AccessoryRectangularStatusView: View {
    let snapshot: CachedVehicleSnapshot
    private var state: TeslaVehicleState { snapshot.vehicleState }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(snapshot.vehicleDisplayName)
                .font(.headline)
                .lineLimit(1)
            HStack(spacing: 8) {
                Label(batteryText(for: state), systemImage: batteryIcon(for: state))
                Image(systemName: state.locked ? "lock.fill" : "lock.open.fill")
                Image(systemName: state.sentryModeEnabled ? "shield.fill" : "shield.slash")
            }
            .font(.caption)
        }
        .widgetAccentable()
    }
}

// MARK: - Previews

#Preview("Lock Screen Circular", as: .accessoryCircular) {
    SentryGuardVehicleWidget()
} timeline: {
    VehicleStatusEntry(date: Date(), status: .available(.placeholder))
}

#Preview("Lock Screen Circular - Low Battery", as: .accessoryCircular) {
    SentryGuardVehicleWidget()
} timeline: {
    VehicleStatusEntry(date: Date(), status: .available(.lowBattery))
}

#Preview("Lock Screen Rectangular", as: .accessoryRectangular) {
    SentryGuardVehicleWidget()
} timeline: {
    VehicleStatusEntry(date: Date(), status: .available(.placeholder))
}

#Preview("Lock Screen Rectangular - Unauthenticated", as: .accessoryRectangular) {
    SentryGuardVehicleWidget()
} timeline: {
    VehicleStatusEntry(date: Date(), status: .unauthenticated)
}
