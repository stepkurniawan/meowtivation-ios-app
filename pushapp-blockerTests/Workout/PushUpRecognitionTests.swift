import AVFoundation
import Foundation
import simd
import Testing
@testable import pushapp_blocker

/// Synthetic camera-space motion. These prove the angle state machine, not Vision accuracy.
nonisolated enum PushUpFixtures {
    static func calibrationFrames(start: Double = 0) -> [PoseFrame] {
        stride(from: 0.0, through: PushUpRecognitionParameters.calibrationDuration, by: 0.1).map {
            var frame = frame(contraction: 0, time: start + $0)
            for joint in PushUp.armChains[0] {
                frame.joints[joint]?.confidence2D = 0.98
            }
            return frame
        }
    }

    static func trackingEngine(visibleSide: Int? = nil) -> PushUpRecognitionEngine {
        var engine = PushUpRecognitionEngine()
        for frame in calibrationFrames() {
            _ = engine.consume(visibleSide.map { onlyArm($0, in: frame) } ?? frame)
        }
        return engine
    }

    static func frame(contraction: Float, time: Double) -> PoseFrame {
        let height: Float = 0.595 - contraction * 0.26
        let wrist: SIMD2<Float> = [0, 0]
        let shoulder: SIMD2<Float> = [0, height]
        let elbow: SIMD2<Float> = [sqrt(0.3 * 0.3 - height * height / 4), height / 2]

        var joints: [BodyJoint: PoseJoint] = [:]
        for (sideIndex, side) in PushUp.armChains.enumerated() {
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

    static func frame(rightContraction: Float, leftContraction: Float, time: Double) -> PoseFrame {
        var combined = frame(contraction: rightContraction, time: time)
        let left = frame(contraction: leftContraction, time: time)
        for joint in PushUp.armChains[1] {
            combined.joints[joint] = left.joints[joint]
        }
        return combined
    }

    static func frame(angle: Float, time: Double) -> PoseFrame {
        let radians = angle * .pi / 180
        let elbow: SIMD2<Float> = [0.5, 0.5]
        let shoulder = elbow + SIMD2<Float>(-0.3, 0)
        let wristRadians = .pi - radians
        let wrist = elbow + SIMD2<Float>(0.3 * cos(wristRadians), 0.3 * sin(wristRadians))

        var joints: [BodyJoint: PoseJoint] = [:]
        for (sideIndex, side) in PushUp.armChains.enumerated() {
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
                         sampleFPS: Double = PoseDetectionParameters.targetFPS) -> [PoseFrame] {
        let step = 1.0 / sampleFPS
        let total = Double(reps) * duration + 0.5
        return stride(from: 0.0, through: total, by: step).map { elapsed in
            let phase = max(0, elapsed - 0.25).truncatingRemainder(dividingBy: duration) / duration
            let contraction = Float((1 - cos(phase * 2 * .pi)) / 2) * amplitude
            return frame(contraction: contraction, time: start + elapsed)
        }
    }

    static func withConfidence(_ frame: PoseFrame, side: Int, confidence: Float) -> PoseFrame {
        var copy = frame
        for joint in PushUp.armChains[side] { copy.joints[joint]?.confidence2D = confidence }
        return copy
    }

    static func onlyArm(_ side: Int, in frame: PoseFrame) -> PoseFrame {
        var copy = frame
        for otherSide in PushUp.armChains.indices where otherSide != side {
            for joint in PushUp.armChains[otherSide] {
                copy.joints[joint] = nil
            }
        }
        return copy
    }

}

struct PushUpRecognitionTests {
    @Test func pushUpCameraTargetUsesTheCentreOfOneReliableArm() {
        var frame = PushUpFixtures.frame(contraction: 0, time: 1)
        for joint in PushUp.armChains[1] { frame.joints[joint] = nil }

        let target = PushUp.cameraTarget(from: frame.joints)
        let arm = PushUp.armChains[0]
        let expected = (frame.joints[arm[0]]!.imagePoint + frame.joints[arm[1]]!.imagePoint +
                        frame.joints[arm[2]]!.imagePoint) / 3

        #expect(target == expected)
    }

    @Test func pushUpCameraTargetRejectsIncompleteOrLowConfidenceArms() {
        var frame = PushUpFixtures.frame(contraction: 0, time: 1)
        for arm in PushUp.armChains {
            frame.joints[arm[2]] = nil
        }
        #expect(PushUp.cameraTarget(from: frame.joints) == nil)

        frame = PushUpFixtures.frame(contraction: 0, time: 1)
        for arm in PushUp.armChains {
            for joint in arm { frame.joints[joint]?.confidence2D = 0.49 }
        }
        #expect(PushUp.cameraTarget(from: frame.joints) == nil)
    }

    @Test func countsOnlyAStableAngleDownThenUpCycle() {
        var engine = PushUpFixtures.trackingEngine()
        let events = PushUpFixtures.sequence().flatMap { engine.consume($0).reps }

        #expect(events.count == 3)
        #expect(Set(events.map(\.id)).count == events.count)
    }

    @Test(arguments: [1.4, 4.5, 6.0])
    func supportsDifferentRepSpeeds(_ duration: Double) {
        var engine = PushUpFixtures.trackingEngine()
        let events = PushUpFixtures.sequence(duration: duration).flatMap { engine.consume($0).reps }
        #expect(events.count == 3, "Push-ups at \(duration) seconds")
    }

    @Test func countsFastPushUpSampledAtThirtyFramesPerSecond() {
        var engine = PushUpFixtures.trackingEngine()
        let events = PushUpFixtures.sequence(reps: 1, duration: 0.4,
                                               sampleFPS: PoseDetectionParameters.targetFPS)
            .flatMap { engine.consume($0).reps }

        #expect(events.count == 1)
    }

    @Test func countsFastConsecutiveRepsAfterPoseStabilization() {
        var stabilizer = PoseStabilizer()
        var engine = PushUpFixtures.trackingEngine()
        let frames = PushUpFixtures.sequence(reps: 3, duration: 0.4,
                                               sampleFPS: PoseDetectionParameters.targetFPS).map { frame in
            var stabilized = frame
            stabilized.joints = stabilizer.stabilize(frame.joints, tracking: PushUp.trackedJoints, at: frame.timestamp)
            return stabilized
        }

        let angles = frames.compactMap { PushUpPose.samples(from: $0).first?.angle }
        let events = frames.flatMap { engine.consume($0).reps }
        #expect(events.count == 3, "angles: \(angles.map { Int($0) })")
    }

    @Test func countsThirtyHundredthsSecondDownAndUpCycle() {
        var engine = PushUpFixtures.trackingEngine()
        let frames = [
            PushUpFixtures.frame(contraction: 0, time: 1.1),
            PushUpFixtures.frame(contraction: 1, time: 1.25),
            PushUpFixtures.frame(contraction: 0, time: 1.40)
        ]

        #expect(frames.flatMap { engine.consume($0).reps }.count == 1)
    }

    @Test func countsCycleThatReachesPragmaticDepth() {
        var engine = PushUpFixtures.trackingEngine()
        let events = PushUpFixtures.sequence(amplitude: 0.70).flatMap { engine.consume($0).reps }
        #expect(events.count == 3)
    }

    @Test func countsAtMaximumContractedAngle() {
        var engine = PushUpFixtures.trackingEngine()
        let frames = [
            PushUpFixtures.frame(angle: 160, time: 1.1),
            PushUpFixtures.frame(angle: 90, time: 1.3),
            PushUpFixtures.frame(angle: 160, time: 1.5)
        ]

        #expect(frames.flatMap { engine.consume($0).reps }.count == 1)
    }

    @Test func doesNotCountShallowAngleCycles() {
        var engine = PushUpFixtures.trackingEngine()
        let events = PushUpFixtures.sequence(amplitude: 0.35).flatMap { engine.consume($0).reps }
        #expect(events.isEmpty)
    }

    @Test func countsWithoutDwellDuringDownAndUpMotion() {
        var engine = PushUpFixtures.trackingEngine()
        let frames = [
            PushUpFixtures.frame(contraction: 0, time: 1.1),
            PushUpFixtures.frame(contraction: 1, time: 1.4),
            PushUpFixtures.frame(contraction: 0, time: 1.5)
        ]

        #expect(frames.flatMap { engine.consume($0).reps }.count == 1)
    }

    @Test func countsConsecutiveCyclesWithoutWaitingBetweenReps() {
        var engine = PushUpFixtures.trackingEngine()
        let frames = [
            PushUpFixtures.frame(angle: 160, time: 1.1),
            PushUpFixtures.frame(angle: 30, time: 1.3),
            PushUpFixtures.frame(angle: 160, time: 1.5),
            PushUpFixtures.frame(angle: 30, time: 1.7),
            PushUpFixtures.frame(angle: 160, time: 1.9)
        ]

        #expect(frames.flatMap { engine.consume($0).reps }.count == 2)
    }

    @Test func heldRecoveryAngleDoesNotCreateAdditionalReps() {
        var engine = PushUpFixtures.trackingEngine()
        let frames = [
            PushUpFixtures.frame(angle: 160, time: 1.1),
            PushUpFixtures.frame(angle: 30, time: 1.3),
            PushUpFixtures.frame(angle: 160, time: 1.5),
            PushUpFixtures.frame(angle: 160, time: 1.8),
            PushUpFixtures.frame(angle: 160, time: 2.2)
        ]

        #expect(frames.flatMap { engine.consume($0).reps }.count == 1)
    }

    @Test func croppedBodyWorksWithOnlyTheArmChain() {
        let frame = PushUpFixtures.frame(contraction: 0, time: 1)
        #expect(PushUpPose.sample(from: frame) != nil)
        #expect(frame.joints[.leftHip] == nil)
        #expect(frame.joints[.leftKnee] == nil)
        #expect(frame.joints[.leftAnkle] == nil)
    }

    @Test func pushUpSamplesIncludesBothUsableArms() {
        let frame = PushUpFixtures.frame(contraction: 0, time: 1)
        #expect(PushUpPose.samples(from: frame).map(\.side) == [0, 1])
    }

    @Test(arguments: [0, 1])
    func eitherArmCanCalibrateAndCountARep(_ side: Int) {
        var engine = PushUpFixtures.trackingEngine(visibleSide: side)
        let frames = [
            PushUpFixtures.onlyArm(side, in: PushUpFixtures.frame(contraction: 0, time: 1.1)),
            PushUpFixtures.onlyArm(side, in: PushUpFixtures.frame(contraction: 1, time: 1.3)),
            PushUpFixtures.onlyArm(side, in: PushUpFixtures.frame(contraction: 0, time: 1.5))
        ]

        #expect(frames.flatMap { engine.consume($0).reps }.count == 1)
    }

    @Test func oneArmCanCountWhileTheOtherIsMissing() {
        var engine = PushUpFixtures.trackingEngine()
        let frames = [
            PushUpFixtures.onlyArm(1, in: PushUpFixtures.frame(contraction: 0, time: 1.1)),
            PushUpFixtures.onlyArm(1, in: PushUpFixtures.frame(contraction: 1, time: 1.3)),
            PushUpFixtures.onlyArm(1, in: PushUpFixtures.frame(contraction: 0, time: 1.5))
        ]

        let updates = frames.map { engine.consume($0) }
        let allUpdatesReady = updates.allSatisfy(\.poseReady)
        #expect(allUpdatesReady)
        #expect(updates.flatMap(\.reps).count == 1)
    }

    @Test func simultaneousArmCompletionsCountOnce() {
        var engine = PushUpFixtures.trackingEngine()
        let frames = [
            PushUpFixtures.frame(contraction: 0, time: 1.1),
            PushUpFixtures.frame(contraction: 1, time: 1.3),
            PushUpFixtures.frame(contraction: 0, time: 1.5)
        ]

        #expect(frames.flatMap { engine.consume($0).reps }.count == 1)
    }

    @Test func completionFromOtherArmWithinDeduplicationWindowIsIgnored() {
        var engine = PushUpFixtures.trackingEngine()
        let frames = [
            PushUpFixtures.frame(rightContraction: 0, leftContraction: 0, time: 1.1),
            PushUpFixtures.frame(rightContraction: 1, leftContraction: 0, time: 1.3),
            PushUpFixtures.frame(rightContraction: 0, leftContraction: 0, time: 1.5),
            PushUpFixtures.frame(rightContraction: 0, leftContraction: 1, time: 1.55),
            PushUpFixtures.frame(rightContraction: 0, leftContraction: 0, time: 1.7)
        ]

        #expect(frames.flatMap { engine.consume($0).reps }.count == 1)
    }

    @Test func completionFromOtherArmAfterDeduplicationWindowCounts() {
        var engine = PushUpFixtures.trackingEngine()
        let frames = [
            PushUpFixtures.frame(rightContraction: 0, leftContraction: 0, time: 1.1),
            PushUpFixtures.frame(rightContraction: 1, leftContraction: 0, time: 1.3),
            PushUpFixtures.frame(rightContraction: 0, leftContraction: 0, time: 1.5),
            PushUpFixtures.frame(rightContraction: 0, leftContraction: 1, time: 1.65),
            PushUpFixtures.frame(rightContraction: 0, leftContraction: 0, time: 1.85)
        ]

        #expect(frames.flatMap { engine.consume($0).reps }.count == 2)
    }

    @Test func armLossLongerThanGraceDoesNotBridgeThatArmsRep() {
        var engine = PushUpFixtures.trackingEngine()
        _ = engine.consume(PushUpFixtures.frame(rightContraction: 0, leftContraction: 0, time: 1.1))
        _ = engine.consume(PushUpFixtures.frame(rightContraction: 1, leftContraction: 0, time: 1.3))
        #expect(engine.consume(PushUpFixtures.onlyArm(1, in: PushUpFixtures.frame(contraction: 0, time: 1.4))).reps.isEmpty)
        #expect(engine.consume(PushUpFixtures.onlyArm(1, in: PushUpFixtures.frame(contraction: 0, time: 1.66))).reps.isEmpty)

        let recovered = engine.consume(PushUpFixtures.frame(rightContraction: 0, leftContraction: 0, time: 1.7))
        #expect(recovered.reps.isEmpty)
        #expect(recovered.poseReady)
    }

    @Test func missingShoulderElbowOrWristMakesPoseNotReady() {
        for joint in [BodyJoint.leftShoulder, .leftElbow, .leftWrist] {
            var frame = PushUpFixtures.frame(contraction: 0, time: 1)
            let rightJoint = BodyJoint(rawValue: joint.rawValue.replacingOccurrences(of: "left", with: "right"))!
            frame.joints[joint] = nil
            frame.joints[rightJoint] = nil
            #expect(PushUpPose.sample(from: frame) == nil)
        }
    }

    @Test func partialAngleExcursionAndAHoldDoNotCount() {
        var partialEngine = PushUpFixtures.trackingEngine()
        let partial = PushUpFixtures.sequence(amplitude: 0.03)
        #expect(partial.flatMap { partialEngine.consume($0).reps }.isEmpty)

        var holdEngine = PushUpFixtures.trackingEngine()
        let extended = (0..<45).map { PushUpFixtures.frame(contraction: 0, time: 1 + Double($0) / 15) }
        let contracted = (0..<180).map { PushUpFixtures.frame(contraction: 1, time: 5 + Double($0) / 15) }
        #expect((extended + contracted).flatMap { holdEngine.consume($0).reps }.isEmpty)
    }

    @Test func missingFramesDoNotBridgeARep() {
        var engine = PushUpFixtures.trackingEngine()
        let frames = PushUpFixtures.sequence(reps: 1).filter { !(2.1...2.8).contains($0.timestamp) }
        #expect(frames.flatMap { engine.consume($0).reps }.isEmpty)
    }

    @Test func missingPoseDoesNotBridgeARep() {
        var engine = PushUpFixtures.trackingEngine()
        let frames = PushUpFixtures.sequence(reps: 1).enumerated().map { index, frame in
            (30...38).contains(index) ? PoseFrame(timestamp: frame.timestamp, joints: [:]) : frame
        }
        #expect(frames.flatMap { engine.consume($0).reps }.isEmpty)
    }

    @Test func duplicateFramesAndInvalidTimestampsDoNotCount() {
        var engine = PushUpFixtures.trackingEngine()
        let frames = PushUpFixtures.sequence(reps: 1)
        var events: [PushUpRepEvent] = []
        for frame in frames {
            events += engine.consume(frame).reps
            #expect(engine.consume(frame).reps.isEmpty)
        }
        #expect(events.count == 1)
        #expect(engine.consume(PushUpFixtures.frame(contraction: 0, time: .nan)).reps.isEmpty)
    }

    @Test func cameraMovementResetsReadiness() {
        var engine = PushUpFixtures.trackingEngine()
        #expect(engine.consume(PushUpFixtures.frame(contraction: 0, time: 1.1)).poseReady)

        var moving = PushUpFixtures.frame(contraction: 0, time: 1.2)
        moving.cameraIsMoving = true
        #expect(!engine.consume(moving).poseReady)
    }

    @Test func requiresAnExtendedStillPositionForOneSecondBeforeStarting() {
        var engine = PushUpRecognitionEngine()
        var bent = PushUpFixtures.frame(angle: 90, time: 0)
        bent = PushUpFixtures.withConfidence(bent, side: 0, confidence: 0.98)
        #expect(engine.consume(bent).tracking == .findingPosition)

        let early = PushUpFixtures.withConfidence(PushUpFixtures.frame(angle: 160, time: 0.5), side: 0, confidence: 0.98)
        #expect(engine.consume(early).tracking == .validatingPosition)
        let halfway = PushUpFixtures.withConfidence(PushUpFixtures.frame(angle: 160, time: 1.0), side: 0, confidence: 0.98)
        #expect(!engine.consume(halfway).didStart)
        let ready = PushUpFixtures.withConfidence(PushUpFixtures.frame(angle: 160, time: 1.5), side: 0, confidence: 0.98)
        #expect(engine.consume(ready).didStart)
    }

    @Test func bothArmsCanFinishCalibrationTogether() {
        var engine = PushUpRecognitionEngine()
        var update = PushUpRecognitionUpdate(tracking: .findingPosition)
        for time in stride(from: 0.0, through: 1.0, by: 0.1) {
            update = engine.consume(PushUpFixtures.frame(angle: 160, time: time))
        }
        #expect(update.tracking == .ready)
        #expect(update.didStart)
        #expect(update.armAngles.keys.sorted() == [0, 1])
    }

    @Test func jitterRestartsCalibration() {
        var engine = PushUpRecognitionEngine()
        let first = PushUpFixtures.withConfidence(PushUpFixtures.frame(angle: 160, time: 0), side: 0, confidence: 0.98)
        var onlyRight = first
        for joint in PushUp.armChains[1] { onlyRight.joints[joint] = nil }
        #expect(engine.consume(onlyRight).tracking == .validatingPosition)
        var shifted = PushUpFixtures.withConfidence(PushUpFixtures.frame(angle: 160, time: 0.5), side: 0, confidence: 0.98)
        for joint in PushUp.armChains[1] { shifted.joints[joint] = nil }
        for joint in PushUp.armChains[0] {
            shifted.joints[joint]?.position.x += 0.1
            shifted.joints[joint]?.imagePoint.x += 0.1
        }
        #expect(engine.consume(shifted).tracking == .findingPosition)
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
    var poseConfigurationUpdates = 0
    func start(generation: Int, rotation: Double) { self.generation = generation }
    func stop() { stops += 1 }
    func updateRotation(_ angle: Double) { }
    func updatePoseConfiguration(_ configuration: WorkoutPoseConfiguration) {
        poseConfigurationUpdates += 1
    }
}

@MainActor struct PushUpSessionTests {
    @Test func poseReadinessTracksCameraAndArmState() {
        let camera = TestWorkoutCamera(), speech = TestWorkoutSpeech()
        let model = PushUpSessionModel(speech: speech, cameraFactory: { _ in camera })
        model.start()
        model.receive(.state(.running), generation: camera.generation)
        #expect(!model.poseReady)

        for frame in PushUpFixtures.calibrationFrames() {
            model.receive(.frame(frame, milliseconds: 20), generation: camera.generation)
        }
        #expect(model.poseReady)

        var incomplete = PushUpFixtures.frame(contraction: 0, time: 2)
        incomplete.joints[.leftWrist] = nil
        incomplete.joints[.rightWrist] = nil
        model.receive(.frame(incomplete, milliseconds: 20), generation: camera.generation)
        #expect(!model.poseReady)

        model.receive(.state(.interrupted), generation: camera.generation)
        #expect(!model.poseReady)
    }

    @Test func sessionCountsPushUpsAndRejectsStaleCallbacks() {
        let camera = TestWorkoutCamera(), speech = TestWorkoutSpeech()
        let model = PushUpSessionModel(speech: speech, cameraFactory: { _ in camera })
        model.start()
        model.receive(.state(.running), generation: camera.generation)
        for frame in PushUpFixtures.calibrationFrames() {
            model.receive(.frame(frame, milliseconds: 20), generation: camera.generation)
        }
        for frame in PushUpFixtures.sequence() {
            model.receive(.frame(frame, milliseconds: 20), generation: camera.generation)
        }
        #expect(model.pushUpCount == 3)
        #expect(camera.poseConfigurationUpdates == 1)

        model.receive(.state(.interrupted), generation: camera.generation)
        let pushUpCount = model.pushUpCount
        model.receive(.frame(PushUpFixtures.frame(contraction: 0, time: 40), milliseconds: 20),
                      generation: camera.generation)
        #expect(model.pushUpCount == pushUpCount)

        model.end()
        #expect(model.hasEnded)
        #expect(camera.stops > 0)
    }

    @Test func sessionShowsAndSpeaksTheStartCueOnlyAfterCalibration() {
        let camera = TestWorkoutCamera(), speech = TestWorkoutSpeech()
        let model = PushUpSessionModel(speech: speech, cameraFactory: { _ in camera })
        model.start()
        model.receive(.state(.running), generation: camera.generation)

        for frame in PushUpFixtures.calibrationFrames() {
            model.receive(.frame(frame, milliseconds: 20), generation: camera.generation)
        }

        #expect(model.startCueVisible)
        #expect(speech.spoken == ["Start!"])
    }

    @Test func mutedSessionStillShowsTheStartCue() {
        let camera = TestWorkoutCamera(), speech = TestWorkoutSpeech()
        let model = PushUpSessionModel(speech: speech, cameraFactory: { _ in camera })
        model.start()
        model.toggleMute()
        model.receive(.state(.running), generation: camera.generation)

        for frame in PushUpFixtures.calibrationFrames() {
            model.receive(.frame(frame, milliseconds: 20), generation: camera.generation)
        }

        #expect(model.startCueVisible)
        #expect(speech.spoken.isEmpty)
    }
}
