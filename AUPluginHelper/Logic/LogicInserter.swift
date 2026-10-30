import AppKit
import ApplicationServices

/// A filled insert slot the user can choose to replace when the track has no empty slot.
struct SlotChoice: Identifiable, Hashable {
    let id: Int
    let name: String
}

enum InsertOutcome {
    case inserted
    case needsAccessibility
    case logicNotRunning
    case noChannelStrip(String)
    case allFull([SlotChoice])
    case failed(String)
}

/// Places a plugin on the selected track in Logic Pro by driving Logic's own interface through
/// Accessibility: it opens the first empty insert slot of the selected track's channel strip
/// (the left strip in the Inspector), types the plugin name into Logic's "Search Plug-ins" field
/// and picks the match. If there is no search field it walks Audio Units → maker → plugin.
@MainActor
final class LogicInserter {
    static let shared = LogicInserter()
    static let bundleIDs = ["com.apple.logic10", "com.apple.logic.pro"]

    /// Strip slots further right than this (from the window's left edge) are not in the Inspector.
    private let inspectorMaxX: CGFloat = 420

    var logicApp: NSRunningApplication? {
        Self.bundleIDs.lazy.compactMap {
            NSRunningApplication.runningApplications(withBundleIdentifier: $0).first
        }.first
    }

    func insert(_ plugin: Plugin, replacing slotIndex: Int? = nil) async -> InsertOutcome {
        guard AXAccess.isTrusted else { return .needsAccessibility }
        guard let logic = logicApp else { return .logicNotRunning }
        logic.activate()
        try? await Task.sleep(for: .milliseconds(150))

        let app = AXNode(el: AXUIElementCreateApplication(logic.processIdentifier))
        AXUIElementSetMessagingTimeout(app.el, 2.0)
        guard let window: AXUIElement = app.attr(kAXFocusedWindowAttribute) ?? app.attr(kAXMainWindowAttribute)
        else { return .failed("Logic has no open project window.") }
        let win = AXNode(el: window)
        let winFrame = win.frame

        let strip = findSlots(in: win, kind: plugin.slotKind, windowMinX: winFrame.minX)

        let target: AXNode
        if let index = slotIndex {
            guard index < strip.filled.count else { return .failed("That slot is no longer there.") }
            target = strip.filled[index]
        } else if let empty = strip.empty {
            target = empty
        } else if !strip.filled.isEmpty {
            return .allFull(strip.filled.enumerated().map {
                SlotChoice(id: $0.offset, name: slotName($0.element))
            })
        } else {
            return .noChannelStrip("I can't see the selected track's channel strip. " +
                                   "Open the Inspector in Logic (press I) and try again.")
        }

        guard let menu = await openMenu(on: target, app: app) else {
            return .failed("Logic's plug-in menu did not open.")
        }
        if await chooseBySearch(plugin, menu: menu, app: app, pid: logic.processIdentifier) {
            return .inserted
        }
        if await chooseByBrowsing(plugin, menu: menu, app: app) {
            return .inserted
        }
        Keyboard.press(53, pid: logic.processIdentifier) // Esc closes the menu
        return .failed("I couldn't find \"\(plugin.name)\" in Logic's plug-in menu. " +
                       "Make sure Logic has scanned it (Plug-in Manager).")
    }

    // MARK: Finding the slots

    private struct Strip {
        var empty: AXNode?
        var filled: [AXNode]
    }

    private func emptyMarkers(_ kind: SlotKind) -> [String] {
        switch kind {
        case .audioFX: return ["Click to insert Audio effect plug-in", "Empty - Audio Plug-in"]
        case .instrument: return ["Click to insert Software Instrument plug-in"]
        case .midiFX: return ["Empty - MIDI Plug-in"]
        }
    }

    private func filledMarker(_ kind: SlotKind) -> String {
        kind == .midiFX ? "MIDI plug-in" : "audio plug-in"
    }

    /// Finds the selected track's strip: the leftmost column of slots inside the Inspector.
    private func findSlots(in win: AXNode, kind: SlotKind, windowMinX: CGFloat) -> Strip {
        let empties = emptyMarkers(kind)
        let filledWord = filledMarker(kind)
        var emptyNodes: [(AXNode, CGRect)] = []
        var filledNodes: [(AXNode, CGRect)] = []
        _ = win.findAll(skipRoles: [AXRole.menuBar]) { node in
            let text = node.allText
            if empties.contains(where: { text.localizedCaseInsensitiveContains($0) }) {
                emptyNodes.append((node, node.frame))
            } else if kind != .instrument,
                      text.localizedCaseInsensitiveContains(filledWord),
                      !text.localizedCaseInsensitiveContains("Empty") {
                filledNodes.append((node, node.frame))
            }
            return false
        }
        let inInspector: ((AXNode, CGRect)) -> Bool = { $0.1.minX - windowMinX < self.inspectorMaxX }
        let emptyIn = emptyNodes.filter(inInspector)
        let filledIn = filledNodes.filter(inInspector)

        // Leftmost column = the selected track (the Inspector's right strip is its output).
        let allX = (emptyIn + filledIn).map(\.1.minX)
        guard let columnX = allX.min() else { return Strip(empty: nil, filled: []) }
        let sameColumn: ((AXNode, CGRect)) -> Bool = { abs($0.1.minX - columnX) < 12 }
        let empty = emptyIn.filter(sameColumn).min { $0.1.minY < $1.1.minY }?.0
        let filled = filledIn.filter(sameColumn).sorted { $0.1.minY < $1.1.minY }.map(\.0)
        return Strip(empty: empty, filled: filled)
    }

    private func slotName(_ node: AXNode) -> String {
        for s in [node.title, node.stringValue, node.desc] {
            let clean = s.replacingOccurrences(of: ", audio plug-in", with: "", options: .caseInsensitive)
                .replacingOccurrences(of: ", MIDI plug-in", with: "", options: .caseInsensitive)
                .trimmingCharacters(in: .whitespaces)
            if !clean.isEmpty, !clean.localizedCaseInsensitiveContains("plug-in") { return clean }
        }
        return node.desc.isEmpty ? "Plug-in" : node.desc
    }

    // MARK: The plug-in menu

    private func openMenu(on slot: AXNode, app: AXNode) async -> AXNode? {
        let actions = slot.actions
        let order = [kAXPressAction, kAXShowMenuAction].filter { actions.contains($0) }
        for action in order.isEmpty ? [kAXPressAction] : order {
            slot.perform(action)
            if let menu = await waitForMenu(app: app) { return menu }
        }
        return nil
    }

    private func waitForMenu(app: AXNode, timeout: Double = 1.5) async -> AXNode? {
        let end = Date().addingTimeInterval(timeout)
        while Date() < end {
            if let menu = app.children.first(where: { $0.role == AXRole.menu })
                ?? app.first(maxNodes: 400, where: { $0.role == AXRole.menu }) {
                return menu
            }
            try? await Task.sleep(for: .milliseconds(80))
        }
        return nil
    }

    private func chooseBySearch(_ plugin: Plugin, menu: AXNode, app: AXNode, pid: pid_t) async -> Bool {
        guard let field = menu.first(maxNodes: 300, where: {
            [AXRole.textField, "AXSearchField"].contains($0.role) || $0.subrole == "AXSearchField"
                || $0.placeholder.localizedCaseInsensitiveContains("Search")
        }) else { return false }
        field.setFocused()
        if !field.setValue(plugin.name) || field.stringValue != plugin.name {
            Keyboard.type(plugin.name, pid: pid)
        }
        try? await Task.sleep(for: .milliseconds(500))

        // Search results replace the menu contents; read them from whichever menu is open now.
        let current = await waitForMenu(app: app) ?? menu
        guard let item = bestItem(for: plugin, in: current) else { return false }
        return await pick(item, app: app)
    }

    private func chooseByBrowsing(_ plugin: Plugin, menu: AXNode, app: AXNode) async -> Bool {
        if plugin.isLogic {
            // Logic's own plugins sit under their category (Reverb → ChromaVerb).
            guard let group = menuItems(menu).first(where: {
                      $0.title.localizedCaseInsensitiveCompare(plugin.category) == .orderedSame
                  }),
                  let list = await submenu(of: group),
                  let item = bestItem(for: plugin, in: list, maxNodes: 2000)
            else { return false }
            return await pick(item, app: app)
        }
        guard let au = menuItems(menu).first(where: { $0.title == "Audio Units" }),
              let makers = await submenu(of: au),
              let maker = menuItems(makers).first(where: {
                  $0.title.localizedCaseInsensitiveCompare(plugin.manufacturer) == .orderedSame
              }),
              let list = await submenu(of: maker),
              let item = bestItem(for: plugin, in: list, maxNodes: 2000)
        else { return false }
        return await pick(item, app: app)
    }

    /// Presses the item; when it opens a channel-format submenu (Mono / Stereo …) picks Stereo.
    private func pick(_ item: AXNode, app: AXNode) async -> Bool {
        if let formats = await submenu(of: item, pressIfNeeded: false) {
            let items = menuItems(formats).filter(\.isEnabled)
            guard let choice = items.first(where: { $0.title == "Stereo" }) ?? items.first
            else { return false }
            return choice.perform(kAXPressAction)
        }
        return item.perform(kAXPressAction)
    }

    private func menuItems(_ menu: AXNode) -> [AXNode] {
        menu.children.filter { $0.role == AXRole.menuItem }
    }

    private func submenu(of item: AXNode, pressIfNeeded: Bool = true) async -> AXNode? {
        if let m = item.children.first(where: { $0.role == AXRole.menu }), !m.children.isEmpty {
            return m
        }
        guard pressIfNeeded else { return nil }
        item.perform(kAXPressAction)
        for _ in 0..<10 {
            try? await Task.sleep(for: .milliseconds(80))
            if let m = item.children.first(where: { $0.role == AXRole.menu }), !m.children.isEmpty {
                return m
            }
        }
        return nil
    }

    private func bestItem(for plugin: Plugin, in menu: AXNode, maxNodes: Int = 600) -> AXNode? {
        let items = menu.findAll(maxNodes: maxNodes) { $0.role == AXRole.menuItem && $0.isEnabled }
        let name = plugin.name
        return items.first { $0.title.localizedCaseInsensitiveCompare(name) == .orderedSame }
            ?? items.first { $0.title.localizedCaseInsensitiveContains(name) &&
                             $0.title.localizedCaseInsensitiveContains(plugin.manufacturer) }
            ?? items.first { $0.title.lowercased().hasPrefix(name.lowercased()) }
    }

    // MARK: Diagnostics

    /// Writes Logic's interface tree to a text file so slot detection can be tuned.
    func dumpDiagnostics() -> URL? {
        guard AXAccess.isTrusted, let logic = logicApp else { return nil }
        let app = AXNode(el: AXUIElementCreateApplication(logic.processIdentifier))
        AXUIElementSetMessagingTimeout(app.el, 2.0)
        var lines: [String] = ["Logic Pro \(logic.bundleURL.flatMap { Bundle(url: $0)?.infoDictionary?["CFBundleShortVersionString"] as? String } ?? "?")"]
        var count = 0
        func walk(_ n: AXNode, _ depth: Int) {
            guard count < 30_000, depth < 60 else { return }
            count += 1
            let f = n.frame
            let parts = [n.role, n.subrole, "t=\(n.title)", "d=\(n.desc)", "h=\(n.help)",
                         "v=\(n.stringValue.prefix(60))", "id=\(n.identifier)",
                         "a=\(n.actions.joined(separator: ","))",
                         "@\(Int(f.minX)),\(Int(f.minY)) \(Int(f.width))x\(Int(f.height))"]
            lines.append(String(repeating: "  ", count: depth) + parts.joined(separator: " | "))
            for c in n.children { walk(c, depth + 1) }
        }
        walk(app, 0)
        let url = PluginStore.shared.supportDir.appendingPathComponent("Logic-interface.txt")
        try? lines.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
        return url
    }
}

enum AXRole {
    static let menu = kAXMenuRole as String
    static let menuItem = kAXMenuItemRole as String
    static let menuBar = kAXMenuBarRole as String
    static let textField = kAXTextFieldRole as String
}
