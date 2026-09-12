import Foundation
import simd

nonisolated enum PushUp {
    static let title = "Push-up"
    static let placement = "Use a side view with one shoulder, elbow, and wrist visible. Your legs can be out of frame."
}

nonisolated enum BodyJoint: String, CaseIterable, Codable, Sendable {
    case leftShoulder, leftElbow, leftWrist, leftHip, leftKnee, leftAnkle
    case rightShoulder, rightElbow, rightWrist, rightHip, rightKnee, rightAnkle

    static let sides: [[BodyJoint]] = [
        [.rightShoulder, .rightElbow, .rightWrist],
        [.leftShoulder, .leftElbow, .leftWrist]
    ]
    static let armJoints = sides.flatMap { $0 }
    static let bones: [(BodyJoint, BodyJoint)] = sides.flatMap { [($0[0], $0[1]), ($0[1], $0[2])] }
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
        (0.005...0.995).contains(imagePoint.x) && (0.005...0.995).contains(imagePoint.y) &&
        confidence2D >= RecognitionParameters.minimumConfidence
    }
}

nonisolated struct PoseFrame: Codable, Sendable {
    var timestamp: TimeInterval
    var joints: [BodyJoint: PoseJoint]
    var cameraIsMoving: Bool = false
    var imageAspectRatio: Double = 9.0 / 16
}

/// Initial conservative values, pending the physical-device acceptance protocol.
nonisolated enum RecognitionParameters {
    static let minimumConfidence: Float = 0.3
    static let targetFPS = 30.0
    static let maximumFrameGap = 0.5
    static let minimumCycleDuration = 0.30
    static let maximumCycleDuration = 8.0
    static let maximumContractedAngle: Float = 90
    static let minimumRecoveryAngle: Float = 130
    static let jointMinimumCutoff: Float = 2.0  // Hz ; the minimum cutoff frequency for the One Euro filter. One Euro Filter is a low-pass filter that adapts its cutoff frequency based on the speed of the input signal. A higher cutoff frequency allows for faster response to changes in the input signal, while a lower cutoff frequency provides more smoothing and stability. The jointMinimumCutoff parameter sets the minimum cutoff frequency for the One Euro filter applied to joint positions, ensuring that even when joints are moving slowly, there is still some responsiveness in the filtering process.
    static let jointSpeedCoefficient: Float = 0.05
    static let jointDerivativeCutoff: Float = 1.0
    static let jointHoldDuration = 0.20
    static let selectedArmDropoutGraceDuration = 0.25
    static let calibrationDuration = 1.0
    static let calibrationJitter: Float = 0.025
    static let confidenceTieTolerance: Float = 0.02
    static let armLengthTieTolerance: Float = 0.01
}

nonisolated struct PushUpSample: Sendable {
    var angle: Float
    var side: Int
    var confidence: Float
    var armLength: Float
    var points: [SIMD2<Float>]
}

/// The angle between three points, in degrees. The angle is at the second point, with the first and third points forming the rays.
nonisolated enum PoseFeatures {
    static func angle(_ a: SIMD2<Float>, _ b: SIMD2<Float>, _ c: SIMD2<Float>) -> Float {
        let u = a - b, v = c - b
        let divisor = simd_length(u) * simd_length(v)
        guard divisor > 0.0001 else { return .nan }
        return acos(max(-1, min(1, simd_dot(u, v) / divisor))) * 180 / .pi
    }

    /// Returns a push-up sample when one shoulder-elbow-wrist chain is usable.
    static func pushUpSample(from frame: PoseFrame) -> PushUpSample? {
        pushUpSamples(from: frame).first
    }

    /// Returns all usable arm chains, ordered by the preferred side.
    /// The recognition engine applies temporal side selection so a brief
    /// confidence change cannot switch arms immediately.
    static func pushUpSamples(from frame: PoseFrame) -> [PushUpSample] {
        guard !frame.cameraIsMoving else { return [] }
        return BodyJoint.sides.enumerated().compactMap { sideIndex, side in
            pushUpSample(shoulder: usable(side[0], in: frame),
                         elbow: usable(side[1], in: frame),
                         wrist: usable(side[2], in: frame),
                         side: sideIndex)
        }
    }

    private static func usable(_ joint: BodyJoint, in frame: PoseFrame) -> PoseJoint? {
        guard let value = frame.joints[joint], value.isUsable else { return nil }
        return value
    }

    private static func pushUpSample(shoulder: PoseJoint?, elbow: PoseJoint?, wrist: PoseJoint?,
                                     side: Int) -> PushUpSample? {
        guard let shoulder, let elbow, let wrist else { return nil }
        guard (0.04...0.8).contains(simd_distance(shoulder.position, elbow.position)),
              (0.04...0.8).contains(simd_distance(elbow.position, wrist.position)) else {
            return nil
        }
        let elbowAngle = angle(shoulder.position, elbow.position, wrist.position)
        guard elbowAngle.isFinite else { return nil }
        return PushUpSample(angle: elbowAngle,
                            side: side,
                            confidence: (shoulder.confidence2D + elbow.confidence2D + wrist.confidence2D) / 3,
                            armLength: simd_distance(shoulder.position, elbow.position) +
                                simd_distance(elbow.position, wrist.position),
                            points: [shoulder.position, elbow.position, wrist.position])
    }
}

/// A low-latency adaptive filter for noisy normalized joint coordinates.
/// It applies more smoothing while a joint is nearly still and responds more
/// quickly as the joint moves.
nonisolated private struct OneEuroFilter2D {
    private var filtered: SIMD2<Float>?
    private var filteredDerivative: SIMD2<Float>?
    private var lastTimestamp: TimeInterval?

    mutating func reset() {
        filtered = nil
        filteredDerivative = nil
        lastTimestamp = nil
    }

    mutating func filter(_ value: SIMD2<Float>, at timestamp: TimeInterval) -> SIMD2<Float> {
        guard value.x.isFinite, value.y.isFinite, timestamp.isFinite else {
            return filtered ?? value
        }
        guard let previous = filtered, let lastTimestamp else {
            filtered = value
            filteredDerivative = .zero
            self.lastTimestamp = timestamp
            return value
        }

        let delta = max(1.0 / 120.0, timestamp - lastTimestamp)
        let derivative = (value - previous) / Float(delta)
        let derivativeAlpha = alpha(cutoff: RecognitionParameters.jointDerivativeCutoff,
                                    delta: delta)
        let smoothedDerivative = filteredDerivative.map {
            $0 + derivativeAlpha * (derivative - $0)
        } ?? derivative
        let cutoff = RecognitionParameters.jointMinimumCutoff +
            RecognitionParameters.jointSpeedCoefficient * simd_length(smoothedDerivative)
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
/// coordinates must never be treated as fresh push-up measurements.
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
                            at timestamp: TimeInterval) -> [BodyJoint: PoseJoint] {
        var result: [BodyJoint: PoseJoint] = [:]
        for joint in BodyJoint.armJoints {
            if let raw = rawJoints[joint], isValid(raw),
               raw.confidence2D >= RecognitionParameters.minimumConfidence {
                var track = tracks[joint] ?? Track()
                let position = track.filter.filter(raw.imagePoint, at: timestamp)
                track.position = position
                track.lastObservedAt = timestamp
                tracks[joint] = track
                result[joint] = PoseJoint(position: position,
                                          imagePoint: position,
                                          confidence2D: raw.confidence2D)
            } else if let track = tracks[joint],
                      timestamp - track.lastObservedAt <= RecognitionParameters.jointHoldDuration {
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
        (0.0...1.0).contains(joint.imagePoint.x) &&
        (0.0...1.0).contains(joint.imagePoint.y)
    }
}
