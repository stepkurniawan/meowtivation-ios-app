import Foundation
import simd

nonisolated enum SquatRecognitionParameters {
    static let maximumFrameGap = 0.5
    static let minimumCycleDuration = 0.30
    static let maximumCycleDuration = 8.0
    static let maximumContractedAngle: Float = 100
    static let minimumRecoveryAngle: Float = 160
    static let legDropoutGraceDuration = 0.25
    static let legRepDeduplicationDuration = 0.30
    static let calibrationDuration = 1.0
    static let calibrationJitter: Float = 0.025
}

nonisolated struct SquatSample: Sendable {
    var angle: Float
    var side: Int
    var points: [SIMD2<Float>]
}

nonisolated enum SquatPose {
    /// Returns every usable hip-knee-ankle chain in the frame.
    static func samples(from frame: PoseFrame) -> [SquatSample] {
        guard !frame.cameraIsMoving else { return [] }
        return Squat.legChains.enumerated().compactMap { sideIndex, leg in
            sample(hip: usable(leg[0], in: frame),
                   knee: usable(leg[1], in: frame),
                   ankle: usable(leg[2], in: frame),
                   side: sideIndex)
        }
    }

    private static func usable(_ joint: BodyJoint, in frame: PoseFrame) -> PoseJoint? {
        guard let value = frame.joints[joint], value.isUsable else { return nil }
        return value
    }

    private static func sample(hip: PoseJoint?, knee: PoseJoint?, ankle: PoseJoint?,
                               side: Int) -> SquatSample? {
        guard let hip, let knee, let ankle else { return nil }
        guard (0.04...0.8).contains(simd_distance(hip.position, knee.position)),
              (0.04...0.8).contains(simd_distance(knee.position, ankle.position)) else {
            return nil
        }
        let kneeAngle = PoseFeatures.angle(hip.position, knee.position, ankle.position)
        guard kneeAngle.isFinite else { return nil }
        return SquatSample(angle: kneeAngle,
                           side: side,
                           points: [hip.position, knee.position, ankle.position])
    }
}
