import SwiftUI

/// The icons at the top right of the library that the user can hide and put in order (BL-189).
/// The ⋯ menu, the pin and the window button always stay, so nothing can be lost.
enum TopItem: String, CaseIterable, Identifiable {
    case shuffle, track, chains, newCollection, favorites, viewOptions, purchases
    var id: String { rawValue }
    var title: String {
        switch self {
        case .shuffle: return "Shuffle"
        case .track: return "This Track"
        case .chains: return "Chains"
        case .newCollection: return "New Collection"
        case .favorites: return "Favorites Only"
        case .viewOptions: return "View Options"
        case .purchases: return "My Purchases"
        }
    }
    var symbol: String {
        switch self {
        case .shuffle: return "dice"
        case .track: return "slider.vertical.3"
        case .chains: return "link"
        case .newCollection: return "plus.rectangle.on.rectangle"
        case .favorites: return "star"
        case .viewOptions: return "square.grid.2x2"
        case .purchases: return "creditcard"
        }
    }
}

/// Right-click on the icons: show or hide each one, drag to reorder.
struct TopBarEditor: View {
    @Bindable var view = ViewSettings.shared
    @State private var dragging: TopItem?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Top bar icons").font(.system(size: Theme.ts(14), weight: .semibold)).foregroundStyle(Theme.text)
            Text("Drag to change the order. Click the eye to show or hide.")
                .font(.system(size: Theme.ts(11.5))).foregroundStyle(Theme.faint)
            VStack(spacing: 3) {
                ForEach(view.topItems) { item in row(item) }
            }
            HStack {
                Text("⋯, the pin and the window button always stay.")
                    .font(.system(size: Theme.ts(11))).foregroundStyle(Theme.faint)
                Spacer()
                if !view.topOrder.isEmpty || !view.topHidden.isEmpty {
                    Button("Reset") { view.topOrder = []; view.topHidden = [] }
                        .buttonStyle(.plain).font(.system(size: Theme.ts(12), weight: .medium)).foregroundStyle(Theme.accent)
                }
            }
        }
        .padding(14)
        .frame(width: 290)
        .background(Theme.surface)
        .preferredColorScheme(Theme.scheme)
    }

    private func row(_ item: TopItem) -> some View {
        let hidden = view.topHidden.contains(item.rawValue)
        return HStack(spacing: 10) {
            Image(systemName: "line.3.horizontal").font(.system(size: Theme.ts(11))).foregroundStyle(Theme.faint)
            Image(systemName: item.symbol).font(.system(size: Theme.ts(13))).frame(width: 20)
                .foregroundStyle(hidden ? Theme.faint : Theme.text)
            Text(item.title).font(.system(size: Theme.ts(13))).foregroundStyle(hidden ? Theme.faint : Theme.text)
            Spacer()
            Button {
                withAnimation(.easeOut(duration: 0.15)) {
                    if hidden { view.topHidden.removeAll { $0 == item.rawValue } } else { view.topHidden.append(item.rawValue) }
                }
            } label: {
                Image(systemName: hidden ? "eye.slash" : "eye").font(.system(size: Theme.ts(12)))
                    .foregroundStyle(hidden ? Theme.faint : Theme.muted).frame(width: 26, height: 22).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(hidden ? "Show \(item.title)" : "Hide \(item.title)")
        }
        .padding(.horizontal, 10).frame(height: 32)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(dragging == item ? Theme.raised : Theme.hover))
        .contentShape(Rectangle())
        .onDrag {
            dragging = item
            return NSItemProvider(object: item.rawValue as NSString)
        }
        .onDrop(of: [.text], delegate: Reorder(item: item, view: view, dragging: $dragging))
    }

    private struct Reorder: DropDelegate {
        let item: TopItem
        let view: ViewSettings
        @Binding var dragging: TopItem?

        func dropEntered(info: DropInfo) {
            guard let d = dragging, d != item else { return }
            var list = view.topItems
            guard let from = list.firstIndex(of: d), let to = list.firstIndex(of: item) else { return }
            list.move(fromOffsets: IndexSet(integer: from), toOffset: to > from ? to + 1 : to)
            withAnimation(.easeOut(duration: 0.15)) { view.topOrder = list.map(\.rawValue) }
        }
        func dropUpdated(info: DropInfo) -> DropProposal? { DropProposal(operation: .move) }
        func performDrop(info: DropInfo) -> Bool { dragging = nil; return true }
    }
}
