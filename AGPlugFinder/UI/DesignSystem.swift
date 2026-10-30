import AppKit
import SwiftUI

/// AG PlugFinder's look: true black, elevation by lightness alone, colour only on data.
/// (taste skill app style "True-black flat", seed 2123194605, with AG amber as the one hue.)
enum Theme {
    // Ground and elevation steps. No borders or shadows on anything at rest.
    static let ground = Color(white: 0.0)          // #000 window
    static let surface = Color(white: 0.067)       // #111 tiles, cards
    static let hover = Color(white: 0.094)         // #181818 tile under the pointer
    static let raised = Color(white: 0.165)        // #2a2a2a controls, selected tile, nested panels
    static let rule = Color(white: 0.086)          // #161616 row rules
    static let edge = Color(white: 0.10)           // #1a1a1a the one structural line

    // Text in three tiers, each 4.5:1 or better on the surfaces it sits on.
    static let text = Color.white
    static let muted = Color(white: 0.706)         // #b4b4b4
    static let faint = Color(white: 0.58)          // #949494

    /// The one hue. Data and the selection only: never buttons, tabs or navigation.
    static let accent = Color(red: 0.961, green: 0.62, blue: 0.239)   // AG amber #f59e3d
    static let warning = Color(red: 0.898, green: 0.663, blue: 0.231)
    static let warningGround = Color(red: 0.169, green: 0.141, blue: 0.078)
    static let negative = Color(red: 0.898, green: 0.337, blue: 0.435)

    static let radiusCard: CGFloat = 20
    static let radiusInner: CGFloat = 12
    static let gap: CGFloat = 14
    static let pad: CGFloat = 22
    static let control: CGFloat = 36

    // Names used by older views.
    static let tileBG = surface
    static let tileSelected = raised
    static let cardGround = Color(white: 0.04)
}

/// The product's mark: three insert slots, the last one filled, as in Logic's channel strip.
struct BrandMark: View {
    var size: CGFloat = 16
    var body: some View {
        VStack(spacing: size * 0.13) {
            ForEach(0..<3) { i in
                Capsule()
                    .fill(i == 2 ? Theme.accent : Color.white.opacity(0.32))
                    .frame(width: size, height: size * 0.2)
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

/// The one primary control: a white pill with black text.
struct PrimaryPill: View {
    let title: String
    var systemImage: String? = nil
    var hint: String? = nil
    var busy = false
    var fullWidth = false
    var height: CGFloat = Theme.control
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                if busy {
                    ProgressView().controlSize(.small).tint(.black)
                } else if let systemImage {
                    Image(systemName: systemImage).font(.system(size: 13, weight: .semibold))
                }
                Text(title).font(.system(size: 14, weight: .semibold))
                if fullWidth { Spacer(minLength: 0) }
                if let hint {
                    Text(hint).font(.system(size: 12, weight: .semibold)).opacity(0.45)
                }
            }
            .padding(.horizontal, 18)
            .frame(maxWidth: fullWidth ? .infinity : nil)
            .frame(height: height)
            .foregroundStyle(Color.black)
            .background(Capsule().fill(Color.white.opacity(hovering ? 0.88 : 1)))
            .contentShape(Capsule())
        }
        .buttonStyle(PressScale())
        .onHover { hovering = $0 }
    }
}

/// A secondary control: grey fill, white text.
struct QuietPill: View {
    let title: String
    var systemImage: String? = nil
    var height: CGFloat = 30
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                if let systemImage { Image(systemName: systemImage).font(.system(size: 12, weight: .medium)) }
                Text(title).font(.system(size: 13, weight: .medium))
            }
            .padding(.horizontal, 14).frame(height: height)
            .foregroundStyle(Theme.text)
            .background(Capsule().fill(hovering ? Color(white: 0.21) : Theme.raised))
            .contentShape(Capsule())
        }
        .buttonStyle(PressScale())
        .onHover { hovering = $0 }
    }
}

/// An icon-only control for bars: no chrome at rest, a grey disc under the pointer.
struct BarIconButton: View {
    let systemImage: String
    let help: String
    var active = false
    var activeTint: Color = Theme.text
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(active ? activeTint : (hovering ? Theme.text : Theme.muted))
                .frame(width: 32, height: 32)
                .background(Circle().fill(hovering || active ? Theme.raised : Color.clear))
                .contentShape(Circle())
        }
        .buttonStyle(PressScale())
        .onHover { hovering = $0 }
        .help(help)
        .accessibilityLabel(help)
    }
}

/// Buttons sink a little when pressed.
struct PressScale: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.96 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

/// A key cap for shortcut hints.
struct KeyCap: View {
    let key: String
    var body: some View {
        Text(key)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(Theme.muted)
            .padding(.horizontal, 6).frame(height: 20)
            .background(RoundedRectangle(cornerRadius: 5).fill(Theme.raised))
    }
}

/// A selectable chip: white when chosen (the style's inversion), grey otherwise.
struct Chip: View {
    let title: String
    var systemImage: String? = nil
    let on: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                if let systemImage { Image(systemName: systemImage).font(.system(size: 11, weight: .medium)) }
                Text(title).font(.system(size: 12, weight: on ? .semibold : .regular))
            }
            .padding(.horizontal, 11).frame(height: 28)
            .foregroundStyle(on ? Color.black : Theme.text)
            .background(Capsule().fill(on ? Color.white : Theme.raised))
            .contentShape(Capsule())
        }
        .buttonStyle(PressScale())
    }
}

/// A square check for lists, white when on.
struct CheckMark: View {
    let on: Bool
    var partial = false
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 5)
                .fill(on || partial ? Color.white : Color.clear)
                .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(on || partial ? .clear : Color(white: 0.35), lineWidth: 1.5))
            if on { Image(systemName: "checkmark").font(.system(size: 10, weight: .bold)).foregroundStyle(.black) }
            else if partial { Image(systemName: "minus").font(.system(size: 10, weight: .bold)).foregroundStyle(.black) }
        }
        .frame(width: 18, height: 18)
    }
}

/// Makes the window's top 52px the app's own bar: hidden system title bar on black, no system
/// toolbar (on macOS 26 it lays a glass blur over the bar). The bar draws its own window buttons.
enum WindowChrome {
    static let barHeight: CGFloat = 52
    static let trafficLightsWidth: CGFloat = 78

    @MainActor
    static func apply(to window: NSWindow) {
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.styleMask.insert(.fullSizeContentView)
        window.toolbar = nil
        window.backgroundColor = .black
        window.appearance = NSAppearance(named: .darkAqua)
        window.titlebarSeparatorStyle = .none
        for kind in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
            window.standardWindowButton(kind)?.isHidden = true
        }
    }
}

/// Close, minimise and zoom, drawn in the app's bar and centred in it. Symbols show on hover,
/// like the system's own buttons.
struct TrafficLights: View {
    var window: NSWindow?
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 8) {
            light(Color(red: 1.0, green: 0.373, blue: 0.341), "xmark", "Close") { window?.performClose(nil) }
            light(Color(red: 0.996, green: 0.737, blue: 0.180), "minus", "Minimise") { window?.miniaturize(nil) }
            light(Color(red: 0.157, green: 0.784, blue: 0.251), "arrow.up.left.and.arrow.down.right", "Zoom") {
                window?.zoom(nil)
            }
        }
        .padding(.leading, 20)
        .frame(width: WindowChrome.trafficLightsWidth, alignment: .leading)
        .onHover { hovering = $0 }
    }

    private func light(_ color: Color, _ symbol: String, _ label: String,
                       _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            ZStack {
                Circle().fill(window?.isKeyWindow == false && !hovering ? Color(white: 0.3) : color)
                if hovering {
                    Image(systemName: symbol)
                        .font(.system(size: 7, weight: .black))
                        .foregroundStyle(Color.black.opacity(0.6))
                }
            }
            .frame(width: 12, height: 12)
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }
}
