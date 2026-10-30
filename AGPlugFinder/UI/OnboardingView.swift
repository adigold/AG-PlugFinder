import AppKit
import SwiftUI

/// First-run tour (BL-11). Shown before the app starts working: it gets Logic control
/// (Accessibility) approved, sets open at login, optionally takes the API key, and only then
/// scans the plugins and takes the screenshots.
@MainActor
final class OnboardingWindow {
    static let shared = OnboardingWindow()
    static let doneKey = "onboardingDone"

    static var isDone: Bool { UserDefaults.standard.bool(forKey: doneKey) }

    private lazy var window: NSWindow = {
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 500),
                         styleMask: [.titled, .closable, .fullSizeContentView],
                         backing: .buffered, defer: false)
        w.titlebarAppearsTransparent = true
        w.titleVisibility = .hidden
        w.isMovableByWindowBackground = true
        w.isReleasedWhenClosed = false
        w.contentView = NSHostingView(rootView: OnboardingView())
        w.center()
        return w
    }()

    func show() {
        window.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }

    func finish() {
        UserDefaults.standard.set(true, forKey: Self.doneKey)
        window.orderOut(nil)
    }
}

struct OnboardingView: View {
    enum Step: Int, CaseIterable { case welcome, logic, login, info, scan }

    @State private var step: Step = .welcome
    @State private var trusted = AXAccess.isTrusted
    @State private var launchAtLogin = true
    @State private var apiKey = ""
    @State private var keySaved = Keychain.read() != nil
    @State private var scanStarted = false
    var queue = SnapshotQueue.shared

    var body: some View {
        VStack(spacing: 0) {
            progressDots.padding(.top, 22)
            Group {
                switch step {
                case .welcome: welcome
                case .logic: logic
                case .login: login
                case .info: info
                case .scan: scan
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(.horizontal, 48)
            .transition(.asymmetric(insertion: .move(edge: .trailing).combined(with: .opacity),
                                    removal: .opacity))
            footer
        }
        .frame(width: 640, height: 500)
        .background(
            LinearGradient(colors: [Theme.accent.opacity(0.10), Color.clear],
                           startPoint: .top, endPoint: .center))
        .onReceive(Timer.publish(every: 1, on: .main, in: .common).autoconnect()) { _ in
            trusted = AXAccess.isTrusted
        }
    }

    // MARK: Steps

    private var welcome: some View {
        VStack(spacing: 18) {
            Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 96, height: 96)
                .shadow(color: .black.opacity(0.2), radius: 10, y: 4)
            Text("Welcome to AG PlugFinder").font(.system(size: 26, weight: .bold))
            Text("Find any plugin by sight and drop it on your Logic track in a second.")
                .font(.system(size: 14)).foregroundStyle(.secondary).multilineTextAlignment(.center)
            VStack(alignment: .leading, spacing: 10) {
                bullet("magnifyingglass", "Search every Audio Unit and Logic plugin, with a picture of each one")
                bullet("keyboard", "Press \(HotKey.display) anywhere, type, press Return")
                bullet("plus.rectangle.on.rectangle", "It lands in the first empty insert of your selected track")
            }
            .padding(.top, 6)
            Text("Two quick permissions first, then you're ready.")
                .font(.system(size: 12)).foregroundStyle(.secondary).padding(.top, 4)
        }
    }

    private var logic: some View {
        VStack(spacing: 16) {
            stepIcon("hand.raised.fill")
            Text("Let AG PlugFinder work with Logic").font(.system(size: 22, weight: .bold))
            Text("To place a plugin in an insert slot, the app needs Accessibility access. It only opens Logic's plug-in menu and picks the plugin you chose. Nothing else.")
                .font(.system(size: 13)).foregroundStyle(.secondary).multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            if trusted {
                statusChip("checkmark.circle.fill", "Access allowed", .green)
            } else {
                Button {
                    AXAccess.requestTrust()
                    AXAccess.openSettings()
                } label: {
                    Label("Open System Settings", systemImage: "gearshape")
                        .font(.system(size: 14, weight: .semibold))
                        .padding(.horizontal, 18).frame(height: 38)
                        .background(RoundedRectangle(cornerRadius: 10).fill(Theme.accent))
                        .foregroundStyle(Color.black)
                }
                .buttonStyle(.plain)
                VStack(alignment: .leading, spacing: 6) {
                    numbered(1, "Click Open System Settings")
                    numbered(2, "Turn on AG PlugFinder in the Accessibility list")
                    numbered(3, "Come back here, this page turns green by itself")
                }
                .padding(14)
                .background(RoundedRectangle(cornerRadius: 12).fill(Color.primary.opacity(0.05)))
                statusChip("clock", "Waiting for access…", .orange)
            }
        }
    }

    private var login: some View {
        VStack(spacing: 16) {
            stepIcon("power")
            Text("Ready whenever Logic is").font(.system(size: 22, weight: .bold))
            Text("AG PlugFinder sits quietly in the menu bar so \(HotKey.display) always works. Start it when you log in?")
                .font(.system(size: 13)).foregroundStyle(.secondary).multilineTextAlignment(.center)
            Toggle(isOn: $launchAtLogin) {
                Text("Open at login").font(.system(size: 14, weight: .medium))
            }
            .toggleStyle(.switch)
            .padding(14)
            .background(RoundedRectangle(cornerRadius: 12).fill(Color.primary.opacity(0.05)))
            Text("You can change this any time in Settings.")
                .font(.system(size: 11)).foregroundStyle(.secondary)
        }
    }

    private var info: some View {
        VStack(spacing: 14) {
            stepIcon("sparkles")
            Text("Plugin info (optional)").font(.system(size: 22, weight: .bold))
            Text("With an Anthropic API key, AG PlugFinder can look up what each plugin does and its best feature. You choose when; each plugin is looked up once.")
                .font(.system(size: 13)).foregroundStyle(.secondary).multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            if keySaved {
                statusChip("checkmark.circle.fill", "Key saved in your Keychain", .green)
            } else {
                HStack {
                    SecureField("Anthropic API key (sk-ant-…)", text: $apiKey)
                        .textFieldStyle(.roundedBorder)
                    Button("Save") { keySaved = Keychain.save(apiKey) && !apiKey.isEmpty; apiKey = "" }
                        .disabled(apiKey.isEmpty)
                }
                Text("No key? Skip this step. Everything else works without it.")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }
        }
    }

    private var scan: some View {
        VStack(spacing: 16) {
            stepIcon("camera.viewfinder")
            Text(scanStarted && !queue.isRunning ? "All set" : "Find your plugins")
                .font(.system(size: 22, weight: .bold))
            if !scanStarted {
                Text("AG PlugFinder will list your plugins and take a picture of each one. Each plugin opens for a moment in the bottom left corner of the screen. This happens once.")
                    .font(.system(size: 13)).foregroundStyle(.secondary).multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            } else if queue.isRunning {
                ProgressView(value: Double(queue.done), total: Double(max(1, queue.total)))
                    .tint(Theme.accent)
                Text("\(queue.done) of \(queue.total): \(queue.currentName)")
                    .font(.system(size: 12)).foregroundStyle(.secondary).monospacedDigit()
            } else {
                Text("\(PluginStore.shared.plugins.count) plugins ready. In Logic, select a track and press \(HotKey.display).")
                    .font(.system(size: 14)).multilineTextAlignment(.center)
            }
        }
    }

    // MARK: Footer

    private var footer: some View {
        HStack {
            if step != .welcome {
                Button("Back") { go(-1) }.buttonStyle(.plain).foregroundStyle(.secondary)
            }
            Spacer()
            if step == .logic && !trusted {
                Button("Skip for now") { go(1) }.buttonStyle(.plain).foregroundStyle(.secondary)
                    .padding(.trailing, 10)
            }
            if step == .info && !keySaved {
                Button("Skip") { go(1) }.buttonStyle(.plain).foregroundStyle(.secondary)
                    .padding(.trailing, 10)
            }
            primaryButton
        }
        .padding(.horizontal, 28).padding(.bottom, 22)
    }

    private var primaryButton: some View {
        let title: String
        var disabled = false
        switch step {
        case .welcome: title = "Get Started"
        case .logic: title = "Continue"; disabled = !trusted
        case .login: title = "Continue"
        case .info: title = "Continue"
        case .scan:
            if !scanStarted { title = "Scan My Plugins" }
            else if queue.isRunning { title = "Working…"; disabled = true }
            else { title = "Start Using AG PlugFinder" }
        }
        return Button(action: primary) {
            Text(title).font(.system(size: 14, weight: .semibold))
                .padding(.horizontal, 20).frame(height: 36)
                .background(RoundedRectangle(cornerRadius: 10)
                    .fill(disabled ? Color.primary.opacity(0.1) : Theme.accent))
                .foregroundStyle(disabled ? Color.secondary : Color.black)
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .keyboardShortcut(.defaultAction)
    }

    private func primary() {
        switch step {
        case .login:
            LaunchAtLogin.set(launchAtLogin)
            go(1)
        case .scan:
            if !scanStarted {
                scanStarted = true
                PluginStore.shared.rescan()
                SnapshotQueue.shared.start()
            } else if !queue.isRunning {
                OnboardingWindow.shared.finish()
            }
        default:
            go(1)
        }
    }

    private func go(_ delta: Int) {
        guard let next = Step(rawValue: step.rawValue + delta) else { return }
        withAnimation(.easeOut(duration: 0.25)) { step = next }
    }

    // MARK: Pieces

    private var progressDots: some View {
        HStack(spacing: 6) {
            ForEach(Step.allCases, id: \.rawValue) { s in
                Capsule()
                    .fill(s.rawValue <= step.rawValue ? Theme.accent : Color.primary.opacity(0.12))
                    .frame(width: s == step ? 22 : 8, height: 8)
            }
        }
        .animation(.easeOut(duration: 0.25), value: step)
    }

    private func stepIcon(_ name: String) -> some View {
        Image(systemName: name)
            .font(.system(size: 30, weight: .semibold))
            .foregroundStyle(Theme.accent)
            .frame(width: 68, height: 68)
            .background(Circle().fill(Theme.accent.opacity(0.15)))
    }

    private func bullet(_ icon: String, _ text: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon).foregroundStyle(Theme.accent).frame(width: 22)
            Text(text).font(.system(size: 13))
        }
    }

    private func numbered(_ n: Int, _ text: String) -> some View {
        HStack(spacing: 10) {
            Text("\(n)").font(.system(size: 11, weight: .bold))
                .frame(width: 20, height: 20).background(Circle().fill(Theme.accent.opacity(0.25)))
            Text(text).font(.system(size: 12))
        }
    }

    private func statusChip(_ icon: String, _ text: String, _ color: Color) -> some View {
        Label(text, systemImage: icon)
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(color)
            .padding(.horizontal, 12).padding(.vertical, 6)
            .background(Capsule().fill(color.opacity(0.12)))
    }
}
