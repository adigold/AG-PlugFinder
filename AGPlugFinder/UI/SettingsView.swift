import SwiftUI

struct SettingsView: View {
    var body: some View {
        TabView {
            GeneralSettings()
                .tabItem { Label("General", systemImage: "gearshape") }
            AppearanceSettingsView()
                .tabItem { Label("Appearance", systemImage: "paintpalette") }
            ShortcutSettings()
                .tabItem { Label("Shortcuts", systemImage: "keyboard") }
            PluginListEditor()
                .tabItem { Label("Plugin List", systemImage: "list.bullet.rectangle") }
            PillsEditor()
                .tabItem { Label("Pills", systemImage: "capsule") }
            PluginManagerView()
                .tabItem { Label("Plugin Manager", systemImage: "shippingbox") }
            LicensesView(topPadding: 22)
                .tabItem { Label("My Purchases", systemImage: "creditcard") }
            UpdateSettings()
                .tabItem { Label("Updates", systemImage: "arrow.down.circle") }
        }
        .frame(width: 780, height: 580)
        .preferredColorScheme(Theme.scheme)
    }
}

/// Import from Logic (BL-139): shows what it found, and adds it only on OK.
@MainActor
private func importFromLogic() {
    let f = LogicTags.found()
    let pluginCount = Set(f.categories.values.flatMap { $0 }).count
    guard !f.favorites.isEmpty || !f.categories.isEmpty else {
        Dialog.show("Nothing to import", message: "Logic has no favorites or categories of your own for the plugins on this Mac.",
                    choices: [Dialog.Choice(title: "OK", primary: true)])
        return
    }
    var parts: [String] = []
    if !f.favorites.isEmpty { parts.append("\(f.favorites.count) favorite\(f.favorites.count == 1 ? "" : "s")") }
    if !f.categories.isEmpty {
        parts.append("\(f.categories.count) categor\(f.categories.count == 1 ? "y" : "ies") with \(pluginCount) plugin\(pluginCount == 1 ? "" : "s")")
    }
    let names = f.categories.keys.sorted().prefix(6).joined(separator: ", ") + (f.categories.count > 6 ? "…" : "")
    guard Dialog.confirm("Import from Logic?",
                         message: "Found \(parts.joined(separator: " and ")).\(f.categories.isEmpty ? "" : " Categories: \(names).") Favorites are added to yours and each category becomes a collection.",
                         ok: "Import") else { return }
    let r = LogicTags.importIntoLibrary(f)
    Toast.show("Imported from Logic: \(r.favorites) new favorite\(r.favorites == 1 ? "" : "s"), \(r.collections) new collection\(r.collections == 1 ? "" : "s").")
}

struct GeneralSettings: View {
    @State private var apiKey = ""
    @State private var keySaved = Keychain.read() != nil
    @State private var launchAtLogin = LaunchAtLogin.isEnabled
    @State private var trusted = AXAccess.isTrusted
    @State private var model = PluginInfoFetcher.shared.model
    @State private var diagnosticsNote = ""
    @State private var sync = UserLibrary.shared.syncEnabled
    @State private var syncState = SyncProgressRow.State.idle

    var body: some View {
        Form {
            Section("General") {
                Toggle("Open at login", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, on in LaunchAtLogin.set(on) }
                LabeledContent("Open AG PlugFinder", value: HotKey.display)
                LabeledContent("Shortcuts", value: "Set every shortcut in the Shortcuts tab")
                Picker("Buttons above the plugins", selection: Bindable(ViewSettings.shared).chipRow) {
                    ForEach(ViewSettings.ChipRow.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                Picker("Before you type, show", selection: Bindable(ViewSettings.shared).startView) {
                    ForEach(ViewSettings.StartView.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                Text("What the library shows before you start typing. Most Used puts the plugins you add most often first, Never Used shows the ones you have not tried yet, and Nothing keeps the list clear until you type. A search or a category always shows everything that matches.")
                    .font(.caption).foregroundStyle(.secondary)
                Toggle("Show mono and stereo versions as one plugin", isOn: Bindable(ViewSettings.shared).joinMonoStereo)
                Text("For example API-550A (m) and (s) show once. Logic gets the mono version on a mono track and the stereo version on a stereo track. Right-click a plugin to choose one yourself.")
                    .font(.caption).foregroundStyle(.secondary)
                Toggle("Preview with the Space bar", isOn: Bindable(ViewSettings.shared).spacePreview)
                Text("Click a plugin and press Space to see it large, with what it does. Arrows move to the next one, Space or Esc closes it. After typing a search, press Tab to move to the results; Shift+Tab goes back to the search.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("From Logic") {
                LabeledContent("Logic's favorites and categories") {
                    Button("Import from Logic…") { importFromLogic() }
                }
                Text("Brings in the plugins you starred in Logic's Plug-in Manager and the categories you made there, as collections. Only adds; nothing in Logic changes.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("Sync") {
                Toggle("Sync with my other Macs through iCloud Drive", isOn: $sync)
                    .onChange(of: sync) { _, on in
                        UserLibrary.shared.syncEnabled = on
                        guard on else { syncState = .idle; return }
                        syncState = .syncing
                        Task {
                            // Long enough to see, even when iCloud answers at once.
                            async let done = UserLibrary.shared.syncNow()
                            try? await Task.sleep(for: .seconds(1.2))
                            syncState = await done ? .synced : .stillUploading
                        }
                    }
                    .disabled(UserLibrary.cloudFile == nil || syncState == .syncing)
                if syncState != .idle { SyncProgressRow(state: syncState) }
                // What syncs, chosen on each Mac (BL-157).
                ForEach(SyncSection.allCases) { section in
                    Toggle(section.title, isOn: Binding(
                        get: { !UserLibrary.shared.syncOff.contains(section.rawValue) },
                        set: { on in
                            if on { UserLibrary.shared.syncOff.remove(section.rawValue) }
                            else { UserLibrary.shared.syncOff.insert(section.rawValue) }
                        }))
                    .padding(.leading, 14)
                    .disabled(!sync || UserLibrary.cloudFile == nil)
                }
                Text(UserLibrary.cloudFile == nil
                     ? "Turn on iCloud Drive in System Settings to sync with your other Macs."
                     : "Turn off what this Mac should keep to itself. License keys stay in each Mac's own Keychain"
                        + (UserLibrary.shared.lastSynced.map { ". Last synced \($0.formatted(.relative(presentation: .named)))." } ?? "."))
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("Logic Pro") {
                LabeledContent("Accessibility") {
                    HStack {
                        Text(trusted ? "Allowed" : "Not allowed yet")
                            .foregroundStyle(trusted ? .green : .orange)
                        if !trusted {
                            Button("Allow…") { AXAccess.requestTrust(); AXAccess.openSettings() }
                        }
                    }
                }
                Text("Needed to place plugins in Logic's insert slots. Nothing else is controlled.")
                    .font(.caption).foregroundStyle(.secondary)
                Picker("Channel format", selection: Bindable(ChannelFormats.shared).mode) {
                    Text("Auto").tag(ChannelFormat.auto)
                    Text("Ask me").tag(ChannelFormat.ask)
                }
                .pickerStyle(.segmented)
                Text("When Logic has a plugin in several versions (Mono, Stereo, Mono to Stereo), Auto picks the one that fits the track and Ask me shows Logic's choice. A plugin can have its own choice in its info panel.")
                    .font(.caption).foregroundStyle(.secondary)
                HStack {
                    Button("Save Logic Interface Report") {
                        if let url = LogicInserter.shared.dumpDiagnostics() {
                            NSWorkspace.shared.activateFileViewerSelecting([url])
                            diagnosticsNote = "Saved. Send this file if inserting doesn't work."
                        } else {
                            diagnosticsNote = "Open Logic and allow Accessibility first."
                        }
                    }
                    Text(diagnosticsNote).font(.caption).foregroundStyle(.secondary)
                }
                HStack {
                    Button("Send Error Log to Goldi…") { CrashReports.sendLogs() }
                }
            }

            Section("Help other users") {
                Toggle("Share plugin pictures", isOn: Binding(
                    get: { PlugDB.sharing },
                    set: { PlugDB.sharing = $0; if $0 { PlugDB.shareExisting() } }))
                Text("Pictures the app takes of your plugins are shared, with each plugin's name and maker, so other users get them without waiting. Nothing else about you or your Mac is sent.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("Plugin info") {
                InfoSourcePicker()
                if PluginInfoFetcher.shared.source == .online {
                    SecureField(keySaved ? "Key saved in Keychain" : "Anthropic API key (sk-ant-…)", text: $apiKey)
                    HStack {
                        Button("Save Key") {
                            keySaved = Keychain.save(apiKey) && !apiKey.isEmpty
                            apiKey = ""
                        }.disabled(apiKey.isEmpty)
                        if keySaved {
                            Button("Remove Key") { Keychain.delete(); keySaved = false }
                        }
                    }
                    LabeledContent("Model") {
                        HStack(spacing: 4) {
                            ForEach(PluginInfoFetcher.Model.allCases) { m in
                                Chip(title: "\(m.title) (~$\(String(format: "%.2f", m.estimatedCostPerPlugin)) each)", on: model == m) {
                                    model = m
                                    PluginInfoFetcher.shared.model = m
                                }
                            }
                        }
                    }
                    Text("The key is stored in your Mac's Keychain. Plugins are looked up only when you press Look Up Info.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }

            Section("Cache") {
                Button("Show Screenshot Folder") {
                    NSWorkspace.shared.open(PluginStore.shared.thumbsDir)
                }
            }
        }
        .formStyle(.grouped)
        .padding(.vertical, 8)
        .onReceive(Timer.publish(every: 2, on: .main, in: .common).autoconnect()) { _ in
            trusted = AXAccess.isTrusted
        }
    }
}

/// Shown under the sync switch while the first sync runs (BL-131).
struct SyncProgressRow: View {
    enum State { case idle, syncing, synced, stillUploading }
    let state: State

    var body: some View {
        HStack(spacing: 10) {
            switch state {
            case .syncing:
                Image(systemName: "arrow.triangle.2.circlepath.icloud")
                    .font(.system(size: Theme.ts(16), weight: .medium)).foregroundStyle(Theme.accent)
                    .symbolEffect(.pulse, options: .repeating)
                ProgressView().progressViewStyle(.linear).tint(Theme.accent).frame(maxWidth: 220)
                Text("Syncing with iCloud…").font(.system(size: Theme.ts(12))).foregroundStyle(.secondary)
            case .synced:
                Image(systemName: "checkmark.icloud.fill")
                    .font(.system(size: Theme.ts(16))).foregroundStyle(.green)
                    .symbolEffect(.bounce, value: state == .synced)
                Text("Synced to iCloud.").font(.system(size: Theme.ts(12))).foregroundStyle(.secondary)
            case .stillUploading:
                Image(systemName: "icloud.and.arrow.up")
                    .font(.system(size: Theme.ts(16))).foregroundStyle(.secondary)
                Text("Saved to iCloud Drive. It is still uploading and finishes in the background.")
                    .font(.system(size: Theme.ts(12))).foregroundStyle(.secondary)
            case .idle:
                EmptyView()
            }
        }
        .transition(.opacity)
        .animation(.easeOut(duration: 0.2), value: state)
    }
}
