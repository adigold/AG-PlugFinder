import AppKit
import SwiftUI

enum Theme {
    static let accent = Color(red: 0.98, green: 0.62, blue: 0.22)
    static let tileBG = Color.primary.opacity(0.05)
    static let tileSelected = Color(red: 0.98, green: 0.62, blue: 0.22).opacity(0.22)
}

/// Search field + sort chips.
struct SearchBar: View {
    @Bindable var model: PickerModel
    var focusOnAppear = true
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Search plugins, makers or categories", text: $model.query)
                    .textFieldStyle(.plain)
                    .font(.system(size: 17))
                    .focused($focused)
                if !model.query.isEmpty {
                    Button { model.query = "" } label: {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                    }.buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 12).padding(.vertical, 9)
            .background(RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(0.07)))

            SortChips(sort: $model.sort)
        }
        .onAppear { if focusOnAppear { focused = true } }
        .onChange(of: model.query) { _, _ in focused = true }
    }
}

/// The five sort options as chips (⌘1 to ⌘5).
struct SortChips: View {
    @Binding var sort: PluginSort

    var body: some View {
        HStack(spacing: 4) {
            ForEach(Array(PluginSort.allCases.enumerated()), id: \.element) { i, option in
                Button { sort = option } label: {
                    Text(option.title)
                        .font(.system(size: 12, weight: sort == option ? .semibold : .regular))
                        .padding(.horizontal, 10).padding(.vertical, 6)
                        .background(Capsule().fill(sort == option ? Theme.accent.opacity(0.85)
                                                                  : Color.primary.opacity(0.06)))
                        .foregroundStyle(sort == option ? Color.black : Color.primary)
                }
                .buttonStyle(.plain)
                .help("Sort by \(option.title.lowercased()) (⌘\(i + 1))")
            }
        }
    }
}

/// Screenshot or a placeholder that says why there is none.
struct PluginThumbnail: View {
    let plugin: Plugin
    var store = PluginStore.shared

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 8).fill(Color.black.opacity(0.78))
            if store.imageGeneration >= 0, let img = store.image(for: plugin.id) {
                Image(nsImage: img).resizable().aspectRatio(contentMode: .fit)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                    .padding(3)
            } else {
                VStack(spacing: 6) {
                    Text(initials).font(.system(size: 26, weight: .bold, design: .rounded))
                        .foregroundStyle(Theme.accent.opacity(0.9))
                    Text(placeholderText).font(.system(size: 10)).foregroundStyle(.secondary)
                }
            }
        }
    }

    private var initials: String {
        let words = plugin.name.split(whereSeparator: { !$0.isLetter && !$0.isNumber })
        return words.prefix(2).compactMap { $0.first.map(String.init) }.joined().uppercased()
    }

    private var placeholderText: String {
        switch plugin.snapshotState {
        case .pending: return "Screenshot coming…"
        case .noUI: return "No custom window"
        case .failed: return "Screenshot failed"
        case .done: return ""
        }
    }
}

struct PluginTile: View {
    let plugin: Plugin
    let isSelected: Bool
    var store = PluginStore.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            PluginThumbnail(plugin: plugin)
                .frame(height: 96)
            HStack(spacing: 4) {
                Text(plugin.name).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                Spacer(minLength: 0)
                if store.favorites.contains(plugin.id) {
                    Image(systemName: "star.fill").font(.system(size: 10)).foregroundStyle(Theme.accent)
                }
            }
            Text("\(plugin.manufacturer) · \(plugin.displayCategory)")
                .font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 12).fill(isSelected ? Theme.tileSelected : Theme.tileBG))
        .overlay(RoundedRectangle(cornerRadius: 12)
            .strokeBorder(isSelected ? Theme.accent : Color.clear, lineWidth: 2))
        .contentShape(RoundedRectangle(cornerRadius: 12))
    }
}

/// Grid of tiles that keeps the selection in view.
struct PluginGrid: View {
    @Bindable var model: PickerModel
    var onActivate: () -> Void

    var body: some View {
        let results = model.results
        ScrollViewReader { proxy in
            ScrollView {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: model.columns),
                          spacing: 10) {
                    ForEach(Array(results.enumerated()), id: \.element.id) { i, plugin in
                        PluginTile(plugin: plugin, isSelected: i == model.selection)
                            .id(plugin.id)
                            .onTapGesture(count: 2) { model.selection = i; onActivate() }
                            .onTapGesture { model.selection = i }
                    }
                }
                .padding(12)
            }
            .onChange(of: model.selection) { _, new in
                if results.indices.contains(new) {
                    withAnimation(.easeOut(duration: 0.12)) { proxy.scrollTo(results[new].id) }
                }
            }
            .overlay {
                if results.isEmpty {
                    Text(PluginStore.shared.plugins.isEmpty ? "Scanning plugins…" : "No plugins match")
                        .foregroundStyle(.secondary)
                }
            }
        }
    }
}

/// The right-hand pane: big screenshot and everything we know about the plugin.
struct PluginDetailView: View {
    let plugin: Plugin
    var onInsert: () -> Void
    var store = PluginStore.shared
    var fetcher = PluginInfoFetcher.shared

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                PluginThumbnail(plugin: plugin).frame(height: 170)
                VStack(alignment: .leading, spacing: 3) {
                    Text(plugin.name).font(.system(size: 20, weight: .bold))
                    Text("\(plugin.manufacturer) · \(plugin.displayCategory)")
                        .font(.system(size: 13)).foregroundStyle(.secondary)
                }
                if let d = plugin.details {
                    if !d.kind.isEmpty {
                        Text(d.kind).font(.system(size: 12, weight: .medium)).foregroundStyle(Theme.accent)
                    }
                    if !d.bestFeature.isEmpty {
                        VStack(alignment: .leading, spacing: 4) {
                            Label("Best feature", systemImage: "sparkles")
                                .font(.system(size: 11, weight: .semibold)).foregroundStyle(Theme.accent)
                            Text(d.bestFeature).font(.system(size: 13))
                        }
                        .padding(10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(RoundedRectangle(cornerRadius: 10).fill(Theme.accent.opacity(0.12)))
                    }
                    Text(d.summary).font(.system(size: 13)).fixedSize(horizontal: false, vertical: true)
                    ForEach(d.highlights, id: \.self) { h in
                        Label(h, systemImage: "checkmark").font(.system(size: 12))
                    }
                } else if fetcher.failures[plugin.id] != nil {
                    Text("Info lookup failed: \(fetcher.failures[plugin.id] ?? "")")
                        .font(.system(size: 12)).foregroundStyle(.red)
                } else {
                    Text("No info yet. Use Look Up Info in the library window.")
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                }
                Divider()
                VStack(alignment: .leading, spacing: 3) {
                    meta("Type", plugin.typeName + (plugin.isV3 ? " (AUv3)" : ""))
                    meta("Version", plugin.version)
                    if let n = plugin.parameterCount { meta("Parameters", "\(n)") }
                    if !plugin.tags.isEmpty { meta("Tags", plugin.tags.joined(separator: ", ")) }
                    if plugin.snapshotState == .failed, let e = plugin.snapshotError { meta("Screenshot", e) }
                }
                HStack {
                    Button(action: onInsert) { Label("Insert in Logic", systemImage: "return") }
                        .keyboardShortcut(.defaultAction)
                    Button {
                        store.toggleFavorite(plugin.id)
                    } label: {
                        Image(systemName: store.favorites.contains(plugin.id) ? "star.fill" : "star")
                    }
                    .help("Favorite (⌘D)")
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func meta(_ k: String, _ v: String) -> some View {
        HStack(alignment: .top) {
            Text(k).foregroundStyle(.secondary).frame(width: 78, alignment: .leading)
            Text(v).textSelection(.enabled)
        }.font(.system(size: 11))
    }
}

/// Shown when every slot is full: pick the one to replace (↑ ↓ and Return).
struct SlotChooser: View {
    @Bindable var model: PickerModel
    var onChoose: (Int) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Replace which insert?").font(.headline)
            ForEach(model.slotChoices ?? []) { slot in
                Button { onChoose(slot.id) } label: {
                    HStack {
                        Text("\(slot.id + 1)").monospacedDigit().foregroundStyle(.secondary).frame(width: 22)
                        Text(slot.name)
                        Spacer()
                    }
                    .padding(.horizontal, 10).padding(.vertical, 6)
                    .background(RoundedRectangle(cornerRadius: 8)
                        .fill(slot.id == model.slotSelection ? Theme.tileSelected : Theme.tileBG))
                }.buttonStyle(.plain)
            }
            Text("↑ ↓ to choose, Return to replace, Esc to cancel")
                .font(.system(size: 11)).foregroundStyle(.secondary)
        }
        .padding(16)
        .frame(width: 340)
        .background(RoundedRectangle(cornerRadius: 14).fill(.regularMaterial))
        .shadow(radius: 20)
    }
}
