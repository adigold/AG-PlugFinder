import SwiftUI

/// The footer's little indicator (BL-165): which program plugins go to right now, Logic Pro or
/// Ableton Live, with its icon and a green dot while it is open.
struct HostBadge: View {
    var store = PluginStore.shared
    @State private var hovering = false

    var body: some View {
        // The library's revision changes whenever the program in use or its state changes.
        let _ = store.revision
        HStack(spacing: 7) {
            if let icon = Host.icon {
                Image(nsImage: icon).resizable().interpolation(.high).frame(width: 16, height: 16)
            }
            Text(Host.title).font(.system(size: Theme.ts(11), weight: .semibold)).foregroundStyle(Theme.text)
            Circle().fill(Host.isOpen ? Color(red: 0.30, green: 0.80, blue: 0.45) : Theme.faint.opacity(0.6)).frame(width: 6, height: 6)
        }
        .padding(.horizontal, 10).frame(height: 22)
        .background(Capsule().fill(hovering ? Theme.raised : Theme.surface))
        .overlay(Capsule().strokeBorder(Theme.edge, lineWidth: 1))
        .onHover { hovering = $0 }
        .help(Host.isOpen ? "Plugins go to \(Host.title). Switch to the other program and it follows."
                          : "\(Host.title) isn't open. Open it, or switch to the other program, and this follows.")
        .animation(.easeOut(duration: 0.2), value: Host.title)
    }
}
