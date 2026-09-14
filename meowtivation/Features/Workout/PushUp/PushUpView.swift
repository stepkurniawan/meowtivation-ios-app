import OSLog
import SwiftUI
import UIKit

// The workout screen keeps setup, live feedback, controls, and summary together.
// swiftlint:disable:next type_body_length
struct WorkoutView: View {
    private enum TapSide {
        case left, right
    }

    private static let developerSequence: [TapSide] = [.left, .right, .left, .right, .left, .right]

    @StateObject private var model: WorkoutSessionModel
    private let mode: WorkoutSessionMode
    @EnvironmentObject private var store: BlockedAppsStore
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @State private var developerMode = false
    @State private var developerTapProgress: [TapSide] = []
    @State private var lastDeveloperTap: TimeInterval?
    @State private var nextExercise: WorkoutExercise?
    @State private var completionError: String?
    @ScaledMetric(relativeTo: .largeTitle) private var dailyCountSize = 52

    init(exercise: WorkoutExercise, mode: WorkoutSessionMode = .daily) {
        _model = StateObject(wrappedValue: WorkoutSessionModel(exercise: exercise))
        self.mode = mode
    }

    private var activeTitle: String {
        model.exercise.title
    }

    private var activeConfiguration: WorkoutPoseConfiguration {
        model.exercise.poseConfiguration
    }

    /// The main view for the workout session. It displays different content based on the state of the workout session
    /// (not started, in progress, or ended).
    var body: some View {
        NavigationStack {
            Group {
                if let nextExercise {
                    exerciseHandoff(nextExercise)
                } else if model.hasEnded {
                    summary
                } else if !model.hasStarted {
                    instructions
                } else {
                    workout
                }
            }
            .navigationTitle(model.hasEnded ? "Workout Summary" : "Workout")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(model.hasStarted && !model.hasEnded ? "End Workout" : "Done") {
                        if model.hasStarted && !model.hasEnded {
                            model.end()
                        } else {
                            dismiss()
                        }
                    }
                }
                if model.hasStarted && !model.hasEnded {
                    ToolbarItem(placement: .primaryAction) {
                        Button { model.toggleMute() } label: {
                            Image(systemName: model.isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                        }
                        .accessibilityLabel(model.isMuted ? "Unmute spoken counts" : "Mute spoken counts")
                    }
                }
            }
            .overlay(alignment: .bottom) {
                if !developerMode {
                    HStack(spacing: 0) {
                        Color.clear
                            .frame(width: 96, height: 96)
                            .contentShape(Rectangle())
                            .onTapGesture { handleDeveloperTap(.left) }
                        Spacer()
                        Color.clear
                            .frame(width: 96, height: 96)
                            .contentShape(Rectangle())
                            .onTapGesture { handleDeveloperTap(.right) }
                    }
                    .ignoresSafeArea(.container, edges: .bottom)
                    .accessibilityHidden(true)
                }
            }
        }
        .interactiveDismissDisabled(model.hasStarted && !model.hasEnded)
        .onChange(of: scenePhase) { _, phase in
            developerTapProgress = []
            lastDeveloperTap = nil
            if phase == .active {
                model.resume()
            } else {
                model.pause()
            }
            UIApplication.shared.isIdleTimerDisabled = phase == .active && model.hasStarted && !model.hasEnded
        }
        .onChange(of: model.hasStarted) { _, started in UIApplication.shared.isIdleTimerDisabled = started }
        .onChange(of: model.hasEnded) { _, ended in
            if ended {
                UIApplication.shared.isIdleTimerDisabled = false
            }
        }
        .onChange(of: model.repCount) { previous, current in
            guard current > previous else { return }
            handleRecognizedRep()
        }
        .onDisappear {
            developerTapProgress = []
            lastDeveloperTap = nil
            developerMode = false
            WorkoutDebugLog.lifecycle.info(
                "WorkoutView onDisappear; ended=\(model.hasEnded, privacy: .public)"
            )
            // Ending the session already pauses the camera. Only pause here when
            // the view disappears before the session has ended.
            if !model.hasEnded {
                model.pause()
            }
            UIApplication.shared.isIdleTimerDisabled = false
        }
    }

    /// A view that displays instructions for setting up the workout session.
    private var instructions: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Text("Set up your phone").font(.title.bold())
                Text(
                    "Lean your phone securely against a wall with the screen facing you. Keep one person in view. " +
                        "Rotate the phone if you need a wider view."
                )
                Text("\(activeTitle) setup").font(.headline)
                Text(model.exercise.placement)
                Text(
                    "Hold your starting position still until Start! appears, then begin."
                )
                Text(
                    mode == .extra
                        ? "Video stays on your phone and is not saved. End the workout whenever you are ready."
                        : "Video stays on your phone and is not saved. Completing today’s recipe opens the cat cafe."
                )
                .font(.footnote).foregroundStyle(.secondary)
                Button("Start Counting") { model.start() }
                    .buttonStyle(.borderedProminent).controlSize(.large)
                    .frame(maxWidth: .infinity)
            }.padding()
        }
    }

    /// A view that displays the live camera preview and workout controls. Also checks portrait or landscape orientation
    /// and adjusts the layout accordingly.
    private var workout: some View {
        GeometryReader { geometry in
            let landscape: Bool = geometry.size.width > geometry.size.height
            Group {
                if landscape {
                    HStack(spacing: 12) {
                        preview
                        ScrollView { controls }.frame(width: min(320, geometry.size.width * 0.45))
                    }
                } else {
                    VStack(spacing: 12) {
                        preview.frame(maxHeight: .infinity)
                        ScrollView { controls }.frame(maxHeight: geometry.size.height * 0.48)
                    }
                }
            }.padding(12)
        }
    }

    /// A view that displays the live camera preview, pose-visibility glow, and error messages.
    private var preview: some View {
        WorkoutPreview(session: model.camera.session, onRotation: model.updateRotation)
            .background(.black)
            .clipShape(RoundedRectangle(cornerRadius: 16))
            .overlay {
                if model.cameraState != .running {
                    VStack(spacing: 12) {
                        Text(model.cameraState.message).multilineTextAlignment(.center)
                        if model.cameraState == .denied {
                            Button("Open Settings") {
                                if let url = URL(string: UIApplication.openSettingsURLString) {
                                    UIApplication.shared.open(url)
                                }
                            }
                        }
                        if case .failed = model.cameraState {
                            Button("Try Again") { model.retry() }
                        }
                    }
                    .padding().foregroundStyle(.white)
                    .background(.black.opacity(0.8), in: RoundedRectangle(cornerRadius: 12)).padding()
                }
            }
            .overlay {
                RoundedRectangle(cornerRadius: 16)
                    .stroke(poseGlow, lineWidth: 4)
                    .shadow(color: poseGlow.opacity(0.8), radius: 12)
            }
            .accessibilityLabel("Live front camera preview")
    }

    private var poseGlow: Color {
        switch activeConfiguration.visibility(in: model.latestFrame) {
        case .complete: .green
        case .partial: .orange
        case .none: .red
        }
    }

    private var activeDailyTarget: Int {
        store.dailyWorkoutRecipe.entries.first(where: { $0.exercise == model.exercise })?.target ?? 0
    }

    /// A view that displays daily progress, tracking messages, and optional diagnostics.
    private var controls: some View {
        VStack(spacing: 12) {
            Text(activeTitle).font(.title2.bold())
            Text("Today")
                .font(.headline)
                .foregroundStyle(.secondary)
            if mode == .extra {
                Text("This session")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Text("\(model.repCount)")
                    .font(.system(size: dailyCountSize, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .accessibilityLabel("\(model.repCount) reps this session")
                Text("Today’s total: \(store.completedRepetitions(for: model.exercise))")
                    .font(.headline)
                    .monospacedDigit()
                    .accessibilityLabel(
                        "\(store.completedRepetitions(for: model.exercise)) \(activeTitle.lowercased()) reps today"
                    )
            } else {
                Text("\(store.completedRepetitions(for: model.exercise)) / \(activeDailyTarget)")
                    .font(.system(size: dailyCountSize, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .accessibilityLabel(
                        "\(store.completedRepetitions(for: model.exercise)) of \(activeDailyTarget) daily repetitions"
                    )
            }
            Text(model.tracking.message(for: model.exercise)).font(.callout).multilineTextAlignment(.center)
            if model.startCueVisible {
                Text("Start!").font(.title.bold()).foregroundStyle(.green)
                    .accessibilityLabel("Start \(activeTitle)")
            }
            if model.tracking == .findingPosition || model.tracking == .waitingForJoints {
                Text(model.exercise.placement).font(.caption).foregroundStyle(.secondary)
            }
            if developerMode {
                Text(String(format: "%.1f fps · %.0f ms · %d usable joints", model.analysisFPS,
                            model.processingMilliseconds,
                            model.latestFrame?.joints.values.filter(\.isUsable).count ?? 0))
                    .font(.caption.monospaced())
                if !model.jointAngles.isEmpty {
                    let angleText = model.jointAngles.keys.sorted().compactMap { side -> String? in
                        guard let angle = model.jointAngles[side] else { return nil }
                        return "\(side == 0 ? "Right" : "Left"): \(Int(angle))°"
                    }.joined(separator: " · ")
                    Text(angleText)
                        .font(.caption.monospaced())
                }
                Text("Glow: green shows both full arms or legs; orange is partial; red has no usable joints.")
                    .font(.caption2)
            }
        }.frame(maxWidth: .infinity)
    }

    private func handleDeveloperTap(_ side: TapSide) {
        guard !developerMode, scenePhase == .active else { return }
        let timestamp = ProcessInfo.processInfo.systemUptime
        if let lastDeveloperTap, timestamp - lastDeveloperTap > 1.5 {
            developerTapProgress = []
        }
        lastDeveloperTap = timestamp
        developerTapProgress.append(side)
        if developerTapProgress == Self.developerSequence {
            developerMode = true
            developerTapProgress = []
            lastDeveloperTap = nil
        } else if !Self.developerSequence.starts(with: developerTapProgress) {
            developerTapProgress = []
            lastDeveloperTap = nil
        }
    }

    /// A view that displays the count for the completed session.
    private var countCard: some View {
        VStack {
            Text("This session").font(.caption).foregroundStyle(.secondary)
            Text("\(model.repCount)").font(.title3.bold()).monospacedDigit()
            Text("\(activeTitle) reps").font(.caption)
        }
        .frame(maxWidth: .infinity)
        .padding()
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 12))
    }

    /// A view that displays a summary of the workout session, including an icon, completion message, workout count, and
    /// a "Done" button to dismiss the view.
    private var summary: some View {
        VStack(spacing: 24) {
            Image(systemName: "figure.strengthtraining.traditional").font(.system(size: 60))
            Text(mode == .extra || !store.hasCompletedDailyWorkout ? "Session complete" : "Daily recipe complete")
                .font(.title.bold())
            countCard
            dailyProgress
            if let completionError {
                Text(completionError).foregroundStyle(.red).multilineTextAlignment(.center)
                Button("Try Again") { retryCompletion() }.buttonStyle(.borderedProminent)
            }
            Button("Done") {
                WorkoutDebugLog.lifecycle.info("Workout summary Done tapped")
                dismiss()
                WorkoutDebugLog.lifecycle.info("Workout summary dismiss() returned")
            }
            .buttonStyle(.borderedProminent)
        }.padding()
    }

    private func exerciseHandoff(_ exercise: WorkoutExercise) -> some View {
        VStack(spacing: 24) {
            Image(systemName: "checkmark.circle.fill").font(.system(size: 60)).foregroundStyle(.green)
            Text("\(model.exercise.title) complete").font(.title.bold())
            dailyProgress
            Text("Next: \(exercise.title)").font(.title2.bold())
            Text("Set up for the next exercise, then continue counting.")
                .foregroundStyle(.secondary).multilineTextAlignment(.center)
            Button("Continue to \(exercise.title)") {
                nextExercise = nil
                model.prepareForNextExercise(exercise)
            }
            .buttonStyle(.borderedProminent)
        }
        .padding()
    }

    private var dailyProgress: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(store.dailyWorkoutRecipe.entries) { entry in
                if entry.isEnabled || mode == .extra {
                    Text("\(entry.exercise.title): \(store.completedRepetitions(for: entry.exercise))/\(entry.target)")
                        .monospacedDigit()
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 12))
    }

    private func handleRecognizedRep() {
        if mode == .extra {
            store.recordExtraWorkoutRep(for: model.exercise)
            return
        }

        do {
            try store.recordRecognizedRep(for: model.exercise)
            if store.hasCompletedDailyWorkout {
                model.end()
            } else if let exercise = store.nextRecipeExercise, exercise != model.exercise {
                model.end()
                nextExercise = exercise
            }
        } catch {
            completionError = error.localizedDescription
            model.end()
        }
    }

    private func retryCompletion() {
        do {
            try store.retryDailyWorkoutRecipeCompletion()
            completionError = nil
        } catch {
            completionError = error.localizedDescription
        }
    }
}

/// Compatibility for callers that still present the old push-up view name.
typealias PushUpView = WorkoutView
