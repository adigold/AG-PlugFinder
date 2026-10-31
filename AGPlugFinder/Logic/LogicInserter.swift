import AppKit
import ApplicationServices
import AudioToolbox

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

    /// True while a new instrument track is being made for an instrument (BL-52).
    private var makingTrack = false

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

    func log(_ line: String) {
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

        // Instruments: Logic's Search and Add only lists audio effects, so an instrument goes
        // straight into the selected track's instrument slot through that slot's own menu.
        if plugin.slotKind == .instrument {
            return await insertInstrument(plugin, logic: logic, confirmedReplace: slotIndex != nil)
        }

        // Audio effects: Logic's own Mix → Search and Add Plug-in… puts the plugin in the next
        // free insert of the selected track. It only lists audio effects, so MIDI effects go
        // through the MIDI Effect slot's own menu below.
        // Legacy plug-ins are not in Logic's search, only in the slot menu's Legacy submenu.
        if slotIndex == nil, plugin.slotKind == .audioFX, plugin.isLegacy != true {
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
        guard let window: AXUIElement = projectWindow(app)
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
        guard let menu = await openMenu(on: target, app: app, legacy: plugin.isLegacy == true) else {
            return .failed("Logic's plug-in menu did not open.")
        }
        log("  menu opened, items=\(menu.children.count)")
        if plugin.isLegacy == true {
            if await chooseLegacy(plugin, menu: menu, app: app) { return .inserted }
        } else if await chooseBySearch(plugin, menu: menu, app: app, pid: logic.processIdentifier) {
            return .inserted
        }
        if await chooseByBrowsing(plugin, menu: menu, app: app) {
            return .inserted
        }
        log("  menu titles: " + menuItems(menu).map(\.title).joined(separator: " | "))
        Keyboard.escapeIfOpen(pid: logic.processIdentifier) // Esc closes the menu
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
            Keyboard.escapeIfOpen(pid: pid)
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
            Keyboard.escapeIfOpen(pid: pid)
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

    func openMenu(on slot: AXNode, app: AXNode, legacy: Bool = false) async -> AXNode? {
        let actions = slot.actions
        // Logic's own second action on a slot (its Option-click) lists the legacy plug-ins too.
        if legacy, let withLegacy = actions.first(where: { $0.contains("legacy plug-ins") }) {
            slot.perform(withLegacy)
            if let menu = await waitForMenu(app: app) { return menu }
        }
        let order = [kAXPressAction, kAXShowMenuAction].filter { actions.contains($0) }
        for action in order.isEmpty ? [kAXPressAction] : order {
            slot.perform(action)
            if let menu = await waitForMenu(app: app) { return menu }
        }
        return nil
    }

    func waitForMenu(app: AXNode, timeout: Double = 1.5) async -> AXNode? {
        let end = Date().addingTimeInterval(timeout)
        while Date() < end {
            // A pop-up menu Logic opens is a child of the app or of a window, never the
            // menu bar's own menus (those would be the Apple menu, File, Edit …).
            for top in app.children where top.role != AXRole.menuBar {
                if top.role == AXRole.menu, !top.children.isEmpty { return top }
                if let menu = top.first(maxNodes: 400, where: { $0.role == AXRole.menu && !$0.children.isEmpty }) {
                    return menu
                }
            }
            try? await Task.sleep(for: .milliseconds(80))
        }
        return nil
    }

    func chooseBySearch(_ plugin: Plugin, menu: AXNode, app: AXNode, pid: pid_t) async -> Bool {
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

    /// The slot menu's Legacy submenu: Legacy → group (Delay, EQ …) → plug-in.
    func chooseLegacy(_ plugin: Plugin, menu: AXNode, app: AXNode) async -> Bool {
        var groups = menu
        if let legacy = menuItems(menu).first(where: { $0.title == "Legacy" }),
           let sub = await submenu(of: legacy) { groups = sub }
        if let item = bestLegacyItem(plugin, in: groups) { return await pick(item, app: app) }
        for group in menuItems(groups) {
            guard let list = await submenu(of: group) else { continue }
            if let item = bestLegacyItem(plugin, in: list) {
                log("  legacy group: \(group.title)")
                return await pick(item, app: app)
            }
        }
        log("  legacy groups: " + menuItems(groups).map(\.title).joined(separator: " | "))
        return false
    }

    private func bestLegacyItem(_ plugin: Plugin, in menu: AXNode) -> AXNode? {
        menuItems(menu).first { $0.isEnabled && $0.title.localizedCaseInsensitiveCompare(plugin.name) == .orderedSame }
    }

    func chooseByBrowsing(_ plugin: Plugin, menu: AXNode, app: AXNode) async -> Bool {
        if plugin.isLogic {
            // Top level first (Drum Machine Designer, recent items), then Logic's groups.
            if let item = menuItems(menu).first(where: {
                $0.title.localizedCaseInsensitiveCompare(plugin.name) == .orderedSame
            }) { return await pick(item, app: app) }
            let groups = plugin.slotKind == .instrument
                ? ["Synthesizer", "Sampler", "Studio Instruments", "Vintage Keys", "Drums", "Utility"]
                : [plugin.category]
            for title in groups {
                guard let group = menuItems(menu).first(where: {
                          $0.title.localizedCaseInsensitiveCompare(title) == .orderedSame
                      }),
                      let list = await submenu(of: group) else { continue }
                if let item = bestItem(for: plugin, in: list, maxNodes: 2000) {
                    return await pick(item, app: app)
                }
            }
            return false
        }
        let auMenu: String
        switch plugin.componentType {
        case kAudioUnitType_MusicDevice: auMenu = "AU Instruments"
        case kAudioUnitType_MusicEffect: auMenu = "AU MIDI-controlled Effects"
        case kAudioUnitType_MIDIProcessor: auMenu = "AU MIDI-controlled Effects"
        default: auMenu = "Audio Units"
        }
        guard let au = menuItems(menu).first(where: { $0.title == auMenu }),
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
    func pick(_ item: AXNode, app: AXNode) async -> Bool {
        if let formats = await submenu(of: item, pressIfNeeded: false) {
            let items = menuItems(formats).filter(\.isEnabled)
            guard let choice = items.first(where: { $0.title == "Stereo" }) ?? items.first
            else { return false }
            return choice.perform(kAXPressAction)
        }
        return item.perform(kAXPressAction)
    }

    func menuItems(_ menu: AXNode) -> [AXNode] {
        menu.children.filter { $0.role == AXRole.menuItem }
    }

    func submenu(of item: AXNode, pressIfNeeded: Bool = true) async -> AXNode? {
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

    // MARK: The project window

    /// Logic's project window, never a plug-in window (inserting opens the plug-in's window,
    /// which then becomes the focused one): the window titled "… - Tracks", else the largest.
    /// The selected track's name, from the inspector's channel strip ("Left inspector channel
    /// strip", its description is the track name), else the inspector's "Track:" name field.
    /// Read only. Only the inspector on the left of the window is searched, so it is quick.
    func selectedTrackName() -> String? {
        guard AXAccess.isTrusted, let logic = logicApp else { return nil }
        return Self.trackName(pid: logic.processIdentifier)
    }

    nonisolated static func trackName(pid: pid_t) -> String? {
        let app = AXNode(el: AXUIElementCreateApplication(pid))
        AXUIElementSetMessagingTimeout(app.el, 0.5)
        let windows = app.children.filter { $0.role == kAXWindowRole as String }
        guard let win = windows.first(where: { $0.title.contains(" - ") }) else { return nil }
        let left = win.frame.minX + 420
        var queue = [win]
        var i = 0
        var fieldAfterTrackLabel = false
        while i < queue.count, i < 6000 {
            let n = queue[i]; i += 1
            if n.help.hasPrefix("Left inspector channel strip"), !n.desc.isEmpty { return n.desc }
            if n.help.hasPrefix("Name field. Double-click to rename the channel strip"), !n.stringValue.isEmpty {
                return n.stringValue
            }
            for c in n.children {
                let f = c.frame
                // Skip everything right of the inspector (tracks, regions, rulers).
                if f.width > 0, f.minX > left { continue }
                if c.role == "AXStaticText", c.stringValue == "Track:" { fieldAfterTrackLabel = true; continue }
                if fieldAfterTrackLabel, c.role == AXRole.textField, !c.stringValue.isEmpty { return c.stringValue }
                queue.append(c)
            }
            fieldAfterTrackLabel = false
        }
        return nil
    }

    func projectWindow(_ app: AXNode) -> AXUIElement? {
        let windows = app.children.filter { $0.role == kAXWindowRole as String }
        if let tracks = windows.first(where: { $0.title.hasSuffix("- Tracks") })
            ?? windows.first(where: { $0.title.contains(" - ") && !$0.title.contains(" - Mixer") }) {
            return tracks.el
        }
        return windows.max { a, b in
            let fa = a.frame, fb = b.frame
            return fa.width * fa.height < fb.width * fb.height
        }?.el ?? app.attr(kAXMainWindowAttribute)
    }

    // MARK: The instrument slot

    private func insertInstrument(_ plugin: Plugin, logic: NSRunningApplication,
                                  confirmedReplace: Bool) async -> InsertOutcome {
        let app = AXNode(el: AXUIElementCreateApplication(logic.processIdentifier))
        AXUIElementSetMessagingTimeout(app.el, 2.0)
        logic.activate()
        try? await Task.sleep(for: .milliseconds(150))
        guard let window: AXUIElement = projectWindow(app)
        else { return .failed("Logic has no open project window.") }
        guard let slot = instrumentSlot(in: AXNode(el: window)) else {
            // An audio or aux track has no instrument slot: make a new instrument track for it
            // (BL-52), unless this is that new track already.
            if !makingTrack {
                log("  no instrument slot: making a new instrument track")
                makingTrack = true
                defer { makingTrack = false }
                if let problem = await LogicTrack.shared.newInstrumentTrack(plugin) { return .failed(problem) }
                return .inserted
            }
            return .failed("The selected track has no instrument slot. Select a software instrument " +
                           "track (and show the Inspector with I) to add \(plugin.name).")
        }
        log("  instrument slot: \(slot.current ?? "empty") actions=\(slot.press.actions)")
        // A track has one instrument; replacing it is always the user's choice.
        if let current = slot.current, !confirmedReplace {
            return .allFull([SlotChoice(id: 0, name: current)])
        }
        let pid = logic.processIdentifier
        let normal = slot.press.actions.first { $0.localizedCaseInsensitiveContains("Open plug-in menu") &&
                                                !$0.localizedCaseInsensitiveContains("legacy") }
        let withLegacy = slot.press.actions.first { $0.localizedCaseInsensitiveContains("legacy plug-ins") }
        if plugin.isLegacy != true {
            slot.press.perform(normal ?? kAXPressAction)
            guard let menu = await waitForMenu(app: app) else {
                Keyboard.escapeIfOpen(pid: pid)
                return .failed("Logic's instrument menu did not open.")
            }
            if await chooseBySearch(plugin, menu: menu, app: app, pid: pid) { return .inserted }
            if await chooseByBrowsing(plugin, menu: menu, app: app) { return .inserted }
            log("  menu titles: " + menuItems(menu).map(\.title).joined(separator: " | "))
            Keyboard.escapeIfOpen(pid: pid)
            Keyboard.escapeIfOpen(pid: pid)
            try? await Task.sleep(for: .milliseconds(300))
        }
        // Legacy instruments (and Logic instruments that moved to Legacy): the slot's legacy menu.
        if plugin.isLogic {
            if let withLegacy {
                slot.press.perform(withLegacy)
            } else {
                // An empty instrument slot has no legacy action: Option-click it, as a person would.
                Keyboard.optionClick(at: CGPoint(x: slot.press.frame.midX, y: slot.press.frame.midY))
            }
            if let menu = await waitForMenu(app: app) {
                if await chooseLegacy(plugin, menu: menu, app: app) { return .inserted }
                log("  legacy menu titles: " + menuItems(menu).map(\.title).joined(separator: " | "))
            }
            Keyboard.escapeIfOpen(pid: pid)
            Keyboard.escapeIfOpen(pid: pid)
        }
        return .failed("I couldn't find \"\(plugin.name)\" in Logic's instrument menu.")
    }

    /// The selected strip's instrument slot: the slot directly under its MIDI Effect slot.
    /// Filled, it is a group named after the instrument with bypass / open / list buttons
    /// (the list button opens Logic's plug-in menu); empty, it is a single button.
    struct InstrumentSlot {
        let press: AXNode      // what opens the plug-in menu
        let current: String?   // the instrument in it now, nil when empty
    }

    func instrumentSlot(in win: AXNode) -> InstrumentSlot? {
        let minX = win.frame.minX
        let midiSlots = win.findAll(skipRoles: [AXRole.menuBar]) { n in
            n.help.localizedCaseInsensitiveContains("MIDI Effect slot") && n.frame.minX - minX < inspectorMaxX
        }
        guard let midi = midiSlots.min(by: { $0.frame.minX < $1.frame.minX }) else { return nil }
        let mf = midi.frame
        // The next control below the MIDI slot in the same column.
        let below = win.findAll(skipRoles: [AXRole.menuBar]) { n in
            let f = n.frame
            return abs(f.minX - mf.minX) < 4 && f.minY >= mf.maxY + 4 && f.minY < mf.maxY + 40
                && f.height > 10 && f.height < 30
                && (n.role == "AXGroup" || n.role == "AXButton")
        }.sorted { $0.frame.minY < $1.frame.minY }
        guard let slot = below.first else { return nil }
        if slot.help.localizedCaseInsensitiveContains("Audio Effect slot") { return nil } // audio track
        if slot.role == "AXGroup" {
            guard let list = slot.children.first(where: { $0.desc == "list" }) else { return nil }
            return InstrumentSlot(press: list, current: slot.desc.isEmpty ? "instrument" : slot.desc)
        }
        return InstrumentSlot(press: slot, current: nil)
    }

    // MARK: Probe

    /// The plugins on the selected (left Inspector) strip right now, top to bottom.
    func stripContents() -> [String] {
        guard AXAccess.isTrusted, let logic = logicApp else { return ["no access"] }
        let app = AXNode(el: AXUIElementCreateApplication(logic.processIdentifier))
        AXUIElementSetMessagingTimeout(app.el, 2.0)
        guard let window: AXUIElement = projectWindow(app)
        else { return ["no window"] }
        let win = AXNode(el: window)
        let minX = win.frame.minX
        let groups = win.findAll(skipRoles: [AXRole.menuBar]) { n in
            n.role == "AXGroup" && !n.desc.isEmpty && n.frame.minX - minX < 60 && n.frame.minX - minX > 10
                && n.children.contains(where: { $0.desc == "list" })
                && n.children.contains(where: { $0.desc == "bypass" })
        }
        return groups.sorted { $0.frame.minY < $1.frame.minY }.map { $0.desc }
    }

    /// Every slot-like control in the Inspector, with its help text and actions (read-only).
    func describeSlots() -> [String] {
        guard AXAccess.isTrusted, let logic = logicApp else { return ["not trusted or Logic closed"] }
        let app = AXNode(el: AXUIElementCreateApplication(logic.processIdentifier))
        AXUIElementSetMessagingTimeout(app.el, 2.0)
        guard let window: AXUIElement = projectWindow(app)
        else { return ["no window"] }
        let win = AXNode(el: window)
        let minX = win.frame.minX
        return win.findAll(skipRoles: [AXRole.menuBar]) { n in
            (n.role == "AXButton" || n.role == "AXMenuButton" || n.role == "AXPopUpButton")
                && n.frame.minX - minX < inspectorMaxX
                && n.help.localizedCaseInsensitiveContains("slot")
        }.map { n in
            let f = n.frame
            return "\(n.role) t=\(n.title) d=\(n.desc) @\(Int(f.minX)),\(Int(f.minY)) h=\(n.help) a=\(n.actions.map { $0.components(separatedBy: "\n").first ?? $0 })"
        }
    }

    func probeInstrumentMenu() async -> String {
        let slots = describeSlots()
        for s in slots { log("  slot: \(s)") }
        guard let logic = logicApp else { return "Logic closed" }
        let app = AXNode(el: AXUIElementCreateApplication(logic.processIdentifier))
        AXUIElementSetMessagingTimeout(app.el, 2.0)
        guard let window: AXUIElement = projectWindow(app)
        else { return "no window" }
        let win = AXNode(el: window)
        let minX = win.frame.minX
        _ = minX
        guard let inst = instrumentSlot(in: win) else { return "no instrument slot found (\(slots.count) slots)" }
        log("  instrument slot: current=\(inst.current ?? "empty") press=\(inst.press.role) \(inst.press.desc) a=\(inst.press.actions.map { $0.components(separatedBy: "\n").first ?? $0 })")
        logic.activate()
        try? await Task.sleep(for: .milliseconds(250))
        let menuAction = inst.press.actions.first { $0.localizedCaseInsensitiveContains("Open plug-in menu") &&
                                                    !$0.localizedCaseInsensitiveContains("legacy") }
        inst.press.perform(menuAction ?? kAXPressAction)
        guard let menu = await waitForMenu(app: app) else {
            Keyboard.escapeIfOpen(pid: logic.processIdentifier)
            return "menu did not open (action \(menuAction ?? "AXPress"))"
        }
        let top = menuItems(menu).map(\.title)
        log("  instrument menu: " + top.joined(separator: " | "))
        let fields = menu.findAll(maxNodes: 300) { [AXRole.textField, "AXSearchField"].contains($0.role) }
        log("  search fields in menu: \(fields.map { "\($0.role) \($0.placeholder)" })")
        if let au = menuItems(menu).first(where: { $0.title.localizedCaseInsensitiveContains("AU ") }),
           let sub = await submenu(of: au) {
            log("  \(au.title): " + menuItems(sub).map(\.title).joined(separator: " | "))
            if let maker = menuItems(sub).first, let list = await submenu(of: maker) {
                log("    \(maker.title): " + menuItems(list).map(\.title).joined(separator: " | "))
                if let first = menuItems(list).first, let formats = await submenu(of: first, pressIfNeeded: false) {
                    log("      \(first.title): " + menuItems(formats).map(\.title).joined(separator: " | "))
                }
            }
        }
        if let alchemy = menuItems(menu).first(where: { $0.title == "Alchemy" }),
           let formats = await submenu(of: alchemy, pressIfNeeded: false) {
            log("  Alchemy: " + menuItems(formats).map(\.title).joined(separator: " | "))
        }
        Keyboard.escapeIfOpen(pid: logic.processIdentifier)
        Keyboard.escapeIfOpen(pid: logic.processIdentifier)
        return "ok, \(top.count) entries"
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

/// `--dump-logic` saves Logic's interface tree; `--probe-instrument-menu` opens the selected
/// track's instrument slot menu, writes its entries to the insert log and closes it with Esc.
/// Neither changes anything in the project.
enum LogicProbe {
    static func run(_ args: [String]) -> Never {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        Task { @MainActor in
            let inserter = LogicInserter.shared
            if args.contains("--dump-logic") {
                print("DUMP \(inserter.dumpDiagnostics()?.path ?? "failed")")
            }
            if args.contains("--probe-instrument-menu") {
                print("PROBE \(await inserter.probeInstrumentMenu())")
            }
            // --track-name: logs the selected track's name (read only).
            if args.contains("--track-name") {
                inserter.log("TRACK \(inserter.selectedTrackName() ?? "none") trusted=\(AXAccess.isTrusted)")
            }
            // --track <action> [args]: the track features, one at a time, for live checks.
            if let i = args.firstIndex(of: "--track"), i + 1 < args.count {
                let t = LogicTrack.shared
                let rest = Array(args[(i + 2)...])
                @MainActor func plugin(_ n: String) -> Plugin? { PluginStore.shared.plugins.first { $0.name == n } }
                @MainActor func slot(_ n: String) -> StripPlugin? { t.read()?.plugins.first { $0.name == n } }
                @MainActor func dump(_ tag: String) {
                    let r = t.read()
                    inserter.log("TRACKTEST \(tag): \(r?.track ?? "none") = " +
                                 (r?.plugins.map { "\($0.name)[\($0.kind.rawValue) on=\($0.isOn.map(String.init) ?? "?")]" }.joined(separator: " | ") ?? ""))
                }
                dump("before")
                var result = "ok"
                switch args[i + 1] {
                case "toggle": if let s = slot(rest[0]) { t.toggle(s) }
                case "remove-last": result = await t.removeLastAdded() ?? "nothing"
                case "clear": result = "\(await t.clearEffects())"
                case "open-all": result = "\(await t.openAll())"
                case "close-all": await t.closeAll()
                case "close-mixer": t.closeMixer()
                case "move": if let s = slot(rest[0]) { result = "\(await t.move(s, toEffect: Int(rest[1])!))" }
                case "open-mixer": await t.showMixer()
                case "tile":
                    if let (_, app) = t.logic() {
                        t.tilePluginWindows(app)
                        for ms in [100, 400, 1000, 2000] {
                            try? await Task.sleep(for: .milliseconds(ms))
                            inserter.log("TRACK after \(ms)ms: " + app.children.filter { !$0.title.contains(" - ") }.map { "\(Int($0.frame.minX))" }.joined(separator: ","))
                        }
                    }
                case "sendup":
                    if let (_, app) = t.logic(), let strip = t.leftStrip(app),
                       let k = strip.findAll(maxNodes: 300, where: { $0.desc == "send knob" }).first {
                        var steps: [String] = []
                        for _ in 0..<Int(rest[0])! {
                            k.perform(kAXIncrementAction)
                            try? await Task.sleep(for: .milliseconds(60))
                            let v: AnyObject? = k.attr(kAXValueAttribute)
                            let d: AnyObject? = k.attr("AXValueDescription")
                            steps.append("\(v.map { "\($0)" } ?? "?")=\(d.map { "\($0)" } ?? "?")")
                        }
                        result = steps.joined(separator: " ")
                    }
                case "sendlevel":
                    if let (_, app) = t.logic(), let strip = t.leftStrip(app) {
                        result = strip.findAll(maxNodes: 300) { $0.desc == "send knob" }.map { k in
                            let v: AnyObject? = k.attr(kAXValueAttribute)
                            let d: AnyObject? = k.attr("AXValueDescription")
                            return "\(String(describing: v)) / \(String(describing: d))"
                        }.joined(separator: ", ")
                    }
                case "replace": if let s = slot(rest[0]), let p = plugin(rest[1]) { result = await t.replace(s, with: p) ?? "ok" }
                case "before", "after":
                    if let s = slot(rest[0]), let p = plugin(rest[1]) {
                        result = await t.insert(p, before: args[i + 1] == "before", s) ?? "ok"
                    }
                case "send": if let p = plugin(rest[0]) { result = await t.addAsSend(p) ?? "ok" }
                case "newtrack": if let p = plugin(rest[0]) { result = await t.newInstrumentTrack(p) ?? "ok" }
                case "scan": result = (await t.scanProject())?.map { "\($0.name): \($0.plugins)" }.joined(separator: " ; ") ?? "nil"
                case "goto":
                    if let tr = await t.scanProject()?.first(where: { $0.name == rest[0] }) { result = "\(await t.goTo(tr))" }
                case "add":
                    if let p = plugin(rest[0]), let all = await t.scanProject() {
                        result = await t.add([p], to: all.filter { rest.dropFirst().contains($0.name) })
                    }
                default: result = "unknown action"
                }
                try? await Task.sleep(for: .milliseconds(800))
                inserter.log("TRACKTEST result: \(result)")
                dump("after")
            }
            // --close-logic-windows: closes every open plug-in window in Logic.
            if args.contains("--close-logic-windows"), let logic = inserter.logicApp {
                let app = AXNode(el: AXUIElementCreateApplication(logic.processIdentifier))
                await LogicCapture.closePluginWindows(app, pid: logic.processIdentifier)
                inserter.log("CLOSE windows done")
            }
            // --capture-logic <name>…: screenshots of Logic's own plugins (all when no names).
            if let i = args.firstIndex(of: "--capture-logic") {
                if !LogicCapture.hasScreenAccess { LogicCapture.requestScreenAccess() }
                let names = Set(args[(i + 1)...].filter { !$0.hasPrefix("--") })
                let list = PluginStore.shared.plugins.filter {
                    $0.isLogic && ($0.isLegacy != true || args.contains("--legacy")) && (names.isEmpty
                        ? !FileManager.default.fileExists(atPath: PluginStore.shared.snapshotURL(for: $0.id).path)
                        : names.contains($0.name))
                }
                let r = await LogicCapture.run(list) { _, name in inserter.log("CAPTURE start \(name)") }
                inserter.log("CAPTURE done \(r.done), failed: \(r.failed.joined(separator: ", "))")
            }
            // --test-insert <name> [--replace]: insert exactly like Return, then read the strip back.
            if let i = args.firstIndex(of: "--test-insert"), i + 1 < args.count {
                let name = args[i + 1]
                let store = PluginStore.shared
                if let p = store.plugins.first(where: { $0.name == name }) {
                    inserter.log("TEST insert \(name)")
                    let outcome = await inserter.insert(p, replacing: args.contains("--replace") ? 0 : nil)
                    try? await Task.sleep(for: .milliseconds(1200))
                    let strip = inserter.stripContents()
                    inserter.log("TEST outcome \(outcome) · strip now: \(strip.joined(separator: " | "))")
                } else {
                    inserter.log("TEST no plugin named \(name)")
                }
            }
            fflush(stdout)
            exit(0)
        }
        app.run()
        exit(0)
    }
}
