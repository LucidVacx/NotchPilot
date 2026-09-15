import Carbon
import Foundation

@MainActor
final class GlobalShortcutMonitor {
    private var hotKey: EventHotKeyRef?
    private var handler: EventHandlerRef?
    private let action: () -> Void

    init(choice: String, action: @escaping () -> Void) {
        self.action = action
        install(choice: choice)
    }

    deinit {
        if let hotKey { UnregisterEventHotKey(hotKey) }
        if let handler { RemoveEventHandler(handler) }
    }

    private func install(choice: String) {
        var specification = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(
            GetApplicationEventTarget(),
            { _, _, userData in
                guard let userData else { return noErr }
                let monitor = Unmanaged<GlobalShortcutMonitor>.fromOpaque(userData).takeUnretainedValue()
                Task { @MainActor in monitor.action() }
                return noErr
            },
            1,
            &specification,
            Unmanaged.passUnretained(self).toOpaque(),
            &handler
        )
        let identifier = EventHotKeyID(signature: OSType(0x4E50544C), id: 1) // NPTL
        let modifiers: UInt32
        switch choice {
        case "control-space": modifiers = UInt32(controlKey)
        case "command-shift-space": modifiers = UInt32(cmdKey | shiftKey)
        default: modifiers = UInt32(optionKey)
        }
        RegisterEventHotKey(UInt32(kVK_Space), modifiers, identifier, GetApplicationEventTarget(), 0, &hotKey)
    }
}
