<div align="center">

<img src="assets/banner.svg" alt="NotchPilot — Hermes, one gesture away" width="880">

# NotchPilot

**Your Hermes terminal, tucked into the notch.**

A native macOS companion that puts the real Hermes CLI a gesture away.

[Report an issue](https://github.com/LucidVacx/NotchPilot/issues)

macOS 15+ · Apple silicon · MIT license

</div>

## A terminal that stays out of the way

- **Pull to open.** Bring Hermes down from the notch, or use Option–Space.
- **Works over fullscreen apps.** Access the terminal while staying in your current workspace.
- **External displays, too.** A small black notch marks the top-center activation area.
- **Predictable mouse-wheel controls.** Scroll down to open and up to close while pointing at the top-center activation area of an external display.
- **A continuous dark surface.** Solid black at the notch fades gradually into a translucent terminal background, with opaque text.
- **Your session stays alive.** Hide the panel and return to the same running terminal. Quitting NotchPilot closes its attached terminal session.

NotchPilot runs your locally installed Hermes CLI inside a native terminal. Hermes owns its models, tools, approvals, configuration and conversation history. Hermes itself is not bundled or automatically installed.

## Requirements

| | Required |
|---|---|
| Mac | Apple silicon (M-series) |
| macOS | 15 Sequoia or later |
| Hermes | Hermes CLI installed and configured locally |
| Build tools | Xcode 16 or later |

## Build and run

1. Clone this repository and open `NativeApp/NotchPilot.xcodeproj` in Xcode.
2. Let Xcode resolve the pinned SwiftTerm dependency. Approve its build-tool plugin when prompted.
3. Select the **NotchPilot** scheme and **My Mac** destination.
4. Press **⌘R** to build and launch. Use **⌘U** to run the tests.

Hermes must be installed and configured separately. Quit any other running copy
of NotchPilot before launching from Xcode.

This project is distributed as source. No prebuilt installer is provided.

## Get started

- **Open / hide:** Option–Space, the menu-bar icon, or a vertical gesture at the notch/top-center activation area. Trackpads use a deliberate pull; ordinary mouse wheels are supported on external displays.
- **Hide without stopping Hermes:** use the up-chevron in the panel.
- **Commands:** type `/help` inside Hermes to see the commands supported by your installed version.
- **Settings:** use the gear in the panel to change shortcuts, appearance, startup behavior or the Hermes executable path.

NotchPilot checks `~/.local/bin/hermes`, then your login shell's PATH. If Hermes is installed elsewhere, set its executable path in Settings and restart the terminal. Existing Hermes account setup and history remain local to your Mac.

## Troubleshooting

**Hermes was not found**
Install and configure Hermes CLI first, or point NotchPilot at its executable in Settings. NotchPilot does not include a Hermes desktop app.

**The shortcut is not responding**
Check that the global shortcut is enabled in Settings, or select an alternative shortcut if another app uses Option–Space. Avoid running multiple copies of NotchPilot.

**I still see an old version**
Quit other running copies, then build and run the current checkout from Xcode.

**The background is completely black**
NotchPilot respects macOS Reduce Transparency. Explicit background colors drawn by terminal applications can also remain opaque.

## Feedback

[Open an issue](https://github.com/LucidVacx/NotchPilot/issues/new) with your NotchPilot version, macOS version, display setup, input device and steps to reproduce. Remove credentials and private conversation content from screenshots or logs before posting.

## Project layout

`NativeApp/Sources/NotchPilot` contains the panel controller, terminal session,
SwiftUI views, gesture handling and preferences. The Xcode project pins SwiftTerm
to version 1.19.0 and includes both MIT license files as app resources.

`NativeApp/Tests/HermesTerminalTests` covers the PTY lifecycle, reveal animation,
wheel input and panel transitions with local fixture processes. Physical gestures,
display hot-plugging, input methods and Hermes providers need manual testing.

## License and credits

NotchPilot source is available under the [MIT license](LICENSE).

**Hermes** provides the agent, commands, tools, approvals and conversation history.
It runs as a separately installed CLI; NotchPilot does not bundle it.
**SwiftTerm** provides the native terminal emulator and PTY transport under MIT.
Its full license is included in the app and in
[third-party notices](THIRD_PARTY_NOTICES.md).

NotchPilot is an independent companion, not an official Hermes product.
