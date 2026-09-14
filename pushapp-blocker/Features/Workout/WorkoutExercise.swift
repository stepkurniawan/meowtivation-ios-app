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

nonisolated extension WorkoutPoseConfiguration {
    /// The setup configuration keeps both candidate exercises available until
    /// the first valid repetition identifies the workout.
    static let automatic: WorkoutPoseConfiguration = {
        let tracked = PushUp.trackedJoints + Squat.trackedJoints
        let bones = PushUp.bones + Squat.bones
        return WorkoutPoseConfiguration(trackedJoints: tracked,
                                        bones: bones,
                                        cameraTarget: { joints in
                                            let points = tracked.compactMap { joint -> SIMD2<Float>? in
                                                guard let value = joints[joint], value.confidence2D >= 0.5,
                                                      value.imagePoint.x.isFinite, value.imagePoint.y.isFinite,
                                                      (0.0 ... 1.0).contains(value.imagePoint.x),
                                                      (0.0 ... 1.0).contains(value.imagePoint.y) else { return nil }
                                                return value.imagePoint
                                            }
                                            guard !points.isEmpty else { return nil }
                                            return points.reduce(.zero, +) / Float(points.count)
                                        })
    }()
}

nonisolated enum WorkoutTrackingState: Equatable, Sendable {
    case findingPosition, validatingPosition, ready, tracking
    case waitingForJoints, cameraMoving, ambiguous

    var message: String {
        switch self {
        case .findingPosition: "Get into a push-up or squat starting position."
        case .validatingPosition: "Hold still. Checking your position."
        case .ready: "Start a push-up or squat."
        case .tracking: "Tracking your workout"
        case .waitingForJoints: "Keep the required body joints visible."
        case .cameraMoving: "Keep the phone still against the wall."
        case .ambiguous: "Keep one exercise movement clear."
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
    var suggestedExercise: WorkoutExercise?
    var selectedExercise: WorkoutExercise?
    var armAngles: [Int: Float] = [:]
    var kneeAngles: [Int: Float] = [:]
    var didStart = false
    var reps: [WorkoutRepEvent] = []
}

/// Runs both exercise recognizers until the first unambiguous valid rep.
/// The suggestion is only guidance; the completed rep is authoritative.
nonisolated struct AutomaticWorkoutRecognitionEngine {
    private var pushUp = PushUpRecognitionEngine()
    private var squat = SquatRecognitionEngine()
    private var selected: WorkoutExercise?
    private var nextID: UInt64 = 0
    private var squatMotionActive = false
    private var lastSquatMotionAt = -Double.infinity

    var selectedExercise: WorkoutExercise? {
        selected
    }

    mutating func resetTracking() {
        pushUp.resetTracking()
        squat.resetTracking()
        squatMotionActive = false
        lastSquatMotionAt = -Double.infinity
    }

    mutating func resetSession() {
        resetTracking()
        selected = nil
        nextID = 0
    }

    // The automatic selector intentionally keeps both recognizers in lockstep.
    // swiftlint:disable:next function_body_length
    mutating func consume(_ frame: PoseFrame) -> WorkoutRecognitionUpdate {
        if let selected {
            switch selected {
            case .pushUp:
                return update(from: pushUp.consume(frame), selected: selected)
            case .squat:
                return update(from: squat.consume(frame), selected: selected)
            }
        }

        if frame.cameraIsMoving {
            squatMotionActive = false
            lastSquatMotionAt = -Double.infinity
        }
        let priorSquatMotion = squatMotionActive
        let squatIsFlexed = SquatPose.samples(from: frame).contains {
            $0.angle < SquatRecognitionParameters.motionAngle
        }
        if squatIsFlexed {
            squatMotionActive = true
            lastSquatMotionAt = frame.timestamp
        } else if squatMotionActive,
                  frame.timestamp - lastSquatMotionAt > SquatRecognitionParameters.legDropoutGraceDuration
        {
            squatMotionActive = false
        }
        if squatIsFlexed && !priorSquatMotion {
            // Discard an arm cycle that started before a clear squat began.
            // Both engines still consume this frame; the reset only prevents a
            // stale push-up claim from winning the automatic selection.
            pushUp.resetTracking()
        }

        let pushUpdate = pushUp.consume(frame)
        let squatUpdate = squat.consume(frame)
        let suggestion = InitialPoseClassifier.suggestion(from: frame)
        let pushClaims = !pushUpdate.reps.isEmpty && !priorSquatMotion && !squatMotionActive
        let squatClaims = !squatUpdate.reps.isEmpty

        if pushClaims != squatClaims {
            if pushClaims {
                selected = .pushUp
                return update(from: pushUpdate, selected: .pushUp,
                              suggestion: suggestion, reps: pushUpdate.reps.count)
            }
            selected = .squat
            return update(from: squatUpdate, selected: .squat,
                          suggestion: suggestion, reps: squatUpdate.reps.count)
        }

        if pushClaims && squatClaims {
            // A simultaneous claim is not enough evidence to choose an exercise.
            // Require a fresh, unambiguous movement instead of applying an
            // arbitrary exercise preference.
            pushUp.resetTracking()
            squat.resetTracking()
            return WorkoutRecognitionUpdate(tracking: .ambiguous,
                                            suggestedExercise: suggestion)
        }

        let tracking = combinedTracking(pushUpdate: pushUpdate, squatUpdate: squatUpdate)
        return WorkoutRecognitionUpdate(tracking: tracking,
                                        poseReady: pushUpdate.poseReady || squatUpdate.poseReady,
                                        suggestedExercise: suggestion,
                                        armAngles: pushUpdate.armAngles,
                                        kneeAngles: squatUpdate.kneeAngles,
                                        didStart: pushUpdate.didStart || squatUpdate.didStart)
    }

    private func combinedTracking(pushUpdate: PushUpRecognitionUpdate,
                                  squatUpdate: SquatRecognitionUpdate) -> WorkoutTrackingState
    {
        if pushUpdate.tracking == .cameraMoving || squatUpdate.tracking == .cameraMoving {
            return .cameraMoving
        }
        if pushUpdate.didStart || squatUpdate.didStart {
            return .ready
        }
        if pushUpdate.tracking == .validatingPosition || squatUpdate.tracking == .validatingPosition {
            return .validatingPosition
        }
        if pushUpdate.tracking == .tracking || squatUpdate.tracking == .tracking {
            return .tracking
        }
        if pushUpdate.tracking == .waitingForArm || squatUpdate.tracking == .waitingForLeg {
            return .waitingForJoints
        }
        return .findingPosition
    }

    private mutating func update(from update: PushUpRecognitionUpdate,
                                 selected exercise: WorkoutExercise,
                                 suggestion: WorkoutExercise? = nil,
                                 reps: Int? = nil) -> WorkoutRecognitionUpdate
    {
        let events = reps.map { makeEvents(count: $0, timestamp: update.reps.last?.timestamp ?? 0) }
        return WorkoutRecognitionUpdate(tracking: update.tracking.workoutState,
                                        poseReady: update.poseReady,
                                        suggestedExercise: suggestion ?? exercise,
                                        selectedExercise: exercise,
                                        armAngles: update.armAngles,
                                        didStart: update.didStart,
                                        reps: events ?? update.reps.map { makeEvent(timestamp: $0.timestamp) })
    }

    private mutating func update(from update: SquatRecognitionUpdate,
                                 selected exercise: WorkoutExercise,
                                 suggestion: WorkoutExercise? = nil,
                                 reps: Int? = nil) -> WorkoutRecognitionUpdate
    {
        let events = reps.map { makeEvents(count: $0, timestamp: update.reps.last?.timestamp ?? 0) }
        return WorkoutRecognitionUpdate(tracking: update.tracking.workoutState,
                                        poseReady: update.poseReady,
                                        suggestedExercise: suggestion ?? exercise,
                                        selectedExercise: exercise,
                                        kneeAngles: update.kneeAngles,
                                        didStart: update.didStart,
                                        reps: events ?? update.reps.map { makeEvent(timestamp: $0.timestamp) })
    }

    private mutating func makeEvent(timestamp: TimeInterval) -> WorkoutRepEvent {
        nextID += 1
        return WorkoutRepEvent(id: nextID, timestamp: timestamp)
    }

    private mutating func makeEvents(count: Int, timestamp: TimeInterval) -> [WorkoutRepEvent] {
        (0 ..< count).map { _ in makeEvent(timestamp: timestamp) }
    }
}

private nonisolated extension PushUpTrackingState {
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

private nonisolated extension SquatTrackingState {
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

/// A lightweight starting-pose hint. It is intentionally advisory: the first
/// completed rep remains the source of truth for exercise selection.
nonisolated enum InitialPoseClassifier {
    private static let dominantAxisRatio: Float = 1.7

    static func suggestion(from frame: PoseFrame) -> WorkoutExercise? {
        guard !frame.cameraIsMoving else { return nil }
        let pushUp = PushUp.armChains.indices.contains { side in
            let chain = PushUp.armChains[side]
            guard let shoulder = usable(chain[0], in: frame),
                  let elbow = usable(chain[1], in: frame),
                  let wrist = usable(chain[2], in: frame),
                  let hip = usable(side == 0 ? .rightHip : .leftHip, in: frame) else { return false }
            let torso = shoulder.position - hip.position
            let elbowAngle = PoseFeatures.angle(shoulder.position, elbow.position, wrist.position)
            return elbowAngle + PushUpRecognitionParameters.angleTolerance >= PushUpRecognitionParameters
                .minimumRecoveryAngle &&
                abs(torso.x) >= abs(torso.y) * dominantAxisRatio
        }
        let squat = Squat.legChains.indices.contains { side in
            let chain = Squat.legChains[side]
            guard let hip = usable(chain[0], in: frame),
                  let knee = usable(chain[1], in: frame),
                  let ankle = usable(chain[2], in: frame),
                  let shoulder = usable(side == 0 ? .rightShoulder : .leftShoulder, in: frame) else { return false }
            let torso = shoulder.position - hip.position
            let kneeAngle = PoseFeatures.angle(hip.position, knee.position, ankle.position)
            return kneeAngle + SquatRecognitionParameters.angleTolerance >= SquatRecognitionParameters
                .minimumRecoveryAngle &&
                abs(torso.y) >= abs(torso.x) * dominantAxisRatio
        }
        let result: WorkoutExercise?
        switch (pushUp, squat) {
        case (true, false): result = .pushUp
        case (false, true): result = .squat
        default: result = nil
        }
        return result
    }

    private static func usable(_ joint: BodyJoint, in frame: PoseFrame) -> PoseJoint? {
        guard let value = frame.joints[joint], value.isUsable else { return nil }
        return value
    }
}
