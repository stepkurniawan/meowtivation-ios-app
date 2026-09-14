import Combine // ObservableObject
import Foundation

@MainActor
// This model remains ObservableObject because the view uses StateObject ownership.
// swiftlint:disable:next observable_object_legacy
final class WorkoutSessionModel: ObservableObject {
    @Published private(set) var exercise: WorkoutExercise
    @Published private(set) var repCount = 0
    @Published private(set) var poseReady = false
    @Published private(set) var tracking = WorkoutTrackingState.findingPosition
    @Published private(set) var cameraState = WorkoutCameraState.idle
    @Published private(set) var latestFrame: PoseFrame?
    @Published private(set) var jointAngles: [Int: Float] = [:]
    @Published private(set) var processingMilliseconds = 0.0
    @Published private(set) var analysisFPS = 0.0
    @Published private(set) var hasStarted = false
    @Published private(set) var hasEnded = false
    @Published private(set) var isMuted = false
    @Published private(set) var startCueVisible = false

    private var engine: WorkoutRecognitionEngine
    private var lastCreditedID: UInt64 = 0
    private var lastPromptAt = -Double.infinity
    private var lastFrameAt: Double?
    private var startCueUntil = -Double.infinity
    private var generation = 0
    private var active = false
    private var rotation = 90.0
    private var speech: any WorkoutSpeaking
    private var cameraStorage: (any WorkoutCameraControlling)!
    var camera: any WorkoutCameraControlling {
        cameraStorage
    }

    init(exercise: WorkoutExercise,
         speech: (any WorkoutSpeaking)? = nil,
         cameraFactory: (WorkoutPoseConfiguration,
                         @escaping @Sendable (Int, WorkoutCameraEvent) -> Void) -> any WorkoutCameraControlling = {
             WorkoutCamera(configuration: $0, onEvent: $1)
         })
    {
        self.exercise = exercise
        engine = WorkoutRecognitionEngine(exercise: exercise)
        self.speech = speech ?? WorkoutSpeech()
        cameraStorage = cameraFactory(exercise.poseConfiguration) { [weak self] token, event in
            Task { @MainActor [weak self] in self?.receive(event, generation: token) }
        }
        cameraStorage.updatePoseConfiguration(exercise.poseConfiguration)
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

    func resume() {
        if hasStarted, !hasEnded {
            start()
        }
    }

    func retry() {
        pause(); start()
    }

    func end() {
        pause()
        hasEnded = true
    }

    /// Stops the current exercise and prepares the same camera session for the next recipe item.
    func prepareForNextExercise(_ exercise: WorkoutExercise) {
        pause()
        self.exercise = exercise
        engine = WorkoutRecognitionEngine(exercise: exercise)
        camera.updatePoseConfiguration(exercise.poseConfiguration)
        repCount = 0
        lastCreditedID = 0
        hasStarted = false
        hasEnded = false
        resetPublishedTracking()
    }

    func toggleMute() {
        isMuted.toggle()
        if isMuted {
            speech.stop()
        }
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
        jointAngles = [:]
        startCueVisible = false
        startCueUntil = -Double.infinity
    }

    // Internal for deterministic lifecycle tests. Generation rejects late callbacks
    // from permission requests, dismissed sessions, and interrupted camera work.
    // Camera state, recognition, published UI state, and speech must update together.
    // swiftlint:disable:next cyclomatic_complexity function_body_length
    func receive(_ event: WorkoutCameraEvent, generation token: Int) {
        guard active, !hasEnded, token == generation else { return }
        switch event {
        case let .state(state):
            cameraState = state
            if state != .running {
                engine.resetTracking()
                resetPublishedTracking()
                latestFrame = nil
                lastFrameAt = nil
                analysisFPS = 0
                speech.stop()
            }
        case let .frame(frame, milliseconds):
            guard cameraState == .running else { return }
            if let lastFrameAt, frame.timestamp > lastFrameAt {
                analysisFPS = 0.8 * analysisFPS + 0.2 / (frame.timestamp - lastFrameAt)
            }
            lastFrameAt = frame.timestamp
            processingMilliseconds = milliseconds
            latestFrame = frame

            let update = engine.consume(frame)
            poseReady = update.poseReady
            tracking = update.tracking
            jointAngles = update.jointAngles
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
                speech.say(repCount == 1 ? "\(exercise.title). \(repCount)" : "\(repCount)")
                lastPromptAt = frame.timestamp
            } else if update.tracking == .waitingForJoints || update.tracking == .cameraMoving,
                      frame.timestamp - lastPromptAt >= 8
            {
                speech.say(update.tracking.message(for: exercise))
                lastPromptAt = frame.timestamp
            }
        }
    }
}
