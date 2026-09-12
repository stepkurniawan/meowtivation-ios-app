import Foundation
import Testing
@testable import pushapp_blocker

struct AutomaticWorkoutRecognitionTests {
    @Test func firstPushUpRepSelectsAndCountsTheWorkout() {
        var engine = AutomaticWorkoutRecognitionEngine()
        for frame in PushUpFixtures.calibrationFrames() {
            _ = engine.consume(frame)
        }

        let updates = [
            PushUpFixtures.frame(angle: 160, time: 1.1),
            PushUpFixtures.frame(angle: 90, time: 1.3),
            PushUpFixtures.frame(angle: 160, time: 1.5)
        ].map { engine.consume($0) }

        #expect(updates.last?.selectedExercise == .pushUp)
        #expect(updates.last?.reps.count == 1)
        #expect(engine.selectedExercise == .pushUp)
    }

    @Test(arguments: [0, 1])
    func firstSquatRepSelectsAndCountsTheWorkout(_ visibleSide: Int) {
        var engine = AutomaticWorkoutRecognitionEngine()
        for frame in SquatFixtures.calibrationFrames(visibleSide: visibleSide) {
            _ = engine.consume(frame)
        }

        let updates = [
            SquatFixtures.frame(angle: 170, time: 1.1, visibleSide: visibleSide),
            SquatFixtures.frame(angle: 90, time: 1.3, visibleSide: visibleSide),
            SquatFixtures.frame(angle: 170, time: 1.5, visibleSide: visibleSide)
        ].map { engine.consume($0) }

        #expect(updates.last?.selectedExercise == .squat)
        #expect(updates.last?.reps.count == 1)
        #expect(engine.selectedExercise == .squat)
    }

    @Test(arguments: [0, 1])
    func bentArmsDoNotBlockAutomaticSquatSelection(_ visibleSide: Int) {
        func squatFrame(angle: Float, time: Double) -> PoseFrame {
            var frame = SquatFixtures.frame(angle: angle, time: time, visibleSide: visibleSide)
            let shoulder: BodyJoint = visibleSide == 0 ? .rightShoulder : .leftShoulder
            let elbow: BodyJoint = visibleSide == 0 ? .rightElbow : .leftElbow
            let wrist: BodyJoint = visibleSide == 0 ? .rightWrist : .leftWrist
            let hip = frame.joints[Squat.legChains[visibleSide][0]]!.position
            let positions: [(BodyJoint, SIMD2<Float>)] = [
                (shoulder, hip + [0, 0.25]),
                (elbow, hip + [0.15, 0.25]),
                (wrist, hip + [0.15, 0.10])
            ]
            for (joint, position) in positions {
                frame.joints[joint] = PoseJoint(position: position, imagePoint: position,
                                                confidence2D: 0.95)
            }
            return frame
        }

        var engine = AutomaticWorkoutRecognitionEngine()
        let calibration = stride(from: 0.0, through: 1.0, by: 0.1).map {
            engine.consume(squatFrame(angle: 170, time: $0))
        }
        #expect(calibration.first?.suggestedExercise == .squat)
        #expect(calibration.last?.poseReady == true)

        _ = engine.consume(squatFrame(angle: 170, time: 1.1))
        _ = engine.consume(squatFrame(angle: 90, time: 1.3))
        let result = engine.consume(squatFrame(angle: 170, time: 1.5))
        #expect(result.selectedExercise == .squat)
        #expect(result.reps.count == 1)
    }

    @Test func selectedWorkoutCannotSwitchToAnotherExercise() {
        var engine = AutomaticWorkoutRecognitionEngine()
        for frame in PushUpFixtures.calibrationFrames() {
            _ = engine.consume(frame)
        }
        _ = engine.consume(PushUpFixtures.frame(angle: 160, time: 1.1))
        _ = engine.consume(PushUpFixtures.frame(angle: 90, time: 1.3))
        let selected = engine.consume(PushUpFixtures.frame(angle: 160, time: 1.5))
        #expect(selected.selectedExercise == .pushUp)
        #expect(selected.reps.count == 1)

        let squatFrame = SquatFixtures.frame(angle: 90, time: 2.0)
        let update = engine.consume(squatFrame)
        #expect(update.selectedExercise == .pushUp)
        #expect(update.reps.isEmpty)
    }
}
