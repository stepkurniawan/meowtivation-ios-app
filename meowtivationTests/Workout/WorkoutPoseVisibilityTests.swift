import Foundation
@testable import pushapp_blocker
import Testing

struct WorkoutPoseVisibilityTests {
    @Test func pushUpGlowRequiresBothCompleteArms() {
        let configuration = PushUp.poseConfiguration
        let frame = PushUpFixtures.frame(contraction: 0, time: 1)

        #expect(configuration.visibility(in: frame) == .complete)
        #expect(configuration.visibility(in: PushUpFixtures.onlyArm(0, in: frame)) == .partial)
    }

    @Test func squatGlowRequiresBothCompleteLegs() {
        let configuration = Squat.poseConfiguration
        let frame = SquatFixtures.frame(angle: 170, time: 1)

        #expect(configuration.visibility(in: frame) == .complete)
        #expect(configuration.visibility(in: SquatFixtures.frame(angle: 170, time: 1, visibleSide: 0)) == .partial)
    }

    @Test func poseGlowIsRedWithoutUsableJoints() {
        let configuration = PushUp.poseConfiguration
        let frame = PushUpFixtures.frame(contraction: 0, time: 1)

        #expect(configuration.visibility(in: nil) == .none)
        #expect(configuration.visibility(in: PoseFrame(timestamp: 1, joints: [:])) == .none)

        var stabilizer = PoseStabilizer()
        _ = stabilizer.stabilize(frame.joints, tracking: configuration.trackedJoints, at: 1)
        let heldJoints = stabilizer.stabilize([:], tracking: configuration.trackedJoints, at: 1.1)
        #expect(configuration.visibility(in: PoseFrame(timestamp: 1.1, joints: heldJoints)) == .none)
    }
}
