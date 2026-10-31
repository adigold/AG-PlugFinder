import Carbon.HIToolbox

/// System-wide hotkeys through the Carbon hotkey API, which needs no permission. Which keys do
/// what is set in Settings > Shortcuts (BL-51); the defaults are Control Option P (open the
/// window), O and W (plugin windows) and 1 to 9 (number keys).
final class HotKey {
    static let shared = HotKey()
    private var refs: [UInt32: EventHotKeyRef] = [:]
    private var handlerInstalled = false

    @MainActor static var display: String { Shortcuts.shared.label(.openLibrary).ifEmpty("the AG PlugFinder shortcut") }
    @MainActor static var openAllDisplay: String { Shortcuts.shared.label(.openAll).ifEmpty("No shortcut") }
    @MainActor static var closeAllDisplay: String { Shortcuts.shared.label(.closeAll).ifEmpty("No shortcut") }
    @MainActor static func pinDisplay(_ n: Int) -> String { Shortcuts.shared.label(.pin(n)).ifEmpty("Key \(n)") }

    /// Registers every shortcut that is set.
    @MainActor
    func apply() {
        installHandler()
        suspend()
        for a in ShortcutAction.allCases {
            guard let c = Shortcuts.shared.combo(a) else { continue }
            var ref: EventHotKeyRef?
            let hk = EventHotKeyID(signature: OSType(0x4147_5046), id: a.hotKeyID) // "AGPF"
            RegisterEventHotKey(c.keyCode, c.mods, hk, GetApplicationEventTarget(), 0, &ref)
            if let ref { refs[a.hotKeyID] = ref }
        }
    }

    /// Lets every key through, while a shortcut is being recorded.
    func suspend() {
        for ref in refs.values { UnregisterEventHotKey(ref) }
        refs = [:]
    }

    /// Pinning something to a number changes what the key does, not which keys are registered.
    @MainActor
    func registerPins() { if Shortcuts.shared.recording == nil { apply() } }

    private func installHandler() {
        guard !handlerInstalled else { return }
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
            var hk = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                              nil, MemoryLayout<EventHotKeyID>.size, nil, &hk)
            let id = hk.id
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    if let a = ShortcutAction.allCases.first(where: { $0.hotKeyID == id }) { Shortcuts.shared.run(a) }
                }
            }
            return noErr
        }, 1, &spec, nil, nil)
        handlerInstalled = true
    }
}
