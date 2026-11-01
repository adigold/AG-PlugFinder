import AppKit
import SwiftUI

// MARK: - Asking for a name

@MainActor
enum NamePrompt {
    static func ask(_ title: String, placeholder: String, initial: String = "") -> String? {
        Dialog.ask(title, placeholder: placeholder, initial: initial)
    }
}

// MARK: - Collections bar (BL-29) and track suggestions (BL-33)

/// Chips above the grid: All, then each collection and, when Settings says so, each category
/// (BL-46). Shown once there is something to show.
struct CollectionBar: View {
    @Bindable var model: PickerModel
    var library = UserLibrary.shared
    var view = ViewSettings.shared
    /// The library window shows the picture size slider at the right of this row (BL-48).
    var showSizeSlider = false
    /// The sideview keeps its pills on one row that scrolls sideways (BL-148).
    var scrolls = false

    var body: some View {
        let showCollections = view.chipRow.showsCollections && !library.collections.isEmpty
        let showCategories = view.chipRow.showsCategories
        if showCollections || showCategories || model.suggestion != nil || showSizeSlider || model.soundHint != nil {
            VStack(alignment: .leading, spacing: 0) {
                if showCollections || showCategories || showSizeSlider {
                    HStack(alignment: .top, spacing: 8) {
                        if showCollections || showCategories {
                            PillRow(model: model, showCollections: showCollections, showCategories: showCategories, scrolls: scrolls)
                                .layoutPriority(1)
                        } else {
                            Spacer(minLength: 8)
                        }
                        if showSizeSlider { SizeSlider().padding(.leading, 10).frame(height: 44) }
                    }
                    .padding(.horizontal, scrolls ? 0 : 18).frame(minHeight: 44)
                }
                // On its own row under the chips, so it never squeezes them (Adi, 2026-10-31).
                suggestionNote
                if let hint = model.soundHint {
                    HStack(spacing: 7) {
                        Image(systemName: "waveform").font(.system(size: Theme.ts(10), weight: .semibold)).foregroundStyle(Theme.accent)
                        Text(hint).font(.system(size: Theme.ts(12))).foregroundStyle(Theme.muted).lineLimit(1)
                    }
                    .padding(.horizontal, 20).padding(.top, 2).padding(.bottom, 8)
                }
            }
            .onChange(of: view.chipRow) { _, row in
                if !row.showsCategories { model.pills = [] }
                if !row.showsCollections { model.collectionID = nil }
            }
        }
    }

    @ViewBuilder private var suggestionNote: some View {
        if let s = model.suggestion, model.query.isEmpty, model.collectionID == nil, model.pills.isEmpty {
            HStack(spacing: 7) {
                Circle().fill(Theme.accent).frame(width: 6, height: 6)
                Text("Suggested for “\(s.track)” shown first")
                    .font(.system(size: Theme.ts(12))).foregroundStyle(Theme.muted).lineLimit(1)
            }
            .fixedSize()
            .help("Plugins that fit the selected Logic track come first while the search is empty")
            .padding(.horizontal, 20).padding(.top, 2).padding(.bottom, 8)
        }
    }
}

/// Picture size: small picture, slider, large picture (BL-48).
struct SizeSlider: View {
    var view = ViewSettings.shared
    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "photo").font(.system(size: Theme.ts(10))).foregroundStyle(Theme.faint)
            Slider(value: Binding(get: { view.tileWidth }, set: { view.setTileWidth($0) }), in: ViewSettings.tileRange)
                .controlSize(.small)
                .tint(Theme.accent)
                .frame(width: 130)
            Image(systemName: "photo").font(.system(size: Theme.ts(15))).foregroundStyle(Theme.faint)
        }
        .help("Picture size")
        .disabled(view.layout == .list)
    }
}

/// Keywords in a track's name, and the plugins that fit it (BL-33).
@MainActor
enum TrackSuggestions {
    private static let rules: [(trackWords: [String], pluginWords: [String])] = [
        (["vocal", "vox", "voice", "lead", "bv", "backing", "choir", "sing", "rap", "verse", "chorus vox"],
         ["deesser", "de-esser", "vocal", "pitch", "compressor", "channel eq", "eq", "reverb", "verb", "delay", "tune"]),
        (["drum", "kick", "snare", "hat", "hihat", "perc", "tom", "overhead", "oh", "beat", "808 kick", "clap"],
         ["drum", "transient", "enveloper", "gate", "compressor", "eq", "saturat", "room", "bitcrush", "clip"]),
        (["bass", "808", "sub"],
         ["bass", "sub", "compressor", "saturat", "distortion", "drive", "eq", "amp"]),
        (["guitar", "gtr", "acoustic", "strat", "les paul"],
         ["amp", "pedal", "guitar", "chorus", "delay", "reverb", "overdrive", "fuzz", "wah", "eq"]),
        (["piano", "keys", "rhodes", "organ", "synth", "pad", "lead synth", "pluck", "arp", "strings"],
         ["chorus", "reverb", "eq", "phaser", "tremolo", "delay", "ensemble", "rotary", "filter"]),
        (["master", "mix", "bus", "stereo out", "2bus", "mastering"],
         ["limiter", "multipressor", "multiband", "compressor", "loudness", "meter", "eq", "imager", "stereo"]),
    ]

    static func plugins(for track: String) -> [String] {
        let name = track.lowercased()
        guard let rule = rules.first(where: { $0.trackWords.contains { name.contains($0) } }) else { return [] }
        let store = PluginStore.shared
        let scored: [(Plugin, Int)] = store.plugins.filter { store.isVisible($0) && $0.slotKind == .audioFX }
            .compactMap { (p: Plugin) -> (Plugin, Int)? in
                let parts: [String] = [p.name, p.displayCategory, p.details?.kind ?? "", p.details?.category ?? ""]
                let hay = parts.joined(separator: " ").lowercased()
                if !name.contains("bass"), p.name.lowercased().contains("bass") { return nil }
                let hits = rule.pluginWords.enumerated().filter { hay.contains($0.element) }
                guard let first = hits.first else { return nil }
                // Earlier words in the rule matter more; favorites and used plugins rise.
                var score = (rule.pluginWords.count - first.offset) * 10 + hits.count
                if store.favorites.contains(p.id) { score += 15 }
                score += min(10, UserLibrary.shared.useCount[p.id] ?? 0)
                return (p, score)
            }
        return scored.sorted { $0.1 > $1.1 }.prefix(12).map(\.0.id)
    }
}

// MARK: - The info panel's extras

/// Under the plugin's info: usage, number key, collections, chains, notes, more like this.
struct PluginExtras: View {
    let plugin: Plugin
    @Bindable var model: PickerModel
    var library = UserLibrary.shared
    @State private var note = ""
    @State private var showChains = false

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            usage
            if !plugin.isLogic { LicenseSection(plugin: plugin).id(plugin.id) }
            logicRow
            pinRow
            collectionsRow
            chainRow
            notes
            similar
        }
        .onAppear { note = library.notes[plugin.id] ?? "" }
        .onChange(of: plugin.id) { _, id in note = library.notes[id] ?? "" }
    }

    private func label(_ text: String) -> some View {
        Text(text).font(.system(size: Theme.ts(12))).foregroundStyle(Theme.faint)
    }

    @ViewBuilder private var usage: some View {
        let n = library.useCount[plugin.id] ?? 0
        HStack(spacing: 8) {
            Image(systemName: "chart.bar").font(.system(size: Theme.ts(11))).foregroundStyle(Theme.faint)
            Text(n == 0 ? "Not used yet" : "Used \(n) time\(n == 1 ? "" : "s")"
                 + (PluginStore.shared.lastUsed[plugin.id].map { " · last \($0.formatted(.relative(presentation: .named)))" } ?? ""))
                .font(.system(size: Theme.ts(12))).foregroundStyle(Theme.muted)
        }
    }

    /// One-step Logic actions for this plugin (BL-40 to BL-43).
    private var logicRow: some View {
        VStack(alignment: .leading, spacing: 8) {
            label("In Logic")
            FlowRow(spacing: 6) {
                if plugin.slotKind == .audioFX {
                    Chip(title: "As a send", systemImage: "arrow.turn.down.right", on: false) { TrackActions.addAsSend(plugin) }
                }
                if plugin.slotKind == .instrument {
                    Chip(title: "New track", systemImage: "plus", on: false) { TrackActions.newTrack(plugin) }
                }
                Chip(title: "Several tracks", systemImage: "square.stack", on: false) {
                    TracksWindow.shared.show(.add([plugin], plugin.name))
                }
                Chip(title: "Find on tracks", systemImage: "magnifyingglass", on: false) {
                    TracksWindow.shared.show(.find(plugin))
                }
            }
            if plugin.slotKind != .midiFX { formatRow }
        }
    }

    /// This plugin's own channel format (BL-69); the first chip follows Settings.
    private var formatRow: some View {
        let formats = ChannelFormats.shared
        let own = formats.own(plugin.id)
        return VStack(alignment: .leading, spacing: 6) {
            label("Channel format")
            FlowRow(spacing: 6) {
                Chip(title: "As in Settings (\(formats.mode.title))", systemImage: nil, on: own == nil) {
                    formats.set(nil, for: plugin.id)
                }
                ForEach([ChannelFormat.ask] + ChannelFormat.fixed) { f in
                    Chip(title: f.title, systemImage: nil, on: own == f) {
                        formats.set(own == f ? nil : f, for: plugin.id)
                    }
                }
            }
        }
        .padding(.top, 4)
    }

    private var pinRow: some View {
        let mine = library.key(for: .plugin(plugin.id))
        return VStack(alignment: .leading, spacing: 8) {
            label(mine.map { "Insert from anywhere with \(HotKey.pinDisplay($0))" } ?? "Pin to a number key")
            HStack(spacing: 5) {
                ForEach(1...9, id: \.self) { n in
                    let taken = library.pinTarget(n) != nil && mine != n
                    Button {
                        library.pin(n, to: mine == n ? nil : .plugin(plugin.id))
                    } label: {
                        Text("\(n)").font(.system(size: Theme.ts(12), weight: .semibold)).monospacedDigit()
                            .frame(width: 26, height: 26)
                            .foregroundStyle(mine == n ? Theme.onInk : (taken ? Theme.faint : Theme.text))
                            .background(RoundedRectangle(cornerRadius: 7).fill(mine == n ? Theme.ink : Theme.raised))
                            .overlay(alignment: .topTrailing) {
                                if taken { Circle().fill(Theme.faint).frame(width: 4, height: 4).padding(3) }
                            }
                    }
                    .buttonStyle(PressScale())
                    .help(taken ? "\(HotKey.pinDisplay(n)) is used by \(pinName(n)); click to use it for \(plugin.name)"
                                : "\(HotKey.pinDisplay(n))")
                }
            }
        }
    }

    private func pinName(_ n: Int) -> String {
        switch library.pinTarget(n) {
        case .plugin(let id)?: return PluginStore.shared.plugin(id)?.name ?? "a plugin"
        case .chain(let id)?: return library.chains.first { $0.id == id }?.name ?? "a chain"
        case nil: return ""
        }
    }

    private var collectionsRow: some View {
        VStack(alignment: .leading, spacing: 8) {
            label("Collections")
            FlowRow(spacing: 6) {
                ForEach(library.collections) { c in
                    Chip(title: c.name, on: c.pluginIDs.contains(plugin.id)) { library.toggle(plugin.id, in: c.id) }
                }
                Chip(title: "New", systemImage: "plus", on: false) {
                    if let name = NamePrompt.ask("New collection", placeholder: "For example Mix bus") {
                        library.collections.append(.init(name: name, pluginIDs: [plugin.id]))
                    }
                }
            }
        }
    }

    private var chainRow: some View {
        VStack(alignment: .leading, spacing: 8) {
            label("Chains")
            HStack(spacing: 6) {
                let inChains = library.chains.filter { $0.pluginIDs.contains(plugin.id) }.map(\.name)
                QuietPill(title: "Add to chain", systemImage: "link", height: 28) { showChains = true }
                    .popover(isPresented: $showChains, arrowEdge: .bottom) {
                        AddToChainList(pluginID: plugin.id) { showChains = false }
                    }
                if !inChains.isEmpty {
                    Text("In \(inChains.joined(separator: ", "))").font(.system(size: Theme.ts(12)))
                        .foregroundStyle(Theme.muted).lineLimit(1)
                }
            }
        }
    }

    private var notes: some View {
        VStack(alignment: .leading, spacing: 8) {
            label("My notes")
            TextEditor(text: $note)
                .font(.system(size: Theme.ts(13)))
                .scrollContentBackground(.hidden)
                .padding(8)
                .frame(minHeight: 70)
                .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Theme.surface))
                .overlay(alignment: .topLeading) {
                    if note.isEmpty {
                        Text("Your settings and tips, for example Ratio 4:1 on vocals")
                            .font(.system(size: Theme.ts(13))).foregroundStyle(Theme.faint)
                            .padding(.horizontal, 13).padding(.vertical, 8).allowsHitTesting(false)
                    }
                }
                .onChange(of: note) { _, v in
                    let t = v.trimmingCharacters(in: .whitespacesAndNewlines)
                    library.notes[plugin.id] = t.isEmpty ? nil : v
                }
        }
    }

    @ViewBuilder private var similar: some View {
        let list = Self.similar(to: plugin)
        if !list.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                label("More like this")
                LazyVGrid(columns: [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8)], spacing: 8) {
                    ForEach(list) { p in
                        Button { model.reveal(p.id) } label: {
                            VStack(alignment: .leading, spacing: 5) {
                                PluginThumbnail(plugin: p, radius: 10).aspectRatio(1.5, contentMode: .fit)
                                Text(p.name).font(.system(size: Theme.ts(11), weight: .medium)).foregroundStyle(Theme.text).lineLimit(1)
                                Text(p.manufacturer).font(.system(size: Theme.ts(10))).foregroundStyle(Theme.faint).lineLimit(1)
                            }
                        }
                        .buttonStyle(PressScale())
                    }
                }
            }
        }
    }

    /// Same slot kind and category (or looked-up kind), visible, best matches first (BL-28).
    static func similar(to plugin: Plugin, limit: Int = 4) -> [Plugin] {
        let store = PluginStore.shared
        let kindWords = Set((plugin.details?.kind ?? "").lowercased().split(separator: " ").map(String.init)
            .filter { $0.count > 3 })
        var scored: [(plugin: Plugin, score: Int)] = []
        for p in store.plugins where p.id != plugin.id && store.isVisible(p) && p.slotKind == plugin.slotKind {
            var score = p.displayCategory == plugin.displayCategory ? 10 : 0
            let words = Set((p.details?.kind ?? "").lowercased().split(separator: " ").map(String.init))
            score += kindWords.intersection(words).count * 4
            if store.favorites.contains(p.id) { score += 1 }
            if score >= 8 { scored.append((p, score)) }
        }
        scored.sort { a, b in a.score == b.score ? a.plugin.name < b.plugin.name : a.score > b.score }
        return scored.prefix(limit).map { $0.plugin }
    }
}

/// Popover list: add the plugin to a chain, or start a new one.
struct AddToChainList: View {
    let pluginID: String
    var close: () -> Void
    var library = UserLibrary.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(library.chains) { c in
                ActionRow(icon: "link", title: c.name, detail: "\(c.pluginIDs.count) plugins") {
                    library.addToChain(c.id, pluginID); close()
                }
            }
            ActionRow(icon: "plus", title: "New chain…", detail: "Starts with this plugin") {
                close()
                if let name = NamePrompt.ask("New chain", placeholder: "For example Vocal chain") {
                    library.newChain(named: name, with: [pluginID])
                }
            }
        }
        .padding(8).frame(width: 260).background(Theme.surface).preferredColorScheme(Theme.scheme)
    }
}

// MARK: - Chains (BL-25)

struct ChainsPanel: View {
    var close: () -> Void
    var library = UserLibrary.shared
    @State private var editing: String?
    @State private var listHeight: CGFloat = 0

    init(close: @escaping () -> Void, editing: String? = nil) {
        self.close = close
        _editing = State(initialValue: editing)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Chains").font(.system(size: Theme.ts(16), weight: .semibold)).foregroundStyle(Theme.text)
                Spacer()
                QuietPill(title: "New Chain", systemImage: "plus", height: 28) {
                    if let n = NamePrompt.ask("New chain", placeholder: "For example Vocal chain") {
                        editing = library.newChain(named: n).id
                    }
                }
            }
            if library.chains.isEmpty {
                Text("A chain is a list of plugins you add to a track in one go, like EQ, Compressor, DeEsser and Reverb for vocals. Start one here, or right-click a plugin and choose Add to Chain.")
                    .font(.system(size: Theme.ts(12))).foregroundStyle(Theme.muted).fixedSize(horizontal: false, vertical: true)
            }
            // The list is as tall as its chains, up to 460, so an open chain is never cut off (BL-146).
            ScrollView {
                VStack(spacing: 8) {
                    ForEach(library.chains) { chain in card(chain) }
                }
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { listHeight = $0 }
            }
            .frame(height: min(max(listHeight, 1), 460))
        }
        .padding(18).frame(width: 380).background(Theme.surface).preferredColorScheme(Theme.scheme)
    }

    private func card(_ chain: UserLibrary.Chain) -> some View {
        let plugins = library.plugins(in: chain)
        let key = library.key(for: .chain(chain.id))
        let open = editing == chain.id
        return VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(chain.name).font(.system(size: Theme.ts(14), weight: .semibold)).foregroundStyle(Theme.text)
                    Text(plugins.map(\.name).joined(separator: " → ").ifEmpty("No plugins yet"))
                        .font(.system(size: Theme.ts(11))).foregroundStyle(Theme.faint).lineLimit(2)
                }
                Spacer(minLength: 6)
                if let key { KeyCap(key: HotKey.pinDisplay(key)) }
                BarIconButton(systemImage: open ? "chevron.up" : "slider.horizontal.3", help: "Edit chain", active: open) {
                    editing = open ? nil : chain.id
                }
                PrimaryPill(title: "Add", height: 30) { close(); InsertRunner.run(plugins, title: chain.name) }
                    .disabled(plugins.isEmpty)
            }
            if open { editor(chain, plugins: plugins, key: key) }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Theme.raised.opacity(open ? 1 : 0.6)))
    }

    private func editor(_ chain: UserLibrary.Chain, plugins: [Plugin], key: Int?) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(chain.pluginIDs.enumerated()), id: \.offset) { i, id in
                HStack(spacing: 8) {
                    Text("\(i + 1)").font(.system(size: Theme.ts(11))).monospacedDigit().foregroundStyle(Theme.faint).frame(width: 14)
                    Text(PluginStore.shared.plugin(id)?.name ?? "Not installed").font(.system(size: Theme.ts(12)))
                        .foregroundStyle(Theme.text)
                    Spacer()
                    mini("arrow.up") { move(chain.id, i, -1) }.disabled(i == 0)
                    mini("arrow.down") { move(chain.id, i, 1) }.disabled(i == chain.pluginIDs.count - 1)
                    mini("xmark") { remove(chain.id, i) }
                }
            }
            HStack(spacing: 4) {
                Text("Key").font(.system(size: Theme.ts(11))).foregroundStyle(Theme.faint)
                ForEach(1...9, id: \.self) { n in
                    Button { library.pin(n, to: key == n ? nil : .chain(chain.id)) } label: {
                        Text("\(n)").font(.system(size: Theme.ts(11), weight: .semibold)).frame(width: 20, height: 20)
                            .foregroundStyle(key == n ? Theme.onInk : Theme.text)
                            .background(RoundedRectangle(cornerRadius: 5).fill(key == n ? Theme.ink : Theme.surface))
                    }
                    .buttonStyle(.plain)
                }
            }
            HStack {
                Button("Add to several tracks…") {
                    close(); TracksWindow.shared.show(.add(plugins, chain.name))
                }
                .disabled(plugins.isEmpty)
                Button("Rename") {
                    if let n = NamePrompt.ask("Rename chain", placeholder: "Name", initial: chain.name),
                       let i = library.chains.firstIndex(where: { $0.id == chain.id }) { library.chains[i].name = n }
                }
                Spacer()
                Button("Delete Chain") { library.deleteChain(chain.id) }.foregroundStyle(Theme.negative)
            }
            .buttonStyle(.plain).font(.system(size: Theme.ts(12))).foregroundStyle(Theme.muted)
        }
    }

    private func mini(_ icon: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon).font(.system(size: Theme.ts(10), weight: .semibold)).foregroundStyle(Theme.muted)
                .frame(width: 22, height: 22).background(Circle().fill(Theme.surface))
        }
        .buttonStyle(.plain)
    }

    private func move(_ chainID: String, _ i: Int, _ d: Int) {
        guard let c = library.chains.firstIndex(where: { $0.id == chainID }) else { return }
        library.chains[c].pluginIDs.swapAt(i, i + d)
    }

    private func remove(_ chainID: String, _ i: Int) {
        guard let c = library.chains.firstIndex(where: { $0.id == chainID }) else { return }
        library.chains[c].pluginIDs.remove(at: i)
    }
}

extension String {
    func ifEmpty(_ other: String) -> String { isEmpty ? other : self }
}

// MARK: - Plugin report: usage (BL-31) and cleanup (BL-32)

@MainActor
final class ReportWindow {
    static let shared = ReportWindow()
    private lazy var window: NSWindow = {
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 760, height: 640),
                         styleMask: [.titled, .closable, .resizable, .fullSizeContentView],
                         backing: .buffered, defer: false)
        w.titlebarAppearsTransparent = true
        w.titleVisibility = .hidden
        w.isMovableByWindowBackground = true
        w.isReleasedWhenClosed = false
        w.backgroundColor = Theme.nsGround
        w.appearance = Theme.nsAppearance
        w.minSize = NSSize(width: 520, height: 420)
        w.contentView = NSHostingView(rootView: ReportView())
        w.center()
        return w
    }()

    static let openTab = Notification.Name("report.openTab")
    /// The tab to open on, for a window that is made right now and not listening yet.
    static var pendingTab: String?

    func show(tab: String? = nil) {
        ReportWindow.pendingTab = tab
        _ = window
        window.makeKeyAndOrderFront(nil); NSApp.activate()
        if let tab { NotificationCenter.default.post(name: Self.openTab, object: tab) }
    }
}

struct ReportView: View {
    enum Tab: String, CaseIterable { case mostUsed = "Most used", never = "Unused", twice = "Installed twice", disk = "Disk space" }
    @State private var tab: Tab = .mostUsed
    @State private var sizes: [(maker: String, bytes: Int64, count: Int)] = []
    var store = PluginStore.shared
    var library = UserLibrary.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Plugin report").font(.system(size: Theme.ts(22), weight: .bold)).foregroundStyle(Theme.text)
            HStack(spacing: 6) {
                ForEach(Tab.allCases, id: \.self) { t in Chip(title: t.rawValue, on: tab == t) { tab = t } }
            }
            if tab == .never {
                UnusedView()
            } else {
                ScrollView {
                    VStack(spacing: 0) {
                        switch tab {
                        case .mostUsed: mostUsed
                        case .never: EmptyView()
                        case .twice: twice
                        case .disk: disk
                        }
                    }
                }
                .background(RoundedRectangle(cornerRadius: Theme.radiusInner).fill(Theme.surface))
            }
        }
        .padding(.horizontal, 26).padding(.top, 40).padding(.bottom, 22)
        .frame(minWidth: 520, minHeight: 420)
        .background(Theme.ground)
        .preferredColorScheme(Theme.scheme)
        .task(id: tab) { if tab == .disk && sizes.isEmpty { sizes = await Self.diskByMaker() } }
        .onAppear {
            if let raw = ReportWindow.pendingTab, let t = Tab(rawValue: raw) { tab = t }
            ReportWindow.pendingTab = nil
        }
        .onReceive(NotificationCenter.default.publisher(for: ReportWindow.openTab)) { n in
            if let raw = n.object as? String, let t = Tab(rawValue: raw) { tab = t }
        }
    }

    private func row(_ left: String, _ sub: String, _ right: String) -> some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(left).font(.system(size: Theme.ts(13))).foregroundStyle(Theme.text)
                    if !sub.isEmpty { Text(sub).font(.system(size: Theme.ts(11))).foregroundStyle(Theme.faint) }
                }
                Spacer()
                Text(right).font(.system(size: Theme.ts(13), weight: .medium)).foregroundStyle(Theme.muted).monospacedDigit()
            }
            .padding(.horizontal, 14).padding(.vertical, 9)
            Rectangle().fill(Theme.rule).frame(height: 1)
        }
    }

    private func empty(_ text: String) -> some View {
        Text(text).font(.system(size: Theme.ts(13))).foregroundStyle(Theme.faint).padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder private var mostUsed: some View {
        let used = store.plugins.filter { (library.useCount[$0.id] ?? 0) > 0 }
            .sorted { (library.useCount[$0.id] ?? 0) > (library.useCount[$1.id] ?? 0) }
        if used.isEmpty { empty("Nothing inserted yet. Every plugin you add to Logic is counted here.") }
        ForEach(used) { p in row(p.name, p.manufacturer, "\(library.useCount[p.id] ?? 0)×") }
    }

    @ViewBuilder private var never: some View {
        let unused = store.plugins.filter { !$0.isLogic && (library.useCount[$0.id] ?? 0) == 0 && store.lastUsed[$0.id] == nil }
            .sorted { $0.manufacturer == $1.manufacturer ? $0.name < $1.name : $0.manufacturer < $1.manufacturer }
        if unused.isEmpty { empty("You have used every installed plugin.") }
        else { empty("\(unused.count) of your installed plugins were never added from AG PlugFinder.") }
        ForEach(unused) { p in row(p.name, p.manufacturer, p.formatName) }
    }

    @ViewBuilder private var twice: some View {
        let groups = Dictionary(grouping: store.plugins) { "\($0.name.lowercased())|\($0.manufacturer.lowercased())" }
            .values.filter { $0.count > 1 }.sorted { $0[0].name < $1[0].name }
        if groups.isEmpty { empty("No plugin is installed twice.") }
        ForEach(groups, id: \.first!.id) { g in
            row(g[0].name, g[0].manufacturer, g.map(\.formatName).joined(separator: " + "))
        }
    }

    @ViewBuilder private var disk: some View {
        if sizes.isEmpty { empty("Measuring…") }
        ForEach(sizes, id: \.maker) { s in
            row(s.maker, "\(s.count) plugin\(s.count == 1 ? "" : "s")",
                ByteCountFormatter.string(fromByteCount: s.bytes, countStyle: .file))
        }
    }

    static func diskByMaker() async -> [(maker: String, bytes: Int64, count: Int)] {
        let entries = PluginStore.shared.plugins.compactMap { p in p.path.map { (p.manufacturer, $0) } }
        return await Task.detached {
            var seen = Set<String>()
            var byMaker: [String: (Int64, Int)] = [:]
            for (maker, path) in entries where seen.insert(path).inserted {
                let bytes = folderSize(path)
                let cur = byMaker[maker] ?? (0, 0)
                byMaker[maker] = (cur.0 + bytes, cur.1 + 1)
            }
            return byMaker.map { ($0.key, $0.value.0, $0.value.1) }.sorted { $0.1 > $1.1 }
        }.value
    }

    nonisolated static func folderSize(_ path: String) -> Int64 {
        let url = URL(fileURLWithPath: path)
        guard let e = FileManager.default.enumerator(at: url, includingPropertiesForKeys: [.totalFileAllocatedSizeKey])
        else { return 0 }
        var total: Int64 = 0
        for case let f as URL in e {
            total += Int64((try? f.resourceValues(forKeys: [.totalFileAllocatedSizeKey]).totalFileAllocatedSize) ?? 0)
        }
        return total
    }
}
