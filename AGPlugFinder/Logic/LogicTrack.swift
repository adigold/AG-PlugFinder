import AppKit
import ApplicationServices

/// One plugin on a channel strip, top to bottom (BL-35).
struct StripPlugin: Identifiable, Hashable {
    let id: Int          // position among the strip's plugins, top to bottom
    let name: String
    let kind: SlotKind
    let isOn: Bool?      // nil when Logic doesn't say
}

/// A channel strip in the project's Mixer (BL-40, BL-41).
struct ProjectTrack: Identifiable, Hashable {
    var id: String { "\(index)|\(name)" }
    let index: Int       // left to right in the Mixer
    let name: String
    let plugins: [String]
}

/// Works on the selected track's channel strip and on the project's Mixer through Logic's own
/// controls: the inspector strip's plug-in buttons, the slot menus, and the menu bar. Never
/// sends Esc and never types into Logic's main window.
@MainActor
final class LogicTrack {
    static let shared = LogicTrack()
    private let inserter = LogicInserter.shared

    /// The last plugin AG PlugFinder added, for "Remove last added" (BL-38).
    var lastAdded: String?

    // MARK: Reading

    struct Slot {
        let group: AXNode
        let kind: SlotKind
        let name: String
        let frame: CGRect
        func child(_ desc: String) -> AXNode? { group.children.first { $0.desc == desc } }
    }

    func logic() -> (NSRunningApplication, AXNode)? {
        guard AXAccess.isTrusted, let logic = inserter.logicApp else { return nil }
        let app = AXNode(el: AXUIElementCreateApplication(logic.processIdentifier))
        AXUIElementSetMessagingTimeout(app.el, 2.0)
        return (logic, app)
    }

    /// The Tracks window's left inspector strip, which always shows the selected track.
    func leftStrip(_ app: AXNode) -> AXNode? {
        guard let w = inserter.projectWindow(app) else { return nil }
        return AXNode(el: w).first(maxNodes: 5000) {
            $0.role == "AXLayoutItem" && $0.help.hasPrefix("Left inspector channel strip")
        }
    }

    /// A strip's plugins in signal order. A filled slot is a group with bypass, open and list
    /// buttons. MIDI effects sit above the empty MIDI slot, the instrument right under it, and
    /// audio effects between the instrument and the empty audio slot (sends come after).
    func slots(in strip: AXNode) -> [Slot] {
        let kids = strip.children
        let groups = kids.filter { g in
            g.role == "AXGroup" && !g.desc.isEmpty
                && g.children.contains { $0.desc == "bypass" } && g.children.contains { $0.desc == "list" }
        }.map { ($0, $0.frame) }.sorted { $0.1.minY < $1.1.minY }
        func ys(_ prefix: String) -> [CGFloat] { kids.filter { $0.help.hasPrefix(prefix) }.map(\.frame.minY) }
        let emptyMidi = ys("MIDI Effect slot").max()
        let audioEnd = ys("Audio Effect slot").max() ?? ys("Send slot").min() ?? ys("Output slot").min()
            ?? .greatestFiniteMagnitude
        var instrumentY: CGFloat?
        if let m = emptyMidi, let g = groups.first(where: { $0.1.minY > m && $0.1.minY < m + 40 }) {
            instrumentY = g.1.minY
        }
        var out: [Slot] = []
        for (g, f) in groups {
            let kind: SlotKind
            if let m = emptyMidi, f.minY < m { kind = .midiFX }
            else if f.minY == instrumentY { kind = .instrument }
            else if f.minY < audioEnd { kind = .audioFX }
            else { continue }
            out.append(Slot(group: g, kind: kind, name: g.desc, frame: f))
        }
        return out
    }

    /// Logic's bypass box is ticked while the plug-in is bypassed (off).
    static func isOn(_ slot: Slot) -> Bool? {
        guard let box = slot.child("bypass"), let v: NSNumber = box.attr(kAXValueAttribute) else { return nil }
        return v.intValue == 0
    }

    /// The selected track's name and plugins; nil when Logic or its inspector is not there.
    func read() -> (track: String, plugins: [StripPlugin])? {
        guard let (_, app) = logic(), let strip = leftStrip(app) ?? leftStrip(app) else { return nil }
        let list = slots(in: strip).enumerated().map { i, s in
            StripPlugin(id: i, name: s.name, kind: s.kind, isOn: Self.isOn(s))
        }
        return (strip.desc, list)
    }

    /// Finds the slot again right before acting on it (Logic rebuilds its controls often).
    private func locate(_ p: StripPlugin) -> (NSRunningApplication, AXNode, Slot)? {
        guard let (logic, app) = logic(), let strip = leftStrip(app) else { return nil }
        let all = slots(in: strip)
        if all.indices.contains(p.id), all[p.id].name == p.name { return (logic, app, all[p.id]) }
        guard let s = all.first(where: { $0.name == p.name && $0.kind == p.kind }) else { return nil }
        return (logic, app, s)
    }

    // MARK: On / off, open, remove (BL-35, BL-38, BL-44)

    @discardableResult
    func toggle(_ p: StripPlugin) -> Bool {
        guard let (_, _, s) = locate(p), let box = s.child("bypass") else { return false }
        inserter.log("TRACK toggle \(p.name)")
        return box.perform(kAXPressAction)
    }

    @discardableResult
    func open(_ p: StripPlugin) -> Bool {
        guard let (logic, _, s) = locate(p), let b = s.child("open") else { return false }
        logic.activate()
        return b.perform(kAXPressAction)
    }

    /// Takes a plugin out of its slot: its list menu → "No Plug-in".
    func remove(_ p: StripPlugin) async -> Bool {
        guard let (logic, app, s) = locate(p) else { return false }
        return await removeSlot(s, logic: logic, app: app)
    }

    private func removeSlot(_ s: Slot, logic: NSRunningApplication, app: AXNode) async -> Bool {
        guard let list = s.child("list") else { return false }
        logic.activate()
        for _ in 1...2 {
            list.perform(kAXPressAction)
            if let menu = await inserter.waitForMenu(app: app, timeout: 2.5),
               let none = menu.first(maxNodes: 200, where: { $0.title == "No Plug-in" }) {
                none.perform(kAXPressAction)
                inserter.log("TRACK removed \(s.name)")
                try? await Task.sleep(for: .milliseconds(350))
                return true
            }
            try? await Task.sleep(for: .milliseconds(400))
        }
        inserter.log("TRACK could not remove \(s.name)")
        return false
    }

    /// The plugin AG PlugFinder added last, if it is on this track, else the lowest effect.
    func removeLastAdded() async -> String? {
        guard let (logic, app) = logic(), let strip = leftStrip(app) else { return nil }
        let all = slots(in: strip)
        let last = lastAdded ?? ""
        guard let s = all.last(where: { Self.sameName($0.name, last) })
                ?? all.last(where: { $0.kind == .audioFX }) ?? all.last(where: { $0.kind == .midiFX })
        else { return nil }
        return await removeSlot(s, logic: logic, app: app) ? s.name : nil
    }

    /// Removes every audio effect from the selected track, bottom first. Returns how many.
    func clearEffects() async -> Int {
        var removed = 0
        for _ in 0..<20 {
            guard let (logic, app) = logic(), let strip = leftStrip(app),
                  let s = slots(in: strip).last(where: { $0.kind == .audioFX }),
                  await removeSlot(s, logic: logic, app: app) else { break }
            removed += 1
        }
        return removed
    }

    /// Opens every plugin on the track and lays the windows out side by side.
    func openAll() async -> Int {
        guard let (logic, app) = logic(), let strip = leftStrip(app) else { return 0 }
        logic.activate()
        await LogicCapture.closePluginWindows(app, pid: logic.processIdentifier)
        let all = slots(in: strip)
        for s in all {
            s.child("open")?.perform(kAXPressAction)
            try? await Task.sleep(for: .milliseconds(350))
        }
        try? await Task.sleep(for: .milliseconds(600))
        tilePluginWindows(app)
        return all.count
    }

    func closeAll() async {
        guard let (logic, app) = logic() else { return }
        await LogicCapture.closePluginWindows(app, pid: logic.processIdentifier)
    }

    /// Lays the plug-in windows out left to right across the screen Logic is on. When they
    /// don't all fit, they overlap evenly so every window still shows.
    func tilePluginWindows(_ app: AXNode) {
        let windows = app.children.filter { $0.role == kAXWindowRole as String && !$0.title.contains(" - ") }
        guard !windows.isEmpty, let primary = NSScreen.screens.first else { return }
        let screen = NSScreen.main ?? primary
        // AX uses top-left coordinates measured from the primary screen.
        let vf = screen.visibleFrame
        let area = CGRect(x: vf.minX, y: primary.frame.maxY - vf.maxY, width: vf.width, height: vf.height)
        let widths = windows.map(\.frame.width)
        let total = widths.reduce(0, +)
        let step: [CGFloat]
        if total <= area.width || windows.count == 1 {
            step = widths
        } else {
            let even = max(40, (area.width - (widths.last ?? 0)) / CGFloat(windows.count - 1))
            step = widths.map { min($0, even) }
        }
        // Logic puts its plug-in windows back when they are moved from outside, so each one is
        // dragged by its title bar, the way a person would. The pointer goes back afterwards.
        let saved = Mouse.location
        var x = area.minX
        for (i, w) in windows.enumerated() {
            let f = w.frame
            AXUIElementPerformAction(w.el, kAXRaiseAction as CFString)
            usleep(80_000)
            let grab = CGPoint(x: f.minX + min(f.width / 2, 160), y: f.minY + 12)
            Mouse.drag(from: grab, to: CGPoint(x: grab.x + (x - f.minX), y: grab.y + (area.minY - f.minY)))
            inserter.log("TRACK window \(i) to \(Int(x)) now \(Int(w.frame.minX))")
            x += step[i]
        }
        Mouse.restore(saved)
    }

    // MARK: Replace (BL-36)

    /// Chooses `plugin` from the slot's own menu, which puts it in that same slot.
    func replace(_ p: StripPlugin, with plugin: Plugin) async -> String? {
        guard plugin.slotKind == p.kind else {
            return "\(plugin.name) can't take the place of \(p.name): " +
                (plugin.slotKind == .instrument ? "it is an instrument." : p.kind == .instrument ? "that slot holds the instrument." : "they go in different slots.")
        }
        guard let (logic, app, s) = locate(p), let list = s.child("list") else {
            return "\(p.name) is no longer on the selected track."
        }
        logic.activate()
        try? await Task.sleep(for: .milliseconds(150))
        inserter.log("TRACK replace \(p.name) with \(plugin.name)")
        guard let menu = await inserter.openMenu(on: list, app: app, legacy: plugin.isLegacy == true) else {
            return "Logic's plug-in menu did not open."
        }
        if await choose(plugin, menu: menu, app: app, pid: logic.processIdentifier) {
            lastAdded = plugin.name
            return nil
        }
        return "I couldn't find \(plugin.name) in Logic's plug-in menu."
    }

    private func choose(_ plugin: Plugin, menu: AXNode, app: AXNode, pid: pid_t) async -> Bool {
        if plugin.isLegacy == true { return await inserter.chooseLegacy(plugin, menu: menu, app: app) }
        if await inserter.chooseBySearch(plugin, menu: menu, app: app, pid: pid) { return true }
        return await inserter.chooseByBrowsing(plugin, menu: menu, app: app)
    }

    // MARK: Insert before or after (BL-39)

    /// Logic puts a thin "insert bar" above every audio effect slot; choosing a plug-in from its
    /// menu inserts it right there. After the last effect, the empty slot does the same.
    func insert(_ plugin: Plugin, before: Bool, _ target: StripPlugin) async -> String? {
        guard plugin.slotKind == .audioFX, target.kind == .audioFX else {
            return "Before and after work for audio effects."
        }
        guard let (logic, app) = logic(), let strip = leftStrip(app) else {
            return "Select a track in Logic with the Inspector showing."
        }
        let audio = slots(in: strip).filter { $0.kind == .audioFX }
        guard let t = audio.firstIndex(where: { $0.name == target.name }) else {
            return "\(target.name) is no longer on the selected track."
        }
        let kids = strip.children
        let bars = kids.filter { $0.desc == "insert bar" }
        let spot: AXNode?
        if before || t + 1 < audio.count {
            let slot = audio[before ? t : t + 1].frame
            spot = bars.min { abs($0.frame.maxY - slot.minY) < abs($1.frame.maxY - slot.minY) }
                .flatMap { abs($0.frame.maxY - slot.minY) < 4 ? $0 : nil }
        } else {
            spot = kids.first { $0.role == "AXButton" && $0.help.hasPrefix("Audio Effect slot") }
        }
        guard let spot else { return "I couldn't find the place \(before ? "before" : "after") \(target.name)." }
        logic.activate()
        try? await Task.sleep(for: .milliseconds(150))
        inserter.log("TRACK insert \(plugin.name) \(before ? "before" : "after") \(target.name)")
        guard let menu = await inserter.openMenu(on: spot, app: app, legacy: plugin.isLegacy == true) else {
            return "Logic's plug-in menu did not open."
        }
        guard await choose(plugin, menu: menu, app: app, pid: logic.processIdentifier) else {
            return "I couldn't find \(plugin.name) in Logic's plug-in menu."
        }
        lastAdded = plugin.name
        return nil
    }

    func message(_ outcome: InsertOutcome, _ plugin: Plugin) -> String {
        switch outcome {
        case .inserted: return ""
        case .allFull: return plugin.slotKind == .instrument ? "The track already has an instrument." : "Every insert is full."
        case .needsAccessibility: return "AG PlugFinder needs Accessibility access to place plugins in Logic."
        case .logicNotRunning: return "Logic Pro isn't open."
        case .noChannelStrip(let t), .failed(let t): return t
        }
    }

    // MARK: Menu bar

    /// Presses a menu bar command, for example ["Track", "New Software Instrument Track"].
    @discardableResult
    func pressMenu(_ app: AXNode, _ path: [String]) -> Bool {
        guard let bar: AXUIElement = app.attr(kAXMenuBarAttribute),
              var node = AXNode(el: bar).children.first(where: { $0.title == path[0] }) else { return false }
        for title in path.dropFirst() {
            guard let menu = node.children.first(where: { $0.role == AXRole.menu }),
                  let item = menu.children.first(where: { $0.title.hasPrefix(title) }) else { return false }
            node = item
        }
        guard node.isEnabled else { return false }
        return node.perform(kAXPressAction)
    }

    // MARK: New track with an instrument (BL-43)

    func newInstrumentTrack(_ plugin: Plugin) async -> String? {
        guard plugin.slotKind == .instrument else { return "Only instruments get a new track." }
        guard let (logic, app) = logic() else { return "Logic Pro isn't open." }
        logic.activate()
        try? await Task.sleep(for: .milliseconds(200))
        guard pressMenu(app, ["Track", "New Software Instrument Track"]) else {
            return "Logic's New Software Instrument Track command isn't available. Open a project first."
        }
        inserter.log("TRACK new instrument track for \(plugin.name)")
        try? await Task.sleep(for: .milliseconds(1400))
        // The new track is selected; whatever Logic loaded by default is replaced.
        let outcome = await inserter.insert(plugin, replacing: 0)
        if case .inserted = outcome { lastAdded = plugin.name; return nil }
        return message(outcome, plugin)
    }

    // MARK: The Mixer (BL-40, BL-41, BL-42)

    private func mixerWindow(_ app: AXNode) -> AXNode? {
        app.children.first { $0.role == kAXWindowRole as String && $0.title.contains(" - Mixer") }
    }

    /// The Mixer window, opened from Window > Open Mixer when it isn't open yet.
    private func openMixer(_ app: AXNode, logic: NSRunningApplication) async -> (AXNode, opened: Bool)? {
        if let w = mixerWindow(app) {
            mixerFrame = w.frame
            fillScreen(w)
            try? await Task.sleep(for: .milliseconds(400))
            return (w, false)
        }
        logic.activate()
        guard pressMenu(app, ["Window", "Open Mixer"]) else { return nil }
        for _ in 0..<30 {
            try? await Task.sleep(for: .milliseconds(100))
            if let w = mixerWindow(app) {
                try? await Task.sleep(for: .milliseconds(300))
                mixerFrame = w.frame
                fillScreen(w)
                try? await Task.sleep(for: .milliseconds(400))
                return (w, true)
            }
        }
        return nil
    }

    /// Logic names only the slots it draws; slots under the Mixer's header read as "input" or
    /// "audio plug-in". The Mixer this opened is made as tall as the screen so all of them show.
    private func fillScreen(_ w: AXNode) {
        guard let primary = NSScreen.screens.first else { return }
        let vf = (NSScreen.main ?? primary).visibleFrame
        var origin = CGPoint(x: w.frame.minX, y: primary.frame.maxY - vf.maxY)
        var size = CGSize(width: w.frame.width, height: vf.height)
        if let v = AXValueCreate(.cgPoint, &origin) { AXUIElementSetAttributeValue(w.el, kAXPositionAttribute as CFString, v) }
        if let v = AXValueCreate(.cgSize, &size) { AXUIElementSetAttributeValue(w.el, kAXSizeAttribute as CFString, v) }
        inserter.log("TRACK mixer frame \(w.frame)")
    }

    private var mixerFrame: CGRect?

    /// Puts the Mixer back to its own size, and closes it when this opened it.
    private func doneWithMixer(_ w: AXNode, opened: Bool) {
        if let f = mixerFrame {
            var origin = f.origin, size = f.size
            if let v = AXValueCreate(.cgSize, &size) { AXUIElementSetAttributeValue(w.el, kAXSizeAttribute as CFString, v) }
            if let v = AXValueCreate(.cgPoint, &origin) { AXUIElementSetAttributeValue(w.el, kAXPositionAttribute as CFString, v) }
            mixerFrame = nil
        }
        if opened { closeWindow(w) }
    }

    /// Logic shortens long names on a strip ("Space D" for Space Designer, "RetroSyn" for Retro
    /// Synth), so a slot matches a plugin when one name starts the other, ignoring spaces.
    nonisolated static func sameName(_ slot: String, _ plugin: String) -> Bool {
        func norm(_ s: String) -> String { s.lowercased().filter { $0.isLetter || $0.isNumber } }
        let a = norm(slot), b = norm(plugin)
        guard !a.isEmpty, !b.isEmpty else { return false }
        if a == b { return true }
        return min(a.count, b.count) >= 4 && (b.hasPrefix(a) || a.hasPrefix(b))
    }

    /// Names Logic uses for a slot it hasn't drawn.
    static let placeholderNames: Set<String> = ["input", "audio plug-in", "MIDI plug-in", "plug-in"]

    /// Opens the Mixer window (used by the live checks).
    func showMixer() async { if let (logic, app) = logic() { _ = await openMixer(app, logic: logic) } }

    /// Closes the Mixer window (used by the live checks).
    func closeMixer() {
        if let (_, app) = logic(), let w = mixerWindow(app) { closeWindow(w) }
    }

    private func closeWindow(_ w: AXNode) {
        if let el: AXUIElement = w.attr(kAXCloseButtonAttribute) { AXNode(el: el).perform(kAXPressAction) }
    }

    private func mixerStrips(_ mixer: AXNode) -> [AXNode] {
        mixer.findAll(maxNodes: 30_000) { n in
            n.role == "AXLayoutItem" && !n.help.hasPrefix("Left inspector") && !n.help.hasPrefix("Right inspector")
                && n.children.contains { $0.desc == "name" && $0.role == AXRole.textField }
        }.sorted { $0.frame.minX < $1.frame.minX }
    }

    private func stripName(_ strip: AXNode) -> String {
        strip.children.first { $0.desc == "name" && $0.role == AXRole.textField }?.stringValue.ifEmpty(strip.desc) ?? strip.desc
    }

    /// Every channel strip in the project with its plugins. Read only: a Mixer window this
    /// opened is closed again.
    func scanProject() async -> [ProjectTrack]? {
        guard let (logic, app) = logic(), let (mixer, opened) = await openMixer(app, logic: logic) else { return nil }
        let tracks = mixerStrips(mixer).enumerated().map { i, s in
            ProjectTrack(index: i, name: stripName(s), plugins: slots(in: s).map(\.name))
        }
        doneWithMixer(mixer, opened: opened)
        inserter.log("TRACK scan: \(tracks.map { "\($0.name)[\($0.plugins.joined(separator: ","))]" }.joined(separator: " "))")
        return tracks
    }

    /// Selects a track by clicking its name in the Mixer, as a person would.
    private func select(_ track: ProjectTrack, in mixer: AXNode) async -> Bool {
        let strips = mixerStrips(mixer)
        let strip = strips.indices.contains(track.index) && stripName(strips[track.index]) == track.name
            ? strips[track.index] : strips.first { stripName($0) == track.name }
        guard let field = strip?.children.first(where: { $0.desc == "name" })?.frame, field.width > 0 else { return false }
        Mouse.click(at: CGPoint(x: field.midX, y: field.midY))
        try? await Task.sleep(for: .milliseconds(450))
        return true
    }

    /// Selects the track in Logic (BL-40).
    func goTo(_ track: ProjectTrack) async -> Bool {
        guard let (logic, app) = logic(), let (mixer, opened) = await openMixer(app, logic: logic) else { return false }
        let ok = await select(track, in: mixer)
        doneWithMixer(mixer, opened: opened)
        return ok
    }

    /// Adds the plugins to each track in turn (BL-41). Returns a summary.
    func add(_ plugins: [Plugin], to tracks: [ProjectTrack]) async -> String {
        guard let (logic, app) = logic() else { return "Logic Pro isn't open." }
        guard let (mixer, opened) = await openMixer(app, logic: logic) else { return "Logic's Mixer did not open." }
        var done = 0
        var problems: [String] = []
        for t in tracks {
            guard await select(t, in: mixer) else { problems.append("\(t.name): not found"); continue }
            var ok = true
            for p in plugins {
                let outcome = await inserter.insert(p, replacing: nil)
                if case .inserted = outcome {
                    lastAdded = p.name
                    PluginStore.shared.markUsed(p.id)
                    try? await Task.sleep(for: .milliseconds(450))
                } else {
                    ok = false
                    problems.append("\(t.name): \(message(outcome, p))")
                    break
                }
            }
            if ok { done += 1 }
            await LogicCapture.closePluginWindows(app, pid: logic.processIdentifier)
        }
        doneWithMixer(mixer, opened: opened)
        if problems.isEmpty { return "Added to \(done) track\(done == 1 ? "" : "s")." }
        return "Added to \(done) of \(tracks.count). " + problems.prefix(2).joined(separator: " ")
    }

    // MARK: Send (BL-42)

    /// Sends the selected track to a free bus; Logic makes an aux for it, and the effect goes
    /// on that aux.
    func addAsSend(_ plugin: Plugin) async -> String? {
        guard plugin.slotKind == .audioFX else { return "Only audio effects go on a send." }
        guard let (logic, app) = logic(), let strip = leftStrip(app) else {
            return "Select a track in Logic and show the Inspector, then try again."
        }
        guard let send = strip.children.first(where: { $0.role == "AXButton" && $0.help.hasPrefix("Send slot") }) else {
            return "This track has no free send slot."
        }
        guard let (mixer, opened) = await openMixer(app, logic: logic) else { return "Logic's Mixer did not open." }
        let before = Set(mixerStrips(mixer).map(stripName))
        defer { doneWithMixer(mixer, opened: opened) }

        logic.activate()
        guard let menu = await inserter.openMenu(on: send, app: app) else { return "Logic's send menu did not open." }
        inserter.log("TRACK send menu: " + inserter.menuItems(menu).map(\.title).joined(separator: " | "))
        guard let bus = await freeBus(in: menu) else { return "I couldn't find a free bus in Logic's send menu." }
        inserter.log("TRACK send to \(bus.title)")
        let busName = bus.title
        bus.perform(kAXPressAction)
        try? await Task.sleep(for: .milliseconds(400))
        raiseSend(busName, app: app)

        var aux: AXNode?
        for _ in 0..<20 {
            try? await Task.sleep(for: .milliseconds(150))
            aux = mixerStrips(mixer).first { !before.contains(stripName($0)) }
            if aux != nil { break }
        }
        guard let aux else { return "Logic made the send, but I couldn't find its aux in the Mixer." }
        guard let slot = aux.children.first(where: { $0.role == "AXButton" && $0.help.hasPrefix("Audio Effect slot") }),
              let fx = await inserter.openMenu(on: slot, app: app, legacy: plugin.isLegacy == true) else {
            return "The send is on \(stripName(aux)), but its plug-in menu did not open."
        }
        guard await choose(plugin, menu: fx, app: app, pid: logic.processIdentifier) else {
            return "The send is on \(stripName(aux)), but I couldn't find \(plugin.name) in the menu."
        }
        inserter.log("TRACK \(plugin.name) on \(stripName(aux))")
        PluginStore.shared.markUsed(plugin.id)
        return nil
    }

    /// A new send starts silent; raise it step by step to about -5 dB, read back from Logic.
    private func raiseSend(_ bus: String, app: AXNode) {
        guard let strip = leftStrip(app),
              let send = strip.children.first(where: { $0.role == "AXGroup" && $0.desc == bus }) else { return }
        let y = send.frame.minY
        guard let knob = strip.children.first(where: { $0.desc == "send knob" && abs($0.frame.minY - y) < 4 }) else { return }
        for _ in 0..<40 {
            let d: String = knob.attr("AXValueDescription") ?? ""
            if let db = Double(d), db >= -6 { break }
            knob.perform(kAXIncrementAction)
            usleep(40_000)
        }
        inserter.log("TRACK send level \(knob.attr("AXValueDescription") as String? ?? "?") dB")
    }

    /// The first unused bus: a plain "Bus n" item, on the top level or in the Bus submenu.
    private func freeBus(in menu: AXNode) async -> AXNode? {
        func plain(_ n: AXNode) -> Bool {
            n.isEnabled && n.title.range(of: #"^Bus \d+$"#, options: .regularExpression) != nil
        }
        if let item = inserter.menuItems(menu).first(where: plain) { return item }
        for title in ["Bus", "Buses"] {
            guard let group = inserter.menuItems(menu).first(where: { $0.title == title }),
                  let sub = await inserter.submenu(of: group) else { continue }
            inserter.log("TRACK bus menu: " + inserter.menuItems(sub).prefix(12).map(\.title).joined(separator: " | "))
            if let item = inserter.menuItems(sub).first(where: plain) { return item }
            for range in inserter.menuItems(sub) where range.title.hasPrefix("Bus ") && range.title.contains("–") {
                if let deeper = await inserter.submenu(of: range), let item = inserter.menuItems(deeper).first(where: plain) {
                    return item
                }
            }
        }
        return nil
    }
}

/// A pointer click for the few things Logic offers no other way to do. The pointer is
/// put back where it was.
enum Mouse {
    private static func post(_ type: CGEventType, _ p: CGPoint, flags: CGEventFlags = []) {
        let e = CGEvent(mouseEventSource: CGEventSource(stateID: .hidSystemState), mouseType: type,
                        mouseCursorPosition: p, mouseButton: .left)
        if !flags.isEmpty { e?.flags = flags }
        e?.post(tap: .cghidEventTap)
    }

    static func click(at p: CGPoint) {
        let saved = CGEvent(source: nil)?.location
        post(.mouseMoved, p); usleep(40_000)
        post(.leftMouseDown, p); usleep(50_000)
        post(.leftMouseUp, p); usleep(60_000)
        if let saved { CGWarpMouseCursorPosition(saved) }
    }

    static func drag(from a: CGPoint, to b: CGPoint, steps: Int = 8) {
        post(.mouseMoved, a); usleep(30_000)
        post(.leftMouseDown, a); usleep(60_000)
        for i in 1...steps {
            let t = CGFloat(i) / CGFloat(steps)
            post(.leftMouseDragged, CGPoint(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t))
            usleep(16_000)
        }
        usleep(40_000)
        post(.leftMouseUp, b); usleep(50_000)
    }

    static var location: CGPoint? { CGEvent(source: nil)?.location }
    static func restore(_ p: CGPoint?) { if let p { CGWarpMouseCursorPosition(p) } }
}
