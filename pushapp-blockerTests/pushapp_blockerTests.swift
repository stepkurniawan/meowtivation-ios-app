//
//  pushapp_blockerTests.swift
//  pushapp-blockerTests
//
//  Created by stephen on 01.09.26.
//

import Testing
import Foundation
import FamilyControls
@testable import pushapp_blocker

struct pushapp_blockerTests {

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
        #expect(DailyBlocking.isLocked(in: monitorDefaults, now: dayOne.addingTimeInterval(7 * 24 * 60 * 60), calendar: calendar))

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
            if shouldFail { throw ScheduleError.unavailable }
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

        now = try #require(calendar.date(from: DateComponents(year: 2026, month: month, day: day, hour: 23, minute: 59)))
        store.refreshLockState()
        #expect(!store.isLocked)

        now = now.addingTimeInterval(60)
        store.refreshLockState()
        #expect(store.isLocked)
    }

}
