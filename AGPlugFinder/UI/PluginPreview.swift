import SwiftUI

/// The Space bar preview (BL-106): the selected plugin large, its picture on the left and what it
/// does on the right. Arrows move to the next plugin, Space or Esc closes, Return inserts.
struct PluginPreview: View {
    let plugin: Plugin
    @Bindable var model: PickerModel
    var onInsert: () -> Void
    var store = PluginStore.shared

    var body: some View {
        GeometryReader { geo in
            ZStack {
                // Clicks pass through the dimming: the library window closes the preview and the
                // click selects the plugin (or presses the button) under it.
                Color.black.opacity(0.62)
                    .allowsHitTesting(false)
                card
                    .frame(width: min(geo.size.width - 64, 1180), height: min(geo.size.height - 56, 760))
                    .background(GeometryReader { g in
                        Color.clear
                            .onAppear { model.previewCard = g.frame(in: .global) }
                            .onChange(of: g.frame(in: .global)) { _, f in model.previewCard = f }
                    })
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var card: some View {
        HStack(spacing: 0) {
            picture
            Rectangle().fill(Theme.edge).frame(width: 1)
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    titleBlock
                    if let d = plugin.details { about(d) } else { noInfo }
                    facts
                }
                .padding(.horizontal, 26).padding(.top, 26).padding(.bottom, 20)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .scrollIndicators(.never)
            .safeAreaInset(edge: .bottom, spacing: 0) { actions }
            .frame(width: 380)
        }
        .background(RoundedRectangle(cornerRadius: 22, style: .continuous).fill(Theme.ground))
        .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).strokeBorder(Theme.edge, lineWidth: 1))
        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        .shadow(color: .black.opacity(0.5), radius: 40, y: 18)
        .id(plugin.id)
        .transition(.opacity)
        .animation(.easeOut(duration: 0.16), value: plugin.id)
    }

    private var picture: some View {
        ZStack(alignment: .bottom) {
            PluginThumbnail(plugin: plugin, radius: 0)
                .padding(18)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            HStack(spacing: 14) {
                hint("←  →", "Browse")
                hint("Space", "Close")
                hint("↩", plugin.slotKind == .instrument ? "Load" : "Insert")
                Spacer()
                let results = model.results
                if results.count > 1 {
                    Text("\(model.selection + 1) of \(results.count)")
                        .font(.system(size: 11, weight: .medium)).monospacedDigit()
                        .foregroundStyle(Theme.faint)
                }
            }
            .padding(.horizontal, 22).padding(.bottom, 16)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.cardGround)
    }

    private func hint(_ key: String, _ what: String) -> some View {
        HStack(spacing: 6) {
            Text(key).font(.system(size: 10, weight: .semibold)).foregroundStyle(Theme.muted)
                .padding(.horizontal, 6).frame(height: 18)
                .background(RoundedRectangle(cornerRadius: 5).fill(Theme.raised))
            Text(what).font(.system(size: 11)).foregroundStyle(Theme.faint)
        }
    }

    private var titleBlock: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(plugin.name)
                .font(.system(size: 26, weight: .semibold)).foregroundStyle(Theme.text)
                .lineLimit(3).fixedSize(horizontal: false, vertical: true)
            Text("\(plugin.manufacturer) · \(plugin.displayCategory) · \(plugin.typeGroup)")
                .font(.system(size: 13)).foregroundStyle(Theme.faint)
            if let kind = plugin.details?.kind, !kind.isEmpty {
                Text(kind).font(.system(size: 15, weight: .medium)).foregroundStyle(Theme.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func about(_ d: PluginDetails) -> some View {
        VStack(alignment: .leading, spacing: 18) {
            if !d.bestFeature.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 6) {
                        Circle().fill(Theme.accent).frame(width: 6, height: 6)
                        Text("Best feature").font(.system(size: 12)).foregroundStyle(Theme.faint)
                    }
                    Text(d.bestFeature)
                        .font(.system(size: 17, weight: .medium)).foregroundStyle(Theme.text)
                        .lineSpacing(3).fixedSize(horizontal: false, vertical: true)
                }
                .padding(18)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Theme.surface))
            }
            if !d.summary.isEmpty {
                Text(d.summary)
                    .font(.system(size: 15)).foregroundStyle(Theme.muted)
                    .lineSpacing(4).fixedSize(horizontal: false, vertical: true)
            }
            if !d.highlights.isEmpty {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(d.highlights, id: \.self) { h in
                        HStack(alignment: .top, spacing: 10) {
                            Image(systemName: "checkmark")
                                .font(.system(size: 11, weight: .bold)).foregroundStyle(Theme.accent)
                                .padding(.top, 3)
                            Text(h).font(.system(size: 14)).foregroundStyle(Theme.text)
                                .fixedSize(horizontal: false, vertical: true)
                            Spacer(minLength: 0)
                        }
                        .padding(.vertical, 9)
                        if h != d.highlights.last { Rectangle().fill(Theme.rule).frame(height: 1) }
                    }
                }
            }
        }
    }

    private var facts: some View {
        VStack(spacing: 0) {
            fact("Format", plugin.isLogic ? "Built into Logic Pro" : plugin.formatName)
            fact("Version", plugin.isLogic ? "Logic Pro \(plugin.version)" : plugin.version)
            if let n = plugin.parameterCount { fact("Parameters", "\(n)") }
            if !plugin.tags.isEmpty { fact("Tags", plugin.tags.joined(separator: ", ")) }
        }
    }

    private func fact(_ k: String, _ v: String) -> some View {
        VStack(spacing: 0) {
            Rectangle().fill(Theme.rule).frame(height: 1)
            HStack(alignment: .top) {
                Text(k).foregroundStyle(Theme.faint)
                Spacer(minLength: 12)
                Text(v).foregroundStyle(Theme.muted).multilineTextAlignment(.trailing).monospacedDigit()
            }
            .font(.system(size: 12))
            .padding(.vertical, 9)
        }
    }

    private var noInfo: some View {
        HStack(spacing: 10) {
            Image(systemName: "sparkles").font(.system(size: 13)).foregroundStyle(Theme.faint)
            Text("No description yet. Right-click the plugin and choose Look Up Info.")
                .font(.system(size: 13)).foregroundStyle(Theme.faint)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Theme.surface))
    }

    private var actions: some View {
        HStack(spacing: 8) {
            PrimaryPill(title: model.isBusy ? "Adding to Logic…" : (plugin.slotKind == .instrument ? "Load as Instrument" : "Insert in Logic"),
                        systemImage: "plus", hint: "↩", busy: model.isBusy, fullWidth: true,
                        height: 40, action: onInsert)
                .disabled(model.isBusy)
            BarIconButton(systemImage: store.favorites.contains(plugin.id) ? "star.fill" : "star",
                          help: "Favorite (⌘D)", active: store.favorites.contains(plugin.id),
                          activeTint: Theme.accent) {
                store.favoriteTapped(plugin.id)
            }
            BarIconButton(systemImage: "xmark", help: "Close (Space)") { model.previewing = false }
        }
        .padding(.horizontal, 26).padding(.vertical, 16)
        .background(Theme.ground)
        .overlay(alignment: .top) { Rectangle().fill(Theme.rule).frame(height: 1) }
    }
}
