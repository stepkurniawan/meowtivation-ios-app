import Foundation
import simd

nonisolated enum PushUpTrackingState: Equatable, Sendable {
    case findingPosition, validatingPosition, ready, tracking, waitingForArm, cameraMoving

    var message: String {
        switch self {
        case .findingPosition: "Get into the starting push-up position."
        case .validatingPosition: "Hold still. Checking your position."
        case .ready: "Start!"
        case .tracking: "Tracking your push-ups"
        case .waitingForArm: "Keep a shoulder, elbow, and wrist visible."
        case .cameraMoving: "Keep the phone still against the wall."
        }
    }
}

nonisolated struct PushUpRepEvent: Identifiable, Sendable {
    let id: UInt64
    let timestamp: TimeInterval
}

nonisolated struct PushUpRecognitionUpdate: Sendable {
    var tracking: PushUpTrackingState
    var poseReady = false
    var armAngles: [Int: Float] = [:]
    var didStart = false
    var reps: [PushUpRepEvent] = []
}

nonisolated private struct CycleDetector {
    enum Phase { case waiting, extended, contracted }
    var phase = Phase.waiting
    var startedAt = 0.0

    mutating func consume(_ raw: PushUpSample, at time: TimeInterval) -> Bool {
        let angle = raw.angle
        if phase != .waiting, time - startedAt > PushUpRecognitionParameters.maximumCycleDuration {
            phase = .waiting
        }

        switch phase {
        case .waiting:
            guard angle + PushUpRecognitionParameters.angleTolerance >= PushUpRecognitionParameters.minimumRecoveryAngle else { return false }
            phase = .extended
            startedAt = time
        case .extended:
            guard angle <= PushUpRecognitionParameters.maximumContractedAngle + PushUpRecognitionParameters.angleTolerance else { return false }
            phase = .contracted
        case .contracted:
            guard angle + PushUpRecognitionParameters.angleTolerance >= PushUpRecognitionParameters.minimumRecoveryAngle else { return false }
            let duration = time - startedAt
            let valid = duration >= PushUpRecognitionParameters.minimumCycleDuration &&
                duration <= PushUpRecognitionParameters.maximumCycleDuration
            phase = .extended
            startedAt = time
            return valid
        }
        return false
    }
}

/// Pure setup and rep classifier. No Vision, camera, persistence, speech, or blocking dependencies.
nonisolated struct PushUpRecognitionEngine {
    private struct CalibrationMeasurement {
        let startedAt: TimeInterval
        let referencePoints: [SIMD2<Float>]

        init(sample: PushUpSample, at timestamp: TimeInterval) {
            startedAt = timestamp
            referencePoints = sample.points
        }

        func isSteady(_ sample: PushUpSample) -> Bool {
            zip(referencePoints, sample.points).allSatisfy {
                simd_distance($0, $1) <= PushUpRecognitionParameters.calibrationJitter
            }
        }
    }

    private var detectors: [Int: CycleDetector] = [:]
    private var nextID: UInt64 = 0
    private var lastTimestamp: TimeInterval?
    private var isTracking = false
    private var armLostAt: [Int: TimeInterval] = [:]
    private var lastRepAt: TimeInterval?
    private var calibrations: [Int: CalibrationMeasurement] = [:]

    mutating func resetTracking() {
        detectors = [:]
        lastTimestamp = nil
        isTracking = false
        armLostAt = [:]
        lastRepAt = nil
        calibrations = [:]
        // Preserve the event sequence across resets to prevent duplicate credits.
    }

    mutating func consume(_ frame: PoseFrame) -> PushUpRecognitionUpdate {
        guard frame.timestamp.isFinite else {
            resetTracking()
            return PushUpRecognitionUpdate(tracking: .findingPosition)
        }
        if let lastTimestamp, frame.timestamp <= lastTimestamp {
            return PushUpRecognitionUpdate(tracking: .findingPosition)
        }
        if let lastTimestamp, frame.timestamp - lastTimestamp > PushUpRecognitionParameters.maximumFrameGap {
            resetTracking()
            self.lastTimestamp = frame.timestamp
            return PushUpRecognitionUpdate(tracking: .findingPosition)
        }
        lastTimestamp = frame.timestamp

        guard !frame.cameraIsMoving else {
            resetTracking()
            return PushUpRecognitionUpdate(tracking: .cameraMoving)
        }

        let candidates = PushUpPose.samples(from: frame)
        if !isTracking {
            return calibrate(candidates, at: frame.timestamp)
        }

        var reps: [PushUpRepEvent] = []
        let samplesBySide = Dictionary(uniqueKeysWithValues: candidates.map { ($0.side, $0) })
        for side in PushUp.armChains.indices {
            guard let sample = samplesBySide[side] else {
                let lostAt = armLostAt[side] ?? frame.timestamp
                armLostAt[side] = lostAt
                if frame.timestamp - lostAt > PushUpRecognitionParameters.armDropoutGraceDuration {
                    detectors.removeValue(forKey: side)
                }
                continue
            }

            armLostAt.removeValue(forKey: side)
            var detector = detectors[side] ?? CycleDetector()
            let completed = detector.consume(sample, at: frame.timestamp)
            detectors[side] = detector
            guard completed,
                  lastRepAt.map({ frame.timestamp - $0 >= PushUpRecognitionParameters.armRepDeduplicationDuration }) ?? true else {
                continue
            }
            nextID += 1
            lastRepAt = frame.timestamp
            reps.append(PushUpRepEvent(id: nextID, timestamp: frame.timestamp))
        }

        let armAngles = Dictionary(uniqueKeysWithValues: candidates.map { ($0.side, $0.angle) })
        guard !candidates.isEmpty else {
            return PushUpRecognitionUpdate(tracking: .waitingForArm)
        }
        return PushUpRecognitionUpdate(tracking: .tracking, poseReady: true,
                                       armAngles: armAngles, reps: reps)
    }

    private mutating func calibrate(_ candidates: [PushUpSample],
                                    at timestamp: TimeInterval) -> PushUpRecognitionUpdate {
        let extended = candidates.filter {
            $0.angle + PushUpRecognitionParameters.angleTolerance >= PushUpRecognitionParameters.minimumRecoveryAngle
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
            return PushUpRecognitionUpdate(tracking: .findingPosition,
                                           armAngles: angles(from: candidates))
        }
        guard calibrations.values.contains(where: {
            timestamp - $0.startedAt >= PushUpRecognitionParameters.calibrationDuration
        }) else {
            return PushUpRecognitionUpdate(tracking: .validatingPosition,
                                           armAngles: angles(from: candidates))
        }
        isTracking = true
        calibrations = [:]
        detectors = [:]
        for sample in candidates {
            var detector = CycleDetector()
            _ = detector.consume(sample, at: timestamp)
            detectors[sample.side] = detector
        }
        return PushUpRecognitionUpdate(tracking: .ready, poseReady: true,
                                       armAngles: angles(from: candidates), didStart: true)
    }

    private func angles(from candidates: [PushUpSample]) -> [Int: Float] {
        Dictionary(uniqueKeysWithValues: candidates.map { ($0.side, $0.angle) })
    }
}
