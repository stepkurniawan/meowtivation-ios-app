import Foundation
import simd

nonisolated enum BodyJoint: String, CaseIterable, Codable, Sendable {
    case leftShoulder, leftElbow, leftWrist, leftHip, leftKnee, leftAnkle
    case rightShoulder, rightElbow, rightWrist, rightHip, rightKnee, rightAnkle
}

/// How much of an exercise's required body pose Vision can currently see.
nonisolated enum WorkoutPoseVisibility: Equatable, Sendable {
    case none, partial, complete
}

/// The joint requirements supplied by one exercise to shared camera and preview code.
nonisolated struct WorkoutPoseConfiguration: Sendable {
    let detectionChains: [[BodyJoint]]
    let cameraTarget: @Sendable ([BodyJoint: PoseJoint]) -> SIMD2<Float>?

    var trackedJoints: [BodyJoint] {
        detectionChains.flatMap { $0 }
    }

    /// A complete pose requires every configured chain, so the feedback glow
    /// only turns green when both arms or both legs are clearly visible.
    func visibility(in frame: PoseFrame?) -> WorkoutPoseVisibility {
        guard let frame else { return .none }
        let isUsable: (BodyJoint) -> Bool = { frame.joints[$0]?.isUsable == true }
        guard detectionChains.flatMap({ $0 }).contains(where: isUsable) else { return .none }
        guard !detectionChains.isEmpty,
              detectionChains.allSatisfy({ chain in !chain.isEmpty && chain.allSatisfy(isUsable) })
        else { return .partial }
        return .complete
    }
}

/// Shared camera and visual-pose values, pending the physical-device acceptance protocol.
nonisolated enum PoseDetectionParameters {
    static let minimumConfidence: Float = 0.3
    static let targetFPS = 30.0
    static let jointMinimumCutoff: Float = 2.0
    static let jointSpeedCoefficient: Float = 0.05
    static let jointDerivativeCutoff: Float = 1.0
    static let jointHoldDuration = 0.20
}

/// Normalized image-space joint positions with the origin at the lower left.
/// No camera images are retained.
nonisolated struct PoseJoint: Codable, Sendable {
    var position: SIMD2<Float>
    var imagePoint: SIMD2<Float>
    var confidence2D: Float

    var isUsable: Bool {
        position.x.isFinite && position.y.isFinite &&
            imagePoint.x.isFinite && imagePoint.y.isFinite &&
            (0.005 ... 0.995).contains(imagePoint.x) && (0.005 ... 0.995).contains(imagePoint.y) &&
            confidence2D >= PoseDetectionParameters.minimumConfidence
    }
}

nonisolated struct PoseFrame: Codable, Sendable {
    var timestamp: TimeInterval
    var joints: [BodyJoint: PoseJoint]
    var cameraIsMoving: Bool = false
    var imageAspectRatio: Double = 9.0 / 16
}

/// Geometry shared by exercises that classify a joint angle.
nonisolated enum PoseFeatures {
    static func angle(_ first: SIMD2<Float>, _ vertex: SIMD2<Float>, _ last: SIMD2<Float>) -> Float {
        let firstVector = first - vertex
        let secondVector = last - vertex
        let divisor = simd_length(firstVector) * simd_length(secondVector)
        guard divisor > 0.0001 else { return .nan }
        return acos(max(-1, min(1, simd_dot(firstVector, secondVector) / divisor))) * 180 / .pi
    }
}

/// A low-latency adaptive filter for noisy normalized joint coordinates.
/// It applies more smoothing while a joint is nearly still and responds more
/// quickly as the joint moves.
private nonisolated struct OneEuroFilter2D {
    private var filtered: SIMD2<Float>?
    private var filteredDerivative: SIMD2<Float>?
    private var lastTimestamp: TimeInterval?

    mutating func filter(_ value: SIMD2<Float>, at timestamp: TimeInterval) -> SIMD2<Float> {
        guard value.x.isFinite, value.y.isFinite, timestamp.isFinite else {
            return filtered ?? value
        }
        guard let previous = filtered, let lastTimestamp else {
            filtered = value
            filteredDerivative = .zero
            lastTimestamp = timestamp
            return value
        }

        let delta = max(1.0 / 120.0, timestamp - lastTimestamp)
        let derivative = (value - previous) / Float(delta)
        let derivativeAlpha = alpha(cutoff: PoseDetectionParameters.jointDerivativeCutoff,
                                    delta: delta)
        let smoothedDerivative = filteredDerivative.map {
            $0 + derivativeAlpha * (derivative - $0)
        } ?? derivative
        let cutoff = PoseDetectionParameters.jointMinimumCutoff +
            PoseDetectionParameters.jointSpeedCoefficient * simd_length(smoothedDerivative)
        let valueAlpha = alpha(cutoff: cutoff, delta: delta)
        let result = previous + valueAlpha * (value - previous)

        filtered = result
        filteredDerivative = smoothedDerivative
        self.lastTimestamp = timestamp
        return result
    }

    private func alpha(cutoff: Float, delta: TimeInterval) -> Float {
        let tau = 1.0 / (2.0 * Double.pi * Double(max(cutoff, 0.001)))
        return Float(1.0 / (1.0 + tau / delta))
    }
}

/// Stabilizes the display while making held joints unusable to recognition.
/// A brief Vision dropout should not make the overlay disappear, but stale
/// coordinates must never be treated as fresh exercise measurements.
nonisolated struct PoseStabilizer {
    private struct Track {
        var filter = OneEuroFilter2D()
        var position: SIMD2<Float> = .zero
        var lastObservedAt: TimeInterval = -.infinity
    }

    private var tracks: [BodyJoint: Track] = [:]

    mutating func reset() {
        tracks.removeAll(keepingCapacity: true)
    }

    mutating func stabilize(_ rawJoints: [BodyJoint: PoseJoint],
                            tracking trackedJoints: [BodyJoint],
                            at timestamp: TimeInterval) -> [BodyJoint: PoseJoint]
    {
        var result: [BodyJoint: PoseJoint] = [:]
        for joint in trackedJoints {
            if let raw = rawJoints[joint], isValid(raw),
               raw.confidence2D >= PoseDetectionParameters.minimumConfidence
            {
                var track = tracks[joint] ?? Track()
                let position = track.filter.filter(raw.imagePoint, at: timestamp)
                track.position = position
                track.lastObservedAt = timestamp
                tracks[joint] = track
                result[joint] = PoseJoint(position: position,
                                          imagePoint: position,
                                          confidence2D: raw.confidence2D)
            } else if let track = tracks[joint],
                      timestamp - track.lastObservedAt <= PoseDetectionParameters.jointHoldDuration
            {
                result[joint] = PoseJoint(position: track.position,
                                          imagePoint: track.position,
                                          confidence2D: 0)
            } else {
                tracks.removeValue(forKey: joint)
            }
        }
        return result
    }

    private func isValid(_ joint: PoseJoint) -> Bool {
        joint.imagePoint.x.isFinite && joint.imagePoint.y.isFinite &&
            (0.0 ... 1.0).contains(joint.imagePoint.x) && (0.0 ... 1.0).contains(joint.imagePoint.y)
    }
}
