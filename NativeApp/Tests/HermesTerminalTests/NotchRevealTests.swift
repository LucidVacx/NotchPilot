import AppKit
import QuartzCore
import XCTest
@testable import NotchPilot

@MainActor
final class NotchRevealTests: XCTestCase {
    private let context = NotchRevealContext(attachmentCenterX: 450, collapseAnchorY: 640, isNotchedDisplay: true, reduceMotion: false, collapseScaleX: 0.22, collapseScaleY: 0.05)

    func testRevealHasNoOpacityDelayOrTerminalResize() async throws {
        let view = makeView()
        let frame = view.hostedView.frame
        let animator = NotchPanelRevealAnimator()
        animator.prepareReveal(in: view)
        XCTAssertEqual(view.layer?.opacity, 0)
        animator.reveal(in: view, context: context)
        XCTAssertEqual(view.layer?.opacity, 1)
        XCTAssertTrue(CATransform3DIsIdentity(view.layer!.transform))
        let mask = try XCTUnwrap(view.layer?.mask as? CAShapeLayer)
        let animation = try XCTUnwrap(mask.animation(forKey: "notchpilot.reveal") as? CABasicAnimation)
        XCTAssertEqual(animation.duration, 0.28)
        XCTAssertEqual(animation.beginTime, 0)
        XCTAssertEqual(view.hostedView.frame, frame)
        try await Task.sleep(nanoseconds: 350_000_000)
        XCTAssertNil(view.layer?.mask)
        XCTAssertEqual(view.hostedView.frame, frame)
    }

    func testReopeningInvalidatesCollapseCompletion() async throws {
        let view = makeView()
        let animator = NotchPanelRevealAnimator()
        var hidden = false
        var opened = false
        animator.collapse(in: view, context: context) { hidden = true }
        animator.reveal(in: view, context: context) { opened = true }
        try await Task.sleep(nanoseconds: 350_000_000)
        XCTAssertFalse(hidden)
        XCTAssertTrue(opened)
        XCTAssertNil(view.layer?.mask)
        XCTAssertEqual(view.layer?.opacity, 1)
    }

    func testCollapseCompletionRunsBeforeMaskIsRemoved() async throws {
        let view = makeView()
        let animator = NotchPanelRevealAnimator()
        var completed = false
        animator.collapse(in: view, context: context) {
            XCTAssertNotNil(view.layer?.mask)
            completed = true
        }
        try await Task.sleep(nanoseconds: 260_000_000)
        XCTAssertTrue(completed)
        XCTAssertNil(view.layer?.mask)
    }

    private func makeView() -> NotchPanelTransitionView {
        let view = NotchPanelTransitionView(hostedView: NSView())
        view.frame = NSRect(x: 0, y: 0, width: 900, height: 640)
        view.layoutSubtreeIfNeeded()
        return view
    }
}
