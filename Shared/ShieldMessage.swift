import Foundation

nonisolated enum ShieldMessage {
    static let subtitle = "Do your workout today to unlock your app."
    static let primaryButtonTitle = "Open Meowtivation"

    static func greeting(for name: String?) -> String {
        let trimmedName = name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmedName.isEmpty ? "Stay focused!" : "Stay focused, \(trimmedName)!"
    }
}
