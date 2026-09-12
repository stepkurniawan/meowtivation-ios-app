import Foundation
import simd
import Testing
@testable import pushapp_blocker

nonisolated enum SquatFixtures {
    static func frame(angle: Float, time: Double, visibleSide: Int? = nil) -> PoseFrame {
        frame(angles: [angle, angle], time: time, visibleSide: visibleSide)
    }

    static func frame(angles: [Float], time: Double, visibleSide: Int? = nil) -> PoseFrame {
        precondition(angles.count == Squat.legChains.count)
        let knee: SIMD2<Float> = [0.5, 0.5]

        var joints: [BodyJoint: PoseJoint] = [:]
        for (sideIndex, leg) in Squat.legChains.enumerated() {
            guard visibleSide == nil || visibleSide == sideIndex else { continue }
            let radians = angles[sideIndex] * .pi / 180
            let hip = knee + SIMD2<Float>(-0.3, 0)
            let ankleRadians = .pi - radians
            let ankle = knee + SIMD2<Float>(0.3 * cos(ankleRadians),
                                            0.3 * sin(ankleRadians))
            let offset = SIMD2<Float>(0, Float(sideIndex) * 0.1)
            let positions = [hip, knee, ankle].map { $0 + offset }
            for (index, joint) in leg.enumerated() {
                let position = positions[index]
                joints[joint] = PoseJoint(position: position,
                                          imagePoint: position,
                                          confidence2D: 0.95)
            }
        }
        return PoseFrame(timestamp: time, joints: joints)
    }

    static func calibrationFrames(visibleSide: Int? = nil) -> [PoseFrame] {
        stride(from: 0.0, through: SquatRecognitionParameters.calibrationDuration, by: 0.1).map {
            frame(angle: 170, time: $0, visibleSide: visibleSide)
        }
    }

    static func trackingEngine(visibleSide: Int? = nil) -> SquatRecognitionEngine {
        var engine = SquatRecognitionEngine()
        for frame in calibrationFrames(visibleSide: visibleSide) {
            _ = engine.consume(frame)
        }
        return engine
    }
}

struct SquatRecognitionTests {
    @Test func extractsKneeAngleFromUsableLegs() {
        let samples = SquatPose.samples(from: SquatFixtures.frame(angle: 170, time: 0))

        #expect(samples.count == 2)
        #expect(samples.allSatisfy { abs($0.angle - 170) < 0.1 })
    }

    @Test func rejectsMissingOrUnusableRequiredJoints() {
        var frame = SquatFixtures.frame(angle: 170, time: 0, visibleSide: 0)
        frame.joints[.rightAnkle] = nil
        #expect(SquatPose.samples(from: frame).isEmpty)

        frame = SquatFixtures.frame(angle: 170, time: 0, visibleSide: 0)
        frame.joints[.rightKnee]?.confidence2D = 0.2
        #expect(SquatPose.samples(from: frame).isEmpty)
    }

    @Test(arguments: [0, 1])
    func eitherLegCountsOneCompleteSquat(_ visibleSide: Int) {
        var engine = SquatFixtures.trackingEngine(visibleSide: visibleSide)
        let frames = [
            SquatFixtures.frame(angle: 170, time: 1.1, visibleSide: visibleSide),
            SquatFixtures.frame(angle: 90, time: 1.3, visibleSide: visibleSide),
            SquatFixtures.frame(angle: 170, time: 1.5, visibleSide: visibleSide)
        ]

        let updates = frames.map { engine.consume($0) }

        #expect(updates.last?.reps.count == 1)
    }

    @Test func staggeredLegRecoveryCountsOneSquatAndAllowsLaterRep() {
        var engine = SquatFixtures.trackingEngine()

        let frames = [
            SquatFixtures.frame(angles: [170, 170], time: 1.1),
            SquatFixtures.frame(angles: [90, 90], time: 1.3),
            SquatFixtures.frame(angles: [170, 90], time: 1.5),
            SquatFixtures.frame(angles: [170, 170], time: 1.9),
            SquatFixtures.frame(angles: [170, 170], time: 2.0),
            SquatFixtures.frame(angles: [90, 90], time: 2.1),
            SquatFixtures.frame(angles: [170, 170], time: 2.4)
        ]

        let updates = frames.map { engine.consume($0) }
        let reps = updates.flatMap(\.reps)

        #expect(reps.count == 2)
        #expect(updates[2].reps.count == 1)
        #expect(updates[3].reps.isEmpty)
        #expect(updates[6].reps.count == 1)
    }

}
