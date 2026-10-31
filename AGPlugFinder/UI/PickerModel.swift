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
    var columns = 4
    /// The collection chip that is on (BL-29); nil shows everything.
    var collectionID: String? { didSet { if collectionID != oldValue { selection = 0 } } }
    /// The category chip that is on (BL-46); nil shows every category.
    var category: String? { didSet { if category != oldValue { selection = 0 } } }
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

    var results: [Plugin] {
        let only = collectionID.flatMap { id in UserLibrary.shared.collections.first { $0.id == id } }
            .map { Set($0.pluginIDs) }
        var list = PluginStore.shared.filtered(query: query, sort: sort,
                                               favoritesOnly: ViewSettings.shared.favoritesOnly, only: only)
        if let category { list = list.filter { $0.displayCategory == category } }
        if let t = pointerTarget { list = list.filter { $0.slotKind == t.kind } }
        guard query.isEmpty, collectionID == nil, category == nil, let s = suggestion, !s.ids.isEmpty else { return list }
        let rank = Dictionary(uniqueKeysWithValues: s.ids.enumerated().map { ($1, $0) })
        let first = list.filter { rank[$0.id] != nil }.sorted { rank[$0.id]! < rank[$1.id]! }
        return first + list.filter { rank[$0.id] == nil }
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
    func reveal(_ id: String) {
        if !results.contains(where: { $0.id == id }) {
            query = ""
            collectionID = nil
            category = nil
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
    func insertSelected(replacing slot: Int? = nil, onHide: () -> Void = {}, onShow: @escaping () -> Void = {}) {
        guard let plugin = selected, !isBusy else { return }
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
            let outcome = await LogicInserter.shared.insert(plugin, replacing: slot)
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
                message = "Logic Pro isn't open."
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
