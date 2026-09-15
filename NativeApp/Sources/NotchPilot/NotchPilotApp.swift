import AppKit
import SwiftUI

@main
struct NotchPilotApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        Settings {
            SettingsRootView(model: appDelegate.model)
        }
        .commands {
            CommandGroup(replacing: .pasteboard) {
                Button("Copy") { NSApp.sendAction(#selector(NSText.copy(_:)), to: nil, from: nil) }
                    .keyboardShortcut("c", modifiers: .command)
                Button("Paste") { NSApp.sendAction(#selector(NSText.paste(_:)), to: nil, from: nil) }
                    .keyboardShortcut("v", modifiers: .command)
                Button("Select All") { NSApp.sendAction(#selector(NSText.selectAll(_:)), to: nil, from: nil) }
                    .keyboardShortcut("a", modifiers: .command)
            }
            CommandMenu("Panel") {
                Button("Show Hermes Terminal") { appDelegate.showTerminal() }
                    .keyboardShortcut("o", modifiers: [.command, .shift])
                Button("Hide Hermes Terminal") { appDelegate.model.hidePanel() }
                    .keyboardShortcut("h", modifiers: [.command, .shift])
                Button("Move to Built-in Display") { appDelegate.moveToBuiltInDisplay() }
            }
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let model = AppModel()
    private var panelController: TopEdgePanelController?
    private var statusItem: NSStatusItem?
    private var isQuitting = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        panelController = TopEdgePanelController(model: model)
        installStatusItem()
        model.start()
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard !isQuitting else { return .terminateLater }
        isQuitting = true
        Task {
            await model.shutdown()
            let closed = !model.terminal.hasOwnedProcesses
            if !closed {
                isQuitting = false
                model.showPanel()
            }
            sender.reply(toApplicationShouldTerminate: closed)
        }
        return .terminateLater
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showTerminal()
        return true
    }

    func showTerminal() { model.showPanel() }
    func moveToBuiltInDisplay() { panelController?.moveToBuiltInDisplay() }

    private func installStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = NSImage(systemSymbolName: "terminal", accessibilityDescription: "Hermes terminal")
        let menu = NSMenu()
        let show = NSMenuItem(title: "Show Hermes Terminal", action: #selector(showFromMenu), keyEquivalent: "")
        show.target = self
        menu.addItem(show)
        let hide = NSMenuItem(title: "Hide Terminal", action: #selector(hideFromMenu), keyEquivalent: "")
        hide.target = self
        menu.addItem(hide)
        menu.addItem(.separator())
        let quit = NSMenuItem(title: "Quit NotchPilot", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.addItem(quit)
        item.menu = menu
        statusItem = item
    }

    @objc private func showFromMenu() { showTerminal() }
    @objc private func hideFromMenu() { model.hidePanel() }
}
