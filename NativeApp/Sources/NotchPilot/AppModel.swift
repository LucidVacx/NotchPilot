import AppKit
import Combine
import ServiceManagement

@MainActor
final class AppModel: ObservableObject {
    @Published var presentationState: NotchPresentationState = .hidden
    @Published var isManuallyHidden = true
    @Published var shortcutEnabled: Bool { didSet { defaults.set(shortcutEnabled, forKey: "shortcutEnabled") } }
    @Published var shortcutChoice: String { didSet { defaults.set(shortcutChoice, forKey: "shortcutChoice") } }
    @Published var hapticsEnabled: Bool { didSet { defaults.set(hapticsEnabled, forKey: "hapticsEnabled") } }
    @Published private(set) var launchAtLogin = false
    @Published private(set) var settingsError: String?
    @Published var activeDisplayHasNotch = false
    @Published var activeNotchWidth: CGFloat = 180
    @Published var activeNotchDepth: CGFloat = 32
    @Published var activeMenuBarHeight: CGFloat = 24

    let terminal: HermesTerminalSession
    let theme: NotchThemeController
    var onPanelDismissRequest: (() -> Void)?
    var onPanelShowRequest: (() -> Void)?
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard, terminal: HermesTerminalSession? = nil) {
        self.defaults = defaults
        self.terminal = terminal ?? HermesTerminalSession(defaults: defaults)
        theme = NotchThemeController(defaults: defaults)
        shortcutEnabled = defaults.object(forKey: "shortcutEnabled") as? Bool ?? true
        shortcutChoice = defaults.string(forKey: "shortcutChoice") ?? "option-space"
        hapticsEnabled = defaults.object(forKey: "hapticsEnabled") as? Bool ?? true
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }

    func start() {
        showPanel()
    }

    func showPanel() {
        onPanelShowRequest?()
        isManuallyHidden = false
        presentationState = .open
    }

    func hidePanel() {
        if let onPanelDismissRequest {
            onPanelDismissRequest()
        } else {
            completePanelDismissal()
        }
    }

    func toggleVisibilityFromShortcut() {
        if isManuallyHidden || !presentationState.isVisible { showPanel() }
        else { hidePanel() }
    }

    func completePanelDismissal() {
        isManuallyHidden = true
        presentationState = .hidden
    }

    func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled { try SMAppService.mainApp.register() }
            else { try SMAppService.mainApp.unregister() }
            launchAtLogin = SMAppService.mainApp.status == .enabled
            settingsError = SMAppService.mainApp.status == .requiresApproval
                ? "Enable NotchPilot in System Settings → General → Login Items." : nil
        } catch {
            launchAtLogin = SMAppService.mainApp.status == .enabled
            settingsError = error.localizedDescription
        }
    }

    func shutdown() async { await terminal.shutdown() }
}
