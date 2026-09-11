import AVFoundation // AVSpeechSynthesizer
import Combine // ObservableObject
import Foundation // Date

@MainActor
protocol WorkoutSpeaking: AnyObject {
    func say(_ text: String)
    func stop()
}

/// A concrete implementation of `WorkoutSpeaking` that uses `AVSpeechSynthesizer` to speak text aloud.
@MainActor
final class WorkoutSpeech: NSObject, WorkoutSpeaking, AVSpeechSynthesizerDelegate {
    private let synthesizer = AVSpeechSynthesizer()
    private let voice: AVSpeechSynthesisVoice?
    override init() {
        voice = AVSpeechSynthesisVoice(language: "en-US")
        super.init()
        synthesizer.delegate = self
    }
    func say(_ text: String) {
        synthesizer.stopSpeaking(at: .immediate)
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .spokenAudio, options: [.duckOthers])
            try session.setActive(true)
            let utterance = AVSpeechUtterance(string: text)
            utterance.voice = voice
            synthesizer.speak(utterance)
        } catch { /* Visual feedback remains available if audio cannot start. */ }
    }
    func stop() {
        synthesizer.stopSpeaking(at: .immediate)
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }
    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        Task { @MainActor [weak self] in
            guard let self, !self.synthesizer.isSpeaking else { return }
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        }
    }
}

@MainActor
final class WorkoutSessionModel: ObservableObject {
    @Published private(set) var totals: [ExerciseKind: Int] = [:]
    @Published private(set) var currentExercise: ExerciseKind?
    @Published private(set) var poseReady = false
    @Published private(set) var tracking = WorkoutTracking.searching
    @Published private(set) var cameraState = WorkoutCameraState.idle
    @Published private(set) var latestFrame: PoseFrame?
    @Published private(set) var angles: [ExerciseKind: Float] = [:]
    @Published private(set) var processingMilliseconds = 0.0
    @Published private(set) var analysisFPS = 0.0
    @Published private(set) var hasStarted = false
    @Published private(set) var hasEnded = false
    @Published private(set) var isMuted = false
    private var engine = WorkoutRecognitionEngine()
    private var lastCreditedID: UInt64 = 0
    private var lastPromptAt = -Double.infinity
    private var lastFrameAt: Double?
    private var generation = 0
    private var active = false
    private var rotation = 90.0
    private var speech: any WorkoutSpeaking
    private var cameraStorage: (any WorkoutCameraControlling)!
    var camera: any WorkoutCameraControlling { cameraStorage }
    var currentCount: Int { currentExercise.map { totals[$0, default: 0] } ?? 0 }

    init(speech: (any WorkoutSpeaking)? = nil,
         cameraFactory: (@escaping @Sendable (Int, WorkoutCameraEvent) -> Void) -> any WorkoutCameraControlling = { WorkoutCamera(onEvent: $0) }) {
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
        currentExercise = nil
        poseReady = false
        tracking = .searching
        cameraState = .requestingPermission
        camera.start(generation: generation, rotation: rotation)
    }

    func pause() {
        active = false
        generation += 1
        camera.stop()
        speech.stop()
        engine.resetTracking()
        currentExercise = nil
        poseReady = false
        latestFrame = nil
        angles = [:]
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
        latestFrame = nil
        currentExercise = nil
        speech.stop()
        camera.updateRotation(angle)
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
                latestFrame = nil
                currentExercise = nil
                poseReady = false
                tracking = .searching
                angles = [:]
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
            let previous = currentExercise
            let update = engine.consume(frame)
            currentExercise = update.exercise
            poseReady = update.poseReady
            tracking = update.tracking
            angles = update.angles
            var counted = false
            for rep in update.reps.sorted(by: { $0.id < $1.id }) where rep.id > lastCreditedID {
                totals[rep.exercise, default: 0] += 1
                lastCreditedID = rep.id
                counted = true
            }
            guard !isMuted else { return }
            if counted, let exercise = currentExercise {
                let count = totals[exercise, default: 0]
                speech.say(previous != exercise ? "\(exercise.title). \(count)" : "\(count)")
                lastPromptAt = frame.timestamp
            } else if update.tracking != .tracking, update.tracking != .searching,
                      frame.timestamp - lastPromptAt >= 8 {
                speech.say(update.tracking.message)
                lastPromptAt = frame.timestamp
            }
        }
    }
}
