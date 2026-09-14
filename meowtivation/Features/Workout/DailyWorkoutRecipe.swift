import Foundation

/// A daily target for one supported exercise. There can be only one entry per exercise.
nonisolated struct DailyExerciseTarget: Codable, Equatable, Identifiable, Sendable {
    let exercise: WorkoutExercise
    var target: Int
    var isEnabled: Bool

    var id: WorkoutExercise {
        exercise
    }
}

/// The ordered exercise list the user must complete before the cat cafe can open.
nonisolated struct DailyWorkoutRecipe: Codable, Equatable, Sendable {
    static let defaultValue = DailyWorkoutRecipe(entries: [
        DailyExerciseTarget(exercise: .pushUp, target: 10, isEnabled: true),
        DailyExerciseTarget(exercise: .squat, target: 20, isEnabled: true),
    ])

    var entries: [DailyExerciseTarget]
}

/// Repetitions recognized on one calendar day. A new date starts with zero counts.
nonisolated struct DailyWorkoutProgress: Codable, Equatable, Sendable {
    let date: Date
    var repetitions: [WorkoutExercise: Int]

    init(date: Date, repetitions: [WorkoutExercise: Int] = [:]) {
        self.date = date
        self.repetitions = repetitions
    }
}
