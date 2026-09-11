import AVFoundation
import Foundation
import simd
import Testing
@testable import pushapp_blocker

/// Synthetic camera-space motion. These prove the angle state machine, not Vision accuracy.
nonisolated enum WorkoutFixtures {
    static func frame(contraction: Float, time: Double) -> PoseFrame {
        let height: Float = 0.595 - contraction * 0.26
        let wrist: SIMD2<Float> = [0, 0]
        let shoulder: SIMD2<Float> = [0, height]
        let elbow: SIMD2<Float> = [sqrt(0.3 * 0.3 - height * height / 4), height / 2]

        var joints: [BodyJoint: PoseJoint] = [:]
        for (sideIndex, side) in BodyJoint.sides.enumerated() {
            let offset = SIMD2<Float>(0, Float(sideIndex) * 0.2)
            let positions = [shoulder, elbow, wrist].map { $0 + offset }
            for (index, joint) in side.prefix(3).enumerated() {
                let position = positions[index]
                joints[joint] = PoseJoint(position: position,
                    imagePoint: [0.4 + position.x * 0.3, 0.15 + position.y * 0.3],
                    confidence2D: 0.95)
            }
        }
        return PoseFrame(timestamp: time, joints: joints)
    }

    static func frame(angle: Float, time: Double) -> PoseFrame {
        let radians = angle * .pi / 180
        let elbow: SIMD2<Float> = [0.5, 0.5]
        let shoulder = elbow + SIMD2<Float>(-0.3, 0)
        let wristRadians = .pi - radians
        let wrist = elbow + SIMD2<Float>(0.3 * cos(wristRadians), 0.3 * sin(wristRadians))

        var joints: [BodyJoint: PoseJoint] = [:]
        for (sideIndex, side) in BodyJoint.sides.enumerated() {
            let offset = SIMD2<Float>(0, Float(sideIndex) * 0.2)
            let positions = [shoulder, elbow, wrist].map { $0 + offset }
            for (index, joint) in side.prefix(3).enumerated() {
                let position = positions[index]
                joints[joint] = PoseJoint(position: position,
                    imagePoint: position,
                    confidence2D: 0.95)
            }
        }
        return PoseFrame(timestamp: time, joints: joints)
    }

    static func sequence(reps: Int = 3, duration: Double = 2.4,
                         start: Double = 1, amplitude: Float = 1,
                         sampleFPS: Double = RecognitionParameters.targetFPS) -> [PoseFrame] {
        let step = 1.0 / sampleFPS
        let total = Double(reps) * duration + 0.5
        return stride(from: 0.0, through: total, by: step).map { elapsed in
            let phase = max(0, elapsed - 0.25).truncatingRemainder(dividingBy: duration) / duration
            let contraction = Float((1 - cos(phase * 2 * .pi)) / 2) * amplitude
            return frame(contraction: contraction, time: start + elapsed)
        }
    }
}

struct WorkoutRecognitionTests {
    @Test func countsOnlyAStableAngleDownThenUpCycle() {
        var engine = WorkoutRecognitionEngine()
        let events = WorkoutFixtures.sequence().flatMap { engine.consume($0).reps }

        #expect(events.count == 3)
        #expect(Set(events.map(\.id)).count == events.count)
    }

    @Test(arguments: [1.4, 4.5, 6.0])
    func supportsDifferentRepSpeeds(_ duration: Double) {
        var engine = WorkoutRecognitionEngine()
        let events = WorkoutFixtures.sequence(duration: duration).flatMap { engine.consume($0).reps }
        #expect(events.count == 3, "Push-ups at \(duration) seconds")
    }

    @Test func countsFastPushUpSampledAtThirtyFramesPerSecond() {
        var engine = WorkoutRecognitionEngine()
        let events = WorkoutFixtures.sequence(reps: 1, duration: 0.4,
                                               sampleFPS: RecognitionParameters.targetFPS)
            .flatMap { engine.consume($0).reps }

        #expect(events.count == 1)
    }

    @Test func countsFastConsecutiveRepsAfterPoseStabilization() {
        var stabilizer = PoseStabilizer()
        var engine = WorkoutRecognitionEngine()
        let frames = WorkoutFixtures.sequence(reps: 3, duration: 0.4,
                                               sampleFPS: RecognitionParameters.targetFPS).map { frame in
            var stabilized = frame
            stabilized.joints = stabilizer.stabilize(frame.joints, at: frame.timestamp)
            return stabilized
        }

        let angles = frames.compactMap { PoseFeatures.pushUpSamples(from: $0).first?.angle }
        let events = frames.flatMap { engine.consume($0).reps }
        #expect(events.count == 3, "angles: \(angles.map { Int($0) })")
    }

    @Test func countsThirtyHundredthsSecondDownAndUpCycle() {
        var engine = WorkoutRecognitionEngine()
        let frames = [
            WorkoutFixtures.frame(contraction: 0, time: 1.0),
            WorkoutFixtures.frame(contraction: 1, time: 1.15),
            WorkoutFixtures.frame(contraction: 0, time: 1.30)
        ]

        #expect(frames.flatMap { engine.consume($0).reps }.count == 1)
    }

    @Test func countsCycleThatReachesPragmaticDepth() {
        var engine = WorkoutRecognitionEngine()
        let events = WorkoutFixtures.sequence(amplitude: 0.70).flatMap { engine.consume($0).reps }
        #expect(events.count == 3)
    }

    @Test func countsAtMaximumContractedAngle() {
        var engine = WorkoutRecognitionEngine()
        let frames = [
            WorkoutFixtures.frame(angle: 160, time: 1.0),
            WorkoutFixtures.frame(angle: 90, time: 1.2),
            WorkoutFixtures.frame(angle: 160, time: 1.4)
        ]

        #expect(frames.flatMap { engine.consume($0).reps }.count == 1)
    }

    @Test func doesNotCountShallowAngleCycles() {
        var engine = WorkoutRecognitionEngine()
        let events = WorkoutFixtures.sequence(amplitude: 0.35).flatMap { engine.consume($0).reps }
        #expect(events.isEmpty)
    }

    @Test func countsWithoutDwellDuringDownAndUpMotion() {
        var engine = WorkoutRecognitionEngine()
        let frames = [
            WorkoutFixtures.frame(contraction: 0, time: 1),
            WorkoutFixtures.frame(contraction: 1, time: 1.3),
            WorkoutFixtures.frame(contraction: 0, time: 1.4)
        ]

        #expect(frames.flatMap { engine.consume($0).reps }.count == 1)
    }

    @Test func countsConsecutiveCyclesWithoutWaitingBetweenReps() {
        var engine = WorkoutRecognitionEngine()
        let frames = [
            WorkoutFixtures.frame(angle: 160, time: 1.0),
            WorkoutFixtures.frame(angle: 30, time: 1.2),
            WorkoutFixtures.frame(angle: 160, time: 1.4),
            WorkoutFixtures.frame(angle: 30, time: 1.6),
            WorkoutFixtures.frame(angle: 160, time: 1.8)
        ]

        #expect(frames.flatMap { engine.consume($0).reps }.count == 2)
    }

    @Test func heldRecoveryAngleDoesNotCreateAdditionalReps() {
        var engine = WorkoutRecognitionEngine()
        let frames = [
            WorkoutFixtures.frame(angle: 160, time: 1.0),
            WorkoutFixtures.frame(angle: 30, time: 1.2),
            WorkoutFixtures.frame(angle: 160, time: 1.4),
            WorkoutFixtures.frame(angle: 160, time: 1.8),
            WorkoutFixtures.frame(angle: 160, time: 2.2)
        ]

        #expect(frames.flatMap { engine.consume($0).reps }.count == 1)
    }

    @Test func croppedBodyWorksWithOnlyTheArmChain() {
        let frame = WorkoutFixtures.frame(contraction: 0, time: 1)
        #expect(PoseFeatures.pushUpSample(from: frame) != nil)
        #expect(frame.joints[.leftHip] == nil)
        #expect(frame.joints[.leftKnee] == nil)
        #expect(frame.joints[.leftAnkle] == nil)
    }

    @Test func prefersRightArmAndFallsBackToLeftArm() {
        var frame = WorkoutFixtures.frame(contraction: 0, time: 1)
        #expect(PoseFeatures.pushUpSample(from: frame)?.side == 0)

        frame.joints[.rightShoulder] = nil
        frame.joints[.rightElbow] = nil
        frame.joints[.rightWrist] = nil
        #expect(PoseFeatures.pushUpSample(from: frame)?.side == 1)
    }

    @Test func brieflyMissingPreferredArmDoesNotSwitchSides() {
        var engine = WorkoutRecognitionEngine()
        #expect(engine.consume(WorkoutFixtures.frame(contraction: 0, time: 1)).poseReady)

        var leftOnly = WorkoutFixtures.frame(contraction: 0, time: 1.1)
        for joint in BodyJoint.sides[0].prefix(3) { leftOnly.joints[joint] = nil }
        #expect(!engine.consume(leftOnly).poseReady)

        #expect(engine.consume(WorkoutFixtures.frame(contraction: 0, time: 1.2)).poseReady)
    }

    @Test func missingShoulderElbowOrWristMakesPoseNotReady() {
        for joint in [BodyJoint.leftShoulder, .leftElbow, .leftWrist] {
            var frame = WorkoutFixtures.frame(contraction: 0, time: 1)
            let rightJoint = BodyJoint(rawValue: joint.rawValue.replacingOccurrences(of: "left", with: "right"))!
            frame.joints[joint] = nil
            frame.joints[rightJoint] = nil
            #expect(PoseFeatures.pushUpSample(from: frame) == nil)
        }
    }

    @Test func partialAngleExcursionAndAHoldDoNotCount() {
        var partialEngine = WorkoutRecognitionEngine()
        let partial = WorkoutFixtures.sequence(amplitude: 0.03)
        #expect(partial.flatMap { partialEngine.consume($0).reps }.isEmpty)

        var holdEngine = WorkoutRecognitionEngine()
        let extended = (0..<45).map { WorkoutFixtures.frame(contraction: 0, time: 1 + Double($0) / 15) }
        let contracted = (0..<180).map { WorkoutFixtures.frame(contraction: 1, time: 5 + Double($0) / 15) }
        #expect((extended + contracted).flatMap { holdEngine.consume($0).reps }.isEmpty)
    }

    @Test func missingFramesDoNotBridgeARep() {
        var engine = WorkoutRecognitionEngine()
        let frames = WorkoutFixtures.sequence(reps: 1).filter { !(2.1...2.8).contains($0.timestamp) }
        #expect(frames.flatMap { engine.consume($0).reps }.isEmpty)
    }

    @Test func briefPoseDropoutDoesNotResetARep() {
        var engine = WorkoutRecognitionEngine()
        let frames = WorkoutFixtures.sequence(reps: 1).enumerated().map { index, frame in
            (30...31).contains(index) ? PoseFrame(timestamp: frame.timestamp, joints: [:]) : frame
        }
        #expect(frames.flatMap { engine.consume($0).reps }.count == 1)
    }

    @Test func duplicateFramesAndInvalidTimestampsDoNotCount() {
        var engine = WorkoutRecognitionEngine()
        let frames = WorkoutFixtures.sequence(reps: 1)
        var events: [PushUpRepEvent] = []
        for frame in frames {
            events += engine.consume(frame).reps
            #expect(engine.consume(frame).reps.isEmpty)
        }
        #expect(events.count == 1)
        #expect(engine.consume(WorkoutFixtures.frame(contraction: 0, time: .nan)).reps.isEmpty)
    }

    @Test func cameraMovementResetsReadiness() {
        var engine = WorkoutRecognitionEngine()
        #expect(engine.consume(WorkoutFixtures.frame(contraction: 0, time: 1)).poseReady)

        var moving = WorkoutFixtures.frame(contraction: 0, time: 2)
        moving.cameraIsMoving = true
        #expect(!engine.consume(moving).poseReady)
    }
}

@MainActor private final class TestWorkoutSpeech: WorkoutSpeaking {
    var spoken: [String] = []
    var stops = 0
    func say(_ text: String) { spoken.append(text) }
    func stop() { stops += 1 }
}

nonisolated private final class TestWorkoutCamera: WorkoutCameraControlling {
    let session = AVCaptureSession()
    var generation = 0
    var stops = 0
    func start(generation: Int, rotation: Double) { self.generation = generation }
    func stop() { stops += 1 }
    func updateRotation(_ angle: Double) { }
}

@MainActor struct WorkoutSessionTests {
    @Test func poseReadinessTracksCameraAndArmState() {
        let camera = TestWorkoutCamera(), speech = TestWorkoutSpeech()
        let model = WorkoutSessionModel(speech: speech, cameraFactory: { _ in camera })
        model.start()
        model.receive(.state(.running), generation: camera.generation)
        #expect(!model.poseReady)

        model.receive(.frame(WorkoutFixtures.frame(contraction: 0, time: 1), milliseconds: 20),
                      generation: camera.generation)
        #expect(model.poseReady)

        var incomplete = WorkoutFixtures.frame(contraction: 0, time: 2)
        incomplete.joints[.leftWrist] = nil
        incomplete.joints[.rightWrist] = nil
        model.receive(.frame(incomplete, milliseconds: 20), generation: camera.generation)
        #expect(!model.poseReady)

        model.receive(.state(.interrupted), generation: camera.generation)
        #expect(!model.poseReady)
    }

    @Test func sessionCountsPushUpsAndRejectsStaleCallbacks() {
        let camera = TestWorkoutCamera(), speech = TestWorkoutSpeech()
        let model = WorkoutSessionModel(speech: speech, cameraFactory: { _ in camera })
        model.start()
        model.receive(.state(.running), generation: camera.generation)
        for frame in WorkoutFixtures.sequence() {
            model.receive(.frame(frame, milliseconds: 20), generation: camera.generation)
        }
        #expect(model.pushUpCount == 3)

        model.receive(.state(.interrupted), generation: camera.generation)
        let pushUpCount = model.pushUpCount
        model.receive(.frame(WorkoutFixtures.frame(contraction: 0, time: 40), milliseconds: 20),
                      generation: camera.generation)
        #expect(model.pushUpCount == pushUpCount)

        model.end()
        #expect(model.hasEnded)
        #expect(camera.stops > 0)
    }
}
