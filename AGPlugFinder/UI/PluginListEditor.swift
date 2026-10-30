import SwiftUI

/// Settings → Plugin List: hide or show plugins by manufacturer, category, format or type,
/// or one at a time. Hidden plugins never appear in the popup or the library.
struct PluginListEditor: View {
    var store = PluginStore.shared
    @State private var kind: PluginStore.GroupKind = .maker
    @State private var selectedGroup: String?
    @State private var search = ""

    private var groups: [(value: String, total: Int, shown: Int)] {
        let byValue = Dictionary(grouping: store.plugins) { PluginStore.groupValue($0, kind) }
        return byValue.map { (value: $0.key, total: $0.value.count,
                              shown: $0.value.filter(store.isVisible).count) }
            .sorted { $0.value.localizedCaseInsensitiveCompare($1.value) == .orderedAscending }
    }

    private var pluginsInView: [Plugin] {
        let words = search.lowercased().split(separator: " ").map(String.init)
        return store.plugins
            .filter { p in selectedGroup.map { PluginStore.groupValue(p, kind) == $0 } ?? true }
            .filter { p in
                let hay = "\(p.name) \(p.manufacturer) \(p.displayCategory) \(p.formatName)".lowercased()
                return words.allSatisfy { hay.contains($0) }
            }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 4) {
                Text("Group by").font(.system(size: 12)).foregroundStyle(.secondary)
                ForEach(PluginStore.GroupKind.allCases) { k in
                    Button { kind = k; selectedGroup = nil } label: {
                        Text(k.title)
                            .font(.system(size: 12, weight: kind == k ? .semibold : .regular))
                            .padding(.horizontal, 10).padding(.vertical, 5)
                            .background(Capsule().fill(kind == k ? Theme.accent.opacity(0.85)
                                                                 : Color.primary.opacity(0.06)))
                            .foregroundStyle(kind == k ? Color.black : Color.primary)
                    }.buttonStyle(.plain)
                }
                Spacer()
                Button("Show Everything") {
                    store.hiddenGroups = []; store.hiddenPlugins = []; store.shownPlugins = []
                }
            }

            HStack(alignment: .top, spacing: 12) {
                // Groups
                ScrollView {
                    VStack(alignment: .leading, spacing: 2) {
                        groupRow(title: "All plugins", count: "\(store.plugins.filter(store.isVisible).count)/\(store.plugins.count)",
                                 state: nil, selected: selectedGroup == nil) { selectedGroup = nil }
                            .contextMenu { BulkMenu(ids: store.plugins.map(\.id), name: "all plugins", isAll: true) }
                        Divider().padding(.vertical, 4)
                        ForEach(groups, id: \.value) { g in
                            groupRow(title: g.value, count: "\(g.shown)/\(g.total)",
                                     state: g.shown == 0 ? false : (g.shown == g.total ? true : nil),
                                     selected: selectedGroup == g.value,
                                     onCheck: { store.setGroup(kind, g.value, visible: g.shown < g.total) }) {
                                selectedGroup = g.value
                            }
                            .contextMenu {
                                Button("Show Only \(g.value)") { store.showOnly(kind, g.value) }
                                Button(g.shown == 0 ? "Show \(g.value)" : "Hide \(g.value)") {
                                    store.setGroup(kind, g.value, visible: g.shown == 0)
                                }
                                Divider()
                                BulkMenu(ids: store.plugins.filter { PluginStore.groupValue($0, kind) == g.value }.map(\.id),
                                         name: g.value)
                            }
                        }
                    }
                    .padding(6)
                }
                .frame(width: 250)
                .background(RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(0.04)))

                // Plugins
                VStack(alignment: .leading, spacing: 6) {
                    TextField("Filter this list", text: $search)
                        .textFieldStyle(.plain)
                        .padding(.horizontal, 10).padding(.vertical, 6)
                        .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.06)))
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 1) {
                            ForEach(pluginsInView) { p in
                                let visible = store.isVisible(p)
                                Button { store.setPlugin(p.id, visible: !visible) } label: {
                                    HStack(spacing: 8) {
                                        checkbox(visible)
                                        PluginThumbnail(plugin: p).frame(width: 46, height: 28)
                                        VStack(alignment: .leading, spacing: 1) {
                                            Text(p.name).font(.system(size: 12, weight: .medium))
                                            Text(p.isLogic ? "\(p.manufacturer) · \(p.displayCategory)"
                                                 : "\(p.manufacturer) · \(p.displayCategory) · \(p.formatName)")
                                                .font(.system(size: 10)).foregroundStyle(.secondary)
                                        }
                                        Spacer()
                                    }
                                    .padding(.horizontal, 6).padding(.vertical, 3)
                                    .contentShape(Rectangle())
                                    .opacity(visible ? 1 : 0.5)
                                }
                                .buttonStyle(.plain)
                                .contextMenu {
                                    Button(visible ? "Hide \(p.name)" : "Show \(p.name)") {
                                        store.setPlugin(p.id, visible: !visible)
                                    }
                                    Divider()
                                    BulkMenu(ids: [p.id], name: p.name)
                                }
                            }
                        }
                    }
                }
                .frame(maxWidth: .infinity)
            }
            Text("Hidden plugins don't appear in the picker or the library. Logic's legacy plugins start hidden.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding(16)
    }

    private func groupRow(title: String, count: String, state: Bool?, selected: Bool,
                          onCheck: (() -> Void)? = nil, onSelect: @escaping () -> Void) -> some View {
        HStack(spacing: 8) {
            if let onCheck {
                Button(action: onCheck) {
                    Image(systemName: state == true ? "checkmark.square.fill"
                          : state == false ? "square" : "minus.square.fill")
                        .foregroundStyle(state == false ? Color.secondary : Theme.accent)
                }.buttonStyle(.plain)
            }
            Text(title).font(.system(size: 12)).lineLimit(1)
            Spacer()
            Text(count).font(.system(size: 11)).monospacedDigit().foregroundStyle(.secondary)
        }
        .padding(.horizontal, 8).padding(.vertical, 5)
        .background(RoundedRectangle(cornerRadius: 6).fill(selected ? Theme.tileSelected : Color.clear))
        .contentShape(Rectangle())
        .onTapGesture(perform: onSelect)
    }

    private func checkbox(_ on: Bool) -> some View {
        Image(systemName: on ? "checkmark.square.fill" : "square")
            .foregroundStyle(on ? Theme.accent : .secondary)
    }
}

/// Screenshot and info actions for one plugin, a group, or everything.
struct BulkMenu: View {
    let ids: [String]
    let name: String
    var isAll = false
    var store = PluginStore.shared
    var snapshots = SnapshotQueue.shared
    var fetcher = PluginInfoFetcher.shared

    private var capturable: [String] {
        ids.filter { id in store.plugin(id).map { !$0.isLogic } ?? false }
    }
    private var missing: [String] {
        capturable.filter { !FileManager.default.fileExists(atPath: store.snapshotURL(for: $0).path) }
    }
    private var withoutInfo: [String] { ids.filter { store.plugin($0)?.details == nil } }

    var body: some View {
        if isAll {
            Button("Rescan Installed Plugins") { store.rescan() }
            Divider()
        }
        Button(missing.isEmpty ? "No Missing Screenshots" : "Take Missing Screenshots (\(missing.count))") {
            snapshots.start(only: Set(missing))
        }
        .disabled(missing.isEmpty || snapshots.isRunning)
        Button(capturable.count == 1 ? "Retake Screenshot" : "Retake Screenshots (\(capturable.count))") {
            snapshots.start(only: Set(capturable))
        }
        .disabled(capturable.isEmpty || snapshots.isRunning)
        Button(capturable.count == 1 ? "Clear Screenshot" : "Clear Screenshots (\(capturable.count))") {
            store.clearScreenshots(capturable)
        }
        .disabled(capturable.isEmpty || snapshots.isRunning)
        Divider()
        Button(withoutInfo.isEmpty ? "Look Up Info Again (\(ids.count))" : "Look Up Missing Info (\(withoutInfo.count))") {
            fetcher.start(ids: withoutInfo.isEmpty ? ids : withoutInfo)
        }
        .disabled(fetcher.isRunning || !fetcher.hasKey)
        Button("Clear Info") { store.clearInfo(ids) }
            .disabled(ids.allSatisfy { store.plugin($0)?.details == nil })
        if isAll {
            Divider()
            Button("Show Screenshot Folder") { NSWorkspace.shared.open(store.thumbsDir) }
        }
    }
}
