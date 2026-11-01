import AppKit
import Observation

/// State shared by the popup and the library window: search, sort, selection and inserting.
@MainActor
@Observable
final class PickerModel {
    var query = "" { didSet { if query != oldValue { selection = 0 } } }
    var sort: PluginSort = PluginSort(rawValue: UserDefaults.standard.string(forKey: "sort") ?? "") ?? .name {
        didSet { UserDefaults.standard.set(sort.rawValue, forKey: "sort"); selection = 0 }
    }
    var selection = 0
    /// The keyboard is on the plugins, not the search (BL-106): Space previews, typing a letter
    /// goes back to the search.
    var keysOnPlugins = false
    /// The large Space bar preview is open.
    var previewing = false
    /// The plugin under the pointer, so a click selects it on press, like the arrows (BL-108).
    /// Read only by the mouse monitor, never by a view, so it causes no redraw.
    @ObservationIgnored var hoverID: String?
    /// Where the preview card sits in the window (top-left origin), so a click outside it
    /// closes the preview and still reaches what was clicked.
    @ObservationIgnored var previewCard: CGRect = .zero
    var columns = 4
    /// The collection chip that is on (BL-29); nil shows everything.
    var collectionID: String? { didSet { if collectionID != oldValue { selection = 0 } } }
    /// The category pills that are on (BL-46, BL-110): "cat:<name>" or "grp:<id>". Empty shows
    /// every category; ⌘-click turns on several.
    var pills: Set<String> = [] { didSet { if pills != oldValue { selection = 0 } } }
    /// One category on its own (self-tests, reveal).
    var category: String? {
        get { pills.count == 1 ? pills.first.flatMap { $0.hasPrefix("cat:") ? String($0.dropFirst(4)) : nil } : nil }
        set { pills = newValue.map { ["cat:" + $0] } ?? [] }
    }
    /// Set from "Replace" on the track panel: the next plugin chosen takes this slot (BL-36).
    var replaceTarget: StripPlugin?
    /// Set from the pointer shortcut: the slot under the pointer in Logic (BL-65). Only plugins
    /// that fit it are listed, and the chosen one goes exactly there.
    var pointerTarget: PointerTarget?
    /// Plugins picked with ⌘-click or ⇧-click, to act on together (BL-79).
    var picked: Set<String> = []

    /// ⌘-click adds or removes one plugin; ⇧-click picks everything from the selected one to it.
    func pick(_ index: Int, range: Bool) {
        let list = results
        guard list.indices.contains(index) else { return }
        if picked.isEmpty, let current = selected { picked.insert(current.id) }
        if range, list.indices.contains(selection) {
            for i in min(selection, index)...max(selection, index) { picked.insert(list[i].id) }
        } else if picked.contains(list[index].id) {
            picked.remove(list[index].id)
        } else {
            picked.insert(list[index].id)
        }
        selection = index
    }
    /// Plugins that fit the selected Logic track, shown first while the search is empty (BL-33).
    var suggestion: (track: String, ids: [String])?

    /// Set when every insert slot is full: the user picks which one to replace.
    var slotChoices: [SlotChoice]?
    var slotSelection = 0
    var message: String?
    var showAccessibilityButton = false
    var isBusy = false

    /// Shown under the pills when plugins were found by the sound described (BL-98).
    var soundHint: String? {
        let words = query.lowercased().split(separator: " ").map(String.init)
        let soundWords = SoundSearch.words(query)
        guard !soundWords.isEmpty else { return nil }
        let any = results.contains { p in
            let (name, desc) = PluginStore.shared.hay(p)
            return !words.allSatisfy { name.contains($0) } && !words.allSatisfy { desc.contains($0) }
                && SoundSearch.score(p, words: soundWords) > 0
        }
        return any ? "Also showing plugins that sound like “\(query.trimmingCharacters(in: .whitespaces))”" : nil
    }

    #if DEBUG
    static var resultsCount = 0
    #endif
    /// Everything the list depends on. Reading it also tells SwiftUI what to watch.
    private struct ResultsKey: Equatable {
        let query: String, sort: PluginSort, collectionID: String?, pills: Set<String>, slot: String?
        let suggestion: [String]?, favoritesOnly: Bool, store: Int, collections: [UserLibrary.Collection]
        let groups: [PillGroup], uses: Int, joined: Bool
    }
    @ObservationIgnored private var memo: (key: ResultsKey, list: [Plugin])?

    /// The plugins shown, in order. Worked out again only when something it depends on changed
    /// (BL-123): a selection, a redraw or scrolling reuse the same list.
    var results: [Plugin] {
        let store = PluginStore.shared, lib = UserLibrary.shared
        // Touch what the list depends on, so views redraw when it changes.
        _ = store.plugins; _ = store.favorites; _ = store.hiddenGroups; _ = store.hiddenPlugins; _ = store.shownPlugins
        let key = ResultsKey(query: query, sort: sort, collectionID: collectionID, pills: pills,
                             slot: pointerTarget.map { "\($0.kind)" }, suggestion: suggestion?.ids,
                             favoritesOnly: ViewSettings.shared.favoritesOnly, store: store.revision,
                             collections: lib.collections, groups: lib.pills.groups,
                             uses: sort == .mostUsed || !query.isEmpty ? lib.useCount.values.reduce(0, +) : 0,
                             joined: ViewSettings.shared.joinMonoStereo)
        if let memo, memo.key == key { return memo.list }
        let list = computeResults()
        memo = (key, list)
        return list
    }

    private func computeResults() -> [Plugin] {
        #if DEBUG
        Self.resultsCount += 1
        #endif
        let only = collectionID.flatMap { id in UserLibrary.shared.collections.first { $0.id == id } }
            .map { Set($0.pluginIDs) }
        var list = PluginStore.shared.filtered(query: query, sort: sort,
                                               favoritesOnly: ViewSettings.shared.favoritesOnly, only: only)
        if !pills.isEmpty {
            let cats = Set(pills.flatMap { Pills.categories(for: $0) })
            list = list.filter { cats.contains($0.displayCategory) }
        }
        if let t = pointerTarget { list = list.filter { $0.slotKind == t.kind } }
        // Favorites always lead, in the order the rest would have had (BL-181).
        let favs = PluginStore.shared.favorites
        func favoritesFirst(_ l: [Plugin]) -> [Plugin] {
            favs.isEmpty ? l : l.filter { favs.contains($0.id) } + l.filter { !favs.contains($0.id) }
        }
        guard query.isEmpty, collectionID == nil, pills.isEmpty, let s = suggestion, !s.ids.isEmpty else { return favoritesFirst(list) }
        let rank = Dictionary(uniqueKeysWithValues: s.ids.enumerated().map { ($1, $0) })
        let first = list.filter { rank[$0.id] != nil }.sorted { rank[$0.id]! < rank[$1.id]! }
        return favoritesFirst(first + list.filter { rank[$0.id] == nil })
    }

    /// Reads the selected Logic track's name and picks plugins for it. Read only: nothing in
    /// Logic is clicked or typed.
    func refreshSuggestion() {
        guard AXAccess.isTrusted, let pid = LogicInserter.shared.logicApp?.processIdentifier else {
            suggestion = nil; return
        }
        Task {
            let name = await Task.detached { LogicInserter.trackName(pid: pid) }.value
            guard let name else { suggestion = nil; return }
            if suggestion?.track == name { return }
            let ids = TrackSuggestions.plugins(for: name)
            suggestion = ids.isEmpty ? nil : (name, ids)
            selection = 0
        }
    }

    /// Shows a plugin even if the search or a collection hides it (More like this).
    /// Shuffle (BL-133): the selection hops across the plugins showing, slowing down like a
    /// wheel, and stops on a random one. Plugins it landed on lately are skipped.
    var shuffling = false
    /// Where the shuffle stopped; the grid scrolls it to the middle.
    var shuffleLanded: String?
    @ObservationIgnored private var recentShuffles: [String] = []

    func shuffle() {
        let r = results
        guard r.count > 1, !shuffling else { return }
        shuffling = true
        picked = []
        let fresh = r.indices.filter { !recentShuffles.contains(r[$0].id) && $0 != selection }
        let target = (fresh.isEmpty ? Array(r.indices.filter { $0 != selection }) : fresh).randomElement() ?? 0
        let hops = min(12, max(4, r.count))
        Task { @MainActor in
            for h in 0..<hops {
                var i = Int.random(in: 0..<r.count)
                if r.count > 2 { while i == selection || i == target { i = Int.random(in: 0..<r.count) } }
                selection = i
                // Fast at first, then slower, like a wheel coming to rest.
                try? await Task.sleep(for: .milliseconds(45 + h * h * 2))
            }
            selection = target
            keysOnPlugins = true
            // The last hop's scroll can still be moving: center the winner once it settles.
            try? await Task.sleep(for: .milliseconds(160))
            shuffleLanded = r[target].id
            recentShuffles.append(r[target].id)
            if recentShuffles.count > 8 { recentShuffles.removeFirst() }
            shuffling = false
        }
    }

    func reveal(_ id: String) {
        if !results.contains(where: { $0.id == id }) {
            query = ""
            collectionID = nil
            pills = []
            ViewSettings.shared.favoritesOnly = false
        }
        select(id)
    }

    var selected: Plugin? {
        let r = results
        return r.indices.contains(selection) ? r[selection] : nil
    }

    func reset() {
        query = ""
        selection = 0
        slotChoices = nil
        message = nil
        showAccessibilityButton = false
        pointerTarget = nil
    }

    func move(_ delta: Int) {
        let count = results.count
        guard count > 0 else { return }
        selection = max(0, min(count - 1, selection + delta))
    }

    func select(_ id: String) {
        if let i = results.firstIndex(where: { $0.id == id }) { selection = i }
    }

    func cycleSort(to index: Int) {
        let all = PluginSort.allCases
        if all.indices.contains(index) { sort = all[index] }
    }

    /// Places the selected plugin in Logic. `onHide`/`onShow` let the popup step out of the way.
    func insertSelected(replacing slot: Int? = nil, version: Plugin? = nil, onHide: () -> Void = {}, onShow: @escaping () -> Void = {}) {
        guard let plugin = version ?? selected, !isBusy else { return }
        if let target = replaceTarget, slot == nil {
            replace(target, with: plugin, onHide: onHide, onShow: onShow)
            return
        }
        if let target = pointerTarget, slot == nil {
            isBusy = true
            message = nil
            onHide()
            Task {
                let problem = await LogicTrack.shared.insert(plugin, at: target)
                isBusy = false
                if let problem {
                    message = problem
                    onShow()
                } else {
                    PluginStore.shared.markUsed(plugin.id)
                    Toast.show(target.occupant.map { "Replaced \($0) with \(plugin.name)" } ?? "Added \(plugin.name)")
                    TrackState.shared.refreshSoon()
                }
            }
            return
        }
        isBusy = true
        message = nil
        slotChoices = nil
        onHide()
        Task {
            let outcome = await Host.insert(plugin, replacing: slot)
            isBusy = false
            switch outcome {
            case .inserted:
                PluginStore.shared.markUsed(plugin.id)
                LogicTrack.shared.lastAdded = plugin.name
                TrackState.shared.refreshSoon()
                return
            case .allFull(let slots):
                slotChoices = slots
                slotSelection = max(0, slots.count - 1)
                message = plugin.slotKind == .instrument
                    ? "This track's instrument is \(slots.first?.name ?? "set"). Replace it with \(plugin.name)?"
                    : "Every insert slot on this track is full. Pick one to replace."
            case .needsAccessibility:
                AXAccess.requestTrust()
                showAccessibilityButton = true
                message = "AG PlugFinder needs Accessibility access to place plugins in Logic. " +
                    "Turn it on in System Settings → Privacy & Security → Accessibility, then try again."
            case .logicNotRunning:
                message = Host.notOpen
            case .noChannelStrip(let text), .failed(let text):
                message = text
            }
            onShow()
        }
    }

    /// Puts the chosen plugin in the slot picked on the track panel (BL-36).
    func replace(_ target: StripPlugin, with plugin: Plugin, onHide: () -> Void = {},
                 onShow: @escaping () -> Void = {}) {
        guard !isBusy else { return }
        isBusy = true
        message = nil
        onHide()
        Task {
            let problem = await LogicTrack.shared.replace(target, with: plugin)
            isBusy = false
            if let problem {
                message = problem
                onShow()
            } else {
                replaceTarget = nil
                PluginStore.shared.markUsed(plugin.id)
                Toast.show("Replaced \(target.name) with \(plugin.name)")
                TrackState.shared.refreshSoon()
            }
        }
    }
}
