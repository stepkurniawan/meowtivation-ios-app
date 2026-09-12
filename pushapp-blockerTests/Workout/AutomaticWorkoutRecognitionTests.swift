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
