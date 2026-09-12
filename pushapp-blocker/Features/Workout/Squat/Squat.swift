import Foundation

/// The body chains used by the first squat recognizer.
nonisolated enum Squat {
    static let title = "Squat"
    static let placement = "Stand far enough from the phone to keep one shoulder, hip, knee, and ankle visible. Keep your torso upright and start with your knees extended."

    static let legChains: [[BodyJoint]] = [
        [.rightHip, .rightKnee, .rightAnkle],
        [.leftHip, .leftKnee, .leftAnkle]
    ]

    static let trackedJoints = legChains.flatMap { $0 }
    static let bones = legChains.flatMap { [
        PoseBone(start: $0[0], end: $0[1]),
        PoseBone(start: $0[1], end: $0[2])
    ] }
    static let poseConfiguration = WorkoutPoseConfiguration(trackedJoints: trackedJoints,
                                                            bones: bones,
                                                            cameraTarget: { joints in
                                                                for leg in legChains {
                                                                    guard let hip = joints[leg[0]], let knee = joints[leg[1]], let ankle = joints[leg[2]],
                                                                          [hip, knee, ankle].allSatisfy({
                                                                              $0.confidence2D >= 0.5 &&
                                                                              $0.imagePoint.x.isFinite && $0.imagePoint.y.isFinite &&
                                                                              (0.0...1.0).contains($0.imagePoint.x) &&
                                                                              (0.0...1.0).contains($0.imagePoint.y)
                                                                          }) else { continue }
                                                                    return (hip.imagePoint + knee.imagePoint + ankle.imagePoint) / 3
                                                                }
                                                                return nil
                                                            })
}
