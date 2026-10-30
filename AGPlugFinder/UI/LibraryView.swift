import AppKit
import SwiftUI

/// The main window: the same browser plus scanning, screenshots and info lookup controls.
/// Arrow keys browse, Return inserts, Esc clears the search. The pin keeps it above Logic and
/// mini mode shrinks it to a small floating search list.
struct LibraryView: View {
    @State private var model = PickerModel()
    @State private var confirmLookup = false
    @State private var window: NSWindow?
    @State private var keyMonitor: Any?
    @State private var pinned = UserDefaults.standard.bool(forKey: "library.pinned")
    @State private var mini = false
    @State private var fullFrame: NSRect?
    var store = PluginStore.shared
    var snapshots = SnapshotQueue.shared
    var fetcher = PluginInfoFetcher.shared

    var body: some View {
        Group {
            if mini { miniBody } else { fullBody }
        }
        .background(WindowAccessor { w in
            guard window !== w else { return }
            window = w
            applyPin()
        })
        .onAppear(perform: installKeys)
        .onDisappear(perform: removeKeys)
        .toolbar(removing: .title)
        .toolbar { toolbarContent }
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

    // MARK: Mini mode

    private var miniBody: some View {
        VStack(spacing: 0) {
            SearchBar(model: model, focusOnAppear: true, compact: true)
                .padding(10)
            Divider()
            PluginGrid(model: model, compact: true) { insert() }
            Divider()
            HStack(spacing: 8) {
                if let p = model.selected {
                    Text(p.name).font(.system(size: 12, weight: .semibold)).lineLimit(1)
                }
                Spacer()
                Button(action: insert) {
                    Label(model.isBusy ? "Adding…" : "Insert", systemImage: "plus.rectangle.on.rectangle")
                        .font(.system(size: 12, weight: .semibold))
                        .padding(.horizontal, 12).frame(height: 28)
                        .background(RoundedRectangle(cornerRadius: 8).fill(Theme.accent))
                        .foregroundStyle(Color.black)
                }
                .buttonStyle(.plain)
                .disabled(model.selected == nil || model.isBusy)
            }
            .padding(10)
            if let message = model.message {
                Text(message).font(.system(size: 11)).foregroundStyle(.orange)
                    .padding(.horizontal, 10).padding(.bottom, 8)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    // MARK: Full window

    private var fullBody: some View {
        VStack(spacing: 0) {
            SearchBar(model: model, focusOnAppear: false)
                .padding(12)
            UpdateBanner()
            statusBar
            Divider()
            HStack(spacing: 0) {
                PluginGrid(model: model) { insert() }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                if ViewSettings.shared.showInfoPane {
                    Divider()
                    Group {
                        if let p = model.selected {
                            PluginDetailView(plugin: p, model: model) { insert() }
                        } else { Color.clear }
                    }
                    .frame(width: 310)
                }
            }
            if !ViewSettings.shared.showInfoPane, let message = model.message {
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
    }

    @ToolbarContentBuilder private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .principal) {
            HStack(spacing: 7) {
                Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 20, height: 20)
                Text("AG PlugFinder").font(.system(size: 14, weight: .semibold))
            }
        }
        ToolbarItemGroup(placement: .automatic) {
            if !mini {
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
            Button { pinned.toggle(); UserDefaults.standard.set(pinned, forKey: "library.pinned"); applyPin() } label: {
                Label("Keep on Top", systemImage: pinned ? "pin.fill" : "pin")
            }
            .help(pinned ? "Stop keeping this window above other apps" : "Keep this window above Logic")
            Button { toggleMini() } label: {
                Label("Mini Mode", systemImage: mini ? "arrow.up.left.and.arrow.down.right"
                                                     : "arrow.down.right.and.arrow.up.left")
            }
            .help(mini ? "Back to the full window" : "Shrink to a small floating window")
        }
        if !mini {
            ToolbarItem(placement: .automatic) {
                VersionBadge()
            }
        }
    }

    private func applyPin() {
        window?.level = (pinned || mini) ? .floating : .normal
        window?.collectionBehavior = (pinned || mini) ? [.canJoinAllSpaces, .fullScreenAuxiliary] : []
    }

    private func toggleMini() {
        guard let window else { mini.toggle(); return }
        if mini {
            mini = false
            if let f = fullFrame { window.setFrame(f, display: true, animate: true) }
        } else {
            fullFrame = window.frame
            mini = true
            let size = NSSize(width: 380, height: 480)
            let origin = NSPoint(x: window.frame.maxX - size.width, y: window.frame.maxY - size.height)
            window.setFrame(NSRect(origin: origin, size: size), display: true, animate: true)
        }
        applyPin()
    }

    // MARK: Keys

    private func installKeys() {
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            guard let window, event.window === window, model.slotChoices == nil else { return event }
            let cmd = event.modifierFlags.contains(.command)
            switch event.keyCode {
            case 125: model.move(model.columns); return nil       // Down
            case 126: model.move(-model.columns); return nil      // Up
            case 123: model.move(-1); return nil                  // Left
            case 124: model.move(1); return nil                   // Right
            case 36, 76: insert(); return nil                     // Return
            case 53:                                               // Esc
                if !model.query.isEmpty { model.query = "" } else { model.message = nil }
                return nil
            default: break
            }
            if cmd, let chars = event.charactersIgnoringModifiers {
                if let n = Int(chars), (1...PluginSort.allCases.count).contains(n) { model.cycleSort(to: n - 1); return nil }
                if chars == "d", let p = model.selected { store.toggleFavorite(p.id); return nil }
                if chars == "f" { ViewSettings.shared.favoritesOnly.toggle(); model.selection = 0; return nil }
            }
            return event
        }
    }

    private func removeKeys() {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
    }

    private func insert() { model.insertSelected() }

    @ViewBuilder private var statusBar: some View {
        HStack(spacing: 18) {
            Text("\(model.results.count) of \(store.plugins.count) plugins shown").foregroundStyle(.secondary)
            if snapshots.isRunning {
                HStack(spacing: 6) {
                    ProgressView(value: Double(snapshots.done), total: Double(max(1, snapshots.total)))
                        .frame(width: 120)
                    Text("Screenshots \(snapshots.done)/\(snapshots.total): \(snapshots.currentName)")
                        .lineLimit(1)
                    Button("Show Details") { SnapshotProgressWindow.shared.show() }.buttonStyle(.link)
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

/// Hands the hosting NSWindow to SwiftUI code.
struct WindowAccessor: NSViewRepresentable {
    var onWindow: (NSWindow) -> Void
    func makeNSView(context: Context) -> NSView {
        let v = NSView()
        DispatchQueue.main.async { if let w = v.window { onWindow(w) } }
        return v
    }
    func updateNSView(_ v: NSView, context: Context) {
        DispatchQueue.main.async { if let w = v.window { onWindow(w) } }
    }
}
