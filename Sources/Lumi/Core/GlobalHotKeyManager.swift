import Carbon.HIToolbox
import Foundation

/// Zero-permission system-wide hotkey manager powered by macOS Carbon RegisterEventHotKey.
/// Works reliably without requiring Accessibility or Input Monitoring permissions.
/// Preserves the previously registered hotkey if a newly chosen shortcut conflicts with another app.
@MainActor
final class GlobalHotKeyManager {
    private var hotKeyRef: EventHotKeyRef?
    private var eventHandlerRef: EventHandlerRef?
    private var currentPreset: GlobalHotKeyPreset = .off
    private var onTrigger: (() -> Void)?

    private static weak var activeInstance: GlobalHotKeyManager?

    init() {
        GlobalHotKeyManager.activeInstance = self
    }

    deinit {
        if let hk = hotKeyRef { UnregisterEventHotKey(hk) }
        if let handler = eventHandlerRef { RemoveEventHandler(handler) }
    }

    /// Registers `preset` globally. Returns `true` on success; on conflict (`OSStatus != noErr`),
    /// restores the previous hotkey and returns `false`.
    @discardableResult
    func register(preset: GlobalHotKeyPreset, onTrigger: @escaping () -> Void) -> Bool {
        let previousPreset = currentPreset
        self.onTrigger = onTrigger

        if preset == .off {
            unregister()
            currentPreset = .off
            return true
        }

        guard ensureHandlerInstalled() else {
            return false
        }

        // Unregister current before trying the new key combo (same EventHotKeyID)
        unregister()
        if registerCarbonHotKey(preset: preset) {
            currentPreset = preset
            return true
        }

        // Conflict or OS failure -> cleanly restore the previous working hotkey
        if previousPreset != .off, registerCarbonHotKey(preset: previousPreset) {
            currentPreset = previousPreset
        } else {
            currentPreset = .off
        }
        return false
    }

    func unregister() {
        if let hk = hotKeyRef {
            UnregisterEventHotKey(hk)
            hotKeyRef = nil
        }
    }

    private func ensureHandlerInstalled() -> Bool {
        if eventHandlerRef != nil { return true }
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
        let status = InstallEventHandler(
            GetApplicationEventTarget(),
            callback,
            1,
            &eventType,
            nil,
            &eventHandlerRef
        )
        return status == noErr
    }

    private func registerCarbonHotKey(preset: GlobalHotKeyPreset) -> Bool {
        let keyCode = UInt32(kVK_ANSI_L)
        let modifiers: UInt32
        switch preset {
        case .off:
            return true
        case .optionL:
            modifiers = UInt32(optionKey)
        case .controlOptionL:
            modifiers = UInt32(controlKey | optionKey)
        case .commandShiftL:
            modifiers = UInt32(cmdKey | shiftKey)
        }
        let hotKeyID = EventHotKeyID(signature: OSType(0x4C554D49), id: 1) // 'LUMI'
        var newRef: EventHotKeyRef?
        let status = RegisterEventHotKey(
            keyCode,
            modifiers,
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &newRef
        )
        if status == noErr, let newRef {
            hotKeyRef = newRef
            return true
        }
        return false
    }
}
