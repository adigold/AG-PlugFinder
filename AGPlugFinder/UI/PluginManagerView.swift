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
    /// The question and the answer show on this page itself, not in a separate window, so
    /// nothing can get stuck behind the Settings window (Adi's report, 2026-11-01).
    @State private var asking: [PluginManager.Item]?
    @State private var done: (folder: URL, moved: Int, failed: [String], extras: Int)?
    /// The list as filtered and sorted, worked out only when the search, a filter, the view or
    /// the scan changes, never on a click (BL-156).
    @State private var shown: [PluginManager.Item] = []
    @State private var groups: [(String, [PluginManager.Item])] = []

    private struct Filter: Hashable {
        var search: String; var formats: Set<PluginManager.Format>; var mode: Mode; var scan: Date?
    }

    init(asking: [PluginManager.Item]? = nil, formats: Set<PluginManager.Format> = [], mode: Mode = .duplicates) {
        _asking = State(initialValue: asking)
        _formats = State(initialValue: formats)
        _mode = State(initialValue: mode)
    }

    var body: some View {
        let notes = manager.notes()
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
            if manager.scanning {
                ScanTicker(manager: manager).frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if shown.isEmpty {
                Text(mode == .duplicates ? "No duplicates found." : "No plugins match.")
                    .font(.system(size: Theme.ts(13))).foregroundStyle(Theme.faint)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    // Only the rows on screen are drawn, so thousands of plugins scroll smoothly (BL-155).
                    LazyVStack(spacing: 0) {
                        if mode == .installers {
                            ForEach(groups, id: \.0) { pkg, list in
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
            summary(shown)
            footer(shown)
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Theme.ground)
        .overlay { if asking != nil || done != nil { card } }
        .onAppear { if manager.lastScan == nil { manager.scan() } }
        .onChange(of: Filter(search: search, formats: formats, mode: mode, scan: manager.lastScan), initial: true) { _, _ in
            shown = visible(manager.notes())
            groups = mode == .installers ? groupsByInstaller(shown) : []
        }
    }

    private func visible(_ notes: [String: PluginManager.Note]) -> [PluginManager.Item] {
        // Duplicates shows each whole group, so the copy that stays is right beside the others.
        let flagged = Set(manager.items.filter { notes[$0.id] != nil }.map(\.key))
        let list = manager.items.filter { i in
            (formats.isEmpty || formats.contains(i.format))
                && (search.isEmpty || i.name.localizedCaseInsensitiveContains(search) || (i.receipt ?? "").localizedCaseInsensitiveContains(search))
                && (mode != .duplicates || flagged.contains(i.key))
                && (mode != .installers || i.receipt != nil)
        }
        // The scan keeps plugins in name order; only Duplicates needs each group's copies together.
        guard mode == .duplicates else { return list }
        return list.sorted { $0.key == $1.key ? $0.format.rawValue < $1.format.rawValue : $0.key < $1.key }
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

    /// What the filters show and what the chosen plugins take on the disk (BL-159).
    private func summary(_ shown: [PluginManager.Item]) -> some View {
        let fmt = { (n: Int64) in ByteCountFormatter.string(fromByteCount: n, countStyle: .file) }
        let group = (formats.isEmpty ? "All formats" : PluginManager.Format.allCases.filter { formats.contains($0) }.map(\.rawValue).joined(separator: " + "))
            + (mode == .duplicates ? ", duplicates" : mode == .installers ? ", by installer" : "")
            + (search.isEmpty ? "" : ", matching “\(search)”")
        let shownSize = shown.reduce(Int64(0)) { $0 + $1.size }
        let chosen = manager.items.filter { manager.selected.contains($0.id) }
        let chosenSize = chosen.reduce(Int64(0)) { $0 + $1.size }
        return HStack(spacing: 10) {
            Image(systemName: "internaldrive").foregroundStyle(Theme.faint)
            Text("\(group): \(shown.count) plugin\(shown.count == 1 ? "" : "s") · \(fmt(shownSize))")
                .foregroundStyle(Theme.text)
            Spacer()
            if !chosen.isEmpty {
                // Moving keeps the files on this disk: the space comes back when the folder is deleted.
                Text("\(chosen.count) chosen: frees \(fmt(chosenSize)) once you delete the Desktop folder")
                    .foregroundStyle(Theme.accent)
            }
        }
        .font(.system(size: Theme.ts(12), weight: .medium)).monospacedDigit()
        .padding(.horizontal, 12).frame(height: 32)
        .background(RoundedRectangle(cornerRadius: 10).fill(Theme.surface))
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
                // Select every plugin shown (after the search and filters), or none (BL-155).
                Chip(title: "Select All (\(shown.count))", on: false) { manager.selected.formUnion(shown.map(\.id)) }
                Chip(title: "Deselect All", on: false) { manager.selected.removeAll() }
                    .disabled(manager.selected.isEmpty)
                    .opacity(manager.selected.isEmpty ? 0.5 : 1)
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
        done = nil
        asking = chosen
    }

    private func plural(_ n: Int, _ word: String) -> String { "\(n) \(word)\(n == 1 ? "" : "s")" }

    /// The question before moving, then what happened, over a dimmed list.
    private var card: some View {
        ZStack {
            Color.black.opacity(0.4).contentShape(Rectangle()).onTapGesture {}
            VStack(alignment: .leading, spacing: 12) {
                if let chosen = asking { question(chosen) } else if let r = done { answer(r) }
            }
            .padding(22)
            .frame(width: 440, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Theme.surface))
            .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Theme.edge, lineWidth: 1))
            .shadow(color: .black.opacity(0.35), radius: 24, y: 8)
        }
    }

    @ViewBuilder private func question(_ chosen: [PluginManager.Item]) -> some View {
        let folder = manager.nextFolder()
        let system = chosen.filter(\.system).count
        let extra = withLeftovers ? manager.leftovers(for: chosen) : []
        let names = chosen.prefix(5).map { "\($0.name).\($0.url.pathExtension)" }.joined(separator: ", ") + (chosen.count > 5 ? "…" : "")
        Text("Move \(plural(chosen.count, "plugin")) off your plugin folders?").font(.system(size: Theme.ts(16), weight: .bold)).foregroundStyle(Theme.text)
        Text(names).font(.system(size: Theme.ts(12))).foregroundStyle(Theme.muted).fixedSize(horizontal: false, vertical: true)
        HStack(spacing: 10) {
            Image(systemName: "folder.badge.plus").font(.system(size: Theme.ts(20))).foregroundStyle(Theme.accent)
            VStack(alignment: .leading, spacing: 2) {
                Text("This creates a folder on your Desktop").font(.system(size: Theme.ts(12), weight: .semibold)).foregroundStyle(Theme.text)
                Text("“\(folder.lastPathComponent)”").font(.system(size: Theme.ts(12))).foregroundStyle(Theme.muted)
            }
        }
        .padding(12).frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12).fill(Theme.raised))
        Text("The plugins go into it, one folder per format, so nothing is deleted. To put one back, drag it to its folder in Library/Audio/Plug-Ins."
             + (extra.isEmpty ? "" : " \(plural(extra.count, "other file")) from the same installer go along, in Other Files.")
             + (system > 0 ? " \(system) \(system == 1 ? "is" : "are") in the Mac's shared folder, so your Mac asks for its password once." : ""))
            .font(.system(size: Theme.ts(12))).foregroundStyle(Theme.faint).fixedSize(horizontal: false, vertical: true)
        HStack(spacing: 10) {
            Spacer()
            Button("Cancel") { asking = nil }
                .buttonStyle(.plain).font(.system(size: Theme.ts(13), weight: .medium)).foregroundStyle(Theme.text)
                .padding(.horizontal, 16).frame(height: 32).background(Capsule().fill(Theme.raised))
                .keyboardShortcut(.cancelAction)
            PrimaryPill(title: "Create Folder and Move", systemImage: "folder.badge.plus", height: 32) {
                asking = nil
                // After this click is finished, so the password prompt (if any) comes up cleanly.
                DispatchQueue.main.async { done = manager.moveToDesktop(chosen, leftovers: extra) }
            }
            .keyboardShortcut(.defaultAction)
        }
        .padding(.top, 4)
    }

    @ViewBuilder private func answer(_ r: (folder: URL, moved: Int, failed: [String], extras: Int)) -> some View {
        Text(r.moved > 0 ? "Moved \(plural(r.moved, "plugin")) to your Desktop" : "Nothing was moved")
            .font(.system(size: Theme.ts(16), weight: .bold)).foregroundStyle(Theme.text)
        Text((r.moved > 0 ? "They are in “\(r.folder.lastPathComponent)” on your Desktop." : "")
             + (r.extras > 0 ? " \(plural(r.extras, "other file")) from their installers are in Other Files." : "")
             + (r.failed.isEmpty ? "" : " \(r.failed.count) could not be moved: \(r.failed.prefix(4).joined(separator: ", ")). If your Mac asked for its password, it may have been cancelled."))
            .font(.system(size: Theme.ts(12))).foregroundStyle(Theme.muted).fixedSize(horizontal: false, vertical: true)
        HStack(spacing: 10) {
            Spacer()
            if r.moved > 0 || r.extras > 0 {
                Button("Show Folder") { NSWorkspace.shared.open(r.folder) }
                    .buttonStyle(.plain).font(.system(size: Theme.ts(13), weight: .medium)).foregroundStyle(Theme.text)
                    .padding(.horizontal, 16).frame(height: 32).background(Capsule().fill(Theme.raised))
            }
            PrimaryPill(title: "Done", height: 32) { done = nil }.keyboardShortcut(.defaultAction)
        }
        .padding(.top, 4)
    }
}

/// The scan as it happens (BL-151): the file being read slides in on top, the ones before it
/// fade down the list, with how many plugin files were found so far.
struct ScanTicker: View {
    var manager: PluginManager

    var body: some View {
        VStack(spacing: 14) {
            ProgressView().controlSize(.small)
            Text(manager.scanStep).font(.system(size: Theme.ts(13), weight: .semibold)).foregroundStyle(Theme.text)
            // How many are left (BL-154): done of total, with a bar.
            VStack(spacing: 6) {
                Text(manager.scanTotal > 0
                     ? "\(manager.scanDone) of \(manager.scanTotal) \(manager.scanStep.hasPrefix("Looking") ? "plugin files" : manager.scanStep.hasPrefix("Matching") ? "installers" : "files")"
                     : "Getting ready")
                    .font(.system(size: Theme.ts(12), weight: .medium)).monospacedDigit().foregroundStyle(Theme.muted)
                    .contentTransition(.numericText())
                ZStack(alignment: .leading) {
                    Capsule().fill(Theme.raised)
                    Capsule().fill(Theme.accent)
                        .frame(width: manager.scanTotal > 0 ? 260 * CGFloat(manager.scanDone) / CGFloat(manager.scanTotal) : 0)
                }
                .frame(width: 260, height: 5)
                .animation(.easeOut(duration: 0.15), value: manager.scanDone)
            }
            VStack(spacing: 4) {
                ForEach(Array(manager.scanTrail.enumerated()), id: \.element) { i, name in
                    Text(name)
                        .font(.system(size: Theme.ts(i == 0 ? 13 : 12), weight: i == 0 ? .medium : .regular, design: .monospaced))
                        .foregroundStyle(i == 0 ? Theme.text : Theme.muted)
                        .opacity(1 - Double(i) * 0.1)
                        .lineLimit(1).truncationMode(.middle)
                        .transition(.asymmetric(insertion: .move(edge: .top), removal: .opacity))
                }
            }
            .frame(width: 380, height: 150, alignment: .top)
            .clipped()
            .animation(.spring(duration: 0.25, bounce: 0.1), value: manager.scanTrail)
        }
        .animation(.easeOut(duration: 0.2), value: manager.scanDone)
    }
}
