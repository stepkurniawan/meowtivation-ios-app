import SwiftUI

struct DailyWorkoutSettingsView: View {
    @EnvironmentObject private var store: BlockedAppsStore

    var body: some View {
        List {
            Section {
                if store.hasCompletedDailyWorkout {
                    Label("Editing tomorrow’s recipe", systemImage: "calendar.badge.clock")
                        .foregroundStyle(.green)
                    Text("Takes effect tomorrow. Today’s completed recipe stays unchanged.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                } else {
                    Text("Drag to choose the exercise order. Keep at least one exercise enabled.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            } header: {
                Text("Daily Exercise")
            }

            Section {
                ForEach(store.recipeForSettings.entries) { entry in
                    exerciseRow(entry)
                }
                .onMove(perform: store.moveRecipe)
            } footer: {
                Text("Each target can be from 1 to 100 recognized repetitions.")
            }

            Section {
                NavigationLink("Blocked Apps") {
                    BlockedAppsView()
                }

                TextField("Your name (optional)", text: $store.userName)
                    .textContentType(.givenName)
                    .autocorrectionDisabled()
            } header: {
                Text("App Blocking")
            } footer: {
                Text("Used in the focus message shown when a blocked app is opened.")
            }
        }
        .navigationTitle("Settings")
        .toolbar {
            EditButton()
        }
    }

    private func exerciseRow(_ entry: DailyExerciseTarget) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Toggle(entry.exercise.title, isOn: Binding(
                get: { entry.isEnabled },
                set: { store.setExercise(entry.exercise, isEnabled: $0) }
            ))

            Stepper(value: Binding(
                get: { entry.target },
                set: { store.setTarget($0, for: entry.exercise) }
            ), in: 1 ... 100) {
                Text("Target: \(entry.target) reps")
                    .monospacedDigit()
            }
            .disabled(!entry.isEnabled)

            if !store.hasCompletedDailyWorkout {
                Text("Today: \(store.completedRepetitions(for: entry.exercise))/\(entry.target)")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
    }
}
