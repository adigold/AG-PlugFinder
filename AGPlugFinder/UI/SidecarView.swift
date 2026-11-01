import AppKit
import SwiftUI

/// How the library window is shown (BL-148).
enum WindowMode: String, CaseIterable, Identifiable {
    case full, sidecar, mini
    var id: String { rawValue }
    var title: String {
        switch self {
        case .full: return "Full Window"
        case .sidecar: return "Sidecar"
        case .mini: return "Mini"
        }
    }
    var symbol: String {
        switch self {
        case .full: return "macwindow"
        case .sidecar: return "sidebar.right"
        case .mini: return "rectangle.compress.vertical"
        }
    }
}

/// The view button in the top bar: a small menu with the three ways to show the window.
struct ViewModeButton: View {
    let mode: WindowMode
    let onMode: (WindowMode) -> Void
    @State private var open = false

    var body: some View {
        BarIconButton(systemImage: mode.symbol, help: "Full window, sidecar or mini", active: open) { open.toggle() }
            .popover(isPresented: $open, arrowEdge: .bottom) {
                VStack(spacing: 2) {
                    ForEach(WindowMode.allCases) { m in
                        ModeRow(mode: m, on: m == mode) {
                            open = false
                            // After the menu has closed, so the window can change size cleanly.
                            DispatchQueue.main.async { onMode(m) }
                        }
                    }
                }
                .padding(6)
                .frame(width: 210)
                .background(Theme.surface)
                .preferredColorScheme(Theme.scheme)
            }
    }

    private struct ModeRow: View {
        let mode: WindowMode
        let on: Bool
        let action: () -> Void
        @State private var hovering = false

        var body: some View {
            Button(action: action) {
                HStack(spacing: 10) {
                    Image(systemName: mode.symbol).font(.system(size: Theme.ts(13))).frame(width: 18)
                        .foregroundStyle(on ? Theme.accent : Theme.muted)
                    Text(mode.title).font(.system(size: Theme.ts(13), weight: on ? .semibold : .regular))
                        .foregroundStyle(Theme.text)
                    Spacer()
                    if on { Image(systemName: "checkmark").font(.system(size: Theme.ts(11), weight: .bold)).foregroundStyle(Theme.accent) }
                }
                .padding(.horizontal, 10).frame(height: 32)
                .background(RoundedRectangle(cornerRadius: 8).fill(hovering ? Theme.raised : Color.clear))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .onHover { hovering = $0 }
        }
    }
}

/// The sidecar (BL-148): a tall narrow panel at the side of the screen. With nothing typed and
/// no pill on, every category is a row of pictures that scrolls sideways; a search or a pill
/// shows the plain list. A click selects, a double-click adds the plugin to Logic.
struct SidecarBody: View {
    @Bindable var model: PickerModel
    var window: NSWindow?
    let mode: WindowMode
    let pinned: Bool
    let onMode: (WindowMode) -> Void
    let onPin: () -> Void
    let onInsert: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                TrafficLights(window: window)
                SearchField(model: model, focusOnAppear: false)
                ViewModeButton(mode: mode, onMode: onMode)
            }
            .padding(.trailing, 8)
            .frame(height: WindowChrome.barHeight)
            .gesture(WindowDragGesture())
            CollectionBar(model: model, scrolls: true)
            if browsing {
                shelves
            } else {
                PluginGrid(model: model, compact: true) { onInsert() }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            if let message = model.message {
                Text(message).font(.system(size: Theme.ts(11))).foregroundStyle(Theme.warning).lineLimit(3)
                    .padding(.horizontal, 14).padding(.vertical, 8)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .overlay {
            if model.slotChoices != nil {
                ZStack {
                    Color.black.opacity(0.55)
                    SlotChooser(model: model) { model.insertSelected(replacing: $0) }
                }
            }
        }
    }

    /// Nothing typed, no pill and no collection on: the category rows.
    private var browsing: Bool {
        model.query.trimmingCharacters(in: .whitespaces).isEmpty && model.pills.isEmpty && model.collectionID == nil
    }

    private var shelves: some View {
        let results = model.results
        let groups = Dictionary(grouping: results, by: \.displayCategory)
            .sorted { $0.key.localizedCaseInsensitiveCompare($1.key) == .orderedAscending }
        let selectedID = model.selected?.id
        return ScrollView {
            LazyVStack(alignment: .leading, spacing: 18) {
                Text("CATEGORY").font(.system(size: Theme.ts(10), weight: .semibold)).kerning(1.2).foregroundStyle(Theme.faint)
                    .padding(.horizontal, 16).padding(.top, 10)
                ForEach(groups, id: \.key) { name, list in
                    VStack(alignment: .leading, spacing: 8) {
                        Button { model.pills = ["cat:" + name] } label: {
                            HStack(spacing: 8) {
                                Image(systemName: LogicCard.symbol(for: name)).font(.system(size: Theme.ts(13)))
                                    .foregroundStyle(Theme.accent).frame(width: 18)
                                Text(name).font(.system(size: Theme.ts(15), weight: .semibold)).foregroundStyle(Theme.text)
                                Spacer()
                                Text("\(list.count)").font(.system(size: Theme.ts(12))).monospacedDigit().foregroundStyle(Theme.faint)
                                Image(systemName: "chevron.right").font(.system(size: Theme.ts(11), weight: .semibold)).foregroundStyle(Theme.faint)
                            }
                            .padding(.horizontal, 16)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .help("Show every \(name) plugin")
                        ScrollView(.horizontal) {
                            LazyHStack(spacing: 10) {
                                ForEach(list.prefix(30)) { p in
                                    card(p, selected: p.id == selectedID, results: results)
                                }
                            }
                            .padding(.horizontal, 16)
                        }
                        .scrollIndicators(.never)
                    }
                }
            }
            .padding(.bottom, 16)
        }
    }

    private func card(_ p: Plugin, selected: Bool, results: [Plugin]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            PluginThumbnail(plugin: p)
                .frame(width: 128, height: 80)
                .overlay(RoundedRectangle(cornerRadius: Theme.radiusInner, style: .continuous)
                    .strokeBorder(selected ? Theme.accent : .clear, lineWidth: 2))
            Text(PluginVariants.title(p)).font(.system(size: Theme.ts(12), weight: .medium))
                .foregroundStyle(selected ? Theme.text : Theme.muted).lineLimit(1)
                .frame(width: 128, alignment: .leading)
        }
        .contentShape(Rectangle())
        .help(p.name)
        .onTapGesture {
            if let i = results.firstIndex(where: { $0.id == p.id }) { model.selection = i }
            if NSApp.currentEvent?.clickCount ?? 1 >= 2 { onInsert() }
        }
        .contextMenu {
            PluginContextMenu(plugin: p, select: { model.select(p.id) }, insert: { model.select(p.id); onInsert() },
                              insertVersion: { v in model.select(p.id); model.insertSelected(version: v) })
        }
    }
}
