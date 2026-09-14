import SwiftUI
import UIKit

// The workout screen keeps setup, live feedback, controls, and summary together.
// swiftlint:disable:next type_body_length
struct WorkoutView: View {
    private enum TapSide {
        case left, right
    }

    private static let developerSequence: [TapSide] = [.left, .right, .left, .right, .left, .right]

    @StateObject private var model = WorkoutSessionModel()
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @State private var developerMode = false
    @State private var developerTapProgress: [TapSide] = []
    @State private var lastDeveloperTap: TimeInterval?

    private var activeTitle: String {
        model.selectedExercise?.title ?? model.suggestedExercise?.title ?? "Push-up or Squat"
    }

    private var activePlacement: String {
        model.selectedExercise?.placement ??
            "Keep one person in view. Try either a side-view push-up or a full-body squat."
    }

    private var activeConfiguration: WorkoutPoseConfiguration {
        model.selectedExercise?.poseConfiguration ?? .automatic
    }

    /// The main view for the workout session. It displays different content based on the state of the workout session
    /// (not started, in progress, or ended).
    var body: some View {
        NavigationStack {
            Group {
                if model.hasEnded {
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
        .onDisappear {
            developerTapProgress = []
            lastDeveloperTap = nil
            developerMode = false
            model.pause()
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
                VStack(alignment: .leading, spacing: 6) {
                    Text("Push-up or Squat").font(.headline)
                    Text(
                        "For a push-up, keep one shoulder, elbow, wrist, and preferably your hip visible from " +
                            "the side. " +
                            "For a squat, keep one shoulder, hip, knee, and ankle visible. " +
                            "Your arms can be bent."
                    )
                }
                Text(
                    "Hold your starting position still until Start! appears, then begin. " +
                        "The first complete rep selects the exercise and counts as rep 1."
                )
                Text(
                    "Video stays on your phone and is not saved. This session counts reps; " +
                        "it does not unlock blocked apps."
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

    /// A view that displays the live camera preview with the detected skeleton overlay and error messages.
    private var preview: some View {
        WorkoutPreview(session: model.camera.session, frame: model.latestFrame,
                       configuration: activeConfiguration,
                       onRotation: model.updateRotation)
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
            .accessibilityLabel("Live front camera preview")
    }

    /// A view that displays the workout count, readiness, tracking messages, and optional diagnostics.
    private var controls: some View {
        VStack(spacing: 12) {
            Text(activeTitle).font(.title2.bold())
            Text("\(model.repCount)").font(.system(size: 64, weight: .bold, design: .rounded))
                .monospacedDigit().accessibilityLabel("\(model.repCount) repetitions")
            Image(systemName: model.poseReady ? "checkmark.circle.fill" : "xmark.circle.fill")
                .font(.title2)
                .foregroundStyle(model.poseReady ? .green : .red)
                .accessibilityLabel(model.poseReady ? "Pose ready" : "Pose not ready")
            Text(model.tracking.message).font(.callout).multilineTextAlignment(.center)
            if let suggestion = model.suggestedExercise, model.selectedExercise == nil {
                Text("Suggested: \(suggestion.title). Start moving when you are ready.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            if model.startCueVisible {
                Text("Start!").font(.title.bold()).foregroundStyle(.green)
                    .accessibilityLabel("Start \(activeTitle)")
            }
            if model.tracking == .findingPosition || model.tracking == .waitingForJoints {
                Text(activePlacement).font(.caption).foregroundStyle(.secondary)
            }
            countCard
            if developerMode {
                Text(String(format: "%.1f fps · %.0f ms · %d usable joints", model.analysisFPS,
                            model.processingMilliseconds,
                            model.latestFrame?.joints.values.filter(\.isUsable).count ?? 0))
                    .font(.caption.monospaced())
                if !model.armAngles.isEmpty || !model.kneeAngles.isEmpty {
                    let armText = model.armAngles.keys.sorted().compactMap { side -> String? in
                        guard let angle = model.armAngles[side] else { return nil }
                        return "\(side == 0 ? "Right" : "Left"): \(Int(angle))°"
                    }.joined(separator: " · ")
                    let kneeText = model.kneeAngles.keys.sorted().compactMap { side -> String? in
                        guard let angle = model.kneeAngles[side] else { return nil }
                        return "\(side == 0 ? "Right" : "Left"): \(Int(angle))°"
                    }.joined(separator: " · ")
                    Text(armText + (kneeText.isEmpty ? "" : "  knees: " + kneeText))
                        .font(.caption.monospaced())
                }
                Text("Green: corroborated joint. Orange: rejected. A returned joint does not prove visibility.")
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

    /// A view that displays the workout count.
    private var countCard: some View {
        VStack {
            Text("\(model.repCount)").font(.title3.bold()).monospacedDigit()
            Text(activeTitle).font(.caption)
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
            Text("Session complete").font(.title.bold())
            countCard
            Text("Your next session starts at zero.").foregroundStyle(.secondary)
            Button("Done") { dismiss() }.buttonStyle(.borderedProminent)
        }.padding()
    }
}

/// Compatibility for callers that still present the old push-up view name.
typealias PushUpView = WorkoutView
