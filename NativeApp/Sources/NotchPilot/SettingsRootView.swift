import SwiftUI

struct SettingsRootView: View {
    @ObservedObject var model: AppModel
    @ObservedObject private var theme: NotchThemeController
    @ObservedObject private var terminal: HermesTerminalSession

    init(model: AppModel) {
        self.model = model
        theme = model.theme
        terminal = model.terminal
    }

    var body: some View {
        Form {
            Section("Access") {
                Toggle("Global keyboard shortcut", isOn: $model.shortcutEnabled)
                Picker("Shortcut", selection: $model.shortcutChoice) {
                    Text("Option–Space").tag("option-space")
                    Text("Control–Space").tag("control-space")
                    Text("Command–Shift–Space").tag("command-shift-space")
                }
                Toggle("Haptic feedback", isOn: $model.hapticsEnabled)
                Toggle("Open at login", isOn: Binding(
                    get: { model.launchAtLogin }, set: { model.setLaunchAtLogin($0) }
                ))
            }
            Section("Appearance") {
                Picker("Accent", selection: Binding(get: { theme.mode }, set: { theme.select($0) })) {
                    ForEach(NotchAppearanceMode.allCases) { mode in
                        Text(mode.title).tag(mode)
                    }
                }
            }
            Section("Hermes terminal") {
                TextField("Executable path (optional)", text: $terminal.executablePath)
                    .help("Leave empty to find Hermes automatically. Changes apply on the next launch.")
                Text("Pull down at the notch or use the shortcut to open Hermes. Hide the panel to leave the session running. Quit NotchPilot to close it.")
                Text("Use Hermes’ own commands inside the terminal for history, models, skills and configuration.")
                    .foregroundStyle(.secondary)
                Text("Native terminal powered by SwiftTerm (MIT license).")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if let error = model.settingsError {
                Text(error).foregroundStyle(.orange)
            }
        }
        .formStyle(.grouped)
        .frame(width: 520, height: 480)
    }
}
