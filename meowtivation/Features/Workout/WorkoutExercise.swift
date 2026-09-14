import Foundation
import simd

/// The exercises supported by the automatic workout session.
nonisolated enum WorkoutExercise: Equatable, Sendable {
    case pushUp
    case squat

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

nonisolated enum WorkoutTrackingState: Equatable, Sendable {
    case findingPosition, validatingPosition, ready, tracking
    case waitingForJoints, cameraMoving, ambiguous

    var message: String {
        switch self {
        case .findingPosition: "Get into a push-up starting position."
        case .validatingPosition: "Hold still. Checking your position."
        case .ready: "Start a push-up."
        case .tracking: "Tracking your workout"
        case .waitingForJoints: "Keep the required body joints visible."
        case .cameraMoving: "Keep the phone still against the wall."
        case .ambiguous: "Keep your movement clear."
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
    var selectedExercise: WorkoutExercise?
    var armAngles: [Int: Float] = [:]
    var didStart = false
    var reps: [WorkoutRepEvent] = []
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
