import SwiftUI

struct SettingsView: View {
    var body: some View {
        TabView {
            GeneralSettings()
                .tabItem { Label("General", systemImage: "gearshape") }
            PluginListEditor()
                .tabItem { Label("Plugin List", systemImage: "list.bullet.rectangle") }
            UpdateSettings()
                .tabItem { Label("Updates", systemImage: "arrow.down.circle") }
        }
        .frame(width: 760, height: 560)
    }
}

struct GeneralSettings: View {
    @State private var apiKey = ""
    @State private var keySaved = Keychain.read() != nil
    @State private var launchAtLogin = LaunchAtLogin.isEnabled
    @State private var trusted = AXAccess.isTrusted
    @State private var model = PluginInfoFetcher.shared.model
    @State private var diagnosticsNote = ""

    var body: some View {
        Form {
            Section("General") {
                Toggle("Open at login", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, on in LaunchAtLogin.set(on) }
                LabeledContent("Picker hotkey", value: HotKey.display)
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
            }

            Section("Plugin info (Claude API)") {
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
                            Button {
                                model = m
                                PluginInfoFetcher.shared.model = m
                            } label: {
                                Text("\(m.title) (~$\(String(format: "%.2f", m.estimatedCostPerPlugin))/plugin)")
                                    .font(.system(size: 12))
                                    .padding(.horizontal, 10).padding(.vertical, 5)
                                    .background(Capsule().fill(model == m ? Theme.accent.opacity(0.85)
                                                                          : Color.primary.opacity(0.06)))
                                    .foregroundStyle(model == m ? Color.black : Color.primary)
                            }.buttonStyle(.plain)
                        }
                    }
                }
                Text("The key is stored in your Mac's Keychain. Plugins are looked up only when you press Look Up Info.")
                    .font(.caption).foregroundStyle(.secondary)
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
