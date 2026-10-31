import AppKit
import SwiftUI

// MARK: - Search

/// The search pill. In the library and mini window it sits in the top bar; in the quick picker
/// it is the top of the panel.
struct SearchField: View {
    @Bindable var model: PickerModel
    var focusOnAppear = true
    var large = false
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 9) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: large ? 15 : 13, weight: .medium))
                .foregroundStyle(Theme.faint)
            TextField("", text: $model.query,
                      prompt: Text(large ? "Search plugins, makers or categories" : "Search plugins").foregroundStyle(Theme.faint))
                .textFieldStyle(.plain)
                .font(.system(size: large ? 17 : 14))
                .foregroundStyle(Theme.text)
                .focused($focused)
            if !model.query.isEmpty {
                Button { model.query = "" } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(Theme.faint)
                }
                .buttonStyle(.plain)
                .help("Clear the search")
            }
        }
        .padding(.horizontal, 14)
        .frame(height: large ? 44 : Theme.control)
        .background(Capsule().fill(Theme.raised))
        .onAppear { if focusOnAppear { focused = true } }
        .onChange(of: model.query) { _, _ in focused = true }
        .onReceive(NotificationCenter.default.publisher(for: .focusSearch)) { _ in focused = true }
    }
}

/// Favorites toggle and the View popover, used in every bar.
struct ViewControls: View {
    @Bindable var model: PickerModel
    var view = ViewSettings.shared
    @State private var showOptions = false

    var body: some View {
        HStack(spacing: 2) {
            BarIconButton(systemImage: view.favoritesOnly ? "star.fill" : "star",
                          help: "Favorites only (⌘F)", active: view.favoritesOnly,
                          activeTint: Theme.accent) {
                view.favoritesOnly.toggle()
                model.selection = 0
            }
            BarIconButton(systemImage: view.layout == .grid ? "square.grid.2x2" : "list.bullet",
                          help: "View options", active: showOptions) {
                showOptions.toggle()
            }
            .popover(isPresented: $showOptions, arrowEdge: .bottom) {
                ViewOptions(model: model)
            }
        }
    }
}

/// The View popover: layout, size, sort, what to show.
struct ViewOptions: View {
    @Bindable var model: PickerModel
    @Bindable var view = ViewSettings.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            section("Layout") {
                ForEach(ViewSettings.Layout.allCases) { l in
                    Chip(title: l.title, systemImage: l.symbol, on: view.layout == l) { view.layout = l }
                }
            }
            section("Thumbnail size") {
                ForEach(ViewSettings.Size.allCases) { s in
                    Chip(title: s.title, on: view.size == s) { view.size = s }
                }
            }
            VStack(alignment: .leading, spacing: 8) {
                label("Sort by")
                FlowRow {
                    ForEach(Array(PluginSort.allCases.enumerated()), id: \.element) { i, s in
                        Chip(title: s.title, on: model.sort == s) { model.sort = s }
                            .help("⌘\(i + 1)")
                    }
                }
            }
            VStack(alignment: .leading, spacing: 10) {
                label("Show")
                toggle("Plugin name", $view.showName)
                toggle("Maker and category", $view.showDetails)
                toggle("Info panel", $view.showInfoPane)
                toggle("Favorites only", $view.favoritesOnly)
            }
        }
        .padding(20)
        .frame(width: 300, alignment: .leading)
        .background(Theme.surface)
        .preferredColorScheme(.dark)
    }

    private func label(_ t: String) -> some View {
        Text(t).font(.system(size: 12)).foregroundStyle(Theme.faint)
    }

    private func section<C: View>(_ title: String, @ViewBuilder _ content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            label(title)
            HStack(spacing: 6) { content() }
        }
    }

    private func toggle(_ title: String, _ value: Binding<Bool>) -> some View {
        Button { value.wrappedValue.toggle() } label: {
            HStack(spacing: 10) {
                CheckMark(on: value.wrappedValue)
                Text(title).font(.system(size: 13)).foregroundStyle(Theme.text)
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// Lays chips out in rows that wrap.
struct FlowRow: Layout {
    var spacing: CGFloat = 6
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? 300
        var x: CGFloat = 0, y: CGFloat = 0, row: CGFloat = 0
        for v in subviews {
            let s = v.sizeThatFits(.unspecified)
            if x + s.width > width, x > 0 { x = 0; y += row + spacing; row = 0 }
            x += s.width + spacing; row = max(row, s.height)
        }
        return CGSize(width: width, height: y + row)
    }
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, row: CGFloat = 0
        for v in subviews {
            let s = v.sizeThatFits(.unspecified)
            if x + s.width > bounds.maxX, x > bounds.minX { x = bounds.minX; y += row + spacing; row = 0 }
            v.place(at: CGPoint(x: x, y: y), proposal: .unspecified)
            x += s.width + spacing; row = max(row, s.height)
        }
    }
}

// MARK: - Pictures

/// Screenshot, a card for Logic's own plugins, or a placeholder that says why there is none.
struct PluginThumbnail: View {
    let plugin: Plugin
    var radius: CGFloat = Theme.radiusInner
    var store = PluginStore.shared

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: radius, style: .continuous).fill(Theme.cardGround)
            if store.imageGeneration >= 0, let img = store.image(for: plugin.id) {
                Image(nsImage: img)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fit)
                    .clipShape(RoundedRectangle(cornerRadius: max(4, radius - 6), style: .continuous))
                    .padding(6)
            } else if plugin.snapshotState == .builtIn {
                LogicCard(plugin: plugin)
            } else {
                VStack(spacing: 6) {
                    Text(initials)
                        .font(.system(size: 22, weight: .semibold))
                        .foregroundStyle(Theme.muted)
                    if !placeholderText.isEmpty {
                        Text(placeholderText).font(.system(size: 11)).foregroundStyle(Theme.faint)
                    }
                }
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
    }

    private var initials: String {
        let words = plugin.name.split(whereSeparator: { !$0.isLetter && !$0.isNumber })
        return words.prefix(2).compactMap { $0.first.map(String.init) }.joined().uppercased()
    }

    private var placeholderText: String {
        switch plugin.snapshotState {
        case .pending: return "Screenshot coming"
        case .noUI: return "No window of its own"
        case .failed: return "Screenshot failed"
        case .done, .builtIn: return ""
        }
    }
}

/// Logic's own plugins only run inside Logic, so they show their category's symbol and name.
struct LogicCard: View {
    let plugin: Plugin

    var body: some View {
        GeometryReader { geo in
            let side = min(geo.size.width, geo.size.height)
            VStack(spacing: side * 0.08) {
                Image(systemName: Self.symbol(for: plugin.category))
                    .font(.system(size: side * 0.24, weight: .light))
                    .foregroundStyle(Theme.muted)
                Text(plugin.name)
                    .font(.system(size: max(10, side * 0.095), weight: .medium))
                    .foregroundStyle(Theme.faint)
                    .lineLimit(1).minimumScaleFactor(0.6)
                    .padding(.horizontal, 8)
            }
            .frame(width: geo.size.width, height: geo.size.height)
        }
    }

    static func symbol(for category: String) -> String {
        switch category {
        case "Amps and Pedals": return "guitars"
        case "Delay": return "repeat"
        case "Distortion": return "bolt"
        case "Dynamics": return "waveform.path.ecg"
        case "EQ": return "slider.vertical.3"
        case "Filter": return "line.3.horizontal.decrease"
        case "Imaging": return "circle.lefthalf.filled"
        case "Metering": return "gauge.with.dots.needle.33percent"
        case "Modulation": return "water.waves"
        case "Multi Effects": return "square.stack.3d.up"
        case "Pitch": return "music.note"
        case "Reverb": return "dot.radiowaves.left.and.right"
        case "Specialized": return "sparkles"
        case "Utility": return "wrench.and.screwdriver"
        case "Synth": return "waveform"
        case "Sampler": return "square.grid.3x3"
        case "Drums": return "circle.hexagongrid"
        case "Keys": return "pianokeys"
        case "Orchestral": return "music.quarternote.3"
        case "Bass": return "guitars"
        case "MIDI FX": return "pianokeys.inverse"
        default: return "puzzlepiece.extension"
        }
    }
}

// MARK: - Tiles and rows

struct PluginTile: View {
    let plugin: Plugin
    let isSelected: Bool
    var store = PluginStore.shared
    var view = ViewSettings.shared
    @State private var hovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            PluginThumbnail(plugin: plugin)
                .aspectRatio(1.6, contentMode: .fit)
                .overlay(alignment: .topTrailing) {
                    if store.favorites.contains(plugin.id) {
                        Image(systemName: "star.fill")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(Theme.accent)
                            .padding(6)
                            .background(Circle().fill(Color.black.opacity(0.7)))
                            .padding(8)
                    }
                }
            if view.showName || view.showDetails {
                VStack(alignment: .leading, spacing: 3) {
                    if view.showName {
                        Text(plugin.name)
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(Theme.text)
                            .lineLimit(1)
                    }
                    if view.showDetails {
                        Text("\(plugin.manufacturer) · \(plugin.displayCategory)")
                            .font(.system(size: 12))
                            .foregroundStyle(Theme.faint)
                            .lineLimit(1)
                    }
                }
                .padding(.horizontal, 4)
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: Theme.radiusCard, style: .continuous)
            .fill(isSelected ? Theme.raised : (hovering ? Theme.hover : Theme.surface)))
        .overlay(RoundedRectangle(cornerRadius: Theme.radiusCard, style: .continuous)
            .strokeBorder(isSelected ? Theme.accent : .clear, lineWidth: 2))
        .contentShape(RoundedRectangle(cornerRadius: Theme.radiusCard, style: .continuous))
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.12), value: hovering)
        .help(plugin.name)
    }
}

/// One line in list layout.
struct PluginRow: View {
    let plugin: Plugin
    let isSelected: Bool
    var compact = false
    var store = PluginStore.shared
    var view = ViewSettings.shared
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 14) {
            PluginThumbnail(plugin: plugin, radius: compact ? 8 : 10)
                .frame(width: compact ? 64 : view.tileWidth * 0.55,
                       height: compact ? 40 : view.tileWidth * 0.34)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(plugin.name)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(Theme.text)
                        .lineLimit(1)
                    if store.favorites.contains(plugin.id) {
                        Image(systemName: "star.fill").font(.system(size: 9)).foregroundStyle(Theme.accent)
                    }
                }
                if view.showDetails || compact {
                    Text(plugin.isLogic ? "\(plugin.manufacturer) · \(plugin.displayCategory)"
                         : "\(plugin.manufacturer) · \(plugin.displayCategory) · \(plugin.formatName)")
                        .font(.system(size: 12)).foregroundStyle(Theme.faint).lineLimit(1)
                }
                if !compact, let best = plugin.details?.bestFeature, !best.isEmpty {
                    Text(best).font(.system(size: 12)).foregroundStyle(Theme.muted).lineLimit(1)
                }
            }
            Spacer(minLength: 0)
            if isSelected && compact {
                KeyCap(key: "↩")
            }
        }
        .padding(.horizontal, compact ? 8 : 10)
        .frame(height: compact ? 54 : nil)
        .padding(.vertical, compact ? 0 : 8)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous)
            .fill(isSelected ? Theme.raised : (hovering ? Theme.hover : Color.clear)))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
            .strokeBorder(isSelected ? Theme.accent : .clear, lineWidth: 2))
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
    }
}

/// Grid or list of plugins that keeps the selection in view and tells the model how many
/// columns there are, so the arrow keys move the right way.
struct PluginGrid: View {
    @Bindable var model: PickerModel
    var compact = false
    var onActivate: () -> Void
    var view = ViewSettings.shared
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let results = model.results
        GeometryReader { geo in
            let spacing = Theme.gap
            let inset: CGFloat = compact ? 8 : 18
            let asList = compact || view.layout == .list
            let columns = asList ? 1
                : max(1, Int((geo.size.width - inset * 2 + spacing) / (view.tileWidth + spacing)))
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
                            LazyVStack(spacing: compact ? 2 : 4) {
                                items(results) { plugin, selected in
                                    PluginRow(plugin: plugin, isSelected: selected, compact: compact)
                                }
                            }
                        }
                    }
                    .padding(inset)
                    // While typing, plugins that stop matching fade and shrink away and the rest
                    // glide into their new places (BL-23).
                    .animation(reduceMotion ? nil : .spring(duration: 0.34, bounce: 0.1),
                               value: results.map(\.id))
                }
                .scrollIndicators(.automatic)
                .onChange(of: model.selection) { _, new in
                    if results.indices.contains(new) {
                        withAnimation(.easeOut(duration: 0.14)) { proxy.scrollTo(results[new].id) }
                    }
                }
                .onAppear { model.columns = columns }
                .onChange(of: columns) { _, c in model.columns = c }
            }
            .overlay {
                if results.isEmpty { emptyState }
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: view.favoritesOnly ? "star" : "magnifyingglass")
                .font(.system(size: 26, weight: .light))
                .foregroundStyle(Theme.faint)
            Text(emptyText).font(.system(size: 14)).foregroundStyle(Theme.muted)
                .multilineTextAlignment(.center)
        }
        .padding(30)
    }

    private var emptyText: String {
        if PluginStore.shared.plugins.isEmpty { return "Scanning your plugins…" }
        if view.favoritesOnly && model.query.isEmpty { return "No favorites yet.\nSelect a plugin and press ⌘D." }
        return "Nothing matches “\(model.query)”"
    }

    @ViewBuilder
    private func items<Cell: View>(_ results: [Plugin],
                                   @ViewBuilder cell: @escaping (Plugin, Bool) -> Cell) -> some View {
        ForEach(Array(results.enumerated()), id: \.element.id) { i, plugin in
            cell(plugin, i == model.selection)
                .id(plugin.id)
                .transition(.asymmetric(
                    insertion: .opacity.combined(with: .scale(scale: 0.94)),
                    removal: .opacity.combined(with: .scale(scale: 0.88))))
                .onTapGesture(count: 2) { model.selection = i; onActivate() }
                .onTapGesture { model.selection = i }
                .contextMenu { PluginContextMenu(plugin: plugin, select: { model.selection = i }, insert: onActivate) }
                // Drag onto a collection chip to add it there (BL-60).
                .draggable(PluginDrag.prefix + plugin.id) {
                    HStack(spacing: 8) {
                        PluginThumbnail(plugin: plugin, radius: 6).frame(width: 54, height: 36)
                        Text(plugin.name).font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.text)
                    }
                    .padding(8)
                    .background(RoundedRectangle(cornerRadius: 10).fill(Theme.raised))
                }
        }
    }
}

// MARK: - The info rail

/// The right-hand rail. Insert sits pinned at the top and never scrolls away; below it the
/// screenshot, what the plugin is, its best feature and the details.
struct PluginDetailView: View {
    let plugin: Plugin
    @Bindable var model: PickerModel
    var onInsert: () -> Void
    var store = PluginStore.shared
    var fetcher = PluginInfoFetcher.shared

    var body: some View {
        VStack(spacing: 0) {
            insertBar
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    PluginThumbnail(plugin: plugin, radius: 16)
                        .aspectRatio(1.5, contentMode: .fit)
                    titleBlock
                    if let d = plugin.details { info(d) } else { noInfo }
                    PluginExtras(plugin: plugin, model: model)
                    detailsList
                }
                .padding(.horizontal, 18).padding(.bottom, 22).padding(.top, 4)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .scrollIndicators(.never)
        }
        .background(Theme.ground)
    }

    private var insertBar: some View {
        VStack(spacing: 10) {
            HStack(spacing: 8) {
                PrimaryPill(title: model.isBusy ? "Adding to Logic…" : insertTitle,
                            systemImage: "plus", hint: "↩", busy: model.isBusy, fullWidth: true,
                            height: 40, action: onInsert)
                    .disabled(model.isBusy)
                    .help("Add \(plugin.name) to the selected track in Logic")
                BarIconButton(systemImage: store.favorites.contains(plugin.id) ? "star.fill" : "star",
                              help: "Favorite (⌘D)", active: store.favorites.contains(plugin.id),
                              activeTint: Theme.accent) {
                    store.toggleFavorite(plugin.id)
                }
            }
            if let message = model.message {
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 12)).foregroundStyle(Theme.warning)
                        .padding(.top, 1)
                    VStack(alignment: .leading, spacing: 8) {
                        Text(message).font(.system(size: 12)).foregroundStyle(Theme.text)
                            .fixedSize(horizontal: false, vertical: true)
                        if model.showAccessibilityButton {
                            QuietPill(title: "Allow in System Settings", height: 26) { AXAccess.openSettings() }
                        }
                    }
                    Spacer(minLength: 0)
                    Button { model.message = nil } label: {
                        Image(systemName: "xmark").font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(Theme.faint)
                    }
                    .buttonStyle(.plain)
                }
                .padding(12)
                .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Theme.warningGround))
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .padding(18)
        .animation(.easeOut(duration: 0.18), value: model.message)
    }

    private var insertTitle: String {
        plugin.slotKind == .instrument ? "Load as Instrument" : "Insert in Logic"
    }

    private var titleBlock: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(plugin.name)
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(Theme.text)
                .lineLimit(2)
            Text("\(plugin.manufacturer) · \(plugin.displayCategory) · \(plugin.typeGroup)")
                .font(.system(size: 13)).foregroundStyle(Theme.faint)
            if let kind = plugin.details?.kind, !kind.isEmpty {
                Text(kind).font(.system(size: 14, weight: .medium)).foregroundStyle(Theme.muted)
                    .padding(.top, 2)
            }
        }
    }

    private func info(_ d: PluginDetails) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            if !d.bestFeature.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 6) {
                        Circle().fill(Theme.accent).frame(width: 6, height: 6)
                        Text("Best feature").font(.system(size: 12)).foregroundStyle(Theme.faint)
                    }
                    Text(d.bestFeature)
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(Theme.text)
                        .lineSpacing(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Theme.surface))
            }
            Text(d.summary)
                .font(.system(size: 13)).foregroundStyle(Theme.muted)
                .lineSpacing(3).fixedSize(horizontal: false, vertical: true)
            if !d.highlights.isEmpty {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(d.highlights, id: \.self) { h in
                        HStack(alignment: .top, spacing: 10) {
                            Image(systemName: "checkmark")
                                .font(.system(size: 10, weight: .bold)).foregroundStyle(Theme.faint)
                                .padding(.top, 3)
                            Text(h).font(.system(size: 13)).foregroundStyle(Theme.text)
                                .fixedSize(horizontal: false, vertical: true)
                            Spacer(minLength: 0)
                        }
                        .padding(.vertical, 8)
                        if h != d.highlights.last { Rectangle().fill(Theme.rule).frame(height: 1) }
                    }
                }
            }
        }
    }

    @ViewBuilder private var noInfo: some View {
        if let err = fetcher.failures[plugin.id] {
            Text("Info lookup failed: \(err)").font(.system(size: 12)).foregroundStyle(Theme.negative)
        } else {
            HStack(spacing: 10) {
                Image(systemName: "sparkles").font(.system(size: 13)).foregroundStyle(Theme.faint)
                Text("No description yet. Right-click the plugin and choose Look Up Info.")
                    .font(.system(size: 12)).foregroundStyle(Theme.faint)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Theme.surface))
        }
    }

    private var detailsList: some View {
        VStack(spacing: 0) {
            row("Format", plugin.isLogic ? "Built into Logic Pro" : plugin.formatName)
            row("Version", plugin.isLogic ? "Logic Pro \(plugin.version)" : plugin.version)
            if let n = plugin.parameterCount { row("Parameters", "\(n)") }
            if !plugin.tags.isEmpty { row("Tags", plugin.tags.joined(separator: ", ")) }
            if plugin.snapshotState == .failed, let e = plugin.snapshotError { row("Screenshot", e) }
        }
    }

    private func row(_ k: String, _ v: String) -> some View {
        VStack(spacing: 0) {
            Rectangle().fill(Theme.rule).frame(height: 1)
            HStack(alignment: .top) {
                Text(k).foregroundStyle(Theme.faint)
                Spacer(minLength: 12)
                Text(v).foregroundStyle(Theme.muted).multilineTextAlignment(.trailing)
                    .monospacedDigit().textSelection(.enabled)
            }
            .font(.system(size: 12))
            .padding(.vertical, 9)
        }
    }
}

// MARK: - Replace chooser and right-click

/// Shown when the slot is taken: pick the one to replace (↑ ↓ and Return).
struct SlotChooser: View {
    @Bindable var model: PickerModel
    var onChoose: (Int) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(model.selected?.slotKind == .instrument ? "Replace the instrument?" : "Replace which insert?")
                .font(.system(size: 16, weight: .semibold)).foregroundStyle(Theme.text)
            if let message = model.message {
                Text(message).font(.system(size: 12)).foregroundStyle(Theme.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            VStack(spacing: 4) {
                ForEach(model.slotChoices ?? []) { slot in
                    Button { onChoose(slot.id) } label: {
                        HStack(spacing: 10) {
                            Text("\(slot.id + 1)").monospacedDigit().foregroundStyle(Theme.faint)
                                .frame(width: 18)
                            Text(slot.name).foregroundStyle(Theme.text)
                            Spacer()
                            if slot.id == model.slotSelection { KeyCap(key: "↩") }
                        }
                        .font(.system(size: 13))
                        .padding(.horizontal, 12).frame(height: 36)
                        .background(RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(slot.id == model.slotSelection ? Theme.raised : Theme.surface))
                    }
                    .buttonStyle(.plain)
                }
            }
            HStack(spacing: 6) {
                KeyCap(key: "↑↓"); Text("choose").foregroundStyle(Theme.faint)
                KeyCap(key: "↩"); Text("replace").foregroundStyle(Theme.faint)
                KeyCap(key: "esc"); Text("cancel").foregroundStyle(Theme.faint)
            }
            .font(.system(size: 11))
        }
        .padding(20)
        .frame(width: 360)
        .background(RoundedRectangle(cornerRadius: Theme.radiusCard, style: .continuous).fill(Theme.surface))
        .shadow(color: .black.opacity(0.5), radius: 30, y: 10)   // it floats over the grid
    }
}

/// Right-click on a plugin.
struct PluginContextMenu: View {
    let plugin: Plugin
    var select: () -> Void
    var insert: () -> Void
    var store = PluginStore.shared

    var body: some View {
        Button(plugin.slotKind == .instrument ? "Load as Instrument" : "Insert in Logic") { select(); insert() }
        Button(store.favorites.contains(plugin.id) ? "Remove from Favorites" : "Add to Favorites") {
            store.toggleFavorite(plugin.id)
        }
        Divider()
        TrackMenuItems(plugin: plugin)
        Divider()
        if !plugin.isLogic {
            Button(plugin.snapshotState == .done ? "Retake Screenshot" : "Take Screenshot") {
                SnapshotQueue.shared.recapture(plugin.id)
            }
            .disabled(SnapshotQueue.shared.isRunning)
            Button("Clear Screenshot") { store.clearScreenshots([plugin.id]) }
                .disabled(store.image(for: plugin.id) == nil)
        }
        Button(plugin.details == nil ? "Look Up Info" : "Look Up Info Again") {
            PluginInfoFetcher.shared.start(ids: [plugin.id])
        }
        .disabled(PluginInfoFetcher.shared.isRunning || !PluginInfoFetcher.shared.canLookUp)
        Divider()
        Menu("Add to Chain") {
            ForEach(UserLibrary.shared.chains) { c in
                Button(c.name) { UserLibrary.shared.addToChain(c.id, plugin.id) }
            }
            if !UserLibrary.shared.chains.isEmpty { Divider() }
            Button("New Chain…") {
                if let n = NamePrompt.ask("New chain", placeholder: "For example Vocal chain") {
                    UserLibrary.shared.newChain(named: n, with: [plugin.id])
                }
            }
        }
        Menu("Collections") {
            ForEach(UserLibrary.shared.collections) { c in
                Button((c.pluginIDs.contains(plugin.id) ? "✓ " : "") + c.name) { UserLibrary.shared.toggle(plugin.id, in: c.id) }
            }
            if !UserLibrary.shared.collections.isEmpty { Divider() }
            Button("New Collection…") {
                if let n = NamePrompt.ask("New collection", placeholder: "For example Mix bus") {
                    UserLibrary.shared.collections.append(.init(name: n, pluginIDs: [plugin.id]))
                }
            }
        }
        Menu("Pin to Key") {
            let mine = UserLibrary.shared.key(for: .plugin(plugin.id))
            ForEach(1...9, id: \.self) { n in
                Button((mine == n ? "✓ " : "") + HotKey.pinDisplay(n)) {
                    UserLibrary.shared.pin(n, to: mine == n ? nil : .plugin(plugin.id))
                }
            }
        }
        Divider()
        Button("Hide This Plugin") { store.setPlugin(plugin.id, visible: false) }
    }
}

extension Notification.Name {
    static let focusSearch = Notification.Name("AGPFFocusSearch")
}

/// What a dragged plugin carries: its id, marked so other dropped text is ignored.
enum PluginDrag {
    static let prefix = "agplugfinder-plugin:"
    static func ids(_ items: [String]) -> [String] {
        items.filter { $0.hasPrefix(prefix) }.map { String($0.dropFirst(prefix.count)) }
    }
}
