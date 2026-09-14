import Combine
import FamilyControls
import Foundation
import ManagedSettings
import OSLog

@MainActor
// FamilyControls state is published through the existing SwiftUI StateObject integration.
// swiftlint:disable:next observable_object_legacy
final class BlockedAppsStore: ObservableObject {
    private static let dailyWorkoutRecipeKey = "dailyWorkoutRecipe"
    private static let pendingDailyWorkoutRecipeKey = "pendingDailyWorkoutRecipe"
    private static let dailyProgressKey = "dailyWorkoutProgress"

    @Published private(set) var isLocked = true
    @Published private(set) var hasDeveloperOverride = false
    @Published private(set) var monitoringError: String?
    @Published private(set) var dailyWorkoutRecipe: DailyWorkoutRecipe
    @Published private(set) var pendingDailyWorkoutRecipe: DailyWorkoutRecipe?
    @Published private(set) var dailyProgress: DailyWorkoutProgress
    @Published private(set) var isCafeOpen = false
    @Published var userName: String {
        didSet {
            defaults.set(userName, forKey: AppSettings.userNameKey)
        }
    }

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
        dailyWorkoutRecipe = Self.recipe(from: sharedDefaults)
        pendingDailyWorkoutRecipe = Self.pendingRecipe(from: sharedDefaults)
        dailyProgress = Self.progress(from: sharedDefaults, now: now(), calendar: calendar)
        userName = sharedDefaults.string(forKey: AppSettings.userNameKey) ?? ""

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

    /// The recipe Settings edits. After today's completion, this is a draft for tomorrow.
    var recipeForSettings: DailyWorkoutRecipe {
        pendingDailyWorkoutRecipe ?? dailyWorkoutRecipe
    }

    var nextRecipeExercise: WorkoutExercise? {
        refreshRecipeIfNeeded(at: now())
        refreshProgressIfNeeded()
        return dailyWorkoutRecipe.entries.first {
            $0.isEnabled && completedRepetitions(for: $0.exercise) < $0.target
        }?.exercise
    }

    var isDailyWorkoutRecipeDone: Bool {
        refreshRecipeIfNeeded(at: now())
        refreshProgressIfNeeded()
        let enabledEntries = dailyWorkoutRecipe.entries.filter(\.isEnabled)
        return !enabledEntries.isEmpty && enabledEntries.allSatisfy {
            completedRepetitions(for: $0.exercise) >= $0.target
        }
    }

    func completedRepetitions(for exercise: WorkoutExercise) -> Int {
        dailyProgress.repetitions[exercise, default: 0]
    }

    func setTarget(_ target: Int, for exercise: WorkoutExercise) {
        updateRecipeBeingEdited { recipe in
            guard let index = recipe.entries.firstIndex(where: { $0.exercise == exercise }) else { return }
            recipe.entries[index].target = min(max(target, 1), 100)
        }
    }

    func setExercise(_ exercise: WorkoutExercise, isEnabled: Bool) {
        updateRecipeBeingEdited { recipe in
            guard let index = recipe.entries.firstIndex(where: { $0.exercise == exercise }) else { return }
            if !isEnabled, recipe.entries.filter(\.isEnabled).count == 1 {
                return
            }
            recipe.entries[index].isEnabled = isEnabled
        }
    }

    func moveRecipe(from source: IndexSet, to destination: Int) {
        updateRecipeBeingEdited { recipe in
            let moved = source.map { recipe.entries[$0] }
            var remaining = recipe.entries.enumerated().compactMap { index, entry in
                source.contains(index) ? nil : entry
            }
            let insertionIndex = destination - source.filter { $0 < destination }.count
            remaining.insert(contentsOf: moved, at: insertionIndex)
            recipe.entries = remaining
        }
    }

    /// Saves one deduplicated recognizer event and completes the day once every enabled target is met.
    func recordRecognizedRep(for exercise: WorkoutExercise) throws {
        refreshRecipeIfNeeded(at: now())
        guard !hasCompletedDailyWorkout else { return }
        refreshProgressIfNeeded()
        guard let entry = dailyWorkoutRecipe.entries.first(where: { $0.exercise == exercise && $0.isEnabled })
        else { return }
        let current = completedRepetitions(for: exercise)
        guard current < entry.target else { return }
        dailyProgress.repetitions[exercise] = current + 1
        saveProgress()
        if isDailyWorkoutRecipeDone {
            try completeDailyWorkout()
        }
    }

    func retryDailyWorkoutRecipeCompletion() throws {
        guard isDailyWorkoutRecipeDone, !hasCompletedDailyWorkout else { return }
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
        guard let data = defaults.data(forKey: dailyWorkoutRecipeKey),
              let recipe = decodedRecipe(from: data) else { return .defaultValue }
        return recipe
    }

    private static func pendingRecipe(from defaults: UserDefaults) -> DailyWorkoutRecipe? {
        guard let data = defaults.data(forKey: pendingDailyWorkoutRecipeKey) else { return nil }
        return decodedRecipe(from: data)
    }

    private static func decodedRecipe(from data: Data) -> DailyWorkoutRecipe? {
        guard let recipe = try? JSONDecoder().decode(DailyWorkoutRecipe.self, from: data),
              recipe.entries.map(\.exercise).count == Set(recipe.entries.map(\.exercise)).count,
              recipe.entries.count == WorkoutExercise.allCases.count
        else { return nil }
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
        guard let data = try? JSONEncoder().encode(dailyWorkoutRecipe) else { return }
        defaults.set(data, forKey: Self.dailyWorkoutRecipeKey)
    }

    private func updateRecipeBeingEdited(_ update: (inout DailyWorkoutRecipe) -> Void) {
        refreshRecipeIfNeeded(at: now())
        if hasCompletedDailyWorkout {
            var recipe = pendingDailyWorkoutRecipe ?? dailyWorkoutRecipe
            update(&recipe)
            pendingDailyWorkoutRecipe = recipe
            savePendingRecipe()
        } else {
            update(&dailyWorkoutRecipe)
            saveRecipe()
        }
    }

    private func refreshRecipeIfNeeded(at date: Date) {
        guard let pendingDailyWorkoutRecipe,
              !DailyBlocking.hasCompletedDailyWorkout(in: defaults, now: date, calendar: calendar)
        else { return }
        dailyWorkoutRecipe = pendingDailyWorkoutRecipe
        self.pendingDailyWorkoutRecipe = nil
        saveRecipe()
        defaults.removeObject(forKey: Self.pendingDailyWorkoutRecipeKey)
    }

    private func savePendingRecipe() {
        guard let pendingDailyWorkoutRecipe,
              let data = try? JSONEncoder().encode(pendingDailyWorkoutRecipe) else { return }
        defaults.set(data, forKey: Self.pendingDailyWorkoutRecipeKey)
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

extension BlockedAppsStore {
    /// Saves a rep from an extra workout without changing the completed recipe or lock state.
    func recordExtraWorkoutRep(for exercise: WorkoutExercise) {
        refreshRecipeIfNeeded(at: now())
        guard isDailyWorkoutRecipeDone else { return }
        refreshProgressIfNeeded()
        dailyProgress.repetitions[exercise, default: 0] += 1
        saveProgress()
    }

    func refreshLockState() {
        let startedAt = ContinuousClock.now
        WorkoutDebugLog.lifecycle.info("BlockedAppsStore refreshLockState started")
        if isAuthorized {
            do {
                try ensureDailyReset()
            } catch {
                // ensureDailyReset publishes the error for the screen to display.
            }
        }
        let date = now()
        refreshRecipeIfNeeded(at: date)
        refreshProgressIfNeeded(at: date)
        hasDeveloperOverride = DailyBlocking.developerOverride(in: defaults, now: date, calendar: calendar) != nil
        isLocked = DailyBlocking.isLocked(in: defaults, now: date, calendar: calendar)
        isCafeOpen = DailyBlocking.hasCompletedDailyWorkout(in: defaults, now: date, calendar: calendar) && !isLocked
        DailyBlocking.apply(selection: selection, isLocked: isLocked, to: managedSettings)
        let durationMilliseconds = WorkoutDebugLog.elapsedMilliseconds(since: startedAt)
        WorkoutDebugLog.lifecycle.info(
            "BlockedAppsStore refreshLockState finished; durationMs=\(durationMilliseconds, privacy: .public)"
        )
        WorkoutDebugLog.lifecycle.info(
            "BlockedAppsStore refreshLockState state; locked=\(isLocked, privacy: .public)"
        )
        WorkoutDebugLog.lifecycle.info(
            "BlockedAppsStore refreshLockState finished; cafeOpen=\(isCafeOpen, privacy: .public)"
        )
    }
}
