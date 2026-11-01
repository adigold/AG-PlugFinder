import AppKit
import SwiftUI

/// Sharing AG PlugFinder (BL-55): a card picture and one-click buttons for the places people
/// actually share, instead of the generic Mac share sheet.
enum ShareLinks {
    static let page = "https://github.com/adigold/AG-PlugFinder"
    static let text = "AG PlugFinder: find any plugin by how it looks and add it to Logic Pro in one keystroke. Free for Mac."
    static var textWithLink: String { "\(text) \(page)" }

    static func enc(_ s: String) -> String {
        s.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? s
    }

    /// The screenshot inside the card, shipped with the app.
    static var screenshot: NSImage? {
        Bundle.main.url(forResource: "share-shot", withExtension: "jpg", subdirectory: "Share")
            .flatMap(NSImage.init(contentsOf:))
            ?? Bundle.main.url(forResource: "share-shot", withExtension: "jpg").flatMap(NSImage.init(contentsOf:))
    }

    /// The card as a 1280 by 640 picture (the size link previews use).
    @MainActor
    static func cardImage() -> NSImage? {
        let r = ImageRenderer(content: ShareCard().frame(width: 1280, height: 640))
        r.scale = 2
        return r.nsImage
    }

    @MainActor
    static func cardPNG() -> Data? {
        guard let img = cardImage(), let tiff = img.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff) else { return nil }
        return rep.representation(using: .png, properties: [:])
    }
}

/// The share card: mark, name, one line, and the app itself.
struct ShareCard: View {
    var body: some View {
        GeometryReader { geo in
            let s = geo.size.width / 1280
            ZStack(alignment: .topLeading) {
                Color.black
                // The app, large and cut off at the right edge.
                if let shot = ShareLinks.screenshot {
                    Image(nsImage: shot).resizable().aspectRatio(contentMode: .fill)
                        .frame(width: 900 * s, height: 560 * s, alignment: .topLeading)
                        .clipShape(RoundedRectangle(cornerRadius: 22 * s, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 22 * s, style: .continuous)
                            .strokeBorder(Color.white.opacity(0.12), lineWidth: 1.5 * s))
                        .offset(x: 600 * s, y: 110 * s)
                }
                VStack(alignment: .leading, spacing: 0) {
                    HStack(spacing: 16 * s) {
                        BrandMark(size: 38 * s)
                        Text("AG PlugFinder").font(.system(size: 34 * s, weight: .bold)).foregroundStyle(.white)
                    }
                    Spacer().frame(height: 70 * s)
                    Text("Find any plugin\nby how it looks.")
                        .font(.system(size: 62 * s, weight: .bold)).foregroundStyle(.white)
                        .lineSpacing(2 * s).fixedSize()
                    Spacer().frame(height: 22 * s)
                    Text("Add it to Logic Pro\nin one keystroke.")
                        .font(.system(size: 34 * s, weight: .semibold)).foregroundStyle(Theme.accent)
                        .lineSpacing(2 * s).fixedSize()
                    Spacer()
                    HStack(spacing: 12 * s) {
                        Text("Free for Mac").font(.system(size: 22 * s, weight: .semibold)).foregroundStyle(.black)
                            .padding(.horizontal, 18 * s).frame(height: 44 * s)
                            .background(Capsule().fill(Color.white))
                        Text("github.com/adigold/AG-PlugFinder")
                            .font(.system(size: 20 * s, weight: .medium)).foregroundStyle(Color(white: 0.7))
                            .lineLimit(1).fixedSize()
                    }
                }
                .padding(.leading, 64 * s).padding(.top, 60 * s).padding(.bottom, 56 * s)
                .frame(width: 600 * s, height: geo.size.height, alignment: .topLeading)
            }
            .frame(width: geo.size.width, height: geo.size.height)
            .clipped()
        }
        .aspectRatio(2, contentMode: .fit)
    }
}

@MainActor
final class ShareWindow {
    static let shared = ShareWindow()
    private var window: NSWindow?

    func show() {
        let w = window ?? {
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 640),
                             styleMask: [.titled, .closable, .fullSizeContentView], backing: .buffered, defer: false)
            w.titlebarAppearsTransparent = true
            w.titleVisibility = .hidden
            w.isMovableByWindowBackground = true
            w.isReleasedWhenClosed = false
            w.backgroundColor = Theme.nsGround
            w.appearance = Theme.nsAppearance
            w.contentView = NSHostingView(rootView: ShareView())
            w.center()
            window = w
            return w
        }()
        w.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }
}

struct ShareView: View {
    @State private var done: String?

    private struct Target: Identifiable {
        let id: String
        let glyph: String       // SF Symbol, or a short mark drawn as text
        let isSymbol: Bool
        let run: @MainActor () -> String?
    }

    private var targets: [Target] {
        let t = ShareLinks.enc(ShareLinks.text), u = ShareLinks.enc(ShareLinks.page)
        let all = ShareLinks.enc(ShareLinks.textWithLink)
        func open(_ s: String) -> String? { if let url = URL(string: s) { NSWorkspace.shared.open(url) }; return nil }
        return [
            Target(id: "X", glyph: "𝕏", isSymbol: false) { open("https://x.com/intent/post?text=\(t)&url=\(u)") },
            Target(id: "WhatsApp", glyph: "phone.bubble.fill", isSymbol: true) {
                // The WhatsApp app when it is installed, else WhatsApp on the web.
                if let app = URL(string: "whatsapp://send?text=\(all)"), NSWorkspace.shared.urlForApplication(toOpen: app) != nil {
                    NSWorkspace.shared.open(app); return nil
                }
                return open("https://wa.me/?text=\(all)")
            },
            Target(id: "Messages", glyph: "message.fill", isSymbol: true) {
                NSSharingService(named: .composeMessage)?.perform(withItems: [ShareLinks.textWithLink]); return nil
            },
            Target(id: "Instagram", glyph: "camera.fill", isSymbol: true) {
                // Instagram has no link to post from a Mac: save the card, copy the caption.
                let url = FileManager.default.homeDirectoryForCurrentUser
                    .appendingPathComponent("Downloads/AG PlugFinder.png")
                if let data = ShareLinks.cardPNG() { try? data.write(to: url) }
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(ShareLinks.textWithLink, forType: .string)
                NSWorkspace.shared.activateFileViewerSelecting([url])
                _ = open("https://www.instagram.com/")
                return "The picture is in Downloads and the caption is copied. Post it from Instagram."
            },
            Target(id: "Telegram", glyph: "paperplane.fill", isSymbol: true) { open("https://t.me/share/url?url=\(u)&text=\(t)") },
            Target(id: "Facebook", glyph: "f", isSymbol: false) { open("https://www.facebook.com/sharer/sharer.php?u=\(u)") },
            Target(id: "LinkedIn", glyph: "in", isSymbol: false) { open("https://www.linkedin.com/sharing/share-offsite/?url=\(u)") },
            Target(id: "Email", glyph: "envelope.fill", isSymbol: true) {
                let s = NSSharingService(named: .composeEmail)
                s?.subject = "AG PlugFinder for Logic Pro"
                s?.perform(withItems: [ShareLinks.textWithLink])
                return nil
            },
            Target(id: "Copy link", glyph: "link", isSymbol: true) {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(ShareLinks.page, forType: .string)
                return "Link copied."
            },
            Target(id: "Save picture", glyph: "arrow.down.to.line", isSymbol: true) {
                let url = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Downloads/AG PlugFinder.png")
                if let data = ShareLinks.cardPNG() { try? data.write(to: url) }
                NSWorkspace.shared.activateFileViewerSelecting([url])
                return "Saved to Downloads."
            },
        ]
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Share AG PlugFinder").font(.system(size: 24, weight: .bold)).foregroundStyle(Theme.text)
                Text("Know someone who makes music in Logic? It's free.")
                    .font(.system(size: 13)).foregroundStyle(Theme.muted)
            }
            ShareCard()
                .frame(width: 584, height: 292)
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Theme.raised, lineWidth: 1))
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: 5), spacing: 14) {
                ForEach(targets) { t in tile(t) }
            }
            HStack {
                Text(done ?? ShareLinks.page).font(.system(size: 12))
                    .foregroundStyle(done == nil ? Theme.faint : Theme.accent).lineLimit(1)
                Spacer()
            }
        }
        .padding(.horizontal, 28).padding(.top, 40).padding(.bottom, 22)
        .frame(width: 640)
        .background(Theme.ground)
        .preferredColorScheme(Theme.scheme)
    }

    private func tile(_ t: Target) -> some View {
        ShareTile(name: t.id, glyph: t.glyph, isSymbol: t.isSymbol) {
            done = t.run() ?? "Opened \(t.id)."
        }
    }
}

private struct ShareTile: View {
    let name: String
    let glyph: String
    let isSymbol: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            VStack(spacing: 8) {
                Group {
                    if isSymbol { Image(systemName: glyph).font(.system(size: 19, weight: .medium)) }
                    else { Text(glyph).font(.system(size: 21, weight: .bold, design: .rounded)) }
                }
                .foregroundStyle(Theme.text)
                .frame(width: 52, height: 52)
                .background(RoundedRectangle(cornerRadius: 15, style: .continuous).fill(hovering ? Theme.raised : Theme.surface))
                Text(name).font(.system(size: 11)).foregroundStyle(Theme.muted).lineLimit(1)
            }
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(PressScale())
        .onHover { hovering = $0 }
    }
}
