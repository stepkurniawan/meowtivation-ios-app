import Foundation
import simd

nonisolated enum WorkoutTracking: Equatable, Sendable {
    case searching, tracking, reposition, cameraMoving
    var message: String {
        switch self {
        case .searching: "Show one shoulder, elbow, and wrist to start."
        case .tracking: "Tracking your movement"
        case .reposition: "Move to a clear side view. Keep the joints needed for the exercise visible."
        case .cameraMoving: "Keep the phone still against the wall."
        }
    }
}

nonisolated struct RepEvent: Identifiable, Sendable {
    let id: UInt64
    let exercise: ExerciseKind
    let timestamp: TimeInterval
}

nonisolated struct RecognitionUpdate: Sendable {
    var exercise: ExerciseKind?
    var tracking: WorkoutTracking
    var poseReady = false
    var reps: [RepEvent] = []
    var angles: [ExerciseKind: Float] = [:]
}

nonisolated private struct CycleDetector {
    enum Phase { case waiting, extended, contracted }
    var phase = Phase.waiting
    var startedAt = 0.0
    var side: Int?

    mutating func consume(_ raw: ExerciseSample, at time: TimeInterval) -> Bool {
        if let side, side != raw.side {
            self = CycleDetector()
        }
        side = raw.side

        // PoseStabilizer has already filtered the joint coordinates. Use that
        // stabilized angle directly so a quick recovery can complete a rep
        // without waiting for a second filter to catch up.
        let angle = raw.angle

        if phase != .waiting, time - startedAt > RecognitionParameters.maximumCycleDuration {
            phase = .waiting
        }

        switch phase {
        case .waiting:
            guard angle >= RecognitionParameters.minimumRecoveryAngle else {
                return false
            }
            phase = .extended
            startedAt = time
        case .extended:
            guard angle <= RecognitionParameters.maximumContractedAngle else {
                return false
            }
            phase = .contracted
        case .contracted:
            guard angle >= RecognitionParameters.minimumRecoveryAngle else { return false }
            let duration = time - startedAt
            let valid = duration >= RecognitionParameters.minimumCycleDuration &&
                duration <= RecognitionParameters.maximumCycleDuration
            phase = .extended
            startedAt = time
            return valid
        }
        return false
    }
}

/// Pure temporal classifier. No Vision, camera, persistence, speech, or blocking dependencies.
nonisolated struct WorkoutRecognitionEngine {
    private(set) var currentExercise: ExerciseKind?
    private var detector = CycleDetector()
    private var nextID: UInt64 = 0
    private var lastTimestamp: TimeInterval?
    private var selectedSide: Int?
    private var sideMissingSince: TimeInterval?
    private var poseMissingSince: TimeInterval?

    mutating func resetTracking() {
        currentExercise = nil
        detector = CycleDetector()
        lastTimestamp = nil
        selectedSide = nil
        sideMissingSince = nil
        poseMissingSince = nil
        // Preserve the event sequence across resets to prevent duplicate credits.
    }

    mutating func consume(_ frame: PoseFrame) -> RecognitionUpdate {
        guard frame.timestamp.isFinite else {
            resetTracking()
            return RecognitionUpdate(exercise: currentExercise, tracking: .reposition)
        }
        if let lastTimestamp, frame.timestamp <= lastTimestamp { // Ignore duplicate/out-of-order delivery.
            return RecognitionUpdate(exercise: currentExercise, tracking: .searching)
        }
        if let lastTimestamp, frame.timestamp - lastTimestamp > RecognitionParameters.maximumFrameGap {
            resetTracking()
        }
        lastTimestamp = frame.timestamp
        guard let sample = selectSample(from: PoseFeatures.pushUpSamples(from: frame),
                                        at: frame.timestamp) else {
            if frame.cameraIsMoving {
                resetTracking()
                return RecognitionUpdate(exercise: currentExercise, tracking: .cameraMoving)
            }
            poseMissingSince = poseMissingSince ?? frame.timestamp
            if frame.timestamp - poseMissingSince! > RecognitionParameters.poseLossGracePeriod {
                resetTracking()
            }
            return RecognitionUpdate(exercise: currentExercise, tracking: .reposition)
        }
        poseMissingSince = nil
        currentExercise = .pushUp
        let completed = detector.consume(sample, at: frame.timestamp)
        var reps: [RepEvent] = []
        if completed {
            nextID += 1
            reps = [RepEvent(id: nextID, exercise: .pushUp, timestamp: frame.timestamp)]
        }
        return RecognitionUpdate(exercise: .pushUp, tracking: .tracking,
            poseReady: true, reps: reps, angles: [.pushUp: sample.angle])
    }

    private mutating func selectSample(from candidates: [ExerciseSample],
                                       at timestamp: TimeInterval) -> ExerciseSample? {
        guard !candidates.isEmpty else {
            if sideMissingSince == nil, selectedSide != nil {
                sideMissingSince = timestamp
            }
            return nil
        }

        if let selectedSide {
            if let current = candidates.first(where: { $0.side == selectedSide }) {
                sideMissingSince = nil
                return current
            }
            if sideMissingSince == nil {
                sideMissingSince = timestamp
                return nil
            }
            if let sideMissingSince,
               timestamp - sideMissingSince < RecognitionParameters.sideSwitchGracePeriod {
                return nil
            }
        }

        let replacement = candidates[0]
        selectedSide = replacement.side
        sideMissingSince = nil
        return replacement
    }
}
