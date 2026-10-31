import AppKit
import SwiftUI

/// The update window (BL-24): what is new, live download progress and each step, then the app
/// restarts by itself. After the restart the new version opens it again as "You're updated".
@MainActor
final class UpdateWindow {
    static let shared = UpdateWindow()

    private lazy var window: NSWindow = {
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 520, height: 560),
                         styleMask: [.titled, .closable, .fullSizeContentView],
                         backing: .buffered, defer: false)
        w.titlebarAppearsTransparent = true
        w.titleVisibility = .hidden
        w.isMovableByWindowBackground = true
        w.isReleasedWhenClosed = false
        w.backgroundColor = .black
        w.appearance = NSAppearance(named: .darkAqua)
        w.contentView = NSHostingView(rootView: UpdateProgressView())
        w.center()
        return w
    }()

    func show() {
        window.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }

    func hide() { window.orderOut(nil) }
}

struct UpdateProgressView: View {
    var updater = Updater.shared

    private enum Step: Int, CaseIterable {
        case download, verify, install, restart
        var title: String {
            switch self {
            case .download: return "Downloading"
            case .verify: return "Checking it is the genuine app"
            case .install: return "Installing"
            case .restart: return "Restarting"
            }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            header
            if let w = updater.whatsNew, !updater.busy, release == nil {
                notesList(w.notes)
                Spacer(minLength: 0)
                HStack { Spacer(); PrimaryPill(title: "Start Using It") { done() } }
            } else {
                steps
                if let r = release, !r.notes.isEmpty { notesList(r.notes) }
                Spacer(minLength: 0)
                footer
            }
        }
        .padding(.horizontal, 32).padding(.top, 40).padding(.bottom, 26)
        .frame(width: 520, height: 560, alignment: .topLeading)
        .background(Theme.ground)
        .preferredColorScheme(.dark)
        .animation(.easeOut(duration: 0.25), value: updater.state)
    }

    private var release: Updater.Release? { updater.installing ?? updater.available }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 16) {
            Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 64, height: 64)
            VStack(alignment: .leading, spacing: 5) {
                Text(title).font(.system(size: 22, weight: .bold)).foregroundStyle(Theme.text)
                Text(subtitle).font(.system(size: 13)).foregroundStyle(Theme.muted).monospacedDigit()
            }
        }
    }

    private var title: String {
        switch updater.state {
        case .restarting: return "Restarting…"
        case .failed: return "The update did not install"
        default:
            if updater.whatsNew != nil, release == nil { return "You're updated." }
            return updater.busy ? "Updating AG PlugFinder" : "A new update is available."
        }
    }

    private var subtitle: String {
        if let w = updater.whatsNew, release == nil { return "Now on version \(w.version)" }
        guard let r = release else { return "Version \(updater.currentVersion)" }
        return "Version \(updater.currentVersion)  →  \(r.version)"
    }

    // MARK: Steps

    private var current: Step? {
        switch updater.state {
        case .downloading: return .download
        case .verifying: return .verify
        case .installing: return .install
        case .restarting: return .restart
        default: return nil
        }
    }

    private var steps: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Step.allCases, id: \.rawValue) { step in
                HStack(spacing: 12) {
                    icon(for: step).frame(width: 20, height: 20)
                    Text(step.title)
                        .font(.system(size: 14, weight: step == current ? .semibold : .regular))
                        .foregroundStyle(state(of: step) == .waiting ? Theme.faint : Theme.text)
                    Spacer()
                    if step == .download, updater.state == .downloading {
                        Text(downloadText).font(.system(size: 12)).foregroundStyle(Theme.muted).monospacedDigit()
                    }
                }
                .padding(.vertical, 11)
                if step == .download, updater.state == .downloading {
                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            Capsule().fill(Theme.raised)
                            Capsule().fill(Theme.accent)
                                .frame(width: max(6, geo.size.width * updater.progress))
                                .animation(.easeOut(duration: 0.2), value: updater.progress)
                        }
                    }
                    .frame(height: 6)
                    .padding(.leading, 32).padding(.bottom, 10)
                }
                if step != .restart { Rectangle().fill(Theme.rule).frame(height: 1).padding(.leading, 32) }
            }
            if case .failed(let why) = updater.state {
                Text(why).font(.system(size: 13)).foregroundStyle(Theme.negative)
                    .padding(.top, 12).fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, 18).padding(.vertical, 8)
        .background(RoundedRectangle(cornerRadius: Theme.radiusInner).fill(Theme.surface))
    }

    private enum StepState { case waiting, active, done }

    private func state(of step: Step) -> StepState {
        guard let current else {
            return updater.state.isFailed || updater.available != nil ? .waiting : .waiting
        }
        if step.rawValue < current.rawValue { return .done }
        return step == current ? .active : .waiting
    }

    @ViewBuilder
    private func icon(for step: Step) -> some View {
        switch state(of: step) {
        case .done:
            Image(systemName: "checkmark.circle.fill").font(.system(size: 17)).foregroundStyle(Theme.accent)
        case .active:
            ProgressView().controlSize(.small)
        case .waiting:
            Circle().strokeBorder(Color(white: 0.3), lineWidth: 1.5).frame(width: 16, height: 16)
        }
    }

    private var downloadText: String {
        let total = release?.size ?? 0
        let f = ByteCountFormatter()
        f.countStyle = .file
        return total > 0
            ? "\(f.string(fromByteCount: updater.receivedBytes)) of \(f.string(fromByteCount: total))"
            : f.string(fromByteCount: updater.receivedBytes)
    }

    // MARK: Notes and buttons

    private func notesList(_ notes: [String]) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            Text("What's new").font(.system(size: 12)).foregroundStyle(Theme.faint)
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(ReleaseNote.parse(notes)) { n in
                        HStack(alignment: .top, spacing: 12) {
                            Image(systemName: n.icon).font(.system(size: 13, weight: .medium))
                                .foregroundStyle(n.kind == .new ? Theme.accent : Theme.muted).frame(width: 18)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(n.title).font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.text)
                                if !n.detail.isEmpty {
                                    Text(n.detail).font(.system(size: 12)).foregroundStyle(Theme.muted)
                                }
                            }
                            .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    @ViewBuilder
    private var footer: some View {
        HStack {
            if updater.state.isFailed {
                QuietPill(title: "Close") { UpdateWindow.shared.hide() }
                Spacer()
                PrimaryPill(title: "Try Again") { updater.install() }
            } else if updater.busy {
                Text("AG PlugFinder will close and open again by itself.")
                    .font(.system(size: 12)).foregroundStyle(Theme.faint)
                Spacer()
            } else {
                QuietPill(title: "Later") { UpdateWindow.shared.hide() }
                Spacer()
                PrimaryPill(title: "Install and Restart") { updater.install() }
            }
        }
    }

    private func done() {
        updater.whatsNew = nil
        UpdateWindow.shared.hide()
    }
}
