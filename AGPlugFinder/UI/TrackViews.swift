import AppKit
import SwiftUI

// MARK: - The selected track's plugins (BL-35)

/// What is on the selected Logic track right now. Read when the panel or window comes up and
/// after every change the app makes.
@MainActor
@Observable
final class TrackState {
    static let shared = TrackState()
    var track: String?
    var plugins: [StripPlugin] = []
    var loaded = false
    var busy = false

    func refresh() {
        let r = LogicTrack.shared.read()
        track = r?.track
        plugins = r?.plugins ?? []
        loaded = true
    }

    func refreshSoon() {
        Task { try? await Task.sleep(for: .milliseconds(700)); refresh() }
    }

    /// Runs a change in Logic, then reads the track again.
    func run(_ work: @escaping () async -> Void) {
        guard !busy else { return }
        busy = true
        Task {
            await work()
            try? await Task.sleep(for: .milliseconds(400))
            refresh()
            busy = false
        }
    }

    var effects: [StripPlugin] { plugins.filter { $0.kind == .audioFX } }

    /// Matches the track's plugin names to the library, effects only.
    func asChain() -> (ids: [String], missing: [String]) {
        let store = PluginStore.shared
        var ids: [String] = [], missing: [String] = []
        for p in plugins where p.kind != .instrument {
            let exact = store.plugins.filter { $0.name.caseInsensitiveCompare(p.name) == .orderedSame }
            let same = exact.isEmpty ? store.plugins.filter { LogicTrack.sameName(p.name, $0.name) } : exact
            if let m = same.first(where: { $0.slotKind == p.kind && $0.isLogic })
                ?? same.first(where: { $0.slotKind == p.kind }) ?? same.first { ids.append(m.id) }
            else { missing.append(p.name) }
        }
        return (ids, missing)
    }
}

struct TrackPanel: View {
    @Bindable var model: PickerModel
    var close: () -> Void
    var state = TrackState.shared
    /// Drag to reorder (BL-56): the effect being dragged and where the line shows.
    @State fileprivate var dragging: StripPlugin?
    @State fileprivate var dropTarget: Int?
    @State fileprivate var dropAbove = true

    /// Moves the dragged effect in Logic to the place it was dropped.
    fileprivate func drop(on target: StripPlugin) {
        defer { dragging = nil; dropTarget = nil }
        guard let moving = dragging, moving.kind == .audioFX, target.kind == .audioFX, moving != target else { return }
        let effects = state.effects
        guard let from = effects.firstIndex(of: moving), let t = effects.firstIndex(of: target) else { return }
        var dest = dropAbove ? t : t + 1
        if dest > from { dest -= 1 }
        guard dest != from else { return }
        state.run {
            if !(await LogicTrack.shared.move(moving, toEffect: dest)) {
                Toast.show("Logic didn't move \(moving.name). Drag it in Logic's channel strip instead.", warning: true)
            }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("This track").font(.system(size: 12)).foregroundStyle(Theme.faint)
                    Text(state.track ?? "No track").font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(Theme.text).lineLimit(1)
                }
                Spacer()
                if state.busy { ProgressView().controlSize(.small) }
                BarIconButton(systemImage: "arrow.clockwise", help: "Read the track again") { state.refresh() }
            }
            if state.track == nil {
                Text(LogicInserter.shared.logicApp == nil
                     ? "Logic Pro isn't open."
                     : "Select a track in Logic with the Inspector showing, then refresh.")
                    .font(.system(size: 12)).foregroundStyle(Theme.muted)
                    .fixedSize(horizontal: false, vertical: true)
            } else if state.plugins.isEmpty {
                Text("No plugins on this track yet.").font(.system(size: 12)).foregroundStyle(Theme.muted)
            } else {
                VStack(spacing: 4) {
                    ForEach(state.plugins) { p in
                        row(p)
                            .overlay(alignment: dropAbove ? .top : .bottom) {
                                if dropTarget == p.id {
                                    Capsule().fill(Theme.accent).frame(height: 3).offset(y: dropAbove ? -3 : 3)
                                }
                            }
                            .onDrag {
                                dragging = p
                                return NSItemProvider(object: p.name as NSString)
                            }
                            .onDrop(of: [.text], delegate: EffectDrop(target: p, panel: self))
                    }
                }
            }
            Rectangle().fill(Theme.rule).frame(height: 1)
            VStack(alignment: .leading, spacing: 2) {
                ActionRow(icon: "link.badge.plus", title: "Save as chain",
                          detail: "Add these plugins to any track later", disabled: state.plugins.isEmpty) { saveChain() }
                ActionRow(icon: "arrow.uturn.backward", title: "Remove last added",
                          detail: LogicTrack.shared.lastAdded.map { "Takes out \($0)" } ?? "Takes out the lowest effect",
                          disabled: state.plugins.isEmpty || state.busy) {
                    state.run { _ = await LogicTrack.shared.removeLastAdded() }
                }
                ActionRow(icon: "trash", title: "Clear effects",
                          detail: "Removes every effect from this track in one step",
                          disabled: state.effects.isEmpty || state.busy) { clearEffects() }
                ActionRow(icon: "power", title: "Remove the ones turned off",
                          detail: "Takes out every effect that is switched off",
                          disabled: !state.plugins.contains { $0.isOn == false } || state.busy) {
                    state.run { _ = await LogicTrack.shared.stripCommand("Remove Bypassed Plug-ins") }
                }
                ActionRow(icon: "arrow.turn.down.right", title: "Remove all sends",
                          detail: "Takes every send off this track", disabled: state.busy) {
                    state.run { _ = await LogicTrack.shared.stripCommand("Remove All Sends") }
                }
                ActionRow(icon: "rectangle.split.3x1", title: "Open all side by side",
                          detail: HotKey.openAllDisplay, disabled: state.plugins.isEmpty || state.busy) {
                    state.run { _ = await LogicTrack.shared.openAll() }
                }
                ActionRow(icon: "xmark.rectangle", title: "Close plugin windows", detail: HotKey.closeAllDisplay) {
                    state.run { await LogicTrack.shared.closeAll() }
                }
            }
        }
        .padding(16).frame(width: 380).background(Theme.surface).preferredColorScheme(.dark)
        .onAppear { state.refresh() }
    }

    private func icon(_ kind: SlotKind) -> String {
        switch kind {
        case .instrument: return "pianokeys"
        case .midiFX: return "music.note"
        case .audioFX: return "waveform"
        }
    }

    private func row(_ p: StripPlugin) -> some View {
        HStack(spacing: 10) {
            Image(systemName: p.kind == .audioFX ? "line.3.horizontal" : icon(p.kind))
                .font(.system(size: 11)).foregroundStyle(Theme.faint).frame(width: 16)
                .help(p.kind == .audioFX ? "Drag to change the order in Logic" : "")
            Text(p.name).font(.system(size: 13, weight: .medium))
                .foregroundStyle(p.isOn == false ? Theme.faint : Theme.text).lineLimit(1)
                .strikethrough(p.isOn == false, color: Theme.faint)
            Spacer(minLength: 6)
            if let on = p.isOn {
                OnOffSwitch(on: on) { state.run { LogicTrack.shared.toggle(p) } }
                    .help(on ? "Turn \(p.name) off (bypass)" : "Turn \(p.name) on")
            }
            small("macwindow", "Open \(p.name)") { LogicTrack.shared.open(p) }
            small("arrow.left.arrow.right", "Replace \(p.name): pick the new plugin in the library") {
                model.replaceTarget = p
                close()
            }
            small("xmark", "Remove \(p.name) from the track") { state.run { _ = await LogicTrack.shared.remove(p) } }
        }
        .padding(.horizontal, 10).frame(height: 36)
        .background(RoundedRectangle(cornerRadius: 10).fill(Theme.raised.opacity(0.6)))
        .disabled(state.busy)
    }

    private func small(_ icon: String, _ help: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon).font(.system(size: 10, weight: .semibold)).foregroundStyle(Theme.muted)
                .frame(width: 24, height: 24).background(Circle().fill(Theme.surface))
        }
        .buttonStyle(.plain).help(help)
    }

    private func saveChain() {
        let (ids, missing) = state.asChain()
        guard !ids.isEmpty else {
            Toast.show("None of these plugins are in your library.", warning: true); return
        }
        close()
        guard let name = NamePrompt.ask("Save track as chain", placeholder: "Name",
                                        initial: "\(state.track ?? "Track") chain") else { return }
        UserLibrary.shared.newChain(named: name, with: ids)
        Toast.show(missing.isEmpty ? "Saved \(name): \(ids.count) plugins"
                                   : "Saved \(name). Not in your library: \(missing.joined(separator: ", "))",
                   warning: !missing.isEmpty)
    }

    private func clearEffects() {
        let alert = NSAlert()
        alert.messageText = "Remove every effect from \(state.track ?? "this track")?"
        alert.informativeText = "\(state.effects.count) effects come off the track. You can undo it in Logic with Edit > Undo."
        alert.addButton(withTitle: "Remove")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        state.run {
            let n = await LogicTrack.shared.clearEffects()
            Toast.show("Removed \(n) effect\(n == 1 ? "" : "s")")
        }
    }
}

/// Where a dragged effect lands: above or below the row under the pointer.
private struct EffectDrop: DropDelegate {
    let target: StripPlugin
    let panel: TrackPanel

    func validateDrop(info: DropInfo) -> Bool {
        target.kind == .audioFX && panel.dragging?.kind == .audioFX
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        panel.dropAbove = info.location.y < 18
        panel.dropTarget = target.id
        return DropProposal(operation: .move)
    }

    func dropExited(info: DropInfo) {
        if panel.dropTarget == target.id { panel.dropTarget = nil }
    }

    func performDrop(info: DropInfo) -> Bool {
        panel.drop(on: target)
        return true
    }
}

struct OnOffSwitch: View {
    let on: Bool
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            ZStack(alignment: on ? .trailing : .leading) {
                Capsule().fill(on ? Theme.accent : Theme.surface).frame(width: 30, height: 18)
                Circle().fill(on ? Color.black : Theme.faint).frame(width: 14, height: 14).padding(2)
            }
            .animation(.easeOut(duration: 0.15), value: on)
        }
        .buttonStyle(.plain)
    }
}

/// "Choose a plugin to replace X" above the grid while a replace is waiting (BL-36).
struct ReplaceBanner: View {
    @Bindable var model: PickerModel
    var body: some View {
        if let t = model.replaceTarget {
            HStack(spacing: 10) {
                Image(systemName: "arrow.left.arrow.right").foregroundStyle(Theme.accent)
                Text("Choose a plugin to take the place of \(t.name), then press Return")
                    .font(.system(size: 12, weight: .medium)).foregroundStyle(Theme.text)
                Spacer()
                QuietPill(title: "Cancel", height: 26) { model.replaceTarget = nil }
            }
            .padding(.horizontal, 18).frame(height: 40)
            .background(Theme.warningGround)
        }
    }
}

// MARK: - Project tracks: find where a plugin is used (BL-40), add to several (BL-41)

@MainActor
final class TracksWindow {
    static let shared = TracksWindow()
    enum Mode { case find(Plugin), add([Plugin], String) }

    private var window: NSWindow?

    func show(_ mode: Mode) {
        let w = window ?? {
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 440, height: 520),
                             styleMask: [.titled, .closable, .resizable, .fullSizeContentView],
                             backing: .buffered, defer: false)
            w.titlebarAppearsTransparent = true
            w.titleVisibility = .hidden
            w.isMovableByWindowBackground = true
            w.isReleasedWhenClosed = false
            w.backgroundColor = .black
            w.appearance = NSAppearance(named: .darkAqua)
            w.level = .floating
            w.center()
            window = w
            return w
        }()
        w.contentView = NSHostingView(rootView: TracksView(mode: mode))
        w.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }
}

struct TracksView: View {
    let mode: TracksWindow.Mode
    @State private var tracks: [ProjectTrack]?
    @State private var chosen: Set<String> = []
    @State private var busy = false
    @State private var status: String?

    private var plugins: [Plugin] {
        switch mode { case .find(let p): return [p]; case .add(let list, _): return list }
    }
    private var finding: Bool { if case .find = mode { return true }; return false }
    private var title: String {
        switch mode {
        case .find(let p): return "Where is \(p.name)?"
        case .add(_, let name): return "Add \(name) to tracks"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(title).font(.system(size: 20, weight: .bold)).foregroundStyle(Theme.text)
            if let tracks {
                let shown = finding ? tracks.filter(uses) : tracks
                Text(subtitle(shown.count, of: tracks.count))
                    .font(.system(size: 12)).foregroundStyle(Theme.muted)
                ScrollView {
                    VStack(spacing: 4) { ForEach(shown) { t in row(t) } }
                }
                .frame(maxHeight: .infinity)
            } else {
                HStack(spacing: 10) {
                    ProgressView().controlSize(.small)
                    Text("Reading the project's tracks…").font(.system(size: 13)).foregroundStyle(Theme.muted)
                }
                Spacer()
            }
            if let status { Text(status).font(.system(size: 12)).foregroundStyle(Theme.warning) }
            HStack {
                QuietPill(title: "Read Again", systemImage: "arrow.clockwise") { Task { await load() } }
                    .disabled(busy)
                Spacer()
                if !finding {
                    PrimaryPill(title: chosen.isEmpty ? "Add" : "Add to \(chosen.count) track\(chosen.count == 1 ? "" : "s")",
                                busy: busy, height: 32) { add() }
                        .disabled(chosen.isEmpty || busy)
                }
            }
        }
        .padding(.horizontal, 24).padding(.top, 38).padding(.bottom, 20)
        .frame(minWidth: 400, minHeight: 420)
        .background(Theme.ground)
        .preferredColorScheme(.dark)
        .task { await load() }
    }

    private func uses(_ t: ProjectTrack) -> Bool {
        t.plugins.contains { name in plugins.contains { LogicTrack.sameName(name, $0.name) } }
    }

    private func subtitle(_ n: Int, of total: Int) -> String {
        if finding { return n == 0 ? "Not on any of the \(total) tracks in this project." : "On \(n) of \(total) tracks. Go selects the track in Logic." }
        return "Tick the tracks, then Add. Each one is selected in Logic in turn."
    }

    private func row(_ t: ProjectTrack) -> some View {
        HStack(spacing: 10) {
            if !finding {
                CheckMark(on: chosen.contains(t.id))
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(t.name).font(.system(size: 13, weight: .medium)).foregroundStyle(Theme.text)
                Text(t.plugins.joined(separator: " → ").ifEmpty("No plugins"))
                    .font(.system(size: 11)).foregroundStyle(Theme.faint).lineLimit(1)
            }
            Spacer()
            if finding {
                QuietPill(title: "Go", height: 26) {
                    Task { busy = true; if !(await LogicTrack.shared.goTo(t)) { status = "Couldn't select \(t.name)." }; busy = false }
                }
                .disabled(busy)
            }
        }
        .padding(.horizontal, 12).frame(height: 46)
        .background(RoundedRectangle(cornerRadius: 10).fill(Theme.surface))
        .contentShape(Rectangle())
        .onTapGesture {
            guard !finding else { return }
            if chosen.contains(t.id) { chosen.remove(t.id) } else { chosen.insert(t.id) }
        }
    }

    private func load() async {
        tracks = nil
        status = nil
        tracks = await LogicTrack.shared.scanProject() ?? []
        if tracks?.isEmpty == true {
            status = LogicInserter.shared.logicApp == nil ? "Logic Pro isn't open." : "I couldn't read Logic's Mixer."
        }
    }

    private func add() {
        guard let tracks else { return }
        let list = tracks.filter { chosen.contains($0.id) }
        busy = true
        status = nil
        Task {
            let result = await LogicTrack.shared.add(plugins, to: list)
            busy = false
            Toast.show(result, warning: !result.hasPrefix("Added to \(list.count) track"))
            await load()
            chosen = []
        }
    }
}

// MARK: - Running the one-step Logic actions with a notice

@MainActor
enum TrackActions {
    static func addAsSend(_ p: Plugin) {
        Toast.show("Adding \(p.name) on a send…", busy: true)
        Task {
            if let problem = await LogicTrack.shared.addAsSend(p) { Toast.show(problem, warning: true) }
            else { Toast.show("\(p.name) is on a new send") }
        }
    }

    static func newTrack(_ p: Plugin) {
        Toast.show("New track with \(p.name)…", busy: true)
        Task {
            if let problem = await LogicTrack.shared.newInstrumentTrack(p) { Toast.show(problem, warning: true) }
            else { PluginStore.shared.markUsed(p.id); Toast.show("New track with \(p.name)") }
        }
    }

    static func insert(_ p: Plugin, before: Bool, _ target: StripPlugin) {
        Toast.show("Adding \(p.name) \(before ? "before" : "after") \(target.name)…", busy: true)
        Task {
            if let problem = await LogicTrack.shared.insert(p, before: before, target) { Toast.show(problem, warning: true) }
            else { PluginStore.shared.markUsed(p.id); Toast.show("Added \(p.name) \(before ? "before" : "after") \(target.name)") }
            TrackState.shared.refreshSoon()
        }
    }

    static func replace(_ target: StripPlugin, with p: Plugin) {
        Toast.show("Replacing \(target.name)…", busy: true)
        Task {
            if let problem = await LogicTrack.shared.replace(target, with: p) { Toast.show(problem, warning: true) }
            else { PluginStore.shared.markUsed(p.id); Toast.show("Replaced \(target.name) with \(p.name)") }
            TrackState.shared.refreshSoon()
        }
    }
}

/// Plugin context menu items that act on Logic's tracks (BL-36, BL-39 to BL-43).
struct TrackMenuItems: View {
    let plugin: Plugin
    var state = TrackState.shared

    var body: some View {
        let same = state.plugins.filter { $0.kind == plugin.slotKind }
        if !same.isEmpty {
            Menu("Replace on Track") {
                ForEach(same) { t in Button(t.name) { TrackActions.replace(t, with: plugin) } }
            }
        }
        if plugin.slotKind == .audioFX, !state.effects.isEmpty {
            Menu("Insert Before") {
                ForEach(state.effects) { t in Button(t.name) { TrackActions.insert(plugin, before: true, t) } }
            }
            Menu("Insert After") {
                ForEach(state.effects) { t in Button(t.name) { TrackActions.insert(plugin, before: false, t) } }
            }
        }
        if plugin.slotKind == .audioFX {
            Button("Add as a Send") { TrackActions.addAsSend(plugin) }
        }
        if plugin.slotKind == .instrument {
            Button("New Track with This Instrument") { TrackActions.newTrack(plugin) }
        }
        Button("Add to Several Tracks…") { TracksWindow.shared.show(.add([plugin], plugin.name)) }
        Button("Find on Tracks…") { TracksWindow.shared.show(.find(plugin)) }
    }
}
