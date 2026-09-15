import XCTest
@testable import NotchPilot

final class NotchWheelTests: XCTestCase {
    func testSingleTickWorksAcrossDeviceMagnitudes() {
        for magnitude in [0.01, 0.1, 1.0, 3.0, 12.0] {
            XCTAssertEqual(NotchWheelGesture.action(deltaX: 0, deltaY: -magnitude), .expand)
            XCTAssertEqual(NotchWheelGesture.action(deltaX: 0, deltaY: magnitude), .dismiss)
        }
    }

    func testReversalDoesNotRequirePauseOrMoreTicks() {
        let result = [-1.0, -1, 1, 1, -1].map { NotchWheelGesture.action(deltaX: 0, deltaY: $0) }
        XCTAssertEqual(result, [.expand, .expand, .dismiss, .dismiss, .expand])
    }

    func testHorizontalAndInvalidEventsDoNotToggle() {
        XCTAssertNil(NotchWheelGesture.action(deltaX: 1, deltaY: 0.1))
        XCTAssertNil(NotchWheelGesture.action(deltaX: 0, deltaY: 0))
        XCTAssertNil(NotchWheelGesture.action(deltaX: .nan, deltaY: 1))
        XCTAssertNil(NotchWheelGesture.action(deltaX: 0, deltaY: .infinity))
    }

    func testTrackpadStillRequiresDeliberateTravel() {
        var gesture = NotchPullGestureAccumulator()
        XCTAssertNil(gesture.ingest(deltaX: 0, deltaY: -23))
        XCTAssertEqual(gesture.ingest(deltaX: 0, deltaY: -23), .expand)
        XCTAssertNil(gesture.ingest(deltaX: 0, deltaY: 46))
        gesture.end()
        XCTAssertEqual(gesture.ingest(deltaX: 0, deltaY: 46), .dismiss)
    }
}
