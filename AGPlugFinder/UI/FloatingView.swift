import AppKit
import SwiftUI

/// Floating (BL-182): a see-through command bar over Logic, a search line with a category chip and
/// the results as a list under it. Tab steps through the categories, the arrows move, Return adds.
struct FloatingBody: View {
    @Bindable var model: PickerModel
    let mode: WindowMode
    let onMode: (WindowMode) -> Void
    var onInsert: () -> Void
    var view = ViewSettings.shared

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                categoryChip
                SearchField(model: model, focusOnAppear: true, large: true, bare: true)
                Text("\(model.results.count)").font(.system(size: Theme.ts(11))).foregroundStyle(Theme.faint).monospacedDigit()
                BarIconButton(systemImage: view.favoritesOnly ? "star.fill" : "star",
                              help: "Favorites only (⌘F)", active: view.favoritesOnly, activeTint: Theme.favorite) {
                    view.favoritesOnly.toggle()
                    model.selection = 0
                }
                ViewModeButton(mode: mode, onMode: onMode)
            }
            .padding(.leading, 16).padding(.trailing, 8)
            .frame(height: 58)
            .gesture(WindowDragGesture())
            Rectangle().fill(Theme.edge).frame(height: 1)
            PluginGrid(model: model, compact: true) { onInsert() }
                .frame(maxHeight: .infinity)
            Rectangle().fill(Theme.edge).frame(height: 1)
            HStack(spacing: 6) {
                KeyCap(key: "⇥"); Text("category")
                KeyCap(key: "↑"); KeyCap(key: "↓"); Text("move")
                Spacer()
                KeyCap(key: "↩"); Text(Host.insertTitle)
            }
            .font(.system(size: Theme.ts(11))).foregroundStyle(Theme.muted)
            .padding(.horizontal, 14).frame(height: 34)
        }
        .background {
            ZStack {
                Blur()
                Theme.ground.opacity(0.55)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Theme.edge, lineWidth: 1))
    }

    /// The category shown, like the chip at the start of a command bar. A click steps on.
    private var categoryChip: some View {
        let title = Self.current(model).flatMap { key in Pills.categoryPills().first { $0.key == key }?.title } ?? "All"
        return Button { Self.stepCategory(model, by: 1) } label: {
            HStack(spacing: 5) {
                Image(systemName: "line.3.horizontal.decrease").font(.system(size: Theme.ts(10), weight: .bold))
                Text(title).font(.system(size: Theme.ts(12), weight: .semibold)).lineLimit(1)
            }
            .foregroundStyle(Theme.accent)
            .padding(.horizontal, 9).frame(height: 24)
            .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Theme.accent.opacity(0.16)))
            .contentShape(Rectangle())
        }
        .buttonStyle(PressScale())
        .help("Category: click or press Tab for the next one, Shift+Tab for the one before")
        .fixedSize()
    }

    private static func current(_ model: PickerModel) -> String? {
        model.pills.count == 1 ? model.pills.first : nil
    }

    /// All, then each shown category in the bar's order.
    static func stepCategory(_ model: PickerModel, by step: Int) {
        let keys: [String?] = [nil] + Pills.categoryPills().filter { !$0.hidden }.map(\.key)
        let at = keys.firstIndex(of: current(model)) ?? 0
        let next = keys[(at + step + keys.count) % keys.count]
        model.pills = next.map { [$0] } ?? []
        model.selection = 0
    }
}

/// The blurred screen behind the floating bar.
private struct Blur: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let v = NSVisualEffectView()
        v.material = .hudWindow
        v.blendingMode = .behindWindow
        v.state = .active
        return v
    }
    func updateNSView(_ v: NSVisualEffectView, context: Context) {}
}
