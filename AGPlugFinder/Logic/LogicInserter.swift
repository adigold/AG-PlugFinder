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

    /// Every attempt is written to "Insert log.txt" in the app's data folder, so a failure can
    /// be traced without guessing.
    func insert(_ plugin: Plugin, replacing slotIndex: Int? = nil) async -> InsertOutcome {
        log("— \(plugin.name) [\(plugin.slotKind.rawValue)] trusted=\(AXAccess.isTrusted) logic=\(logicApp != nil)")
        let outcome = await performInsert(plugin, replacing: slotIndex)
        log("  result: \(outcome)")
        return outcome
    }

    private func log(_ line: String) {
        let url = PluginStore.shared.supportDir.appendingPathComponent("Insert log.txt")
        let stamp = Date().formatted(date: .numeric, time: .standard)
        let text = "\(stamp) \(line)\n"
        if let h = try? FileHandle(forWritingTo: url) {
            h.seekToEndOfFile(); h.write(Data(text.utf8)); try? h.close()
        } else {
            try? text.write(to: url, atomically: true, encoding: .utf8)
        }
    }

    private func performInsert(_ plugin: Plugin, replacing slotIndex: Int?) async -> InsertOutcome {
        guard AXAccess.isTrusted else { return .needsAccessibility }
        guard let logic = logicApp else { return .logicNotRunning }

        // First choice: Logic's own Mix → Search and Add Plug-in…, which puts the plugin on the
        // selected track in the right place (instrument slot or the next free insert).
        if slotIndex == nil {
            switch await searchAndAdd(plugin, logic: logic) {
            case .done: return .inserted
            case .stop(let outcome): return outcome
            case .unavailable: log("  Search and Add not available, falling back to the slots")
            }
        }
        logic.activate()
        try? await Task.sleep(for: .milliseconds(150))

        let app = AXNode(el: AXUIElementCreateApplication(logic.processIdentifier))
        AXUIElementSetMessagingTimeout(app.el, 2.0)
        guard let window: AXUIElement = app.attr(kAXFocusedWindowAttribute) ?? app.attr(kAXMainWindowAttribute)
        else { return .failed("Logic has no open project window.") }
        let win = AXNode(el: window)
        let winFrame = win.frame
        log("  window: \"\(win.title)\" \(Int(winFrame.width))x\(Int(winFrame.height))")

        var strip = findSlots(in: win, kind: plugin.slotKind, windowMinX: winFrame.minX)

        // Slots are typed by Logic's own labels, so an instrument can only meet the instrument
        // slot and an effect only audio effect slots. A track without that kind of slot says so.
        if strip.empty == nil, strip.filled.isEmpty {
            switch plugin.slotKind {
            case .instrument:
                return .failed("The selected track has no instrument slot (it is an audio track). " +
                               "Select a software instrument track to add \(plugin.name).")
            case .midiFX:
                return .failed("MIDI effects go on software instrument tracks. Select one to add \(plugin.name).")
            case .audioFX:
                break
            }
        }
        log("  slots: empty=\(strip.empty != nil) filled=\(strip.filled.count)")
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

        log("  opening slot: \(target.role) \"\(target.allText.prefix(80))\" actions=\(target.actions)")
        guard let menu = await openMenu(on: target, app: app) else {
            return .failed("Logic's plug-in menu did not open.")
        }
        log("  menu opened, items=\(menu.children.count)")
        if await chooseBySearch(plugin, menu: menu, app: app, pid: logic.processIdentifier) {
            return .inserted
        }
        if await chooseByBrowsing(plugin, menu: menu, app: app) {
            return .inserted
        }
        log("  menu titles: " + menuItems(menu).map(\.title).joined(separator: " | "))
        Keyboard.press(53, pid: logic.processIdentifier) // Esc closes the menu
        return .failed("I couldn't find \"\(plugin.name)\" in Logic's plug-in menu. " +
                       "Make sure Logic has scanned it (Plug-in Manager).")
    }

    // MARK: Logic's Search and Add Plug-in

    private enum SearchAddResult { case done, stop(InsertOutcome), unavailable }

    private func searchAndAdd(_ plugin: Plugin, logic: NSRunningApplication) async -> SearchAddResult {
        let pid = logic.processIdentifier
        let app = AXNode(el: AXUIElementCreateApplication(pid))
        AXUIElementSetMessagingTimeout(app.el, 2.0)
        logic.activate()
        try? await Task.sleep(for: .milliseconds(200))

        guard let menuBar: AXUIElement = app.attr(kAXMenuBarAttribute),
              let mix = AXNode(el: menuBar).children.first(where: { $0.title == "Mix" }),
              let mixMenu = mix.children.first(where: { $0.role == AXRole.menu }),
              let command = mixMenu.children.first(where: { $0.title.hasPrefix("Search and Add Plug-in") })
        else { return .unavailable }
        guard command.isEnabled else {
            return .stop(.failed("Select a track in Logic first, then try again."))
        }
        let windowsBefore = Set(app.children.filter { $0.role == kAXWindowRole as String }.map { CFHash($0.el) })
        command.perform(kAXPressAction)
        log("  pressed Mix > Search and Add Plug-in")

        // Find the search field Logic opens (focused element, or a field in a new window).
        var field: AXNode?
        for _ in 0..<25 {
            try? await Task.sleep(for: .milliseconds(80))
            if let focused: AXUIElement = app.attr(kAXFocusedUIElementAttribute) {
                let f = AXNode(el: focused)
                if [AXRole.textField, "AXSearchField", "AXComboBox"].contains(f.role) { field = f; break }
            }
        }
        guard let field else {
            log("  no search field appeared")
            Keyboard.press(53, pid: pid)
            return .stop(.failed("Logic's plug-in search did not open. Click a track in Logic and try again."))
        }
        log("  search field: \(field.role) \"\(field.placeholder)\"")
        if !field.setValue(plugin.name) || field.stringValue != plugin.name {
            Keyboard.type(plugin.name, pid: pid)
        }
        try? await Task.sleep(for: .milliseconds(600))

        // The results live in the window that holds the field.
        let popup = window(containing: field, app: app, before: windowsBefore)
        let candidates = popup.findAll(maxNodes: 3000) { n in
            let r = n.role
            return r == "AXRow" || r == "AXCell" || r == "AXStaticText" || r == AXRole.menuItem
                || r == "AXButton" || r == "AXOutlineRow"
        }
        let name = plugin.name.lowercased()
        func text(_ n: AXNode) -> String { [n.title, n.stringValue, n.desc].first { !$0.isEmpty } ?? "" }
        let exact = candidates.filter { text($0).lowercased() == name }
        log("  results: \(candidates.count) elements, \(exact.count) exact for \"\(plugin.name)\"")
        if exact.isEmpty {
            logTree(popup)
            Keyboard.press(53, pid: pid)
            return .stop(.failed("Logic's search did not list \"\(plugin.name)\". " +
                                 "If it is an instrument, select a software instrument track."))
        }
        // Prefer the match whose row also names the maker (two plugins can share a name).
        let maker = plugin.manufacturer.lowercased()
        let pick = exact.first { el in
            let rowText = (parentRow(of: el) ?? el).findAll(maxNodes: 40) { _ in true }
                .map { text($0).lowercased() }.joined(separator: " ")
            return rowText.contains(maker)
        } ?? exact[0]
        let row = parentRow(of: pick) ?? pick
        AXUIElementSetAttributeValue(row.el, kAXSelectedAttribute as CFString, kCFBooleanTrue)
        if row.actions.contains(kAXPressAction) {
            row.perform(kAXPressAction)
        } else {
            Keyboard.press(36, pid: pid) // Return adds the selected result
        }
        log("  picked \(row.role) \"\(text(pick))\"")
        return .done
    }

    private func window(containing node: AXNode, app: AXNode, before: Set<CFHashCode>) -> AXNode {
        var current: AXUIElement? = node.el
        while let el = current {
            let n = AXNode(el: el)
            if n.role == kAXWindowRole as String { return n }
            current = n.attr(kAXParentAttribute)
        }
        let windows = app.children.filter { $0.role == kAXWindowRole as String }
        return windows.first { !before.contains(CFHash($0.el)) } ?? windows.first ?? app
    }

    private func parentRow(of node: AXNode) -> AXNode? {
        var current: AXUIElement? = node.el
        for _ in 0..<4 {
            guard let el = current else { return nil }
            let n = AXNode(el: el)
            if n.role == "AXRow" || n.role == "AXOutlineRow" { return n }
            current = n.attr(kAXParentAttribute)
        }
        return nil
    }

    /// Writes a small tree of the search window to the log, for tuning.
    private func logTree(_ root: AXNode) {
        var count = 0
        func walk(_ n: AXNode, _ depth: Int) {
            guard count < 120, depth < 12 else { return }
            count += 1
            log("    " + String(repeating: "  ", count: depth) +
                "\(n.role) t=\(n.title) v=\(n.stringValue.prefix(40)) d=\(n.desc) h=\(n.help.prefix(40))")
            for c in n.children { walk(c, depth + 1) }
        }
        walk(root, 0)
    }

    // MARK: Finding the slots

    private struct Strip {
        var empty: AXNode?
        var filled: [AXNode]
        /// Where the audio insert column sits, used to find the instrument slot above it.
        var columnX: CGFloat?
        var topY: CGFloat?
    }


    /// Logic labels every slot with its kind in the help text, e.g. "Audio Effect slot. Insert an
    /// audio effect…". Only slots of the plugin's own kind are ever touched.
    private func slotKind(of node: AXNode) -> SlotKind? {
        let help = node.help.lowercased()
        let text = node.allText.lowercased()
        if help.contains("audio effect slot") || text.contains("click to insert audio effect") { return .audioFX }
        if help.contains("midi effect slot") || text.contains("empty - midi plug-in") { return .midiFX }
        if help.contains("instrument slot") || text.contains("click to insert software instrument") {
            return .instrument
        }
        return nil
    }

    /// An empty slot shows no plugin name; a filled one carries the plugin's name as its title.
    private func isEmptySlot(_ node: AXNode) -> Bool {
        let name = node.title.trimmingCharacters(in: .whitespaces)
        if node.allText.localizedCaseInsensitiveContains("Click to insert") { return true }
        if node.desc.localizedCaseInsensitiveContains("Empty") { return true }
        return name.isEmpty
    }

    /// Finds the selected track's strip: the leftmost column of slots of this kind in the Inspector.
    private func findSlots(in win: AXNode, kind: SlotKind, windowMinX: CGFloat) -> Strip {
        var emptyNodes: [(AXNode, CGRect)] = []
        var filledNodes: [(AXNode, CGRect)] = []
        _ = win.findAll(skipRoles: [AXRole.menuBar]) { node in
            guard node.role == "AXButton" || node.role == "AXMenuButton" || node.role == "AXPopUpButton",
                  slotKind(of: node) == kind else { return false }
            if isEmptySlot(node) { emptyNodes.append((node, node.frame)) }
            else { filledNodes.append((node, node.frame)) }
            return false
        }
        let inInspector: ((AXNode, CGRect)) -> Bool = { $0.1.minX - windowMinX < self.inspectorMaxX }
        let emptyIn = emptyNodes.filter(inInspector)
        let filledIn = filledNodes.filter(inInspector)

        // Leftmost column = the selected track (the Inspector's right strip is its output).
        let allX = (emptyIn + filledIn).map(\.1.minX)
        guard let columnX = allX.min() else { return Strip(empty: nil, filled: []) }
        let sameColumn: ((AXNode, CGRect)) -> Bool = { abs($0.1.minX - columnX) < 12 }
        let column = (emptyIn + filledIn).filter(sameColumn)
        let empty = emptyIn.filter(sameColumn).min { $0.1.minY < $1.1.minY }?.0
        let filled = filledIn.filter(sameColumn).sorted { $0.1.minY < $1.1.minY }.map(\.0)
        return Strip(empty: empty, filled: filled, columnX: columnX,
                     topY: column.map(\.1.minY).min())
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
