import OSLog

nonisolated enum WorkoutDebugLog {
    static let lifecycle = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "pushapp-blocker",
        category: "WorkoutLifecycle"
    )

    static func elapsedMilliseconds(since start: ContinuousClock.Instant) -> Int {
        let duration = start.duration(to: .now)
        let components = duration.components
        let nanoseconds = components.attoseconds / 1_000_000_000
        return Int(components.seconds * 1000 + nanoseconds / 1_000_000)
    }
}
