# Blocked Apps

`BlockedAppsStore.swift` manages the data and blocking rules. It remembers selected apps, saves them, requests Screen Time access, applies blocking, and handles unlocking after a workout and setting up the daily reset.

`BlockedAppsView.swift` manages what you see and tap. It displays selected apps, categories, websites, lock status, and errors. It also provides the **Edit** button and app picker.

## How they work together

When you select apps in the View, it updates `store.selection`. The Store then saves that selection and updates blocking. When the Store's published state changes, SwiftUI automatically refreshes the View.

## Where to make changes

- **Appearance, text, or buttons:** [BlockedAppsView.swift](BlockedAppsView.swift)
- **Saving selections or blocking/unlocking behavior:** [BlockedAppsStore.swift](BlockedAppsStore.swift)
