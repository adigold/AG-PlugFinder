import AppKit
import SwiftUI

/// The "Taking screenshots" window. Opens by itself when a capture run starts; it can be
/// hidden while the run continues, and reopened from the status line in the library window.
@MainActor
final class SnapshotProgressWindow {
    static let shared = SnapshotProgressWindow()

    private lazy var window: NSWindow = {
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 560),
                         styleMask: [.titled, .closable, .miniaturizable, .resizable],
                         backing: .buffered, defer: false)
        w.title = "Plugin Screenshots"
        w.isReleasedWhenClosed = false
        w.backgroundColor = Theme.nsGround
        w.appearance = Theme.nsAppearance
        w.minSize = NSSize(width: 520, height: 420)
        w.contentView = NSHostingView(rootView: SnapshotProgressView())
        w.center()
        return w
    }()

    func show() {
        window.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }

    func hide() { window.orderOut(nil) }
}

struct SnapshotProgressView: View {
    var queue = SnapshotQueue.shared
    var store = PluginStore.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            HStack(alignment: .top, spacing: 14) {
                currentCard
                counts
            }
            list
            footer
        }
        .padding(22)
        .frame(minWidth: 520, minHeight: 420)
        .background(Theme.ground)
        .preferredColorScheme(Theme.scheme)
    }

    // MARK: Header: big bar, numbers, time

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text(title).font(.system(size: Theme.ts(18), weight: .bold))
                Spacer()
                Text("\(queue.done) of \(queue.total)")
                    .font(.system(size: Theme.ts(15), weight: .semibold)).monospacedDigit()
            }
            ProgressView(value: Double(queue.done), total: Double(max(1, queue.total)))
                .progressViewStyle(.linear)
                .tint(Theme.accent)
                .controlSize(.large)
            HStack {
                Text("\(percent)%").monospacedDigit()
                Spacer()
                Text(timeText).monospacedDigit()
            }
            .font(.system(size: Theme.ts(12))).foregroundStyle(Theme.faint)
        }
    }

    private var title: String {
        if queue.isRunning { return "Taking plugin screenshots" }
        if queue.cancelledRun { return "Stopped" }
        return queue.total == 0 ? "No screenshots to take" : "Screenshots finished"
    }

    private var percent: Int {
        queue.total == 0 ? 0 : Int((Double(queue.done) / Double(queue.total) * 100).rounded())
    }

    private var timeText: String {
        guard let start = queue.startedAt else { return "" }
        let elapsed = (queue.finishedAt ?? Date()).timeIntervalSince(start)
        var text = "Elapsed \(format(elapsed))"
        if let left = queue.secondsLeft { text += " · About \(format(left)) left" }
        return text
    }

    private func format(_ s: Double) -> String {
        let t = Int(s.rounded())
        return t < 60 ? "\(t)s" : "\(t / 60)m \(t % 60)s"
    }

    // MARK: What is happening now

    private var currentCard: some View {
        let shownID = queue.currentID ?? queue.items.last(where: { $0.status == .done || $0.status == .generic })?.id
        return VStack(alignment: .leading, spacing: 6) {
            Text(queue.isRunning ? "Now" : "Last captured")
                .font(.system(size: Theme.ts(12))).foregroundStyle(Theme.faint)
            ZStack {
                RoundedRectangle(cornerRadius: 8).fill(Color.black.opacity(0.78))
                if let id = shownID, let p = store.plugin(id), store.image(for: id) != nil {
                    PluginThumbnail(plugin: p)
                } else if queue.isRunning {
                    VStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        TimelineView(.periodic(from: .now, by: 1)) { ctx in
                            let s = queue.currentStarted.map { Int(ctx.date.timeIntervalSince($0)) } ?? 0
                            Text(s < 3 ? "Opening the plugin…" : "Opening the plugin… \(s)s")
                                .font(.system(size: Theme.ts(11))).foregroundStyle(Theme.faint).monospacedDigit()
                        }

                    }
                }
            }
            .frame(width: 260, height: 150)
            if let id = shownID, let item = queue.items.first(where: { $0.id == id }) {
                Text(item.name).font(.system(size: Theme.ts(13), weight: .semibold)).lineLimit(1)
                Text(item.maker).font(.system(size: Theme.ts(11))).foregroundStyle(Theme.faint).lineLimit(1)
            }
        }
    }

    private var counts: some View {
        VStack(alignment: .leading, spacing: 8) {
            countRow("checkmark.circle.fill", .green, "Captured", queue.succeeded)
            countRow("rectangle.dashed", .blue, "Basic controls (no own window)",
                     queue.items.filter { $0.status == .generic }.count)
            countRow("minus.circle", .secondary, "No window at all", queue.withoutWindow)
            countRow("xmark.octagon.fill", .red, "Failed", queue.failed)
            countRow("clock", .secondary, "Waiting",
                     queue.items.filter { $0.status == .waiting }.count)
            Text("Each plugin opens for a moment in the bottom left corner of your screen while it is captured. Logic's own plugins only run inside Logic, so they keep their category card.")
                .font(.system(size: Theme.ts(11))).foregroundStyle(Theme.faint)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func countRow(_ icon: String, _ color: Color, _ label: String, _ n: Int) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon).foregroundStyle(color).frame(width: 16)
            Text(label).font(.system(size: Theme.ts(12)))
            Spacer()
            Text("\(n)").font(.system(size: Theme.ts(12), weight: .semibold)).monospacedDigit()
        }
    }

    // MARK: Every plugin

    private var list: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(queue.items) { item in
                        row(item).id(item.id)
                        Divider().opacity(0.4)
                    }
                }
            }
            .background(RoundedRectangle(cornerRadius: 10).fill(Theme.surface))
            .onChange(of: queue.currentID) { _, id in
                if let id { withAnimation(.easeOut(duration: 0.15)) { proxy.scrollTo(id, anchor: .center) } }
            }
        }
    }

    private func row(_ item: SnapshotQueue.Item) -> some View {
        HStack(spacing: 10) {
            statusIcon(item.status).frame(width: 18)
            VStack(alignment: .leading, spacing: 1) {
                Text(item.name).font(.system(size: Theme.ts(12), weight: item.status == .working ? .semibold : .regular))
                if case .failed(let why) = item.status {
                    Text(why).font(.system(size: Theme.ts(10))).foregroundStyle(.red).lineLimit(2)
                }
            }
            Spacer()
            Text(item.maker).font(.system(size: Theme.ts(11))).foregroundStyle(Theme.faint).lineLimit(1)
            Text(item.seconds.map { String(format: "%.1fs", $0) } ?? "")
                .font(.system(size: Theme.ts(11))).monospacedDigit().foregroundStyle(Theme.faint)
                .frame(width: 44, alignment: .trailing)
        }
        .padding(.horizontal, 10).padding(.vertical, 6)
        .background(item.status == .working ? Theme.tileSelected : Color.clear)
    }

    @ViewBuilder
    private func statusIcon(_ s: SnapshotQueue.Item.Status) -> some View {
        switch s {
        case .waiting: Image(systemName: "circle").foregroundStyle(.tertiary)
        case .working: ProgressView().controlSize(.mini)
        case .done: Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        case .generic: Image(systemName: "rectangle.dashed").foregroundStyle(.blue)
        case .noUI: Image(systemName: "minus.circle").foregroundStyle(Theme.faint)
        case .failed: Image(systemName: "xmark.octagon.fill").foregroundStyle(.red)
        case .skipped: Image(systemName: "forward.end").foregroundStyle(Theme.faint)
        }
    }

    // MARK: Buttons

    private var footer: some View {
        HStack {
            if queue.isRunning {
                Button("Stop") { queue.cancel() }
                Button("Skip This Plugin") { queue.skipCurrent() }
                    .disabled(queue.currentID == nil)
                Spacer()
                Button("Hide, keep going") { SnapshotProgressWindow.shared.hide() }
                    .keyboardShortcut(.defaultAction)
            } else {
                if queue.failed > 0 {
                    Button("Try Failed Again") { queue.retryFailed() }
                }
                // Plugins that failed or only showed their basic controls (iZotope and others):
                // pick their real look from pictures on the web (BL-80).
                let needLook = queue.items.filter {
                    if case .failed = $0.status { return true }; return $0.status == .generic
                }.compactMap { item in PluginStore.shared.plugin(item.id) }
                if !needLook.isEmpty, WebPicture.available {
                    Button("Find Real Pictures on the Web (\(needLook.count))") {
                        SnapshotProgressWindow.shared.hide()
                        WebPicture.find(needLook)
                    }
                }
                Spacer()
                Button("Done") { SnapshotProgressWindow.shared.hide() }
                    .keyboardShortcut(.defaultAction)
            }
        }
    }
}
