import AppKit
import SwiftUI

/// The main window. Its own 52px top bar holds the mark and name on the left, the search in the
/// middle and the tools on the right. Arrow keys browse, Return inserts, Esc clears the search.
/// The pin keeps it above Logic; mini mode shrinks it to the search and two result rows, and the
/// sideview is a tall narrow panel at the side of the screen (BL-148).
struct LibraryView: View {
    @AppStorage("fixFailed.dismissedAt") private var fixFailedDismissedAt = 0
    @State private var model = PickerModel()
    @State private var confirmLookup = false
    @State private var window: NSWindow?
    @State private var keyMonitor: Any?
    @State private var mouseMonitor: Any?
    @State private var flagsMonitor: Any?
    /// Holding Option: where on the track the selected effect will go (BL-180).
    @State private var placing = false
    @State private var placeSpot = 0
    @State private var optionDown = false
    @State private var pinned = UserDefaults.standard.bool(forKey: "library.pinned")
    @State private var mode = WindowMode.full
    private var mini: Bool { mode == .mini }
    @State private var fullFrame: NSRect?
    @State private var showActions = false
    @State private var showChains = false
    @State private var showTrack = false
    @State private var showTopEditor = false
    var store = PluginStore.shared
    var snapshots = SnapshotQueue.shared
    var fetcher = PluginInfoFetcher.shared
    var view = ViewSettings.shared

    /// Two compact rows (54 each, 2 apart) plus the list's padding.
    static let miniRowsHeight: CGFloat = 2 * 54 + 2 + 16

    var body: some View {
        VStack(spacing: 0) {
            switch mode {
            case .full: fullBody
            case .mini: miniBody
            case .sideview: SideviewBody(model: model, window: window, mode: mode, pinned: pinned,
                                       onMode: setMode, onPin: togglePin) { insert() }
            case .floating: FloatingBody(model: model, mode: mode, onMode: setMode) { insert() }
            }
        }
        // Holding Option in Mini, Floating or Sideview: the track's effects over the window (BL-187).
        .overlay {
            if placing, mode != .full, let p = model.selected {
                PlacePanel(plugin: p, spot: placeSpot, compact: mode == .mini)
                    .clipShape(RoundedRectangle(cornerRadius: mode == .floating ? 16 : 0, style: .continuous))
                    .transition(.opacity)
            }
        }
        .animation(.easeOut(duration: 0.15), value: placing)
        .frame(minWidth: mode == .full ? 860 : 300, minHeight: mode == .full ? 540 : (mini ? 150 : (mode == .floating ? 300 : 400)))
        .overlay { UnfavoriteConfirm() }
        .animation(.easeOut(duration: 0.15), value: PluginStore.shared.confirmingUnfavorite)
        // Floating is see-through: it draws its own blurred card (BL-182).
        .background(mode == .floating ? Color.clear : Theme.ground)
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
        // The menu bar's Window Style (BL-176).
        .onReceive(NotificationCenter.default.publisher(for: .setWindowMode)) { n in
            if let m = (n.object as? String).flatMap(WindowMode.init(rawValue:)) { setMode(m) }
        }
        #if DEBUG
        // Self-test only: switch between full window, sideview and mini (BL-148).
        .onReceive(NotificationCenter.default.publisher(for: .demoWindowMode)) { n in
            if let m = (n.object as? String).flatMap(WindowMode.init(rawValue:)) { setMode(m) }
        }
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
        .onReceive(NotificationCenter.default.publisher(for: .demoPlace)) { n in
            if let spot = n.object as? Int { placeSpot = spot; placing = true } else { placing = false }
        }
        .onReceive(NotificationCenter.default.publisher(for: .demoPick)) { n in
            let names = n.object as? [String] ?? []
            model.picked = Set(store.plugins.filter { names.contains($0.name) }.map(\.id))
        }
        #endif
        .onReceive(NotificationCenter.default.publisher(for: .showTrackPanel)) { _ in
            if mode != .full { setMode(.full) }
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
                if view.showInfoPane || placing {
                    Rectangle().fill(Theme.edge).frame(width: 1)
                        .transition(.move(edge: .trailing).combined(with: .opacity))
                    Group {
                        if placing, let p = model.selected {
                            PlacePanel(plugin: p, spot: placeSpot)
                        } else if let p = model.selected {
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
            .animation(.easeOut(duration: 0.15), value: placing)
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
            footer
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
            }
            .fixedSize()
            Spacer(minLength: 16)
            SearchField(model: model, focusOnAppear: false)
                .frame(minWidth: 220, maxWidth: 480)
            Spacer(minLength: 16)
            // Shown only while some screenshots failed (BL-130).
            let failed = PlugDB.shownFailedIDs.count
            // Dismissed with its x, it stays away until more screenshots fail (BL-143).
            if failed > 0, !snapshots.isRunning, failed > fixFailedDismissedAt {
                HStack(spacing: 0) {
                    QuietPill(title: "Fix Failed Screenshots (\(failed))", systemImage: "arrow.triangle.2.circlepath", height: 28) {
                        PlugDB.fixFailed()
                    }
                    .help("Checks the shared database again for the \(failed) plugin\(failed == 1 ? "" : "s") whose screenshot failed")
                    Button {
                        withAnimation(.easeOut(duration: 0.2)) { fixFailedDismissedAt = failed }
                        Toast.show("Hidden. It comes back if more screenshots fail.")
                    } label: {
                        Image(systemName: "xmark").font(.system(size: Theme.ts(10), weight: .bold))
                            .foregroundStyle(Theme.faint)
                            .frame(width: 22, height: 22)
                            .background(Circle().fill(Theme.raised))
                            .contentShape(Circle())
                    }
                    .buttonStyle(PressScale())
                    .help("Hide this until more screenshots fail")
                    .padding(.leading, 4)
                }
                .fixedSize()
                .transition(.opacity)
            }
            // Fewer failures than when it was dismissed (some got fixed): new ones bring it back.
            Color.clear.frame(width: 0, height: 0)
                .onChange(of: failed) { _, n in if n < fixFailedDismissedAt { fixFailedDismissedAt = n } }
            HStack(spacing: 2) {
                // In the user's order, without the hidden ones; right-click to edit (BL-189).
                HStack(spacing: 2) {
                    ForEach(view.topItems.filter { !view.topHidden.contains($0.rawValue) }) { item in topIcon(item) }
                }
                .contextMenu { Button("Edit Icons…") { showTopEditor = true } }
                .popover(isPresented: $showTopEditor, arrowEdge: .bottom) { TopBarEditor() }
                BarIconButton(systemImage: "ellipsis", help: "Plugins, screenshots and info", active: showActions) {
                    showActions.toggle()
                }
                .popover(isPresented: $showActions, arrowEdge: .bottom) {
                    LibraryActions(confirmLookup: $confirmLookup) { showActions = false }
                }
                BarIconButton(systemImage: pinned ? "pin.fill" : "pin",
                              help: pinned ? "Stop keeping this window on top" : "Keep this window above Logic",
                              active: pinned) { togglePin() }
                ViewModeButton(mode: mode, onMode: setMode)
            }
            .fixedSize()
        }
        // The tools sit tight in the top-right corner (BL-163).
        .padding(.trailing, 8)
        .frame(height: WindowChrome.barHeight)
        .background(Theme.ground)
        .gesture(WindowDragGesture())
    }

    /// A thin line at the bottom (BL-163): feedback, then the version and Check for Update.
    private var footer: some View {
        HStack(spacing: 4) {
            BarIconButton(systemImage: "questionmark.bubble", help: "Send feedback to Goldi") { FeedbackWindow.shared.show() }
                .scaleEffect(0.85)
            VersionBadge(arrowEdge: .top)
        }
        .frame(maxWidth: .infinity).frame(height: 30)
        // Which program plugins go to, bottom left (BL-165).
        .overlay(alignment: .leading) { HostBadge().padding(.leading, 12) }
        // How many plugins, bottom right (BL-191; it sat beside the name at the top before).
        .overlay(alignment: .trailing) {
            Text("\(store.plugins.filter(store.isVisible).count) plugins found")
                .font(.system(size: Theme.ts(10), weight: .medium)).monospacedDigit()
                .foregroundStyle(Theme.faint)
                .padding(.horizontal, 7).frame(height: 18)
                .background(Capsule().fill(Theme.surface))
                .help("Plugins shown")
                .padding(.trailing, 12)
        }
        .background(Theme.ground)
        .overlay(alignment: .top) { Rectangle().fill(Theme.edge).frame(height: 1) }
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
                // Favorites only, the same switch as the full window's star (BL-179).
                BarIconButton(systemImage: ViewSettings.shared.favoritesOnly ? "star.fill" : "star",
                              help: "Favorites only (⌘F)", active: ViewSettings.shared.favoritesOnly,
                              activeTint: Theme.favorite) {
                    ViewSettings.shared.favoritesOnly.toggle()
                    model.selection = 0
                }
                BarIconButton(systemImage: pinned ? "pin.fill" : "pin",
                              help: pinned ? "Stop keeping this window on top" : "Keep on top",
                              active: pinned) { togglePin() }
                ViewModeButton(mode: mode, onMode: setMode)
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
        window?.level = (pinned || mode != .full) ? .floating : .normal
        window?.collectionBehavior = (pinned || mode != .full) ? [.canJoinAllSpaces, .fullScreenAuxiliary] : []
    }

    /// The shortcut and menu item switch between the full window and mini.
    private func toggleMini() { setMode(mini ? .full : .mini) }

    /// Full window, sideview or mini (BL-148). The full window's place is kept to come back to.
    private func setMode(_ new: WindowMode) {
        guard new != mode else { return }
        guard let window else { mode = new; return }
        if mode == .full { fullFrame = window.frame }
        mode = new
        // Only Floating lets the screen show through the window (BL-182).
        window.isOpaque = new != .floating
        window.backgroundColor = new == .floating ? .clear : Theme.nsGround
        switch new {
        case .full:
            if let f = fullFrame { window.setFrame(f, display: true, animate: true) }
        case .mini:
            let size = NSSize(width: 440, height: WindowChrome.barHeight + Self.miniRowsHeight + 6)
            let from = fullFrame ?? window.frame
            window.setFrame(NSRect(origin: NSPoint(x: from.maxX - size.width, y: from.maxY - size.height), size: size),
                            display: true, animate: true)
        case .sideview:
            // The full height of the screen the window is on, against its right edge.
            let area = (window.screen ?? NSScreen.main)?.visibleFrame ?? window.frame
            let width: CGFloat = 360
            window.setFrame(NSRect(x: area.maxX - width, y: area.minY, width: width, height: area.height),
                            display: true, animate: true)
        case .floating:
            // A command bar in the upper middle of the screen.
            let area = (window.screen ?? NSScreen.main)?.visibleFrame ?? window.frame
            let size = NSSize(width: 680, height: 480)
            window.setFrame(NSRect(x: area.midX - size.width / 2, y: area.minY + area.height * 0.6 - size.height / 2,
                                   width: size.width, height: size.height), display: true, animate: true)
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
            guard event.clickCount == 1, mode == .full,
                  event.modifierFlags.intersection([.command, .shift, .control, .option]).isEmpty,
                  model.slotChoices == nil, store.confirmingUnfavorite == nil,
                  let id = model.hoverID, !model.picked.contains(id),
                  let i = model.results.firstIndex(where: { $0.id == id }) else { return event }
            model.picked = []
            if model.selection != i { model.selection = i }
            model.keysOnPlugins = true
            return event
        }
        // Option alone held for a moment, on an audio effect: show where it will go (BL-180).
        flagsMonitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { event in
            guard let window, event.window === window else { return event }
            let mods = event.modifierFlags.intersection([.command, .control, .option, .shift])
            if mods == .option {
                guard !optionDown else { return event }
                optionDown = true
                Task {
                    try? await Task.sleep(for: .milliseconds(250))
                    guard optionDown, canPlace() else { return }
                    TrackState.shared.refresh()
                    placeSpot = TrackState.shared.effects.count
                    placing = true
                }
            } else {
                optionDown = false
                if placing { placing = false }
            }
            return event
        }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            guard let window, event.window === window else { return event }
            if placing {
                let count = TrackState.shared.effects.count
                switch event.keyCode {
                case 126: placeSpot = max(0, placeSpot - 1); return nil              // Option Up
                case 125: placeSpot = min(count, placeSpot + 1); return nil          // Option Down
                case 36, 76: placeHere(); return nil                                 // Return
                case 53: placing = false; return nil                                 // Esc
                default: return nil
                }
            }
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
            // Floating: Tab and Shift+Tab step through the categories (BL-182).
            if mode == .floating, event.keyCode == 48,
               event.modifierFlags.intersection([.command, .control, .option]).isEmpty {
                FloatingBody.stepCategory(model, by: event.modifierFlags.contains(.shift) ? -1 : 1)
                return nil
            }
            // Tab in the search: the keyboard moves to the results, so Space previews (BL-127).
            if event.keyCode == 48, mode == .full, window.firstResponder is NSText,
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
                // Floating: back to All, with the search cleared (BL-186).
                if mode == .floating {
                    model.picked = []; model.query = ""; model.pills = []; model.collectionID = nil; model.selection = 0
                    return nil
                }
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
        if mode == .full, model.selected != nil { model.keysOnPlugins = true }
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
        guard mode == .full, model.keysOnPlugins, !(window.firstResponder is NSText), mods.isEmpty else { return nil }
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
        if let flagsMonitor { NSEvent.removeMonitor(flagsMonitor) }
        keyMonitor = nil
        mouseMonitor = nil
        flagsMonitor = nil
    }

    @ViewBuilder
    private func topIcon(_ item: TopItem) -> some View {
        switch item {
        case .shuffle: ShuffleButton(model: model)
        case .track:
            BarIconButton(systemImage: "slider.vertical.3", help: "This track in Logic: its plugins, on and off, replace, remove",
                          active: showTrack) { showTrack.toggle() }
                .popover(isPresented: $showTrack, arrowEdge: .bottom) { TrackPanel(model: model) { showTrack = false } }
        case .chains:
            BarIconButton(systemImage: "link", help: "Chains: add several plugins at once", active: showChains) {
                showChains.toggle()
            }
            .popover(isPresented: $showChains, arrowEdge: .bottom) { ChainsPanel { showChains = false } }
        case .newCollection, .favorites, .viewOptions: ViewControl(item: item, model: model)
        case .purchases: BarIconButton(systemImage: "creditcard", help: "My Purchases") { LicensesWindow.shared.show() }
        }
    }

    /// Only for an audio effect, with Logic in use and nothing else open. Every window mode (BL-187).
    private func canPlace() -> Bool {
        Host.current == .logic && model.selected?.slotKind == .audioFX && model.picked.count < 2
            && !model.previewing && model.slotChoices == nil && model.replaceTarget == nil
    }

    /// Adds the selected effect at the chosen spot: before the effect there, or after the last.
    private func placeHere() {
        placing = false
        guard let p = model.selected else { return }
        let effects = TrackState.shared.effects
        if effects.isEmpty { insert(); return }
        if placeSpot < effects.count { TrackActions.insert(p, before: true, effects[placeSpot]) }
        else { TrackActions.insert(p, before: false, effects[effects.count - 1]) }
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
    static let setWindowMode = Notification.Name("AGPFSetWindowMode")
    static let demoWindowMode = Notification.Name("AGPFDemoWindowMode")
    static let demoQuery = Notification.Name("AGPFDemoQuery")
    static let demoQueryPlain = Notification.Name("AGPFDemoQueryPlain")
    static let demoSelect = Notification.Name("AGPFDemoSelect")
    static let demoPick = Notification.Name("AGPFDemoPick")
    static let demoPlace = Notification.Name("AGPFDemoPlace")
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
