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

    /// Set when every insert slot is full: the user picks which one to replace.
    var slotChoices: [SlotChoice]?
    var slotSelection = 0
    var message: String?
    var showAccessibilityButton = false
    var isBusy = false

    var results: [Plugin] {
        PluginStore.shared.filtered(query: query, sort: sort, favoritesOnly: ViewSettings.shared.favoritesOnly)
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
                return
            case .allFull(let slots):
                slotChoices = slots
                slotSelection = max(0, slots.count - 1)
                message = plugin.slotKind == .instrument
                    ? "This track already has an instrument. Replace it with \(plugin.name)?"
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
}
