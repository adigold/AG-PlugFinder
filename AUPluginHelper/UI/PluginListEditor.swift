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
                        Divider().padding(.vertical, 4)
                        ForEach(groups, id: \.value) { g in
                            groupRow(title: g.value, count: "\(g.shown)/\(g.total)",
                                     state: g.shown == 0 ? false : (g.shown == g.total ? true : nil),
                                     selected: selectedGroup == g.value,
                                     onCheck: { store.setGroup(kind, g.value, visible: g.shown < g.total) }) {
                                selectedGroup = g.value
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
                                            Text("\(p.manufacturer) · \(p.displayCategory) · \(p.formatName)")
                                                .font(.system(size: 10)).foregroundStyle(.secondary)
                                        }
                                        Spacer()
                                    }
                                    .padding(.horizontal, 6).padding(.vertical, 3)
                                    .contentShape(Rectangle())
                                    .opacity(visible ? 1 : 0.5)
                                }
                                .buttonStyle(.plain)
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
