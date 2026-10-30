import AppKit
import SwiftUI

enum Theme {
    static let accent = Color(red: 0.98, green: 0.62, blue: 0.22)
    static let tileBG = Color.primary.opacity(0.05)
    static let tileSelected = Color(red: 0.98, green: 0.62, blue: 0.22).opacity(0.22)
}

/// Search field + the View button (layout, size, what to show, sort, favorites only).
struct SearchBar: View {
    @Bindable var model: PickerModel
    var focusOnAppear = true
    var compact = false
    @FocusState private var focused: Bool
    @State private var showOptions = false
    var view = ViewSettings.shared

    var body: some View {
        HStack(spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Search plugins, makers or categories", text: $model.query)
                    .textFieldStyle(.plain)
                    .font(.system(size: compact ? 14 : 17))
                    .focused($focused)
                if !model.query.isEmpty {
                    Button { model.query = "" } label: {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                    }.buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 12).padding(.vertical, 9)
            .background(RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(0.07)))

            if !compact {
            Button { view.favoritesOnly.toggle() } label: {
                Image(systemName: view.favoritesOnly ? "star.fill" : "star")
                    .foregroundStyle(view.favoritesOnly ? Theme.accent : .secondary)
                    .frame(width: 34, height: 34)
                    .background(RoundedRectangle(cornerRadius: 9).fill(Color.primary.opacity(0.07)))
            }
            .buttonStyle(.plain)
            .help("Favorites only (⌘F)")

            Button { showOptions.toggle() } label: {
                HStack(spacing: 6) {
                    Image(systemName: view.layout.symbol)
                    Text("View")
                    Image(systemName: "chevron.down").font(.system(size: 9, weight: .bold))
                }
                .font(.system(size: 13, weight: .medium))
                .padding(.horizontal, 12).frame(height: 34)
                .background(RoundedRectangle(cornerRadius: 9).fill(Color.primary.opacity(0.07)))
            }
            .buttonStyle(.plain)
            .popover(isPresented: $showOptions, arrowEdge: .bottom) {
                ViewOptions(model: model)
            }
            }
        }
        .onAppear { if focusOnAppear { focused = true } }
        .onChange(of: model.query) { _, _ in focused = true }
    }
}

/// The View popover. Every choice is a themed button, no system menus.
struct ViewOptions: View {
    @Bindable var model: PickerModel
    @Bindable var view = ViewSettings.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            section("Layout") {
                ForEach(ViewSettings.Layout.allCases) { l in
                    chip(l.title, symbol: l.symbol, on: view.layout == l) { view.layout = l }
                }
            }
            section("Thumbnail size") {
                ForEach(ViewSettings.Size.allCases) { s in
                    chip(s.title, on: view.size == s) { view.size = s }
                }
            }
            section("Sort by") {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(Array(PluginSort.allCases.enumerated()), id: \.element) { i, s in
                        chip("\(s.title)   ⌘\(i + 1)", on: model.sort == s) { model.sort = s }
                    }
                }
            }
            section("Show") {
                VStack(alignment: .leading, spacing: 4) {
                    toggle("Plugin name", $view.showName)
                    toggle("Maker and category", $view.showDetails)
                    toggle("Info panel on the right", $view.showInfoPane)
                    toggle("Favorites only", $view.favoritesOnly)
                }
            }
        }
        .padding(16)
        .frame(width: 270)
    }

    private func section<C: View>(_ title: String, @ViewBuilder _ content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title.uppercased()).font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary)
            HStack(spacing: 4) { content() }
        }
    }

    private func chip(_ title: String, symbol: String? = nil, on: Bool, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 5) {
                if let symbol { Image(systemName: symbol) }
                Text(title)
            }
            .font(.system(size: 12, weight: on ? .semibold : .regular))
            .padding(.horizontal, 10).padding(.vertical, 5)
            .background(Capsule().fill(on ? Theme.accent.opacity(0.85) : Color.primary.opacity(0.06)))
            .foregroundStyle(on ? Color.black : Color.primary)
        }
        .buttonStyle(.plain)
    }

    private func toggle(_ title: String, _ value: Binding<Bool>) -> some View {
        Button { value.wrappedValue.toggle() } label: {
            HStack(spacing: 8) {
                Image(systemName: value.wrappedValue ? "checkmark.square.fill" : "square")
                    .foregroundStyle(value.wrappedValue ? Theme.accent : .secondary)
                Text(title).foregroundStyle(Color.primary)
            }
            .font(.system(size: 12))
        }
        .buttonStyle(.plain)
    }
}

/// Screenshot, a category card for Logic's own plugins, or a placeholder that says why there is none.
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
            } else if plugin.snapshotState == .builtIn {
                LogicCard(plugin: plugin)
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
        case .done, .builtIn: return ""
        }
    }
}

/// Card for Logic's own plugins: an icon for the category on a tinted background.
struct LogicCard: View {
    let plugin: Plugin

    var body: some View {
        GeometryReader { geo in
            let side = min(geo.size.width, geo.size.height)
            ZStack {
                LinearGradient(colors: [tint.opacity(0.55), tint.opacity(0.18)],
                               startPoint: .topLeading, endPoint: .bottomTrailing)
                VStack(spacing: side * 0.06) {
                    Image(systemName: symbol)
                        .font(.system(size: side * 0.32, weight: .medium))
                        .foregroundStyle(.white.opacity(0.92))
                    Text(plugin.name)
                        .font(.system(size: max(9, side * 0.1), weight: .semibold))
                        .foregroundStyle(.white.opacity(0.85))
                        .lineLimit(1).minimumScaleFactor(0.6)
                        .padding(.horizontal, 6)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .padding(3)
        }
    }

    private var symbol: String {
        switch plugin.category {
        case "Amps and Pedals": return "guitars"
        case "Delay": return "repeat"
        case "Distortion": return "bolt.fill"
        case "Dynamics": return "waveform.path.ecg"
        case "EQ": return "slider.vertical.3"
        case "Filter": return "line.3.horizontal.decrease"
        case "Imaging": return "circle.lefthalf.filled"
        case "Metering": return "gauge.with.dots.needle.33percent"
        case "Modulation": return "water.waves"
        case "Multi Effects": return "square.stack.3d.up.fill"
        case "Pitch": return "music.note"
        case "Reverb": return "dot.radiowaves.left.and.right"
        case "Specialized": return "sparkles"
        case "Utility": return "wrench.and.screwdriver"
        case "Synth": return "waveform"
        case "Sampler": return "square.grid.3x3.fill"
        case "Drums": return "circle.hexagongrid.fill"
        case "Keys": return "pianokeys"
        case "Orchestral": return "music.quarternote.3"
        case "Bass": return "guitars.fill"
        case "MIDI FX": return "pianokeys.inverse"
        default: return "puzzlepiece.extension"
        }
    }

    private var tint: Color {
        let palette: [Color] = [.orange, .pink, .purple, .blue, .teal, .green, .indigo, .red, .mint, .cyan]
        let h = plugin.category.unicodeScalars.reduce(0) { ($0 &* 31 &+ Int($1.value)) & 0xFFFF }
        return palette[h % palette.count]
    }
}

struct PluginTile: View {
    let plugin: Plugin
    let isSelected: Bool
    var store = PluginStore.shared
    var view = ViewSettings.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            PluginThumbnail(plugin: plugin)
                .frame(height: view.size.tileWidth * 0.6)
                .overlay(alignment: .topTrailing) {
                    if !view.showName && store.favorites.contains(plugin.id) { star.padding(6) }
                }
            if view.showName {
                HStack(spacing: 4) {
                    Text(plugin.name).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                    Spacer(minLength: 0)
                    if store.favorites.contains(plugin.id) { star }
                }
            }
            if view.showDetails {
                Text("\(plugin.manufacturer) · \(plugin.displayCategory)")
                    .font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
            }
        }
        .padding(view.showName || view.showDetails ? 8 : 5)
        .background(RoundedRectangle(cornerRadius: 12).fill(isSelected ? Theme.tileSelected : Theme.tileBG))
        .overlay(RoundedRectangle(cornerRadius: 12)
            .strokeBorder(isSelected ? Theme.accent : Color.clear, lineWidth: 2))
        .contentShape(RoundedRectangle(cornerRadius: 12))
        .help(plugin.name)
    }

    private var star: some View {
        Image(systemName: "star.fill").font(.system(size: 10)).foregroundStyle(Theme.accent)
    }
}

/// One line in list layout.
struct PluginRow: View {
    let plugin: Plugin
    let isSelected: Bool
    var compact = false
    var store = PluginStore.shared
    var view = ViewSettings.shared

    var body: some View {
        HStack(spacing: 12) {
            PluginThumbnail(plugin: plugin)
                .frame(width: compact ? 64 : view.size.tileWidth * 0.6,
                       height: compact ? 38 : view.size.tileWidth * 0.36)
            VStack(alignment: .leading, spacing: 3) {
                if view.showName {
                    HStack(spacing: 5) {
                        Text(plugin.name).font(.system(size: 14, weight: .semibold))
                        if store.favorites.contains(plugin.id) {
                            Image(systemName: "star.fill").font(.system(size: 10)).foregroundStyle(Theme.accent)
                        }
                    }
                }
                if view.showDetails {
                    Text(plugin.isLogic ? "\(plugin.manufacturer) · \(plugin.displayCategory)"
                         : "\(plugin.manufacturer) · \(plugin.displayCategory) · \(plugin.formatName)")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                }
                if !compact, let best = plugin.details?.bestFeature, !best.isEmpty {
                    Text(best).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 10).fill(isSelected ? Theme.tileSelected : Color.clear))
        .overlay(RoundedRectangle(cornerRadius: 10)
            .strokeBorder(isSelected ? Theme.accent : Color.clear, lineWidth: 2))
        .contentShape(Rectangle())
    }
}

/// Grid or list of plugins that keeps the selection in view and tells the model how many
/// columns there are, so the arrow keys move the right way.
struct PluginGrid: View {
    @Bindable var model: PickerModel
    var compact = false
    var onActivate: () -> Void
    var view = ViewSettings.shared

    var body: some View {
        let results = model.results
        GeometryReader { geo in
            let spacing: CGFloat = 10
            let asList = compact || view.layout == .list
            let columns = asList ? 1
                : max(1, Int((geo.size.width - 24 + spacing) / (view.size.tileWidth + spacing)))
            ScrollViewReader { proxy in
                ScrollView {
                    Group {
                        if !asList {
                            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: spacing),
                                                     count: columns), spacing: spacing) {
                                items(results) { plugin, selected in
                                    PluginTile(plugin: plugin, isSelected: selected)
                                }
                            }
                        } else {
                            LazyVStack(spacing: 2) {
                                items(results) { plugin, selected in
                                    PluginRow(plugin: plugin, isSelected: selected, compact: compact)
                                }
                            }
                        }
                    }
                    .padding(12)
                }
                .onChange(of: model.selection) { _, new in
                    if results.indices.contains(new) {
                        withAnimation(.easeOut(duration: 0.12)) { proxy.scrollTo(results[new].id) }
                    }
                }
                .onAppear { model.columns = columns }
                .onChange(of: columns) { _, c in model.columns = c }
            }
            .overlay {
                if results.isEmpty {
                    Text(emptyText).foregroundStyle(.secondary)
                }
            }
        }
    }

    private var emptyText: String {
        if PluginStore.shared.plugins.isEmpty { return "Scanning plugins…" }
        if view.favoritesOnly && model.query.isEmpty { return "No favorites yet. Press ⌘D on a plugin to add it." }
        return "No plugins match"
    }

    @ViewBuilder
    private func items<Cell: View>(_ results: [Plugin],
                                   @ViewBuilder cell: @escaping (Plugin, Bool) -> Cell) -> some View {
        ForEach(Array(results.enumerated()), id: \.element.id) { i, plugin in
            cell(plugin, i == model.selection)
                .id(plugin.id)
                .onTapGesture(count: 2) { model.selection = i; onActivate() }
                .onTapGesture { model.selection = i }
        }
    }
}

/// The right-hand pane. The Insert button is pinned at the top and never scrolls away; below it
/// the screenshot, what the plugin is, its best feature and the details.
struct PluginDetailView: View {
    let plugin: Plugin
    @Bindable var model: PickerModel
    var onInsert: () -> Void
    var store = PluginStore.shared
    var fetcher = PluginInfoFetcher.shared

    var body: some View {
        VStack(spacing: 0) {
            insertBar
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    PluginThumbnail(plugin: plugin)
                        .frame(height: 180)
                        .shadow(color: .black.opacity(0.25), radius: 10, y: 4)
                    titleBlock
                    if let d = plugin.details { info(d) } else { noInfo }
                    detailsCard
                }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    // MARK: Pinned top bar

    private var insertBar: some View {
        VStack(spacing: 8) {
            HStack(spacing: 8) {
                Button(action: onInsert) {
                    HStack(spacing: 8) {
                        if model.isBusy {
                            ProgressView().controlSize(.small).tint(.black)
                        } else {
                            Image(systemName: "plus.rectangle.on.rectangle")
                        }
                        Text(model.isBusy ? "Adding to Logic…" : "Insert in Logic")
                            .font(.system(size: 14, weight: .semibold))
                        Spacer(minLength: 0)
                        Text("↩").font(.system(size: 13, weight: .bold)).opacity(0.6)
                    }
                    .padding(.horizontal, 14).frame(height: 38)
                    .foregroundStyle(Color.black)
                    .background(
                        RoundedRectangle(cornerRadius: 10)
                            .fill(LinearGradient(colors: [Theme.accent, Theme.accent.opacity(0.8)],
                                                 startPoint: .top, endPoint: .bottom)))
                    .shadow(color: Theme.accent.opacity(0.35), radius: 6, y: 2)
                }
                .buttonStyle(.plain)
                .disabled(model.isBusy)
                .help("Place \(plugin.name) in the first empty insert of the selected track")

                Button { store.toggleFavorite(plugin.id) } label: {
                    Image(systemName: store.favorites.contains(plugin.id) ? "star.fill" : "star")
                        .font(.system(size: 15))
                        .foregroundStyle(store.favorites.contains(plugin.id) ? Theme.accent : .secondary)
                        .frame(width: 38, height: 38)
                        .background(RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(0.07)))
                }
                .buttonStyle(.plain)
                .help("Favorite (⌘D)")
            }
            if let message = model.message {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    VStack(alignment: .leading, spacing: 6) {
                        Text(message).font(.system(size: 12)).fixedSize(horizontal: false, vertical: true)
                        if model.showAccessibilityButton {
                            Button("Allow Access in System Settings") { AXAccess.openSettings() }
                                .controlSize(.small)
                        }
                    }
                    Spacer(minLength: 0)
                    Button { model.message = nil } label: { Image(systemName: "xmark").font(.system(size: 10)) }
                        .buttonStyle(.plain).foregroundStyle(.secondary)
                }
                .padding(10)
                .background(RoundedRectangle(cornerRadius: 10).fill(Color.orange.opacity(0.12)))
            }
        }
        .padding(12)
    }

    // MARK: Content

    private var titleBlock: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(plugin.name).font(.system(size: 22, weight: .bold)).lineLimit(2)
            HStack(spacing: 6) {
                pill(plugin.manufacturer, systemImage: "building.2")
                pill(plugin.displayCategory, systemImage: "tag")
                pill(plugin.typeGroup, systemImage: plugin.slotKind == .instrument ? "pianokeys" : "waveform")
            }
            if let kind = plugin.details?.kind, !kind.isEmpty {
                Text(kind).font(.system(size: 13, weight: .medium)).foregroundStyle(Theme.accent)
            }
        }
    }

    private func info(_ d: PluginDetails) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            if !d.bestFeature.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Label("Best feature", systemImage: "sparkles")
                        .font(.system(size: 11, weight: .bold)).foregroundStyle(Theme.accent)
                    Text(d.bestFeature).font(.system(size: 13, weight: .medium))
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 12)
                    .fill(LinearGradient(colors: [Theme.accent.opacity(0.18), Theme.accent.opacity(0.06)],
                                         startPoint: .topLeading, endPoint: .bottomTrailing)))
                .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Theme.accent.opacity(0.3)))
            }
            Text(d.summary).font(.system(size: 13)).foregroundStyle(.primary.opacity(0.85))
                .lineSpacing(2).fixedSize(horizontal: false, vertical: true)
            if !d.highlights.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(d.highlights, id: \.self) { h in
                        HStack(alignment: .top, spacing: 8) {
                            Image(systemName: "checkmark.circle.fill").foregroundStyle(Theme.accent)
                                .font(.system(size: 12))
                            Text(h).font(.system(size: 12)).fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder private var noInfo: some View {
        if let err = fetcher.failures[plugin.id] {
            Text("Info lookup failed: \(err)").font(.system(size: 12)).foregroundStyle(.red)
        } else {
            HStack(spacing: 8) {
                Image(systemName: "sparkles").foregroundStyle(.secondary)
                Text("No info yet. Use Look Up Info in the toolbar.")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
            }
        }
    }

    private var detailsCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            meta("Format", plugin.isLogic ? "Built into Logic Pro" : plugin.formatName)
            meta("Version", plugin.isLogic ? "Logic Pro \(plugin.version)" : plugin.version)
            if let n = plugin.parameterCount { meta("Parameters", "\(n)") }
            if !plugin.tags.isEmpty { meta("Tags", plugin.tags.joined(separator: ", ")) }
            if plugin.snapshotState == .failed, let e = plugin.snapshotError { meta("Screenshot", e) }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color.primary.opacity(0.04)))
    }

    private func pill(_ text: String, systemImage: String) -> some View {
        Label(text, systemImage: systemImage)
            .font(.system(size: 11, weight: .medium))
            .lineLimit(1)
            .padding(.horizontal, 8).padding(.vertical, 4)
            .background(Capsule().fill(Color.primary.opacity(0.07)))
    }

    private func meta(_ k: String, _ v: String) -> some View {
        HStack(alignment: .top) {
            Text(k).foregroundStyle(.secondary).frame(width: 80, alignment: .leading)
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
            Text(model.selected?.slotKind == .instrument ? "Replace the instrument?" : "Replace which insert?")
                .font(.headline)
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
