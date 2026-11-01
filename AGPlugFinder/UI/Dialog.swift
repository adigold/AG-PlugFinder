import AppKit
import SwiftUI

/// The app's own dialog (BL-116): a dark card over a dimmed window, instead of the system box.
/// Return presses the main button, Esc cancels. It waits for the answer like the system box did,
/// so every caller stays as simple as before.
@MainActor
enum Dialog {
    struct Choice {
        let title: String
        var primary = false
        var cancel = false
        var destructive = false
    }

    struct Answer {
        let index: Int
        let text: String
        let checked: Bool
    }

    @Observable
    final class State {
        var text = ""
        var checked = false
    }

    /// Shows the card and returns which button was pressed, the text typed and the checkbox.
    @discardableResult
    static func show(_ title: String, message: String? = nil, field: (placeholder: String, initial: String)? = nil,
                     multiline: Bool = false, checkbox: String? = nil, requireText: Bool = false, choices: [Choice]) -> Answer {
        let parent = NSApp.keyWindow ?? NSApp.mainWindow
        let state = State()
        state.text = field?.initial ?? ""
        let panel = DialogPanel(contentRect: .zero, styleMask: [.borderless], backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .modalPanel
        panel.appearance = Theme.nsAppearance
        let primary = choices.firstIndex(where: \.primary) ?? 0
        let cancel = choices.firstIndex(where: \.cancel) ?? (choices.count - 1)
        var picked: Int?
        // With a text field, OK needs something typed: empty or only spaces is not an answer (BL-190).
        let needsText = requireText && field != nil
        func hasText() -> Bool { !state.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        panel.onReturn = { debugLog("return"); if !needsText || hasText() { picked = primary } }
        panel.onEscape = { debugLog("escape"); picked = cancel }
        panel.multiline = multiline
        let host = FirstClickHost(rootView: DialogCard(title: title, message: message, field: field, multiline: multiline,
                                                      checkbox: checkbox, choices: choices, state: state, requireText: requireText) { i in
            debugLog("button \(i)")
            picked = i
        })
        let size = host.fittingSize
        panel.setContentSize(size)
        panel.contentView = host
        // Centered over the window it belongs to, a little above the middle.
        let area = parent?.frame ?? NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1200, height: 800)
        panel.setFrameOrigin(NSPoint(x: area.midX - size.width / 2, y: area.midY - size.height / 2 + area.height * 0.08))

        var dim: NSWindow?
        if let parent {
            let d = NSWindow(contentRect: parent.frame, styleMask: [.borderless], backing: .buffered, defer: false)
            d.isOpaque = false
            d.backgroundColor = NSColor.black.withAlphaComponent(0.35)
            d.ignoresMouseEvents = true
            d.level = parent.level
            parent.addChildWindow(d, ordered: .above)
            dim = d
        }
        NSApp.activate()
        panel.makeKeyAndOrderFront(nil)
        // Esc and Return answer even when the keyboard is still with another window (BL-190).
        let keys = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { e in
            guard e.window !== panel else { return e }
            if e.keyCode == 53 { picked = cancel; return nil }
            if e.keyCode == 36 || e.keyCode == 76 { panel.onReturn(); return nil }
            return e
        }
        // Its own modal loop: only a button, Return or Esc ends it. Other windows wait.
        let session = NSApp.beginModalSession(for: panel)
        while picked == nil {
            if NSApp.runModalSession(session) != .continue { break }
            RunLoop.current.run(mode: .default, before: Date(timeIntervalSinceNow: 0.03))
        }
        NSApp.endModalSession(session)
        if let keys { NSEvent.removeMonitor(keys) }
        let code = picked ?? cancel
        panel.orderOut(nil)
        if let dim { parent?.removeChildWindow(dim); dim.orderOut(nil) }
        parent?.makeKeyAndOrderFront(nil)
        let index = (0..<choices.count).contains(code) ? code : cancel
        return Answer(index: index, text: state.text.trimmingCharacters(in: .whitespacesAndNewlines), checked: state.checked)
    }

    /// A name or a short text; nil when cancelled or left empty.
    static func ask(_ title: String, message: String? = nil, placeholder: String, initial: String = "",
                    ok: String = "OK") -> String? {
        let a = show(title, message: message, field: (placeholder, initial), requireText: true,
                     choices: [Choice(title: "Cancel", cancel: true), Choice(title: ok, primary: true)])
        return a.index == 1 && !a.text.isEmpty ? a.text : nil
    }

    /// Yes or no.
    static func confirm(_ title: String, message: String? = nil, ok: String, cancel: String = "Cancel",
                        destructive: Bool = false) -> Bool {
        show(title, message: message,
             choices: [Choice(title: cancel, cancel: true), Choice(title: ok, primary: true, destructive: destructive)]).index == 1
    }
}

private func debugLog(_ s: String) {
    #if DEBUG
    print("DIALOG " + s); fflush(stdout)
    #endif
}

/// The dialog's buttons answer the first click, even before the card has the keyboard (BL-188).
final class FirstClickHost<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// A borderless panel that can take the keyboard; Return and Esc answer the dialog.
final class DialogPanel: NSPanel {
    var onReturn: () -> Void = {}
    var onEscape: () -> Void = {}
    var multiline = false
    /// A button only counts when the mouse went down on this card first (BL-188): a stray
    /// release, for example from the click that opened it, pressed Cancel by itself.
    private var pressedHere = false
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }

    override func sendEvent(_ event: NSEvent) {
        if event.type == .leftMouseDown { pressedHere = true }
        if event.type == .leftMouseUp {
            guard pressedHere else { return }
            pressedHere = false
        }
        if event.type == .keyDown {
            if event.keyCode == 53 { onEscape(); return }
            if event.keyCode == 36 || event.keyCode == 76,
               !multiline || event.modifierFlags.contains(.command) { onReturn(); return }
        }
        super.sendEvent(event)
    }
}

struct DialogCard: View {
    let title: String
    let message: String?
    let field: (placeholder: String, initial: String)?
    let multiline: Bool
    let checkbox: String?
    let choices: [Dialog.Choice]
    @Bindable var state: Dialog.State
    /// OK waits for something typed (BL-190); an optional note leaves it on.
    var requireText = false
    let choose: (Int) -> Void
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top, spacing: 12) {
                BrandMark(size: 22).padding(.top, 2)
                VStack(alignment: .leading, spacing: 6) {
                    Text(title).font(.system(size: Theme.ts(15), weight: .semibold)).foregroundStyle(Theme.text)
                        .fixedSize(horizontal: false, vertical: true)
                    if let message {
                        Text(message).font(.system(size: Theme.ts(12.5))).foregroundStyle(Theme.muted)
                            .lineSpacing(2).fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            if let field {
                Group {
                    if multiline {
                        TextField("", text: $state.text, prompt: Text(field.placeholder).foregroundStyle(Theme.faint), axis: .vertical)
                            .lineLimit(3...6)
                            .padding(.vertical, 10)
                    } else {
                        TextField("", text: $state.text, prompt: Text(field.placeholder).foregroundStyle(Theme.faint))
                            .frame(height: 38)
                    }
                }
                .textFieldStyle(.plain).font(.system(size: Theme.ts(14))).foregroundStyle(Theme.text)
                .focused($focused)
                .padding(.horizontal, 14)
                .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Theme.raised))
                .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(focused ? Theme.accent.opacity(0.7) : Color.clear, lineWidth: 1.5))
            }
            if let checkbox {
                Button { state.checked.toggle() } label: {
                    HStack(spacing: 9) {
                        CheckMark(on: state.checked)
                        Text(checkbox).font(.system(size: Theme.ts(12.5))).foregroundStyle(Theme.muted)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            HStack(spacing: 8) {
                Spacer(minLength: 0)
                ForEach(Array(choices.enumerated()), id: \.offset) { i, c in
                    // OK appears once something is typed (BL-190).
                    if !(c.primary && requireText && field != nil && state.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) {
                        DialogButton(choice: c) { choose(i) }
                            .transition(.opacity.combined(with: .scale(scale: 0.9)))
                    }
                }
            }
            .padding(.top, 2)
            .animation(.easeOut(duration: 0.15), value: state.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
        .padding(22)
        .frame(width: 400)
        .background(RoundedRectangle(cornerRadius: 20, style: .continuous).fill(Theme.surface))
        .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).strokeBorder(Theme.edge, lineWidth: 1))
        .preferredColorScheme(Theme.scheme)
        .onAppear { if field != nil { DispatchQueue.main.async { focused = true } } }
    }
}

private struct DialogButton: View {
    let choice: Dialog.Choice
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Text(choice.title)
                .font(.system(size: Theme.ts(13), weight: choice.primary ? .semibold : .medium))
                .padding(.horizontal, 16).frame(height: 32)
                .foregroundStyle(choice.primary ? (choice.destructive ? Color.white : Theme.onInk) : Theme.text)
                .background(Capsule().fill(fill.opacity(hovering ? 0.88 : 1)))
                .contentShape(Capsule())
        }
        .buttonStyle(PressScale())
        .onHover { hovering = $0 }
    }

    private var fill: Color {
        if choice.primary { return choice.destructive ? Theme.negative : Theme.ink }
        return Theme.raised
    }
}
