import AppKit
import SwiftUI

/// Plugins you don't use (BL-99): how many, the disk space they take and what they cost, with
/// one click to hide them or show them in Finder to uninstall. Counted from the plugins added
/// with AG PlugFinder.
struct UnusedView: View {
    enum Span: String, CaseIterable { case never = "Never used", half = "Not used in 6 months" }
    enum Order: String, CaseIterable { case size = "Biggest first", maker = "By maker", name = "By name" }

    var store = PluginStore.shared
    var library = UserLibrary.shared
    var lic = Licenses.shared
    @State private var span: Span = .never
    @State private var order: Order = .size
    @State private var sizes: [String: Int64] = [:]
    @State private var checked: Set<String> = []
    @State private var showHidden = false

    private var list: [Plugin] {
        let cutoff = Calendar.current.date(byAdding: .month, value: -6, to: Date()) ?? Date()
        let all = store.plugins.filter { p in
            // Apple's own plugins come with macOS and can't be uninstalled.
            guard !p.isLogic, p.manufacturer != "Apple", store.isVisible(p) != showHidden else { return false }
            let used = (library.useCount[p.id] ?? 0) > 0 || store.lastUsed[p.id] != nil
            switch span {
            case .never: return !used
            case .half: return !used || (store.lastUsed[p.id].map { $0 < cutoff } ?? false)
            }
        }
        switch order {
        case .size: return all.sorted { (sizes[$0.id] ?? 0) == (sizes[$1.id] ?? 0) ? $0.name < $1.name : (sizes[$0.id] ?? 0) > (sizes[$1.id] ?? 0) }
        case .maker: return all.sorted { $0.manufacturer == $1.manufacturer ? $0.name < $1.name : $0.manufacturer < $1.manufacturer }
        case .name: return all.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        }
    }

    private func paid(_ p: Plugin) -> Double? { lic.licenses[p.id]?.price }

    var body: some View {
        let items = list
        // Plugins that share one file count it once.
        var seen = Set<String>()
        let bytes = items.reduce(Int64(0)) { t, p in seen.insert(p.path ?? p.id).inserted ? t + (sizes[p.id] ?? 0) : t }
        let money = items.compactMap(paid).reduce(0, +)
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                tile(showHidden ? "Hidden" : span.rawValue, "\(items.count) plugin\(items.count == 1 ? "" : "s")",
                     showHidden ? "Hidden from the library" : "Counted from what you added with AG PlugFinder")
                tile("Disk space", sizes.isEmpty && !items.isEmpty ? "Measuring…" : ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file),
                     "What uninstalling them would free")
                tile("You paid", money > 0 ? lic.money(money) : "Not entered", money > 0 ? "From your licenses" : "Add prices in My Purchases")
            }
            HStack(spacing: 6) {
                ForEach(Span.allCases, id: \.self) { s in Chip(title: s.rawValue, on: span == s && !showHidden) { span = s; showHidden = false; checked = [] } }
                Chip(title: "Hidden", systemImage: "eye.slash", on: showHidden) { showHidden.toggle(); checked = [] }
                Spacer()
                ForEach(Order.allCases, id: \.self) { o in Chip(title: o.rawValue, on: order == o) { order = o } }
            }
            if !checked.isEmpty { bulkBar }
            ScrollView {
                LazyVStack(spacing: 0) {
                    if items.isEmpty {
                        Text(showHidden ? "No hidden plugins." : "Nothing here. You use every plugin you have.")
                            .font(.system(size: Theme.ts(13))).foregroundStyle(Theme.faint).padding(20)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    ForEach(items) { p in row(p) }
                }
            }
            .background(RoundedRectangle(cornerRadius: Theme.radiusInner).fill(Theme.surface))
        }
        .task { await measure() }
    }

    private func tile(_ title: String, _ value: String, _ sub: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.system(size: Theme.ts(11))).foregroundStyle(Theme.faint)
            Text(value).font(.system(size: Theme.ts(17), weight: .bold)).foregroundStyle(Theme.text).lineLimit(1).minimumScaleFactor(0.7)
            Text(sub).font(.system(size: Theme.ts(11))).foregroundStyle(Theme.muted).lineLimit(2)
        }
        .padding(12)
        .frame(maxWidth: .infinity, minHeight: 96, maxHeight: 96, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: Theme.radiusInner).fill(Theme.surface))
    }

    private var bulkBar: some View {
        HStack(spacing: 8) {
            Text("\(checked.count) selected").font(.system(size: Theme.ts(12), weight: .semibold)).foregroundStyle(Theme.text)
            Spacer()
            if showHidden {
                QuietPill(title: "Show in Library", systemImage: "eye", height: 28) { setVisible(checked, true) }
            } else {
                QuietPill(title: "Hide from Library", systemImage: "eye.slash", height: 28) { setVisible(checked, false) }
            }
            QuietPill(title: "Show in Finder", systemImage: "folder", height: 28) { reveal(checked) }
            QuietPill(title: "Clear", height: 28) { checked = [] }
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .background(RoundedRectangle(cornerRadius: Theme.radiusInner).fill(Theme.raised))
    }

    private func row(_ p: Plugin) -> some View {
        let on = checked.contains(p.id)
        var sub = [p.manufacturer]
        if let last = store.lastUsed[p.id] { sub.append("last used \(last.formatted(.relative(presentation: .named)))") }
        return HStack(spacing: 12) {
            Button { if on { checked.remove(p.id) } else { checked.insert(p.id) } } label: { CheckMark(on: on) }
                .buttonStyle(.plain)
            PluginThumbnail(plugin: p, radius: 6).frame(width: 54, height: 36)
            VStack(alignment: .leading, spacing: 2) {
                Text(p.name).font(.system(size: Theme.ts(13), weight: .medium)).foregroundStyle(Theme.text).lineLimit(1)
                Text(sub.joined(separator: " · ")).font(.system(size: Theme.ts(11))).foregroundStyle(Theme.faint).lineLimit(1)
            }
            Spacer()
            if let v = paid(p) { Text(lic.money(v)).font(.system(size: Theme.ts(12))).foregroundStyle(Theme.muted).monospacedDigit() }
            Text(sizes[p.id].map { ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) } ?? "…")
                .font(.system(size: Theme.ts(12))).foregroundStyle(Theme.muted).monospacedDigit().frame(width: 70, alignment: .trailing)
            BarIconButton(systemImage: showHidden ? "eye" : "eye.slash", help: showHidden ? "Show in the library again" : "Hide from the library") {
                setVisible([p.id], showHidden)
            }
            BarIconButton(systemImage: "folder", help: "Show in Finder, to uninstall it") { reveal([p.id]) }
        }
        .padding(.horizontal, 14).frame(height: 52)
        .contentShape(Rectangle())
        .onTapGesture { if on { checked.remove(p.id) } else { checked.insert(p.id) } }
        .overlay(alignment: .bottom) { Rectangle().fill(Theme.rule).frame(height: 1) }
    }

    private func setVisible(_ ids: Set<String>, _ visible: Bool) {
        for id in ids { store.setPlugin(id, visible: visible) }
        Toast.show(visible ? "Back in the library: \(ids.count)" : "Hidden from the library: \(ids.count). Find them under Hidden.")
        checked = []
    }

    private func reveal(_ ids: Set<String>) {
        let urls = ids.compactMap { store.plugin($0)?.path }.map { URL(fileURLWithPath: $0) }
        guard !urls.isEmpty else { Toast.show("Couldn't find where these are installed.", warning: true); return }
        NSWorkspace.shared.activateFileViewerSelecting(urls)
    }

    private func measure() async {
        let entries = store.plugins.filter { !$0.isLogic }.compactMap { p in p.path.map { (p.id, $0) } }
        let result = await Task.detached { () -> [String: Int64] in
            var out: [String: Int64] = [:]
            for (id, path) in entries { out[id] = ReportView.folderSize(path) }
            return out
        }.value
        sizes = result
    }
}
