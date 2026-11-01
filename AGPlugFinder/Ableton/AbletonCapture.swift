#if DEBUG
import AppKit
import ScreenCaptureKit

/// Development tool only (BL-164): photographs each of Live's devices once, for the pictures the
/// app ships with. Each device goes alone onto a spare track; Live's window is photographed
/// before and after, and the part that changed is the device. The spare track is deleted at
/// the end. Never part of a release build.
@MainActor
enum AbletonCapture {
    static func run(to folder: URL, only: String? = nil) async {
        func say(_ s: String) { print("APIC " + s); fflush(stdout) }
        let bridge = AbletonBridge.shared
        guard await bridge.isConnected() else { say("Live is not connected"); return }
        guard CGPreflightScreenCaptureAccess() else { _ = CGRequestScreenCaptureAccess(); say("needs Screen Recording"); return }
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        _ = await bridge.send(["cmd": "pics_begin"], timeout: 5)
        try? await Task.sleep(for: .seconds(1))
        var done = 0, failed: [String] = []
        for p in AbletonCatalog.scan() where only == nil || p.name == only {
            _ = await bridge.send(["cmd": "pics_load", "name": ""], timeout: 5)
            try? await Task.sleep(for: .milliseconds(700))
            guard let before = await liveWindow() else { say("no Live window"); break }
            let reply = await bridge.send(["cmd": "pics_load", "name": p.name, "kind": "device"], timeout: 10)
            guard reply?["ok"] as? Bool == true else { failed.append(p.name); say("not loaded: \(p.name)"); continue }
            try? await Task.sleep(for: .milliseconds(1500))
            guard let after = await liveWindow(), let box = changed(before, after) else { failed.append(p.name); say("no change: \(p.name)"); continue }
            guard let raw = after.cropping(to: box), let crop = trimmed(raw), save(crop, to: folder.appendingPathComponent(p.id + ".jpg")) else {
                failed.append(p.name); continue
            }
            done += 1
            say("ok \(p.name) \(Int(box.width))x\(Int(box.height))")
        }
        _ = await bridge.send(["cmd": "pics_end"], timeout: 5)
        say("done \(done), failed \(failed.count): \(failed.joined(separator: ", "))")
    }

    /// Live's main window, photographed.
    private static func liveWindow() async -> CGImage? {
        guard let content = try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true),
              let w = content.windows.filter({ $0.owningApplication?.bundleIdentifier.hasPrefix(Host.abletonPrefix) == true })
                .max(by: { $0.frame.width * $0.frame.height < $1.frame.width * $1.frame.height }) else { return nil }
        let config = SCStreamConfiguration()
        let scale = Int(NSScreen.main?.backingScaleFactor ?? 2)
        config.width = Int(w.frame.width) * scale
        config.height = Int(w.frame.height) * scale
        config.showsCursor = false
        return try? await SCScreenshotManager.captureImage(contentFilter: SCContentFilter(desktopIndependentWindow: w), configuration: config)
    }

    /// The device: the largest block that changed between two pictures of Live's window, in the
    /// lower half. Small changes elsewhere (a record button, the status line) are left out.
    private static func changed(_ a: CGImage, _ b: CGImage) -> CGRect? {
        guard a.width == b.width, a.height == b.height, let pa = pixels(a), let pb = pixels(b) else { return nil }
        let w = a.width, h = a.height, cell = 8
        let cols = w / cell, rows = h / cell
        var hot = [Bool](repeating: false, count: cols * rows)
        // Live's status line at the very bottom changes too; it is left out.
        let statusRows = Int(ceil(80.0 / Double(cell)))
        for r in (rows / 2)..<max(rows / 2, rows - statusRows) {
            for c in 0..<cols {
                var count = 0
                for dy in stride(from: 0, to: cell, by: 2) {
                    for dx in stride(from: 0, to: cell, by: 2) {
                        let i = ((r * cell + dy) * w + (c * cell + dx)) * 4
                        let d = abs(Int(pa[i]) - Int(pb[i])) + abs(Int(pa[i + 1]) - Int(pb[i + 1])) + abs(Int(pa[i + 2]) - Int(pb[i + 2]))
                        if d > 30 { count += 1 }
                    }
                }
                hot[r * cols + c] = count > 0
            }
        }
        // Groups of touching changed cells; gaps of one cell are bridged, so a device with plain
        // areas inside stays one block.
        var seen = [Bool](repeating: false, count: hot.count)
        var best: (Int, Int, Int, Int, Int)?     // cells, minC, minR, maxC, maxR
        for start in hot.indices where hot[start] && !seen[start] {
            var stack = [start]; seen[start] = true
            var n = 0, minC = cols, minR = rows, maxC = 0, maxR = 0
            while let i = stack.popLast() {
                n += 1
                let r = i / cols, c = i % cols
                minC = min(minC, c); maxC = max(maxC, c); minR = min(minR, r); maxR = max(maxR, r)
                for dr in -2...2 { for dc in -2...2 {
                    let rr = r + dr, cc = c + dc
                    guard rr >= 0, rr < rows, cc >= 0, cc < cols else { continue }
                    let j = rr * cols + cc
                    if hot[j] && !seen[j] { seen[j] = true; stack.append(j) }
                } }
            }
            let area = (maxC - minC + 1) * (maxR - minR + 1)
            if best == nil || area > (best!.3 - best!.1 + 1) * (best!.4 - best!.2 + 1) { best = (n, minC, minR, maxC, maxR) }
        }
        guard let b = best, b.3 - b.1 > 6, b.4 - b.2 > 6 else { return nil }
        let m = 4
        let x0 = max(0, b.1 * cell - m), y0 = max(0, b.2 * cell - m)
        let x1 = min(w, (b.3 + 1) * cell + m), y1 = min(h, (b.4 + 1) * cell + m)
        return CGRect(x: x0, y: y0, width: x1 - x0, height: y1 - y0)
    }

    /// Plain grey on the sides (where Live's "Drop … Here" text was) is cut away.
    private static func trimmed(_ img: CGImage) -> CGImage? {
        guard let px = pixels(img) else { return img }
        let w = img.width, h = img.height
        func plain(_ x: Int) -> Bool {
            var lo = 255, hi = 0
            for y in stride(from: h / 8, to: h - h / 8, by: 3) {
                let i = (y * w + x) * 4
                let v = (Int(px[i]) + Int(px[i + 1]) + Int(px[i + 2])) / 3
                lo = min(lo, v); hi = max(hi, v)
            }
            return hi - lo < 10
        }
        var right = w - 1
        while right > w / 4, plain(right) { right -= 1 }
        var left = 0
        while left < right - w / 4, plain(left) { left += 1 }
        let m = 6
        let x0 = max(0, left - m), x1 = min(w, right + 1 + m)
        return img.cropping(to: CGRect(x: x0, y: 0, width: x1 - x0, height: h)) ?? img
    }

    private static func pixels(_ img: CGImage) -> [UInt8]? {
        var buf = [UInt8](repeating: 0, count: img.width * img.height * 4)
        guard let ctx = CGContext(data: &buf, width: img.width, height: img.height, bitsPerComponent: 8, bytesPerRow: img.width * 4,
                                  space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.draw(img, in: CGRect(x: 0, y: 0, width: img.width, height: img.height))
        return buf
    }

    private static func save(_ image: CGImage, to url: URL) -> Bool {
        let scale = min(1.0, 720.0 / Double(image.width))
        let w = max(1, Int(Double(image.width) * scale)), h = max(1, Int(Double(image.height) * scale))
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
        ctx.interpolationQuality = .high
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        guard let scaled = ctx.makeImage(),
              let data = NSBitmapImageRep(cgImage: scaled).representation(using: .jpeg, properties: [.compressionFactor: 0.85]) else { return false }
        return (try? data.write(to: url, options: .atomic)) != nil
    }
}
#endif
