import SwiftUI

/// The popup (⌃⌥P): search, sort, grid of screenshots, details, Return to insert.
struct PickerView: View {
    @Bindable var model: PickerModel
    var controller: PickerPanelController { .shared }

    var body: some View {
        VStack(spacing: 0) {
            SearchBar(model: model)
                .padding(.horizontal, 16).padding(.top, 16).padding(.bottom, 12)
            Divider()
            HStack(spacing: 0) {
                PluginGrid(model: model) { controller.insert() }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                Divider()
                Group {
                    if let p = model.selected {
                        PluginDetailView(plugin: p) { controller.insert() }
                    } else {
                        Color.clear
                    }
                }
                .frame(width: 300)
                .frame(maxHeight: .infinity)
            }
            if let message = model.message {
                Divider()
                HStack {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Theme.accent)
                    Text(message).font(.system(size: 12))
                    Spacer()
                    if model.showAccessibilityButton {
                        Button("Open Accessibility Settings") { AXAccess.openSettings() }
                    }
                }
                .padding(10)
            }
            Divider()
            footer
        }
        .overlay {
            if model.slotChoices != nil {
                ZStack {
                    Color.black.opacity(0.25)
                    SlotChooser(model: model) { controller.insert(replacing: $0) }
                }
            }
        }
        .background(.ultraThinMaterial)
        .ignoresSafeArea(.container, edges: .top)
    }

    private var footer: some View {
        HStack(spacing: 16) {
            hint("↩", "insert")
            hint("← → ↑ ↓", "move")
            hint("⌘1–5", "sort")
            hint("⌘D", "favorite")
            hint("esc", "close")
            Spacer()
            Text("\(model.results.count) plugins").foregroundStyle(.secondary)
        }
        .font(.system(size: 11))
        .padding(.horizontal, 16).padding(.vertical, 8)
    }

    private func hint(_ key: String, _ what: String) -> some View {
        HStack(spacing: 4) {
            Text(key).font(.system(size: 11, weight: .semibold, design: .rounded))
                .padding(.horizontal, 5).padding(.vertical, 1)
                .background(RoundedRectangle(cornerRadius: 4).fill(Color.primary.opacity(0.08)))
            Text(what).foregroundStyle(.secondary)
        }
    }
}
