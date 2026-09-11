import DeviceActivity
import Foundation
import ManagedSettings

final class DailyResetMonitor: DeviceActivityMonitor {
    override func intervalDidStart(for activity: DeviceActivityName) {
        super.intervalDidStart(for: activity)
        refreshShields(for: activity)
    }

    override func intervalDidEnd(for activity: DeviceActivityName) {
        super.intervalDidEnd(for: activity)
        refreshShields(for: activity)
    }

    private func refreshShields(for activity: DeviceActivityName) {
        guard activity == DailyBlocking.activity else { return }
        // Read today's state each time: a delayed callback must not undo today's workout.
        DailyBlocking.apply(
            selection: DailyBlocking.selection(from: DailyBlocking.defaults),
            isLocked: DailyBlocking.isLocked(in: DailyBlocking.defaults, now: Date()),
            to: ManagedSettingsStore(named: DailyBlocking.storeName)
        )
    }
}
