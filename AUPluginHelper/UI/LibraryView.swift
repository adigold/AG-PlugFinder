import SwiftUI

/// The main window: the same browser plus scanning, screenshots and info lookup controls.
struct LibraryView: View {
    @State private var model = PickerModel()
    @State private var confirmLookup = false
    var store = PluginStore.shared
    var snapshots = SnapshotQueue.shared
    var fetcher = PluginInfoFetcher.shared

    var body: some View {
        VStack(spacing: 0) {
            SearchBar(model: model, focusOnAppear: false)
                .padding(12)
            statusBar
            Divider()
            HStack(spacing: 0) {
                PluginGrid(model: model) { insert() }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                Divider()
                Group {
                    if let p = model.selected {
                        PluginDetailView(plugin: p) { insert() }
                    } else { Color.clear }
                }
                .frame(width: 310)
            }
            if let message = model.message {
                Divider()
                HStack {
                    Text(message).font(.system(size: 12))
                    Spacer()
                    if model.showAccessibilityButton {
                        Button("Open Accessibility Settings") { AXAccess.openSettings() }
                    }
                }.padding(10)
            }
        }
        .toolbar {
            ToolbarItemGroup {
                Button { store.rescan(); snapshots.start() } label: {
                    Label("Rescan Plugins", systemImage: "arrow.clockwise")
                }.help("Find newly installed plugins")
                Button { snapshots.start(force: true) } label: {
                    Label("Retake Screenshots", systemImage: "camera")
                }.help("Capture every plugin's window again")
                    .disabled(snapshots.isRunning)
                Button { confirmLookup = true } label: {
                    Label("Look Up Info", systemImage: "sparkles")
                }.help("Look up each plugin's summary and best feature")
                    .disabled(fetcher.isRunning || fetcher.missingCount() == 0)
            }
        }
        .alert("Look up \(fetcher.missingCount()) plugins?", isPresented: $confirmLookup) {
            Button("Look Up") { fetcher.start() }
            Button("Cancel", role: .cancel) {}
        } message: {
            let n = fetcher.missingCount()
            let cost = Double(n) * fetcher.model.estimatedCostPerPlugin
            Text("This uses your Anthropic API key with \(fetcher.model.title) and web search. " +
                 "Estimated cost about $\(String(format: "%.2f", cost)) (\(n) plugins). " +
                 "Each plugin is looked up once and saved.")
        }
    }

    private func insert() { model.insertSelected() }

    @ViewBuilder private var statusBar: some View {
        HStack(spacing: 18) {
            Text("\(store.plugins.count) Audio Units").foregroundStyle(.secondary)
            if snapshots.isRunning {
                HStack(spacing: 6) {
                    ProgressView(value: Double(snapshots.done), total: Double(max(1, snapshots.total)))
                        .frame(width: 120)
                    Text("Screenshots \(snapshots.done)/\(snapshots.total): \(snapshots.currentName)")
                        .lineLimit(1)
                    Button("Stop") { snapshots.cancel() }.buttonStyle(.link)
                }
            }
            if fetcher.isRunning {
                HStack(spacing: 6) {
                    ProgressView(value: Double(fetcher.done), total: Double(max(1, fetcher.total)))
                        .frame(width: 120)
                    Text("Info \(fetcher.done)/\(fetcher.total)")
                    Button("Stop") { fetcher.cancel() }.buttonStyle(.link)
                }
            } else if let e = fetcher.lastError {
                Text(e).foregroundStyle(.red).lineLimit(1)
            }
            Spacer()
            Text("Open the picker from anywhere with \(HotKey.display)").foregroundStyle(.secondary)
        }
        .font(.system(size: 11))
        .padding(.horizontal, 14).padding(.bottom, 8)
    }
}
