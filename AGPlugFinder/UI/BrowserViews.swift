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
        .onAppear { if focusOnAppear { focused = true }; EnglishKeys.apply() }
        .onChange(of: focused) { _, on in if on { EnglishKeys.apply(); model.keysOnPlugins = false } }
        .onChange(of: model.query) { _, q in
            focused = true
            // Typed with a Hebrew keyboard: read the keys as the English letters they sit on.
            let english = EnglishKeys.fromHebrewKeys(q)
            if english != q { model.query = english }
        }
        .onReceive(NotificationCenter.default.publisher(for: .focusSearch)) { _ in focused = true }
        .onReceive(NotificationCenter.default.publisher(for: .typeInSearch)) { n in
            // A letter typed while the keyboard was on the plugins (BL-106): back to the search,
            // with the letter added at the end.
            guard (n.object as? PickerModel) === model, let chars = n.userInfo?["chars"] as? String else { return }
            focused = false
            DispatchQueue.main.async {
                focused = true
                if chars == "\u{7F}" { if !model.query.isEmpty { model.query.removeLast() } } else { model.query += chars }
                DispatchQueue.main.async {
                    (NSApp.keyWindow?.firstResponder as? NSTextView)?.moveToEndOfDocument(nil)
                }
            }
        }
    }
}

/// Favorites toggle and the View popover, used in every bar.
struct ViewControls: View {
    @Bindable var model: PickerModel
    var view = ViewSettings.shared
    @State private var showOptions = false

    var body: some View {
        HStack(spacing: 2) {
            BarIconButton(systemImage: "plus.rectangle.on.rectangle", help: "New collection") { newCollection() }
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

extension ViewControls {
    /// Makes an empty collection and shows it, so plugins can be dragged onto its chip.
    func newCollection() {
        guard let name = NamePrompt.ask("New collection", placeholder: "For example Mix bus") else { return }
        let c = UserLibrary.Collection(name: name, pluginIDs: [])
        UserLibrary.shared.collections.append(c)
        if !view.chipRow.showsCollections { view.chipRow = .both }
        Toast.show("Made \(name). Drag plugins onto it at the top to add them.")
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
            QuietPill(title: "Edit Pills…", systemImage: "line.3.horizontal.decrease", height: 28) { PillsWindow.shared.show() }
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
                // Small cards have no room beside the name: the star sits on the picture's corner.
                .overlay(alignment: .topTrailing) {
                    if view.tileWidth < ViewSettings.smallestCards || !(view.showName || view.showDetails) {
                        FavoriteStar(plugin: plugin, cardHovered: hovering).scaleEffect(0.85).padding(-4)
                    }
                }

            if view.showName || view.showDetails {
                HStack(alignment: .bottom, spacing: 4) {
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
                    .frame(maxWidth: .infinity, alignment: .leading)
                    // The star sits in the bottom-right corner, beside the text; small cards
                    // have no room for it (the info panel's star still works).
                    if view.tileWidth >= ViewSettings.smallestCards {
                        FavoriteStar(plugin: plugin, cardHovered: hovering).padding(-6)
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
    // Selection box (BL-97): drag on empty space to pick every plugin it touches.
    @State private var frames: [String: CGRect] = [:]
    @State private var band: CGRect?
    @State private var bandBase: Set<String> = []

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
                    .frame(minHeight: geo.size.height, alignment: .top)
                    .coordinateSpace(.named(Self.space))
                    .onPreferenceChange(TileFrames.self) { frames = $0 }
                    .background {
                        Color.clear.contentShape(Rectangle())
                            .onTapGesture { model.picked = [] }
                            .gesture(bandGesture(results))
                    }
                    .overlay(alignment: .topLeading) {
                        if let band {
                            Rectangle().fill(Theme.accent.opacity(0.12))
                                .overlay(Rectangle().strokeBorder(Theme.accent, lineWidth: 1))
                                .frame(width: band.width, height: band.height)
                                .offset(x: band.minX, y: band.minY)
                                .allowsHitTesting(false)
                        }
                    }
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
            .overlay(alignment: .bottom) { PickedBar(model: model) }
            .animation(.easeOut(duration: 0.18), value: model.picked.count > 1)
        }
    }

    static let space = "pluginGrid"

    /// Drag from empty space: a box that picks every plugin it touches. ⌘ or ⇧ adds to the
    /// plugins already picked.
    private func bandGesture(_ results: [Plugin]) -> some Gesture {
        DragGesture(minimumDistance: 4, coordinateSpace: .named(Self.space))
            .onChanged { v in
                if band == nil {
                    let mods = NSEvent.modifierFlags
                    bandBase = mods.contains(.command) || mods.contains(.shift) ? model.picked : []
                }
                let r = CGRect(x: min(v.startLocation.x, v.location.x), y: min(v.startLocation.y, v.location.y),
                               width: abs(v.location.x - v.startLocation.x), height: abs(v.location.y - v.startLocation.y))
                band = r
                let hits = Set(frames.filter { $0.value.intersects(r) }.map(\.key))
                let next = bandBase.union(hits)
                if next != model.picked { model.picked = next }
            }
            .onEnded { _ in
                band = nil
                if let first = results.firstIndex(where: { model.picked.contains($0.id) }) { model.selection = first }
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
                .background(GeometryReader { g in
                    Color.clear.preference(key: TileFrames.self, value: [plugin.id: g.frame(in: .named(Self.space))])
                })
                .transition(.asymmetric(
                    insertion: .opacity.combined(with: .scale(scale: 0.94)),
                    removal: .opacity.combined(with: .scale(scale: 0.88))))
                .overlay {
                    if model.picked.contains(plugin.id) {
                        RoundedRectangle(cornerRadius: Theme.radiusCard, style: .continuous)
                            .strokeBorder(Theme.accent, lineWidth: 2)
                            .overlay(alignment: .topLeading) {
                                Image(systemName: "checkmark.circle.fill")
                                    .font(.system(size: 16)).foregroundStyle(Color.black, Theme.accent)
                                    .padding(8)
                            }
                            .allowsHitTesting(false)
                    }
                }
                .onHover { inside in
                    if inside { model.hoverID = plugin.id } else if model.hoverID == plugin.id { model.hoverID = nil }
                }
                // One tap handler: selects on the first click with no wait, and the second click
                // of a double-click inserts. Two separate tap gestures made every single click
                // wait out the double-click time before selecting.
                .onTapGesture {
                    if NSApp.currentEvent?.clickCount ?? 1 >= 2 {
                        model.selection = i
                        onActivate()
                        return
                    }
                    let mods = NSEvent.modifierFlags
                    if mods.contains(.command) || mods.contains(.shift) {
                        model.pick(i, range: mods.contains(.shift))
                    } else {
                        model.picked = []
                        model.selection = i
                    }
                    model.keysOnPlugins = true
                }
                .contextMenu {
                    if model.picked.count > 1, model.picked.contains(plugin.id) {
                        PickedMenu(model: model)
                    } else {
                        PluginContextMenu(plugin: plugin, select: { model.selection = i }, insert: onActivate)
                    }
                }
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
                    VStack(spacing: 8) {
                        ZoomableThumbnail(plugin: plugin)
                        PictureActions(plugin: plugin)
                    }
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
                    store.favoriteTapped(plugin.id)
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
            store.favoriteTapped(plugin.id)
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
        // Every plugin, Logic's own too, can get a picture from the web.
        Button("Find Picture on the Web") { WebPicture.find([plugin]) }
        Button("Use the Database Picture") { WebPicture.revertToDatabase(plugin) }
        if FileManager.default.fileExists(atPath: WebPicture.backupURL(plugin.id).path) {
            Button("Undo Picture Change") { WebPicture.undo(plugin) }
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
        CategoryMenu(ids: [plugin.id])
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
    static let typeInSearch = Notification.Name("AGPFTypeInSearch")
}

/// What a dragged plugin carries: its id, marked so other dropped text is ignored.
enum PluginDrag {
    static let prefix = "agplugfinder-plugin:"
    static func ids(_ items: [String]) -> [String] {
        items.filter { $0.hasPrefix(prefix) }.map { String($0.dropFirst(prefix.count)) }
    }
}

/// The info panel's picture: a magnifier on hover, click to see it large (BL-61).
struct ZoomableThumbnail: View {
    let plugin: Plugin
    @State private var hovering = false

    private var hasImage: Bool { PluginStore.shared.image(for: plugin.id) != nil }

    var body: some View {
        PluginThumbnail(plugin: plugin, radius: 16)
            .aspectRatio(1.5, contentMode: .fit)
            .overlay(alignment: .bottomTrailing) {
                if hasImage {
                    Image(systemName: "plus.magnifyingglass")
                        .font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.text)
                        .frame(width: 32, height: 32)
                        .background(Circle().fill(Color.black.opacity(0.65)))
                        .padding(10)
                        .opacity(hovering ? 1 : 0)
                }
            }
            .onHover { h in
                hovering = h
                if hasImage { if h { NSCursor.pointingHand.push() } else { NSCursor.pop() } }
            }
            .onTapGesture { if hasImage { ImageZoom.show(plugin) } }
            .help(hasImage ? "Click to see it large" : "")
            .animation(.easeOut(duration: 0.15), value: hovering)
    }
}

/// A large view of a plugin's picture. Pinch or scroll with ⌘ to zoom further, double-click
/// to switch between fitting the window and full size, Esc or click outside to close.
@MainActor
enum ImageZoom {
    private static var window: NSWindow?

    static func show(_ plugin: Plugin) {
        guard let image = PluginStore.shared.image(for: plugin.id) else { return }
        window?.close()
        backdrop?.orderOut(nil)
        let screen = (NSScreen.main ?? NSScreen.screens[0]).visibleFrame
        // As large as most of the screen allows, up to twice the picture's own size.
        let scale = min(2, min(screen.width * 0.8 / image.size.width, (screen.height * 0.8 - 44) / image.size.height))
        let size = NSSize(width: max(480, image.size.width * scale), height: max(320, image.size.height * scale + 44))
        let w = ZoomWindow(contentRect: NSRect(origin: .zero, size: size),
                           styleMask: [.titled, .closable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
        w.titlebarAppearsTransparent = true
        w.titleVisibility = .hidden
        w.isMovableByWindowBackground = true
        w.isReleasedWhenClosed = false
        w.backgroundColor = .black
        w.appearance = NSAppearance(named: .darkAqua)
        w.level = .floating

        let scroll = NSScrollView()
        scroll.allowsMagnification = true
        scroll.minMagnification = 0.25
        scroll.maxMagnification = 4
        scroll.backgroundColor = .black
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.autohidesScrollers = true
        let imageView = NSImageView(image: image)
        imageView.frame = NSRect(origin: .zero, size: image.size)
        imageView.imageScaling = .scaleProportionallyUpOrDown
        scroll.documentView = imageView
        let container = NSView()
        let title = NSTextField(labelWithString: "\(plugin.name)  ·  \(plugin.manufacturer)")
        title.font = .systemFont(ofSize: 13, weight: .semibold)
        title.textColor = .white
        for v in [scroll, title] { v.translatesAutoresizingMaskIntoConstraints = false; container.addSubview(v) }
        NSLayoutConstraint.activate([
            title.topAnchor.constraint(equalTo: container.topAnchor, constant: 12),
            title.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            scroll.topAnchor.constraint(equalTo: container.topAnchor, constant: 40),
            scroll.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
        w.contentView = container
        w.center()
        let target = w.frame
        // It grows out of the picture that was clicked: starts small at the pointer.
        let mouse = NSEvent.mouseLocation
        let startW = max(120, min(220, target.width * 0.18))
        let startH = startW * target.height / target.width
        let start = NSRect(x: mouse.x - startW / 2, y: mouse.y - startH / 2, width: startW, height: startH)
        source = start
        showBackdrop(on: NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main)
        w.setFrame(start, display: false)
        w.alphaValue = 0
        w.makeKeyAndOrderFront(nil)
        NSApp.activate()
        container.layoutSubtreeIfNeeded()
        scroll.magnification = max(0.25, scale * startW / target.width)
        NSAnimationContext.runAnimationGroup { c in
            c.duration = 0.42
            c.timingFunction = CAMediaTimingFunction(controlPoints: 0.2, 0.9, 0.25, 1)
            c.allowsImplicitAnimation = true
            w.animator().setFrame(target, display: true)
            w.animator().alphaValue = 1
            scroll.animator().magnification = scale
        }
        let click = NSClickGestureRecognizer(target: ZoomToggle.shared, action: #selector(ZoomToggle.toggle(_:)))
        click.numberOfClicksRequired = 2
        imageView.addGestureRecognizer(click)
        ZoomToggle.shared.fit = scale
        window = w
    }

    /// Where the picture grew from; it shrinks back there when closed.
    static var source: NSRect = .zero
    private static var backdrop: NSWindow?

    /// The screen behind the picture, blurred and dimmed; a click on it closes the picture.
    private static func showBackdrop(on screen: NSScreen?) {
        guard let screen else { return }
        let b = backdrop ?? {
            let b = BackdropWindow(contentRect: screen.frame, styleMask: [.borderless], backing: .buffered, defer: false)
            b.isOpaque = false
            b.backgroundColor = .clear
            b.level = .floating
            b.isReleasedWhenClosed = false
            b.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            let blur = NSVisualEffectView()
            blur.material = .fullScreenUI
            blur.blendingMode = .behindWindow
            blur.state = .active
            let dim = NSView()
            dim.wantsLayer = true
            dim.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.35).cgColor
            dim.autoresizingMask = [.width, .height]
            blur.addSubview(dim)
            b.contentView = blur
            dim.frame = blur.bounds
            backdrop = b
            return b
        }()
        b.setFrame(screen.frame, display: false)
        b.alphaValue = 0
        b.orderFront(nil)
        NSAnimationContext.runAnimationGroup { c in
            c.duration = 0.3
            b.animator().alphaValue = 1
        }
    }

    static func hideBackdrop() {
        guard let b = backdrop else { return }
        NSAnimationContext.runAnimationGroup({ c in
            c.duration = 0.22
            b.animator().alphaValue = 0
        }, completionHandler: { b.orderOut(nil) })
    }

    static func close() { (window as? ZoomWindow)?.animatedClose() }
}

/// The blurred screen behind an enlarged picture. It never takes focus; a click closes the picture.
final class BackdropWindow: NSWindow {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
    override func mouseDown(with event: NSEvent) { MainActor.assumeIsolated { ImageZoom.close() } }
}

/// Double-click switches between fitting the window and full size.
@MainActor
final class ZoomToggle: NSObject {
    static let shared = ZoomToggle()
    var fit: CGFloat = 1
    @objc func toggle(_ g: NSClickGestureRecognizer) {
        guard let scroll = g.view?.enclosingScrollView else { return }
        let target: CGFloat = abs(scroll.magnification - 1) < 0.01 ? fit : 1
        let point = g.location(in: g.view)
        NSAnimationContext.runAnimationGroup { _ in
            scroll.animator().setMagnification(target, centeredAt: point)
        }
    }
}

/// Closes on Esc and when it loses focus (a click outside), shrinking back to where it came from.
final class ZoomWindow: NSWindow {
    private var wasKey = false
    private var closing = false
    override func cancelOperation(_ sender: Any?) { animatedClose() }
    override func becomeKey() { super.becomeKey(); wasKey = true }
    override func resignKey() {
        super.resignKey()
        if wasKey { DispatchQueue.main.async { self.animatedClose() } }
    }

    func animatedClose() {
        guard !closing else { return }
        closing = true
        MainActor.assumeIsolated {
            ImageZoom.hideBackdrop()
            let back = ImageZoom.source
            NSAnimationContext.runAnimationGroup({ c in
                c.duration = 0.24
                c.timingFunction = CAMediaTimingFunction(controlPoints: 0.4, 0, 0.8, 0.4)
                if back.width > 0 { self.animator().setFrame(back, display: true) }
                self.animator().alphaValue = 0
            }, completionHandler: { self.close() })
        }
    }
}


/// The star on a card: amber when the plugin is a favorite, a quiet gray outline otherwise.
/// A click adds it; removing asks first.
struct FavoriteStar: View {
    let plugin: Plugin
    var cardHovered = false
    var store = PluginStore.shared
    @State private var hovering = false

    var body: some View {
        let on = store.favorites.contains(plugin.id)
        Button { store.favoriteTapped(plugin.id) } label: {
            Image(systemName: on ? "star.fill" : "star")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(on ? Theme.accent : (hovering ? Theme.text : Color.white.opacity(cardHovered ? 0.55 : 0.32)))
                .frame(width: 24, height: 24)
                .background(Circle().fill(Color.black.opacity(on || hovering || cardHovered ? 0.7 : 0.45)))
                .scaleEffect(hovering ? 1.12 : 1)
        }
        .buttonStyle(.plain)
        .padding(8)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.12), value: hovering)
        .animation(.spring(response: 0.25, dampingFraction: 0.6), value: on)
        .help(on ? "Remove from Favorites" : "Add to Favorites")
    }
}

/// "Remove from Favorites?", in the app's own style, over the window that asked.
struct UnfavoriteConfirm: View {
    var store = PluginStore.shared

    var body: some View {
        if let id = store.confirmingUnfavorite {
            let plugin = store.plugins.first { $0.id == id }
            ZStack {
                Color.black.opacity(0.55).onTapGesture { store.confirmingUnfavorite = nil }
                VStack(spacing: 14) {
                    if let plugin {
                        PluginThumbnail(plugin: plugin, radius: 10).frame(width: 150, height: 94)
                    }
                    Image(systemName: "star.slash").font(.system(size: 20)).foregroundStyle(Theme.accent)
                    VStack(spacing: 4) {
                        Text("Remove from Favorites?").font(.system(size: 15, weight: .semibold)).foregroundStyle(Theme.text)
                        Text("\(plugin?.name ?? "This plugin") won't show in Favorites anymore. You can add it back with the star.")
                            .font(.system(size: 12)).foregroundStyle(Theme.muted)
                            .multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
                    }
                    HStack(spacing: 8) {
                        QuietPill(title: "Keep", height: 32) { store.confirmingUnfavorite = nil }
                            .keyboardShortcut(.cancelAction)
                        PrimaryPill(title: "Remove", systemImage: "star.slash", height: 32) {
                            store.favorites.remove(id)
                            store.confirmingUnfavorite = nil
                        }
                        .keyboardShortcut(.defaultAction)
                    }
                }
                .padding(22)
                .frame(width: 300)
                .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Theme.surface))
                .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Theme.rule, lineWidth: 1))
                .shadow(color: .black.opacity(0.5), radius: 30, y: 10)
            }
            .transition(.opacity)
        }
    }
}


// MARK: - Several plugins at once (BL-79)

/// What can be done to every picked plugin together.
@MainActor
enum PickedActions {
    static func plugins(_ model: PickerModel) -> [Plugin] {
        PluginStore.shared.plugins.filter { model.picked.contains($0.id) }
    }

    /// Adds every selected plugin to the selected Logic track, in the order they show (BL-111).
    static func addAll(_ model: PickerModel) {
        let list = model.results.filter { model.picked.contains($0.id) }
        guard !list.isEmpty else { return }
        InsertRunner.run(list, title: "\(list.count) plugins")
    }

    static func takePictures(_ model: PickerModel) {
        let ids = Set(plugins(model).filter { !$0.isLogic }.map(\.id))
        guard !ids.isEmpty else { Toast.show("Logic's own plugins already have their pictures.", warning: true); return }
        guard !SnapshotQueue.shared.isRunning else { Toast.show("Pictures are already being taken. Try again when it finishes.", warning: true); return }
        SnapshotQueue.shared.start(only: ids)
    }

    static func favorite(_ model: PickerModel) {
        let ids = plugins(model).map(\.id)
        PluginStore.shared.favorites.formUnion(ids)
        Toast.show("Added \(ids.count) to Favorites")
    }

    static func addToCollection(_ model: PickerModel, _ id: String?) {
        let ids = plugins(model).map(\.id)
        let lib = UserLibrary.shared
        if let id, let i = lib.collections.firstIndex(where: { $0.id == id }) {
            for p in ids where !lib.collections[i].pluginIDs.contains(p) { lib.collections[i].pluginIDs.append(p) }
            Toast.show("Added \(ids.count) to \(lib.collections[i].name)")
        } else if let name = NamePrompt.ask("New collection", placeholder: "For example Mix bus") {
            lib.collections.append(.init(name: name, pluginIDs: ids))
            Toast.show("Made \(name) with \(ids.count) plugins")
        }
    }
}

struct PickedMenu: View {
    @Bindable var model: PickerModel

    var body: some View {
        let n = model.picked.count
        Button("Add All \(n) to Logic") { PickedActions.addAll(model) }
        Divider()
        Button("Take Pictures of \(n) Plugins") { PickedActions.takePictures(model) }
        Button("Clear \(n) Pictures") { PluginStore.shared.clearScreenshots(Array(model.picked)) }
        Button("Find \(n) Pictures on the Web") { WebPicture.find(PickedActions.plugins(model)) }
            .disabled(!WebPicture.available)
        Divider()
        Button("Add \(n) to Favorites") { PickedActions.favorite(model) }
        Menu("Add \(n) to Collection") {
            ForEach(UserLibrary.shared.collections) { c in
                Button(c.name) { PickedActions.addToCollection(model, c.id) }
            }
            if !UserLibrary.shared.collections.isEmpty { Divider() }
            Button("New Collection…") { PickedActions.addToCollection(model, nil) }
        }
        CategoryMenu(ids: Array(model.picked))
        LicenseMenu(ids: Array(model.picked))
        Button("Look Up Info for \(n)") { PluginInfoFetcher.shared.start(ids: Array(model.picked)) }
            .disabled(PluginInfoFetcher.shared.isRunning || !PluginInfoFetcher.shared.canLookUp)
        Divider()
        Button("Deselect All") { model.picked = [] }
    }
}

/// The bar at the bottom of the grid while several plugins are picked.
struct PickedBar: View {
    @Bindable var model: PickerModel

    var body: some View {
        if model.picked.count > 1 {
            HStack(spacing: 8) {
                Text("\(model.picked.count) selected").font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.text)
                    .padding(.horizontal, 6)
                PrimaryPill(title: "Add All to Logic", systemImage: "plus", height: 28) { PickedActions.addAll(model) }
                    .help("Adds the \(model.picked.count) plugins to the selected track, one after another, in the order shown")
                QuietPill(title: "Take Pictures", systemImage: "camera", height: 28) { PickedActions.takePictures(model) }
                QuietPill(title: "Favorites", systemImage: "star", height: 28) { PickedActions.favorite(model) }
                QuietPill(title: "Collection", systemImage: "plus.rectangle.on.rectangle", height: 28) {
                    PickedActions.addToCollection(model, nil)
                }
                QuietPill(title: "Done", height: 28) { model.picked = [] }
            }
            .padding(8)
            .background(Capsule().fill(Theme.raised))
            .overlay(Capsule().strokeBorder(Theme.rule, lineWidth: 1))
            .shadow(color: .black.opacity(0.45), radius: 18, y: 6)
            .padding(.bottom, 16)
            .transition(.move(edge: .bottom).combined(with: .opacity))
        }
    }
}


/// Choose the category for one plugin or several (BL-82). "Automatic" goes back to the guess.
struct CategoryMenu: View {
    let ids: [String]
    var store = PluginStore.shared

    var body: some View {
        let current = Set(ids.compactMap { id in store.plugins.first { $0.id == id }?.displayCategory })
        Menu(ids.count > 1 ? "Set Category for \(ids.count)" : "Category") {
            ForEach(PluginCategories.all, id: \.self) { c in
                Button((current == [c] ? "✓ " : "") + c) { set(c) }
            }
            Divider()
            Button("Automatic") { set(nil) }
                .disabled(!ids.contains { id in store.plugins.first { $0.id == id }?.userCategory != nil })
        }
    }

    private func set(_ category: String?) {
        let before = Dictionary(uniqueKeysWithValues: ids.map { id in (id, store.plugins.first { $0.id == id }?.userCategory) })
        for id in ids { store.update(id) { $0.userCategory = category } }
        Toast.show(category.map { ids.count > 1 ? "\(ids.count) plugins moved to \($0)" : "Moved to \($0)" }
                   ?? "Back to the automatic category")
        guard let category else { return }
        let plugins = ids.compactMap { id in store.plugins.first { $0.id == id } }
        guard !plugins.isEmpty else { return }
        // Offer it to everyone: other users' apps can then sort these plugins the same way.
        let d = UserDefaults.standard
        if d.bool(forKey: "share.categories.always") { PlugDB.shareCategory(plugins, category); return }
        let alert = NSAlert()
        let what = plugins.count == 1 ? plugins[0].name : "these \(plugins.count) plugins"
        alert.messageText = "Move \(what) to \(category) for everyone, or only on this Mac?"
        alert.informativeText = "Everyone: other AG PlugFinder users will see \(plugins.count == 1 ? "it" : "them") in \(category) too, once other users agree. Only the plugin names and the category are sent.\n\nOnly This Mac: the change stays with you."
        alert.addButton(withTitle: "Everyone")
        alert.addButton(withTitle: "Only This Mac")
        alert.addButton(withTitle: "Cancel")
        alert.showsSuppressionButton = true
        alert.suppressionButton?.title = "Always choose Everyone without asking"
        let answer = alert.runModal()
        if answer == .alertThirdButtonReturn {
            // Cancel: the category goes back to what it was.
            for (id, old) in before { store.update(id) { $0.userCategory = old } }
            Toast.show("Category not changed")
            return
        }
        if answer == .alertFirstButtonReturn {
            PlugDB.shareCategory(plugins, category)
            if alert.suppressionButton?.state == .on { d.set(true, forKey: "share.categories.always") }
            Toast.show("Moved for everyone. Thank you!")
        }
    }
}


/// Plugin names are English, so the search field always types English (Adi, 2026-10-31): the
/// Mac switches to an English keyboard while it has focus and back afterwards. If Hebrew letters
/// still arrive, they are read as the English letters on the same keys.
@MainActor
enum EnglishKeys {
    static func apply() {
        DispatchQueue.main.async {
            for w in NSApp.windows where w.isVisible {
                if let tv = w.firstResponder as? NSTextView {
                    tv.inputContext?.allowedInputSourceLocales = [NSAllRomanInputSourcesLocaleIdentifier]
                }
            }
        }
    }

    private static let hebrew: [Character: Character] = [
        "/": "q", "׳": "w", "ק": "e", "ר": "r", "א": "t", "ט": "y", "ו": "u", "ן": "i", "ם": "o", "פ": "p",
        "ש": "a", "ד": "s", "ג": "d", "כ": "f", "ע": "g", "י": "h", "ח": "j", "ל": "k", "ך": "l", "ף": ";",
        "ז": "z", "ס": "x", "ב": "c", "ה": "v", "נ": "b", "מ": "n", "צ": "m", "ת": ",", "ץ": ".",
    ]

    static func fromHebrewKeys(_ s: String) -> String {
        guard s.unicodeScalars.contains(where: { (0x05D0...0x05EA).contains($0.value) }) else { return s }
        return String(s.map { hebrew[$0] ?? $0 })
    }
}


/// Everything about the picture, right under it in the info panel (Adi, 2026-10-31).
struct PictureActions: View {
    let plugin: Plugin
    var store = PluginStore.shared
    var queue = SnapshotQueue.shared

    var body: some View {
        let hasImage = store.image(for: plugin.id) != nil
        FlowRow(spacing: 6) {
            if !plugin.isLogic {
                small(hasImage ? "Retake" : "Take Picture", "camera") { queue.recapture(plugin.id) }
                    .disabled(queue.isRunning)
            }
            small("Find on the Web", "globe") { WebPicture.find([plugin]) }
            small("Database Picture", "arrow.uturn.backward") { WebPicture.revertToDatabase(plugin) }
            if FileManager.default.fileExists(atPath: WebPicture.backupURL(plugin.id).path) {
                small("Undo", "arrow.uturn.backward") { WebPicture.undo(plugin) }
            }
            if !plugin.isLogic, hasImage {
                small("Clear", "trash") { store.clearScreenshots([plugin.id]) }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func small(_ title: String, _ icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: icon).font(.system(size: 10, weight: .medium))
                Text(title).font(.system(size: 11))
            }
            .padding(.horizontal, 9).frame(height: 24)
            .foregroundStyle(Theme.muted)
            .background(Capsule().fill(Theme.raised))
            .contentShape(Capsule())
        }
        .buttonStyle(PressScale())
        .help(title)
    }
}

/// Where each plugin card sits in the grid, for the selection box (BL-97).
struct TileFrames: PreferenceKey {
    static let defaultValue: [String: CGRect] = [:]
    static func reduce(value: inout [String: CGRect], nextValue: () -> [String: CGRect]) {
        value.merge(nextValue()) { $1 }
    }
}
