import AppKit
import SwiftUI

/// Settings > Shortcuts (BL-51): every action with its keys, a recorder for each, and Caps Lock
/// as a Hyper key.
struct ShortcutSettings: View {
    var shortcuts = Shortcuts.shared
    @State private var hyper = HyperKey.enabled
    @State private var note: String?

    private var groups: [(String, [ShortcutAction])] {
        let order = ["Windows", "The selected track", "Number keys"]
        return order.map { g in (g, ShortcutAction.allCases.filter { $0.group == g }) }
    }

    var body: some View {
        Form {
            Section {
                if HyperKey.otherAppMapsKeys && !hyper {
                    LabeledContent("Hyper key") {
                        HStack(spacing: 6) {
                            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                            Text("Ready, from another app")
                        }
                    }
                    Text("Another app already turns Caps Lock into a Hyper key, and it works here too. Click a shortcut below, hold Caps Lock and press a key. To let AG PlugFinder handle Caps Lock instead, switch off the Hyper key in that app first.")
                        .font(.caption).foregroundStyle(.secondary)
                } else {
                    Toggle("Use Caps Lock as a Hyper key", isOn: $hyper)
                        .onChange(of: hyper) { _, on in
                            if on, let problem = HyperKey.start() { note = problem; hyper = false; return }
                            HyperKey.enabled = on
                            note = nil
                        }
                    Text("Hold Caps Lock and press a key to use Hyper shortcuts. Hyper is Control, Option, Shift and Command together, so it never clashes with Logic's own key commands. Caps Lock works normally again when you turn this off or quit AG PlugFinder.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if let note { Text(note).font(.caption).foregroundStyle(.orange) }
            }
            ForEach(groups, id: \.0) { group in
                Section(group.0) {
                    ForEach(group.1) { a in
                        LabeledContent(a.title) { ShortcutRecorder(action: a, note: $note) }
                    }
                }
            }
            Section {
                HStack {
                    Text("Click a shortcut, then press the new keys. Delete clears it, Esc cancels.")
                        .font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("Restore Defaults") { shortcuts.resetAll(); note = nil }
                }
            }
        }
        .formStyle(.grouped)
        .onDisappear { shortcuts.recording = nil }
    }
}

struct ShortcutRecorder: View {
    let action: ShortcutAction
    @Binding var note: String?
    var shortcuts = Shortcuts.shared
    @State private var monitor: Any?
    @State private var hovering = false

    private var isRecording: Bool { shortcuts.recording == action }

    var body: some View {
        HStack(spacing: 6) {
            Button { isRecording ? stop() : start() } label: {
                Text(isRecording ? "Press keys…" : (shortcuts.combo(action)?.display ?? "Record Shortcut"))
                    .font(.system(size: Theme.ts(12), weight: .medium)).monospacedDigit()
                    .foregroundStyle(isRecording ? Theme.onAccent : (shortcuts.combo(action) == nil ? Theme.faint : Theme.text))
                    .padding(.horizontal, 12).frame(minWidth: 130).frame(height: 26)
                    .background(RoundedRectangle(cornerRadius: 7)
                        .fill(isRecording ? Theme.accent : (hovering ? Theme.raised : Theme.surface)))
            }
            .buttonStyle(.plain)
            .onHover { hovering = $0 }
            if shortcuts.combo(action) != nil, !isRecording {
                Button { shortcuts.set(action, nil) } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(Theme.faint)
                }
                .buttonStyle(.plain).help("No shortcut")
            }
        }
        .onChange(of: shortcuts.recording) { _, r in if r != action { removeMonitor() } }
        .onDisappear { if isRecording { stop() } }
    }

    private func start() {
        note = nil
        shortcuts.recording = action
        removeMonitor()
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { e in
            guard shortcuts.recording == action else { return e }
            switch Int(e.keyCode) {
            case 53: stop(); return nil                          // Esc cancels
            case 51, 117: shortcuts.set(action, nil); stop(); return nil   // Delete clears
            default: break
            }
            let mods = KeyCombo.carbonMods(e.modifierFlags)
            let name = KeyCombo.keyName(e)
            let isFKey = name.count > 1 && name.hasPrefix("F") && Int(name.dropFirst()) != nil
            guard mods != 0 || isFKey else {
                note = "Add Control, Option, Command or Hyper, so the shortcut doesn't get in the way of typing."
                return nil
            }
            let combo = KeyCombo(keyCode: UInt32(e.keyCode), mods: mods, key: KeyCombo.keyName(e))
            if let other = shortcuts.set(action, combo) {
                note = "\(combo.display) was used for \"\(other.title)\". That one has no shortcut now."
            }
            stop()
            return nil
        }
    }

    private func stop() {
        removeMonitor()
        if shortcuts.recording == action { shortcuts.recording = nil }
    }

    private func removeMonitor() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }
}
