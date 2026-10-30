#if DEBUG
import AppKit
import ScreenCaptureKit

/// Debug-only: `--selftest <folder> [query]` opens the picker and saves pictures of it,
/// so the layout can be checked without a person at the keyboard.
@MainActor
enum SelfTest {
    static func runIfRequested() {
        let args = CommandLine.arguments
        // --dump-logic: save Logic's interface tree.  --test-insert <name>: insert like Return does.
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
            try? await Task.sleep(for: .milliseconds(800))
            await capture(to: folder.appendingPathComponent("picker.png"))
            controller.model.query = query
            controller.model.move(1)
            try? await Task.sleep(for: .milliseconds(600))
            await capture(to: folder.appendingPathComponent("picker-search.png"))
            for sort in PluginSort.allCases {
                controller.model.query = ""
                controller.model.sort = sort
                let names = controller.model.results.prefix(6).map(\.name).joined(separator: ", ")
                print("SORT \(sort.rawValue): \(names)")
            }
            controller.model.sort = .name
            print("SELFTEST DONE")
            fflush(stdout)
        }
    }

    private static func capture(to url: URL) async {
        guard let window = NSApp.windows.first(where: { $0 is PickerPanel && $0.isVisible }),
              let content = try? await SCShareableContent.currentProcess,
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
