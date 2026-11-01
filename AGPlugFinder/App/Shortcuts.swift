import SwiftUI
import AppKit
import Carbon.HIToolbox
import Observation

/// Everything AG PlugFinder can do from the keyboard (BL-51).
enum ShortcutAction: String, CaseIterable, Identifiable, Codable {
    case openLibrary, quickPicker, miniWindow, trackPanel, openAll, closeAll, removeLast
    case saveChain, removeAllEffects, removeTurnedOff, removeAllSends
    case pointerInsert, pointerRemove, pointerToggle
    case pin1, pin2, pin3, pin4, pin5, pin6, pin7, pin8, pin9

    var id: String { rawValue }

    var pinNumber: Int? {
        rawValue.hasPrefix("pin") ? Int(rawValue.dropFirst(3)) : nil
    }

    static func pin(_ n: Int) -> ShortcutAction { ShortcutAction(rawValue: "pin\(n)") ?? .pin1 }

    var title: String {
        switch self {
        case .openLibrary: return "Open or hide AG PlugFinder"
        case .quickPicker: return "Quick picker"
        case .miniWindow: return "Mini window"
        case .trackPanel: return "This track's plugins"
        case .openAll: return "Open the track's plugins side by side"
        case .closeAll: return "Close plugin windows"
        case .removeLast: return "Remove the last plugin added"
        case .saveChain: return "Save the track as a chain"
        case .removeAllEffects: return "Remove all effects"
        case .removeTurnedOff: return "Remove the effects turned off"
        case .removeAllSends: return "Remove all sends"
        case .pointerInsert: return "Add or replace in the slot under the pointer"
        case .pointerRemove: return "Remove the plugin under the pointer"
        case .pointerToggle: return "Turn the plugin under the pointer on or off"
        default: return "Insert what is pinned to \(pinNumber ?? 0)"
        }
    }

    var group: String {
        switch self {
        case .openLibrary, .quickPicker, .miniWindow: return "Windows"
        case .trackPanel, .openAll, .closeAll, .removeLast, .saveChain, .removeAllEffects, .removeTurnedOff,
             .removeAllSends: return "The selected track"
        case .pointerInsert, .pointerRemove, .pointerToggle: return "Under the pointer in Logic"
        default: return "Number keys"
        }
    }

    /// Carbon hotkey ids; 1… in declaration order.
    var hotKeyID: UInt32 { UInt32((Self.allCases.firstIndex(of: self) ?? 0) + 1) }

    var defaultCombo: KeyCombo? {
        let co = UInt32(controlKey | optionKey)
        switch self {
        case .openLibrary: return KeyCombo(keyCode: UInt32(kVK_ANSI_P), mods: co, key: "P")
        case .openAll: return KeyCombo(keyCode: UInt32(kVK_ANSI_O), mods: co, key: "O")
        case .pointerInsert: return KeyCombo(keyCode: UInt32(kVK_ANSI_I), mods: co, key: "I")
        case .closeAll: return KeyCombo(keyCode: UInt32(kVK_ANSI_W), mods: co, key: "W")
        case .quickPicker, .miniWindow, .trackPanel, .removeLast, .saveChain, .removeAllEffects, .removeTurnedOff,
             .removeAllSends, .pointerRemove, .pointerToggle: return nil
        default:
            let digits = [kVK_ANSI_1, kVK_ANSI_2, kVK_ANSI_3, kVK_ANSI_4, kVK_ANSI_5,
                          kVK_ANSI_6, kVK_ANSI_7, kVK_ANSI_8, kVK_ANSI_9]
            let n = pinNumber ?? 1
            return KeyCombo(keyCode: UInt32(digits[n - 1]), mods: co, key: "\(n)")
        }
    }
}

/// A key and its modifiers, in Carbon's terms (what RegisterEventHotKey takes).
struct KeyCombo: Codable, Equatable, Hashable {
    var keyCode: UInt32
    var mods: UInt32
    var key: String

    static let hyperMods = UInt32(controlKey | optionKey | shiftKey | cmdKey)

    var isHyper: Bool { mods & Self.hyperMods == Self.hyperMods }

    var display: String {
        if isHyper { return "Hyper " + key }
        var s = ""
        if mods & UInt32(controlKey) != 0 { s += "⌃" }
        if mods & UInt32(optionKey) != 0 { s += "⌥" }
        if mods & UInt32(shiftKey) != 0 { s += "⇧" }
        if mods & UInt32(cmdKey) != 0 { s += "⌘" }
        return s + key
    }

    /// The same keys for a menu item.
    var eventModifiers: SwiftUI.EventModifiers {
        var m: SwiftUI.EventModifiers = []
        if mods & UInt32(controlKey) != 0 { m.insert(.control) }
        if mods & UInt32(optionKey) != 0 { m.insert(.option) }
        if mods & UInt32(shiftKey) != 0 { m.insert(.shift) }
        if mods & UInt32(cmdKey) != 0 { m.insert(.command) }
        return m
    }

    static func carbonMods(_ f: NSEvent.ModifierFlags) -> UInt32 {
        var m: UInt32 = 0
        if f.contains(.control) { m |= UInt32(controlKey) }
        if f.contains(.option) { m |= UInt32(optionKey) }
        if f.contains(.shift) { m |= UInt32(shiftKey) }
        if f.contains(.command) { m |= UInt32(cmdKey) }
        return m
    }

    static func carbonMods(_ f: CGEventFlags) -> UInt32 {
        var m: UInt32 = 0
        if f.contains(.maskControl) { m |= UInt32(controlKey) }
        if f.contains(.maskAlternate) { m |= UInt32(optionKey) }
        if f.contains(.maskShift) { m |= UInt32(shiftKey) }
        if f.contains(.maskCommand) { m |= UInt32(cmdKey) }
        return m
    }

    /// A readable name for the key itself.
    static func keyName(_ event: NSEvent) -> String {
        let names: [Int: String] = [
            kVK_Space: "Space", kVK_Return: "↩", kVK_Tab: "⇥", kVK_Delete: "⌫", kVK_ForwardDelete: "⌦",
            kVK_LeftArrow: "←", kVK_RightArrow: "→", kVK_UpArrow: "↑", kVK_DownArrow: "↓",
            kVK_Home: "↖", kVK_End: "↘", kVK_PageUp: "⇞", kVK_PageDown: "⇟",
            kVK_F1: "F1", kVK_F2: "F2", kVK_F3: "F3", kVK_F4: "F4", kVK_F5: "F5", kVK_F6: "F6",
            kVK_F7: "F7", kVK_F8: "F8", kVK_F9: "F9", kVK_F10: "F10", kVK_F11: "F11", kVK_F12: "F12",
            kVK_F13: "F13", kVK_F14: "F14", kVK_F15: "F15", kVK_F16: "F16", kVK_F17: "F17", kVK_F19: "F19",
        ]
        if let n = names[Int(event.keyCode)] { return n }
        return (event.charactersIgnoringModifiers ?? "?").uppercased()
    }
}

/// The user's shortcuts, saved in UserDefaults; nil means "no shortcut".
@MainActor
@Observable
final class Shortcuts {
    static let shared = Shortcuts()
    private(set) var combos: [ShortcutAction: KeyCombo] = [:]
    /// The action whose shortcut is being recorded; hotkeys are paused meanwhile.
    var recording: ShortcutAction? {
        didSet { if recording == nil { HotKey.shared.apply() } else { HotKey.shared.suspend() } }
    }

    private init() {
        if let data = UserDefaults.standard.data(forKey: "shortcuts"),
           let saved = try? JSONDecoder().decode([String: KeyCombo?].self, from: data) {
            for a in ShortcutAction.allCases {
                if let entry = saved[a.rawValue] { combos[a] = entry } else { combos[a] = a.defaultCombo }
            }
        } else {
            for a in ShortcutAction.allCases { combos[a] = a.defaultCombo }
        }
    }

    /// Another Mac's shortcuts (BL-193).
    func applySynced(_ data: Data) {
        guard let saved = try? JSONDecoder().decode([String: KeyCombo?].self, from: data) else { return }
        for a in ShortcutAction.allCases { combos[a] = saved[a.rawValue] ?? a.defaultCombo }
        if !UserLibrary.testing { UserDefaults.standard.set(data, forKey: "shortcuts") }
        HotKey.shared.apply()
    }

    func combo(_ a: ShortcutAction) -> KeyCombo? { combos[a] }

    func label(_ a: ShortcutAction) -> String { combos[a]?.display ?? "" }

    /// Sets a shortcut; another action that had the same keys loses them. Returns that action.
    @discardableResult
    func set(_ a: ShortcutAction, _ combo: KeyCombo?) -> ShortcutAction? {
        var taken: ShortcutAction?
        if let combo, let other = combos.first(where: { $0.key != a && $0.value == combo })?.key {
            combos[other] = nil
            taken = other
        }
        combos[a] = combo
        save()
        HotKey.shared.apply()
        return taken
    }

    func resetAll() {
        for a in ShortcutAction.allCases { combos[a] = a.defaultCombo }
        save()
        HotKey.shared.apply()
    }

    func action(for combo: KeyCombo) -> ShortcutAction? {
        combos.first { $0.value.keyCode == combo.keyCode && $0.value.mods == combo.mods }?.key
    }

    private func save() {
        var out: [String: KeyCombo?] = [:]
        for a in ShortcutAction.allCases { out[a.rawValue] = .some(combos[a] ?? nil) }
        if let data = try? JSONEncoder().encode(out) { UserDefaults.standard.set(data, forKey: "shortcuts") }
        Task { @MainActor in UserLibrary.shared.pluginDataChanged() }
    }

    // MARK: Running an action

    func run(_ a: ShortcutAction) {
        switch a {
        case .openLibrary: LibraryWindow.toggle()
        case .quickPicker: PickerPanelController.shared.toggle()
        case .miniWindow:
            LibraryWindow.show()
            NotificationCenter.default.post(name: .toggleMiniMode, object: nil)
        case .trackPanel:
            LibraryWindow.show()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                NotificationCenter.default.post(name: .showTrackPanel, object: nil)
            }
        case .openAll: TrackState.shared.run { _ = await LogicTrack.shared.openAll() }
        case .closeAll: Task { await LogicTrack.shared.closeAll() }
        case .removeLast:
            Task {
                if let name = await LogicTrack.shared.removeLastAdded() { Toast.show("Removed \(name)") }
                else { Toast.show("Nothing to remove on the selected track.", warning: true) }
                TrackState.shared.refreshSoon()
            }
        case .saveChain:
            TrackState.shared.refresh()
            let state = TrackState.shared
            let (ids, missing) = state.asChain()
            guard !ids.isEmpty else { Toast.show("No plugins from your library on the selected track.", warning: true); return }
            NSApp.activate()
            guard let name = NamePrompt.ask("Save track as chain", placeholder: "Name",
                                            initial: "\(state.track ?? "Track") chain") else { return }
            UserLibrary.shared.newChain(named: name, with: ids)
            Toast.show(missing.isEmpty ? "Saved \(name): \(ids.count) plugins"
                                       : "Saved \(name). Not in your library: \(missing.joined(separator: ", "))",
                       warning: !missing.isEmpty)
        case .removeAllEffects:
            Task {
                if let n = await LogicTrack.shared.clearEffects() {
                    Toast.show(n == 0 ? "No effects on the selected track." : "Removed \(n) effect\(n == 1 ? "" : "s"). Undo in Logic with ⌘Z.")
                } else {
                    Toast.show("Logic's Remove All Effect Plug-ins wasn't available. Show the Inspector (I) and try again.", warning: true)
                }
                TrackState.shared.refreshSoon()
            }
        case .removeTurnedOff:
            Task {
                let ok = await LogicTrack.shared.stripCommand("Remove Bypassed Plug-ins")
                Toast.show(ok ? "Removed the effects that were turned off." : "No effects turned off on the selected track.", warning: !ok)
                TrackState.shared.refreshSoon()
            }
        case .removeAllSends:
            Task {
                let ok = await LogicTrack.shared.stripCommand("Remove All Sends")
                Toast.show(ok ? "Removed all sends." : "No sends on the selected track.", warning: !ok)
                TrackState.shared.refreshSoon()
            }
        case .pointerInsert:
            guard let t = PointerSlot.target() else {
                Toast.show("Point at a plugin slot in Logic's Inspector or Mixer, then press the key.", warning: true); return
            }
            PickerPanelController.shared.show(for: t)
        case .pointerRemove:
            guard let t = PointerSlot.target(), t.occupant != nil else {
                Toast.show("Point at a plugin in Logic, then press the key.", warning: true); return
            }
            SlotHighlight.show(t.frame)
            Task {
                let problem = await LogicTrack.shared.remove(at: t)
                SlotHighlight.hide()
                Toast.show(problem ?? "Removed \(t.occupant ?? "it")", warning: problem != nil)
                TrackState.shared.refreshSoon()
            }
        case .pointerToggle:
            guard let t = PointerSlot.target(), let bypass = t.bypass else {
                Toast.show("Point at a plugin in Logic, then press the key.", warning: true); return
            }
            bypass.perform(kAXPressAction)
            TrackState.shared.refreshSoon()
        default:
            guard let n = a.pinNumber else { return }
            if let target = UserLibrary.shared.pinTarget(n) { InsertRunner.run(target) }
            else { Toast.show("Nothing is pinned to \(n) yet. Pin a plugin or a chain in its info panel.", warning: true) }
        }
    }
}

extension Notification.Name {
    static let showTrackPanel = Notification.Name("AGPFShowTrackPanel")
}

// MARK: - Caps Lock as a Hyper key

/// Turns Caps Lock into a Hyper key (Control Option Shift Command) while AG PlugFinder runs.
/// macOS is told to send F18 for Caps Lock, and a keyboard watcher adds the four modifiers to
/// every key pressed while it is held, so Hyper shortcuts work here and in other apps. Caps Lock
/// goes back to normal when the switch is off or the app quits.
@MainActor
enum HyperKey {
    private static let capsLock: UInt64 = 0x700000039
    private static let f18: UInt64 = 0x70000006D
    private static var tap: CFMachPort?
    nonisolated(unsafe) private static var held = false

    static var enabled: Bool {
        get { UserDefaults.standard.bool(forKey: "hyper.capsLock") }
        set {
            UserDefaults.standard.set(newValue, forKey: "hyper.capsLock")
            if newValue { start() } else { stop() }
        }
    }

    static func applyOnLaunch() { if enabled { start() } }

    /// Every key mapping on every keyboard, as (from, to) pairs.
    private static func mappings() -> [(src: UInt64, dst: UInt64)] {
        let text = hidutil(["property", "--get", "UserKeyMapping"])
        var out: [(UInt64, UInt64)] = []
        var src: UInt64?, dst: UInt64?
        for line in text.split(separator: "\n") {
            let t = line.trimmingCharacters(in: .whitespaces)
            func value() -> UInt64? { t.split(separator: "=").last.flatMap { UInt64($0.trimmingCharacters(in: CharacterSet(charactersIn: " ;"))) } }
            if t.hasPrefix("HIDKeyboardModifierMappingSrc") { src = value() }
            if t.hasPrefix("HIDKeyboardModifierMappingDst") { dst = value() }
            if let s = src, let d = dst { out.append((s, d)); src = nil; dst = nil }
        }
        return out
    }

    /// True when another app already changes keys (Raycast's Hyper Key, for example). Then
    /// AG PlugFinder leaves the keyboard alone: that app's Hyper key already works here.
    static var otherAppMapsKeys: Bool {
        mappings().contains { !($0.src == capsLock && $0.dst == f18) }
    }

    /// Returns a problem to show, or nil when it worked.
    @discardableResult
    static func start() -> String? {
        if otherAppMapsKeys {
            UserDefaults.standard.set(false, forKey: "hyper.capsLock")
            return "Another app already changes your keyboard (for example a Hyper key in Raycast). Its Hyper key already works with AG PlugFinder: record your shortcuts with it."
        }
        _ = hidutil(["property", "--set",
                     "{\"UserKeyMapping\":[{\"HIDKeyboardModifierMappingSrc\":\(capsLock),\"HIDKeyboardModifierMappingDst\":\(f18)}]}"])
        installTap()
        return nil
    }

    /// Clears the keyboard mapping only when every mapping on the Mac is AG PlugFinder's own.
    static func stop() {
        let all = mappings()
        if !all.isEmpty, all.allSatisfy({ $0.src == capsLock && $0.dst == f18 }) {
            _ = hidutil(["property", "--set", "{\"UserKeyMapping\":[]}"])
        }
        if let tap { CGEvent.tapEnable(tap: tap, enable: false) }
        held = false
    }

    private static func installTap() {
        if let tap { CGEvent.tapEnable(tap: tap, enable: true); return }
        let mask = (1 << CGEventType.keyDown.rawValue) | (1 << CGEventType.keyUp.rawValue)
        guard let port = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
                                           eventsOfInterest: CGEventMask(mask), callback: { _, type, event, _ in
            if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                MainActor.assumeIsolated { if let t = HyperKey.tap { CGEvent.tapEnable(tap: t, enable: true) } }
                return Unmanaged.passUnretained(event)
            }
            let code = event.getIntegerValueField(.keyboardEventKeycode)
            if code == Int64(kVK_F18) {
                HyperKey.held = type == .keyDown
                return nil
            }
            guard HyperKey.held else { return Unmanaged.passUnretained(event) }
            event.flags.formUnion([.maskControl, .maskAlternate, .maskShift, .maskCommand])
            if type == .keyDown {
                let handled: Bool = MainActor.assumeIsolated {
                    let s = Shortcuts.shared
                    guard s.recording == nil,
                          let a = s.action(for: KeyCombo(keyCode: UInt32(code), mods: KeyCombo.hyperMods, key: ""))
                    else { return false }
                    s.run(a)
                    return true
                }
                if handled { return nil }
            }
            return Unmanaged.passUnretained(event)
        }, userInfo: nil) else { return }
        tap = port
        let source = CFMachPortCreateRunLoopSource(nil, port, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: port, enable: true)
    }

    private static func hidutil(_ args: [String]) -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/hidutil")
        p.arguments = args
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return "" }
        p.waitUntilExit()
        return String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
    }
}
