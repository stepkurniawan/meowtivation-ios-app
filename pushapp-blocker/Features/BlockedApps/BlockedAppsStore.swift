import Combine
import FamilyControls
import Foundation
import ManagedSettings

@MainActor
final class BlockedAppsStore: ObservableObject {
    @Published var selection: FamilyActivitySelection {
        didSet {
            guard selection != oldValue else { return }
            saveSelection()
            applySelection()
        }
    }

    private let defaults: UserDefaults
    private let managedSettings = ManagedSettingsStore()
    private let selectionKey = "blockedAppsSelection"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults

        if let data = defaults.data(forKey: selectionKey),
           let savedSelection = try? JSONDecoder().decode(FamilyActivitySelection.self, from: data) {
            selection = savedSelection
        } else {
            selection = FamilyActivitySelection()
        }

        applySelection()
    }

    func requestAuthorization() async throws {
        let authorizationCenter = AuthorizationCenter.shared

        guard authorizationCenter.authorizationStatus != .approved,
              authorizationCenter.authorizationStatus != .approvedWithDataAccess else {
            return
        }

        try await authorizationCenter.requestAuthorization(for: .individual)
    }

    private func saveSelection() {
        guard let data = try? JSONEncoder().encode(selection) else { return }
        defaults.set(data, forKey: selectionKey)
    }

    private func applySelection() {
        managedSettings.shield.applications = selection.applicationTokens.isEmpty
            ? nil
            : selection.applicationTokens
        managedSettings.shield.applicationCategories = selection.categoryTokens.isEmpty
            ? nil
            : .specific(selection.categoryTokens)
        managedSettings.shield.webDomains = selection.webDomainTokens.isEmpty
            ? nil
            : selection.webDomainTokens
    }
}
