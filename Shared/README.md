# Shared daily blocking logic

`DailyBlocking.swift` contains the blocking logic used by both the main app and the `DailyResetMonitor` extension. Xcode includes this folder in both build targets so they use the same implementation without duplicating code.

- **Main app:** saves the selected apps, records workout completion, starts daily monitoring, and updates restrictions.
- **Monitor extension:** refreshes restrictions at daily schedule boundaries, independently of the app’s UI.

[`AppSettings.swift`](AppSettings.swift) contains the App Group identifier, accessed through `AppSettings.appGroup`. It must match both targets’ entitlements.

[`DailyBlocking.swift`](DailyBlocking.swift) keeps the blocking-specific storage keys, monitoring schedule, and named settings store alongside helpers to read selections, migrate older saved data, check whether today’s workout is complete, and apply or remove restrictions for apps, categories, and web domains. Storage key changes require a data migration.

Apps remain locked unless a workout completion date falls on the current calendar day. Both targets use this rule, so a delayed monitor callback checks the latest completion date before applying restrictions.

The `Shared` folder shares **source code**; the App Group’s `UserDefaults` shares **saved data** between the app and extension. The folder name is a convention, not an Apple requirement.
