import AppKit
import AVFoundation
import CoreAudioKit
import ScreenCaptureKit

/// Runs inside a short-lived helper process (`--render`), so a plugin that crashes or hangs
/// can never take the main app down. Loads one Audio Unit, opens its window, captures it, exits.
///
/// Arguments: --render <type> <subtype> <manufacturer> <isV3 0|1> <output.png>
/// Prints one JSON line to stdout: {"status":"ok"|"noUI"|"failed","params":N,"error":"..."}
enum SnapshotRenderer {
    static func run(_ args: [String]) -> Never {
        guard args.count >= 6,
              let type = UInt32(args[1]), let sub = UInt32(args[2]), let manu = UInt32(args[3])
        else {
            report(["status": "failed", "error": "bad arguments"])
            exit(2)
        }
        let isV3 = args[4] == "1"
        let output = URL(fileURLWithPath: args[5])

        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        dismissPluginAlerts()
        #if DEBUG
        if args.contains("--test-alert") {
            DispatchQueue.main.async {
                let a = NSAlert()
                a.messageText = "Too many parameters in process"
                a.runModal()
            }
        }
        #endif
        Task { @MainActor in
            var result = await render(type: type, sub: sub, manu: manu, isV3: isV3, output: output)
            if let said = alertText, result["status"] as? String == "failed" {
                result["error"] = "the plugin said: \(said)"
            }
            report(result)
            exit(result["status"] as? String == "failed" ? 1 : 0)
        }
        app.run()
        exit(0)
    }

    /// What a plugin showed in a popup of its own, if it did.
    @MainActor private static var alertText: String?

    /// Some plugins put up their own popup while loading ("Too many parameters in process").
    /// In this helper nobody is there to answer it, so it is closed at once and its text kept
    /// for the report. The plugin then goes on loading, or fails and is not tried again.
    private static func dismissPluginAlerts() {
        let timer = Timer(timeInterval: 0.25, repeats: true) { _ in
            MainActor.assumeIsolated {
                guard let w = NSApp.modalWindow ?? NSApp.windows.first(where: { $0.isVisible && $0.level == .modalPanel })
                else { return }
                let texts = (w.contentView.map(allText) ?? []).filter { !$0.isEmpty && $0 != "OK" }
                alertText = texts.joined(separator: " ")
                if NSApp.modalWindow != nil { NSApp.stopModal() }
                w.orderOut(nil)
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        RunLoop.main.add(timer, forMode: .modalPanel)
    }

    @MainActor private static func allText(_ v: NSView) -> [String] {
        var out: [String] = []
        if let t = v as? NSTextField { out.append(t.stringValue) }
        for sub in v.subviews { out += allText(sub) }
        return out
    }

    private static func report(_ dict: [String: Any]) {
        if let data = try? JSONSerialization.data(withJSONObject: dict),
           let line = String(data: data, encoding: .utf8) {
            print(line)
            fflush(stdout)
        }
    }

    @MainActor
    private static func render(type: UInt32, sub: UInt32, manu: UInt32, isV3: Bool,
                               output: URL) async -> [String: Any] {
        let desc = AudioComponentDescription(componentType: type, componentSubType: sub,
                                             componentManufacturer: manu, componentFlags: 0,
                                             componentFlagsMask: 0)
        let unit: AVAudioUnit
        do {
            unit = try await AVAudioUnit.instantiate(with: desc,
                                                     options: isV3 ? .loadOutOfProcess : [])
        } catch {
            return ["status": "failed", "error": "could not load: \(error.localizedDescription)"]
        }
        let params = unit.auAudioUnit.parameterTree?.allParameters.count ?? 0

        let controller: NSViewController? = await withCheckedContinuation { cont in
            unit.auAudioUnit.requestViewController { cont.resume(returning: $0) }
        }
        // No custom window: show the plugin's controls the way Logic does (generic view).
        let hasCustomView = controller != nil
        guard let controller = controller ?? genericController(unit.auAudioUnit, params: params) else {
            return ["status": "noUI", "params": params]
        }

        let size = bestSize(controller)

        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentViewController = controller
        window.setContentSize(size)
        window.isReleasedWhenClosed = false
        // Bottom-left corner of the main screen, behind other windows.
        if let screen = NSScreen.main {
            window.setFrameOrigin(NSPoint(x: screen.visibleFrame.minX, y: screen.visibleFrame.minY))
        }
        window.orderBack(nil)

        // Give the plugin time to draw (many build their UI asynchronously), and follow it
        // if it asks for a different size once it has loaded.
        try? await Task.sleep(for: .milliseconds(1800))
        let later = bestSize(controller)
        if abs(later.width - size.width) > 4 || abs(later.height - size.height) > 4 {
            window.setContentSize(later)
            try? await Task.sleep(for: .milliseconds(600))
        }

        var image: CGImage? = await captureWithScreenCaptureKit(window: window)
        if image == nil || isBlank(image!) {
            image = captureFromView(controller.view) ?? image
        }
        window.orderOut(nil)

        guard let image, !isBlank(image) else {
            return ["status": "failed", "params": params, "error": "plugin window came out blank"]
        }
        guard writeThumbnail(image, to: output) else {
            return ["status": "failed", "params": params, "error": "could not save the screenshot"]
        }
        return ["status": hasCustomView ? "ok" : "generic", "params": params]
    }

    @MainActor
    private static func genericController(_ au: AUAudioUnit, params: Int) -> NSViewController? {
        guard params > 0 else { return nil }
        let vc = AUGenericViewController()
        vc.auAudioUnit = au
        vc.view.frame = NSRect(x: 0, y: 0, width: 560, height: min(80 + params * 34, 700))
        return vc
    }

    /// The largest sensible size the plugin reports for its view.
    @MainActor
    private static func bestSize(_ controller: NSViewController) -> NSSize {
        let candidates = [controller.preferredContentSize, controller.view.frame.size,
                          controller.view.fittingSize]
            .filter { $0.width >= 50 && $0.height >= 50 }
        var size = candidates.max { $0.width * $0.height < $1.width * $1.height }
            ?? NSSize(width: 640, height: 400)
        size.width = min(size.width, 1600)
        size.height = min(size.height, 1100)
        return size
    }

    /// Captures only our own window (needs no Screen Recording permission on macOS 14.4+).
    @MainActor
    private static func captureWithScreenCaptureKit(window: NSWindow) async -> CGImage? {
        do {
            let content = try await SCShareableContent.currentProcess
            guard let scWindow = content.windows.first(where: {
                $0.windowID == CGWindowID(window.windowNumber)
            }) else { return nil }
            let filter = SCContentFilter(desktopIndependentWindow: scWindow)
            let config = SCStreamConfiguration()
            let scale = Int(window.backingScaleFactor)
            config.width = Int(scWindow.frame.width) * scale
            config.height = Int(scWindow.frame.height) * scale
            config.showsCursor = false
            config.captureResolution = .best
            return try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
        } catch {
            return nil
        }
    }

    @MainActor
    private static func captureFromView(_ view: NSView) -> CGImage? {
        guard view.bounds.width > 0, view.bounds.height > 0,
              let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return nil }
        view.cacheDisplay(in: view.bounds, to: rep)
        return rep.cgImage
    }

    /// True when nearly every sampled pixel has the same colour.
    private static func isBlank(_ image: CGImage) -> Bool {
        let w = 32, h = 32
        var pixels = [UInt8](repeating: 0, count: w * h * 4)
        guard let ctx = CGContext(data: &pixels, width: w, height: h, bitsPerComponent: 8,
                                  bytesPerRow: w * 4, space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return false }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        let r0 = Int(pixels[0]), g0 = Int(pixels[1]), b0 = Int(pixels[2])
        var different = 0
        for i in stride(from: 0, to: pixels.count, by: 4) {
            let d = abs(Int(pixels[i]) - r0) + abs(Int(pixels[i + 1]) - g0) + abs(Int(pixels[i + 2]) - b0)
            if d > 24 { different += 1 }
        }
        return different < (w * h) / 50
    }

    /// Saves a PNG at most 720 px wide.
    private static func writeThumbnail(_ image: CGImage, to url: URL) -> Bool {
        let maxW = 720.0
        let scale = min(1.0, maxW / Double(image.width))
        let w = Int(Double(image.width) * scale), h = Int(Double(image.height) * scale)
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return false }
        ctx.interpolationQuality = .high
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        guard let scaled = ctx.makeImage() else { return false }
        let rep = NSBitmapImageRep(cgImage: scaled)
        guard let data = rep.representation(using: .png, properties: [:]) else { return false }
        return (try? data.write(to: url, options: .atomic)) != nil
    }
}
