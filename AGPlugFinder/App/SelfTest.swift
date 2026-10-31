#if DEBUG
import AppKit
import ScreenCaptureKit
import SwiftUI

/// Debug-only: `--selftest <folder> [query]` opens the picker and saves pictures of it,
/// so the layout can be checked without a person at the keyboard.
@MainActor
enum SelfTest {
    /// Exercises BL-25…BL-34 and photographs the new panels. Everything it creates is removed.
    static func features(_ dir: URL) async {
        let store = PluginStore.shared, lib = UserLibrary.shared
        func say(_ s: String) { print("FEAT " + s); fflush(stdout) }
        say("plugins \(store.plugins.count), visible \(store.plugins.filter(store.isVisible).count)")

        // BL-27 search by description
        if let p = store.plugins.first(where: { store.isVisible($0) && ($0.details?.bestFeature.count ?? 0) > 20 }),
           let word = p.details!.bestFeature.lowercased().split(separator: " ").map(String.init)
               .first(where: { $0.count > 6 && !PluginStore.nameHay(p).contains($0) && $0.allSatisfy(\.isLetter) }) {
            let r = store.filtered(query: word, sort: .name)
            say("search '\(word)' -> \(r.count) results, finds \(p.name): \(r.contains { $0.id == p.id })")
        } else { say("search: no plugin with a description to test") }

        // BL-28 more like this
        for name in ["ChromaVerb", "Compressor", "Alchemy"] {
            if let p = store.plugins.first(where: { $0.name == name }) {
                say("similar to \(name): \(PluginExtras.similar(to: p).map(\.name))")
            }
        }

        // BL-33 track suggestions
        say("selected Logic track: \(LogicInserter.shared.selectedTrackName() ?? "none")")
        for t in ["Lead Vocal", "Kick", "Bass", "Guitar", "Master"] {
            let names = TrackSuggestions.plugins(for: t).prefix(5).compactMap { store.plugin($0)?.name }
            say("suggest \(t): \(names)")
        }

        // BL-29 collections, BL-25 chains, BL-26 pins, BL-30 notes, BL-31 usage
        let ids = Array(store.plugins.filter(store.isVisible).prefix(3).map(\.id))
        let col = UserLibrary.Collection(name: "Test collection", pluginIDs: ids)
        lib.collections.append(col)
        let model = PickerModel()
        model.collectionID = col.id
        say("collection filter -> \(model.results.count) (expected \(ids.count))")
        let chain = lib.newChain(named: "Test chain", with: ids)
        let freeKey = (1...9).first { lib.pinTarget($0) == nil } ?? 9
        let oldPin = lib.pinTarget(freeKey)
        lib.pin(freeKey, to: .chain(chain.id))
        say("chain pin key \(freeKey) -> \(lib.key(for: .chain(chain.id)).map(String.init) ?? "none")")
        lib.notes[ids[0]] = "Test note"
        say("note -> \(lib.notes[ids[0]] ?? "none")")
        let before = lib.useCount[ids[2]]
        lib.useCount[ids[2]] = 999
        say("most used first -> \(store.filtered(query: "", sort: .mostUsed).first?.id == ids[2])")
        say("sync file: \(UserLibrary.cloudFile?.path ?? "iCloud Drive off")")

        // Photos of the new panels (app windows only).
        if let p = store.plugins.first(where: { $0.name == "ChromaVerb" }) ?? store.plugins.first {
            await shoot(PluginExtras(plugin: p, model: model).padding(18).frame(width: 340).background(Theme.ground),
                        size: NSSize(width: 340, height: 760), to: dir.appendingPathComponent("extras.png"))
        }
        await shoot(ChainsPanel {}, size: NSSize(width: 380, height: 420), to: dir.appendingPathComponent("chains.png"))
        await shoot(CollectionBar(model: PickerModel()).frame(width: 900).background(Theme.ground),
                    size: NSSize(width: 900, height: 44), to: dir.appendingPathComponent("collections.png"))
        ReportWindow.shared.show()
        try? await Task.sleep(for: .milliseconds(800))
        if let w = NSApp.windows.first(where: { $0.isVisible && $0.contentView is NSHostingView<ReportView> }) {
            await capture(w, to: dir.appendingPathComponent("report.png"))
        }
        let sizes = await ReportView.diskByMaker()
        say("disk by maker top: \(sizes.prefix(3).map { "\($0.maker) \(ByteCountFormatter.string(fromByteCount: $0.bytes, countStyle: .file))" })")

        // Clean up everything the test made.
        lib.useCount[ids[2]] = before
        lib.notes[ids[0]] = nil
        lib.pin(freeKey, to: oldPin)
        lib.deleteChain(chain.id)
        lib.collections.removeAll { $0.id == col.id }
        say("cleaned up: chains \(lib.chains.count), collections \(lib.collections.count)")
        say("done")
    }

    static func mapping() -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/hidutil")
        p.arguments = ["property", "--get", "UserKeyMapping"]
        let pipe = Pipe()
        p.standardOutput = pipe
        try? p.run()
        p.waitUntilExit()
        return String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
    }

    /// The real Control Option P, as the keyboard sends it.
    private static func pressHotKey() {
        let src = CGEventSource(stateID: .hidSystemState)
        for down in [true, false] {
            let e = CGEvent(keyboardEventSource: src, virtualKey: 35, keyDown: down)
            e?.flags = [.maskControl, .maskAlternate]
            e?.post(tap: .cghidEventTap)
            usleep(30_000)
        }
    }

    private static func shoot<V: View>(_ view: V, size: NSSize, to url: URL) async {
        let w = NSWindow(contentRect: NSRect(origin: NSPoint(x: 80, y: 80), size: size),
                         styleMask: [.borderless], backing: .buffered, defer: false)
        w.appearance = NSAppearance(named: .darkAqua)
        w.backgroundColor = .black
        w.contentView = NSHostingView(rootView: view.preferredColorScheme(.dark))
        w.orderFrontRegardless()
        try? await Task.sleep(for: .milliseconds(700))
        await capture(w, to: url)
        w.orderOut(nil)
    }

    static func runIfRequested() {
        let args = CommandLine.arguments
        // --dump-logic: save Logic's interface tree.  --test-insert <name>: insert like Return does.
        if args.contains("--selftest-update") {
            Task {
                await Updater.shared.check()
                print("UPDATE state \(Updater.shared.state)"); fflush(stdout)
                if Updater.shared.available != nil { Updater.shared.install() }
                // --selftest-update <dir>: photograph the update window (only that window) as it works.
                let dir = args.firstIndex(of: "--selftest-update").flatMap { i in
                    i + 1 < args.count && !args[i + 1].hasPrefix("--") ? URL(fileURLWithPath: args[i + 1]) : nil
                }
                for n in 0..<40 {
                    try? await Task.sleep(for: .milliseconds(500))
                    if let dir, let w = NSApp.windows.first(where: { $0.isVisible && $0.contentView is NSHostingView<UpdateProgressView> }) {
                        await capture(w, to: dir.appendingPathComponent("update-\(n).png"))
                    }
                    if case .failed(let m) = Updater.shared.state { print("UPDATE failed \(m)"); fflush(stdout); return }
                }
            }
        }
        if let k = args.firstIndex(of: "--selftest-window"), k + 1 < args.count {
            let out = URL(fileURLWithPath: args[k + 1])
            Task {
                await Updater.shared.check(userInitiated: true)
                try? await Task.sleep(for: .milliseconds(1500))
                guard let window = NSApp.windows.first(where: { !($0 is PickerPanel) && $0.isVisible && $0.frame.width > 500 })
                else { print("WINDOW none"); fflush(stdout); return }
                await capture(window, to: out)
                if args.contains("--mini") {
                    NotificationCenter.default.post(name: .toggleMiniMode, object: nil)
                    try? await Task.sleep(for: .milliseconds(1200))
                    await capture(window, to: out.deletingPathExtension().appendingPathExtension("mini.png"))
                    print("MINI \(Int(window.frame.width))x\(Int(window.frame.height))")
                }
                print("WINDOW state \(Updater.shared.state)"); fflush(stdout)
            }
        }
        // --selftest-track <dir>: the track panel, the tracks window, category chips and the
        // hotkey's window toggle, photographed from the app's own windows only.
        if let k = args.firstIndex(of: "--selftest-track"), k + 1 < args.count {
            let dir = URL(fileURLWithPath: args[k + 1])
            Task {
                func say(_ s: String) { print("TRACKUI " + s); fflush(stdout) }
                TrackState.shared.refresh()
                say("track \(TrackState.shared.track ?? "none"): \(TrackState.shared.plugins.map(\.name))")
                let model = PickerModel()
                await shoot(TrackPanel(model: model) {}, size: NSSize(width: 380, height: 560), to: dir.appendingPathComponent("track-panel.png"))
                model.replaceTarget = TrackState.shared.plugins.last
                await shoot(ReplaceBanner(model: model).frame(width: 900), size: NSSize(width: 900, height: 40), to: dir.appendingPathComponent("replace-banner.png"))
                let view = ViewSettings.shared
                let oldRow = view.chipRow
                for row in [ViewSettings.ChipRow.categories, .both] {
                    view.chipRow = row
                    await shoot(CollectionBar(model: PickerModel()).frame(width: 1100), size: NSSize(width: 1100, height: 44),
                                to: dir.appendingPathComponent("chips-\(row.rawValue).png"))
                }
                let m2 = PickerModel()
                m2.category = "Reverb"
                say("category Reverb: \(m2.results.count) plugins, all reverb: \(m2.results.allSatisfy { $0.displayCategory == "Reverb" })")
                view.chipRow = oldRow
                if let p = PluginStore.shared.plugins.first(where: { $0.name == "ChromaVerb" }) {
                    TracksWindow.shared.show(.find(p))
                    try? await Task.sleep(for: .seconds(4))
                    if let w = NSApp.windows.first(where: { $0.isVisible && ($0.contentView as? NSHostingView<TracksView>) != nil }) {
                        await capture(w, to: dir.appendingPathComponent("tracks-find.png"))
                        w.orderOut(nil)
                    }
                }
                // Control Option P: brings the main window up, then puts it away.
                say("windows: " + NSApp.windows.map { "\($0.identifier?.rawValue ?? "nil")/\(type(of: $0))/vis=\($0.isVisible)" }.joined(separator: ", ") + " opener=\(LibraryWindow.opener != nil)")
                LibraryWindow.window?.orderOut(nil)
                LogicInserter.shared.logicApp?.activate()
                try? await Task.sleep(for: .milliseconds(800))
                pressHotKey()
                try? await Task.sleep(for: .milliseconds(1000))
                say("after first press: " + NSApp.windows.filter(\.isVisible).map { "\($0.identifier?.rawValue ?? "nil") key=\($0.isKeyWindow)" }.joined(separator: ", ") + " active=\(NSApp.isActive)")
                let shown = LibraryWindow.window.map { $0.isVisible && $0.isKeyWindow } ?? false
                say("picker instead: \(PickerPanelController.shared.isVisible)")
                PickerPanelController.shared.hide()
                pressHotKey()
                try? await Task.sleep(for: .milliseconds(500))
                let hidden = !(LibraryWindow.window?.isVisible ?? false)
                say("hotkey shows library: \(shown), second press hides it: \(hidden)")
                say("done")
            }
        }
        // --selftest-whatsnew-window <png>: the What's New window with this version's notes.
        if let k = args.firstIndex(of: "--selftest-whatsnew-window"), k + 1 < args.count {
            let out = URL(fileURLWithPath: args[k + 1])
            Task {
                let lines = (try? String(contentsOfFile: args[k + 2], encoding: .utf8))?
                    .split(separator: "\n").map { String($0.dropFirst(2)) } ?? []
                WhatsNewWindow.shared.show(version: "0.5.0", notes: lines, justUpdated: args.contains("--updated"))
                try? await Task.sleep(for: .milliseconds(1200))
                if let w = NSApp.windows.first(where: { $0.isVisible && ($0.contentView as? NSHostingView<WhatsNewView>) != nil }) {
                    await capture(w, to: out)
                }
                print("WHATSNEW done"); fflush(stdout)
            }
        }
        // --selftest-shortcuts <dir>: the Shortcuts tab, conflict handling, and Caps Lock as Hyper
        // switched on and straight back off.
        if let k = args.firstIndex(of: "--selftest-shortcuts"), k + 1 < args.count {
            let dir = URL(fileURLWithPath: args[k + 1])
            Task {
                func say(_ s: String) { print("KEYS " + s); fflush(stdout) }
                let s = Shortcuts.shared
                let before = ShortcutAction.allCases.map { s.combo($0) }
                let p = s.combo(.openLibrary)!
                let other = s.set(.quickPicker, p)
                say("give ⌃⌥P to quick picker: took it from \(other?.rawValue ?? "none"), open library now \(s.combo(.openLibrary)?.display ?? "none")")
                say("hyper label: \(KeyCombo(keyCode: 40, mods: KeyCombo.hyperMods, key: "K").display)")
                for (a, c) in zip(ShortcutAction.allCases, before) { s.set(a, c) }
                say("restored: open library \(s.label(.openLibrary)), quick picker '\(s.label(.quickPicker))'")
                await shoot(ShortcutSettings().frame(width: 700, height: 980), size: NSSize(width: 700, height: 980),
                            to: dir.appendingPathComponent("shortcuts.png"))
                // Never switches the keyboard here: only checks that another app's mapping is seen
                // and left alone.
                let mapBefore = Self.mapping()
                let problem = HyperKey.otherAppMapsKeys ? HyperKey.start() : "skipped"
                say("other app maps keys: \(HyperKey.otherAppMapsKeys) | start refused: \(problem ?? "no, started") | mapping unchanged: \(mapBefore == Self.mapping())")
                say("done")
            }
        }
        if let k = args.firstIndex(of: "--readme-shots"), k + 2 < args.count {
            let lines = (try? String(contentsOfFile: args[k + 2], encoding: .utf8))?
                .split(separator: "\n").map { String($0.dropFirst(2)) } ?? []
            Task { await readmeShots(URL(fileURLWithPath: args[k + 1]), notes: lines) }
        }
        // --share-shots <dir>: the social preview card (1280 by 640) and the Share window.
        if let k = args.firstIndex(of: "--share-shots"), k + 1 < args.count {
            let dir = URL(fileURLWithPath: args[k + 1])
            Task {
                let r = ImageRenderer(content: ShareCard().frame(width: 1280, height: 640))
                r.scale = 1
                if let img = r.nsImage, let tiff = img.tiffRepresentation,
                   let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) {
                    try? png.write(to: dir.appendingPathComponent("social-preview.png"))
                }
                ShareWindow.shared.show()
                try? await Task.sleep(for: .seconds(1.2))
                if let w = NSApp.windows.first(where: { $0.isVisible && ($0.contentView as? NSHostingView<ShareView>) != nil }) {
                    await capture(w, to: dir.appendingPathComponent("share-window.png"))
                }
                print("SHARE done"); fflush(stdout)
            }
        }
        // --selftest-ondevice <dir>: the Mac's built-in model on one plugin (nothing is saved),
        // and a picture of the Plugin info choices.
        if let k = args.firstIndex(of: "--selftest-ondevice"), k + 1 < args.count {
            let dir = URL(fileURLWithPath: args[k + 1])
            Task {
                print("ONDEVICE status \(OnDeviceInfo.status)"); fflush(stdout)
                if let p = PluginStore.shared.plugins.first(where: { $0.name == "ChromaVerb" }) {
                    let t = Date()
                    switch await OnDeviceInfo.lookUp(p) {
                    case .success(let d):
                        print("ONDEVICE \(String(format: "%.1f", Date().timeIntervalSince(t)))s category=\(d.category) | kind=\(d.kind) | best=\(d.bestFeature) | summary=\(d.summary) | highlights=\(d.highlights)")
                    case .failure(let e): print("ONDEVICE failed \(e)")
                    }
                }
                await shoot(Form { Section("Plugin info") { InfoSourcePicker() } }.formStyle(.grouped).frame(width: 640, height: 260),
                            size: NSSize(width: 640, height: 260), to: dir.appendingPathComponent("info-source.png"))
                print("ONDEVICE done"); fflush(stdout)
            }
        }
        if let k = args.firstIndex(of: "--selftest-zoom"), k + 1 < args.count {
            let out = URL(fileURLWithPath: args[k + 1])
            Task {
                if let p = PluginStore.shared.plugins.first(where: { $0.name == "Chaosverb" }) { ImageZoom.show(p) }
                try? await Task.sleep(for: .seconds(1.2))
                if let w = NSApp.windows.first(where: { $0 is ZoomWindow && $0.isVisible }) {
                    print("ZOOM \(Int(w.frame.width))x\(Int(w.frame.height))")
                    await capture(w, to: out)
                }
                print("ZOOM done"); fflush(stdout)
            }
        }
        // --selftest-category: sets a plugin's category, checks it shows and survives a rescan, then undoes it.
        if args.contains("--selftest-category") {
            Task {
                let store = PluginStore.shared
                guard let p = store.plugins.first(where: { !$0.isLogic }) else { exit(1) }
                let before = p.displayCategory
                store.update(p.id) { $0.userCategory = "Imaging" }
                let set = store.plugin(p.id)?.displayCategory ?? "?"
                store.rescan()
                let after = store.plugin(p.id)?.displayCategory ?? "?"
                store.update(p.id) { $0.userCategory = nil }
                print("CATEGORY \(p.name): \(before) -> \(set) -> after rescan \(after) -> back \(store.plugin(p.id)?.displayCategory ?? "?")")
                fflush(stdout); exit(0)
            }
        }
        // --selftest-picked <png>: the grid with three plugins picked and the bar at the bottom.
        if let k = args.firstIndex(of: "--selftest-picked"), k + 1 < args.count {
            let out = URL(fileURLWithPath: args[k + 1])
            Task {
                let model = PickerModel()
                model.picked = Set(model.results.prefix(3).map(\.id))
                await shoot(PluginGrid(model: model) {}.background(Theme.ground), size: NSSize(width: 900, height: 560), to: out)
                print("PICKED done"); fflush(stdout)
                exit(0)
            }
        }
        // --selftest-favorites <dir>: cards with their stars, then the Remove from Favorites
        // confirmation (answered Keep, so nothing changes).
        if let k = args.firstIndex(of: "--selftest-favorites"), k + 1 < args.count {
            let dir = URL(fileURLWithPath: args[k + 1])
            Task {
                LibraryWindow.show()
                try? await Task.sleep(for: .seconds(2.5))
                guard let w = LibraryWindow.window else { print("FAV no window"); return }
                await capture(w, to: dir.appendingPathComponent("cards.png"), scale: 1)
                let store = PluginStore.shared
                let id = store.favorites.first ?? store.plugins.first?.id
                let wasFavorite = id.map { store.favorites.contains($0) } ?? false
                if let id, !wasFavorite { store.favorites.insert(id) }
                if let id { store.favoriteTapped(id) }
                try? await Task.sleep(for: .seconds(0.8))
                await capture(w, to: dir.appendingPathComponent("confirm.png"), scale: 1)
                store.confirmingUnfavorite = nil
                if let id, !wasFavorite { store.favorites.remove(id) }
                print("FAV done"); fflush(stdout)
            }
        }
        // --selftest-compact <png>: how big a picture is once shrunk for sending.
        if let k = args.firstIndex(of: "--selftest-compact"), k + 1 < args.count {
            let d = (try? Data(contentsOf: URL(fileURLWithPath: args[k + 1]))) ?? Data()
            print("COMPACT \(d.count) -> \(PlugDB.compactForTest(d) ?? -1) bytes"); fflush(stdout)
            exit(0)
        }
        // --selftest-plugdb <id>: downloads that plugin's approved picture from the shared database.
        if let k = args.firstIndex(of: "--selftest-plugdb"), k + 1 < args.count {
            let id = args[k + 1]
            Task {
                let got = await PlugDB.fetchApproved([id])
                let file = PluginStore.shared.snapshotURL(for: id)
                let size = (try? FileManager.default.attributesOfItem(atPath: file.path)[.size] as? Int) ?? 0
                print("PLUGDB got=\(got.sorted()) file=\(size) bytes"); fflush(stdout)
                try? FileManager.default.removeItem(at: file)
                exit(0)
            }
        }
        if let k = args.firstIndex(of: "--selftest-features"), k + 1 < args.count {
            let dir = URL(fileURLWithPath: args[k + 1])
            Task { await features(dir); fflush(stdout) }
        }
        if let k = args.firstIndex(of: "--selftest-whatsnew"), k + 1 < args.count {
            let out = URL(fileURLWithPath: args[k + 1])
            Task {
                Updater.shared.whatsNew = (Updater.shared.currentVersion,
                                           ["New: Plugin chains you can drop on a track with one key.", "Improved: Faster search."])
                UpdateWindow.shared.show()
                try? await Task.sleep(for: .milliseconds(1200))
                if let w = NSApp.windows.first(where: { $0.isVisible && $0.contentView is NSHostingView<UpdateProgressView> }) {
                    await capture(w, to: out); print("WHATSNEW ok")
                } else { print("WHATSNEW none") }
                fflush(stdout)
            }
        }
        if let k = args.firstIndex(of: "--selftest-onboarding"), k + 1 < args.count {
            let out = URL(fileURLWithPath: args[k + 1])
            Task {
                OnboardingWindow.shared.show()
                try? await Task.sleep(for: .milliseconds(1200))
                if let w = NSApp.windows.first(where: { $0.isVisible && $0.contentView is NSHostingView<OnboardingView> }) {
                    await capture(w, to: out); print("ONBOARD ok")
                } else { print("ONBOARD none") }
                fflush(stdout)
            }
        }
        if args.contains("--dump-logic") {
            print("DUMP \(LogicInserter.shared.dumpDiagnostics()?.path ?? "failed (Logic open? Accessibility allowed?)")")
            fflush(stdout)
        }
        if let j = args.firstIndex(of: "--test-insert"), j + 1 < args.count {
            let name = args[j + 1]
            Task {
                guard let p = PluginStore.shared.plugins.first(where: { $0.name == name }) else {
                    print("INSERT no plugin named \(name)"); fflush(stdout); return
                }
                let slot = args.firstIndex(of: "--slot").flatMap { Int(args[$0 + 1]) }
                let outcome = await LogicInserter.shared.insert(p, replacing: slot)
                print("INSERT \(outcome)"); fflush(stdout)
            }
        }
        guard let i = args.firstIndex(of: "--selftest"), i + 1 < args.count else { return }
        let folder = URL(fileURLWithPath: args[i + 1])
        let query = i + 2 < args.count ? args[i + 2] : ""
        Task {
            while SnapshotQueue.shared.isRunning { try? await Task.sleep(for: .milliseconds(500)) }
            let controller = PickerPanelController.shared
            controller.show()
            let view = ViewSettings.shared
            view.layout = .grid; view.size = .medium; view.showName = true; view.showDetails = true
            view.showInfoPane = true; view.favoritesOnly = false
            controller.model.query = query
            try? await Task.sleep(for: .milliseconds(900))
            await capture(to: folder.appendingPathComponent("1-grid.png"))
            view.layout = .list
            try? await Task.sleep(for: .milliseconds(600))
            await capture(to: folder.appendingPathComponent("2-list.png"))
            view.layout = .grid; view.size = .huge; view.showName = false; view.showDetails = false
            view.showInfoPane = false; controller.model.query = ""
            try? await Task.sleep(for: .milliseconds(700))
            await capture(to: folder.appendingPathComponent("3-xl-no-info.png"))
            view.size = .medium; view.showName = true; view.showDetails = true; view.showInfoPane = true
            let store = PluginStore.shared
            print("COUNTS total \(store.plugins.count) visible \(store.plugins.filter(store.isVisible).count) logic \(store.plugins.filter(\.isLogic).count)")
            store.setGroup(.maker, "Apple", visible: false)
            print("HIDE Apple -> visible \(store.plugins.filter(store.isVisible).count)")
            store.setPlugin(store.plugins.first { $0.name == "AUDelay" }!.id, visible: true)
            print("SHOW AUDelay -> visible \(store.plugins.filter(store.isVisible).count)")
            store.setGroup(.maker, "Apple", visible: true)
            print("RESET -> visible \(store.plugins.filter(store.isVisible).count)")
            print("SELFTEST DONE")
            fflush(stdout)
        }
    }

    private static func capture(to url: URL) async {
        guard let window = NSApp.windows.first(where: { $0 is PickerPanel && $0.isVisible }) else { return }
        await capture(window, to: url)
    }

    /// --readme-shots <dir>: pictures and GIF frames for the README, from the app's own windows.
    static func readmeShots(_ dir: URL, notes: [String]) async {
        func say(_ s: String) { print("README " + s); fflush(stdout) }
        let fm = FileManager.default
        try? fm.createDirectory(at: dir.appendingPathComponent("frames"), withIntermediateDirectories: true)
        LibraryWindow.show()
        try? await Task.sleep(for: .seconds(1.5))
        guard let lib = LibraryWindow.window else { say("no library window"); return }
        let oldFrame = lib.frame
        lib.setFrame(NSRect(x: 60, y: 60, width: 1320, height: 820), display: true)
        let post = { (name: Notification.Name, obj: String) in NotificationCenter.default.post(name: name, object: obj) }
        post(.demoQuery, "")
        post(.demoSelect, "ChromaVerb")
        try? await Task.sleep(for: .seconds(1.2))
        await capture(lib, to: dir.appendingPathComponent("library.png"))
        say("library")

        // GIF: typing a search, the rest fading away.
        post(.demoQuery, "")
        post(.demoSelect, "ChromaVerb")
        try? await Task.sleep(for: .seconds(1))
        var frame = 0
        func grab(_ n: Int) async {
            for _ in 0..<n {
                await capture(lib, to: dir.appendingPathComponent(String(format: "frames/f%04d.png", frame)), scale: 1)
                frame += 1
            }
        }
        await grab(6)
        for q in ["v", "ve", "ver", "verb"] { post(.demoQuery, q); await grab(5) }
        await grab(10)
        post(.demoQuery, "delay"); await grab(14)
        post(.demoQuery, "warm tape"); await grab(16)
        post(.demoQuery, ""); await grab(10)
        say("frames \(frame)")

        // The selected track's panel, on the track with the most plugins.
        if let tracks = await LogicTrack.shared.scanProject(),
           let busy = tracks.max(by: { $0.plugins.count < $1.plugins.count }) {
            _ = await LogicTrack.shared.goTo(busy)
            try? await Task.sleep(for: .seconds(1))
        }
        TrackState.shared.refresh()
        await shoot(TrackPanel(model: PickerModel()) {}, size: NSSize(width: 380, height: 640), to: dir.appendingPathComponent("track-panel.png"))
        say("track panel: \(TrackState.shared.track ?? "none")")

        if let p = PluginStore.shared.plugins.first(where: { $0.name == "ChromaVerb" }) {
            TracksWindow.shared.show(.find(p))
            try? await Task.sleep(for: .seconds(4))
            if let w = NSApp.windows.first(where: { $0.isVisible && ($0.contentView as? NSHostingView<TracksView>) != nil }) {
                w.setContentSize(NSSize(width: 440, height: 380))
                try? await Task.sleep(for: .milliseconds(400))
                await capture(w, to: dir.appendingPathComponent("find-on-tracks.png"))
                w.orderOut(nil)
            }
        }
        WhatsNewWindow.shared.show(version: "0.5.0", notes: notes)
        try? await Task.sleep(for: .seconds(1.2))
        if let w = NSApp.windows.first(where: { $0.isVisible && ($0.contentView as? NSHostingView<WhatsNewView>) != nil }) {
            await capture(w, to: dir.appendingPathComponent("whats-new.png"))
            w.orderOut(nil)
        }
        await shoot(ShortcutSettings().frame(width: 700, height: 760), size: NSSize(width: 700, height: 760),
                    to: dir.appendingPathComponent("shortcuts.png"))
        lib.setFrame(oldFrame, display: true)
        say("done")
    }

    private static func capture(_ window: NSWindow, to url: URL, scale: Int = 2) async {
        guard let content = try? await SCShareableContent.currentProcess,
              let sc = content.windows.first(where: { $0.windowID == CGWindowID(window.windowNumber) })
        else { print("SELFTEST no window"); return }
        let config = SCStreamConfiguration()
        config.width = Int(sc.frame.width) * scale
        config.height = Int(sc.frame.height) * scale
        config.showsCursor = false
        guard let img = try? await SCScreenshotManager.captureImage(
            contentFilter: SCContentFilter(desktopIndependentWindow: sc), configuration: config),
              let data = NSBitmapImageRep(cgImage: img).representation(using: .png, properties: [:])
        else { print("SELFTEST capture failed"); return }
        try? data.write(to: url)
    }
}
#endif
