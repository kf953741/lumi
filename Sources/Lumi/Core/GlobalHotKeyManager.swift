import Carbon.HIToolbox
import Foundation

/// Zero-permission system-wide hotkey manager powered by macOS Carbon RegisterEventHotKey.
/// Works reliably without requiring Accessibility or Input Monitoring permissions.
@MainActor
final class GlobalHotKeyManager {
    private var hotKeyRef: EventHotKeyRef?
    private var eventHandlerRef: EventHandlerRef?
    private var onTrigger: (() -> Void)?

    private static weak var activeInstance: GlobalHotKeyManager?

    init() {
        GlobalHotKeyManager.activeInstance = self
    }

    deinit {
        if let hk = hotKeyRef { UnregisterEventHotKey(hk) }
        if let handler = eventHandlerRef { RemoveEventHandler(handler) }
    }

    func register(preset: GlobalHotKeyPreset, onTrigger: @escaping () -> Void) {
        unregister()
        self.onTrigger = onTrigger
        guard preset != .off else { return }

        let keyCode = UInt32(kVK_ANSI_L)
        let modifiers: UInt32
        switch preset {
        case .off:
            return
        case .optionL:
            modifiers = UInt32(optionKey)
        case .controlOptionL:
            modifiers = UInt32(controlKey | optionKey)
        case .commandShiftL:
            modifiers = UInt32(cmdKey | shiftKey)
        }

        if eventHandlerRef == nil {
            var eventType = EventTypeSpec(
                eventClass: OSType(kEventClassKeyboard),
                eventKind: UInt32(kEventHotKeyPressed)
            )
            let callback: EventHandlerUPP = { _, _, _ in
                Task { @MainActor in
                    GlobalHotKeyManager.activeInstance?.onTrigger?()
                }
                return noErr
            }
            InstallEventHandler(
                GetApplicationEventTarget(),
                callback,
                1,
                &eventType,
                nil,
                &eventHandlerRef
            )
        }

        let hotKeyID = EventHotKeyID(signature: OSType(0x4C554D49), id: 1) // 'LUMI'
        RegisterEventHotKey(
            keyCode,
            modifiers,
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &hotKeyRef
        )
    }

    func unregister() {
        if let hk = hotKeyRef {
            UnregisterEventHotKey(hk)
            hotKeyRef = nil
        }
    }
}
