import AppKit
import SwiftUI

/// One release-note line, split for display: "New: Plugin chains. Save a chain…" becomes a
/// New card titled "Plugin chains" with the rest as its detail.
struct ReleaseNote: Identifiable, Hashable {
    enum Kind: String { case new = "New", improved = "Improved", fixed = "Fixed" }
    let id: Int
    let kind: Kind
    let title: String
    let detail: String
    let icon: String

    static func parse(_ notes: [String]) -> [ReleaseNote] {
        notes.enumerated().map { i, raw in
            var text = raw.trimmingCharacters(in: .whitespaces)
            var kind = Kind.new
            for k in [Kind.new, .improved, .fixed] where text.hasPrefix(k.rawValue + ":") {
                kind = k
                text = String(text.dropFirst(k.rawValue.count + 1)).trimmingCharacters(in: .whitespaces)
            }
            var title = text, detail = ""
            if let r = text.range(of: ". ") {
                title = String(text[..<r.lowerBound])
                detail = String(text[r.upperBound...])
            } else {
                if title.hasSuffix(".") { title.removeLast() }
                // A long single sentence: a short title, the rest as detail.
                if title.count > 40 {
                    let cuts = [", ", " with ", " through "].compactMap { title.range(of: $0) }
                        .filter { title.distance(from: title.startIndex, to: $0.lowerBound) >= 12 }
                    if let cut = cuts.min(by: { $0.lowerBound < $1.lowerBound }) {
                        let rest = String(title[cut.upperBound...])
                        let lead = title[cut.lowerBound...].hasPrefix(", ") ? "" : title[cut].trimmingCharacters(in: .whitespaces) + " "
                        detail = (lead + rest).prefix(1).uppercased() + (lead + rest).dropFirst() + "."
                        title = String(title[..<cut.lowerBound])
                    }
                }
            }
            return ReleaseNote(id: i, kind: kind, title: title, detail: detail, icon: icon(for: text))
        }
    }

    /// Most specific words first.
    private static let icons: [(words: [String], icon: String)] = [
        (["side by side", "plugin windows"], "rectangle.split.3x1"),
        (["as a send", "send"], "arrow.triangle.branch"),
        (["instrument track"], "plus.rectangle.on.rectangle"),
        (["several tracks"], "square.stack.3d.up"),
        (["find every track"], "scope"),
        (["before or after"], "arrow.up.arrow.down"),
        (["remove the last", "clear every"], "arrow.uturn.backward"),
        (["selected track, turn", "turn each one on"], "slider.vertical.3"),
        (["category"], "tag"),
        (["control option p"], "macwindow"),
        (["number keys", "control option"], "keyboard"),
        (["chain"], "link"),
        (["search by what"], "text.magnifyingglass"),
        (["more like this"], "square.on.square"),
        (["collections"], "folder"),
        (["notes on every"], "note.text"),
        (["suggestions"], "sparkles"),
        (["report"], "chart.bar"),
        (["icloud", "sync"], "icloud"),
        (["update"], "arrow.down.circle"),
        (["pictures"], "photo.on.rectangle"),
        (["legacy"], "clock.arrow.circlepath"),
        (["fade", "glide"], "wand.and.stars"),
        (["instrument"], "pianokeys"),
        (["design"], "paintbrush"),
        (["search"], "magnifyingglass"),
    ]

    private static func icon(for text: String) -> String {
        let t = text.lowercased()
        return icons.first { $0.words.contains { t.contains($0) } }?.icon ?? "sparkle"
    }
}

/// The What's New window (2026-10-31): the release's changes as cards, with the update's
/// install button when it is waiting, or "You're updated" right after an update.
@MainActor
final class WhatsNewWindow {
    static let shared = WhatsNewWindow()
    private var window: NSWindow?

    func show(version: String, notes: [String], justUpdated: Bool = false) {
        let w = window ?? {
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 820, height: 720),
                             styleMask: [.titled, .closable, .resizable, .fullSizeContentView],
                             backing: .buffered, defer: false)
            w.titlebarAppearsTransparent = true
            w.titleVisibility = .hidden
            w.isMovableByWindowBackground = true
            w.isReleasedWhenClosed = false
            w.backgroundColor = .black
            w.appearance = NSAppearance(named: .darkAqua)
            w.minSize = NSSize(width: 560, height: 480)
            w.center()
            window = w
            return w
        }()
        w.contentView = NSHostingView(rootView: WhatsNewView(version: version, notes: notes, justUpdated: justUpdated) {
            self.window?.orderOut(nil)
        })
        w.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }
}

struct WhatsNewView: View {
    let version: String
    let notes: [String]
    var justUpdated = false
    var close: () -> Void
    var updater = Updater.shared

    private var items: [ReleaseNote] { ReleaseNote.parse(notes) }
    private var waiting: Bool { !justUpdated && updater.available?.version == version }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 30) {
                    header
                    section(.new, "New in this version")
                    section(.improved, "Better than before")
                    section(.fixed, "Fixed")
                }
                .padding(.horizontal, 40).padding(.top, 52).padding(.bottom, 30)
            }
            footer
        }
        .frame(minWidth: 560, minHeight: 480)
        .background(Theme.ground)
        .preferredColorScheme(.dark)
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 22) {
            Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 84, height: 84)
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 10) {
                    Text(justUpdated ? "You're updated." : (waiting ? "A new update is available." : "What's new"))
                        .font(.system(size: 13, weight: .medium)).foregroundStyle(Theme.muted)
                    NewBadge()
                }
                Text("AG PlugFinder \(version)")
                    .font(.system(size: 30, weight: .bold)).foregroundStyle(Theme.text)
                Text(summary).font(.system(size: 14)).foregroundStyle(Theme.muted)
            }
        }
    }

    private var summary: String {
        let n = items.filter { $0.kind == .new }.count
        let b = items.count - n
        var parts: [String] = []
        if n > 0 { parts.append("\(n) new feature\(n == 1 ? "" : "s")") }
        if b > 0 { parts.append("\(b) improvement\(b == 1 ? "" : "s")") }
        return parts.joined(separator: " and ")
    }

    @ViewBuilder
    private func section(_ kind: ReleaseNote.Kind, _ title: String) -> some View {
        let list = items.filter { $0.kind == kind }
        if !list.isEmpty {
            VStack(alignment: .leading, spacing: 14) {
                Text(title).font(.system(size: 17, weight: .semibold)).foregroundStyle(Theme.text)
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 300), spacing: 12, alignment: .top)],
                          alignment: .leading, spacing: 12) {
                    ForEach(list) { card($0) }
                }
            }
        }
    }

    private func card(_ n: ReleaseNote) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: n.icon)
                .font(.system(size: 18, weight: .medium))
                .foregroundStyle(n.kind == .new ? Theme.accent : Theme.muted)
                .frame(width: 26, height: 26, alignment: .center)
                .padding(.top, 1)
            VStack(alignment: .leading, spacing: 5) {
                Text(n.title).font(.system(size: 14, weight: .semibold)).foregroundStyle(Theme.text)
                    .fixedSize(horizontal: false, vertical: true)
                if !n.detail.isEmpty {
                    Text(n.detail).font(.system(size: 12.5)).foregroundStyle(Theme.muted)
                        .lineSpacing(2).fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(16)
        .frame(maxWidth: .infinity, minHeight: 92, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Theme.surface))
    }

    private var footer: some View {
        HStack(spacing: 10) {
            if waiting {
                Text("AG PlugFinder closes and opens again by itself.")
                    .font(.system(size: 12)).foregroundStyle(Theme.faint)
                Spacer()
                QuietPill(title: "Later", height: 34) { close() }
                PrimaryPill(title: "Install and Restart", height: 36) { close(); updater.install() }
            } else {
                QuietPill(title: "Share AG PlugFinder", systemImage: "square.and.arrow.up", height: 34) { ShareWindow.shared.show() }
                Spacer()
                PrimaryPill(title: justUpdated ? "Start Using It" : "Close", height: 36) {
                    if justUpdated { updater.whatsNew = nil }
                    close()
                }
            }
        }
        .padding(.horizontal, 40).padding(.vertical, 16)
        .background(Theme.surface)
    }
}

/// The amber "New" badge for update announcements.
struct NewBadge: View {
    var body: some View {
        Text("New")
            .font(.system(size: 11, weight: .bold))
            .foregroundStyle(Color.black)
            .padding(.horizontal, 8).frame(height: 18)
            .background(Capsule().fill(Theme.accent))
    }
}
