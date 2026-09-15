import SwiftUI

struct PanelRootView: View {
    @ObservedObject var model: AppModel
    @ObservedObject private var terminal: HermesTerminalSession
    @ObservedObject private var theme: NotchThemeController
    @Environment(\.openSettings) private var openSettings
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    init(model: AppModel) {
        self.model = model
        terminal = model.terminal
        theme = model.theme
    }

    private var headerTopInset: CGFloat {
        let aboveScreen: CGFloat = model.activeDisplayHasNotch ? 0 : 14
        let notchDepth = model.activeDisplayHasNotch ? model.activeNotchDepth : 0
        return aboveScreen + max(notchDepth, model.activeMenuBarHeight, 24) + 6
    }

    var body: some View {
        VStack(spacing: 0) {
            Color.black.frame(height: headerTopInset)
            HStack(spacing: 10) {
                Image(systemName: "terminal.fill")
                    .foregroundStyle(theme.palette.accent)
                Text("Hermes").font(.system(size: 13, weight: .semibold))
                Text(terminal.statusTitle)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                Spacer()
                if !terminal.isRunning {
                    Button("Start Hermes") { terminal.restart() }
                        .buttonStyle(.borderless)
                }
                Button { openSettings() } label: { Image(systemName: "gearshape") }
                    .help("Settings")
                    .accessibilityLabel("Settings")
                Button { model.hidePanel() } label: { Image(systemName: "chevron.up") }
                    .help("Hide terminal · Hermes keeps running")
                    .accessibilityLabel("Hide terminal")
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 18)
            .frame(height: 36)
            Divider().overlay(Color.white.opacity(0.06))
            TerminalSurfaceView(session: terminal)
                .padding(.horizontal, 12)
                .padding(.top, 6)
                .padding(.bottom, 12)
            if let error = terminal.error {
                Text(error)
                    .font(.system(size: 12))
                    .foregroundStyle(.orange)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 18)
                    .padding(.bottom, 12)
            }
        }
        .background {
            GeometryReader { geometry in
                let crown = headerTopInset
                let solidEnd = min(0.4, (crown + 52) / max(1, geometry.size.height))
                if reduceTransparency {
                    Color.black
                } else {
                    LinearGradient(stops: [
                        .init(color: .black, location: 0),
                        .init(color: .black, location: solidEnd),
                        .init(color: .black.opacity(0.95), location: 0.45),
                        .init(color: .black.opacity(0.84), location: 0.72),
                        .init(color: .black.opacity(0.75), location: 1)
                    ], startPoint: .top, endPoint: .bottom)
                }
            }
            .allowsHitTesting(false)
        }
        .clipShape(UnevenRoundedRectangle(bottomLeadingRadius: 20, bottomTrailingRadius: 20))
        .overlay {
            UnevenRoundedRectangle(bottomLeadingRadius: 20, bottomTrailingRadius: 20)
                .strokeBorder(Color.white.opacity(0.12), lineWidth: 1)
                .allowsHitTesting(false)
        }
        .preferredColorScheme(.dark)
    }
}
