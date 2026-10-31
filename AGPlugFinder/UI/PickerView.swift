import SwiftUI

/// The quick picker (menu bar > Quick Picker): a floating panel over Logic. Type, move with the arrows, Return.
struct PickerView: View {
    @Bindable var model: PickerModel
    var controller: PickerPanelController { .shared }
    var view = ViewSettings.shared

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                BrandMark(size: 18)
                SearchField(model: model, large: true)
                ViewControls(model: model)
            }
            .padding(.horizontal, 18).padding(.top, 16).padding(.bottom, 12)
            Rectangle().fill(Theme.edge).frame(height: 1)
            HStack(spacing: 0) {
                PluginGrid(model: model) { controller.insert() }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                if view.showInfoPane {
                    Rectangle().fill(Theme.edge).frame(width: 1)
                    Group {
                        if let p = model.selected {
                            PluginDetailView(plugin: p, model: model) { controller.insert() }
                        } else {
                            Color.clear
                        }
                    }
                    .frame(width: 320)
                }
            }
            if !view.showInfoPane, let message = model.message {
                HStack(spacing: 10) {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Theme.warning)
                    Text(message).font(.system(size: 12)).foregroundStyle(Theme.text)
                    Spacer()
                    if model.showAccessibilityButton {
                        QuietPill(title: "Allow in System Settings", height: 26) { AXAccess.openSettings() }
                    }
                }
                .padding(.horizontal, 18).frame(height: 44)
                .background(Theme.warningGround)
            }
            Rectangle().fill(Theme.edge).frame(height: 1)
            footer
        }
        .background(Theme.ground)
        .overlay {
            if model.slotChoices != nil {
                ZStack {
                    Color.black.opacity(0.55)
                    SlotChooser(model: model) { controller.insert(replacing: $0) }
                }
            }
        }
        .ignoresSafeArea(.container, edges: .top)
        .preferredColorScheme(.dark)
    }

    private var footer: some View {
        HStack(spacing: 16) {
            hint("↩", "insert")
            hint("← → ↑ ↓", "move")
            hint("⌘1–4", "sort")
            hint("⌘F", "favorites")
            hint("⌘D", "favorite")
            hint("esc", "close")
            Spacer()
            Text("\(model.results.count) plugins").monospacedDigit().foregroundStyle(Theme.faint)
        }
        .font(.system(size: 11))
        .padding(.horizontal, 18).frame(height: 38)
    }

    private func hint(_ key: String, _ what: String) -> some View {
        HStack(spacing: 6) {
            KeyCap(key: key)
            Text(what).foregroundStyle(Theme.faint)
        }
    }
}
