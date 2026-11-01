import AppKit
import SwiftUI

/// One look for the whole app (BL-130): window grounds, surfaces, text tiers and the one hue.
struct Palette: Identifiable, Equatable {
    let id: String
    let name: String
    let isDark: Bool
    let ground, surface, hover, raised, rule, edge: UInt32
    let text, muted, faint: UInt32
    let accent, onAccent: UInt32
    /// The card's two dots in the Appearance picker.
    let dots: (UInt32, UInt32)

    static func == (a: Palette, b: Palette) -> Bool { a.id == b.id }

    static let all: [Palette] = [
        // Today's look, unchanged, and the default.
        Palette(id: "classic", name: "AG Classic", isDark: true,
                ground: 0x000000, surface: 0x111111, hover: 0x181818, raised: 0x2a2a2a, rule: 0x161616, edge: 0x1a1a1a,
                text: 0xffffff, muted: 0xb4b4b4, faint: 0x949494, accent: 0xf59e3d, onAccent: 0x000000, dots: (0xf59e3d, 0x2a2a2a)),
        Palette(id: "clean-light", name: "Clean Light", isDark: false,
                ground: 0xf4f4f5, surface: 0xffffff, hover: 0xf0f0f2, raised: 0xe4e4e7, rule: 0xececef, edge: 0xdedee3,
                text: 0x18181b, muted: 0x4b4b53, faint: 0x66666f, accent: 0x18181b, onAccent: 0xffffff, dots: (0x1f1f22, 0x8e8e93)),
        Palette(id: "nord-light", name: "Nord Light", isDark: false,
                ground: 0xeceff4, surface: 0xf8f9fb, hover: 0xeef1f6, raised: 0xdbe1ea, rule: 0xe5e9f0, edge: 0xd5dbe5,
                text: 0x2e3440, muted: 0x4c566a, faint: 0x5b667c, accent: 0x5e81ac, onAccent: 0xffffff, dots: (0x5e81ac, 0x88c0d0)),
        Palette(id: "sakura", name: "Sakura Blossom", isDark: false,
                ground: 0xfbf3f4, surface: 0xfffafb, hover: 0xf8ecee, raised: 0xf0dde1, rule: 0xf3e6e9, edge: 0xead5da,
                text: 0x3a2a2e, muted: 0x664e53, faint: 0x7f6268, accent: 0xc45c74, onAccent: 0xffffff, dots: (0xc45c74, 0xe39aa8)),
        Palette(id: "clean-dark", name: "Clean Dark", isDark: true,
                ground: 0x0e0e0e, surface: 0x171717, hover: 0x1f1f1f, raised: 0x2c2c2c, rule: 0x1c1c1c, edge: 0x232323,
                text: 0xf2f2f2, muted: 0xb0b0b0, faint: 0x8e8e8e, accent: 0xf2f2f2, onAccent: 0x000000, dots: (0xf2f2f2, 0x9a9a9a)),
        Palette(id: "dracula", name: "Dracula Classic", isDark: true,
                ground: 0x21222c, surface: 0x282a36, hover: 0x30323f, raised: 0x3b3d4c, rule: 0x2d2f3b, edge: 0x343746,
                text: 0xf8f8f2, muted: 0xc5c8d6, faint: 0xa2a7bc, accent: 0xbd93f9, onAccent: 0x1a1a24, dots: (0xbd93f9, 0xff79c6)),
        Palette(id: "cyberpunk", name: "Cyberpunk Neon", isDark: true,
                ground: 0x0b0610, surface: 0x140c1c, hover: 0x1c1226, raised: 0x2a1c36, rule: 0x1a1022, edge: 0x24162e,
                text: 0xf5f0ff, muted: 0xc9bfd9, faint: 0xa497b8, accent: 0xff2e88, onAccent: 0xffffff, dots: (0xff2e88, 0x5ff3ff)),
        Palette(id: "emerald", name: "Emerald Forest", isDark: true,
                ground: 0x07110d, surface: 0x0d1a14, hover: 0x12221a, raised: 0x1c3127, rule: 0x11201a, edge: 0x172a21,
                text: 0xeefaf3, muted: 0xb5cfc1, faint: 0x92b0a1, accent: 0x4cc38a, onAccent: 0x04140c, dots: (0x4cb886, 0x6fd6a0)),
        Palette(id: "oled", name: "OLED Pitch Black", isDark: true,
                ground: 0x000000, surface: 0x0a0a0a, hover: 0x121212, raised: 0x1e1e1e, rule: 0x0f0f0f, edge: 0x141414,
                text: 0xffffff, muted: 0xaeb4c0, faint: 0x8c93a2, accent: 0x4f7fff, onAccent: 0xffffff, dots: (0x4f7fff, 0x7aa2ff)),
    ]
}

extension Color {
    init(hex: UInt32) {
        self.init(red: Double((hex >> 16) & 0xff) / 255, green: Double((hex >> 8) & 0xff) / 255, blue: Double(hex & 0xff) / 255)
    }
}

extension NSColor {
    convenience init(hex: UInt32) {
        self.init(srgbRed: CGFloat((hex >> 16) & 0xff) / 255, green: CGFloat((hex >> 8) & 0xff) / 255,
                  blue: CGFloat(hex & 0xff) / 255, alpha: 1)
    }
}

/// The chosen look and text size, remembered across launches (BL-130).
@Observable
final class AppearanceSettings {
    nonisolated(unsafe) static let shared = AppearanceSettings()

    var paletteID: String { didSet { save("theme", paletteID); restyleWindows() } }
    /// 0.85 to 1.3; 1 is the size the app was designed at.
    var textScale: Double { didSet { save("textScale", textScale) } }

    var palette: Palette { Palette.all.first { $0.id == paletteID } ?? Palette.all[0] }

    private init() {
        let d = UserDefaults.standard
        paletteID = d.string(forKey: "view.theme") ?? "classic"
        let s = d.double(forKey: "view.textScale")
        textScale = s > 0 ? min(max(s, 0.85), 1.3) : 1
    }

    private func save(_ key: String, _ value: Any) {
        #if DEBUG
        // Test runs share the real app's settings: never save a look tried during a test.
        if CommandLine.arguments.contains(where: { $0.hasPrefix("--selftest") }) { return }
        #endif
        UserDefaults.standard.set(value, forKey: "view." + key)
        // Shared with the other Macs when that is on (BL-157).
        if UserLibrary.ready, Thread.isMainThread { MainActor.assumeIsolated { UserLibrary.shared.settingChanged() } }
    }

    /// Windows made in AppKit take the new look at once. See-through windows (the dim behind a
    /// dialog) keep their color.
    private func restyleWindows() {
        DispatchQueue.main.async {
            for w in NSApp.windows {
                if w.appearance != nil { w.appearance = Theme.nsAppearance }
                if (w.backgroundColor.usingColorSpace(.sRGB)?.alphaComponent ?? 0) == 1 { w.backgroundColor = Theme.nsGround }
            }
        }
    }
}

/// Settings, Appearance (BL-130): the theme cards and the text size.
struct AppearanceSettingsView: View {
    @Bindable var look = AppearanceSettings.shared
    private let columns = Array(repeating: GridItem(.flexible(), spacing: 14), count: 4)

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text("Theme").font(.system(size: Theme.ts(13), weight: .semibold)).foregroundStyle(Theme.muted)
                LazyVGrid(columns: columns, spacing: 14) {
                    ForEach(Palette.all) { p in
                        ThemeCard(palette: p, chosen: look.paletteID == p.id) { look.paletteID = p.id }
                    }
                }
                Text("Text").font(.system(size: Theme.ts(13), weight: .semibold)).foregroundStyle(Theme.muted)
                    .padding(.top, 14)
                HStack(spacing: 18) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Text size").font(.system(size: Theme.ts(14), weight: .medium)).foregroundStyle(Theme.text)
                        Text("Size of text across the app. Default is 100%.")
                            .font(.system(size: Theme.ts(12))).foregroundStyle(Theme.faint)
                    }
                    Spacer(minLength: 12)
                    Slider(value: $look.textScale, in: 0.85...1.3, step: 0.05).frame(width: 220).tint(Theme.accent)
                    Text("\(Int((look.textScale * 100).rounded()))%")
                        .font(.system(size: Theme.ts(14), weight: .medium)).monospacedDigit().foregroundStyle(Theme.text)
                        .frame(width: 52, alignment: .trailing)
                }
                .padding(16)
                .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Theme.surface))
                .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Theme.edge, lineWidth: 1))
                if look.textScale != 1 || look.paletteID != "classic" {
                    Button("Back to the Original Look") { look.paletteID = "classic"; look.textScale = 1 }
                        .buttonStyle(.plain).font(.system(size: Theme.ts(12), weight: .medium)).foregroundStyle(Theme.accent)
                }
            }
            .padding(24)
        }
        .background(Theme.ground)
    }
}

private struct ThemeCard: View {
    let palette: Palette
    let chosen: Bool
    let pick: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: pick) {
            VStack(alignment: .leading, spacing: 10) {
                ZStack(alignment: .topTrailing) {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(Color(hex: palette.ground))
                        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .strokeBorder(Color(hex: palette.edge), lineWidth: 1))
                        .overlay(alignment: .bottomLeading) {
                            HStack(spacing: 6) {
                                Circle().fill(Color(hex: palette.dots.0)).frame(width: 18, height: 18)
                                Circle().fill(Color(hex: palette.dots.1)).frame(width: 18, height: 18)
                            }
                            .padding(10)
                        }
                    if chosen {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 18)).foregroundStyle(Theme.onInk, Theme.ink)
                            .padding(8)
                    }
                }
                .frame(height: 64)
                VStack(alignment: .leading, spacing: 2) {
                    Text(palette.name).font(.system(size: Theme.ts(13), weight: .semibold)).foregroundStyle(Theme.text)
                        .lineLimit(1).minimumScaleFactor(0.8)
                    Text(palette.isDark ? "Dark" : "Light").font(.system(size: Theme.ts(11))).foregroundStyle(Theme.faint)
                }
            }
            .padding(10)
            .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(chosen ? Theme.raised : (hovering ? Theme.hover : Theme.surface)))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(chosen ? Theme.text : Theme.edge, lineWidth: chosen ? 2 : 1))
            .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(palette.name)
    }
}
