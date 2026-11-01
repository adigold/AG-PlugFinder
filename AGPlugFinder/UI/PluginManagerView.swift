import AppKit
import SwiftUI

/// Settings, Plugin Manager (BL-144): every plugin file in every format, duplicates, and removal
/// into a folder on the Desktop.
struct PluginManagerView: View {
    enum Mode: String, CaseIterable { case duplicates = "Duplicates", all = "All Plugins", installers = "By Installer" }
    @Bindable var manager = PluginManager.shared
    @State private var mode = Mode.duplicates
    @State private var search = ""
    @State private var formats: Set<PluginManager.Format> = []
    @State private var withLeftovers = true

    var body: some View {
        let notes = manager.notes()
        let shown = visible(notes)
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Plugin Manager").font(.system(size: Theme.ts(22), weight: .bold)).foregroundStyle(Theme.text)
                Text("Every plugin on this Mac in every format. Removing moves the files into a folder on your Desktop, so you can always put them back.")
                    .font(.system(size: Theme.ts(12))).foregroundStyle(Theme.faint)
            }
            HStack(spacing: 8) {
                BarIconButton(systemImage: "arrow.clockwise", help: "Scan again") { manager.scan() }
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass").foregroundStyle(Theme.faint)
                    TextField("", text: $search, prompt: Text("Search plugins").foregroundStyle(Theme.faint))
                        .textFieldStyle(.plain).foregroundStyle(Theme.text)
                }
                .padding(.horizontal, 12).frame(height: 30)
                .background(Capsule().fill(Theme.raised))
                ForEach(Mode.allCases, id: \.self) { m in
                    Chip(title: m.rawValue, on: mode == m) { mode = m }
                }
            }
            HStack(spacing: 6) {
                Chip(title: "All formats", on: formats.isEmpty) { formats = [] }
                ForEach(PluginManager.Format.allCases) { f in
                    Chip(title: f.rawValue, on: formats.contains(f)) {
                        if formats.contains(f) { formats.remove(f) } else { formats.insert(f) }
                    }
                }
            }
            header
            if manager.scanning && manager.items.isEmpty {
                ProgressView("Scanning your plugins…").frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if shown.isEmpty {
                Text(mode == .duplicates ? "No duplicates found." : "No plugins match.")
                    .font(.system(size: Theme.ts(13))).foregroundStyle(Theme.faint)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    VStack(spacing: 0) {
                        if mode == .installers {
                            ForEach(groupsByInstaller(shown), id: \.0) { pkg, list in
                                installerRow(pkg, list)
                                ForEach(list) { row($0, note: notes[$0.id]) }
                            }
                        } else {
                            ForEach(shown) { row($0, note: notes[$0.id]) }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .top)
                }
                .frame(maxHeight: .infinity, alignment: .top)
            }
            footer(shown)
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Theme.ground)
        .onAppear { if manager.lastScan == nil { manager.scan() } }
    }

    private func visible(_ notes: [String: PluginManager.Note]) -> [PluginManager.Item] {
        // Duplicates shows each whole group, so the copy that stays is right beside the others.
        let flagged = Set(manager.items.filter { notes[$0.id] != nil }.map(\.key))
        return manager.items.filter { i in
            (formats.isEmpty || formats.contains(i.format))
                && (search.isEmpty || i.name.localizedCaseInsensitiveContains(search) || (i.receipt ?? "").localizedCaseInsensitiveContains(search))
                && (mode != .duplicates || flagged.contains(i.key))
                && (mode != .installers || i.receipt != nil)
        }
        .sorted { $0.key == $1.key ? $0.format.rawValue < $1.format.rawValue : $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    private func groupsByInstaller(_ list: [PluginManager.Item]) -> [(String, [PluginManager.Item])] {
        Dictionary(grouping: list) { $0.receipt ?? "" }.sorted { $0.key < $1.key }.map { ($0.key, $0.value) }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Color.clear.frame(width: 18, height: 1)
            Text("Plugin").frame(maxWidth: .infinity, alignment: .leading)
            Text("Format").frame(width: 56, alignment: .leading)
            Text("Folder").frame(width: 58, alignment: .leading)
            Text("Installed").frame(width: 84, alignment: .leading)
            Text("Size").frame(width: 70, alignment: .trailing)
            Text("Version").frame(width: 70, alignment: .leading)
            Color.clear.frame(width: 22, height: 1)
        }
        .font(.system(size: Theme.ts(11), weight: .semibold)).foregroundStyle(Theme.faint)
        .padding(.horizontal, 10)
    }

    private func row(_ i: PluginManager.Item, note: PluginManager.Note?) -> some View {
        let on = manager.selected.contains(i.id)
        return HStack(spacing: 10) {
            CheckMark(on: on).onTapGesture { toggle(i) }
            HStack(spacing: 6) {
                Text(i.name).foregroundStyle(Theme.text).lineLimit(1)
                if let note {
                    Text(note.rawValue).font(.system(size: Theme.ts(10), weight: .semibold))
                        .foregroundStyle(note == .notLogic ? Theme.faint : Theme.warning)
                        .padding(.horizontal, 6).frame(height: 16)
                        .background(Capsule().strokeBorder(note == .notLogic ? Theme.edge : Theme.warning.opacity(0.6), lineWidth: 1))
                        .fixedSize()
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Text(i.format.rawValue).foregroundStyle(i.format.usedByLogic ? Theme.text : Theme.muted).frame(width: 56, alignment: .leading)
            Text(i.system ? "System" : "User").foregroundStyle(Theme.muted).frame(width: 58, alignment: .leading)
            Text(i.installed.map { $0.formatted(date: .numeric, time: .omitted) } ?? "").foregroundStyle(Theme.muted)
                .frame(width: 84, alignment: .leading)
            Text(ByteCountFormatter.string(fromByteCount: i.size, countStyle: .file)).foregroundStyle(Theme.muted).monospacedDigit()
                .frame(width: 70, alignment: .trailing)
            Text(i.version).foregroundStyle(Theme.muted).lineLimit(1).frame(width: 70, alignment: .leading)
            Button { NSWorkspace.shared.activateFileViewerSelecting([i.url]) } label: {
                Image(systemName: "magnifyingglass.circle").foregroundStyle(Theme.faint)
            }
            .buttonStyle(.plain).help("Show in Finder").frame(width: 22)
        }
        .font(.system(size: Theme.ts(12)))
        .padding(.horizontal, 10).frame(height: 32)
        .background(on ? Theme.raised : Color.clear)
        .contentShape(Rectangle())
        .onTapGesture { toggle(i) }
        .overlay(alignment: .bottom) { Rectangle().fill(Theme.rule).frame(height: 1) }
    }

    private func installerRow(_ pkg: String, _ list: [PluginManager.Item]) -> some View {
        let all = list.allSatisfy { manager.selected.contains($0.id) }
        return HStack(spacing: 10) {
            CheckMark(on: all, partial: !all && list.contains { manager.selected.contains($0.id) })
            Text(pkg).font(.system(size: Theme.ts(12), weight: .semibold)).foregroundStyle(Theme.text)
            Spacer()
            let extra = manager.leftoverFiles[pkg]?.count ?? 0
            Text("\(list.count) plugin\(list.count == 1 ? "" : "s")\(extra > 0 ? " + \(extra) other file\(extra == 1 ? "" : "s")" : "") · \(ByteCountFormatter.string(fromByteCount: list.reduce(0) { $0 + $1.size }, countStyle: .file))")
                .font(.system(size: Theme.ts(11))).foregroundStyle(Theme.faint)
        }
        .padding(.horizontal, 10).frame(height: 30)
        .background(Theme.surface)
        .contentShape(Rectangle())
        .onTapGesture {
            if all { manager.selected.subtract(list.map(\.id)) } else { manager.selected.formUnion(list.map(\.id)) }
        }
    }

    private func toggle(_ i: PluginManager.Item) {
        if manager.selected.contains(i.id) { manager.selected.remove(i.id) } else { manager.selected.insert(i.id) }
    }

    private func footer(_ shown: [PluginManager.Item]) -> some View {
        let chosen = manager.items.filter { manager.selected.contains($0.id) }
        let size = chosen.reduce(Int64(0)) { $0 + $1.size }
        let total = manager.items.reduce(Int64(0)) { $0 + $1.size }
        let extra = manager.leftovers(for: chosen).count
        return HStack(spacing: 10) {
            Text("\(manager.items.count) plugins · \(ByteCountFormatter.string(fromByteCount: total, countStyle: .file))")
                .font(.system(size: Theme.ts(11))).foregroundStyle(Theme.faint)
            if !shown.isEmpty {
                Button(shown.allSatisfy { manager.selected.contains($0.id) } ? "Select None" : "Select All Shown") {
                    if shown.allSatisfy({ manager.selected.contains($0.id) }) { manager.selected.subtract(shown.map(\.id)) }
                    else { manager.selected.formUnion(shown.map(\.id)) }
                }
                .buttonStyle(.plain).font(.system(size: Theme.ts(11), weight: .medium)).foregroundStyle(Theme.accent)
            }
            Spacer()
            if extra > 0 {
                HStack(spacing: 6) {
                    CheckMark(on: withLeftovers)
                    Text("Also the installer's \(extra) other file\(extra == 1 ? "" : "s")").font(.system(size: Theme.ts(11))).foregroundStyle(Theme.muted)
                }
                .contentShape(Rectangle())
                .onTapGesture { withLeftovers.toggle() }
                .help("Support files, presets and manuals the same installer put in your Library folders. Moved only when every plugin from that installer is chosen.")
            }
            PrimaryPill(title: chosen.isEmpty ? "Move to Desktop" : "Move \(chosen.count) to Desktop (\(ByteCountFormatter.string(fromByteCount: size, countStyle: .file)))",
                        systemImage: "tray.and.arrow.down", height: 32) { remove(chosen) }
                .disabled(chosen.isEmpty)
                .opacity(chosen.isEmpty ? 0.5 : 1)
        }
    }

    private func remove(_ chosen: [PluginManager.Item]) {
        guard !chosen.isEmpty else { return }
        let system = chosen.filter(\.system).count
        let extra = withLeftovers ? manager.leftovers(for: chosen) : []
        let names = chosen.prefix(5).map { "\($0.name).\($0.url.pathExtension)" }.joined(separator: ", ") + (chosen.count > 5 ? "…" : "")
        guard Dialog.confirm("Move \(chosen.count) plugin\(chosen.count == 1 ? "" : "s") to your Desktop?",
                             message: "\(names)\n\nThey go into a Removed Plugins folder on your Desktop. Drag them back to their folder to put them back."
                                + (extra.isEmpty ? "" : " \(extra.count) other file\(extra.count == 1 ? "" : "s") from the same installer go along, in Other Files, under the folders they came from.")
                                + (system > 0 ? " \(system) are in the system folder, so your Mac asks for its password once." : ""),
                             ok: "Move to Desktop") else { return }
        let r = manager.moveToDesktop(chosen, leftovers: extra)
        let failed = r.failed.isEmpty ? "" : " \(r.failed.count) could not be moved: \(r.failed.prefix(4).joined(separator: ", "))."
        let open = Dialog.show("Moved \(r.moved) plugin\(r.moved == 1 ? "" : "s") to your Desktop",
                               message: "They are in “\(r.folder.lastPathComponent)” on your Desktop.\(r.extras > 0 ? " \(r.extras) other file\(r.extras == 1 ? "" : "s") from their installers are in Other Files." : "")\(failed) To put one back, drag it to its folder in Library/Audio/Plug-Ins.",
                               choices: [Dialog.Choice(title: "OK", cancel: true), Dialog.Choice(title: "Show Folder", primary: true)])
        if open.index == 1 { NSWorkspace.shared.open(r.folder) }
    }
}
