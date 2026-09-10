import FamilyControls
import SwiftUI

struct BlockedAppsView: View {
    @EnvironmentObject private var store: BlockedAppsStore
    @State private var isPickerPresented = false
    @State private var authorizationError: String?

    private var hasSelection: Bool {
        !store.selection.applicationTokens.isEmpty
            || !store.selection.categoryTokens.isEmpty
            || !store.selection.webDomainTokens.isEmpty
    }

    var body: some View {
        List {
            Section {
                Label(
                    store.isLocked ? "Workout needed to unlock" : "Unlocked for today",
                    systemImage: store.isLocked ? "lock.fill" : "lock.open.fill"
                )
            }

            if !hasSelection {
                ContentUnavailableView(
                    "No Apps Blocked",
                    systemImage: "lock.open",
                    description: Text("Tap Edit to choose apps with Screen Time.")
                )
                .listRowBackground(Color.clear)
            }

            if !store.selection.applicationTokens.isEmpty {
                Section("Apps") {
                    ForEach(Array(store.selection.applicationTokens), id: \.self) { token in
                        Label(token)
                    }
                }
            }

            if !store.selection.categoryTokens.isEmpty {
                Section("Categories") {
                    ForEach(Array(store.selection.categoryTokens), id: \.self) { token in
                        Label(token)
                    }
                }
            }

            if !store.selection.webDomainTokens.isEmpty {
                Section("Websites") {
                    ForEach(Array(store.selection.webDomainTokens), id: \.self) { token in
                        Label(token)
                    }
                }
            }
        }
        .navigationTitle("Blocked Apps")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("Edit") {
                    authorizeAndShowPicker()
                }
            }
        }
        .familyActivityPicker(
            title: "Choose Apps to Block",
            headerText: "Select the apps and categories you want PushApp Blocker to control.",
            footerText: "You can change this selection at any time.",
            isPresented: $isPickerPresented,
            selection: $store.selection
        )
        .alert("Screen Time Access Needed", isPresented: isAuthorizationAlertPresented) {
            Button("OK", role: .cancel) { }
        } message: {
            Text(authorizationError ?? "Allow Screen Time access to choose apps.")
        }
    }

    private var isAuthorizationAlertPresented: Binding<Bool> {
        Binding(
            get: { authorizationError != nil },
            set: { isPresented in
                if !isPresented {
                    authorizationError = nil
                }
            }
        )
    }

    private func authorizeAndShowPicker() {
        Task {
            do {
                try await store.requestAuthorization()
                isPickerPresented = true
            } catch {
                authorizationError = error.localizedDescription
            }
        }
    }
}

#Preview {
    NavigationStack {
        BlockedAppsView()
            .environmentObject(BlockedAppsStore())
    }
}
