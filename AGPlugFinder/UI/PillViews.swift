import AppKit
import SwiftUI

// MARK: - Colors

extension Pills {
    static func color(_ name: String?) -> Color? {
        switch name {
        case "red": return Color(red: 0.95, green: 0.36, blue: 0.34)
        case "orange": return Color(red: 0.96, green: 0.58, blue: 0.24)
        case "yellow": return Color(red: 0.96, green: 0.80, blue: 0.27)
        case "green": return Color(red: 0.36, green: 0.80, blue: 0.45)
        case "teal": return Color(red: 0.30, green: 0.78, blue: 0.80)
        case "blue": return Color(red: 0.36, green: 0.58, blue: 0.98)
        case "purple": return Color(red: 0.66, green: 0.46, blue: 0.96)
        case "pink": return Color(red: 0.95, green: 0.45, blue: 0.70)
        default: return nil
        }
    }
}

// MARK: - The row above the plugins

/// All, pinned pills, collections, then categories and combined pills (BL-110). What doesn't fit
/// goes into a More pill, or the row wraps, as chosen in Edit Pills.
struct PillRow: View {
    @Bindable var model: PickerModel
    let showCollections: Bool
    let showCategories: Bool
    var library = UserLibrary.shared
    @State private var showMore = false
    @State private var dropOn: String?

    var body: some View {
        let prefs = library.pills
        let cols = showCollections ? Pills.collectionPills() : []
        let cats = showCategories ? Pills.categoryPills() : []
        let pinned = (cols + cats).filter(\.pinned)
            .sorted { (prefs.pinned.firstIndex(of: $0.key) ?? 0) < (prefs.pinned.firstIndex(of: $1.key) ?? 0) }
        let rest = cols.filter { !$0.pinned } + cats.filter { !$0.pinned }
        let splitAt = cols.filter { !$0.pinned }.count
        if prefs.wrap {
            FlowRow(spacing: 8) {
                allChip(prefs)
                ForEach(pinned) { chip($0, prefs) }
                ForEach(Array(rest.enumerated()), id: \.element.id) { i, p in
                    chip(p, prefs).padding(.leading, i == splitAt && splitAt > 0 && i < rest.count ? 9 : 0)
                }
                editButton
            }
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            GeometryReader { geo in
                let fit = fitting(pinned + rest, width: geo.size.width, prefs: prefs)
                let shown = Array((pinned + rest).prefix(fit))
                let overflow = Array((pinned + rest).dropFirst(fit))
                HStack(spacing: 8) {
                    allChip(prefs)
                    ForEach(Array(shown.enumerated()), id: \.element.id) { i, p in
                        if i == pinned.count + splitAt, splitAt > 0, i > 0, p.kind != .collection {
                            Rectangle().fill(Theme.raised).frame(width: 1, height: 18).padding(.horizontal, 1)
                        }
                        chip(p, prefs)
                    }
                    if !overflow.isEmpty { moreChip(overflow, prefs) }
                    editButton
                }
                .frame(maxHeight: .infinity)
            }
            .frame(height: 44)
        }
    }

    /// How many pills fit beside All, the More pill and the edit button.
    private func fitting(_ pills: [Pill], width: CGFloat, prefs: PillPrefs) -> Int {
        let allWidth: CGFloat = (prefs.compact ? 18 : 22) + 18 + 8
        let tail: CGFloat = 30 + 8          // edit button
        let more: CGFloat = (prefs.compact ? 84 : 92)
        var used = allWidth + tail
        for (i, p) in pills.enumerated() {
            let w = Pills.width(p, prefs: prefs) + (p.kind != .collection && i > 0 && pills[i - 1].kind == .collection ? 12 : 0)
            let needMore = i < pills.count - 1
            if used + w + (needMore ? more : 0) > width { return i }
            used += w
        }
        return pills.count
    }

    private func allChip(_ prefs: PillPrefs) -> some View {
        PillChip(title: "All", count: nil, color: nil, on: model.collectionID == nil && model.pills.isEmpty,
                 compact: prefs.compact) {
            model.collectionID = nil
            model.pills = []
        }
    }

    private var editButton: some View {
        BarIconButton(systemImage: "line.3.horizontal.decrease", help: "Edit pills: show, hide, order, rename, colors") {
            PillsWindow.shared.show()
        }
    }

    @ViewBuilder private func chip(_ p: Pill, _ prefs: PillPrefs) -> some View {
        let on = p.kind == .collection ? model.collectionID == String(p.key.dropFirst(4)) : model.pills.contains(p.key)
        PillChip(title: p.title, count: p.kind == .collection || prefs.showCounts ? p.count : nil,
                 color: Pills.color(p.color), on: on, compact: prefs.compact) { tap(p) }
            .help(p.kind == .group ? Pills.categories(for: p.key).joined(separator: ", ")
                  : p.kind == .category ? "⌘-click to add more categories" : "")
            .overlay(Capsule().strokeBorder(Theme.accent, lineWidth: 2).opacity(dropOn == p.key ? 1 : 0))
            .scaleEffect(dropOn == p.key ? 1.08 : 1)
            .animation(.easeOut(duration: 0.12), value: dropOn)
            .modifier(CollectionDrop(pill: p, dropOn: $dropOn))
            .contextMenu { PillMenu(pill: p, model: model) }
    }

    private func moreChip(_ overflow: [Pill], _ prefs: PillPrefs) -> some View {
        let anyOn = overflow.contains { p in
            p.kind == .collection ? model.collectionID == String(p.key.dropFirst(4)) : model.pills.contains(p.key)
        }
        return Button { showMore.toggle() } label: {
            HStack(spacing: 5) {
                Text("More").font(.system(size: prefs.compact ? 11 : 12, weight: anyOn ? .semibold : .regular))
                Text("\(overflow.count)").font(.system(size: prefs.compact ? 10 : 11)).opacity(0.55).monospacedDigit()
                Image(systemName: "chevron.down").font(.system(size: 9, weight: .bold))
            }
            .padding(.horizontal, prefs.compact ? 9 : 11).frame(height: prefs.compact ? 24 : 28)
            .foregroundStyle(anyOn ? Color.black : Theme.text)
            .background(Capsule().fill(anyOn ? Color.white : Theme.raised))
            .contentShape(Capsule())
        }
        .buttonStyle(PressScale())
        .fixedSize()
        .popover(isPresented: $showMore, arrowEdge: .bottom) {
            MorePills(pills: overflow, model: model) { p in
                tap(p)
                if !NSEvent.modifierFlags.contains(.command) { showMore = false }
            }
        }
    }

    /// Click: only this one. ⌘-click: add or remove a category (BL-110).
    private func tap(_ p: Pill) {
        if p.kind == .collection {
            let id = String(p.key.dropFirst(4))
            model.collectionID = model.collectionID == id ? nil : id
            model.pills = []
            return
        }
        model.collectionID = nil
        if NSEvent.modifierFlags.contains(.command) {
            if model.pills.contains(p.key) { model.pills.remove(p.key) } else { model.pills.insert(p.key) }
        } else {
            model.pills = model.pills == [p.key] ? [] : [p.key]
        }
    }
}

/// Plugins dropped on a collection's pill go into it (BL-60).
private struct CollectionDrop: ViewModifier {
    let pill: Pill
    @Binding var dropOn: String?

    func body(content: Content) -> some View {
        if pill.kind == .collection {
            content.dropDestination(for: String.self) { items, _ in
                let lib = UserLibrary.shared
                let ids = PluginDrag.ids(items)
                guard !ids.isEmpty, let i = lib.collections.firstIndex(where: { "col:" + $0.id == pill.key }) else { return false }
                let new = ids.filter { !lib.collections[i].pluginIDs.contains($0) }
                lib.collections[i].pluginIDs.append(contentsOf: new)
                let name = ids.count == 1 ? (PluginStore.shared.plugin(ids[0])?.name ?? "Plugin") : "\(ids.count) plugins"
                Toast.show(new.isEmpty ? "\(name) is already in \(pill.title)" : "Added \(name) to \(pill.title)")
                return true
            } isTargeted: { on in
                if on { dropOn = pill.key } else if dropOn == pill.key { dropOn = nil }
            }
        } else {
            content
        }
    }
}

/// A pill: optional color dot and count, white when on.
struct PillChip: View {
    let title: String
    let count: Int?
    let color: Color?
    let on: Bool
    var compact = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                if let color { Circle().fill(color).frame(width: 6, height: 6) }
                Text(title).font(.system(size: compact ? 11 : 12, weight: on ? .semibold : .regular)).lineLimit(1)
                if let count {
                    Text("\(count)").font(.system(size: compact ? 10 : 11)).opacity(0.55).monospacedDigit()
                }
            }
            .padding(.horizontal, compact ? 9 : 11).frame(height: compact ? 24 : 28)
            .foregroundStyle(on ? Color.black : Theme.text)
            .background(Capsule().fill(on ? Color.white : Theme.raised))
            .contentShape(Capsule())
        }
        .buttonStyle(PressScale())
        .fixedSize()
    }
}

/// Right-click on a pill (BL-110).
struct PillMenu: View {
    let pill: Pill
    @Bindable var model: PickerModel

    var body: some View {
        Button(pill.pinned ? "Unpin" : "Pin to Front") { Pills.togglePin(pill.key) }
        Button(pill.kind == .collection ? "Rename Collection…" : pill.kind == .group ? "Rename…" : "Rename Pill…") {
            Pills.rename(pill)
        }
        if pill.kind == .category, pill.title != pill.original {
            Button("Back to “\(pill.original)”") { Pills.restoreName(pill.key) }
        }
        Menu("Color") {
            Button { Pills.setColor(pill.key, nil) } label: {
                if pill.color == nil { Label("None", systemImage: "checkmark") } else { Text("None") }
            }
            ForEach(Pills.colorNames, id: \.self) { c in
                Button { Pills.setColor(pill.key, c) } label: {
                    if pill.color == c { Label(c.capitalized, systemImage: "checkmark") } else { Text(c.capitalized) }
                }
            }
        }
        Button("Hide Pill") {
            Pills.setHidden(pill.key, true)
            model.pills.remove(pill.key)
            if pill.kind == .collection, model.collectionID == String(pill.key.dropFirst(4)) { model.collectionID = nil }
        }
        Divider()
        switch pill.kind {
        case .category:
            Button("Combine with Other Categories…") { PillsWindow.shared.show(newGroupWith: pill.original) }
        case .group:
            Button("Edit Combined Pill…") { PillsWindow.shared.show(editGroup: String(pill.key.dropFirst(4))) }
            Button("Split Back into Categories") {
                model.pills.remove(pill.key)
                Pills.ungroup(pill.key)
            }
        case .collection:
            Button("Delete Collection") {
                let id = String(pill.key.dropFirst(4))
                if model.collectionID == id { model.collectionID = nil }
                UserLibrary.shared.collections.removeAll { $0.id == id }
            }
        }
        Divider()
        Button("Edit Pills…") { PillsWindow.shared.show() }
    }
}

/// The pills that didn't fit, with a search.
struct MorePills: View {
    let pills: [Pill]
    @Bindable var model: PickerModel
    let choose: (Pill) -> Void
    @State private var search = ""

    var body: some View {
        let words = search.lowercased().split(separator: " ").map(String.init)
        let list = pills.filter { p in words.allSatisfy { p.title.lowercased().contains($0) } }
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").font(.system(size: 12)).foregroundStyle(Theme.faint)
                TextField("", text: $search, prompt: Text("Find a pill").foregroundStyle(Theme.faint))
                    .textFieldStyle(.plain).font(.system(size: 13)).foregroundStyle(Theme.text)
            }
            .padding(.horizontal, 12).frame(height: 32)
            .background(Capsule().fill(Theme.raised))
            ScrollView {
                VStack(spacing: 2) {
                    ForEach(list) { p in
                        let on = p.kind == .collection ? model.collectionID == String(p.key.dropFirst(4)) : model.pills.contains(p.key)
                        Button { choose(p) } label: {
                            HStack(spacing: 9) {
                                Circle().fill(Pills.color(p.color) ?? Theme.raised).frame(width: 7, height: 7)
                                Text(p.title).font(.system(size: 13, weight: on ? .semibold : .regular))
                                    .foregroundStyle(Theme.text)
                                Spacer(minLength: 8)
                                Text("\(p.count)").font(.system(size: 11)).foregroundStyle(Theme.faint).monospacedDigit()
                                Image(systemName: "checkmark").font(.system(size: 10, weight: .bold))
                                    .foregroundStyle(Theme.accent).opacity(on ? 1 : 0)
                            }
                            .padding(.horizontal, 10).frame(height: 30)
                            .background(RoundedRectangle(cornerRadius: 8).fill(on ? Theme.raised : Color.clear))
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .contextMenu { PillMenu(pill: p, model: model) }
                    }
                }
            }
            .frame(maxHeight: 320)
            HStack {
                Text("⌘-click to pick several").font(.system(size: 11)).foregroundStyle(Theme.faint)
                Spacer()
                QuietPill(title: "Edit Pills…", height: 26) { PillsWindow.shared.show() }
            }
        }
        .padding(14)
        .frame(width: 280)
        .background(Theme.surface)
        .preferredColorScheme(.dark)
    }
}

// MARK: - Edit Pills

@MainActor
final class PillsWindow {
    static let shared = PillsWindow()
    private var window: NSWindow?

    func show(newGroupWith category: String? = nil, editGroup: String? = nil) {
        let w = window ?? {
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 620, height: 680),
                             styleMask: [.titled, .closable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
            w.titlebarAppearsTransparent = true
            w.titleVisibility = .hidden
            w.isMovableByWindowBackground = true
            w.isReleasedWhenClosed = false
            w.backgroundColor = .black
            w.appearance = NSAppearance(named: .darkAqua)
            w.minSize = NSSize(width: 520, height: 480)
            let host = NSHostingView(rootView: PillsEditor(topPadding: 36))
            host.sizingOptions = []
            w.contentView = host
            w.setContentSize(NSSize(width: 620, height: 680))
            w.center()
            window = w
            return w
        }()
        w.makeKeyAndOrderFront(nil)
        NSApp.activate()
        if category != nil || editGroup != nil {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                NotificationCenter.default.post(name: .editCombinedPill, object: nil,
                                                userInfo: ["category": category as Any, "group": editGroup as Any])
            }
        }
    }
}

extension Notification.Name {
    static let editCombinedPill = Notification.Name("AGPFEditCombinedPill")
}

/// Edit Pills (BL-110): what shows, in what order, names, colors, combined pills, the look.
struct PillsEditor: View {
    var topPadding: CGFloat = 22
    var library = UserLibrary.shared
    var view = ViewSettings.shared
    @State private var groupSheet: GroupDraft?
    @State private var confirmReset = false

    struct GroupDraft: Identifiable {
        var id: String { groupID ?? "new" }
        var groupID: String?
        var name: String
        var categories: Set<String>
    }

    var body: some View {
        let prefs = library.pills
        let cols = Pills.collectionPills(includeHidden: true)
        let cats = Pills.categoryPills(includeHidden: true)
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Pills").font(.system(size: 22, weight: .semibold)).foregroundStyle(Theme.text)
                    Text("Choose which pills show above your plugins, their order, names and colors. Synced to your other Macs.")
                        .font(.system(size: 12)).foregroundStyle(Theme.faint)
                        .fixedSize(horizontal: false, vertical: true)
                }
                options(prefs)
            }
            .padding(.horizontal, 22).padding(.top, topPadding).padding(.bottom, 14)

            List {
                if !cols.isEmpty {
                    Section { rows(cols) } header: { header("Collections") }
                }
                Section { rows(cats) } header: { header("Categories") }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .padding(.horizontal, 12)
            .environment(\.defaultMinListRowHeight, 40)

            HStack(spacing: 8) {
                QuietPill(title: "Combined Pill", systemImage: "plus", height: 30) {
                    groupSheet = GroupDraft(groupID: nil, name: "", categories: [])
                }
                .help("One pill for several categories, for example Space = Reverb + Delay")
                Spacer()
                QuietPill(title: "Reset to Default", height: 30) { confirmReset = true }
            }
            .padding(.horizontal, 22).padding(.vertical, 14)
            .overlay(alignment: .top) { Rectangle().fill(Theme.rule).frame(height: 1) }
        }
        .background(Theme.ground)
        .preferredColorScheme(.dark)
        .sheet(item: $groupSheet) { d in CombinedPillSheet(draft: d) { groupSheet = nil } }
        .alert("Reset the pills?", isPresented: $confirmReset) {
            Button("Reset") { Pills.reset() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Order, names, colors, pinned and hidden pills go back to the default. Your combined pills stay.")
        }
        .onReceive(NotificationCenter.default.publisher(for: .editCombinedPill)) { n in
            if let id = n.userInfo?["group"] as? String, let g = library.pills.groups.first(where: { $0.id == id }) {
                groupSheet = GroupDraft(groupID: id, name: g.name, categories: Set(g.categories))
            } else if let c = n.userInfo?["category"] as? String {
                groupSheet = GroupDraft(groupID: nil, name: "", categories: [c])
            }
        }
    }

    private func options(_ prefs: PillPrefs) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            option("Show") {
                ForEach(ViewSettings.ChipRow.allCases) { r in
                    Chip(title: r.title, on: view.chipRow == r) { view.chipRow = r }
                }
            }
            option("Order") {
                ForEach(PillPrefs.Sort.allCases) { s in
                    Chip(title: s.title, on: prefs.sort == s) { var p = prefs; p.sort = s; Pills.prefs = p }
                }
            }
            option("Too many") {
                Chip(title: "More pill", on: !prefs.wrap) { var p = prefs; p.wrap = false; Pills.prefs = p }
                Chip(title: "Wrap to more rows", on: prefs.wrap) { var p = prefs; p.wrap = true; Pills.prefs = p }
            }
            option("Look") {
                Chip(title: "Regular", on: !prefs.compact) { var p = prefs; p.compact = false; Pills.prefs = p }
                Chip(title: "Compact", on: prefs.compact) { var p = prefs; p.compact = true; Pills.prefs = p }
                Chip(title: "Counts", systemImage: prefs.showCounts ? "checkmark" : nil, on: prefs.showCounts) {
                    var p = prefs; p.showCounts.toggle(); Pills.prefs = p
                }
                .help("Show how many plugins each category has")
            }
        }
    }

    private func option<C: View>(_ title: String, @ViewBuilder _ content: () -> C) -> some View {
        HStack(spacing: 6) {
            Text(title).font(.system(size: 12)).foregroundStyle(Theme.faint).frame(width: 74, alignment: .leading)
            content()
        }
    }

    private func header(_ t: String) -> some View {
        HStack {
            Text(t).font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.muted)
            Spacer()
            Text("Drag to set your own order").font(.system(size: 11)).foregroundStyle(Theme.faint)
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder private func rows(_ pills: [Pill]) -> some View {
        ForEach(pills) { p in
            PillEditRow(pill: p) {
                if let id = p.kind == .group ? String(p.key.dropFirst(4)) : nil,
                   let g = library.pills.groups.first(where: { $0.id == id }) {
                    groupSheet = GroupDraft(groupID: id, name: g.name, categories: Set(g.categories))
                }
            }
            .listRowBackground(Color.clear)
            .listRowSeparatorTint(Theme.rule)
        }
        .onMove { from, to in
            var keys = pills.map(\.key)
            keys.move(fromOffsets: from, toOffset: to)
            Pills.setOrder(keys)
        }
    }
}

/// One row in Edit Pills: drag handle, color, name, count, pin, show.
struct PillEditRow: View {
    let pill: Pill
    var editGroup: () -> Void
    @State private var showColors = false

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "line.3.horizontal").font(.system(size: 11)).foregroundStyle(Theme.faint)
            Button { showColors.toggle() } label: {
                Circle().fill(Pills.color(pill.color) ?? Color.clear)
                    .overlay(Circle().strokeBorder(pill.color == nil ? Theme.faint : .clear, style: StrokeStyle(lineWidth: 1, dash: [2, 2])))
                    .frame(width: 14, height: 14)
            }
            .buttonStyle(.plain)
            .help("Color")
            .popover(isPresented: $showColors, arrowEdge: .bottom) { palette }
            VStack(alignment: .leading, spacing: 1) {
                Text(pill.title).font(.system(size: 13, weight: .medium))
                    .foregroundStyle(pill.hidden ? Theme.faint : Theme.text)
                if let sub {
                    Text(sub).font(.system(size: 11)).foregroundStyle(Theme.faint).lineLimit(1)
                }
            }
            Spacer(minLength: 8)
            Text("\(pill.count)").font(.system(size: 11)).foregroundStyle(Theme.faint).monospacedDigit()
            if pill.kind == .group {
                icon("square.and.pencil", "Edit combined pill", false, editGroup)
            }
            icon("pencil", "Rename", false) { Pills.rename(pill) }
            icon(pill.pinned ? "pin.fill" : "pin", pill.pinned ? "Unpin" : "Pin to front", pill.pinned) { Pills.togglePin(pill.key) }
            icon(pill.hidden ? "eye.slash" : "eye", pill.hidden ? "Show this pill" : "Hide this pill", !pill.hidden) {
                Pills.setHidden(pill.key, !pill.hidden)
            }
        }
        .padding(.vertical, 4)
        .opacity(pill.hidden ? 0.7 : 1)
    }

    private var sub: String? {
        switch pill.kind {
        case .group: return Pills.categories(for: pill.key).joined(separator: ", ")
        case .category: return pill.title != pill.original ? pill.original : nil
        case .collection: return nil
        }
    }

    private func icon(_ name: String, _ help: String, _ on: Bool, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: name).font(.system(size: 12, weight: .medium))
                .foregroundStyle(on ? Theme.accent : Theme.muted)
                .frame(width: 26, height: 26)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
    }

    private var palette: some View {
        HStack(spacing: 8) {
            Button { Pills.setColor(pill.key, nil); showColors = false } label: {
                Circle().strokeBorder(Theme.faint, style: StrokeStyle(lineWidth: 1, dash: [2, 2]))
                    .frame(width: 20, height: 20)
                    .overlay(Image(systemName: "xmark").font(.system(size: 8, weight: .bold)).foregroundStyle(Theme.faint))
            }
            .buttonStyle(.plain).help("No color")
            ForEach(Pills.colorNames, id: \.self) { c in
                Button { Pills.setColor(pill.key, c); showColors = false } label: {
                    Circle().fill(Pills.color(c) ?? .clear).frame(width: 20, height: 20)
                        .overlay(Circle().strokeBorder(Color.white, lineWidth: pill.color == c ? 2 : 0))
                }
                .buttonStyle(.plain).help(c.capitalized)
            }
        }
        .padding(12)
        .background(Theme.surface)
        .preferredColorScheme(.dark)
    }
}

/// Make or edit a combined pill: a name and the categories in it.
struct CombinedPillSheet: View {
    @State var draft: PillsEditor.GroupDraft
    var close: () -> Void
    @State private var search = ""

    /// Categories already in another combined pill, and its name.
    private var otherGroups: [String: String] {
        var m: [String: String] = [:]
        for g in Pills.prefs.groups where g.id != draft.groupID { for c in g.categories { m[c] = g.name } }
        return m
    }

    var body: some View {
        let counts = Pills.categoryCounts()
        let others = otherGroups
        let words = search.lowercased().split(separator: " ").map(String.init)
        let all = counts.keys.sorted { $0.localizedCompare($1) == .orderedAscending }
            .filter { c in words.allSatisfy { c.lowercased().contains($0) } }
        VStack(alignment: .leading, spacing: 14) {
            Text(draft.groupID == nil ? "New combined pill" : "Edit combined pill")
                .font(.system(size: 17, weight: .semibold)).foregroundStyle(Theme.text)
            TextField("", text: $draft.name, prompt: Text("Name, for example Space").foregroundStyle(Theme.faint))
                .textFieldStyle(.plain).font(.system(size: 14)).foregroundStyle(Theme.text)
                .padding(.horizontal, 12).frame(height: 34)
                .background(RoundedRectangle(cornerRadius: 9).fill(Theme.raised))
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").font(.system(size: 11)).foregroundStyle(Theme.faint)
                TextField("", text: $search, prompt: Text("Find a category").foregroundStyle(Theme.faint))
                    .textFieldStyle(.plain).font(.system(size: 12)).foregroundStyle(Theme.text)
            }
            .padding(.horizontal, 10).frame(height: 28)
            .background(Capsule().fill(Theme.raised))
            ScrollView {
                VStack(spacing: 2) {
                    ForEach(all, id: \.self) { c in
                        let on = draft.categories.contains(c)
                        Button {
                            if on { draft.categories.remove(c) } else { draft.categories.insert(c) }
                        } label: {
                            HStack(spacing: 10) {
                                CheckMark(on: on)
                                Text(c).font(.system(size: 13)).foregroundStyle(Theme.text)
                                if let g = others[c] {
                                    Text("in \(g)").font(.system(size: 11)).foregroundStyle(Theme.faint)
                                }
                                Spacer()
                                Text("\(counts[c] ?? 0)").font(.system(size: 11)).foregroundStyle(Theme.faint).monospacedDigit()
                            }
                            .padding(.horizontal, 8).frame(height: 30)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .frame(height: 280)
            HStack {
                Text(draft.categories.isEmpty ? "Pick two or more" : "\(draft.categories.count) categories, \(draft.categories.reduce(0) { $0 + (counts[$1] ?? 0) }) plugins")
                    .font(.system(size: 11)).foregroundStyle(Theme.faint)
                Spacer()
                QuietPill(title: "Cancel", height: 30) { close() }
                PrimaryPill(title: "Save", height: 30) {
                    let name = draft.name.trimmingCharacters(in: .whitespaces)
                    Pills.saveGroup(id: draft.groupID, name: name.isEmpty ? draft.categories.sorted().joined(separator: " + ") : name,
                                    categories: Array(draft.categories))
                    close()
                }
                .disabled(draft.categories.count < 2)
                .opacity(draft.categories.count < 2 ? 0.4 : 1)
            }
        }
        .padding(20)
        .frame(width: 400)
        .background(Theme.surface)
        .preferredColorScheme(.dark)
    }
}
