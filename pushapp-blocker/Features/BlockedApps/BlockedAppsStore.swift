import Combine
import FamilyControls
import Foundation
import ManagedSettings

@MainActor
final class BlockedAppsStore: ObservableObject {
    @Published private(set) var isLocked = true
    @Published private(set) var monitoringError: String?

    @Published var selection: FamilyActivitySelection {
        didSet {
            guard selection != oldValue else { return }
            saveSelection()
            refreshLockState()
        }
    }

    private let defaults: UserDefaults
    private let managedSettings = ManagedSettingsStore(named: DailyBlocking.storeName)
    private let now: () -> Date
    private let calendar: Calendar
    private let startMonitoring: () throws -> Void

    init(
        defaults: UserDefaults? = nil,
        now: @escaping () -> Date = Date.init,
        calendar: Calendar = .autoupdatingCurrent,
        startMonitoring: @escaping () throws -> Void = DailyBlocking.startMonitoring
    ) {
        let sharedDefaults: UserDefaults = defaults ?? DailyBlocking.defaults
        self.defaults = sharedDefaults
        self.now = now
        self.calendar = calendar
        self.startMonitoring = startMonitoring

        selection = DailyBlocking.selection(from: sharedDefaults)

        refreshLockState()
        if defaults == nil {
            // Older builds used the app's unnamed store. Remove those shields.
            DailyBlocking.apply(selection: selection, isLocked: false, to: ManagedSettingsStore())
        }
    }

    /// Call only after the daily workout has been successfully completed.
    func completeDailyWorkout() throws {
        // Do not grant an unlock unless iOS has accepted the repeating reset schedule.
        try ensureDailyReset()
        defaults.set(now(), forKey: DailyBlocking.workoutCompletionKey)
        refreshLockState()
    }

    func refreshLockState() {
        if isAuthorized {
            do {
                try ensureDailyReset()
            } catch {
                // ensureDailyReset publishes the error for the screen to display.
            }
        }
        isLocked = DailyBlocking.isLocked(in: defaults, now: now(), calendar: calendar)
        DailyBlocking.apply(selection: selection, isLocked: isLocked, to: managedSettings)
    }

    func requestAuthorization() async throws {
        if !isAuthorized {
            try await AuthorizationCenter.shared.requestAuthorization(for: .individual)
        }
        try ensureDailyReset()
        refreshLockState()
    }

    private func saveSelection() {
        guard let data = try? JSONEncoder().encode(selection) else { return }
        defaults.set(data, forKey: DailyBlocking.selectionKey)
    }

    private var isAuthorized: Bool {
        let status: AuthorizationStatus = AuthorizationCenter.shared.authorizationStatus
        return status == .approved || status == .approvedWithDataAccess
    }

    private func ensureDailyReset() throws {
        do {
            try startMonitoring()
            monitoringError = nil
        } catch {
            monitoringError = error.localizedDescription
            throw error
        }
    }
}
