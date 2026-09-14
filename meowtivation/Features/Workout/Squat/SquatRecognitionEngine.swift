import Foundation
import simd

nonisolated enum SquatTrackingState: Equatable, Sendable {
    case findingPosition, validatingPosition, ready, tracking, waitingForLeg, cameraMoving
}

nonisolated struct SquatRepEvent: Identifiable, Sendable {
    let id: UInt64
    let timestamp: TimeInterval
}

nonisolated struct SquatRecognitionUpdate: Sendable {
    var tracking: SquatTrackingState
    var poseReady = false
    var kneeAngles: [Int: Float] = [:]
    var didStart = false
    var reps: [SquatRepEvent] = []
}

private nonisolated struct SquatCycleDetector {
    enum Phase { case waiting, extended, contracted }
    var phase = Phase.waiting
    var startedAt = 0.0

    mutating func consume(_ raw: SquatSample, at time: TimeInterval) -> Bool {
        let angle = raw.angle
        if phase != .waiting,
           time - startedAt > SquatRecognitionParameters.maximumCycleDuration
        {
            phase = .waiting
        }

        switch phase {
        case .waiting:
            guard angle + SquatRecognitionParameters.angleTolerance >= SquatRecognitionParameters.minimumRecoveryAngle
            else { return false }
            phase = .extended
            startedAt = time
        case .extended:
            guard angle <= SquatRecognitionParameters.maximumContractedAngle + SquatRecognitionParameters
                .angleTolerance else { return false }
            phase = .contracted
        case .contracted:
            guard angle + SquatRecognitionParameters.angleTolerance >= SquatRecognitionParameters.minimumRecoveryAngle
            else { return false }
            let duration = time - startedAt
            let valid = duration >= SquatRecognitionParameters.minimumCycleDuration &&
                duration <= SquatRecognitionParameters.maximumCycleDuration
            phase = .extended
            startedAt = time
            return valid
        }
        return false
    }
}

/// Pure squat setup and rep classifier. It has no camera, UI, speech, or persistence dependencies.
nonisolated struct SquatRecognitionEngine {
    private struct CalibrationMeasurement {
        let startedAt: TimeInterval
        let referencePoints: [SIMD2<Float>]

        init(sample: SquatSample, at timestamp: TimeInterval) {
            startedAt = timestamp
            referencePoints = sample.points
        }

        func isSteady(_ sample: SquatSample) -> Bool {
            zip(referencePoints, sample.points).allSatisfy {
                simd_distance($0, $1) <= SquatRecognitionParameters.calibrationJitter
            }
        }
    }

    private var detectors: [Int: SquatCycleDetector] = [:]
    private var nextID: UInt64 = 0
    private var lastTimestamp: TimeInterval?
    private var isTracking = false
    private var legLostAt: [Int: TimeInterval] = [:]
    private var lastRepAt: TimeInterval?
    private var calibrations: [Int: CalibrationMeasurement] = [:]

    mutating func resetTracking() {
        detectors = [:]
        lastTimestamp = nil
        isTracking = false
        legLostAt = [:]
        lastRepAt = nil
        calibrations = [:]
        // Preserve the event sequence across resets to prevent duplicate credits.
    }

    // The squat state machine keeps dropout, calibration, and rep transitions atomic.
    // swiftlint:disable:next function_body_length
    mutating func consume(_ frame: PoseFrame) -> SquatRecognitionUpdate {
        guard frame.timestamp.isFinite else {
            resetTracking()
            return SquatRecognitionUpdate(tracking: .findingPosition)
        }
        if let lastTimestamp, frame.timestamp <= lastTimestamp {
            return SquatRecognitionUpdate(tracking: .findingPosition)
        }
        if let lastTimestamp,
           frame.timestamp - lastTimestamp > SquatRecognitionParameters.maximumFrameGap
        {
            resetTracking()
            self.lastTimestamp = frame.timestamp
            return SquatRecognitionUpdate(tracking: .findingPosition)
        }
        lastTimestamp = frame.timestamp

        guard !frame.cameraIsMoving else {
            resetTracking()
            return SquatRecognitionUpdate(tracking: .cameraMoving)
        }

        let candidates = SquatPose.samples(from: frame)
        if !isTracking {
            return calibrate(candidates, at: frame.timestamp)
        }

        var reps: [SquatRepEvent] = []
        let samplesBySide: [Int: SquatSample] = Dictionary(uniqueKeysWithValues: candidates.map { ($0.side, $0) })
        for side: Range<Array<[BodyJoint]>.Index>.Element in Squat.legChains.indices {
            guard let sample: SquatSample = samplesBySide[side] else {
                let lostAt: TimeInterval = legLostAt[side] ?? frame.timestamp
                legLostAt[side] = lostAt
                if frame.timestamp - lostAt > SquatRecognitionParameters.legDropoutGraceDuration {
                    detectors.removeValue(forKey: side)
                }
                continue
            }

            legLostAt.removeValue(forKey: side)
            var detector = detectors[side] ?? SquatCycleDetector()
            let completed = detector.consume(sample, at: frame.timestamp)
            detectors[side] = detector
            guard completed,
                  lastRepAt
                  .map({ frame.timestamp - $0 >= SquatRecognitionParameters.legRepDeduplicationDuration }) ?? true
            else {
                continue
            }
            nextID += 1
            lastRepAt = frame.timestamp
            reps.append(SquatRepEvent(id: nextID, timestamp: frame.timestamp))
        }

        let kneeAngles = angles(from: candidates)
        guard !candidates.isEmpty else {
            return SquatRecognitionUpdate(tracking: .waitingForLeg)
        }
        return SquatRecognitionUpdate(tracking: .tracking, poseReady: true,
                                      kneeAngles: kneeAngles, reps: reps)
    }

    private mutating func calibrate(_ candidates: [SquatSample],
                                    at timestamp: TimeInterval) -> SquatRecognitionUpdate
    {
        let extended = candidates.filter {
            $0.angle + SquatRecognitionParameters.angleTolerance >= SquatRecognitionParameters.minimumRecoveryAngle
        }
        let visibleSides = Set(extended.map(\.side))
        for side in Array(calibrations.keys) where !visibleSides.contains(side) {
            calibrations.removeValue(forKey: side)
        }
        for sample in extended {
            if let measurement = calibrations[sample.side] {
                if !measurement.isSteady(sample) {
                    calibrations.removeValue(forKey: sample.side)
                }
            } else {
                calibrations[sample.side] = CalibrationMeasurement(sample: sample, at: timestamp)
            }
        }

        guard !calibrations.isEmpty else {
            return SquatRecognitionUpdate(tracking: .findingPosition,
                                          kneeAngles: angles(from: candidates))
        }
        guard calibrations.values.contains(where: {
            timestamp - $0.startedAt >= SquatRecognitionParameters.calibrationDuration
        }) else {
            return SquatRecognitionUpdate(tracking: .validatingPosition,
                                          kneeAngles: angles(from: candidates))
        }

        isTracking = true
        calibrations = [:]
        detectors = [:]
        for sample in extended {
            var detector = SquatCycleDetector()
            _ = detector.consume(sample, at: timestamp)
            detectors[sample.side] = detector
        }
        return SquatRecognitionUpdate(tracking: .ready, poseReady: true,
                                      kneeAngles: angles(from: candidates), didStart: true)
    }

    private func angles(from candidates: [SquatSample]) -> [Int: Float] {
        Dictionary(uniqueKeysWithValues: candidates.map { ($0.side, $0.angle) })
    }
}
