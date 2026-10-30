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

    var layout: Layout { didSet { save("layout", layout.rawValue) } }
    var size: Size { didSet { save("size", size.rawValue) } }
    var showName: Bool { didSet { save("showName", showName) } }
    var showDetails: Bool { didSet { save("showDetails", showDetails) } }
    var showInfoPane: Bool { didSet { save("showInfoPane", showInfoPane) } }
    var favoritesOnly: Bool { didSet { save("favoritesOnly", favoritesOnly) } }

    private init() {
        let d = UserDefaults.standard
        layout = Layout(rawValue: d.string(forKey: "view.layout") ?? "") ?? .grid
        size = Size(rawValue: d.string(forKey: "view.size") ?? "") ?? .medium
        showName = d.object(forKey: "view.showName") as? Bool ?? true
        showDetails = d.object(forKey: "view.showDetails") as? Bool ?? true
        showInfoPane = d.object(forKey: "view.showInfoPane") as? Bool ?? true
        favoritesOnly = d.bool(forKey: "view.favoritesOnly")
    }

    private func save(_ key: String, _ value: Any) {
        UserDefaults.standard.set(value, forKey: "view." + key)
    }
}
