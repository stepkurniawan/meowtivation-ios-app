import Foundation
import simd

nonisolated enum PushUpRecognitionParameters {
    static let maximumFrameGap = 0.5
    static let minimumCycleDuration = 0.30
    static let maximumCycleDuration = 8.0
    static let maximumContractedAngle: Float = 90
    static let minimumRecoveryAngle: Float = 130
    static let angleTolerance: Float = 0.1
    static let armDropoutGraceDuration = 0.25
    static let armRepDeduplicationDuration = 0.30
    static let calibrationDuration = 1.0
    static let calibrationJitter: Float = 0.025
}

nonisolated struct PushUpSample: Sendable {
    var angle: Float
    var side: Int
    var points: [SIMD2<Float>]
}

nonisolated enum PushUpPose {
    /// Returns one usable push-up arm chain.
    static func sample(from frame: PoseFrame) -> PushUpSample? {
        samples(from: frame).first
    }

    /// Returns all usable arm chains for independent temporal tracking.
    static func samples(from frame: PoseFrame) -> [PushUpSample] {
        guard !frame.cameraIsMoving else { return [] }
        return PushUp.armChains.enumerated().compactMap { sideIndex, side in
            sample(shoulder: usable(side[0], in: frame),
                   elbow: usable(side[1], in: frame),
                   wrist: usable(side[2], in: frame),
                   side: sideIndex)
        }
    }

    private static func usable(_ joint: BodyJoint, in frame: PoseFrame) -> PoseJoint? {
        guard let value = frame.joints[joint], value.isUsable else { return nil }
        return value
    }

    private static func sample(shoulder: PoseJoint?, elbow: PoseJoint?, wrist: PoseJoint?,
                               side: Int) -> PushUpSample? {
        guard let shoulder, let elbow, let wrist else { return nil }
        guard (0.04...0.8).contains(simd_distance(shoulder.position, elbow.position)),
              (0.04...0.8).contains(simd_distance(elbow.position, wrist.position)) else {
            return nil
        }
        let elbowAngle = PoseFeatures.angle(shoulder.position, elbow.position, wrist.position)
        guard elbowAngle.isFinite else { return nil }
        return PushUpSample(angle: elbowAngle,
                            side: side,
                            points: [shoulder.position, elbow.position, wrist.position])
    }
}
