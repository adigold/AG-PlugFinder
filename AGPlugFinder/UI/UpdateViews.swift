import SwiftUI

/// "Update available" / "What's new" strip under the top bar of the library window.
struct UpdateBanner: View {
    var updater = Updater.shared

    var body: some View {
        if let r = updater.available {
            strip(dot: Theme.accent, title: "A new update is available: version \(r.version)", notes: r.notes, badge: true) {
                QuietPill(title: "What's New") { WhatsNewWindow.shared.show(version: r.version, notes: r.notes) }
                PrimaryPill(title: "Install and Restart", height: 30) { updater.install() }
            }
        } else if updater.busy {
            strip(dot: Theme.accent, title: "Updating AG PlugFinder…", notes: []) {
                QuietPill(title: "Show Progress") { UpdateWindow.shared.show() }
            }
        } else if case .failed(let msg) = updater.state, msg != "No update address is set for this build." {
            strip(dot: Theme.warning, title: "The update did not install", notes: [msg]) {
                QuietPill(title: "Try Again") { Task { await updater.check(userInitiated: true) } }
            }
        } else if let w = updater.whatsNew {
            strip(dot: Theme.accent, title: "You're updated to \(w.version)", notes: w.notes, badge: true) {
                QuietPill(title: "What's New") { WhatsNewWindow.shared.show(version: w.version, notes: w.notes, justUpdated: true) }
                QuietPill(title: "Got It") { updater.whatsNew = nil }
            }
        }
    }

    private func strip<A: View>(dot: Color, title: String, notes: [String], badge: Bool = false,
                                @ViewBuilder action: () -> A) -> some View {
        HStack(alignment: .center, spacing: 14) {
            if badge { NewBadge() } else { Circle().fill(dot).frame(width: 8, height: 8) }
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.text)
                if !notes.isEmpty {
                    Text(badge ? ReleaseNote.parse(notes).prefix(4).map(\.title).joined(separator: "  ·  ")
                               : notes.prefix(3).joined(separator: "  ·  "))
                        .font(.system(size: 12)).foregroundStyle(Theme.muted).lineLimit(1)
                }
            }
            Spacer()
            action()
        }
        .padding(.horizontal, 18).padding(.vertical, 12)
        .background(Theme.surface)
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
        case .verifying: return "Checking the download…"
        case .installing: return "Installing…"
        case .restarting: return "Restarting…"
        case .failed(let m): return m
        }
    }
}

/// Top right of the main window: the installed version and the update status.
/// Click it for Versions: installed and latest version, Check for Update, what's new, install.
struct VersionBadge: View {
    var updater = Updater.shared
    @State private var showVersions = false
    @State private var hovering = false

    var body: some View {
        Button { showVersions.toggle() } label: {
            HStack(spacing: 7) {
                if updater.available != nil {
                    NewBadge()
                } else if updater.state == .checking {
                    ProgressView().controlSize(.mini)
                } else {
                    Image(systemName: updater.state == .upToDate ? "checkmark" : "arrow.triangle.2.circlepath")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(Theme.faint)
                }
                Text(label).font(.system(size: 12, weight: .medium))
                    .foregroundStyle(updater.available != nil ? Theme.text : Theme.muted)
            }
            .padding(.horizontal, 12).frame(height: 28)
            .background(Capsule().fill(updater.available != nil || hovering ? Theme.raised : Color.clear))
            .contentShape(Capsule())
        }
        .buttonStyle(PressScale())
        .onHover { hovering = $0 }
        .help("Versions and updates")
        .popover(isPresented: $showVersions, arrowEdge: .bottom) { VersionsPanel() }
    }

    private var label: String {
        switch updater.state {
        case .available: return "A new update is available"
        case .upToDate: return "v\(updater.currentVersion) · You're updated."
        case .checking: return "Checking…"
        case .downloading: return "Downloading \(Int(updater.progress * 100))%"
        case .verifying, .installing, .restarting: return "Installing…"
        default: return "v\(updater.currentVersion) · Check for update"
        }
    }
}

/// The Versions popover.
struct VersionsPanel: View {
    var updater = Updater.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 10) {
                BrandMark(size: 18)
                Text("AG PlugFinder").font(.system(size: 16, weight: .semibold)).foregroundStyle(Theme.text)
            }
            Text(status)
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(Theme.text)
            VStack(spacing: 0) {
                row("Installed", "v\(updater.currentVersion)")
                if let r = updater.available { row("Latest", "v\(r.version)", dot: true) }
                if let d = updater.lastChecked {
                    row("Last checked", d.formatted(date: .abbreviated, time: .shortened))
                }
            }
            if let r = updater.available, !r.notes.isEmpty {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 8) {
                        Text("What's new in \(r.version)").font(.system(size: 12)).foregroundStyle(Theme.faint)
                        NewBadge()
                    }
                    ForEach(ReleaseNote.parse(r.notes).prefix(3)) { n in
                        HStack(alignment: .top, spacing: 10) {
                            Image(systemName: n.icon).font(.system(size: 13, weight: .medium))
                                .foregroundStyle(Theme.accent).frame(width: 18)
                            Text(n.title).font(.system(size: 13, weight: .medium)).foregroundStyle(Theme.text)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    Button { WhatsNewWindow.shared.show(version: r.version, notes: r.notes) } label: {
                        Text("See all \(r.notes.count) changes").font(.system(size: 12, weight: .medium))
                            .foregroundStyle(Theme.accent)
                    }
                    .buttonStyle(.plain)
                }
            }
            HStack(spacing: 8) {
                if updater.available != nil {
                    PrimaryPill(title: "Install and Restart", height: 32) { updater.install() }
                }
                QuietPill(title: updater.state == .checking ? "Checking…" : "Check for Update", height: 32) {
                    Task { await updater.check(userInitiated: true) }
                }
                .disabled(updater.state == .checking || updater.busy)
            }
        }
        .padding(22)
        .frame(width: 340, alignment: .leading)
        .background(Theme.surface)
        .preferredColorScheme(.dark)
    }

    private var status: String {
        switch updater.state {
        case .available: return "A new update is available."
        case .upToDate: return "You're updated."
        case .checking: return "Checking for updates…"
        case .downloading: return "Downloading the update…"
        case .verifying: return "Checking the download…"
        case .installing: return "Installing…"
        case .restarting: return "Restarting…"
        case .failed(let m): return m
        case .idle: return "Not checked yet."
        }
    }

    private func row(_ k: String, _ v: String, dot: Bool = false) -> some View {
        VStack(spacing: 0) {
            Rectangle().fill(Theme.rule).frame(height: 1)
            HStack {
                Text(k).foregroundStyle(Theme.faint)
                Spacer()
                if dot { Circle().fill(Theme.accent).frame(width: 6, height: 6) }
                Text(v).foregroundStyle(Theme.text).monospacedDigit()
            }
            .font(.system(size: 13))
            .padding(.vertical, 9)
        }
    }
}
