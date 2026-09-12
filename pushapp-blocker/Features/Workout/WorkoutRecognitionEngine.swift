import Foundation
import simd

nonisolated enum WorkoutTracking: Equatable, Sendable {
    case findingPosition, validatingPosition, ready, tracking, waitingForSelectedArm, cameraMoving

    var message: String {
        switch self {
        case .findingPosition: "Get into the starting push-up position."
        case .validatingPosition: "Hold still. Checking your position."
        case .ready: "Start!"
        case .tracking: "Tracking your push-ups"
        case .waitingForSelectedArm: "Keep your selected shoulder, elbow, and wrist visible."
        case .cameraMoving: "Keep the phone still against the wall."
        }
    }
}

nonisolated struct PushUpRepEvent: Identifiable, Sendable {
    let id: UInt64
    let timestamp: TimeInterval
}

nonisolated struct PushUpRecognitionUpdate: Sendable {
    var tracking: WorkoutTracking
    var poseReady = false
    var pushUpAngle: Float?
    var selectedSide: Int?
    var didStart = false
    var reps: [PushUpRepEvent] = []
}

nonisolated private struct CycleDetector {
    enum Phase { case waiting, extended, contracted }
    var phase = Phase.waiting
    var startedAt = 0.0

    mutating func consume(_ raw: PushUpSample, at time: TimeInterval) -> Bool {
        let angle = raw.angle
        if phase != .waiting, time - startedAt > RecognitionParameters.maximumCycleDuration {
            phase = .waiting
        }

        switch phase {
        case .waiting:
            guard angle >= RecognitionParameters.minimumRecoveryAngle else { return false }
            phase = .extended
            startedAt = time
        case .extended:
            guard angle <= RecognitionParameters.maximumContractedAngle else { return false }
            phase = .contracted
        case .contracted:
            guard angle >= RecognitionParameters.minimumRecoveryAngle else { return false }
            let duration = time - startedAt
            let valid = duration >= RecognitionParameters.minimumCycleDuration &&
                duration <= RecognitionParameters.maximumCycleDuration
            phase = .extended
            startedAt = time
            return valid
        }
        return false
    }
}

/// Pure setup and rep classifier. No Vision, camera, persistence, speech, or blocking dependencies.
nonisolated struct WorkoutRecognitionEngine {
    private struct CalibrationMeasurement {
        let startedAt: TimeInterval
        let referencePoints: [SIMD2<Float>]
        var confidenceTotal: Float
        var armLengthTotal: Float
        var sampleCount: Int

        init(sample: PushUpSample, at timestamp: TimeInterval) {
            startedAt = timestamp
            referencePoints = sample.points
            confidenceTotal = sample.confidence
            armLengthTotal = sample.armLength
            sampleCount = 1
        }

        var averageConfidence: Float { confidenceTotal / Float(sampleCount) }
        var averageArmLength: Float { armLengthTotal / Float(sampleCount) }

        func isSteady(_ sample: PushUpSample) -> Bool {
            zip(referencePoints, sample.points).allSatisfy {
                simd_distance($0, $1) <= RecognitionParameters.calibrationJitter
            }
        }

        mutating func append(_ sample: PushUpSample) {
            confidenceTotal += sample.confidence
            armLengthTotal += sample.armLength
            sampleCount += 1
        }
    }

    private var detector = CycleDetector()
    private var nextID: UInt64 = 0
    private var lastTimestamp: TimeInterval?
    private var selectedSide: Int?
    private var calibrations: [Int: CalibrationMeasurement] = [:]

    mutating func resetTracking() {
        detector = CycleDetector()
        lastTimestamp = nil
        selectedSide = nil
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
        if let lastTimestamp, frame.timestamp - lastTimestamp > RecognitionParameters.maximumFrameGap {
            resetTracking()
            self.lastTimestamp = frame.timestamp
            return PushUpRecognitionUpdate(tracking: .findingPosition)
        }
        lastTimestamp = frame.timestamp

        guard !frame.cameraIsMoving else {
            resetTracking()
            return PushUpRecognitionUpdate(tracking: .cameraMoving)
        }

        let candidates = PoseFeatures.pushUpSamples(from: frame)
        if selectedSide == nil {
            return calibrate(candidates, at: frame.timestamp)
        }

        guard let selectedSide,
              let sample = candidates.first(where: { $0.side == selectedSide }) else {
            detector = CycleDetector()
            return PushUpRecognitionUpdate(tracking: .waitingForSelectedArm,
                                           selectedSide: selectedSide)
        }

        let completed = detector.consume(sample, at: frame.timestamp)
        var reps: [PushUpRepEvent] = []
        if completed {
            nextID += 1
            reps = [PushUpRepEvent(id: nextID, timestamp: frame.timestamp)]
        }
        return PushUpRecognitionUpdate(tracking: .tracking, poseReady: true,
                                       pushUpAngle: sample.angle, selectedSide: selectedSide, reps: reps)
    }

    private mutating func calibrate(_ candidates: [PushUpSample],
                                    at timestamp: TimeInterval) -> PushUpRecognitionUpdate {
        let extended = candidates.filter { $0.angle >= RecognitionParameters.minimumRecoveryAngle }
        let visibleSides = Set(extended.map(\.side))
        for side in Array(calibrations.keys) where !visibleSides.contains(side) {
            calibrations.removeValue(forKey: side)
        }
        for sample in extended {
            if var measurement = calibrations[sample.side] {
                if measurement.isSteady(sample) {
                    measurement.append(sample)
                    calibrations[sample.side] = measurement
                } else {
                    calibrations.removeValue(forKey: sample.side)
                }
            } else {
                calibrations[sample.side] = CalibrationMeasurement(sample: sample, at: timestamp)
            }
        }

        guard !calibrations.isEmpty else {
            return PushUpRecognitionUpdate(tracking: .findingPosition)
        }
        guard let side = selectedCalibrationSide(at: timestamp) else {
            return PushUpRecognitionUpdate(tracking: .validatingPosition)
        }
        selectedSide = side
        calibrations = [:]
        detector = CycleDetector()
        return PushUpRecognitionUpdate(tracking: .ready, poseReady: true,
                                       selectedSide: side, didStart: true)
    }

    private func selectedCalibrationSide(at timestamp: TimeInterval) -> Int? {
        let completed = calibrations.filter {
            timestamp - $0.value.startedAt >= RecognitionParameters.calibrationDuration
        }
        guard !completed.isEmpty else { return nil }
        guard completed.count > 1 else { return completed.keys.first }
        let ordered = completed.sorted { $0.key < $1.key }
        guard let first = ordered.first, let second = ordered.dropFirst().first else { return nil }
        let confidenceDifference = first.value.averageConfidence - second.value.averageConfidence
        if abs(confidenceDifference) > RecognitionParameters.confidenceTieTolerance {
            return confidenceDifference > 0 ? first.key : second.key
        }
        let lengthDifference = first.value.averageArmLength - second.value.averageArmLength
        if abs(lengthDifference) > RecognitionParameters.armLengthTieTolerance {
            return lengthDifference > 0 ? first.key : second.key
        }
        return nil
    }
}
