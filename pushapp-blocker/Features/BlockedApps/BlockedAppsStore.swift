import Combine
import FamilyControls
import Foundation
import ManagedSettings

@MainActor
final class BlockedAppsStore: ObservableObject {
    @Published private(set) var isLocked = true

    @Published var selection: FamilyActivitySelection {
        didSet {
            guard selection != oldValue else { return }
            saveSelection()
            refreshLockState()
        }
    }

    private let defaults: UserDefaults
    private let managedSettings = ManagedSettingsStore()
    private let selectionKey = "blockedAppsSelection"

    private let workoutCompletionKey = "dailyWorkoutCompletedAt"
    private let now: () -> Date
    private let calendar: Calendar

    init(
        defaults: UserDefaults = .standard,
        now: @escaping () -> Date = Date.init,
        calendar: Calendar = .autoupdatingCurrent
    ) {
        self.defaults = defaults
        self.now = now
        self.calendar = calendar

        if let data = defaults.data(forKey: selectionKey),
           let savedSelection = try? JSONDecoder().decode(FamilyActivitySelection.self, from: data) {
            selection = savedSelection
        } else {
            selection = FamilyActivitySelection()
        }

        refreshLockState()
    }

    /// Call only after the daily workout has been successfully completed.
    func completeDailyWorkout() {
        defaults.set(now(), forKey: workoutCompletionKey)
        refreshLockState()
    }

    func refreshLockState() {
        if let completedAt = defaults.object(forKey: workoutCompletionKey) as? Date {
            isLocked = !calendar.isDate(completedAt, inSameDayAs: now())
        } else {
            isLocked = true
        }
        applySelection()
    }

    func requestAuthorization() async throws {
        let authorizationCenter = AuthorizationCenter.shared

        guard authorizationCenter.authorizationStatus != .approved,
              authorizationCenter.authorizationStatus != .approvedWithDataAccess else {
            return
        }

        try await authorizationCenter.requestAuthorization(for: .individual)
    }

    private func saveSelection() {
        guard let data = try? JSONEncoder().encode(selection) else { return }
        defaults.set(data, forKey: selectionKey)
    }

    private func applySelection() {
        guard isLocked else {
            managedSettings.shield.applications = nil
            managedSettings.shield.applicationCategories = nil
            managedSettings.shield.webDomains = nil
            return
        }

        managedSettings.shield.applications = selection.applicationTokens.isEmpty
            ? nil
            : selection.applicationTokens
        managedSettings.shield.applicationCategories = selection.categoryTokens.isEmpty
            ? nil
            : .specific(selection.categoryTokens)
        managedSettings.shield.webDomains = selection.webDomainTokens.isEmpty
            ? nil
            : selection.webDomainTokens
    }
}
