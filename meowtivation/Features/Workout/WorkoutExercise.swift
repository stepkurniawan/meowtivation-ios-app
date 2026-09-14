import Foundation
import simd

/// The exercises a user can choose for a workout session.
nonisolated enum WorkoutExercise: String, CaseIterable, Codable, Hashable, Identifiable, Sendable {
    case pushUp
    case squat

    var id: Self {
        self
    }

    var title: String {
        switch self {
        case .pushUp: PushUp.title
        case .squat: Squat.title
        }
    }

    var placement: String {
        switch self {
        case .pushUp: PushUp.placement
        case .squat: Squat.placement
        }
    }

    var poseConfiguration: WorkoutPoseConfiguration {
        switch self {
        case .pushUp: PushUp.poseConfiguration
        case .squat: Squat.poseConfiguration
        }
    }
}

/// The reason a workout session was started, which controls how recognized reps are recorded.
nonisolated enum WorkoutSessionMode: Equatable, Sendable {
    case daily
    case extra
}

nonisolated enum WorkoutTrackingState: Equatable, Sendable {
    case findingPosition, validatingPosition, ready, tracking
    case waitingForJoints, cameraMoving

    func message(for exercise: WorkoutExercise) -> String {
        switch self {
        case .findingPosition: "Get into a \(exercise.title.lowercased()) starting position."
        case .validatingPosition: "Hold still. Checking your position."
        case .ready: "Start a \(exercise.title.lowercased())."
        case .tracking: "Tracking your workout"
        case .waitingForJoints: "Keep the required body joints visible."
        case .cameraMoving: "Keep the phone still against the wall."
        }
    }
}

nonisolated struct WorkoutRepEvent: Identifiable, Sendable {
    let id: UInt64
    let timestamp: TimeInterval
}

nonisolated struct WorkoutRecognitionUpdate: Sendable {
    var tracking: WorkoutTrackingState
    var poseReady = false
    var jointAngles: [Int: Float] = [:]
    var didStart = false
    var reps: [WorkoutRepEvent] = []
}

/// Routes frames to the recognizer chosen before the session starts.
/// Keeping the cases explicit avoids a speculative shared recognizer protocol.
nonisolated enum WorkoutRecognitionEngine {
    case pushUp(PushUpRecognitionEngine)
    case squat(SquatRecognitionEngine)

    init(exercise: WorkoutExercise) {
        switch exercise {
        case .pushUp: self = .pushUp(PushUpRecognitionEngine())
        case .squat: self = .squat(SquatRecognitionEngine())
        }
    }

    mutating func resetTracking() {
        switch self {
        case var .pushUp(engine):
            engine.resetTracking()
            self = .pushUp(engine)
        case var .squat(engine):
            engine.resetTracking()
            self = .squat(engine)
        }
    }

    mutating func consume(_ frame: PoseFrame) -> WorkoutRecognitionUpdate {
        switch self {
        case var .pushUp(engine):
            let update = engine.consume(frame)
            self = .pushUp(engine)
            return WorkoutRecognitionUpdate(tracking: update.tracking.workoutState,
                                            poseReady: update.poseReady,
                                            jointAngles: update.armAngles,
                                            didStart: update.didStart,
                                            reps: update.reps.map {
                                                WorkoutRepEvent(id: $0.id, timestamp: $0.timestamp)
                                            })
        case var .squat(engine):
            let update = engine.consume(frame)
            self = .squat(engine)
            return WorkoutRecognitionUpdate(tracking: update.tracking.workoutState,
                                            poseReady: update.poseReady,
                                            jointAngles: update.kneeAngles,
                                            didStart: update.didStart,
                                            reps: update.reps.map {
                                                WorkoutRepEvent(id: $0.id, timestamp: $0.timestamp)
                                            })
        }
    }
}

nonisolated extension PushUpTrackingState {
    var workoutState: WorkoutTrackingState {
        switch self {
        case .findingPosition: .findingPosition
        case .validatingPosition: .validatingPosition
        case .ready: .ready
        case .tracking: .tracking
        case .waitingForArm: .waitingForJoints
        case .cameraMoving: .cameraMoving
        }
    }
}

nonisolated extension SquatTrackingState {
    var workoutState: WorkoutTrackingState {
        switch self {
        case .findingPosition: .findingPosition
        case .validatingPosition: .validatingPosition
        case .ready: .ready
        case .tracking: .tracking
        case .waitingForLeg: .waitingForJoints
        case .cameraMoving: .cameraMoving
        }
    }
}
