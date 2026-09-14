import Combine
import FamilyControls
import Foundation
import ManagedSettings

@MainActor
// FamilyControls state is published through the existing SwiftUI StateObject integration.
// swiftlint:disable:next observable_object_legacy
final class BlockedAppsStore: ObservableObject {
    private static let dailyRecipeKey = "dailyWorkoutRecipe"
    private static let dailyProgressKey = "dailyWorkoutProgress"

    @Published private(set) var isLocked = true
    @Published private(set) var hasDeveloperOverride = false
    @Published private(set) var monitoringError: String?
    @Published private(set) var dailyRecipe: DailyWorkoutRecipe
    @Published private(set) var dailyProgress: DailyWorkoutProgress
    @Published private(set) var isCafeOpen = false

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

    private let authorizationCheck: () -> Bool

    enum DeveloperOverrideError: LocalizedError {
        case authorizationRequired

        var errorDescription: String? {
            "Allow Screen Time access in Blocked Apps before changing restrictions."
        }
    }

    init(
        defaults: UserDefaults? = nil,
        now: @escaping () -> Date = Date.init,
        calendar: Calendar = .autoupdatingCurrent,
        startMonitoring: @escaping () throws -> Void = DailyBlocking.startMonitoring,
        authorizationCheck: @escaping () -> Bool = {
            let status = AuthorizationCenter.shared.authorizationStatus
            return status == .approved || status == .approvedWithDataAccess
        }
    ) {
        let sharedDefaults: UserDefaults = defaults ?? DailyBlocking.defaults
        self.defaults = sharedDefaults
        self.now = now
        self.calendar = calendar
        self.startMonitoring = startMonitoring
        self.authorizationCheck = authorizationCheck

        selection = DailyBlocking.selection(from: sharedDefaults)
        dailyRecipe = Self.recipe(from: sharedDefaults)
        dailyProgress = Self.progress(from: sharedDefaults, now: now(), calendar: calendar)

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

    var hasCompletedDailyWorkout: Bool {
        DailyBlocking.hasCompletedDailyWorkout(in: defaults, now: now(), calendar: calendar)
    }

    var nextRecipeExercise: WorkoutExercise? {
        refreshProgressIfNeeded()
        return dailyRecipe.entries.first {
            $0.isEnabled && completedRepetitions(for: $0.exercise) < $0.target
        }?.exercise
    }

    var isDailyRecipeSatisfied: Bool {
        refreshProgressIfNeeded()
        let enabledEntries = dailyRecipe.entries.filter(\.isEnabled)
        return !enabledEntries.isEmpty && enabledEntries.allSatisfy {
            completedRepetitions(for: $0.exercise) >= $0.target
        }
    }

    func completedRepetitions(for exercise: WorkoutExercise) -> Int {
        dailyProgress.repetitions[exercise, default: 0]
    }

    func setTarget(_ target: Int, for exercise: WorkoutExercise) {
        guard !hasCompletedDailyWorkout,
              let index = dailyRecipe.entries.firstIndex(where: { $0.exercise == exercise }) else { return }
        dailyRecipe.entries[index].target = min(max(target, 1), 100)
        saveRecipe()
    }

    func setExercise(_ exercise: WorkoutExercise, isEnabled: Bool) {
        guard !hasCompletedDailyWorkout,
              let index = dailyRecipe.entries.firstIndex(where: { $0.exercise == exercise }) else { return }
        if !isEnabled, dailyRecipe.entries.filter(\.isEnabled).count == 1 {
            return
        }
        dailyRecipe.entries[index].isEnabled = isEnabled
        saveRecipe()
    }

    func moveRecipe(from source: IndexSet, to destination: Int) {
        guard !hasCompletedDailyWorkout else { return }
        let moved = source.map { dailyRecipe.entries[$0] }
        var remaining = dailyRecipe.entries.enumerated().compactMap { index, entry in
            source.contains(index) ? nil : entry
        }
        let insertionIndex = destination - source.filter { $0 < destination }.count
        remaining.insert(contentsOf: moved, at: insertionIndex)
        dailyRecipe.entries = remaining
        saveRecipe()
    }

    /// Saves one deduplicated recognizer event and completes the day once every enabled target is met.
    func recordRecognizedRep(for exercise: WorkoutExercise) throws {
        guard !hasCompletedDailyWorkout else { return }
        refreshProgressIfNeeded()
        guard let entry = dailyRecipe.entries.first(where: { $0.exercise == exercise && $0.isEnabled }) else { return }
        let current = completedRepetitions(for: exercise)
        guard current < entry.target else { return }
        dailyProgress.repetitions[exercise] = current + 1
        saveProgress()
        if isDailyRecipeSatisfied {
            try completeDailyWorkout()
        }
    }

    func retryDailyRecipeCompletion() throws {
        guard isDailyRecipeSatisfied, !hasCompletedDailyWorkout else { return }
        try completeDailyWorkout()
    }

    func setDeveloperLockOverride(isLocked: Bool) throws {
        guard isAuthorized else { throw DeveloperOverrideError.authorizationRequired }
        if !isLocked {
            try ensureDailyReset()
        }
        let override = DailyBlocking.DeveloperOverride(isLocked: isLocked, date: now())
        defaults.set(try JSONEncoder().encode(override), forKey: DailyBlocking.developerOverrideKey)
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
        let date = now()
        refreshProgressIfNeeded(at: date)
        hasDeveloperOverride = DailyBlocking.developerOverride(in: defaults, now: date, calendar: calendar) != nil
        isLocked = DailyBlocking.isLocked(in: defaults, now: date, calendar: calendar)
        isCafeOpen = DailyBlocking.hasCompletedDailyWorkout(in: defaults, now: date, calendar: calendar) && !isLocked
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
        authorizationCheck()
    }

    private static func recipe(from defaults: UserDefaults) -> DailyWorkoutRecipe {
        guard let data = defaults.data(forKey: dailyRecipeKey),
              let recipe = try? JSONDecoder().decode(DailyWorkoutRecipe.self, from: data),
              recipe.entries.map(\.exercise).count == Set(recipe.entries.map(\.exercise)).count,
              recipe.entries.count == WorkoutExercise.allCases.count
        else { return .defaultValue }
        return recipe
    }

    private static func progress(from defaults: UserDefaults, now: Date,
                                 calendar: Calendar) -> DailyWorkoutProgress
    {
        guard let data = defaults.data(forKey: dailyProgressKey),
              let progress = try? JSONDecoder().decode(DailyWorkoutProgress.self, from: data),
              calendar.isDate(progress.date, inSameDayAs: now)
        else {
            return DailyWorkoutProgress(date: now)
        }
        return progress
    }

    private func refreshProgressIfNeeded() {
        refreshProgressIfNeeded(at: now())
    }

    private func refreshProgressIfNeeded(at date: Date) {
        guard !calendar.isDate(dailyProgress.date, inSameDayAs: date) else { return }
        dailyProgress = DailyWorkoutProgress(date: date)
        saveProgress()
    }

    private func saveRecipe() {
        guard let data = try? JSONEncoder().encode(dailyRecipe) else { return }
        defaults.set(data, forKey: Self.dailyRecipeKey)
    }

    private func saveProgress() {
        guard let data = try? JSONEncoder().encode(dailyProgress) else { return }
        defaults.set(data, forKey: Self.dailyProgressKey)
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
