import AppKit
import SwiftUI

/// The main window. Its own 52px top bar holds the mark and name on the left, the search in the
/// middle and the tools on the right. Arrow keys browse, Return inserts, Esc clears the search.
/// The pin keeps it above Logic; mini mode shrinks it to the search and two result rows.
struct LibraryView: View {
    @State private var model = PickerModel()
    @State private var confirmLookup = false
    @State private var window: NSWindow?
    @State private var keyMonitor: Any?
    @State private var pinned = UserDefaults.standard.bool(forKey: "library.pinned")
    @State private var mini = false
    @State private var fullFrame: NSRect?
    @State private var showActions = false
    @State private var showChains = false
    @State private var showTrack = false
    var store = PluginStore.shared
    var snapshots = SnapshotQueue.shared
    var fetcher = PluginInfoFetcher.shared
    var view = ViewSettings.shared

    /// Two compact rows (54 each, 2 apart) plus the list's padding.
    static let miniRowsHeight: CGFloat = 2 * 54 + 2 + 16

    var body: some View {
        VStack(spacing: 0) {
            if mini { miniBody } else { fullBody }
        }
        .frame(minWidth: mini ? 340 : 860, minHeight: mini ? 150 : 540)
        .background(Theme.ground)
        .ignoresSafeArea(.container, edges: .top)
        .preferredColorScheme(.dark)
        .background(WindowAccessor { w in
            guard window !== w else { return }
            window = w
            WindowChrome.apply(to: w)
            applyPin()
        })
        .onAppear(perform: installKeys)
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { n in
            if (n.object as? NSWindow) === window {
                model.refreshSuggestion()
                TrackState.shared.refresh()
            }
        }
        .onDisappear(perform: removeKeys)
        .onReceive(NotificationCenter.default.publisher(for: .toggleMiniMode)) { _ in toggleMini() }
        .onReceive(NotificationCenter.default.publisher(for: .showTrackPanel)) { _ in
            if mini { toggleMini() }
            showTrack = true
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

    // MARK: Full window

    private var fullBody: some View {
        VStack(spacing: 0) {
            topBar
            UpdateBanner()
            activityStrip
            ReplaceBanner(model: model)
            CollectionBar(model: model, showSizeSlider: true)
            HStack(spacing: 0) {
                PluginGrid(model: model) { insert() }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                if view.showInfoPane {
                    Rectangle().fill(Theme.edge).frame(width: 1)
                    Group {
                        if let p = model.selected {
                            PluginDetailView(plugin: p, model: model) { insert() }
                        } else {
                            Color.clear
                        }
                    }
                    .frame(width: 340)
                }
            }
            if !view.showInfoPane, let message = model.message {
                HStack(spacing: 10) {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Theme.warning)
                    Text(message).font(.system(size: 12)).foregroundStyle(Theme.text)
                    Spacer()
                    if model.showAccessibilityButton {
                        QuietPill(title: "Allow in System Settings", height: 26) { AXAccess.openSettings() }
                    }
                }
                .padding(.horizontal, 18).frame(height: 44)
                .background(Theme.warningGround)
            }
        }
        .overlay { if model.slotChoices != nil { chooserOverlay } }
    }

    private var topBar: some View {
        HStack(spacing: 12) {
            TrafficLights(window: window)
            HStack(spacing: 9) {
                BrandMark(size: 17)
                Text("AG PlugFinder").font(.system(size: 15, weight: .semibold)).foregroundStyle(Theme.text)
                Text("\(store.plugins.filter(store.isVisible).count)")
                    .font(.system(size: 12, weight: .medium)).monospacedDigit()
                    .foregroundStyle(Theme.faint)
                    .padding(.horizontal, 7).frame(height: 20)
                    .background(Capsule().fill(Theme.surface))
                    .help("Plugins shown")
            }
            .fixedSize()
            Spacer(minLength: 16)
            SearchField(model: model, focusOnAppear: false)
                .frame(minWidth: 220, maxWidth: 480)
            Spacer(minLength: 16)
            HStack(spacing: 2) {
                BarIconButton(systemImage: "slider.vertical.3", help: "This track in Logic: its plugins, on and off, replace, remove",
                              active: showTrack) { showTrack.toggle() }
                    .popover(isPresented: $showTrack, arrowEdge: .bottom) { TrackPanel(model: model) { showTrack = false } }
                BarIconButton(systemImage: "link", help: "Chains: add several plugins at once", active: showChains) {
                    showChains.toggle()
                }
                .popover(isPresented: $showChains, arrowEdge: .bottom) { ChainsPanel { showChains = false } }
                ViewControls(model: model)
                BarIconButton(systemImage: "ellipsis", help: "Plugins, screenshots and info", active: showActions) {
                    showActions.toggle()
                }
                .popover(isPresented: $showActions, arrowEdge: .bottom) {
                    LibraryActions(confirmLookup: $confirmLookup) { showActions = false }
                }
                BarIconButton(systemImage: pinned ? "pin.fill" : "pin",
                              help: pinned ? "Stop keeping this window on top" : "Keep this window above Logic",
                              active: pinned) { togglePin() }
                BarIconButton(systemImage: "rectangle.compress.vertical", help: "Mini window") { toggleMini() }
                Rectangle().fill(Theme.raised).frame(width: 1, height: 18).padding(.horizontal, 6)
                VersionBadge()
            }
            .fixedSize()
        }
        .padding(.trailing, 14)
        .frame(height: WindowChrome.barHeight)
        .background(Theme.ground)
        .gesture(WindowDragGesture())
    }

    /// Shown only while something runs in the background.
    @ViewBuilder private var activityStrip: some View {
        if snapshots.isRunning || fetcher.isRunning || fetcher.lastError != nil {
            HStack(spacing: 14) {
                if snapshots.isRunning {
                    progress(Double(snapshots.done), Double(snapshots.total),
                             "Screenshots \(snapshots.done) of \(snapshots.total) · \(snapshots.currentName)")
                    QuietPill(title: "Details", height: 24) { SnapshotProgressWindow.shared.show() }
                }
                if fetcher.isRunning {
                    progress(Double(fetcher.done), Double(fetcher.total),
                             "Plugin info \(fetcher.done) of \(fetcher.total)")
                    QuietPill(title: "Stop", height: 24) { fetcher.cancel() }
                } else if let e = fetcher.lastError {
                    Text(e).foregroundStyle(Theme.negative).lineLimit(1)
                }
                Spacer()
            }
            .font(.system(size: 12))
            .padding(.horizontal, 18).frame(height: 36)
            .background(Theme.surface)
        }
    }

    private func progress(_ value: Double, _ total: Double, _ label: String) -> some View {
        HStack(spacing: 10) {
            ZStack(alignment: .leading) {
                Capsule().fill(Theme.raised)
                Capsule().fill(Theme.accent)
                    .frame(width: total > 0 ? 120 * value / total : 0)
            }
            .frame(width: 120, height: 4)
            Text(label).foregroundStyle(Theme.muted).lineLimit(1).monospacedDigit()
        }
    }

    private var chooserOverlay: some View {
        ZStack {
            Color.black.opacity(0.55)
            SlotChooser(model: model) { model.insertSelected(replacing: $0) }
        }
    }

    // MARK: Mini mode

    /// One search line and two result rows. Arrows move, Return inserts.
    private var miniBody: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                TrafficLights(window: window)
                SearchField(model: model, focusOnAppear: true)
                BarIconButton(systemImage: pinned ? "pin.fill" : "pin",
                              help: pinned ? "Stop keeping this window on top" : "Keep on top",
                              active: pinned) { togglePin() }
                BarIconButton(systemImage: "rectangle.expand.vertical", help: "Full window") { toggleMini() }
            }
            .padding(.trailing, 10)
            .frame(height: WindowChrome.barHeight)
            .gesture(WindowDragGesture())
            PluginGrid(model: model, compact: true) { insert() }
                .frame(height: Self.miniRowsHeight)
            if let message = model.message {
                Text(message).font(.system(size: 11)).foregroundStyle(Theme.warning).lineLimit(2)
                    .padding(.horizontal, 14).padding(.bottom, 10)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .overlay { if model.slotChoices != nil { chooserOverlay } }
    }

    // MARK: Window behaviour

    private func insert() { model.insertSelected() }

    private func togglePin() {
        pinned.toggle()
        UserDefaults.standard.set(pinned, forKey: "library.pinned")
        applyPin()
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
            let size = NSSize(width: 440, height: WindowChrome.barHeight + Self.miniRowsHeight + 6)
            let origin = NSPoint(x: window.frame.maxX - size.width, y: window.frame.maxY - size.height)
            window.setFrame(NSRect(origin: origin, size: size), display: true, animate: true)
        }
        applyPin()
    }

    // MARK: Keys

    private func installKeys() {
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            guard let window, event.window === window else { return event }
            if model.slotChoices != nil {
                switch event.keyCode {
                case 126: model.slotSelection = max(0, model.slotSelection - 1); return nil
                case 125: model.slotSelection = min((model.slotChoices?.count ?? 1) - 1, model.slotSelection + 1); return nil
                case 36, 76: model.insertSelected(replacing: model.slotSelection); return nil
                case 53: model.slotChoices = nil; model.message = nil; return nil
                default: return nil
                }
            }
            let cmd = event.modifierFlags.contains(.command)
            switch event.keyCode {
            case 125: model.move(model.columns); return nil       // Down
            case 126: model.move(-model.columns); return nil      // Up
            case 123: model.move(-1); return nil                  // Left
            case 124: model.move(1); return nil                   // Right
            case 36, 76: insert(); return nil                     // Return
            case 53:                                               // Esc
                if model.replaceTarget != nil { model.replaceTarget = nil; return nil }
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
}

/// The ⋯ popover: everything that works on the whole library.
struct LibraryActions: View {
    @Binding var confirmLookup: Bool
    var close: () -> Void
    var store = PluginStore.shared
    var snapshots = SnapshotQueue.shared
    var fetcher = PluginInfoFetcher.shared
    var pack = PluginPack.shared
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            action("arrow.clockwise", "Rescan installed plugins", detail: "Finds what you installed since") {
                store.rescan(); snapshots.start()
            }
            action("camera", "Take missing screenshots",
                   detail: snapshots.missingCount == 0 ? "Every plugin has one" : "\(snapshots.missingCount) without a picture",
                   disabled: snapshots.isRunning || snapshots.missingCount == 0) {
                snapshots.start()
            }
            action("sparkles", "Look up plugin info",
                   detail: fetcher.missingCount() == 0 ? "Every plugin has a description" : "\(fetcher.missingCount()) without a description",
                   disabled: fetcher.isRunning || fetcher.missingCount() == 0) {
                confirmLookup = true
            }
            action("arrow.down.circle", "Download plugin pack", detail: packDetail,
                   disabled: pack.state == .working) {
                Task { await pack.install() }
            }
            Rectangle().fill(Theme.rule).frame(height: 1).padding(.vertical, 6)
            action("chart.bar", "Plugin report", detail: "Most used, never used, installed twice, disk space") {
                ReportWindow.shared.show()
            }
            action("rectangle.stack", "Screenshot progress", detail: nil) { SnapshotProgressWindow.shared.show() }
            action("gearshape", "Settings and plugin list", detail: nil) { openSettings() }
        }
        .padding(8)
        .frame(width: 300)
        .background(Theme.surface)
        .preferredColorScheme(.dark)
    }

    private var packDetail: String {
        switch pack.state {
        case .idle: return "Pictures and info other users already have"
        case .working: return "Downloading…"
        case .finished(let pictures, let info):
            return pictures + info == 0 ? "Nothing new for your plugins" : "Added \(pictures) pictures, \(info) descriptions"
        case .failed(let why): return why
        }
    }

    private func action(_ icon: String, _ title: String, detail: String?, disabled: Bool = false,
                        _ run: @escaping () -> Void) -> some View {
        ActionRow(icon: icon, title: title, detail: detail, disabled: disabled) { close(); run() }
    }
}

struct ActionRow: View {
    let icon: String
    let title: String
    let detail: String?
    var disabled = false
    let run: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: run) {
            HStack(spacing: 12) {
                Image(systemName: icon).font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Theme.muted).frame(width: 18)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.system(size: 13, weight: .medium)).foregroundStyle(Theme.text)
                    if let detail { Text(detail).font(.system(size: 11)).foregroundStyle(Theme.faint) }
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10).padding(.vertical, 8)
            .background(RoundedRectangle(cornerRadius: 10).fill(hovering && !disabled ? Theme.raised : .clear))
            .contentShape(Rectangle())
            .opacity(disabled ? 0.45 : 1)
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .onHover { hovering = $0 }
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

extension Notification.Name {
    static let toggleMiniMode = Notification.Name("AGPFToggleMiniMode")
}
