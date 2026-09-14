//
//  meowtivationUITests.swift
//  meowtivationUITests
//
//  Created by stephen on 01.09.26.
//

import XCTest

final class MeowtivationUITests: XCTestCase {
    override func setUpWithError() throws {
        // Put setup code here. This method is called before the invocation of each test method in the class.

        // In UI tests it is usually best to stop immediately when a failure occurs.
        continueAfterFailure = false

        // In UI tests it’s important to set the initial state - such as interface orientation - required for your tests
        // before they run. The setUp method is a good place to do this.
    }

    override func tearDownWithError() throws {
        // Put teardown code here. This method is called after the invocation of each test method in the class.
    }

    @MainActor
    func testStartWorkoutOpensTheNextExerciseSetup() throws {
        let app = XCUIApplication()
        app.launch()

        XCTAssertTrue(app.staticTexts["No apps selected"].waitForExistence(timeout: 2))
        XCTAssertTrue(app.staticTexts["Next: Push-up"].exists)
        XCTAssertTrue(app.staticTexts["0 of 10 reps today"].exists)

        let startWorkout = app.buttons["Start Workout"]
        XCTAssertTrue(startWorkout.waitForExistence(timeout: 2))
        startWorkout.tap()
        XCTAssertTrue(app.staticTexts["Push-up setup"].waitForExistence(timeout: 2))

        app.buttons["Done"].tap()
        XCTAssertTrue(startWorkout.waitForExistence(timeout: 2))
    }

    @MainActor
    func testLaunchPerformance() throws {
        // This measures how long it takes to launch your application.
        measure(metrics: [XCTApplicationLaunchMetric()]) {
            XCUIApplication().launch()
        }
    }
}
