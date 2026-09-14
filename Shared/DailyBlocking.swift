import DeviceActivity // DeviceActivityName, DeviceActivitySchedule, DeviceActivityCenter
import FamilyControls // FamilyActivitySelection
import Foundation // Date, UserDefaults
import ManagedSettings // ManagedSettingsStore

// Compiled into both the app and its monitor extension.
nonisolated enum DailyBlocking {
    static let selectionKey = "blockedAppsSelection"
    static let workoutCompletionKey = "dailyWorkoutCompletedAt"
    static let developerOverrideKey = "developerLockOverride"

    struct DeveloperOverride: Codable {
        let isLocked: Bool
        let date: Date
    }

    static func developerOverride(in defaults: UserDefaults, now: Date,
                                  calendar: Calendar = .autoupdatingCurrent) -> DeveloperOverride?
    {
        guard let data = defaults.data(forKey: developerOverrideKey),
              let override = try? JSONDecoder().decode(DeveloperOverride.self, from: data),
              calendar.isDate(override.date, inSameDayAs: now) else { return nil }
        return override
    }

    static let activity = DeviceActivityName("dailyWorkoutReset")
    static let storeName = ManagedSettingsStore.Name("dailyWorkout")
    static let defaults: UserDefaults = {
        guard let defaults = UserDefaults(suiteName: AppSettings.appGroup) else {
            preconditionFailure("The app group UserDefaults store is unavailable")
        }
        return defaults
    }()

    /// Returns a device activity schedule configured to repeat every day at midnight.
    ///
    /// The schedule activates at 00:00 and ends at 00:00 daily, making the activity span the entire day.
    /// - Returns: A `DeviceActivitySchedule` set to repeat daily at midnight.
    static var schedule: DeviceActivitySchedule {
        DeviceActivitySchedule(
            intervalStart: DateComponents(hour: 0, minute: 0),
            intervalEnd: DateComponents(hour: 0, minute: 0),
            repeats: true
        )
    }

    /// Starts monitoring device activity for daily workout resets.
    ///
    /// Initializes a `DeviceActivityCenter` singleton and begins monitoring the daily activity schedule.
    /// If monitoring is already active, this method returns early without making duplicate requests.
    /// - Throws: `DeviceActivityError` if the monitoring request fails.
    static func startMonitoring() throws {
        let center: DeviceActivityCenter =
            DeviceActivityCenter() // DeviceActivityCenter is a singleton that manages device activity monitoring.
        guard !center.activities.contains(activity) else { return }
        try center.startMonitoring(activity, during: schedule)
    }

    /// Retrieves the family activity selection from user defaults.
    ///
    /// Attempts to decode a stored `FamilyActivitySelection` from the provided `UserDefaults`.
    /// If no valid data is found or decoding fails, returns an empty selection.
    /// - Parameter defaults: The `UserDefaults` instance to retrieve data from.
    /// - Returns: The decoded `FamilyActivitySelection`, or an empty selection if none exists.
    static func selection(from defaults: UserDefaults) -> FamilyActivitySelection {
        guard let data: Data = defaults.data(forKey: selectionKey),
              let selection: FamilyActivitySelection = try? JSONDecoder().decode(
                  FamilyActivitySelection.self,
                  from: data
              )
        else {
            return FamilyActivitySelection()
        }
        return selection
    }

    /// Determines whether app blocking is currently active.
    ///
    /// Uses today's developer override when present; otherwise checks today's workout completion.
    /// Blocking is active by default when neither grants an unlock.
    /// - Parameters:
    ///   - defaults: The `UserDefaults` instance containing the completion timestamp.
    ///   - now: The date to check against the completion date.
    ///   - calendar: The calendar to use for date comparison (defaults to the autoupdating current calendar).
    /// - Returns: Whether blocking should be active for the provided date.
    static func isLocked(in defaults: UserDefaults, now: Date, calendar: Calendar = .autoupdatingCurrent) -> Bool {
        if let override = developerOverride(in: defaults, now: now, calendar: calendar) {
            return override.isLocked
        }
        guard let completedAt: Date = defaults.object(forKey: workoutCompletionKey) as? Date else { return true }
        return !calendar.isDate(completedAt, inSameDayAs: now)
    }

    /// Applies app blocking restrictions to the managed settings store.
    ///
    /// Configures the shield in the managed settings store to block selected apps, categories, and web domains.
    /// When `isLocked` is `false`, all restrictions are cleared (set to `nil`).
    /// - Parameters:
    ///   - selection: The `FamilyActivitySelection` containing apps, categories, and domains to block.
    ///   - isLocked: Whether blocking should be active; if `false`, removes all restrictions.
    ///   - store: The `ManagedSettingsStore` to apply restrictions to.
    static func apply(selection: FamilyActivitySelection, isLocked: Bool, to store: ManagedSettingsStore) {
        store.shield.applications = isLocked && !selection.applicationTokens.isEmpty
            ? selection.applicationTokens : nil
        store.shield.applicationCategories = isLocked && !selection.categoryTokens.isEmpty
            ? .specific(selection.categoryTokens) : nil
        store.shield.webDomains = isLocked && !selection.webDomainTokens.isEmpty
            ? selection.webDomainTokens : nil
    }
}
