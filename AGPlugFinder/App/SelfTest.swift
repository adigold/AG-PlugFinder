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

    private static func capture(_ window: NSWindow, to url: URL) async {
        guard let content = try? await SCShareableContent.currentProcess,
              let sc = content.windows.first(where: { $0.windowID == CGWindowID(window.windowNumber) })
        else { print("SELFTEST no window"); return }
        let config = SCStreamConfiguration()
        config.width = Int(sc.frame.width) * 2
        config.height = Int(sc.frame.height) * 2
        guard let img = try? await SCScreenshotManager.captureImage(
            contentFilter: SCContentFilter(desktopIndependentWindow: sc), configuration: config),
              let data = NSBitmapImageRep(cgImage: img).representation(using: .png, properties: [:])
        else { print("SELFTEST capture failed"); return }
        try? data.write(to: url)
    }
}
#endif
