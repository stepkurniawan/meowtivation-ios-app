import Foundation

/// The body chains used by the first squat recognizer.
nonisolated enum Squat {
    static let legChains: [[BodyJoint]] = [
        [.rightHip, .rightKnee, .rightAnkle],
        [.leftHip, .leftKnee, .leftAnkle]
    ]

    static let trackedJoints = legChains.flatMap { $0 }
}
