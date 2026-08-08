import Foundation

/// Snapshot of vehicle telemetry cached to the shared App Group container so the
/// widget extension can render it without ever calling the Tesla Fleet API itself.
///
/// Per CLAUDE.md rule 3 (no vehicle polling) and rule 1 (widgets are 100% read-only,
/// cached data only), this is the ONLY channel through which the widget learns about
/// vehicle state — it never talks to `TeslaApiClienting` directly.
struct CachedVehicleSnapshot: Codable, Equatable {
    let vin: String
    let vehicleDisplayName: String
    let vehicleModelName: String
    let vehicleState: TeslaVehicleState
    let lastUpdated: Date

    static let defaultStalenessThreshold: TimeInterval = 15 * 60

    /// Whether this snapshot is old enough that the widget should flag it as possibly
    /// out of date, rather than presenting it as current. Per Task 3.1, stale data is
    /// still shown (fallback to last-known telemetry beats a blank "Offline" widget) —
    /// this only drives a visual staleness indicator, it never hides the data.
    func isStale(asOf referenceDate: Date = Date(), threshold: TimeInterval = defaultStalenessThreshold) -> Bool {
        referenceDate.timeIntervalSince(lastUpdated) > threshold
    }
}

/// Reads/writes `CachedVehicleSnapshot` to `UserDefaults(suiteName:)` backed by the
/// `group.com.sentryguard.app` App Group, shared between the main app and the widget.
enum WidgetVehicleStore {
    static let appGroupID = "group.com.sentryguard.app"
    /// Not `private` so tests can write raw/corrupted data under the same key.
    static let cacheKey = "com.sentryguard.app.widget.cachedVehicleSnapshot"

    static func save(_ snapshot: CachedVehicleSnapshot) {
        guard let defaults = UserDefaults(suiteName: appGroupID),
              let data = try? JSONEncoder().encode(snapshot) else {
            return
        }
        defaults.set(data, forKey: cacheKey)
    }

    static func load() -> CachedVehicleSnapshot? {
        guard let defaults = UserDefaults(suiteName: appGroupID),
              let data = defaults.data(forKey: cacheKey) else {
            return nil
        }
        return try? JSONDecoder().decode(CachedVehicleSnapshot.self, from: data)
    }

    static func clear() {
        UserDefaults(suiteName: appGroupID)?.removeObject(forKey: cacheKey)
    }
}
