import AppKit
import Combine
import Darwin
import SwiftTerm

@MainActor
final class HermesTerminalSession: NSObject, ObservableObject {
    struct LaunchOverride: Equatable {
        let executable: String
        let args: [String]
        let currentDirectory: String?

        init(executable: String, args: [String] = [], currentDirectory: String? = nil) {
            self.executable = executable
            self.args = args
            self.currentDirectory = currentDirectory
        }
    }

    private struct ShutdownTarget {
        let generation: UInt
        let leaderPID: pid_t
        let sessionID: pid_t
        let processGroups: Set<pid_t>
    }

    enum State: Equatable {
        case idle
        case launching
        case running
        case exited(Int32?)
        case failed
    }

    @Published private(set) var state: State = .idle
    @Published private(set) var error: String?
    @Published var executablePath: String {
        didSet {
            defaults.set(executablePath, forKey: Self.executablePathDefaultsKey)
        }
    }

    let terminalView: LocalProcessTerminalView

    var hasOwnedProcesses: Bool { ownedSessionID != nil || activeShutdown != nil }

    var isRunning: Bool { hasOwnedProcesses || state == .launching }

    var statusTitle: String {
        switch state {
        case .idle:
            return "Terminal ready"
        case .launching:
            return "Starting Hermes"
        case .running:
            return "Hermes terminal"
        case .exited(let code):
            return code.map { "Hermes exited (\($0))" } ?? "Hermes exited"
        case .failed:
            return "Hermes could not start"
        }
    }

    private static let executablePathDefaultsKey = "hermes.terminalExecutablePath"
    private let defaults: UserDefaults
    private let launchOverride: LaunchOverride?
    private var startRequested = false
    private var didRequestShutdown = false
    private var ownedSessionID: pid_t?
    private var launchGeneration: UInt = 0
    private var activeShutdown: ShutdownTarget?

    init(defaults: UserDefaults = .standard, launchOverride: LaunchOverride? = nil) {
        self.defaults = defaults
        self.launchOverride = launchOverride
        executablePath = defaults.string(forKey: Self.executablePathDefaultsKey) ?? ""
        let font = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
        terminalView = LocalProcessTerminalView(
            frame: .zero,
            font: font,
            options: TerminalOptions(cols: 100, rows: 30, scrollback: 5_000)
        )
        super.init()

        terminalView.processDelegate = self
        terminalView.wantsLayer = true
        terminalView.nativeBackgroundColor = .black
        terminalView.backgroundOpacity = 0
        terminalView.nativeForegroundColor = NSColor(calibratedWhite: 0.88, alpha: 1)
        terminalView.appearance = NSAppearance(named: .darkAqua)
    }

    func ensureStarted() {
        guard state == .idle, ownedSessionID == nil, !startRequested else { return }
        startRequested = true
        startAfterLayoutIfNeeded()
    }

    func startAfterLayoutIfNeeded() {
        guard startRequested,
              terminalView.bounds.width > 1,
              terminalView.bounds.height > 1,
              ownedSessionID == nil else { return }

        startRequested = false
        didRequestShutdown = false
        error = nil
        state = .launching
        if let launchOverride {
            terminalView.startProcess(
                executable: launchOverride.executable,
                args: launchOverride.args,
                environment: childEnvironment(),
                currentDirectory: launchOverride.currentDirectory
            )
        } else {
            terminalView.startProcess(
                executable: "/bin/zsh",
                args: ["-l", "-i", "-c", launchCommand],
                environment: childEnvironment(),
                currentDirectory: FileManager.default.homeDirectoryForCurrentUser.path
            )
        }

        if terminalView.process.running {
            ownedSessionID = terminalView.process.shellPid
            launchGeneration &+= 1
            state = .running
        } else {
            state = .failed
            error = "Could not create the Hermes terminal process."
        }
    }

    func focus() {
        guard let window = terminalView.window else { return }
        window.makeFirstResponder(terminalView)
    }

    func shutdown() async {
        startRequested = false
        guard activeShutdown == nil,
              let ownedSessionID else { return }
        didRequestShutdown = true
        let target = makeShutdownTarget(sessionID: ownedSessionID)
        activeShutdown = target
        signalOwnedProcessGroups(target, signal: SIGTERM)

        if await waitForShutdown(target, attempts: 15) {
            finishShutdown(target)
            return
        }
        guard activeShutdown?.generation == target.generation,
              launchGeneration == target.generation else { return }
        signalOwnedProcessGroups(target, signal: SIGKILL)
        if await waitForShutdown(target, attempts: 10) {
            finishShutdown(target)
            return
        }

        guard activeShutdown?.generation == target.generation else { return }
        state = .failed
        error = "Hermes did not exit after termination; its process could not be reaped."
    }

    func restart() {
        guard activeShutdown == nil,
              ownedSessionID == nil,
              state != .launching else { return }
        state = .idle
        error = nil
        startRequested = false
        ensureStarted()
    }

    private func childEnvironment() -> [String] {
        var environment = ProcessInfo.processInfo.environment
        environment["TERM"] = "xterm-256color"
        environment["COLORTERM"] = "truecolor"
        environment["TERM_PROGRAM"] = "NotchPilot"
        if environment["LANG"]?.isEmpty != false {
            environment["LANG"] = "en_US.UTF-8"
        }
        return environment.map { "\($0.key)=\($0.value)" }
    }

    private var launchCommand: String {
        let configuredPath = executablePath.trimmingCharacters(in: .whitespacesAndNewlines)
        if !configuredPath.isEmpty {
            let quotedPath = Self.shellQuoted(configuredPath)
            return """
            if [[ -x \(quotedPath) ]]; then
              exec \(quotedPath)
            fi
            print -u2 -- "NotchPilot: Hermes executable is not executable:"
            print -u2 -- \(quotedPath)
            exit 127
            """
        }

        return """
        if [[ -x \"$HOME/.local/bin/hermes\" ]]; then
          exec \"$HOME/.local/bin/hermes\"
        elif command -v hermes >/dev/null 2>&1; then
          exec hermes
        fi
        print -u2 -- "NotchPilot: Hermes was not found. Set its executable path in Settings or install ~/.local/bin/hermes."
        exit 127
        """
    }

    static func shellQuoted(_ value: String) -> String {
        "'\(value.replacingOccurrences(of: "'", with: "'\\''"))'"
    }

    private func makeShutdownTarget(sessionID: pid_t) -> ShutdownTarget {
        let leaderPID = sessionID
        var ownedGroups = Set<pid_t>()
        if leaderPID > 0,
           getsid(leaderPID) == sessionID,
           getpgid(leaderPID) == leaderPID {
            ownedGroups.insert(leaderPID)
        }
        if let process = terminalView.process,
           process.childfd >= 0,
           tcgetsid(process.childfd) == sessionID {
            let foregroundGroup = tcgetpgrp(process.childfd)
            if foregroundGroup > 0 {
                ownedGroups.insert(foregroundGroup)
            }
        }

        return ShutdownTarget(
            generation: launchGeneration,
            leaderPID: leaderPID,
            sessionID: sessionID,
            processGroups: ownedGroups
        )
    }

    private func signalOwnedProcessGroups(_ target: ShutdownTarget, signal: Int32) {
        guard activeShutdown?.generation == target.generation else { return }
        for group in target.processGroups where isOwnedProcessGroup(group, target: target) {
            _ = kill(-group, signal)
        }
    }

    private func waitForShutdown(_ target: ShutdownTarget, attempts: Int) async -> Bool {
        for _ in 0..<attempts {
            guard activeShutdown?.generation == target.generation,
                  launchGeneration == target.generation else { return false }
            if shutdownCompleted(target) { return true }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        return shutdownCompleted(target)
    }

    private func shutdownCompleted(_ target: ShutdownTarget) -> Bool {
        guard ownedSessionID == nil else { return false }
        return !target.processGroups.contains { isOwnedProcessGroup($0, target: target) }
    }

    private func isOwnedProcessGroup(_ group: pid_t, target: ShutdownTarget) -> Bool {
        guard processGroupExists(group) else { return false }

        if getsid(group) == target.sessionID, getpgid(group) == group {
            return true
        }

        guard let process = terminalView.process,
              process.childfd >= 0,
              tcgetsid(process.childfd) == target.sessionID else { return false }
        return tcgetpgrp(process.childfd) == group
    }

    private func processGroupExists(_ group: pid_t) -> Bool {
        guard group > 0 else { return false }
        errno = 0
        return kill(-group, 0) == 0 || errno == EPERM
    }

    private func finishShutdown(_ target: ShutdownTarget) {
        guard activeShutdown?.generation == target.generation else { return }
        activeShutdown = nil
        didRequestShutdown = false
        state = .idle
        error = nil
    }

    private func processDidTerminate(exitCode: Int32?) {
        if didRequestShutdown,
           activeShutdown?.generation == launchGeneration {
            state = .idle
            ownedSessionID = nil
            return
        }

        let commandExitCode = exitCode.map(Self.normalizedExitCode)
        state = .exited(commandExitCode)
        ownedSessionID = nil
        if commandExitCode == 127 {
            error = "Hermes was not found or is not executable. Check the executable path in Settings."
        } else if commandExitCode == 0 {
            error = nil
        } else {
            error = "Hermes terminal exited. Restart it when you are ready."
        }
    }

    private static func normalizedExitCode(_ waitStatus: Int32) -> Int32 {
        let signal = waitStatus & 0x7f
        if signal == 0 { return (waitStatus >> 8) & 0xff }
        if signal != 0x7f { return 128 + signal }
        return waitStatus
    }
}

extension HermesTerminalSession: LocalProcessTerminalViewDelegate {
    nonisolated func sizeChanged(source: LocalProcessTerminalView, newCols: Int, newRows: Int) {}

    nonisolated func setTerminalTitle(source: LocalProcessTerminalView, title: String) {}

    nonisolated func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}

    nonisolated func processTerminated(source: TerminalView, exitCode: Int32?) {
        Task { @MainActor [weak self] in
            self?.processDidTerminate(exitCode: exitCode)
        }
    }
}
