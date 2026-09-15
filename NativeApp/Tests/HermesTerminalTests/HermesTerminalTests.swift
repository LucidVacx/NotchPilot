import AppKit
import Darwin
import Foundation
import SwiftTerm
import XCTest
import SwiftUI
@testable import NotchPilot

@MainActor
final class HermesTerminalTests: XCTestCase {
    private let pollInterval: UInt64 = 25_000_000
    private let timeout: UInt64 = 4_000_000_000
    private var sessions: [HermesTerminalSession] = []
    private var windows: [NSWindow] = []

    override func tearDown() async throws {
        for session in sessions {
            await session.shutdown()
        }
        sessions.removeAll()
        windows.removeAll()
        try await super.tearDown()
    }

    func testDefersLaunchUntilTerminalHasUsableGeometry() async throws {
        let session = makeSession(command: "while :; do sleep 1; done")

        session.ensureStarted()
        try await Task.sleep(nanoseconds: 150_000_000)
        XCTAssertEqual(session.state, .idle)
        XCTAssertFalse(session.isRunning)

        install(session, in: makeWindow(size: NSSize(width: 720, height: 360)))
        try await waitUntil("PTY launches after layout") { session.isRunning }
        XCTAssertEqual(session.state, .running)
    }

    func testPTYProvidesTerminalEnvironmentAndCarriesInputToChildAndScreen() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let probe = root.appendingPathComponent("pty-probe.txt")
        let marker = "input-\(UUID().uuidString)"
        let command = """
        printf 'READY\\n'
        IFS= read -r received
        printf 'TTY=%s TERM=%s INPUT=%s\\n' "$(test -t 0 && printf yes || printf no)" "$TERM" "$received" > \(shellQuoted(probe.path))
        printf 'REPLY:%s\\n' "$received"
        """
        let session = makeSession(command: command)

        install(session, in: makeWindow(size: NSSize(width: 760, height: 420)))
        session.ensureStarted()
        try await waitUntil("shell starts") { session.isRunning }
        try await waitUntil("child prompt appears") { self.terminalText(session).contains("READY") }

        session.terminalView.send(txt: marker + "\n")
        try await waitForFile(probe, description: "child receives terminal input")

        let result = try String(contentsOf: probe, encoding: .utf8)
        XCTAssertTrue(result.contains("TTY=yes"), result)
        XCTAssertTrue(result.contains("TERM=xterm-256color"), result)
        XCTAssertTrue(result.contains("INPUT=\(marker)"), result)
        try await waitUntil("child reply is rendered") { self.terminalText(session).contains("REPLY:\(marker)") }
    }

    func testResizingWindowUpdatesThePTYAndHidingDoesNotReplaceItsProcess() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let initialSize = root.appendingPathComponent("initial-size.txt")
        let resizedSize = root.appendingPathComponent("resized-size.txt")
        let command = """
        IFS= read -r _
        stty size > \(shellQuoted(initialSize.path))
        IFS= read -r _
        stty size > \(shellQuoted(resizedSize.path))
        while :; do sleep 1; done
        """
        let session = makeSession(command: command)
        let window = makeWindow(size: NSSize(width: 520, height: 240))
        install(session, in: window)
        session.ensureStarted()
        try await waitUntil("shell starts") { session.isRunning }
        let initialPID = session.terminalView.process.shellPid
        XCTAssertGreaterThan(initialPID, 0)
        session.terminalView.send(txt: "measure-initial\n")
        try await waitForFile(initialSize, description: "initial PTY size")

        window.setContentSize(NSSize(width: 980, height: 620))
        window.contentView?.layoutSubtreeIfNeeded()
        session.terminalView.layoutSubtreeIfNeeded()
        try await Task.sleep(nanoseconds: 200_000_000)
        session.terminalView.send(txt: "measure-resized\n")
        try await waitForFile(resizedSize, description: "resized PTY size")

        let initialDimensions = try terminalDimensions(in: initialSize)
        let resizedDimensions = try terminalDimensions(in: resizedSize)
        XCTAssertTrue(
            initialDimensions.0 != resizedDimensions.0 || initialDimensions.1 != resizedDimensions.1,
            "stty did not observe the window resize"
        )
        XCTAssertGreaterThan(resizedDimensions.0, 0)
        XCTAssertGreaterThan(resizedDimensions.1, 0)

        let dimensions = try String(contentsOf: resizedSize, encoding: .utf8)
            .split(whereSeparator: \.isWhitespace)
            .compactMap { Int($0) }
        XCTAssertEqual(dimensions.count, 2, dimensions.description)
        XCTAssertGreaterThan(dimensions[0], 0, dimensions.description)
        XCTAssertGreaterThan(dimensions[1], 0, dimensions.description)

        window.orderOut(nil)
        try await Task.sleep(nanoseconds: 120_000_000)
        XCTAssertTrue(session.isRunning)
        XCTAssertEqual(session.terminalView.process.shellPid, initialPID)
        window.orderFrontRegardless()
        try await Task.sleep(nanoseconds: 120_000_000)
        XCTAssertTrue(session.isRunning)
        XCTAssertEqual(session.terminalView.process.shellPid, initialPID)
    }

    func testExitStatusDoesNotRelaunchAndRestartIsExplicit() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let launches = root.appendingPathComponent("launches.txt")
        let command = "printf '%s\\n' \"$$\" >> \(shellQuoted(launches.path)); exit 23"
        let session = makeSession(command: command)

        install(session, in: makeWindow(size: NSSize(width: 720, height: 360)))
        session.ensureStarted()
        try await waitForFile(launches, description: "first command launch")
        try await waitUntil("exit status arrives") {
            if case .exited(23) = session.state { return true }
            return false
        }
        try await Task.sleep(nanoseconds: 250_000_000)
        XCTAssertEqual(try launchPIDs(in: launches).count, 1)
        XCTAssertFalse(session.isRunning)

        session.restart()
        try await waitUntil("explicit restart completes") { (try? self.launchPIDs(in: launches).count) == 2 }
        try await waitUntil("restarted command exits") {
            if case .exited(23) = session.state { return true }
            return false
        }
        XCTAssertEqual(try launchPIDs(in: launches).count, 2)
    }

    func testMissingExecutableReports127AndNeverLoopsUntilRestart() async throws {
        let session = HermesTerminalSession(
            defaults: makeDefaults(),
            launchOverride: .init(executable: "/private/tmp/notchpilot-missing-\(UUID().uuidString)")
        )
        sessions.append(session)

        install(session, in: makeWindow(size: NSSize(width: 720, height: 360)))
        session.ensureStarted()
        try await waitUntil("missing executable exits") {
            if case .exited(127) = session.state { return true }
            return false
        }
        XCTAssertEqual(session.error, "Hermes was not found or is not executable. Check the executable path in Settings.")
        try await Task.sleep(nanoseconds: 250_000_000)
        XCTAssertFalse(session.isRunning)
        XCTAssertEqual(session.state, .exited(127))
    }

    func testShutdownReapsAChildThatIgnoresTERM() async throws {
        let session = makeSession(command: "trap '' TERM; printf 'TERM-READY\\n'; while :; do sleep 1; done")
        install(session, in: makeWindow(size: NSSize(width: 720, height: 360)))
        session.ensureStarted()
        try await waitUntil("TERM-resistant child starts") { self.terminalText(session).contains("TERM-READY") }
        let pid = session.terminalView.process.shellPid
        XCTAssertGreaterThan(pid, 0)

        await session.shutdown()

        try await waitUntil("shutdown reaps terminal child") {
            errno = 0
            return kill(pid, 0) == -1 && errno == ESRCH
        }
        XCTAssertFalse(session.isRunning)
    }

    func testShutdownKillsForegroundProcessGroupWhenItsChildIgnoresTERM() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let childPIDFile = root.appendingPathComponent("foreground-child.pid")
        let command = """
        import os, signal, sys, time
        child = os.fork()
        if child == 0:
            os.setpgid(0, 0)
            signal.signal(signal.SIGTERM, signal.SIG_IGN)
            signal.signal(signal.SIGHUP, signal.SIG_IGN)
            while os.tcgetpgrp(0) != os.getpgrp():
                time.sleep(0.01)
            with open(sys.argv[1] + '.tmp', 'w') as output:
                output.write(str(os.getpid()))
            os.replace(sys.argv[1] + '.tmp', sys.argv[1])
            while True:
                signal.pause()
        else:
            os.setpgid(child, child)
            os.tcsetpgrp(0, child)
            while True:
                signal.pause()
        """
        let session = HermesTerminalSession(
            defaults: makeDefaults(),
            launchOverride: .init(executable: "/usr/bin/python3", args: ["-c", command, childPIDFile.path])
        )
        sessions.append(session)
        install(session, in: makeWindow(size: NSSize(width: 720, height: 360)))
        session.ensureStarted()
        try await waitForFile(childPIDFile, description: "foreground child starts")
        let childPID = try readPID(from: childPIDFile)
        let foregroundGroup = tcgetpgrp(session.terminalView.process.childfd)
        XCTAssertGreaterThan(foregroundGroup, 0)
        XCTAssertEqual(getpgid(childPID), foregroundGroup)
        XCTAssertNotEqual(foregroundGroup, session.terminalView.process.shellPid,
                          "Fixture must create a separate foreground process group")

        await session.shutdown()

        try await waitUntil("foreground TERM-resistant child is reaped") {
            errno = 0
            return kill(childPID, 0) == -1 && errno == ESRCH
        }
        XCTAssertFalse(session.isRunning)
    }

    func testConfiguredHostileExecutablePathIsQuotedBeforeItIsGivenToZsh() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let marker = "quoted-fixture-\(UUID().uuidString)"
        let hostileName = "fixture ' $(printf bad) `printf bad`"
        let fixture = root.appendingPathComponent(hostileName)
        let script = "#!/bin/sh\nprintf '\(marker)\\n'\nexit 0\n"
        try Data(script.utf8).write(to: fixture)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fixture.path)
        let defaults = makeDefaults()
        defaults.set(fixture.path, forKey: "hermes.terminalExecutablePath")
        let session = HermesTerminalSession(defaults: defaults)
        sessions.append(session)

        install(session, in: makeWindow(size: NSSize(width: 720, height: 360)))
        session.ensureStarted()
        try await waitUntil("quoted executable exits normally") {
            if case .exited(0) = session.state { return true }
            return false
        }
        XCTAssertTrue(terminalText(session).contains(marker))
    }

    private func makeSession(command: String) -> HermesTerminalSession {
        let session = HermesTerminalSession(
            defaults: makeDefaults(),
            launchOverride: .init(executable: "/bin/sh", args: ["-c", command])
        )
        sessions.append(session)
        return session
    }

    private func makeDefaults() -> UserDefaults {
        let suite = "HermesTerminalTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }

    private func makeWindow(size: NSSize) -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.orderFrontRegardless()
        windows.append(window)
        return window
    }

    private func install(_ session: HermesTerminalSession, in window: NSWindow) {
        let host = NSHostingView(rootView: TerminalSurfaceView(session: session))
        host.frame = window.contentView?.bounds ?? .zero
        host.autoresizingMask = [.width, .height]
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        session.terminalView.layoutSubtreeIfNeeded()
    }

    private func waitForFile(_ url: URL, description: String) async throws {
        try await waitUntil(description) { FileManager.default.fileExists(atPath: url.path) }
    }

    private func waitUntil(_ description: String, condition: @escaping @MainActor () -> Bool) async throws {
        let deadline = DispatchTime.now().uptimeNanoseconds + timeout
        while DispatchTime.now().uptimeNanoseconds < deadline {
            if condition() { return }
            try await Task.sleep(nanoseconds: pollInterval)
        }
        XCTFail("Timed out waiting for \(description)")
        throw WaitFailure.timedOut(description)
    }

    private func terminalText(_ session: HermesTerminalSession) -> String {
        let data = session.terminalView.getTerminal().getBufferAsData()
        return String(data: data, encoding: .utf8) ?? ""
    }

    private func launchPIDs(in url: URL) throws -> [String] {
        try String(contentsOf: url, encoding: .utf8)
            .split(whereSeparator: \.isNewline)
            .map(String.init)
    }

    private func terminalDimensions(in url: URL) throws -> (Int, Int) {
        let values = try String(contentsOf: url, encoding: .utf8)
            .split(whereSeparator: \.isWhitespace)
            .compactMap { Int($0) }
        guard values.count == 2 else {
            throw WaitFailure.timedOut("valid stty dimensions")
        }
        return (values[0], values[1])
    }

    private func readPID(from url: URL) throws -> pid_t {
        guard let pid = pid_t(try String(contentsOf: url, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)) else {
            throw WaitFailure.timedOut("valid fixture pid")
        }
        return pid
    }

    private func makeTemporaryDirectory() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("HermesTerminalTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func shellQuoted(_ value: String) -> String {
        "'\(value.replacingOccurrences(of: "'", with: "'\\''"))'"
    }

    private enum WaitFailure: Error {
        case timedOut(String)
    }
}
