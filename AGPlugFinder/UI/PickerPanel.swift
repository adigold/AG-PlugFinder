import AppKit
import SwiftUI

/// A floating panel that takes the keyboard without making Logic lose focus.
final class PickerPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
    override func cancelOperation(_ sender: Any?) {
        Task { @MainActor in PickerPanelController.shared.hide() }
    }
}

@MainActor
final class PickerPanelController {
    static let shared = PickerPanelController()
    let model = PickerModel()
    private var keyMonitor: Any?

    private lazy var panel: PickerPanel = {
        let p = PickerPanel(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 640),
                            styleMask: [.titled, .fullSizeContentView, .nonactivatingPanel, .resizable],
                            backing: .buffered, defer: false)
        p.titlebarAppearsTransparent = true
        p.titleVisibility = .hidden
        p.isMovableByWindowBackground = true
        p.level = .floating
        p.hidesOnDeactivate = false
        p.isReleasedWhenClosed = false
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        p.minSize = NSSize(width: 760, height: 480)
        p.backgroundColor = Theme.nsGround
        p.appearance = Theme.nsAppearance
        for b in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
            p.standardWindowButton(b)?.isHidden = true
        }
        p.contentView = NSHostingView(rootView: PickerView(model: model).overlay { UnfavoriteConfirm() })
        return p
    }()

    var isVisible: Bool { panel.isVisible }

    func toggle() { isVisible ? hide() : show() }

    func show() {
        model.reset()
        present()
    }

    /// Brings the panel back without clearing the search (after an insert problem).
    func present() {
        if !panel.isVisible {
            let mouse = NSEvent.mouseLocation
            let screen = NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main
            if let frame = screen?.visibleFrame {
                let size = panel.frame.size
                panel.setFrameOrigin(NSPoint(x: frame.midX - size.width / 2,
                                             y: frame.midY - size.height / 2 + 40))
            }
        }
        panel.makeKeyAndOrderFront(nil)
        installKeys()
    }

    /// Opens the picker for the slot under the pointer in Logic, with that slot outlined (BL-65).
    func show(for target: PointerTarget) {
        model.reset()
        model.pointerTarget = target
        SlotHighlight.show(target.frame)
        present()
    }

    func hide() {
        SlotHighlight.hide()
        panel.orderOut(nil)
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
    }

    func insert(replacing slot: Int? = nil) {
        model.insertSelected(replacing: slot, onHide: { [weak self] in self?.hide() },
                             onShow: { [weak self] in self?.present() })
    }

    private func installKeys() {
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, event.window === self.panel else { return event }
            return self.handle(event) ? nil : event
        }
    }

    /// Returns true when the key was used.
    private func handle(_ e: NSEvent) -> Bool {
        let cmd = e.modifierFlags.contains(.command)
        if let choices = model.slotChoices {
            switch e.keyCode {
            case 126: model.slotSelection = max(0, model.slotSelection - 1); return true
            case 125: model.slotSelection = min(choices.count - 1, model.slotSelection + 1); return true
            case 36, 76: insert(replacing: model.slotSelection); return true
            case 53: model.slotChoices = nil; model.message = nil; return true
            default: return true
            }
        }
        switch e.keyCode {
        case 53: hide(); return true                                // Esc
        case 36, 76: insert(); return true                         // Return / Enter
        case 125: model.move(model.columns); return true           // Down
        case 126: model.move(-model.columns); return true          // Up
        case 123: model.move(-1); return true                      // Left
        case 124: model.move(1); return true                       // Right
        default: break
        }
        if cmd, let chars = e.charactersIgnoringModifiers {
            if let n = Int(chars), (1...PluginSort.allCases.count).contains(n) { model.cycleSort(to: n - 1); return true }
            if chars == "f" { ViewSettings.shared.favoritesOnly.toggle(); model.selection = 0; return true }
            if chars == "d", let p = model.selected { PluginStore.shared.favoriteTapped(p.id); return true }
        }
        return false
    }
}
