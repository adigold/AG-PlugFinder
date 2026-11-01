import SwiftUI

struct SettingsView: View {
    var body: some View {
        TabView {
            GeneralSettings()
                .tabItem { Label("General", systemImage: "gearshape") }
            ShortcutSettings()
                .tabItem { Label("Shortcuts", systemImage: "keyboard") }
            PluginListEditor()
                .tabItem { Label("Plugin List", systemImage: "list.bullet.rectangle") }
            PillsEditor()
                .tabItem { Label("Pills", systemImage: "capsule") }
            LicensesView(topPadding: 22)
                .tabItem { Label("Licenses", systemImage: "creditcard") }
            UpdateSettings()
                .tabItem { Label("Updates", systemImage: "arrow.down.circle") }
        }
        .frame(width: 780, height: 580)
        .preferredColorScheme(.dark)
    }
}

struct GeneralSettings: View {
    @State private var apiKey = ""
    @State private var keySaved = Keychain.read() != nil
    @State private var launchAtLogin = LaunchAtLogin.isEnabled
    @State private var trusted = AXAccess.isTrusted
    @State private var model = PluginInfoFetcher.shared.model
    @State private var diagnosticsNote = ""
    @State private var sync = UserLibrary.shared.syncEnabled

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
                Toggle("Show mono and stereo versions as one plugin", isOn: Bindable(ViewSettings.shared).joinMonoStereo)
                Text("For example API-550A (m) and (s) show once. Logic gets the mono version on a mono track and the stereo version on a stereo track. Right-click a plugin to choose one yourself.")
                    .font(.caption).foregroundStyle(.secondary)
                Toggle("Preview with the Space bar", isOn: Bindable(ViewSettings.shared).spacePreview)
                Text("Click a plugin and press Space to see it large, with what it does. Arrows move to the next one, Space or Esc closes it. After typing a search, press Tab to move to the results; Shift+Tab goes back to the search.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("Sync") {
                Toggle("Sync with my other Macs through iCloud Drive", isOn: $sync)
                    .onChange(of: sync) { _, on in UserLibrary.shared.syncEnabled = on }
                    .disabled(UserLibrary.cloudFile == nil)
                Text(UserLibrary.cloudFile == nil
                     ? "Turn on iCloud Drive in System Settings to sync favorites, collections, chains, notes, number keys, hidden plugins and licenses."
                     : "Favorites, collections, chains, notes, number keys, hidden plugins, licenses and subscriptions. License keys stay on each Mac"
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
