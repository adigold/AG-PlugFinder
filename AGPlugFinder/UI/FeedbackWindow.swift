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
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 520, height: 710),
                             styleMask: [.titled, .closable, .fullSizeContentView], backing: .buffered, defer: false)
            w.titlebarAppearsTransparent = true
            w.titleVisibility = .hidden
            w.isMovableByWindowBackground = true
            w.isReleasedWhenClosed = false
            w.backgroundColor = Theme.nsGround
            w.appearance = Theme.nsAppearance
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

    func send(kind: String, message: String, includeLog: Bool, picture: Data? = nil,
              name: String = "", email: String = "") async -> Bool {
        guard let base = PlugDB.base, let key = PlugDB.key else { return false }
        var body: [String: Any] = [
            "kind": kind, "message": message, "installId": PlugDB.installID,
            "appVersion": Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "",
            "macOS": ProcessInfo.processInfo.operatingSystemVersionString,
        ]
        if includeLog { body["log"] = CrashReports.diagnostics() }
        if !name.isEmpty { body["name"] = name }
        if !email.isEmpty { body["email"] = email }
        if let picture, let small = PlugDB.compact(picture) { body["picture"] = small.base64EncodedString() }
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
    @State private var picture: Data?
    // Optional, remembered for next time.
    @AppStorage("feedback.name") private var name = ""
    @AppStorage("feedback.email") private var email = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 10) {
                BrandMark(size: 22)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Send feedback to Goldi").font(.system(size: Theme.ts(18), weight: .bold)).foregroundStyle(Theme.text)
                    Text("Goldi reads every message. You'll see here when it's fixed.")
                        .font(.system(size: Theme.ts(12))).foregroundStyle(Theme.muted)
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
                    .font(.system(size: Theme.ts(13))).scrollContentBackground(.hidden)
                    .padding(8).frame(height: 150)
                    .background(RoundedRectangle(cornerRadius: 10).fill(Theme.raised))
                if message.isEmpty {
                    Text(kind == "idea" ? "What would make the app better for you?"
                         : kind == "question" ? "What would you like to know?"
                         : "What happened, and what did you expect?")
                        .font(.system(size: Theme.ts(13))).foregroundStyle(Theme.faint).padding(14).allowsHitTesting(false)
                }
            }
            HStack(spacing: 10) {
                field("Full name (optional)", $name)
                field("Email (optional, for a reply)", $email)
            }
            screenshotRow
            Toggle("Include the app's log (helps find the cause)", isOn: $includeLog)
                .toggleStyle(.checkbox).font(.system(size: Theme.ts(12))).foregroundStyle(Theme.muted)
            HStack {
                if let result { Text(result).font(.system(size: Theme.ts(12))).foregroundStyle(Theme.muted) }
                Spacer()
                PrimaryPill(title: sending ? "Sending…" : "Send", systemImage: "paperplane", busy: sending, height: 34) { send() }
                    .disabled(sending || message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            Rectangle().fill(Theme.rule).frame(height: 1)
            Text("What you sent").font(.system(size: Theme.ts(12))).foregroundStyle(Theme.faint)
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    if feedback.items.isEmpty {
                        Text("Nothing yet.").font(.system(size: Theme.ts(12))).foregroundStyle(Theme.faint)
                    }
                    ForEach(feedback.items) { item in
                        HStack(alignment: .top, spacing: 10) {
                            StatusPill(status: item.status)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(item.message).font(.system(size: Theme.ts(12))).foregroundStyle(Theme.text).lineLimit(2)
                                if let note = item.note, !note.isEmpty {
                                    Text(note).font(.system(size: Theme.ts(11))).foregroundStyle(Theme.muted)
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
        .frame(width: 520, height: 710)
        .onDrop(of: [.image, .fileURL], isTargeted: nil) { providers in
            for p in providers {
                if p.canLoadObject(ofClass: NSImage.self) {
                    _ = p.loadObject(ofClass: NSImage.self) { obj, _ in
                        if let tiff = (obj as? NSImage)?.tiffRepresentation { DispatchQueue.main.async { picture = tiff } }
                    }
                    return true
                }
            }
            return false
        }
        .background(Theme.ground)
        .preferredColorScheme(Theme.scheme)
    }

    private func field(_ prompt: String, _ text: Binding<String>) -> some View {
        TextField("", text: text, prompt: Text(prompt).foregroundStyle(Theme.faint))
            .textFieldStyle(.plain).font(.system(size: Theme.ts(13))).foregroundStyle(Theme.text)
            .padding(.horizontal, 12).frame(height: 34)
            .background(RoundedRectangle(cornerRadius: 10).fill(Theme.raised))
    }

    /// A screenshot: choose a file, paste one, or drop one here.
    private var screenshotRow: some View {
        HStack(spacing: 10) {
            if let picture, let image = NSImage(data: picture) {
                Image(nsImage: image).resizable().scaledToFill().frame(width: 72, height: 46)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                    .overlay(alignment: .topTrailing) {
                        Button { self.picture = nil } label: {
                            Image(systemName: "xmark.circle.fill").foregroundStyle(.white, .black.opacity(0.7))
                        }
                        .buttonStyle(.plain).padding(3).help("Remove the screenshot")
                    }
                Text("Screenshot attached").font(.system(size: Theme.ts(12))).foregroundStyle(Theme.muted)
            } else {
                QuietPill(title: "Add Screenshot…", systemImage: "photo", height: 28) { choose() }
                QuietPill(title: "Paste", systemImage: "doc.on.clipboard", height: 28) { paste() }
                Text("or drop an image here").font(.system(size: Theme.ts(11))).foregroundStyle(Theme.faint)
            }
            Spacer()
        }
        .frame(minHeight: 46)
    }

    private func choose() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = false
        panel.directoryURL = FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first
        if panel.runModal() == .OK, let url = panel.url, let d = try? Data(contentsOf: url), NSImage(data: d) != nil {
            picture = d
        }
    }

    private func paste() {
        let pb = NSPasteboard.general
        if let image = NSImage(pasteboard: pb), let tiff = image.tiffRepresentation { picture = tiff }
        else { result = "There is no image to paste. Take a screenshot with ⇧⌘4 and hold Control to copy it." }
    }

    private func send() {
        sending = true
        result = nil
        let text = message.trimmingCharacters(in: .whitespacesAndNewlines)
        Task {
            let ok = await feedback.send(kind: kind, message: text, includeLog: includeLog, picture: picture,
                                         name: name.trimmingCharacters(in: .whitespaces),
                                         email: email.trimmingCharacters(in: .whitespaces))
            sending = false
            if ok { message = ""; picture = nil; result = "Sent. Thank you!" }
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
        Text(title).font(.system(size: Theme.ts(10), weight: .semibold)).foregroundStyle(color)
            .padding(.horizontal, 8).frame(height: 20)
            .background(Capsule().fill(color.opacity(0.14)))
            .frame(width: 78, alignment: .leading)
    }
}
