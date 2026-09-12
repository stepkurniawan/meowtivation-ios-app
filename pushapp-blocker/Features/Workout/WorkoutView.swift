import AVFoundation
import SwiftUI
import UIKit

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

    /// The main view for the workout session. It displays different content based on the state of the workout session (not started, in progress, or ended).
    var body: some View {
        NavigationStack {
            Group {
                if model.hasEnded { summary }
                else if !model.hasStarted { instructions }
                else { workout }
            }
            .navigationTitle(model.hasEnded ? "Workout Summary" : "Workout")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(model.hasStarted && !model.hasEnded ? "End Workout" : "Done") {
                        if model.hasStarted && !model.hasEnded { model.end() }
                        else { dismiss() }
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
            if phase == .active { model.resume() }
            else { model.pause() }
            UIApplication.shared.isIdleTimerDisabled = phase == .active && model.hasStarted && !model.hasEnded
        }
        .onChange(of: model.hasStarted) { _, started in UIApplication.shared.isIdleTimerDisabled = started }
        .onChange(of: model.hasEnded) { _, ended in if ended { UIApplication.shared.isIdleTimerDisabled = false } }
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
                Text("Lean your phone securely against a wall with the screen facing you. Keep one person in view with one shoulder, elbow, and wrist visible. Rotate the phone if you need a wider view.")
                VStack(alignment: .leading, spacing: 6) {
                    Text(PushUp.title).font(.headline)
                    Text(PushUp.placement)
                }
                Text("Start with your arms extended. One rep is counted when your elbow angle gets smaller and then returns to the extended position.")
                Text("Video stays on your phone and is not saved. This session counts reps; it does not unlock blocked apps.")
                    .font(.footnote).foregroundStyle(.secondary)
                Button("Start Counting") { model.start() }
                    .buttonStyle(.borderedProminent).controlSize(.large)
                    .frame(maxWidth: .infinity)
            }.padding()
        }
    }

    /// A view that displays the live camera preview and workout controls. Also checks portrait or landscape orientation and adjusts the layout accordingly.
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
                       showSkeleton: true, selectedSide: model.selectedSide,
                       onRotation: model.updateRotation)
            .background(.black)
            .clipShape(RoundedRectangle(cornerRadius: 16))
            .overlay {
                if model.cameraState != .running {
                    VStack(spacing: 12) {
                        Text(model.cameraState.message).multilineTextAlignment(.center)
                        if model.cameraState == .denied {
                            Button("Open Settings") {
                                if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
                            }
                        }
                        if case .failed = model.cameraState { Button("Try Again") { model.retry() } }
                    }
                    .padding().foregroundStyle(.white)
                    .background(.black.opacity(0.8), in: RoundedRectangle(cornerRadius: 12)).padding()
                }
            }
            .accessibilityLabel("Live front camera preview")
    }

    /// A view that displays the push-up count, readiness, tracking messages, and optional diagnostics.
    private var controls: some View {
        VStack(spacing: 12) {
            Text(PushUp.title).font(.title2.bold())
            Text("\(model.pushUpCount)").font(.system(size: 64, weight: .bold, design: .rounded))
                .monospacedDigit().accessibilityLabel("\(model.pushUpCount) repetitions")
            Image(systemName: model.poseReady ? "checkmark.circle.fill" : "xmark.circle.fill")
                .font(.title2)
                .foregroundStyle(model.poseReady ? .green : .red)
                .accessibilityLabel(model.poseReady ? "Pose ready" : "Pose not ready")
            Text(model.tracking.message).font(.callout).multilineTextAlignment(.center)
            if model.startCueVisible {
                Text("Start!").font(.title.bold()).foregroundStyle(.green)
                    .accessibilityLabel("Start push-ups")
            }
            if model.tracking == .findingPosition || model.tracking == .waitingForSelectedArm {
                Text(PushUp.placement).font(.caption).foregroundStyle(.secondary)
            }
            pushUpCountCard
            if developerMode {
                Text(String(format: "%.1f fps · %.0f ms · %d usable joints", model.analysisFPS,
                            model.processingMilliseconds, model.latestFrame?.joints.values.filter(\.isUsable).count ?? 0))
                    .font(.caption.monospaced())
                if let angle = model.pushUpAngle {
                    Text("\(PushUp.title): \(Int(angle))°").font(.caption.monospaced())
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

    /// A view that displays the push-up count.
    private var pushUpCountCard: some View {
        VStack {
            Text("\(model.pushUpCount)").font(.title3.bold()).monospacedDigit()
            Text(PushUp.title).font(.caption)
        }
        .frame(maxWidth: .infinity)
        .padding()
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 12))
    }

    /// A view that displays a summary of the workout session, including an icon, completion message, push-up count, and a "Done" button to dismiss the view.
    private var summary: some View {
        VStack(spacing: 24) {
            Image(systemName: "figure.strengthtraining.traditional").font(.system(size: 60))
            Text("Session complete").font(.title.bold())
            pushUpCountCard
            Text("Your next session starts at zero.").foregroundStyle(.secondary)
            Button("Done") { dismiss() }.buttonStyle(.borderedProminent)
        }.padding()
    }
}


private struct WorkoutPreview: UIViewRepresentable {
    let session: AVCaptureSession
    let frame: PoseFrame?
    let showSkeleton: Bool
    let selectedSide: Int?
    let onRotation: (Double) -> Void
    func makeUIView(context: Context) -> WorkoutPreviewView {
        let view = WorkoutPreviewView()
        view.preview.session = session
        view.onRotation = onRotation
        return view
    }
    func updateUIView(_ view: WorkoutPreviewView, context: Context) {
        view.frameData = showSkeleton && selectedSide != nil ? frame : nil
        view.selectedSide = selectedSide
        view.imageAspect = frame?.imageAspectRatio ?? view.imageAspect
        view.setNeedsLayout()
    }
}

private final class WorkoutPreviewView: UIView {
    override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
    var preview: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }
    var onRotation: ((Double) -> Void)?
    var frameData: PoseFrame?
    var selectedSide: Int?
    var imageAspect = 9.0 / 16
    private var angle: Double?
    private let validJoints = CAShapeLayer()
    private let rejectedJoints = CAShapeLayer()
    override init(frame: CGRect) {
        super.init(frame: frame)
        preview.videoGravity = .resizeAspect
        for (shape, color) in [(validJoints, UIColor.systemGreen), (rejectedJoints, UIColor.systemOrange)] {
            shape.fillColor = color.cgColor
            shape.strokeColor = color.cgColor
            shape.lineWidth = 2
            layer.addSublayer(shape)
        }
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func layoutSubviews() {
        super.layoutSubviews()
        let rotation: Double
        switch window?.windowScene?.effectiveGeometry.interfaceOrientation {
        case .landscapeLeft: rotation = 0
        case .landscapeRight: rotation = 180
        case .portraitUpsideDown: rotation = 270
        default: rotation = 90
        }
        if let connection = preview.connection {
            if connection.isVideoRotationAngleSupported(rotation) { connection.videoRotationAngle = rotation }
            if connection.isVideoMirroringSupported {
                connection.automaticallyAdjustsVideoMirroring = false
                connection.isVideoMirrored = true
            }
        }
        if angle != rotation {
            angle = rotation
            DispatchQueue.main.async { [weak self] in self?.onRotation?(rotation) }
        }
        let size = CGSize(width: min(bounds.width, bounds.height * imageAspect),
                          height: min(bounds.height, bounds.width / imageAspect))
        let rect = CGRect(x: (bounds.width - size.width) / 2, y: (bounds.height - size.height) / 2,
                          width: size.width, height: size.height)
        func point(_ joint: PoseJoint) -> CGPoint {
            CGPoint(x: rect.minX + CGFloat(1 - joint.imagePoint.x) * rect.width,
                    y: rect.minY + CGFloat(1 - joint.imagePoint.y) * rect.height)
        }
        let good = UIBezierPath(), bad = UIBezierPath()
        if let frameData, let selectedSide {
            let selectedJoints = BodyJoint.sides[selectedSide]
            for (a, b) in BodyJoint.bones where selectedJoints.contains(a) && selectedJoints.contains(b) {
                if let start = frameData.joints[a], let end = frameData.joints[b], start.isUsable, end.isUsable {
                    good.move(to: point(start)); good.addLine(to: point(end))
                }
            }
            for bodyJoint in selectedJoints {
                guard let joint = frameData.joints[bodyJoint],
                      joint.imagePoint.x.isFinite, joint.imagePoint.y.isFinite else { continue }
                let position = point(joint)
                (joint.isUsable ? good : bad).append(UIBezierPath(ovalIn:
                    CGRect(x: position.x - 3, y: position.y - 3, width: 6, height: 6)))
            }
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        validJoints.path = good.cgPath
        rejectedJoints.path = bad.cgPath
        CATransaction.commit()
    }
}
