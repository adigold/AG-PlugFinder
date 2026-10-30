import SwiftUI

/// "Update available" / "What's new" card shown at the top of the library window.
struct UpdateBanner: View {
    var updater = Updater.shared

    var body: some View {
        if let r = updater.available {
            card(title: "Update available: version \(r.version)", notes: r.notes) {
                Button("Install and Restart") { updater.install() }
                    .keyboardShortcut(.defaultAction)
            }
        } else if updater.state == .downloading || updater.state == .installing {
            card(title: updater.state == .downloading ? "Downloading the update…" : "Installing…",
                 notes: []) { ProgressView().controlSize(.small) }
        } else if case .failed(let msg) = updater.state, msg != "No update address is set for this build." {
            card(title: "Update problem", notes: [msg]) {
                Button("Try Again") { Task { await updater.check() } }
            }
        } else if let w = updater.whatsNew {
            card(title: "What's new in \(w.version)", notes: w.notes) {
                Button("Got It") { updater.whatsNew = nil }
            }
        }
    }

    private func card<A: View>(title: String, notes: [String], @ViewBuilder action: () -> A) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "arrow.down.circle.fill").font(.system(size: 22)).foregroundStyle(Theme.accent)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.system(size: 13, weight: .semibold))
                ForEach(notes.prefix(5), id: \.self) { n in
                    Text(n).font(.system(size: 12)).foregroundStyle(.secondary)
                }
            }
            Spacer()
            action()
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 12).fill(Theme.accent.opacity(0.12)))
        .padding(.horizontal, 12).padding(.bottom, 8)
    }
}

/// Settings → Updates.
struct UpdateSettings: View {
    var updater = Updater.shared
    @State private var autoCheck = Updater.shared.autoCheck

    var body: some View {
        Form {
            Section {
                LabeledContent("Installed version", value: updater.currentVersion)
                LabeledContent("Status", value: statusText)
                if let d = updater.lastChecked {
                    LabeledContent("Last checked", value: d.formatted(date: .abbreviated, time: .shortened))
                }
                Toggle("Check for updates automatically", isOn: $autoCheck)
                    .onChange(of: autoCheck) { _, v in updater.autoCheck = v }
                HStack {
                    Button("Check Now") { Task { await updater.check() } }
                        .disabled(updater.feedURL == nil || updater.state == .checking)
                    if updater.available != nil {
                        Button("Install and Restart") { updater.install() }
                    }
                }
            }
            if let r = updater.available {
                Section("What's new in \(r.version)") {
                    ForEach(r.notes, id: \.self) { Text($0) }
                }
            }
        }
        .formStyle(.grouped)
    }

    private var statusText: String {
        switch updater.state {
        case .idle: return updater.feedURL == nil ? "Updates are not set up in this build" : "Not checked yet"
        case .checking: return "Checking…"
        case .upToDate: return "You have the latest version"
        case .available(let r): return "Version \(r.version) is available"
        case .downloading: return "Downloading…"
        case .installing: return "Installing…"
        case .failed(let m): return m
        }
    }
}
