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
    @State private var mouseMonitor: Any?
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
        .overlay { UnfavoriteConfirm() }
        .animation(.easeOut(duration: 0.15), value: PluginStore.shared.confirmingUnfavorite)
        .background(Theme.ground)
        .ignoresSafeArea(.container, edges: .top)
        .preferredColorScheme(Theme.scheme)
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
        #if DEBUG
        // Self-test only: type a search or select a plugin, for the README pictures.
        .onReceive(NotificationCenter.default.publisher(for: .demoQuery)) { n in
            // No window-wide animation: one right after a resize made SwiftUI resize the test
            // window in a loop until macOS stopped it (2026-11-01). The grid still animates.
            model.query = n.object as? String ?? ""
        }
        .onReceive(NotificationCenter.default.publisher(for: .demoQueryPlain)) { n in
            model.query = n.object as? String ?? ""
        }
        .onReceive(NotificationCenter.default.publisher(for: .demoSelect)) { n in
            if let name = n.object as? String, let p = store.plugins.first(where: { $0.name == name }) { model.reveal(p.id) }
        }
        #endif
        .onReceive(NotificationCenter.default.publisher(for: .showTrackPanel)) { _ in
            if mini { toggleMini() }
            showTrack = true
        }
        .onChange(of: confirmLookup) { _, on in
            guard on else { return }
            confirmLookup = false
            DispatchQueue.main.async {
                let n = fetcher.missingCount()
                let cost = Double(n) * fetcher.model.estimatedCostPerPlugin
                if Dialog.confirm("Look up \(n) plugins?",
                                  message: "This uses your Anthropic API key with \(fetcher.model.title) and web search. " +
                                      "Estimated cost about $\(String(format: "%.2f", cost)) (\(n) plugins). " +
                                      "Each plugin is looked up once and saved.",
                                  ok: "Look Up") { fetcher.start() }
            }
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
                    // Where the info panel was: brings it back (BL-118).
                    .overlay(alignment: .topTrailing) {
                        if !view.showInfoPane {
                            Button { toggleInfo() } label: {
                                Image(systemName: "sidebar.right").font(.system(size: Theme.ts(13), weight: .medium))
                                    .foregroundStyle(Theme.text)
                                    .frame(width: 34, height: 34)
                                    .background(Circle().fill(Theme.raised))
                                    .overlay(Circle().strokeBorder(Theme.edge, lineWidth: 1))
                                    .shadow(color: .black.opacity(0.4), radius: 8, y: 3)
                                    .contentShape(Circle())
                            }
                            .buttonStyle(PressScale())
                            .help("Show the info panel (⌘I)")
                            .padding(.top, 10).padding(.trailing, 12)
                            .transition(.opacity.combined(with: .scale(scale: 0.8)))
                        }
                    }
                if view.showInfoPane {
                    Rectangle().fill(Theme.edge).frame(width: 1)
                        .transition(.move(edge: .trailing).combined(with: .opacity))
                    Group {
                        if let p = model.selected {
                            PluginDetailView(plugin: p, model: model) { insert() }
                        } else {
                            Color.clear
                        }
                    }
                    .frame(width: 340)
                    .transition(.move(edge: .trailing).combined(with: .opacity))
                }
            }
            .animation(.spring(duration: 0.28, bounce: 0.08), value: view.showInfoPane)
            if !view.showInfoPane, let message = model.message {
                HStack(spacing: 10) {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Theme.warning)
                    Text(message).font(.system(size: Theme.ts(12))).foregroundStyle(Theme.text)
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
        .overlay {
            if model.previewing, let p = model.selected {
                PluginPreview(plugin: p, model: model, onInsert: { model.previewing = false; insert() })
                    .transition(.opacity.combined(with: .scale(scale: 0.97)))
            }
        }
        .animation(.spring(duration: 0.26, bounce: 0.12), value: model.previewing)
        .onChange(of: model.keysOnPlugins) { _, on in
            // The search lets go of the keyboard, so Space reaches the plugins.
            if on, window?.firstResponder is NSText { window?.makeFirstResponder(nil) }
        }
    }

    private var topBar: some View {
        HStack(spacing: 12) {
            TrafficLights(window: window)
            HStack(spacing: 9) {
                BrandMark(size: 17)
                Text("AG PlugFinder").font(.system(size: Theme.ts(15), weight: .semibold)).foregroundStyle(Theme.text)
                Text("\(store.plugins.filter(store.isVisible).count) plugins found")
                    .font(.system(size: Theme.ts(10), weight: .medium)).monospacedDigit()
                    .foregroundStyle(Theme.faint)
                    .padding(.horizontal, 7).frame(height: 18)
                    .background(Capsule().fill(Theme.surface))
                    .help("Plugins shown")
            }
            .fixedSize()
            Spacer(minLength: 16)
            SearchField(model: model, focusOnAppear: false)
                .frame(minWidth: 220, maxWidth: 480)
            Spacer(minLength: 16)
            HStack(spacing: 2) {
                ShuffleButton(model: model)
                BarIconButton(systemImage: "slider.vertical.3", help: "This track in Logic: its plugins, on and off, replace, remove",
                              active: showTrack) { showTrack.toggle() }
                    .popover(isPresented: $showTrack, arrowEdge: .bottom) { TrackPanel(model: model) { showTrack = false } }
                BarIconButton(systemImage: "link", help: "Chains: add several plugins at once", active: showChains) {
                    showChains.toggle()
                }
                .popover(isPresented: $showChains, arrowEdge: .bottom) { ChainsPanel { showChains = false } }
                ViewControls(model: model)
                BarIconButton(systemImage: "creditcard", help: "My Purchases") { LicensesWindow.shared.show() }
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
                BarIconButton(systemImage: "questionmark.bubble", help: "Send feedback to Goldi") { FeedbackWindow.shared.show() }
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
            .font(.system(size: Theme.ts(12)))
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
                Text(message).font(.system(size: Theme.ts(11))).foregroundStyle(Theme.warning).lineLimit(2)
                    .padding(.horizontal, 14).padding(.bottom, 10)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .overlay { if model.slotChoices != nil { chooserOverlay } }
    }

    // MARK: Window behaviour

    private func insert() { model.insertSelected() }

    /// Opens or closes the info panel on the right (BL-118).
    private func toggleInfo() { view.showInfoPane.toggle() }

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
        // A click selects the plugin when the button goes down, not when it comes up (BL-108).
        // The event carries on, so double-click, drag, ⌘ and ⇧ clicks work as before.
        mouseMonitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { event in
            guard let window, event.window === window else { return event }
            if model.previewing {
                // Inside the card: its own buttons. Outside: close, and the click goes on to
                // whatever is under it, so one click both closes and selects.
                let p = event.locationInWindow
                let top = CGPoint(x: p.x, y: (window.contentView?.bounds.height ?? 0) - p.y)
                if model.previewCard.contains(top) { return event }
                model.previewing = false
            }
            guard event.clickCount == 1, !mini,
                  event.modifierFlags.intersection([.command, .shift, .control, .option]).isEmpty,
                  model.slotChoices == nil, store.confirmingUnfavorite == nil,
                  let id = model.hoverID, !model.picked.contains(id),
                  let i = model.results.firstIndex(where: { $0.id == id }) else { return event }
            model.picked = []
            if model.selection != i { model.selection = i }
            model.keysOnPlugins = true
            return event
        }
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
            // Tab in the search: the keyboard moves to the results, so Space previews (BL-127).
            if event.keyCode == 48, !mini, window.firstResponder is NSText,
               event.modifierFlags.intersection([.shift, .command, .control, .option]).isEmpty,
               model.selected != nil {
                model.keysOnPlugins = true
                return nil
            }
            if let handled = previewKeys(event, window: window) { return handled ? nil : event }
            switch event.keyCode {
            case 125: model.move(model.columns); onPlugins(); return nil       // Down
            case 126: model.move(-model.columns); onPlugins(); return nil      // Up
            case 123: model.move(-1); onPlugins(); return nil                  // Left
            case 124: model.move(1); onPlugins(); return nil                   // Right
            case 36, 76: insert(); return nil                     // Return
            case 53:                                               // Esc
                if model.replaceTarget != nil { model.replaceTarget = nil; return nil }
                if !model.picked.isEmpty { model.picked = []; return nil }
                if !model.query.isEmpty { model.query = "" } else { model.message = nil }
                return nil
            default: break
            }
            if cmd, let chars = event.charactersIgnoringModifiers {
                if let n = Int(chars), (1...PluginSort.allCases.count).contains(n) { model.cycleSort(to: n - 1); return nil }
                if chars == "d", let p = model.selected { store.favoriteTapped(p.id); return nil }
                if chars == "f" { ViewSettings.shared.favoritesOnly.toggle(); model.selection = 0; return nil }
                if chars == "i" { toggleInfo(); return nil }
            }
            return event
        }
    }

    /// Arrows choose a plugin, so the keyboard moves to the plugins (BL-106).
    private func onPlugins() {
        if !mini, model.selected != nil { model.keysOnPlugins = true }
    }

    /// Space bar preview keys (BL-106). nil: not handled here; true: used; false: pass it on.
    private func previewKeys(_ event: NSEvent, window: NSWindow) -> Bool? {
        let mods = event.modifierFlags.intersection([.command, .control, .option])
        if model.previewing, model.selected == nil { model.previewing = false }
        if model.previewing {
            switch event.keyCode {
            case 49, 53: model.previewing = false; return true            // Space, Esc
            case 36, 76: model.previewing = false; insert(); return true  // Return
            case 123, 124, 125, 126: return nil                           // arrows browse
            default: break
            }
            if !mods.isEmpty { return false }
            model.previewing = false
        }
        // Only while the keyboard is on the plugins, never while typing in a text field.
        guard !mini, model.keysOnPlugins, !(window.firstResponder is NSText), mods.isEmpty else { return nil }
        if event.keyCode == 49 {
            guard view.spacePreview, model.selected != nil, model.slotChoices == nil else { return nil }
            model.previewing = true
            return true
        }
        if event.keyCode == 48, event.modifierFlags.contains(.shift) {    // Shift+Tab: back to the search (BL-126)
            model.keysOnPlugins = false
            NotificationCenter.default.post(name: .focusSearch, object: nil)
            return true
        }
        if event.keyCode == 51 {                                          // Delete: back to the search
            NotificationCenter.default.post(name: .typeInSearch, object: model, userInfo: ["chars": "\u{7F}"])
            return true
        }
        if let chars = event.characters, !chars.isEmpty,
           chars.unicodeScalars.allSatisfy({ CharacterSet.alphanumerics.union(.punctuationCharacters).union(.symbols).contains($0) }) {
            NotificationCenter.default.post(name: .typeInSearch, object: model, userInfo: ["chars": chars])
            return true
        }
        return nil
    }

    private func removeKeys() {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        if let mouseMonitor { NSEvent.removeMonitor(mouseMonitor) }
        keyMonitor = nil
        mouseMonitor = nil
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
            action("camera", "Take missing pictures",
                   detail: snapshots.missingCount == 0 ? "Every plugin has one" : "\(snapshots.missingCount) without a picture, failed ones tried again",
                   disabled: snapshots.isRunning || snapshots.missingCount == 0) {
                snapshots.start(retryFailed: true)
            }
            action("sparkles", "Look up plugin info",
                   detail: fetcher.missingCount() == 0 ? "Every plugin has a description" : "\(fetcher.missingCount()) without a description",
                   disabled: fetcher.isRunning || fetcher.missingCount() == 0) {
                if fetcher.isFree { fetcher.start() } else { confirmLookup = true }
            }
            action("arrow.down.circle", "Download plugin pack", detail: packDetail,
                   disabled: pack.state == .working) {
                Task { await pack.install() }
            }
            Rectangle().fill(Theme.rule).frame(height: 1).padding(.vertical, 6)
            action("archivebox", "Plugins you don't use", detail: "Never used, how much space and money they take") {
                ReportWindow.shared.show(tab: "Unused")
            }
            action("chart.bar", "Plugin report", detail: "Most used, unused, installed twice, disk space") {
                ReportWindow.shared.show()
            }
            action("creditcard", "My Purchases", detail: licenseDetail) {
                LicensesWindow.shared.show()
            }
            action("square.and.arrow.up", "Share AG PlugFinder", detail: "X, WhatsApp, Messages, Instagram and more") {
                ShareWindow.shared.show()
            }
            action("rectangle.stack", "Screenshot progress", detail: nil) { SnapshotProgressWindow.shared.show() }
            action("gearshape", "Settings and plugin list", detail: nil) { openSettings() }
        }
        .padding(8)
        .frame(width: 300)
        .background(Theme.surface)
        .preferredColorScheme(Theme.scheme)
    }

    private var licenseDetail: String {
        let lic = Licenses.shared
        let subs = lic.plans.filter { $0.isSubscription && $0.active }.count
        if subs > 0 { return "\(subs) subscription\(subs == 1 ? "" : "s"), \(lic.money(lic.perMonth)) a month" }
        return lic.licenses.isEmpty ? "What you own, what renews, what it's worth" : "Collection worth \(lic.money(lic.collectionValue))"
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
                Image(systemName: icon).font(.system(size: Theme.ts(13), weight: .medium))
                    .foregroundStyle(Theme.muted).frame(width: 18)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.system(size: Theme.ts(13), weight: .medium)).foregroundStyle(Theme.text)
                    if let detail { Text(detail).font(.system(size: Theme.ts(11))).foregroundStyle(Theme.faint) }
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
    static let demoQuery = Notification.Name("AGPFDemoQuery")
    static let demoQueryPlain = Notification.Name("AGPFDemoQueryPlain")
    static let demoSelect = Notification.Name("AGPFDemoSelect")
}


/// Shuffle (BL-133): a die that spins while the selection hops, then lands on a random plugin.
struct ShuffleButton: View {
    @Bindable var model: PickerModel
    @State private var hovering = false
    @State private var turns = 0.0

    var body: some View {
        Button {
            withAnimation(.spring(duration: 0.9, bounce: 0.25)) { turns += 2 }
            model.shuffle()
        } label: {
            Image(systemName: "dice")
                .font(.system(size: Theme.ts(15), weight: .medium))
                .foregroundStyle(model.shuffling ? Theme.accent : (hovering ? Theme.text : Theme.muted))
                .rotationEffect(.degrees(turns * 360))
                .scaleEffect(model.shuffling ? 1.15 : 1)
                .animation(.spring(duration: 0.3), value: model.shuffling)
                .frame(width: 32, height: 32)
                .background(Circle().fill(hovering || model.shuffling ? Theme.raised : Color.clear))
                .contentShape(Circle())
        }
        .buttonStyle(PressScale())
        .onHover { hovering = $0 }
        .disabled(model.results.count < 2)
        .help("Shuffle: land on a random plugin")
        .accessibilityLabel("Shuffle: land on a random plugin")
    }
}
