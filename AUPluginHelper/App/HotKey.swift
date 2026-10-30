import Carbon.HIToolbox

/// System-wide hotkey (Ctrl+Option+P). Uses the Carbon hotkey API, which needs no permission.
final class HotKey {
    static let shared = HotKey()
    private var ref: EventHotKeyRef?
    private var handlerInstalled = false
    fileprivate var action: (() -> Void)?

    static let display = "⌃⌥P"

    func register(_ action: @escaping () -> Void) {
        self.action = action
        if !handlerInstalled {
            var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                     eventKind: UInt32(kEventHotKeyPressed))
            InstallEventHandler(GetApplicationEventTarget(), { _, _, _ in
                DispatchQueue.main.async { HotKey.shared.action?() }
                return noErr
            }, 1, &spec, nil, nil)
            handlerInstalled = true
        }
        if let ref { UnregisterEventHotKey(ref) }
        let id = EventHotKeyID(signature: OSType(0x4155_5048), id: 1) // "AUPH"
        RegisterEventHotKey(UInt32(kVK_ANSI_P), UInt32(controlKey | optionKey), id,
                            GetApplicationEventTarget(), 0, &ref)
    }
}
