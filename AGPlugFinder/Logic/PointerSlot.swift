import AppKit
import ApplicationServices

/// The Logic slot under the pointer (BL-65): an empty slot, a filled one, or the insert bar
/// between two. Works in the Inspector and the Mixer, because it asks Logic what is under the
/// pointer instead of looking in one place.
struct PointerTarget {
    let kind: SlotKind
    var point: CGPoint = .zero  // where the pointer was, to find the slot again later
    let occupant: String?      // the plugin in it now, nil when empty
    let press: AXNode          // opens the slot's plug-in menu (list button, empty slot or insert bar)
    let bypass: AXNode?
    let frame: CGRect          // screen coordinates, top-left origin
}

@MainActor
enum PointerSlot {
    static func target(at point: CGPoint? = nil) -> PointerTarget? {
        guard AXAccess.isTrusted, let logic = LogicInserter.shared.logicApp,
              let p = point ?? CGEvent(source: nil)?.location else { return nil }
        let app = AXNode(el: AXUIElementCreateApplication(logic.processIdentifier))
        AXUIElementSetMessagingTimeout(app.el, 1.0)
        var hit: AXUIElement?
        guard AXUIElementCopyElementAtPosition(app.el, Float(p.x), Float(p.y), &hit) == .success, let hit
        else { return nil }
        var node = AXNode(el: hit)
        for _ in 0..<4 {
            if var t = classify(node, at: p) { t.point = p; return t }
            guard let parent: AXUIElement = node.attr(kAXParentAttribute) else { break }
            node = AXNode(el: parent)
        }
        return nil
    }

    private static func kind(fromHelp help: String) -> SlotKind? {
        if help.hasPrefix("Audio Effect slot") { return .audioFX }
        if help.hasPrefix("MIDI Effect slot") { return .midiFX }
        if help.hasPrefix("Instrument slot") || help.localizedCaseInsensitiveContains("instrument slot") { return .instrument }
        return nil
    }

    private static func classify(_ n: AXNode, at p: CGPoint) -> PointerTarget? {
        // The thin line between two audio effects: inserts right there.
        if n.desc == "insert bar" {
            return PointerTarget(kind: .audioFX, occupant: nil, press: n, bypass: nil, frame: n.frame)
        }
        // An empty slot button.
        if n.role == "AXButton", let k = kind(fromHelp: n.help) {
            return PointerTarget(kind: k, occupant: nil, press: n, bypass: nil, frame: n.frame)
        }
        // A filled slot: a group with bypass, open and list buttons, inside a channel strip.
        if n.role == "AXGroup", !n.desc.isEmpty,
           let list = n.children.first(where: { $0.desc == "list" }),
           n.children.contains(where: { $0.desc == "bypass" }),
           let parent: AXUIElement = n.attr(kAXParentAttribute) {
            let strip = AXNode(el: parent)
            let frame = n.frame
            // Logic wraps each filled slot in a group whose help names the slot's kind.
            let k = kind(fromHelp: strip.help) ?? kind(fromHelp: n.help) ?? .audioFX
            // The top edge of an audio effect: the insert bar just above it, so the new plugin
            // goes in before this one instead of replacing it. The bar itself is 1 pixel tall.
            if k == .audioFX, p.y - frame.minY <= 4,
               let bar = (strip.children + ((strip.attr(kAXParentAttribute) as AXUIElement?).map { AXNode(el: $0).children } ?? []))
                   .first(where: { $0.desc == "insert bar" && abs($0.frame.midY - frame.minY) <= 4 }) {
                return PointerTarget(kind: .audioFX, occupant: nil, press: bar, bypass: nil,
                                     frame: CGRect(x: frame.minX, y: frame.minY - 2, width: frame.width, height: 4))
            }
            return PointerTarget(kind: k, occupant: n.desc, press: list,
                                 bypass: n.children.first { $0.desc == "bypass" }, frame: frame)
        }
        return nil
    }
}

/// An amber frame around the targeted slot while the picker is open.
@MainActor
enum SlotHighlight {
    private static var panel: NSPanel?

    static func show(_ axFrame: CGRect) {
        guard let primary = NSScreen.screens.first else { return }
        // AX frames are top-left based; Cocoa windows are bottom-left based.
        let r = NSRect(x: axFrame.minX - 3, y: primary.frame.maxY - axFrame.maxY - 3,
                       width: axFrame.width + 6, height: axFrame.height + 6)
        let p = panel ?? {
            let p = NSPanel(contentRect: r, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            p.isOpaque = false
            p.backgroundColor = .clear
            p.ignoresMouseEvents = true
            p.level = .statusBar
            p.hasShadow = false
            p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            let v = NSView()
            v.wantsLayer = true
            v.layer?.borderColor = NSColor(red: 0.961, green: 0.62, blue: 0.239, alpha: 1).cgColor
            v.layer?.borderWidth = 2.5
            v.layer?.cornerRadius = 4
            p.contentView = v
            panel = p
            return p
        }()
        p.setFrame(r, display: true)
        p.orderFrontRegardless()
    }

    static func hide() { panel?.orderOut(nil) }
}

extension LogicTrack {
    /// Chooses `plugin` from the target slot's own menu: inserts into an empty slot or at an
    /// insert bar, replaces in a filled one.
    func insert(_ plugin: Plugin, at t: PointerTarget) async -> String? {
        guard plugin.slotKind == t.kind else {
            return "\(plugin.name) doesn't go in this slot."
        }
        guard let (logic, app) = logic() else { return "Logic Pro isn't open." }
        await LogicInserter.shared.bringForward(logic)
        // Logic rebuilds its controls when it comes forward: find the slot again at that spot.
        let press = PointerSlot.target(at: t.point).map(\.press) ?? t.press
        LogicInserter.shared.log("POINTER press \(press.role) desc=\(press.desc) help=\(press.help.prefix(30)) frame=\(press.frame) actions=\(press.actions) at \(t.point)")
        guard let menu = await LogicInserter.shared.openMenu(on: press, app: app, legacy: plugin.isLegacy == true) else {
            return "Logic's plug-in menu did not open for that slot."
        }
        guard await choose(plugin, menu: menu, app: app, pid: logic.processIdentifier) else {
            return "I couldn't find \(plugin.name) in Logic's plug-in menu."
        }
        lastAdded = plugin.name
        LogicInserter.shared.log("POINTER \(t.occupant.map { "replaced \($0) with" } ?? "inserted") \(plugin.name)")
        return nil
    }

    func remove(at t: PointerTarget) async -> String? {
        guard let name = t.occupant else { return "Point at a slot with a plugin in it to remove it." }
        guard let (logic, app) = logic() else { return "Logic Pro isn't open." }
        await LogicInserter.shared.bringForward(logic)
        let press = PointerSlot.target(at: t.point).map(\.press) ?? t.press
        for _ in 1...2 {
            press.perform(kAXPressAction)
            if let menu = await LogicInserter.shared.waitForMenu(app: app, timeout: 2.5),
               let none = menu.first(maxNodes: 200, where: { $0.title == "No Plug-in" }) {
                none.perform(kAXPressAction)
                return nil
            }
        }
        return "Logic didn't remove \(name)."
    }
}
