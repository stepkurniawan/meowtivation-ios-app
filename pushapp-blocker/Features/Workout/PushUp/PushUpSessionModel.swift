import Combine // ObservableObject
import Foundation

@MainActor
final class WorkoutSessionModel: ObservableObject {
    @Published private(set) var repCount = 0
    @Published private(set) var poseReady = false
    @Published private(set) var tracking = WorkoutTrackingState.findingPosition
    @Published private(set) var selectedExercise: WorkoutExercise?
    @Published private(set) var suggestedExercise: WorkoutExercise?
    @Published private(set) var cameraState = WorkoutCameraState.idle
    @Published private(set) var latestFrame: PoseFrame?
    @Published private(set) var armAngles: [Int: Float] = [:]
    @Published private(set) var kneeAngles: [Int: Float] = [:]
    @Published private(set) var processingMilliseconds = 0.0
    @Published private(set) var analysisFPS = 0.0
    @Published private(set) var hasStarted = false
    @Published private(set) var hasEnded = false
    @Published private(set) var isMuted = false
    @Published private(set) var startCueVisible = false

    private var engine = AutomaticWorkoutRecognitionEngine()
    private var lastCreditedID: UInt64 = 0
    private var lastPromptAt = -Double.infinity
    private var lastFrameAt: Double?
    private var startCueUntil = -Double.infinity
    private var generation = 0
    private var active = false
    private var rotation = 90.0
    private var speech: any WorkoutSpeaking
    private var cameraStorage: (any WorkoutCameraControlling)!
    var camera: any WorkoutCameraControlling { cameraStorage }

    /// Compatibility for existing callers while the UI moves to the shared name.
    var pushUpCount: Int { repCount }

    init(speech: (any WorkoutSpeaking)? = nil,
         cameraFactory: (@escaping @Sendable (Int, WorkoutCameraEvent) -> Void) -> any WorkoutCameraControlling = {
             WorkoutCamera(configuration: .automatic, onEvent: $0)
         }) {
        self.speech = speech ?? WorkoutSpeech()
        cameraStorage = cameraFactory { [weak self] token, event in
            Task { @MainActor [weak self] in self?.receive(event, generation: token) }
        }
    }

    func start() {
        guard !hasEnded, !active else { return }
        hasStarted = true
        active = true
        generation += 1
        engine.resetTracking()
        resetPublishedTracking()
        cameraState = .requestingPermission
        camera.start(generation: generation, rotation: rotation)
    }

    func pause() {
        active = false
        generation += 1
        camera.stop()
        speech.stop()
        engine.resetTracking()
        resetPublishedTracking()
        latestFrame = nil
        lastFrameAt = nil
        analysisFPS = 0
        cameraState = .idle
    }

    func resume() { if hasStarted, !hasEnded { start() } }

    func retry() { pause(); start() }

    func end() {
        pause()
        hasEnded = true
    }

    func toggleMute() {
        isMuted.toggle()
        if isMuted { speech.stop() }
    }

    func updateRotation(_ angle: Double) {
        guard rotation != angle else { return }
        rotation = angle
        engine.resetTracking()
        resetPublishedTracking()
        latestFrame = nil
        speech.stop()
        camera.updateRotation(angle)
    }

    private func resetPublishedTracking() {
        poseReady = false
        tracking = .findingPosition
        suggestedExercise = selectedExercise
        armAngles = [:]
        kneeAngles = [:]
        startCueVisible = false
        startCueUntil = -Double.infinity
    }

    // Internal for deterministic lifecycle tests. Generation rejects late callbacks
    // from permission requests, dismissed sessions, and interrupted camera work.
    func receive(_ event: WorkoutCameraEvent, generation token: Int) {
        guard active, !hasEnded, token == generation else { return }
        switch event {
        case .state(let state):
            cameraState = state
            if state != .running {
                engine.resetTracking()
                resetPublishedTracking()
                latestFrame = nil
                lastFrameAt = nil
                analysisFPS = 0
                speech.stop()
            }
        case .frame(let frame, let milliseconds):
            guard cameraState == .running else { return }
            if let lastFrameAt, frame.timestamp > lastFrameAt {
                analysisFPS = 0.8 * analysisFPS + 0.2 / (frame.timestamp - lastFrameAt)
            }
            lastFrameAt = frame.timestamp
            processingMilliseconds = milliseconds
            latestFrame = frame

            let previousSelection = selectedExercise
            let update = engine.consume(frame)
            poseReady = update.poseReady
            tracking = update.tracking
            selectedExercise = update.selectedExercise ?? engine.selectedExercise
            suggestedExercise = update.suggestedExercise ?? selectedExercise
            if previousSelection != selectedExercise, let selectedExercise {
                camera.updatePoseConfiguration(selectedExercise.poseConfiguration)
            }
            armAngles = update.armAngles
            kneeAngles = update.kneeAngles
            startCueVisible = frame.timestamp < startCueUntil
            if update.didStart {
                startCueUntil = frame.timestamp + 1.5
                startCueVisible = true
            }

            var counted = false
            for rep in update.reps.sorted(by: { $0.id < $1.id }) where rep.id > lastCreditedID {
                repCount += 1
                lastCreditedID = rep.id
                counted = true
            }

            guard !isMuted else { return }
            if update.didStart {
                speech.say("Start!")
                lastPromptAt = frame.timestamp
            } else if counted {
                let title = selectedExercise?.title ?? "Workout"
                speech.say(repCount == 1 ? "\(title). \(repCount)" : "\(repCount)")
                lastPromptAt = frame.timestamp
            } else if update.tracking == .ambiguous,
                      frame.timestamp - lastPromptAt >= 1 {
                speech.say(update.tracking.message)
                lastPromptAt = frame.timestamp
            } else if update.tracking == .waitingForJoints || update.tracking == .cameraMoving,
                      frame.timestamp - lastPromptAt >= 8 {
                speech.say(update.tracking.message)
                lastPromptAt = frame.timestamp
            }
        }
    }
}

/// Preserve the old type name for existing tests and integrations during the
/// transition to the shared workout model.
typealias PushUpSessionModel = WorkoutSessionModel
