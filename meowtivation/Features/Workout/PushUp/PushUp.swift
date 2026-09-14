import Foundation
import simd

nonisolated enum PushUp {
    static let title = "Push-up"
    static let placement =
        "Looking at the floor is fine. Keep the side of your head, upper body, and one shoulder, elbow, and wrist " +
        "visible. Either arm can count; both are tracked when visible. Your legs can be out of frame."

    static let armChains: [[BodyJoint]] = [
        [.rightShoulder, .rightElbow, .rightWrist],
        [.leftShoulder, .leftElbow, .leftWrist],
    ]
    static let trackedJoints = armChains.flatMap { $0 }
    static let bones = armChains.flatMap { [
        PoseBone(start: $0[0], end: $0[1]),
        PoseBone(start: $0[1], end: $0[2]),
    ] }
    static let poseConfiguration = WorkoutPoseConfiguration(trackedJoints: trackedJoints,
                                                            bones: bones,
                                                            cameraTarget: { cameraTarget(from: $0) })

    /// Returns one arm's image-space centre when Vision sees a reliable push-up arm.
    static func cameraTarget(from joints: [BodyJoint: PoseJoint]) -> SIMD2<Float>? {
        for arm in armChains {
            guard let shoulder = joints[arm[0]], let elbow = joints[arm[1]], let wrist = joints[arm[2]],
                  [shoulder, elbow, wrist].allSatisfy({
                      $0.confidence2D >= 0.5 &&
                          $0.imagePoint.x.isFinite && $0.imagePoint.y.isFinite &&
                          (0.0 ... 1.0).contains($0.imagePoint.x) &&
                          (0.0 ... 1.0).contains($0.imagePoint.y)
                  }) else { continue }
            return (shoulder.imagePoint + elbow.imagePoint + wrist.imagePoint) / 3
        }
        return nil
    }
}
