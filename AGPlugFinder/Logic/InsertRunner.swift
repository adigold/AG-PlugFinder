import AppKit
import SwiftUI

/// Inserts a pinned plugin or a whole chain without opening the window (BL-25, BL-26), and
/// tells the user how it went in a small notice at the bottom of the screen.
@MainActor
enum InsertRunner {
    private static var running = false

    static func run(_ target: UserLibrary.PinTarget) {
        switch target {
        case .plugin(let id):
            guard let p = PluginStore.shared.plugin(id) else { Toast.show("That pinned plugin is no longer installed."); return }
            run([p], title: p.name)
        case .chain(let id):
            guard let chain = UserLibrary.shared.chains.first(where: { $0.id == id }) else { return }
            run(UserLibrary.shared.plugins(in: chain), title: chain.name)
        }
    }

    /// Inserts the plugins one after another. An instrument goes into the instrument slot only
    /// when it is empty; a filled one is never replaced from here.
    static func run(_ plugins: [Plugin], title: String) {
        guard !running, !plugins.isEmpty else { return }
        running = true
        Toast.show(plugins.count > 1 ? "Adding \(title) (\(plugins.count) plugins)…" : "Adding \(title)…", busy: true)
        Task {
            var added = 0
            var problem: String?
            for p in plugins {
                let outcome = await LogicInserter.shared.insert(p, replacing: nil)
                switch outcome {
                case .inserted:
                    added += 1
                    PluginStore.shared.markUsed(p.id)
                    LogicTrack.shared.lastAdded = p.name
                    try? await Task.sleep(for: .milliseconds(500))
                case .allFull:
                    problem = p.slotKind == .instrument
                        ? "\(p.name) skipped: the track already has an instrument."
                        : "\(p.name) skipped: every insert is full."
                case .needsAccessibility:
                    problem = "AG PlugFinder needs Accessibility access to place plugins in Logic."
                case .logicNotRunning:
                    problem = "Logic Pro isn't open."
                case .noChannelStrip(let t), .failed(let t):
                    problem = t
                }
                if case .needsAccessibility = outcome { break }
                if case .logicNotRunning = outcome { break }
            }
            running = false
            TrackState.shared.refreshSoon()
            if let problem, added == 0 { Toast.show(problem, warning: true) }
            else if let problem { Toast.show("Added \(added) of \(plugins.count). \(problem)", warning: true) }
            else { Toast.show(plugins.count > 1 ? "Added \(title): \(added) plugins" : "Added \(title)") }
        }
    }
}

/// A small floating notice near the bottom of the screen that never takes focus.
@MainActor
enum Toast {
    private static var panel: NSPanel?
    private static var hideWork: DispatchWorkItem?

    static func show(_ text: String, busy: Bool = false, warning: Bool = false) {
        let view = ToastView(text: text, busy: busy, warning: warning)
        let host = NSHostingView(rootView: view)
        let size = host.fittingSize
        let p = panel ?? {
            let p = NSPanel(contentRect: .zero, styleMask: [.nonactivatingPanel, .borderless],
                            backing: .buffered, defer: false)
            p.level = .statusBar
            p.isOpaque = false
            p.backgroundColor = .clear
            p.hasShadow = true
            p.ignoresMouseEvents = true
            p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            panel = p
            return p
        }()
        p.contentView = host
        if let screen = NSScreen.main?.visibleFrame {
            p.setFrame(NSRect(x: screen.midX - size.width / 2, y: screen.minY + 80, width: size.width, height: size.height),
                       display: true)
        }
        p.orderFrontRegardless()
        hideWork?.cancel()
        guard !busy else { return }
        let work = DispatchWorkItem { panel?.orderOut(nil) }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + (warning ? 4 : 2.2), execute: work)
    }
}

private struct ToastView: View {
    let text: String
    let busy: Bool
    let warning: Bool

    var body: some View {
        HStack(spacing: 10) {
            if busy { ProgressView().controlSize(.small) }
            else {
                Image(systemName: warning ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                    .foregroundStyle(warning ? Theme.warning : Theme.accent)
            }
            Text(text).font(.system(size: Theme.ts(13), weight: .medium)).foregroundStyle(Theme.text)
                .lineLimit(2).frame(maxWidth: 420, alignment: .leading)
        }
        .padding(.horizontal, 18).padding(.vertical, 12)
        .background(Capsule().fill(Theme.raised))
        .environment(\.colorScheme, .dark)
    }
}
