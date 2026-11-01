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
                if args.contains("--sidecar") { UserLibrary.shared.readOnly = true; LibraryWindow.show() }
                else { await Updater.shared.check(userInitiated: true) }
                try? await Task.sleep(for: .milliseconds(args.contains("--sidecar") ? 3000 : 1500))
                guard let window = (args.contains("--sidecar") ? LibraryWindow.window : nil)
                        ?? NSApp.windows.first(where: { !($0 is PickerPanel) && $0.isVisible && $0.frame.width > 500 })
                else { print("WINDOW none"); fflush(stdout); return }
                await capture(window, to: out)
                if args.contains("--mini") {
                    NotificationCenter.default.post(name: .toggleMiniMode, object: nil)
                    try? await Task.sleep(for: .milliseconds(1200))
                    await capture(window, to: out.deletingPathExtension().appendingPathExtension("mini.png"))
                    print("MINI \(Int(window.frame.width))x\(Int(window.frame.height))")
                }
                if args.contains("--sidecar") {
                    let full = window.frame
                    for m in ["sidecar", "mini", "sidecar", "full"] {
                        NotificationCenter.default.post(name: .demoWindowMode, object: m)
                        try? await Task.sleep(for: .milliseconds(1400))
                        print("MODE \(m) \(Int(window.frame.width))x\(Int(window.frame.height)) level=\(window.level.rawValue)"); fflush(stdout)
                        if m != "full" { await capture(window, to: out.deletingPathExtension().appendingPathExtension("\(m).png")) }
                    }
                    print("MODE back to full: \(window.frame == full)")
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
        // --selftest-webpicture <name> <file>: finds that plugin's picture on the web (not saved in the app).
        if let k = args.firstIndex(of: "--selftest-webpicture"), k + 2 < args.count {
            Task {
                // "Name|Maker" tries any plugin, even one not on this Mac.
                let parts = args[k + 1].split(separator: "|").map(String.init)
                guard var p = PluginStore.shared.plugins.first(where: { $0.name == parts[0] }) ?? PluginStore.shared.plugins.first(where: { !$0.isLogic })
                else { print("WEB no plugin"); exit(1) }
                if parts.count == 2 { p.name = parts[0]; p.manufacturer = parts[1] }
                print("WEB \(p.name): \(await WebPicture.probe(p, to: URL(fileURLWithPath: args[k + 2])))"); fflush(stdout)
                exit(0)
            }
        }
        // --selftest-feedback <png>: the feedback window.
        if let k = args.firstIndex(of: "--selftest-feedback"), k + 1 < args.count {
            Task {
                FeedbackWindow.shared.show()
                try? await Task.sleep(for: .seconds(2))
                if let w = NSApp.windows.first(where: { $0.isVisible && $0.contentView is NSHostingView<FeedbackView> }) {
                    await capture(w, to: URL(fileURLWithPath: args[k + 1]), scale: 1)
                }
                exit(0)
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
        // --selftest-small <png>: small cards with their stars; the size setting is put back after.
        if let k = args.firstIndex(of: "--selftest-small"), k + 1 < args.count {
            Task {
                let v = ViewSettings.shared, old = v.tileWidth
                v.setTileWidth(130)
                await shoot(PluginGrid(model: PickerModel()) {}.background(Theme.ground), size: NSSize(width: 700, height: 360),
                            to: URL(fileURLWithPath: args[k + 1]))
                v.setTileWidth(old)
                exit(0)
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
        // --selftest-chipbar <file>: the chip row with a track suggestion under it.
        if let k = args.firstIndex(of: "--selftest-chipbar"), k + 1 < args.count {
            let out = URL(fileURLWithPath: args[k + 1])
            Task {
                let m = PickerModel()
                m.suggestion = ("Vintage B3 Organ", [])
                await shoot(CollectionBar(model: m, showSizeSlider: true).frame(width: 1000).background(Theme.ground),
                            size: NSSize(width: 1000, height: 90), to: out)
                print("CHIPBAR ok"); fflush(stdout)
            }
        }
        // --selftest-licenses <dir>: sample licenses (never the real file), then pictures of the windows.
        if let k = args.firstIndex(of: "--selftest-licenses"), k + 1 < args.count {
            let dir = URL(fileURLWithPath: args[k + 1])
            Task {
                Licenses.testMode = true
                let lic = Licenses.shared
                lic.licenses = [:]; lic.plans = []
                let cal = Calendar.current, today = cal.startOfDay(for: Date())
                lic.plans = [
                    LicensePlan(name: "Waves Creative Access", kind: .subscription, cost: 299.88, period: .yearly,
                                nextRenewal: cal.date(byAdding: .day, value: 12, to: today), remindDays: 7),
                    LicensePlan(name: "Slate All Access", kind: .subscription, cost: 14.99, period: .monthly,
                                nextRenewal: cal.date(byAdding: .day, value: 4, to: today), remindDays: 3),
                    LicensePlan(name: "Plugin Alliance MEGA", kind: .bundle, cost: 349, value: 4999),
                ]
                let ps = PluginStore.shared.plugins.filter { !$0.isLogic }
                for (i, p) in ps.prefix(12).enumerated() {
                    var l = LicenseInfo()
                    switch i % 4 {
                    case 0: l.status = .owned; l.price = 149; l.value = 199; l.store = "Plugin Boutique"
                    case 1: l.status = .subscription; l.planID = lic.plans[0].id
                    case 2: l.status = .trial; l.trialEnds = cal.date(byAdding: .day, value: 9, to: today); l.value = 129
                    default: l.status = .bundle; l.planID = lic.plans[2].id
                    }
                    lic.set(l, for: p.id)
                }
                await shoot(LicensesView(), size: NSSize(width: 760, height: 900), to: dir.appendingPathComponent("licenses.png"))
                await shoot(PlanEditor(id: lic.plans[0].id) {}, size: NSSize(width: 520, height: 700),
                            to: dir.appendingPathComponent("plan.png"))
                if let p = ps.first {
                    await shoot(LicenseSection(plugin: p).padding(20).frame(width: 420, alignment: .topLeading)
                        .background(Theme.ground), size: NSSize(width: 420, height: 520),
                                to: dir.appendingPathComponent("section.png"))
                }
                await shoot(CalendarPicker(date: .constant(cal.date(byAdding: .day, value: 12, to: today)!)) {},
                            size: NSSize(width: 300, height: 380), to: dir.appendingPathComponent("calendar.png"))
                await shoot(CurrencyList {}, size: NSSize(width: 280, height: 360), to: dir.appendingPathComponent("currency.png"))
                await shoot(LicensesView(topPadding: 22), size: NSSize(width: 780, height: 300), to: dir.appendingPathComponent("tab.png"))
                print("LICENSES ok \(lic.money(lic.collectionValue)) \(lic.money(lic.perMonth))"); fflush(stdout)
            }
        }
        // --selftest-unused <file>: the Plugins you don't use screen (BL-99).
        if let k = args.firstIndex(of: "--selftest-unused"), k + 1 < args.count {
            let out = URL(fileURLWithPath: args[k + 1])
            Task {
                ReportWindow.pendingTab = "Unused"
                await shoot(ReportView(), size: NSSize(width: 760, height: 640), to: out)
                print("UNUSED ok"); fflush(stdout)
            }
        }
        // --selftest-search "warm tape|wide|punchy drums": what each search finds (BL-98).
        if let k = args.firstIndex(of: "--selftest-search"), k + 1 < args.count {
            for q in args[k + 1].split(separator: "|").map(String.init) {
                let m = PickerModel()
                m.query = q
                print("SEARCH \(q) -> \(m.results.prefix(8).map(\.name).joined(separator: ", ")) | hint: \(m.soundHint ?? "-")")
            }
            print("SEARCH done"); fflush(stdout)
        }
        // --selftest-themes <dir>: the library and the Appearance tab in every theme, then the
        // largest text, as pictures (BL-130). Nothing is saved.
        if let k = args.firstIndex(of: "--selftest-themes"), k + 1 < args.count {
            let dir = URL(fileURLWithPath: args[k + 1])
            Task {
                let look = AppearanceSettings.shared
                // --fakefailed: two visible plugins look failed, in memory only (BL-137 button picture).
                if args.contains("--fakefailed") {
                    let store = PluginStore.shared
                    let pick = Set(store.plugins.filter { !$0.isLogic && store.isVisible($0) }.prefix(2).map(\.id))
                    store.debugUsePlugins(store.plugins.map { p in var q = p; if pick.contains(q.id) { q.snapshotState = .failed }; return q })
                }
                LibraryWindow.show()
                try? await Task.sleep(for: .seconds(2))
                guard let w = LibraryWindow.window else { print("THEMES no window"); return }
                w.setFrame(NSRect(x: 60, y: 60, width: 1320, height: 820), display: true)
                NotificationCenter.default.post(name: .demoSelect, object: "ChromaVerb")
                let only = args.firstIndex(of: "--only").map { args[$0 + 1] }
                for p in Palette.all where only == nil || only == p.id {
                    look.paletteID = p.id
                    try? await Task.sleep(for: .milliseconds(700))
                    await capture(w, to: dir.appendingPathComponent("lib-\(p.id).png"), scale: 1)
                    await shoot(AppearanceSettingsView(), size: NSSize(width: 780, height: 560), to: dir.appendingPathComponent("set-\(p.id).png"))
                    print("THEMES \(p.id)"); fflush(stdout)
                    if only != nil {
                        await shoot(DialogCard(title: "Delete this collection?", message: "The plugins stay installed.", field: nil, multiline: false,
                                               checkbox: "Don't ask again", choices: [Dialog.Choice(title: "Cancel", cancel: true),
                                               Dialog.Choice(title: "Delete", primary: true)], state: Dialog.State()) { _ in },
                                    size: NSSize(width: 400, height: 190), to: dir.appendingPathComponent("dialog-\(p.id).png"))
                        await shoot(PillsEditor(topPadding: 20), size: NSSize(width: 760, height: 560), to: dir.appendingPathComponent("pills-\(p.id).png"))
                        for type in [NSEvent.EventType.keyDown, .keyUp] {
                            if let e = NSEvent.keyEvent(with: type, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: w.windowNumber,
                                                        context: nil, characters: "\u{F703}", charactersIgnoringModifiers: "\u{F703}", isARepeat: false, keyCode: 124) { NSApp.postEvent(e, atStart: false) }
                        }
                        try? await Task.sleep(for: .milliseconds(500))
                        for type in [NSEvent.EventType.keyDown, .keyUp] {
                            if let e = NSEvent.keyEvent(with: type, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: w.windowNumber,
                                                        context: nil, characters: " ", charactersIgnoringModifiers: " ", isARepeat: false, keyCode: 49) { NSApp.postEvent(e, atStart: false) }
                        }
                        try? await Task.sleep(for: .milliseconds(900))
                        await capture(w, to: dir.appendingPathComponent("preview-\(p.id).png"), scale: 1)
                    }
                }
                look.paletteID = "classic"; look.textScale = 1.3
                try? await Task.sleep(for: .milliseconds(700))
                await capture(w, to: dir.appendingPathComponent("lib-classic-130.png"), scale: 1)
                look.paletteID = "clean-light"
                try? await Task.sleep(for: .milliseconds(700))
                await capture(w, to: dir.appendingPathComponent("lib-light-130.png"), scale: 1)
                look.textScale = 1; look.paletteID = "classic"
                print("THEMES done"); fflush(stdout)
            }
        }
        // --selftest-syncrow <dir>: the three sync states as pictures (BL-131). Nothing syncs.
        if let k = args.firstIndex(of: "--selftest-syncrow"), k + 1 < args.count {
            let dir = URL(fileURLWithPath: args[k + 1])
            Task {
                for (n, st) in [("syncing", SyncProgressRow.State.syncing), ("synced", .synced), ("uploading", .stillUploading)] {
                    await shoot(Form { Section("Sync") { Toggle("Sync with my other Macs through iCloud Drive", isOn: .constant(true)); SyncProgressRow(state: st) } }
                                    .formStyle(.grouped).preferredColorScheme(Theme.scheme),
                                size: NSSize(width: 700, height: 150), to: dir.appendingPathComponent("sync-\(n).png"))
                }
                print("SYNCROW done"); fflush(stdout)
            }
        }
        // --selftest-logictags <dir>: what Import from Logic would bring in, and the crash note (BL-139). Read only.
        if let k = args.firstIndex(of: "--selftest-logictags"), k + 1 < args.count {
            let dir = URL(fileURLWithPath: args[k + 1])
            Task {
                try? await Task.sleep(for: .seconds(2))
                let all = LogicTags.entries()
                let f = LogicTags.found()
                print("LT entries=\(all.count) favorites=\(f.favorites.count) categories=\(f.categories.keys.sorted()) crashes=\(all.filter { $0.value.crashes > 0 }.map { "\($0.key):\($0.value.crashes)" })")
                if let p = PluginStore.shared.plugins.first(where: { LogicTags.crashes($0.id) > 0 }) {
                    await shoot(PluginDetailView(plugin: p, model: PickerModel()) {}, size: NSSize(width: 340, height: 560),
                                to: dir.appendingPathComponent("crash-note.png"))
                }
                print("LT done"); fflush(stdout)
            }
        }
        // --selftest-pilldefaults: what a new user gets, and an old saved setting without these keys (BL-141).
        if args.contains("--selftest-pilldefaults") {
            let fresh = PillPrefs()
            let old = (try? JSONDecoder().decode(PillPrefs.self, from: Data("{}".utf8)))
            print("PD fresh sort=\(fresh.sort) counts=\(fresh.showCounts) wrap=\(fresh.wrap) compact=\(fresh.compact)")
            print("PD old-save sort=\(old.map { "\($0.sort)" } ?? "nil") counts=\(old?.showCounts ?? false) wrap=\(old?.wrap ?? false)")
            print("PD done"); fflush(stdout)
        }
        // --selftest-removed: the scan keeps real plugins and drops one whose file is gone (BL-142). Nothing saved.
        if args.contains("--selftest-removed") {
            let real = PluginScanner.scan()
            let missingOnDisk = real.filter { p in p.path.map { !FileManager.default.fileExists(atPath: $0) } ?? false }
            var ghost = real.first { !$0.isLogic }!
            ghost.id = "aufx-Gone-Test"; ghost.name = "Deleted Plugin"; ghost.path = "/Library/Audio/Plug-Ins/Components/Deleted Plugin.component"
            let kept = PluginScanner.keepInstalled(real + [ghost])
            print("RM real=\(real.count) missing-on-disk=\(missingOnDisk.map(\.name)) kept=\(kept.count) ghost-kept=\(kept.contains { $0.id == ghost.id })")
            let allGone = real.map { p -> Plugin in var q = p; q.path = "/nope/\(p.id)"; return q }
            print("RM safety: all paths wrong -> kept \(PluginScanner.keepInstalled(allGone).count) of \(allGone.count)")
            print("RM done"); fflush(stdout)
        }
        // --selftest-pluginmanager <dir>: scan every format, list duplicates, picture the tab (BL-144). Moves nothing.
        if let k = args.firstIndex(of: "--selftest-pluginmanager"), k + 1 < args.count {
            let dir = URL(fileURLWithPath: args[k + 1])
            Task {
                let m = PluginManager.shared
                m.scan()
                while m.scanning || m.lastScan == nil { try? await Task.sleep(for: .milliseconds(200)) }
                let byFormat = Dictionary(grouping: m.items, by: \.format).map { "\($0.key.rawValue):\($0.value.count)" }.sorted()
                let notes = m.notes()
                print("PM items=\(m.items.count) \(byFormat) receipts=\(m.items.filter { $0.receipt != nil }.count) notes=\(notes.count)")
                for i in m.items where notes[i.id] != nil { print("PM   \(notes[i.id]!.rawValue): \(i.name) [\(i.format.rawValue), \(i.system ? "system" : "user"), \(i.version)]") }
                for (pkg, files) in m.leftoverFiles.sorted(by: { $0.key < $1.key }) {
                    print("PM   leftovers \(pkg): \(files.count)"); for f in files.prefix(4) { print("PM     \(f)") }
                }
                // Ticks rows in memory to picture the footer; nothing is moved.
                if args.contains("--selectall") { m.selected = Set(m.items.map(\.id)); print("PM leftovers for all: \(m.leftovers(for: m.items).count)") }
                let w = NSWindow(contentRect: NSRect(x: 80, y: 80, width: 780, height: 580), styleMask: [.titled], backing: .buffered, defer: false)
                let ask = args.contains("--ask") ? Array(m.items.filter { !$0.format.usedByLogic }.prefix(3)) : nil
                w.contentView = NSHostingView(rootView: PluginManagerView(asking: ask))
                w.makeKeyAndOrderFront(nil)
                try? await Task.sleep(for: .seconds(1.2))
                await capture(w, to: dir.appendingPathComponent("pm.png"), scale: 1)
                print("PM done"); fflush(stdout)
            }
        }
        // --selftest-shortnames: Logic's shortened slot names matched to installed plugins (BL-145).
        if args.contains("--selftest-shortnames") {
            Task {
                try? await Task.sleep(for: .seconds(2))
                for slot in ["SpecGate", "SilvGate", "SilvComp", "ChanEQ", "Compressor", "Drum Kit"] {
                    let hits = PluginStore.shared.plugins.filter { LogicTrack.shortName(slot, matches: $0.name) }.map(\.name)
                    print("SHORT \(slot) -> \(hits)")
                }
                // An empty chain opened, as in Adi's report; in memory only, nothing is saved.
                if let k = args.firstIndex(of: "--shoot"), k + 1 < args.count {
                    UserLibrary.shared.readOnly = true
                    let c = UserLibrary.shared.newChain(named: "Goldi")
                    let w = NSWindow(contentRect: NSRect(x: 80, y: 80, width: 380, height: 600), styleMask: [.borderless], backing: .buffered, defer: false)
                    w.contentView = NSHostingView(rootView: ChainsPanel(close: {}, editing: c.id).fixedSize())
                    w.setContentSize(w.contentView!.fittingSize)
                    w.makeKeyAndOrderFront(nil)
                    try? await Task.sleep(for: .seconds(1))
                    w.setContentSize(w.contentView!.fittingSize)
                    try? await Task.sleep(for: .seconds(0.5))
                    await capture(w, to: URL(fileURLWithPath: args[k + 1]), scale: 1)
                }
                print("SHORT done"); fflush(stdout)
            }
        }
        // --selftest-pmmove: moves one fake plugin the test made itself, with the button's own code (BL-144).
        if args.contains("--selftest-pmmove") {
            Task {
                let fm = FileManager.default
                let fake = fm.homeDirectoryForCurrentUser.appendingPathComponent("Library/Audio/Plug-Ins/VST3/ZZ PM Test.vst3/Contents")
                try? fm.createDirectory(at: fake, withIntermediateDirectories: true)
                fm.createFile(atPath: fake.appendingPathComponent("Info.plist").path, contents: Data("<plist><dict/></plist>".utf8))
                let m = PluginManager.shared
                m.scan()
                while m.scanning || m.lastScan == nil { try? await Task.sleep(for: .milliseconds(200)) }
                let pick = m.items.filter { $0.name == "ZZ PM Test" }
                print("PMMOVE found \(pick.count)")
                let r = m.moveToDesktop(pick)
                print("PMMOVE moved=\(r.moved) failed=\(r.failed) folder=\(r.folder.path) exists=\(fm.fileExists(atPath: r.folder.path))")
                print("PMMOVE done"); fflush(stdout)
            }
        }
        // --selftest-makerurl: where Maker's Website goes for a few plugins (BL-129).
        if args.contains("--selftest-makerurl") {
            Task {
                try? await Task.sleep(for: .seconds(2))
                let ps = PluginStore.shared.plugins
                let picks = [ps.first { $0.isLogic }, ps.first { !$0.isLogic && MakerSites.site(for: $0.manufacturer) != nil },
                             ps.first { !$0.isLogic && MakerSites.site(for: $0.manufacturer) == nil && PlugDB.productURL($0.id) == nil }]
                for p in picks.compactMap({ $0 }) { print("URL \(p.manufacturer) / \(p.name) -> \(MakerSites.url(for: p)?.absoluteString ?? "nil")") }
                print("URL done"); fflush(stdout)
            }
        }
        // --selftest-msflip: the window open first, then the mono/stereo switch flipped and the
        // plugin list changed while it is showing, as a user would (BL-124). In memory only.
        if args.contains("--selftest-msflip") {
            Task {
                func say(_ s: String) { print("FLIP " + s); fflush(stdout) }
                UserLibrary.shared.readOnly = true
                let start = ViewSettings.shared.joinMonoStereo
                LibraryWindow.show()
                try? await Task.sleep(for: .seconds(2))
                guard let w = LibraryWindow.window else { say("no window"); return }
                say("window open")
                if let q = args.firstIndex(of: "--emptyq").map({ _ in "zzzzqq" }) {
                    // A search that finds nothing, typed (no animation) or animated like the old test.
                    if args.contains("--resize-first") { w.setFrame(NSRect(x: 60, y: 60, width: 1320, height: 700), display: true) }
                    NotificationCenter.default.post(name: args.contains("--anim") ? .demoQuery : .demoQueryPlain, object: q)
                    try? await Task.sleep(for: .seconds(2))
                    say("empty search shown")
                    for width in stride(from: 860, through: 1500, by: 80) {
                        w.setFrame(NSRect(x: 60, y: 60, width: width, height: 760), display: true)
                        try? await Task.sleep(for: .milliseconds(60))
                    }
                    say("done")
                    return
                }
                for i in 0..<6 {
                    ViewSettings.shared.joinMonoStereo.toggle()
                    try? await Task.sleep(for: .milliseconds(400))
                    say("flip \(i) joined=\(ViewSettings.shared.joinMonoStereo)")
                }
                if !args.contains("--nofakes"), let base = PluginStore.shared.plugins.first(where: { !$0.isLogic }) {
                    func fake(_ name: String, _ id: String) -> Plugin { var p = base; p.name = name; p.manufacturer = "Waves"; p.id = id; return p }
                    PluginStore.shared.debugUsePlugins(PluginStore.shared.plugins + [fake("API-550A (m)", "t-m"), fake("API-550A (s)", "t-s")])
                    try? await Task.sleep(for: .milliseconds(600))
                    say("fakes added")
                    NotificationCenter.default.post(name: .demoQuery, object: "550")
                    NotificationCenter.default.post(name: .demoSelect, object: "API-550A (s)")
                    try? await Task.sleep(for: .milliseconds(600))
                    say("selected joined plugin")
                }
                for width in stride(from: 860, through: 1500, by: 80) {
                    w.setFrame(NSRect(x: 60, y: 60, width: width, height: 760), display: true)
                    try? await Task.sleep(for: .milliseconds(60))
                }
                say("resized")
                ViewSettings.shared.joinMonoStereo = start
                say("done")
            }
        }
        // --selftest-preview <dir>: arrows move the keyboard to the plugins, Space opens the
        // preview, Right moves on, Space closes, a letter goes back to the search (BL-106).
        if let k = args.firstIndex(of: "--selftest-preview"), k + 1 < args.count {
            let dir = URL(fileURLWithPath: args[k + 1])
            Task {
                LibraryWindow.show()
                try? await Task.sleep(for: .seconds(1.5))
                guard let lib = LibraryWindow.window else { print("PREVIEW no window"); return }
                lib.setFrame(NSRect(x: 60, y: 60, width: 1320, height: 820), display: true)
                NotificationCenter.default.post(name: .demoQuery, object: "")
                NotificationCenter.default.post(name: .demoSelect, object: args.dropFirst(k + 2).first ?? "ChromaVerb")
                try? await Task.sleep(for: .seconds(1))
                @MainActor func key(_ code: UInt16, _ chars: String) async {
                    for type in [NSEvent.EventType.keyDown, .keyUp] {
                        if let e = NSEvent.keyEvent(with: type, location: .zero, modifierFlags: [], timestamp: 0,
                                                    windowNumber: lib.windowNumber, context: nil, characters: chars,
                                                    charactersIgnoringModifiers: chars, isARepeat: false, keyCode: code) {
                            NSApp.postEvent(e, atStart: false)
                        }
                    }
                    try? await Task.sleep(for: .milliseconds(700))
                }
                @MainActor func shot(_ name: String) async {
                    await capture(lib, to: dir.appendingPathComponent(name + ".png"), scale: 1)
                    print("PREVIEW \(name) responder=\(lib.firstResponder.map { String(describing: type(of: $0)) } ?? "nil")")
                    fflush(stdout)
                }
                // A single click on another tile: it must be selected at once, not after the
                // double-click time.
                if args.contains("--click") {
                    let at = NSPoint(x: 300, y: lib.frame.height - 170)
                    // --press: only the button going down, after the pointer moves over the tile.
                    let press = args.contains("--press")
                    let types: [NSEvent.EventType] = press ? [.mouseMoved, .leftMouseDown] : [.leftMouseDown, .leftMouseUp]
                    if press {
                        let screen = lib.convertPoint(toScreen: at)
                        CGWarpMouseCursorPosition(CGPoint(x: screen.x, y: (NSScreen.screens.first?.frame.maxY ?? 0) - screen.y))
                        try? await Task.sleep(for: .milliseconds(300))
                    }
                    for type in types {
                        if let e = NSEvent.mouseEvent(with: type, location: at, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                                      windowNumber: lib.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1) {
                            NSApp.postEvent(e, atStart: false)
                        }
                    }
                    try? await Task.sleep(for: .milliseconds(40))
                    await shot("0-click-40ms")
                    if press, let up = NSEvent.mouseEvent(with: .leftMouseUp, location: at, modifierFlags: [],
                                                         timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: lib.windowNumber,
                                                         context: nil, eventNumber: 0, clickCount: 1, pressure: 0) {
                        NSApp.postEvent(up, atStart: false)
                    }
                    try? await Task.sleep(for: .milliseconds(900))
                }
                // --pill x y: scrolled down, click a category pill; the grid must be back at the top (BL-138).
                if let k3 = args.firstIndex(of: "--pill") {
                    let at = NSPoint(x: Double(args[k3 + 1]) ?? 0, y: lib.frame.height - (Double(args[k3 + 2]) ?? 0))
                    await shot("pill-0-scrolled")
                    let screen = lib.convertPoint(toScreen: at)
                    CGWarpMouseCursorPosition(CGPoint(x: screen.x, y: (NSScreen.screens.first?.frame.maxY ?? 0) - screen.y))
                    try? await Task.sleep(for: .milliseconds(250))
                    for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                        if let e = NSEvent.mouseEvent(with: type, location: at, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                                      windowNumber: lib.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1) {
                            NSApp.postEvent(e, atStart: false)
                        }
                        try? await Task.sleep(for: .milliseconds(60))
                    }
                    try? await Task.sleep(for: .milliseconds(900))
                    await shot("pill-1-after")
                    print("PREVIEW done pill"); fflush(stdout)
                    return
                }
                // --shuffle x y: click the dice twice; pictures mid-spin and where it landed (BL-133).
                if let k2 = args.firstIndex(of: "--shuffle") {
                    let at = NSPoint(x: Double(args[k2 + 1]) ?? 0, y: lib.frame.height - (Double(args[k2 + 2]) ?? 0))
                    if let f = args.firstIndex(of: "--filter") {
                        NotificationCenter.default.post(name: .demoQuery, object: args[f + 1])
                        try? await Task.sleep(for: .milliseconds(600))
                    }
                    for round in 1...2 {
                        let screen = lib.convertPoint(toScreen: at)
                        CGWarpMouseCursorPosition(CGPoint(x: screen.x, y: (NSScreen.screens.first?.frame.maxY ?? 0) - screen.y))
                        try? await Task.sleep(for: .milliseconds(250))
                        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                            if let e = NSEvent.mouseEvent(with: type, location: at, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                                          windowNumber: lib.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1) {
                                NSApp.postEvent(e, atStart: false)
                            }
                            try? await Task.sleep(for: .milliseconds(60))
                        }
                        try? await Task.sleep(for: .milliseconds(250))
                        await shot("shuffle-\(round)-spinning")
                        try? await Task.sleep(for: .milliseconds(1600))
                        await shot("shuffle-\(round)-landed")
                    }
                    print("PREVIEW done shuffle"); fflush(stdout)
                    return
                }
                // --similar: Space, Find Similar, then the first match (BL-132).
                if args.contains("--similar") {
                    NotificationCenter.default.post(name: .focusSearch, object: nil); try? await Task.sleep(for: .milliseconds(400)); await key(48, "\t"); await key(49, " ")
                    @MainActor func click(_ at: NSPoint) async {
                        let screen = lib.convertPoint(toScreen: at)
                        CGWarpMouseCursorPosition(CGPoint(x: screen.x, y: (NSScreen.screens.first?.frame.maxY ?? 0) - screen.y))
                        try? await Task.sleep(for: .milliseconds(250))
                        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                            if let e = NSEvent.mouseEvent(with: type, location: at, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                                          windowNumber: lib.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1) {
                                NSApp.postEvent(e, atStart: false)
                            }
                            try? await Task.sleep(for: .milliseconds(90))
                        }
                        try? await Task.sleep(for: .milliseconds(700))
                    }
                    await shot("sim-0-preview")
                    let x = args.firstIndex(of: "--at").map { (Double(args[$0 + 1]) ?? 0, Double(args[$0 + 2]) ?? 0) }
                    if let (bx, by) = x {
                        await click(NSPoint(x: bx, y: lib.frame.height - by))
                        await shot("sim-1-open")
                        if let (tx, ty) = args.firstIndex(of: "--then").map({ (Double(args[$0 + 1]) ?? 0, Double(args[$0 + 2]) ?? 0) }) {
                            await click(NSPoint(x: tx, y: lib.frame.height - ty))
                            await shot("sim-2-walked")
                        }
                    }
                    print("PREVIEW done similar"); fflush(stdout)
                    return
                }
                // --typed-space: type a search with the keys, then (--click-first) click the first
                // result, then Space: the preview must open (BL-127).
                if args.contains("--typed-space") {
                    NotificationCenter.default.post(name: .focusSearch, object: nil)
                    try? await Task.sleep(for: .milliseconds(400))
                    for (c, code) in [("c", UInt16(8)), ("h", 4), ("r", 15), ("o", 31), ("m", 46)] { await key(code, c) }
                    print("TYPED responder=\(lib.firstResponder.map { String(describing: type(of: $0)) } ?? "nil")"); fflush(stdout)
                    if args.contains("--click-first") {
                        let at = NSPoint(x: 100, y: lib.frame.height - 230)
                        let screen = lib.convertPoint(toScreen: at)
                        CGWarpMouseCursorPosition(CGPoint(x: screen.x, y: (NSScreen.screens.first?.frame.maxY ?? 0) - screen.y))
                        try? await Task.sleep(for: .milliseconds(300))
                        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                            if let e = NSEvent.mouseEvent(with: type, location: at, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                                          windowNumber: lib.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1) {
                                NSApp.postEvent(e, atStart: false)
                            }
                            try? await Task.sleep(for: .milliseconds(90))
                        }
                        try? await Task.sleep(for: .milliseconds(400))
                    }
                    if args.contains("--tab") {
                        await key(48, "\t")
                        print("TAB responder=\(lib.firstResponder.map { String(describing: type(of: $0)) } ?? "nil")"); fflush(stdout)
                    }
                    if args.contains("--shift-tab") {
                        for type in [NSEvent.EventType.keyDown, .keyUp] {
                            if let e = NSEvent.keyEvent(with: type, location: .zero, modifierFlags: [.shift], timestamp: 0,
                                                        windowNumber: lib.windowNumber, context: nil, characters: "\u{19}",
                                                        charactersIgnoringModifiers: "\t", isARepeat: false, keyCode: 48) {
                                NSApp.postEvent(e, atStart: false)
                            }
                        }
                        try? await Task.sleep(for: .milliseconds(500))
                        print("SHIFTTAB responder=\(lib.firstResponder.map { String(describing: type(of: $0)) } ?? "nil")"); fflush(stdout)
                        await shot("shift-tab")
                    } else {
                        await key(49, " ")
                        await shot("typed-space")
                    }
                    print("PREVIEW done typed"); fflush(stdout)
                    return
                }
                await key(124, "\u{F703}"); await key(123, "\u{F702}")   // Right, Left
                // --after-preview: open the preview, close it with the pointer over another plugin,
                // then one click there must select it.
                if args.contains("--after-preview") {
                    // --click-through: click a plugin showing beside the open preview instead.
                    let at = args.contains("--click-through") ? NSPoint(x: 45, y: lib.frame.height - 400)
                                                              : NSPoint(x: 490, y: lib.frame.height - 170)
                    await key(49, " ")
                    let screen = lib.convertPoint(toScreen: at)
                    CGWarpMouseCursorPosition(CGPoint(x: screen.x, y: (NSScreen.screens.first?.frame.maxY ?? 0) - screen.y))
                    try? await Task.sleep(for: .milliseconds(400))
                    if !args.contains("--click-through") { await key(49, " ") }
                    for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                        if let e = NSEvent.mouseEvent(with: type, location: at, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                                      windowNumber: lib.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1) {
                            NSApp.postEvent(e, atStart: false)
                        }
                        try? await Task.sleep(for: .milliseconds(90))
                    }
                    try? await Task.sleep(for: .milliseconds(500))
                    await shot("5-after-preview-one-click")
                    print("PREVIEW done"); fflush(stdout)
                    return
                }
                await key(49, " "); await shot("1-open")
                await key(124, "\u{F703}"); await shot("2-next")
                await key(49, " "); await shot("3-closed")
                await key(0, "a"); await shot("4-typed")
                print("PREVIEW done"); fflush(stdout)
            }
        }
        // --selftest-pills <dir>: the pill row and Edit Pills, with nothing saved (BL-110).
        if let k = args.firstIndex(of: "--selftest-pills"), k + 1 < args.count {
            let dir = URL(fileURLWithPath: args[k + 1])
            Task {
                let lib = UserLibrary.shared
                lib.readOnly = true
                let saved = lib.pills
                func say(_ s: String) { print("PILLS " + s); fflush(stdout) }
                LibraryWindow.show()
                try? await Task.sleep(for: .seconds(1.5))
                guard let w = LibraryWindow.window else { say("no window"); return }
                w.setFrame(NSRect(x: 60, y: 60, width: 1320, height: 560), display: true)
                NotificationCenter.default.post(name: .demoQuery, object: "")
                let savedRow = ViewSettings.shared.chipRow
                ViewSettings.shared.chipRow = .both
                try? await Task.sleep(for: .seconds(0.6))
                await capture(w, to: dir.appendingPathComponent("1-default.png"), scale: 1)
                say("cats " + Pills.categoryPills().map(\.title).joined(separator: ", "))
                var p = PillPrefs()
                p.pinned = ["cat:EQ"]
                p.colors = ["cat:Dynamics": "red", "cat:EQ": "blue"]
                p.names = ["cat:Amps and Pedals": "Guitar"]
                p.hidden = ["cat:Metering"]
                p.showCounts = true
                lib.pills = p
                let space = Pills.saveGroup(id: nil, name: "Space", categories: ["Reverb", "Delay"])
                Pills.setColor(space, "purple")
                try? await Task.sleep(for: .seconds(0.6))
                await capture(w, to: dir.appendingPathComponent("2-custom.png"), scale: 1)
                say("custom " + Pills.categoryPills().map(\.title).joined(separator: ", "))
                let m = PickerModel()
                m.pills = ["cat:EQ", space]
                say("filter EQ+Space -> \(m.results.count) plugins: \(Set(m.results.map(\.displayCategory)).sorted())")
                await shoot(CollectionBar(model: m).frame(width: 1100).background(Theme.ground),
                            size: NSSize(width: 1100, height: 60), to: dir.appendingPathComponent("3-multi.png"))
                var q = lib.pills; q.wrap = true; lib.pills = q
                try? await Task.sleep(for: .seconds(0.6))
                await capture(w, to: dir.appendingPathComponent("4-wrap.png"), scale: 1)
                q.wrap = false; q.compact = true; lib.pills = q
                try? await Task.sleep(for: .seconds(0.6))
                await capture(w, to: dir.appendingPathComponent("5-compact.png"), scale: 1)
                await shoot(MorePills(pills: Array(Pills.categoryPills().suffix(8)), model: m) { _ in }.background(Theme.surface),
                            size: NSSize(width: 280, height: 380), to: dir.appendingPathComponent("6-more.png"))
                await shoot(CombinedPillSheet(draft: .init(groupID: nil, name: "Dirt", categories: ["Distortion"])) {},
                            size: NSSize(width: 400, height: 470), to: dir.appendingPathComponent("7-combine.png"))
                PillsWindow.shared.show()
                try? await Task.sleep(for: .seconds(1))
                if let pw = NSApp.windows.first(where: { $0.isVisible && $0.contentView is NSHostingView<PillsEditor> }) {
                    await capture(pw, to: dir.appendingPathComponent("8-editor.png"), scale: 1)
                }
                await shoot(ColorMapPicker(selected: "#4fa3e0") { _ in }, size: NSSize(width: 300, height: 250),
                            to: dir.appendingPathComponent("10-colormap.png"))
                // A real click on the first row's empty color circle must open the colors.
                if let pw = NSApp.windows.first(where: { $0.isVisible && $0.contentView is NSHostingView<PillsEditor> }),
                   let cv = pw.contentView {
                    var dot: NSPoint?
                    if let args2 = args.firstIndex(of: "--dot"), args2 + 2 < args.count,
                       let x = Double(args[args2 + 1]), let y = Double(args[args2 + 2]) { dot = NSPoint(x: x, y: cv.bounds.height - y) }
                    if let at = dot {
                        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                            if let e = NSEvent.mouseEvent(with: type, location: at, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                                          windowNumber: pw.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1) {
                                NSApp.postEvent(e, atStart: false)
                            }
                        }
                        try? await Task.sleep(for: .seconds(0.8))
                        let pops = NSApp.windows.filter { $0.isVisible && String(describing: type(of: $0)).contains("Popover") }
                        say("dot click -> popover open: \(!pops.isEmpty)")
                        if let pop = pops.first { await capture(pop, to: dir.appendingPathComponent("11-popover.png"), scale: 1) }
                        pops.forEach { $0.orderOut(nil) }
                    }
                    // Esc closes the window.
                    if let e = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: pw.windowNumber,
                                                context: nil, characters: "\u{1B}", charactersIgnoringModifiers: "\u{1B}", isARepeat: false, keyCode: 53) {
                        pw.makeKeyAndOrderFront(nil)
                        NSApp.postEvent(e, atStart: false)
                    }
                    try? await Task.sleep(for: .seconds(0.6))
                    say("esc -> window still open: \(pw.isVisible)")
                }
                let mp = PickerModel()
                mp.picked = Set(mp.results.prefix(3).map(\.id))
                await shoot(PickedBar(model: mp).frame(width: 900, height: 80).background(Theme.ground),
                            size: NSSize(width: 900, height: 80), to: dir.appendingPathComponent("9-picked.png"))
                // Inside a collection: Remove from it (nothing saved, the library is read only here).
                if let c = lib.collections.first(where: { $0.pluginIDs.count >= 2 }) {
                    let mc = PickerModel()
                    mc.collectionID = c.id
                    mc.picked = Set(mc.results.prefix(2).map(\.id))
                    await shoot(PickedBar(model: mc).frame(width: 900, height: 80).background(Theme.ground),
                                size: NSSize(width: 900, height: 80), to: dir.appendingPathComponent("12-in-collection.png"))
                    let before = c.pluginIDs.count
                    let savedCols = lib.collections
                    PickedActions.removeFromCollection(mc)
                    say("remove from \(c.name): \(before) -> \(lib.collections.first { $0.id == c.id }?.pluginIDs.count ?? -1)")
                    lib.collections = savedCols
                }
                // Most used order (BL-115).
                var u = PillPrefs(); u.sort = .used; lib.pills = u
                say("most used: " + Pills.categoryPills().prefix(5).map { "\($0.title)=\($0.uses)" }.joined(separator: ", "))
                lib.pills = saved
                try? await Task.sleep(for: .seconds(0.5))
                await capture(w, to: dir.appendingPathComponent("13-collections-outlined.png"), scale: 1)
                // The themed dialogs (BL-116), drawn without opening a live window.
                let st = Dialog.State(); st.text = "Dynamics"
                await shoot(DialogCard(title: "Name for the Dynamics pill", message: nil, field: ("Dynamics", "Dynamics"), multiline: false,
                                       checkbox: nil, choices: [.init(title: "Cancel", cancel: true), .init(title: "OK", primary: true)],
                                       state: st) { _ in }, size: NSSize(width: 400, height: 190), to: dir.appendingPathComponent("14-dialog-name.png"))
                await shoot(DialogCard(title: "Move Tape Delay to Delay for everyone, or only on this Mac?",
                                       message: "Everyone: other AG PlugFinder users will see it in Delay too, once other users agree. Only the plugin names and the category are sent.\n\nOnly This Mac: the change stays with you.",
                                       field: nil, multiline: false, checkbox: "Always choose Everyone without asking",
                                       choices: [.init(title: "Cancel", cancel: true), .init(title: "Only This Mac"), .init(title: "Everyone", primary: true)],
                                       state: Dialog.State()) { _ in }, size: NSSize(width: 400, height: 280), to: dir.appendingPathComponent("15-dialog-question.png"))
                await shoot(DialogCard(title: "Remove every effect from Lead Vocal?", message: "4 effects come off the track. You can undo it in Logic with Edit > Undo.",
                                       field: nil, multiline: false, checkbox: nil,
                                       choices: [.init(title: "Cancel", cancel: true), .init(title: "Remove", primary: true, destructive: true)],
                                       state: Dialog.State()) { _ in }, size: NSSize(width: 400, height: 160), to: dir.appendingPathComponent("16-dialog-destructive.png"))
                lib.pills = saved
                ViewSettings.shared.chipRow = savedRow
                say("done")
            }
        }
        // --selftest-dynamics: how every dynamics plugin is sorted (BL-121).
        if args.contains("--selftest-dynamics") {
            for c in ["Compressor", "Limiter", "Dynamics"] {
                let names = PluginStore.shared.plugins.filter { $0.displayCategory == c }.map(\.name).sorted()
                print("DYN \(c) (\(names.count)): \(names.joined(separator: ", "))")
            }
            fflush(stdout)
        }
        func findScroll(_ v: NSView?) -> NSScrollView? {
            guard let v else { return nil }
            if let s = v as? NSScrollView, s.documentView?.frame.height ?? 0 > 2000 { return s }
            for sub in v.subviews { if let s = findScroll(sub) { return s } }
            return nil
        }
        // --selftest-perf: where the time goes with many plugins (BL-123). Changes nothing.
        if args.contains("--selftest-perf") {
            Task {
                func ms(_ t: Date) -> String { String(format: "%.1f ms", Date().timeIntervalSince(t) * 1000) }
                let store = PluginStore.shared
                // --many N: copies of this Mac's plugins in memory, up to N, nothing saved.
                if let k = args.firstIndex(of: "--many"), k + 1 < args.count, let n = Int(args[k + 1]) {
                    UserLibrary.shared.readOnly = true
                    let real = store.plugins
                    var list: [Plugin] = []
                    var i = 0
                    while list.count < n {
                        for var p in real where list.count < n {
                            if i > 0 { p.id += "-\(i)"; p.name += " \(i)" }
                            list.append(p)
                        }
                        i += 1
                    }
                    store.debugUsePlugins(list)
                }
                print("PERF plugins \(store.plugins.count)")
                var t = Date(); let m = PickerModel(); _ = m.results; print("PERF results (no search) \(ms(t))")
                t = Date(); m.query = "comp"; _ = m.results; print("PERF results 'comp' \(ms(t))")
                t = Date(); m.query = "warm tape"; _ = m.results; print("PERF results 'warm tape' \(ms(t))")
                m.query = ""
                t = Date(); for p in store.plugins { _ = p.displayCategory }; print("PERF displayCategory x all \(ms(t))")
                t = Date(); for p in store.plugins { _ = store.isVisible(p) }; print("PERF isVisible x all \(ms(t))")
                t = Date(); _ = Pills.categoryPills(); print("PERF category pills \(ms(t))")
                // A picture as the grid loads it.
                if let p = store.plugins.first(where: { store.image(for: $0.id) != nil && !$0.isLogic }) ?? store.plugins.first {
                    let url = store.snapshotURL(for: p.id)
                    let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
                    t = Date(); let img = NSImage(contentsOf: url); _ = img?.cgImage(forProposedRect: nil, context: nil, hints: nil)
                    print("PERF one picture load+decode \(ms(t)) (\(size / 1024) KB, \(Int(img?.size.width ?? 0))x\(Int(img?.size.height ?? 0)))")
                }
                // How often the list is rebuilt when one plugin is selected in the window.
                LibraryWindow.show()
                try? await Task.sleep(for: .seconds(1.5))
                PickerModel.resultsCount = 0
                NotificationCenter.default.post(name: .demoSelect, object: store.plugins.dropFirst(5).first?.name ?? "")
                try? await Task.sleep(for: .seconds(1))
                print("PERF list rebuilt \(PickerModel.resultsCount) times for one selection")
                // Scrolling the grid: how often the list is rebuilt, and how long each step takes.
                if let w = LibraryWindow.window, let scroll = findScroll(w.contentView) {
                    PickerModel.resultsCount = 0
                    var worst = 0.0, total = 0.0
                    for step in 1...40 {
                        let t0 = Date()
                        scroll.contentView.scroll(to: NSPoint(x: 0, y: CGFloat(step) * 120))
                        scroll.reflectScrolledClipView(scroll.contentView)
                        RunLoop.current.run(until: Date().addingTimeInterval(0.02))
                        let d = Date().timeIntervalSince(t0) * 1000 - 20
                        worst = max(worst, d); total += d
                    }
                    print(String(format: "PERF scroll 40 steps: list rebuilt %d times, average %.1f ms, worst %.1f ms per step",
                                 PickerModel.resultsCount, total / 40, worst))
                }
                // Typing a search, one letter at a time.
                t = Date()
                for q in ["c", "co", "com", "comp"] {
                    NotificationCenter.default.post(name: .demoQuery, object: q)
                    RunLoop.current.run(until: Date().addingTimeInterval(0.01))
                }
                print("PERF typing 4 letters \(ms(t)) (with 40 ms of waiting)")
                NotificationCenter.default.post(name: .demoQuery, object: "")
                print("PERF done"); fflush(stdout)
            }
        }
        // --selftest-monostereo <dir>: mono and stereo versions shown as one (BL-124). In memory only.
        if let k = args.firstIndex(of: "--selftest-monostereo"), k + 1 < args.count {
            let dir = URL(fileURLWithPath: args[k + 1])
            Task {
                let store = PluginStore.shared
                UserLibrary.shared.readOnly = true
                guard let base = store.plugins.first(where: { !$0.isLogic }) ?? store.plugins.first else { return }
                func fake(_ name: String, _ maker: String, _ id: String) -> Plugin {
                    var p = base; p.name = name; p.manufacturer = maker; p.id = id; p.userCategory = "EQ"; return p
                }
                let fakes = [fake("API-550A (m)", "Waves", "t-550m"), fake("API-550A (s)", "Waves", "t-550s"),
                             fake("API-550A (m->s)", "Waves", "t-550ms"), fake("SSL Fusion Stereo Image", "SSL", "t-ssl"),
                             fake("bx_dynEQ V2 Mono", "Plugin Alliance", "t-bxm"), fake("bx_dynEQ V2 Stereo", "Plugin Alliance", "t-bxs")]
                if !args.contains("--nofakes") { store.debugUsePlugins(store.plugins + fakes) }
                func say(_ s: String) { print("MS " + s); fflush(stdout) }
                let m = PickerModel(); m.query = "550"
                say("joined on, search 550: " + m.results.map { "\($0.name) as \(PluginVariants.title($0))" }.joined(separator: ", "))
                m.query = "ssl fusion"; say("stereo image: " + m.results.map(\.name).joined(separator: ", "))
                m.query = "dyneq"; say("bx: " + m.results.map { "\($0.name) as \(PluginVariants.title($0))" }.joined(separator: ", "))
                let s = fakes[1], mono = fakes[0]
                say("mono track formats [Mono, Mono→Stereo] on (s) → \(PluginVariants.better(for: s, formats: ["Mono", "Mono→Stereo"])?.name ?? "keep")")
                say("mono track formats [Mono→Stereo] on (s) → \(PluginVariants.better(for: s, formats: ["Mono→Stereo"])?.name ?? "keep")")
                say("stereo track formats [Stereo, Dual Mono] on (s) → \(PluginVariants.better(for: s, formats: ["Stereo", "Dual Mono"])?.name ?? "keep")")
                say("stereo track formats [Dual Mono] on (m) → \(PluginVariants.better(for: mono, formats: ["Dual Mono"])?.name ?? "keep")")
                if !args.contains("--notoggle") {
                    ViewSettings.shared.joinMonoStereo = false
                    m.query = "550"; say("joined off, search 550: " + m.results.map(\.name).joined(separator: ", "))
                    ViewSettings.shared.joinMonoStereo = !args.contains("--off")
                }
                if args.contains("--wait") { try? await Task.sleep(for: .seconds(1)) }
                LibraryWindow.show()
                try? await Task.sleep(for: .seconds(1.5))
                if let w = LibraryWindow.window {
                    w.setFrame(NSRect(x: 60, y: 60, width: 1320, height: 700), display: true)
                    let q = args.firstIndex(of: "--q").map { args[$0 + 1] } ?? "550"
                    NotificationCenter.default.post(name: .demoQuery, object: q)
                    if !args.contains("--noselect") { NotificationCenter.default.post(name: .demoSelect, object: "API-550A (s)") }
                    try? await Task.sleep(for: .seconds(1))
                    if !args.contains("--nocap") { await capture(w, to: dir.appendingPathComponent("monostereo.png"), scale: 1) }
                    // Resize across many widths and heights: the window must never get stuck re-laying out.
                    for width in stride(from: 860, through: 1500, by: 40) {
                        for height in [560, 700, 900] {
                            w.setFrame(NSRect(x: 60, y: 60, width: width, height: height), display: true)
                            try? await Task.sleep(for: .milliseconds(30))
                        }
                    }
                    say("resized 51 times, wrap \(UserLibrary.shared.pills.wrap)")
                    NotificationCenter.default.post(name: .demoQuery, object: "")
                }
                say("done")
            }
        }
        if let k = args.firstIndex(of: "--selftest-menu-actions"), k + 1 < args.count {
            let dir = URL(fileURLWithPath: args[k + 1])
            Task { await menuActions(dir) }
        }
        if let k = args.firstIndex(of: "--selftest-menu-of"), k + 1 < args.count, let pid = pid_t(args[k + 1]),
           pid != getpid() {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { menuTest(of: pid) }
        }
        if let k = args.firstIndex(of: "--selftest-onboarding-sync"), k + 1 < args.count {
            let out = URL(fileURLWithPath: args[k + 1])
            Task {
                await shoot(OnboardingView(start: .sync), size: NSSize(width: 640, height: 500), to: out)
                print("ONBOARDSYNC ok"); fflush(stdout)
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

    static func capture(_ window: NSWindow, to url: URL, scale: Int = 2) async {
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
