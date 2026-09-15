import AppKit
import SwiftTerm
import XCTest
@testable import NotchPilot

@MainActor
final class PanelControllerTests: XCTestCase {
    private var model: AppModel!
    private var controller: TopEdgePanelController!

    override func setUp() async throws {
        _ = NSApplication.shared
        let defaults = UserDefaults(suiteName: "NotchPilot.ControllerTests.\(UUID().uuidString)")!
        defaults.set(false, forKey: "shortcutEnabled")
        defaults.set(false, forKey: "hapticsEnabled")
        let terminal = HermesTerminalSession(defaults: defaults,
            launchOverride: .init(executable: "/bin/sh", args: ["-c", "while :; do sleep 1; done"]))
        model = AppModel(defaults: defaults, terminal: terminal)
        controller = TopEdgePanelController(model: model)
    }

    override func tearDown() async throws {
        await model?.shutdown()
        controller = nil
        model = nil
    }

    func testRepeatedHideCompletesWithoutReplacingTerminal() async throws {
        model.showPanel()
        try await waitUntil { self.controller.terminalPanel.isVisible && self.model.terminal.isRunning }
        let pid = model.terminal.terminalView.process.shellPid
        let frame = controller.terminalPanel.frame
        for _ in 0..<5 { model.hidePanel() }
        try await waitUntil { !self.controller.terminalPanel.isVisible && self.model.isManuallyHidden }
        XCTAssertEqual(model.terminal.terminalView.process.shellPid, pid)
        XCTAssertEqual(controller.terminalPanel.frame, frame)
        XCTAssertTrue(model.terminal.isRunning)
        model.showPanel()
        try await waitUntil { self.controller.terminalPanel.isVisible }
        XCTAssertEqual(model.terminal.terminalView.process.shellPid, pid)
        XCTAssertEqual(controller.terminalPanel.frame, frame)
    }

    func testReopeningDuringCollapseRejectsStaleClose() async throws {
        model.showPanel()
        try await waitUntil { self.controller.terminalPanel.isVisible && self.model.terminal.isRunning }
        model.hidePanel()
        try await Task.sleep(nanoseconds: 40_000_000)
        model.showPanel()
        try await Task.sleep(nanoseconds: 400_000_000)
        XCTAssertTrue(controller.terminalPanel.isVisible)
        XCTAssertFalse(model.isManuallyHidden)
        XCTAssertTrue(model.presentationState.isVisible)
        XCTAssertNil(controller.terminalPanel.contentView?.layer?.mask)
    }

    func testDuplicateShowRetainsGeometryAndFocusCapablePanel() async throws {
        model.showPanel()
        try await waitUntil { self.controller.terminalPanel.isVisible && self.model.terminal.isRunning }
        let frame = controller.terminalPanel.frame
        let revealMask = controller.terminalPanel.contentView?.layer?.mask
        for _ in 0..<5 { model.showPanel() }
        XCTAssertTrue(controller.terminalPanel.contentView?.layer?.mask === revealMask,
                      "Duplicate show must not install another reveal animation")
        try await Task.sleep(nanoseconds: 350_000_000)
        XCTAssertEqual(controller.terminalPanel.frame, frame)
        XCTAssertTrue(controller.terminalPanel.canBecomeKey)
        XCTAssertFalse(controller.terminalPanel.canBecomeMain)
        XCTAssertTrue(controller.terminalPanel.styleMask.contains(.nonactivatingPanel))
        XCTAssertTrue(controller.terminalPanel.collectionBehavior.contains(.canJoinAllApplications))
        XCTAssertNil(controller.terminalPanel.contentView?.layer?.mask)
    }

    func testMoveToBuiltInDisplayOpensHiddenPanel() async throws {
        controller.moveToBuiltInDisplay()
        try await waitUntil { self.controller.terminalPanel.isVisible }
        XCTAssertFalse(model.isManuallyHidden)
    }

    private func waitUntil(_ predicate: () -> Bool) async throws {
        for _ in 0..<100 {
            if predicate() { return }
            try await Task.sleep(nanoseconds: 25_000_000)
        }
        XCTFail("Timed out waiting for native panel lifecycle")
        throw NSError(domain: "PanelControllerTests", code: 1)
    }
}
