import Carbon.HIToolbox

/// System-wide hotkeys, through the Carbon hotkey API, which needs no permission:
/// Ctrl+Option+P opens the picker, Ctrl+Option+1…9 insert what is pinned to that number (BL-26).
final class HotKey {
    static let shared = HotKey()
    private var refs: [UInt32: EventHotKeyRef] = [:]
    private var handlerInstalled = false
    fileprivate var actions: [UInt32: () -> Void] = [:]

    static let display = "⌃⌥P"
    static func pinDisplay(_ n: Int) -> String { "⌃⌥\(n)" }

    private static let digitKeys: [Int: Int] = [
        1: kVK_ANSI_1, 2: kVK_ANSI_2, 3: kVK_ANSI_3, 4: kVK_ANSI_4, 5: kVK_ANSI_5,
        6: kVK_ANSI_6, 7: kVK_ANSI_7, 8: kVK_ANSI_8, 9: kVK_ANSI_9,
    ]

    func register(_ action: @escaping () -> Void) {
        installHandler()
        set(id: 1, key: kVK_ANSI_P, action: action)
    }

    /// Registers Ctrl+Option+n only for the numbers that have something pinned.
    @MainActor
    func registerPins() {
        installHandler()
        for n in 1...9 {
            let id = UInt32(10 + n)
            if let target = UserLibrary.shared.pinTarget(n) {
                set(id: id, key: Self.digitKeys[n]!) { Task { @MainActor in InsertRunner.run(target) } }
            } else {
                remove(id: id)
            }
        }
    }

    private func set(id: UInt32, key: Int, action: @escaping () -> Void) {
        actions[id] = action
        remove(id: id, keepAction: true)
        var ref: EventHotKeyRef?
        let hk = EventHotKeyID(signature: OSType(0x4147_5046), id: id) // "AGPF"
        RegisterEventHotKey(UInt32(key), UInt32(controlKey | optionKey), hk, GetApplicationEventTarget(), 0, &ref)
        if let ref { refs[id] = ref }
    }

    private func remove(id: UInt32, keepAction: Bool = false) {
        if let ref = refs[id] { UnregisterEventHotKey(ref) }
        refs[id] = nil
        if !keepAction { actions[id] = nil }
    }

    private func installHandler() {
        guard !handlerInstalled else { return }
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
            var hk = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                              nil, MemoryLayout<EventHotKeyID>.size, nil, &hk)
            let id = hk.id
            DispatchQueue.main.async { HotKey.shared.actions[id]?() }
            return noErr
        }, 1, &spec, nil, nil)
        handlerInstalled = true
    }
}
