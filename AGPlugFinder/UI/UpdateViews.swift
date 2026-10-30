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
                Button("Try Again") { Task { await updater.check(userInitiated: true) } }
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
                    Button("Check Now") { Task { await updater.check(userInitiated: true) } }
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
        case .upToDate: return "You're updated."
        case .available(let r): return "A new update is available (v\(r.version))."
        case .downloading: return "Downloading…"
        case .installing: return "Installing…"
        case .failed(let m): return m
        }
    }
}

/// Top right of the main window: the installed version and the update status.
/// Click it for Versions: installed and latest version, Check for Update, what's new, install.
struct VersionBadge: View {
    var updater = Updater.shared
    @State private var showVersions = false

    var body: some View {
        Button { showVersions.toggle() } label: {
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .foregroundStyle(updater.available != nil ? Color.black : tint)
                Text(label).font(.system(size: 12, weight: .medium))
            }
            .padding(.horizontal, 10).padding(.vertical, 4)
            .background(Capsule().fill(updater.available != nil ? Theme.accent : Color.primary.opacity(0.07)))
            .foregroundStyle(updater.available != nil ? Color.black : Color.primary)
        }
        .buttonStyle(.plain)
        .help("Versions and updates")
        .popover(isPresented: $showVersions, arrowEdge: .bottom) { VersionsPanel() }
    }

    private var label: String {
        switch updater.state {
        case .available: return "A new update is available"
        case .upToDate: return "v\(updater.currentVersion) · You're updated."
        case .checking: return "Checking…"
        case .downloading: return "Downloading…"
        case .installing: return "Installing…"
        default: return "v\(updater.currentVersion) · Check for update"
        }
    }

    private var icon: String {
        switch updater.state {
        case .available: return "arrow.down.circle.fill"
        case .upToDate: return "checkmark.circle.fill"
        case .failed: return "exclamationmark.circle"
        default: return "arrow.triangle.2.circlepath"
        }
    }

    private var tint: Color {
        switch updater.state {
        case .upToDate: return .green
        case .failed: return .orange
        default: return .secondary
        }
    }
}

/// The Versions popover.
struct VersionsPanel: View {
    var updater = Updater.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Versions").font(.system(size: 15, weight: .bold))
            row("Installed", "v\(updater.currentVersion)")
            if let r = updater.available { row("Latest", "v\(r.version)") }
            if let d = updater.lastChecked {
                row("Last checked", d.formatted(date: .abbreviated, time: .shortened))
            }

            Text(status)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(statusColor)

            if let r = updater.available, !r.notes.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("WHAT'S NEW").font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary)
                    ForEach(r.notes, id: \.self) { Text($0).font(.system(size: 12)) }
                }
            }

            HStack {
                Button("Check for Update") { Task { await updater.check(userInitiated: true) } }
                    .disabled(updater.state == .checking || updater.state == .downloading
                              || updater.state == .installing)
                if updater.available != nil {
                    Button("Install and Restart") { updater.install() }
                        .keyboardShortcut(.defaultAction)
                }
            }
        }
        .padding(16)
        .frame(width: 320, alignment: .leading)
    }

    private var status: String {
        switch updater.state {
        case .available: return "A new update is available."
        case .upToDate: return "You're updated."
        case .checking: return "Checking for updates…"
        case .downloading: return "Downloading the update…"
        case .installing: return "Installing, the app will restart."
        case .failed(let m): return m
        case .idle: return "Not checked yet."
        }
    }

    private var statusColor: Color {
        switch updater.state {
        case .available: return Theme.accent
        case .upToDate: return .green
        case .failed: return .orange
        default: return .secondary
        }
    }

    private func row(_ k: String, _ v: String) -> some View {
        HStack {
            Text(k).foregroundStyle(.secondary).frame(width: 90, alignment: .leading)
            Text(v)
        }.font(.system(size: 12))
    }
}
