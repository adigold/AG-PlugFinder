import AppKit
import SwiftUI

/// Feedback to Goldi (BL-85): a bug, an idea or a question goes straight to Goldi. Below it,
/// what this Mac sent before and whether it was seen or fixed.
@MainActor
final class FeedbackWindow {
    static let shared = FeedbackWindow()
    private var window: NSWindow?

    func show() {
        let w = window ?? {
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 520, height: 620),
                             styleMask: [.titled, .closable, .fullSizeContentView], backing: .buffered, defer: false)
            w.titlebarAppearsTransparent = true
            w.titleVisibility = .hidden
            w.isMovableByWindowBackground = true
            w.isReleasedWhenClosed = false
            w.backgroundColor = .black
            w.appearance = NSAppearance(named: .darkAqua)
            w.contentView = NSHostingView(rootView: FeedbackView())
            w.center()
            window = w
            return w
        }()
        w.makeKeyAndOrderFront(nil)
        NSApp.activate()
        Task { await Feedback.shared.refresh() }
    }
}

@MainActor
@Observable
final class Feedback {
    static let shared = Feedback()

    struct Item: Identifiable, Equatable {
        let id: Int
        let kind: String
        let message: String
        let status: String
        let note: String?
    }

    private(set) var items: [Item] = []

    func refresh() async {
        guard let base = PlugDB.base, let key = PlugDB.key else { return }
        var r = URLRequest(url: base.appendingPathComponent("v1/feedback/mine"))
        r.httpMethod = "POST"
        r.timeoutInterval = 15
        r.setValue("application/json", forHTTPHeaderField: "Content-Type")
        r.setValue(key, forHTTPHeaderField: "X-AGPF-Key")
        r.httpBody = try? JSONSerialization.data(withJSONObject: ["installId": PlugDB.installID])
        guard let (data, response) = try? await URLSession.shared.data(for: r),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let list = json["items"] as? [[String: Any]] else { return }
        items = list.compactMap { d in
            guard let id = Int("\(d["id"] ?? "")"), let message = d["message"] as? String else { return nil }
            return Item(id: id, kind: d["kind"] as? String ?? "bug", message: message,
                        status: d["status"] as? String ?? "open", note: d["note"] as? String)
        }
    }

    func send(kind: String, message: String, includeLog: Bool) async -> Bool {
        guard let base = PlugDB.base, let key = PlugDB.key else { return false }
        var body: [String: Any] = [
            "kind": kind, "message": message, "installId": PlugDB.installID,
            "appVersion": Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "",
            "macOS": ProcessInfo.processInfo.operatingSystemVersionString,
        ]
        if includeLog { body["log"] = CrashReports.diagnostics() }
        var r = URLRequest(url: base.appendingPathComponent("v1/feedback"))
        r.httpMethod = "POST"
        r.timeoutInterval = 30
        r.setValue("application/json", forHTTPHeaderField: "Content-Type")
        r.setValue(key, forHTTPHeaderField: "X-AGPF-Key")
        r.httpBody = try? JSONSerialization.data(withJSONObject: body)
        guard let (_, response) = try? await URLSession.shared.data(for: r),
              (response as? HTTPURLResponse)?.statusCode == 201 else { return false }
        await refresh()
        return true
    }

    /// On launch: tells the user once when something they sent was fixed.
    func announceFixed() async {
        await refresh()
        let d = UserDefaults.standard
        var told = Set(d.array(forKey: "feedback.toldFixed") as? [Int] ?? [])
        let fresh = items.filter { $0.status == "fixed" && !told.contains($0.id) }
        guard !fresh.isEmpty else { return }
        for f in fresh { told.insert(f.id) }
        d.set(Array(told), forKey: "feedback.toldFixed")
        let first = fresh[0]
        Toast.show(fresh.count == 1
                   ? "Fixed: \(first.message.prefix(60))" + (first.note.map { ". \($0)" } ?? "")
                   : "\(fresh.count) things you reported were fixed. See Send Feedback.")
    }
}

struct FeedbackView: View {
    var feedback = Feedback.shared
    @State private var kind = "bug"
    @State private var message = ""
    @State private var includeLog = true
    @State private var sending = false
    @State private var result: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 10) {
                BrandMark(size: 22)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Send feedback to Goldi").font(.system(size: 18, weight: .bold)).foregroundStyle(Theme.text)
                    Text("Goldi reads every message. You'll see here when it's fixed.")
                        .font(.system(size: 12)).foregroundStyle(Theme.muted)
                }
            }
            .padding(.top, 18)
            HStack(spacing: 6) {
                Chip(title: "Something's wrong", systemImage: "ladybug", on: kind == "bug") { kind = "bug" }
                Chip(title: "Idea", systemImage: "lightbulb", on: kind == "idea") { kind = "idea" }
                Chip(title: "Question", systemImage: "questionmark", on: kind == "question") { kind = "question" }
            }
            ZStack(alignment: .topLeading) {
                TextEditor(text: $message)
                    .font(.system(size: 13)).scrollContentBackground(.hidden)
                    .padding(8).frame(height: 150)
                    .background(RoundedRectangle(cornerRadius: 10).fill(Theme.raised))
                if message.isEmpty {
                    Text(kind == "idea" ? "What would make the app better for you?"
                         : kind == "question" ? "What would you like to know?"
                         : "What happened, and what did you expect?")
                        .font(.system(size: 13)).foregroundStyle(Theme.faint).padding(14).allowsHitTesting(false)
                }
            }
            Toggle("Include the app's log (helps find the cause)", isOn: $includeLog)
                .toggleStyle(.checkbox).font(.system(size: 12)).foregroundStyle(Theme.muted)
            HStack {
                if let result { Text(result).font(.system(size: 12)).foregroundStyle(Theme.muted) }
                Spacer()
                PrimaryPill(title: sending ? "Sending…" : "Send", systemImage: "paperplane", busy: sending, height: 34) { send() }
                    .disabled(sending || message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            Rectangle().fill(Theme.rule).frame(height: 1)
            Text("What you sent").font(.system(size: 12)).foregroundStyle(Theme.faint)
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    if feedback.items.isEmpty {
                        Text("Nothing yet.").font(.system(size: 12)).foregroundStyle(Theme.faint)
                    }
                    ForEach(feedback.items) { item in
                        HStack(alignment: .top, spacing: 10) {
                            StatusPill(status: item.status)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(item.message).font(.system(size: 12)).foregroundStyle(Theme.text).lineLimit(2)
                                if let note = item.note, !note.isEmpty {
                                    Text(note).font(.system(size: 11)).foregroundStyle(Theme.muted)
                                }
                            }
                            Spacer(minLength: 0)
                        }
                        .padding(10)
                        .background(RoundedRectangle(cornerRadius: 10).fill(Theme.surface))
                    }
                }
            }
        }
        .padding(.horizontal, 24).padding(.bottom, 20)
        .frame(width: 520, height: 620)
        .background(Theme.ground)
        .preferredColorScheme(.dark)
    }

    private func send() {
        sending = true
        result = nil
        let text = message.trimmingCharacters(in: .whitespacesAndNewlines)
        Task {
            let ok = await feedback.send(kind: kind, message: text, includeLog: includeLog)
            sending = false
            if ok { message = ""; result = "Sent. Thank you!" }
            else { result = "Couldn't send it. Check the internet connection and try again." }
        }
    }
}

private struct StatusPill: View {
    let status: String
    var body: some View {
        let (title, color): (String, Color) = switch status {
        case "fixed": ("Fixed", .green)
        case "progress": ("In progress", Theme.accent)
        case "seen": ("Seen", Theme.accent)
        case "closed": ("Done", Theme.faint)
        default: ("Sent", Theme.muted)
        }
        Text(title).font(.system(size: 10, weight: .semibold)).foregroundStyle(color)
            .padding(.horizontal, 8).frame(height: 20)
            .background(Capsule().fill(color.opacity(0.14)))
            .frame(width: 78, alignment: .leading)
    }
}
