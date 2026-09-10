//
//  pushapp_blockerTests.swift
//  pushapp-blockerTests
//
//  Created by stephen on 01.09.26.
//

import Testing
import Foundation
@testable import pushapp_blocker

struct pushapp_blockerTests {

    @MainActor
    @Test func dailyLockPersistsAndResetsAtLocalMidnight() throws {
        let suiteName = "DailyLockTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(identifier: "Europe/Berlin"))
        var now = try #require(calendar.date(from: DateComponents(year: 2026, month: 9, day: 10, hour: 23, minute: 59)))
        let store = BlockedAppsStore(defaults: defaults, now: { now }, calendar: calendar)

        #expect(store.isLocked)
        store.completeDailyWorkout()
        #expect(!store.isLocked)

        let reopenedStore = BlockedAppsStore(defaults: defaults, now: { now }, calendar: calendar)
        #expect(!reopenedStore.isLocked)

        now = now.addingTimeInterval(60)
        reopenedStore.refreshLockState()
        #expect(reopenedStore.isLocked)
        #expect(BlockedAppsStore(defaults: defaults, now: { now }, calendar: calendar).isLocked)

        reopenedStore.completeDailyWorkout()
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
        let store = BlockedAppsStore(defaults: defaults, now: { now }, calendar: calendar)
        store.completeDailyWorkout()

        now = try #require(calendar.date(from: DateComponents(year: 2026, month: month, day: day, hour: 23, minute: 59)))
        store.refreshLockState()
        #expect(!store.isLocked)

        now = now.addingTimeInterval(60)
        store.refreshLockState()
        #expect(store.isLocked)
    }

}
