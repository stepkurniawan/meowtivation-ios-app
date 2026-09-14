import ManagedSettings

nonisolated enum ShieldActionResponseFactory {
    static func response(for action: ShieldAction) -> ShieldActionResponse {
        switch action {
        case .primaryButtonPressed:
            .openParentalControlsApp
        default:
            .none
        }
    }
}
