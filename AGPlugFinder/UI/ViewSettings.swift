import Foundation
import Observation

/// How the browser looks. Shared by the popup and the library window, remembered across launches.
@MainActor
@Observable
final class ViewSettings {
    static let shared = ViewSettings()

    enum Layout: String, CaseIterable, Identifiable {
        case grid, list
        var id: String { rawValue }
        var title: String { self == .grid ? "Grid" : "List" }
        var symbol: String { self == .grid ? "square.grid.2x2" : "list.bullet" }
    }

    enum Size: String, CaseIterable, Identifiable {
        case small, medium, large, huge
        var id: String { rawValue }
        var title: String {
            switch self {
            case .small: return "S"
            case .medium: return "M"
            case .large: return "L"
            case .huge: return "XL"
            }
        }
        /// Tile width in points.
        var tileWidth: CGFloat {
            switch self {
            case .small: return 130
            case .medium: return 180
            case .large: return 250
            case .huge: return 340
            }
        }
    }

    /// What the chip row above the grid shows (BL-46).
    /// What the library shows before anything is typed (BL-184).
    enum StartView: String, CaseIterable, Identifiable {
        case all, mostUsed, favorites, unused, empty
        var id: String { rawValue }
        var title: String {
            switch self {
            case .all: return "All"
            case .mostUsed: return "Most Used"
            case .favorites: return "Favorites"
            case .unused: return "Never Used"
            case .empty: return "Nothing"
            }
        }
    }

    enum ChipRow: String, CaseIterable, Identifiable {
        case collections, categories, both, off
        var id: String { rawValue }
        var title: String {
            switch self {
            case .collections: return "Collections"
            case .categories: return "Categories"
            case .both: return "Both"
            case .off: return "Off"
            }
        }
        var showsCollections: Bool { self == .collections || self == .both }
        var showsCategories: Bool { self == .categories || self == .both }
    }

    var layout: Layout { didSet { save("layout", layout.rawValue) } }
    var size: Size { didSet { save("size", size.rawValue); if !settingWidth { tileWidth = size.tileWidth } } }
    /// Picture width from the size slider (BL-48), any width between small and extra large.
    var tileWidth: CGFloat { didSet { save("tileWidth", Double(tileWidth)) } }
    static let tileRange: ClosedRange<CGFloat> = 110...420
    /// Below this the cards are the smallest size: the star moves onto the picture's corner.
    static let smallestCards: CGFloat = 150
    private var settingWidth = false

    /// Moves the slider; the S M L XL chips light up for the nearest size.
    func setTileWidth(_ w: CGFloat) {
        tileWidth = min(max(w, Self.tileRange.lowerBound), Self.tileRange.upperBound)
        let nearest = Size.allCases.min { abs($0.tileWidth - tileWidth) < abs($1.tileWidth - tileWidth) } ?? .medium
        if nearest != size { settingWidth = true; size = nearest; settingWidth = false }
    }
    var showName: Bool { didSet { save("showName", showName) } }
    var showDetails: Bool { didSet { save("showDetails", showDetails) } }
    var showInfoPane: Bool { didSet { save("showInfoPane", showInfoPane) } }
    var favoritesOnly: Bool { didSet { save("favoritesOnly", favoritesOnly) } }
    var chipRow: ChipRow { didSet { save("chipRow", chipRow.rawValue) } }
    /// Space opens a large preview of the selected plugin (BL-106).
    var spacePreview: Bool { didSet { save("spacePreview", spacePreview) } }
    /// Mono and stereo versions of a plugin shown as one (BL-124).
    var joinMonoStereo: Bool { didSet { save("joinMonoStereo", joinMonoStereo) } }
    /// The selected plugin's card shows bigger and follows the arrow keys (BL-171).
    var zoomSelected: Bool { didSet { save("zoomSelected", zoomSelected) } }
    /// How much bigger (BL-172): S 1.15, M 1.25, L 1.4.
    var zoomScale: Double { didSet { save("zoomScale", zoomScale) } }
    var startView: StartView { didSet { save("startView", startView.rawValue) } }
    /// The icons at the top right, in the user's order, and the ones hidden (BL-189).
    var topOrder: [String] { didSet { save("topOrder", topOrder) } }
    var topHidden: [String] { didSet { save("topHidden", topHidden) } }

    /// Every top bar icon, in the chosen order; new ones join at the end.
    var topItems: [TopItem] {
        let chosen = topOrder.compactMap(TopItem.init(rawValue:))
        return chosen + TopItem.allCases.filter { !chosen.contains($0) }
    }

    private init() {
        let d = UserDefaults.standard
        layout = Layout(rawValue: d.string(forKey: "view.layout") ?? "") ?? .grid
        size = Size(rawValue: d.string(forKey: "view.size") ?? "") ?? .medium
        let savedWidth = d.double(forKey: "view.tileWidth")
        tileWidth = savedWidth > 0 ? CGFloat(savedWidth) : (Size(rawValue: d.string(forKey: "view.size") ?? "") ?? .medium).tileWidth
        showName = d.object(forKey: "view.showName") as? Bool ?? true
        showDetails = d.object(forKey: "view.showDetails") as? Bool ?? true
        showInfoPane = d.object(forKey: "view.showInfoPane") as? Bool ?? true
        favoritesOnly = d.bool(forKey: "view.favoritesOnly")
        chipRow = ChipRow(rawValue: d.string(forKey: "view.chipRow") ?? "") ?? .both
        spacePreview = d.object(forKey: "view.spacePreview") as? Bool ?? true
        joinMonoStereo = d.object(forKey: "view.joinMonoStereo") as? Bool ?? true
        zoomSelected = d.bool(forKey: "view.zoomSelected")
        let z = d.double(forKey: "view.zoomScale")
        zoomScale = [1.15, 1.25, 1.4].contains(z) ? z : 1.25
        startView = StartView(rawValue: d.string(forKey: "view.startView") ?? "") ?? .all
        topOrder = d.stringArray(forKey: "view.topOrder") ?? []
        topHidden = d.stringArray(forKey: "view.topHidden") ?? []
    }

    private func save(_ key: String, _ value: Any) {
        #if DEBUG
        // Test runs share the real app's settings: never save a view tried during a test.
        if CommandLine.arguments.contains(where: { $0.hasPrefix("--selftest") }) { return }
        #endif
        UserDefaults.standard.set(value, forKey: "view." + key)
        if !applying, UserLibrary.ready { UserLibrary.shared.settingChanged() }
    }

    // MARK: Sync (BL-157)

    private var applying = false

    /// The view choices other Macs take, as text.
    var syncValues: [String: String] {
        ["layout": layout.rawValue, "size": size.rawValue, "tileWidth": String(Double(tileWidth)),
         "showName": String(showName), "showDetails": String(showDetails), "showInfoPane": String(showInfoPane),
         "chipRow": chipRow.rawValue, "spacePreview": String(spacePreview), "joinMonoStereo": String(joinMonoStereo),
         "zoomSelected": String(zoomSelected), "zoomScale": String(zoomScale), "startView": startView.rawValue,
         "topOrder": topOrder.joined(separator: ","), "topHidden": topHidden.joined(separator: ",")]
    }

    /// Takes another Mac's view choices; only what differs changes.
    func applySync(_ v: [String: String]) {
        applying = true
        defer { applying = false }
        if let x = v["layout"].flatMap(Layout.init(rawValue:)), x != layout { layout = x }
        if let x = v["size"].flatMap(Size.init(rawValue:)), x != size { settingWidth = true; size = x; settingWidth = false }
        if let x = v["tileWidth"].flatMap(Double.init), abs(CGFloat(x) - tileWidth) > 0.5 {
            tileWidth = min(max(CGFloat(x), Self.tileRange.lowerBound), Self.tileRange.upperBound)
        }
        func flag(_ k: String) -> Bool? { v[k].flatMap(Bool.init) }
        if let x = flag("showName"), x != showName { showName = x }
        if let x = flag("showDetails"), x != showDetails { showDetails = x }
        if let x = flag("showInfoPane"), x != showInfoPane { showInfoPane = x }
        if let x = v["chipRow"].flatMap(ChipRow.init(rawValue:)), x != chipRow { chipRow = x }
        if let x = flag("spacePreview"), x != spacePreview { spacePreview = x }
        if let x = flag("joinMonoStereo"), x != joinMonoStereo { joinMonoStereo = x }
        if let x = flag("zoomSelected"), x != zoomSelected { zoomSelected = x }
        if let x = v["zoomScale"].flatMap(Double.init), [1.15, 1.25, 1.4].contains(x), x != zoomScale { zoomScale = x }
        if let x = v["startView"].flatMap(StartView.init(rawValue:)), x != startView { startView = x }
        func list(_ k: String) -> [String]? { v[k].map { $0.split(separator: ",").map(String.init) } }
        if let x = list("topOrder"), x != topOrder { topOrder = x }
        if let x = list("topHidden"), x != topHidden { topHidden = x }
    }
}
