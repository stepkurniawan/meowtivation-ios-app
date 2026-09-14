//
//  meowtivationTests.swift
//  meowtivationTests
//
//  Created by stephen on 01.09.26.
//

import FamilyControls
import Foundation
@testable import pushapp_blocker
import Testing

struct MeowtivationTests {
    @MainActor
    @Test func monitorReadsSavedCompletionWithoutOpeningTheApp() throws {
        let suiteName = "DailyLockTests.\(UUID().uuidString)"
        let appDefaults = try #require(UserDefaults(suiteName: suiteName))
        defer { appDefaults.removePersistentDomain(forName: suiteName) }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(secondsFromGMT: 0))
        let dayOne = try #require(calendar.date(from: DateComponents(year: 2026, month: 9, day: 10, hour: 12)))
        appDefaults.set(dayOne, forKey: DailyBlocking.workoutCompletionKey)
        let selection = FamilyActivitySelection(includeEntireCategory: true)
        appDefaults.set(try JSONEncoder().encode(selection), forKey: DailyBlocking.selectionKey)

        // The monitor opens the shared data independently, with no app store refresh.
        let monitorDefaults = try #require(UserDefaults(suiteName: suiteName))
        #expect(DailyBlocking.selection(from: monitorDefaults) == selection)
        #expect(!DailyBlocking.isLocked(in: monitorDefaults, now: dayOne, calendar: calendar))
        let dayTwo = dayOne.addingTimeInterval(24 * 60 * 60)
        #expect(DailyBlocking.isLocked(in: monitorDefaults, now: dayTwo, calendar: calendar))
        #expect(DailyBlocking.isLocked(
            in: monitorDefaults,
            now: dayOne.addingTimeInterval(7 * 24 * 60 * 60),
            calendar: calendar
        ))

        // A callback delivered after today's workout must keep today's unlock.
        appDefaults.set(dayTwo, forKey: DailyBlocking.workoutCompletionKey)
        #expect(!DailyBlocking.isLocked(in: monitorDefaults, now: dayTwo.addingTimeInterval(60), calendar: calendar))
    }

    @MainActor
    @Test func failedMonitoringDoesNotUnlockApps() throws {
        enum ScheduleError: Error { case unavailable }
        let suiteName = "DailyLockTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        var shouldFail = true
        let store = BlockedAppsStore(defaults: defaults, startMonitoring: {
            if shouldFail {
                throw ScheduleError.unavailable
            }
        })

        #expect(throws: ScheduleError.self) { try store.completeDailyWorkout() }
        #expect(store.isLocked)
        #expect(defaults.object(forKey: DailyBlocking.workoutCompletionKey) == nil)
        #expect(store.monitoringError != nil)

        shouldFail = false
        try store.completeDailyWorkout()
        #expect(!store.isLocked)
        #expect(store.monitoringError == nil)
    }

    @MainActor
    @Test func dailyLockPersistsAndResetsAtLocalMidnight() throws {
        let suiteName = "DailyLockTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(identifier: "Europe/Berlin"))
        var now = try #require(calendar.date(from: DateComponents(year: 2026, month: 9, day: 10, hour: 23, minute: 59)))
        let store = BlockedAppsStore(defaults: defaults, now: { now }, calendar: calendar, startMonitoring: {})

        #expect(store.isLocked)
        try store.completeDailyWorkout()
        #expect(!store.isLocked)

        let reopenedStore = BlockedAppsStore(defaults: defaults, now: { now }, calendar: calendar, startMonitoring: {})
        #expect(!reopenedStore.isLocked)

        now = now.addingTimeInterval(60)
        reopenedStore.refreshLockState()
        #expect(reopenedStore.isLocked)
        #expect(BlockedAppsStore(defaults: defaults, now: { now }, calendar: calendar, startMonitoring: {}).isLocked)

        try reopenedStore.completeDailyWorkout()
        #expect(!reopenedStore.isLocked)
    }

    @MainActor
    @Test(arguments: [3, 10])
    func unlockUsesCalendarDayAcrossDaylightSavingChanges(month: Int) throws {
        let suiteName = "DailyLockTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(identifier: "Europe/Berlin"))
        let day = month == 3 ? 29 : 25
        var now = try #require(calendar.date(from: DateComponents(year: 2026, month: month, day: day)))
        let store = BlockedAppsStore(defaults: defaults, now: { now }, calendar: calendar, startMonitoring: {})
        try store.completeDailyWorkout()

        now = try #require(calendar.date(from: DateComponents(
            year: 2026,
            month: month,
            day: day,
            hour: 23,
            minute: 59
        )))
        store.refreshLockState()
        #expect(!store.isLocked)

        now = now.addingTimeInterval(60)
        store.refreshLockState()
        #expect(store.isLocked)
    }

    @MainActor
    @Test func developerOverridePersistsAndExpiresWithoutChangingWorkout() throws {
        let suite = "DeveloperOverrideTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(identifier: "Europe/Berlin"))
        var now = try #require(calendar.date(from: DateComponents(year: 2026, month: 9, day: 10, hour: 23, minute: 59)))
        let completedAt = now
        defaults.set(completedAt, forKey: DailyBlocking.workoutCompletionKey)
        let store = BlockedAppsStore(defaults: defaults, now: { now }, calendar: calendar,
                                     startMonitoring: {}, authorizationCheck: { true })
        let selectionData = try JSONEncoder().encode(FamilyActivitySelection(includeEntireCategory: true))
        defaults.set(selectionData, forKey: DailyBlocking.selectionKey)
        try store.setDeveloperLockOverride(isLocked: true)
        #expect(store.isLocked && store.hasDeveloperOverride)
        let independentDefaults = try #require(UserDefaults(suiteName: suite))
        #expect(DailyBlocking.isLocked(in: independentDefaults, now: now, calendar: calendar))
        let reopened = BlockedAppsStore(defaults: independentDefaults, now: { now }, calendar: calendar,
                                        startMonitoring: {}, authorizationCheck: { true })
        #expect(reopened.isLocked && reopened.hasDeveloperOverride)
        try store.setDeveloperLockOverride(isLocked: false)
        #expect(!DailyBlocking.isLocked(in: independentDefaults, now: now, calendar: calendar))
        #expect(defaults.object(forKey: DailyBlocking.workoutCompletionKey) as? Date == completedAt)
        #expect(defaults.data(forKey: DailyBlocking.selectionKey) == selectionData)
        now = now.addingTimeInterval(60)
        reopened.refreshLockState()
        #expect(reopened.isLocked && !reopened.hasDeveloperOverride)
        #expect(DailyBlocking.isLocked(in: independentDefaults, now: now, calendar: calendar))
        try reopened.completeDailyWorkout()
        #expect(!reopened.isLocked)
        try reopened.setDeveloperLockOverride(isLocked: true)
        #expect(reopened.isLocked)
        now = now.addingTimeInterval(24 * 60 * 60)
        defaults.set(now, forKey: DailyBlocking.workoutCompletionKey)
        reopened.refreshLockState()
        #expect(!reopened.isLocked && !reopened.hasDeveloperOverride)
    }

    @MainActor
    @Test func developerCommandsHandleAuthorizationAndScheduleFailures() throws {
        enum ScheduleError: Error { case unavailable }
        let suite = "DeveloperOverrideTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        var authorized = true
        var failSchedule = false
        let store = BlockedAppsStore(defaults: defaults, startMonitoring: {
            if failSchedule {
                throw ScheduleError.unavailable
            }
        }, authorizationCheck: { authorized })
        try store.setDeveloperLockOverride(isLocked: false)
        failSchedule = true
        try store.setDeveloperLockOverride(isLocked: true)
        #expect(store.isLocked && store.monitoringError != nil)
        let previous = defaults.data(forKey: DailyBlocking.developerOverrideKey)
        #expect(throws: ScheduleError.self) { try store.setDeveloperLockOverride(isLocked: false) }
        #expect(store.isLocked)
        #expect(defaults.data(forKey: DailyBlocking.developerOverrideKey) == previous)
        authorized = false
        for isLocked in [true, false] {
            #expect(throws: BlockedAppsStore.DeveloperOverrideError.self) {
                try store.setDeveloperLockOverride(isLocked: isLocked)
            }
        }
        #expect(defaults.data(forKey: DailyBlocking.developerOverrideKey) == previous)
        failSchedule = false
        authorized = true
        try store.setDeveloperLockOverride(isLocked: false)
        #expect(!store.isLocked && store.monitoringError == nil)
        #expect(defaults.object(forKey: DailyBlocking.workoutCompletionKey) == nil)
    }

    @MainActor
    @Test func dailyWorkoutRecipePersistsProgressOrdersExercisesAndResetsTomorrow() throws {
        let suite = "DailyWorkoutRecipeTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(secondsFromGMT: 0))
        var now = try #require(calendar.date(from: DateComponents(year: 2026, month: 9, day: 14, hour: 12)))
        let store = BlockedAppsStore(defaults: defaults, now: { now }, calendar: calendar, startMonitoring: {})

        #expect(store.dailyWorkoutRecipe.entries.map(\.exercise) == [.pushUp, .squat])
        #expect(store.dailyWorkoutRecipe.entries.map(\.target) == [10, 20])
        store.setTarget(1, for: .pushUp)
        store.setTarget(1, for: .squat)

        try store.recordRecognizedRep(for: .pushUp)
        #expect(store.completedRepetitions(for: .pushUp) == 1)
        #expect(store.nextRecipeExercise == .squat)
        #expect(!store.hasCompletedDailyWorkout)

        let reopened = BlockedAppsStore(defaults: defaults, now: { now }, calendar: calendar, startMonitoring: {})
        #expect(reopened.completedRepetitions(for: .pushUp) == 1)
        try reopened.recordRecognizedRep(for: .squat)
        #expect(reopened.hasCompletedDailyWorkout)
        #expect(reopened.isCafeOpen)

        now = now.addingTimeInterval(24 * 60 * 60)
        reopened.refreshLockState()
        #expect(reopened.completedRepetitions(for: .pushUp) == 0)
        #expect(reopened.nextRecipeExercise == .pushUp)
        #expect(!reopened.isCafeOpen)
    }

    @MainActor
    @Test func recipeEditsApplyBeforeCompletionAndQueueForTomorrowAfterward() throws {
        let suite = "DailyWorkoutRecipeTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(secondsFromGMT: 0))
        var now = try #require(calendar.date(from: DateComponents(year: 2026, month: 9, day: 14, hour: 12)))
        let store = BlockedAppsStore(defaults: defaults, now: { now }, calendar: calendar, startMonitoring: {})

        store.setExercise(.squat, isEnabled: false)
        store.setTarget(1, for: .pushUp)
        #expect(store.dailyWorkoutRecipe.entries.first(where: { $0.exercise == .squat })?.isEnabled == false)
        store.setExercise(.pushUp, isEnabled: false)
        #expect(store.dailyWorkoutRecipe.entries.first(where: { $0.exercise == .pushUp })?.isEnabled == true)
        store.moveRecipe(from: IndexSet(integer: 1), to: 0)
        #expect(store.dailyWorkoutRecipe.entries.map(\.exercise) == [.squat, .pushUp])

        try store.recordRecognizedRep(for: .pushUp)
        #expect(store.hasCompletedDailyWorkout)
        store.setTarget(99, for: .pushUp)
        store.setExercise(.pushUp, isEnabled: false)
        #expect(store.recipeForSettings.entries.first(where: { $0.exercise == .pushUp })?.isEnabled == true)
        store.setExercise(.squat, isEnabled: true)
        store.moveRecipe(from: IndexSet(integer: 1), to: 0)

        #expect(store.dailyWorkoutRecipe.entries.first(where: { $0.exercise == .pushUp })?.target == 1)
        #expect(store.recipeForSettings.entries.map(\.exercise) == [.pushUp, .squat])
        #expect(store.recipeForSettings.entries.first(where: { $0.exercise == .pushUp })?.target == 99)
        #expect(store.recipeForSettings.entries.first(where: { $0.exercise == .squat })?.isEnabled == true)
        #expect(store.isCafeOpen)

        let reopened = BlockedAppsStore(defaults: defaults, now: { now }, calendar: calendar, startMonitoring: {})
        #expect(reopened.dailyWorkoutRecipe.entries.first(where: { $0.exercise == .pushUp })?.target == 1)
        #expect(reopened.recipeForSettings.entries.first(where: { $0.exercise == .pushUp })?.target == 99)
        #expect(reopened.hasCompletedDailyWorkout && reopened.isCafeOpen)

        now = now.addingTimeInterval(24 * 60 * 60)
        reopened.refreshLockState()
        #expect(reopened.dailyWorkoutRecipe.entries.map(\.exercise) == [.pushUp, .squat])
        #expect(reopened.dailyWorkoutRecipe.entries.first(where: { $0.exercise == .pushUp })?.target == 99)
        #expect(reopened.dailyWorkoutRecipe.entries.first(where: { $0.exercise == .squat })?.isEnabled == true)
        #expect(reopened.recipeForSettings == reopened.dailyWorkoutRecipe)
        #expect(reopened.completedRepetitions(for: .pushUp) == 0)
        #expect(reopened.nextRecipeExercise == .pushUp)
        #expect(!reopened.hasCompletedDailyWorkout && !reopened.isCafeOpen)
    }

    @MainActor
    @Test func failedRecipeUnlockKeepsCafeClosedUntilRetrySucceeds() throws {
        enum ScheduleError: Error { case unavailable }
        let suite = "DailyWorkoutRecipeTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        var fails = true
        let store = BlockedAppsStore(defaults: defaults, startMonitoring: {
            if fails {
                throw ScheduleError.unavailable
            }
        })
        store.setExercise(.squat, isEnabled: false)
        store.setTarget(1, for: .pushUp)

        #expect(throws: ScheduleError.self) { try store.recordRecognizedRep(for: .pushUp) }
        #expect(store.completedRepetitions(for: .pushUp) == 1)
        #expect(store.isLocked && !store.isCafeOpen)

        fails = false
        try store.retryDailyWorkoutRecipeCompletion()
        #expect(!store.isLocked && store.isCafeOpen)
    }

    @MainActor
    @Test func developerUnlockDoesNotOpenCafeAndDeveloperBlockClosesIt() throws {
        let suite = "DailyWorkoutRecipeTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = BlockedAppsStore(defaults: defaults, startMonitoring: {}, authorizationCheck: { true })

        try store.setDeveloperLockOverride(isLocked: false)
        #expect(!store.isLocked && !store.isCafeOpen)

        store.setExercise(.squat, isEnabled: false)
        store.setTarget(1, for: .pushUp)
        try store.recordRecognizedRep(for: .pushUp)
        #expect(store.isCafeOpen)

        try store.setDeveloperLockOverride(isLocked: true)
        #expect(store.isLocked && !store.isCafeOpen)
    }
}
