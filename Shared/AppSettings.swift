// App configuration shared by the app and its monitor extension.
nonisolated enum AppSettings {
    // Must match the App Group in both targets' entitlements.
    static let appGroup = "group.com.stepkurniawan.pushapp-blocker"
    static let userNameKey = "userName"
}
