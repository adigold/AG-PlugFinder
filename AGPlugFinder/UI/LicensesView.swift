import AppKit
import SwiftUI

// MARK: - Small fields

private func fieldLabel(_ text: String) -> some View {
    Text(text).font(.system(size: 11)).foregroundStyle(Theme.faint)
}

/// A one-line text field in the app's style.
struct LicenseTextField: View {
    let placeholder: String
    @Binding var text: String
    var width: CGFloat? = nil

    var body: some View {
        TextField(placeholder, text: $text)
            .textFieldStyle(.plain)
            .font(.system(size: 13))
            .padding(.horizontal, 10).frame(height: 30)
            .frame(width: width)
            .frame(maxWidth: width == nil ? .infinity : nil)
            .background(RoundedRectangle(cornerRadius: 8).fill(Theme.raised))
    }
}

/// An amount in the chosen currency; empty means not entered.
struct MoneyField: View {
    @Binding var value: Double?
    var placeholder = "0"
    var lic = Licenses.shared
    @State private var text = ""

    var body: some View {
        HStack(spacing: 4) {
            Text(lic.symbol).font(.system(size: 13)).foregroundStyle(Theme.faint)
            TextField(placeholder, text: $text)
                .textFieldStyle(.plain).font(.system(size: 13)).monospacedDigit()
                .onChange(of: text) { _, t in
                    let clean = t.replacingOccurrences(of: ",", with: ".").filter { "0123456789.".contains($0) }
                    value = clean.isEmpty ? nil : Double(clean)
                }
        }
        .padding(.horizontal, 10).frame(width: 120, height: 30)
        .background(RoundedRectangle(cornerRadius: 8).fill(Theme.raised))
        .onAppear { text = value.map { $0.rounded() == $0 ? String(Int($0)) : String(format: "%.2f", $0) } ?? "" }
    }
}

/// A date that may be left empty.
struct OptionalDate: View {
    let title: String
    @Binding var date: Date?
    var start: () -> Date = { Calendar.current.startOfDay(for: Date()) }

    var body: some View {
        if let d = date {
            HStack(spacing: 6) {
                DatePicker("", selection: Binding(get: { d }, set: { date = $0 }), displayedComponents: .date)
                    .labelsHidden().datePickerStyle(.field).frame(width: 120)
                Button { date = nil } label: {
                    Image(systemName: "xmark.circle.fill").font(.system(size: 13)).foregroundStyle(Theme.faint)
                }
                .buttonStyle(.plain).help("Clear the date")
            }
        } else {
            Chip(title: title, systemImage: "calendar", on: false) { date = start() }
        }
    }
}

/// A license key or serial, kept in the Keychain. Hidden until Show is pressed.
struct LicenseKeyField: View {
    let id: String
    @State private var key = ""
    @State private var shown = false
    @State private var loaded = false

    var body: some View {
        HStack(spacing: 6) {
            Group {
                if shown { TextField("Serial or license key", text: $key) }
                else { SecureField("Serial or license key", text: $key) }
            }
            .textFieldStyle(.plain).font(.system(size: 13, design: .monospaced))
            .padding(.horizontal, 10).frame(height: 30)
            .background(RoundedRectangle(cornerRadius: 8).fill(Theme.raised))
            .onChange(of: key) { _, v in if loaded { LicenseKeys.save(v, for: id) } }
            BarIconButton(systemImage: shown ? "eye.slash" : "eye", help: shown ? "Hide" : "Show") { shown.toggle() }
            BarIconButton(systemImage: "doc.on.doc", help: "Copy") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(key, forType: .string)
                Toast.show("Copied")
            }
            .disabled(key.isEmpty)
        }
        .onAppear {
            key = LicenseKeys.read(id) ?? ""
            DispatchQueue.main.async { loaded = true }
        }
    }
}

// MARK: - One plugin's license (in the info panel and its own window)

struct LicenseSection: View {
    let plugin: Plugin
    var showsTitle = true
    var lic = Licenses.shared

    private var info: Binding<LicenseInfo> {
        Binding(get: { lic.license(plugin.id) }, set: { lic.set($0, for: plugin.id) })
    }

    var body: some View {
        let l = info.wrappedValue
        VStack(alignment: .leading, spacing: 10) {
            if showsTitle {
                HStack {
                    Text("License").font(.system(size: 12)).foregroundStyle(Theme.faint)
                    Spacer()
                    Button("All licenses") { LicensesWindow.shared.show() }
                        .buttonStyle(.plain).font(.system(size: 11)).foregroundStyle(Theme.muted)
                }
            }
            FlowRow(spacing: 6) {
                ForEach(LicenseInfo.Status.allCases) { s in
                    Chip(title: s.title, on: l.status == s) {
                        var n = l
                        n.status = l.status == s ? nil : s
                        if n.status != .subscription && n.status != .bundle { n.planID = nil }
                        info.wrappedValue = n
                    }
                }
            }
            if let s = l.status {
                details(s, l)
            }
        }
    }

    @ViewBuilder private func details(_ s: LicenseInfo.Status, _ l: LicenseInfo) -> some View {
        if s == .subscription || s == .bundle {
            planChooser(kind: s == .subscription ? .subscription : .bundle, l)
        }
        if s == .trial {
            HStack(spacing: 10) {
                fieldLabel("Trial ends").frame(width: 78, alignment: .leading)
                OptionalDate(title: "Set the date", date: info.trialEnds) {
                    Calendar.current.date(byAdding: .day, value: 14, to: Calendar.current.startOfDay(for: Date())) ?? Date()
                }
            }
        }
        if s == .owned || s == .trial || s == .free {
            HStack(spacing: 10) {
                if s == .owned {
                    VStack(alignment: .leading, spacing: 4) { fieldLabel("Paid"); MoneyField(value: info.price) }
                }
                if s != .free {
                    VStack(alignment: .leading, spacing: 4) {
                        fieldLabel("Worth today"); MoneyField(value: info.value, placeholder: "List price")
                    }
                }
                if s == .owned {
                    VStack(alignment: .leading, spacing: 4) { fieldLabel("Bought"); OptionalDate(title: "Date", date: info.bought) }
                }
            }
        }
        if s == .subscription || s == .bundle {
            VStack(alignment: .leading, spacing: 4) {
                fieldLabel("Worth today, if bought alone"); MoneyField(value: info.value, placeholder: "List price")
            }
        }
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 4) {
                fieldLabel("Bought from"); LicenseTextField(placeholder: "Store or website", text: info.store)
            }
            VStack(alignment: .leading, spacing: 4) {
                fieldLabel("Account"); LicenseTextField(placeholder: "Email or user name", text: info.account)
            }
        }
        VStack(alignment: .leading, spacing: 4) {
            fieldLabel("License key"); LicenseKeyField(id: plugin.id)
        }
        VStack(alignment: .leading, spacing: 4) {
            fieldLabel("License notes"); LicenseTextField(placeholder: "For example 2 activations, upgrade price available", text: info.notes)
        }
    }

    private func planChooser(kind: LicensePlan.Kind, _ l: LicenseInfo) -> some View {
        let list = lic.plans.filter { $0.kind == kind }
        return VStack(alignment: .leading, spacing: 6) {
            fieldLabel(kind == .subscription ? "Which subscription" : "Which bundle")
            FlowRow(spacing: 6) {
                ForEach(list) { p in
                    Chip(title: p.name, on: l.planID == p.id) {
                        var n = l
                        n.planID = l.planID == p.id ? nil : p.id
                        info.wrappedValue = n
                    }
                }
                Chip(title: kind == .subscription ? "New subscription" : "New bundle", systemImage: "plus", on: false) {
                    if let p = lic.newPlan(kind, adding: [plugin.id]) { PlanWindow.show(p.id) }
                }
            }
            if let p = lic.plan(l.planID) {
                Button { PlanWindow.show(p.id) } label: {
                    HStack(spacing: 6) {
                        Text(PlanSummary.line(p)).font(.system(size: 12)).foregroundStyle(Theme.muted)
                        Text("Edit").font(.system(size: 12, weight: .medium)).foregroundStyle(Theme.text)
                    }
                }
                .buttonStyle(.plain)
            }
        }
    }
}

@MainActor
enum PlanSummary {
    static func line(_ p: LicensePlan) -> String {
        let lic = Licenses.shared
        let n = lic.plugins(in: p).count
        var parts: [String] = []
        if let c = p.cost { parts.append(p.isSubscription ? "\(lic.money(c)) \(p.period.unit)" : "Paid \(lic.money(c))") }
        if p.isSubscription {
            if !p.active { parts.append("Cancelled") }
            else if let d = p.nextRenewal { parts.append("renews \(d.formatted(date: .abbreviated, time: .omitted))") }
        }
        parts.append("\(n) plugin\(n == 1 ? "" : "s")")
        return parts.joined(separator: " · ")
    }
}

// MARK: - A subscription or bundle

@MainActor
enum PlanWindow {
    private static var windows: [String: NSWindow] = [:]

    static func show(_ id: String) {
        let w = windows[id] ?? {
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 520, height: 600),
                             styleMask: [.titled, .closable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
            w.titlebarAppearsTransparent = true
            w.titleVisibility = .hidden
            w.isMovableByWindowBackground = true
            w.isReleasedWhenClosed = false
            w.backgroundColor = .black
            w.appearance = NSAppearance(named: .darkAqua)
            w.contentView = NSHostingView(rootView: PlanEditor(id: id) { windows[id]?.close() })
            w.center()
            windows[id] = w
            return w
        }()
        w.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }

    static func close(_ id: String) { windows[id]?.close(); windows[id] = nil }
}

struct PlanEditor: View {
    let id: String
    var close: () -> Void
    var lic = Licenses.shared
    @State private var confirmDelete = false

    private var plan: Binding<LicensePlan> {
        Binding(get: { lic.plan(id) ?? LicensePlan(name: "", kind: .subscription) },
                set: { new in if let i = lic.plans.firstIndex(where: { $0.id == id }) { lic.plans[i] = new } })
    }

    var body: some View {
        let p = plan.wrappedValue
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text(p.isSubscription ? "Subscription" : "Bundle").font(.system(size: 12)).foregroundStyle(Theme.faint)
                TextField("Name", text: plan.name)
                    .textFieldStyle(.plain).font(.system(size: 22, weight: .bold)).foregroundStyle(Theme.text)
                HStack(spacing: 6) {
                    Chip(title: "Subscription", on: p.isSubscription) { plan.wrappedValue.kind = .subscription; relabel(.subscription) }
                    Chip(title: "Bundle", on: !p.isSubscription) { plan.wrappedValue.kind = .bundle; relabel(.bundle) }
                }
                if p.isSubscription { subscription(p) } else { bundle }
                HStack(spacing: 8) {
                    VStack(alignment: .leading, spacing: 4) {
                        fieldLabel("Bought from"); LicenseTextField(placeholder: "Store or website", text: plan.store)
                    }
                    VStack(alignment: .leading, spacing: 4) {
                        fieldLabel("Account"); LicenseTextField(placeholder: "Email or user name", text: plan.account)
                    }
                }
                VStack(alignment: .leading, spacing: 4) { fieldLabel("License key"); LicenseKeyField(id: id) }
                VStack(alignment: .leading, spacing: 4) {
                    fieldLabel("Notes"); LicenseTextField(placeholder: "For example cancel in the account page", text: plan.notes)
                }
                pluginList
                HStack {
                    Button("Delete \(p.isSubscription ? "Subscription" : "Bundle")") { confirmDelete = true }
                        .buttonStyle(.plain).font(.system(size: 12)).foregroundStyle(Theme.negative)
                    Spacer()
                    PrimaryPill(title: "Done") { close() }
                }
            }
            .padding(.horizontal, 26).padding(.top, 40).padding(.bottom, 22)
        }
        .frame(minWidth: 480, minHeight: 480)
        .background(Theme.ground)
        .preferredColorScheme(.dark)
        .alert("Delete \(p.name)?", isPresented: $confirmDelete) {
            Button("Delete", role: .destructive) { lic.deletePlan(id); PlanWindow.close(id) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The plugins in it stay, without this \(p.isSubscription ? "subscription" : "bundle").")
        }
    }

    /// Plugins follow their plan's kind.
    private func relabel(_ kind: LicensePlan.Kind) {
        let ids = lic.licenses.filter { $0.value.planID == id }.map(\.key)
        lic.add(ids, to: id)
    }

    private func subscription(_ p: LicensePlan) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .bottom, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) { fieldLabel("Cost each renewal"); MoneyField(value: plan.cost) }
                HStack(spacing: 6) {
                    ForEach(LicensePlan.Period.allCases) { per in
                        Chip(title: per.title, on: p.period == per) { plan.wrappedValue.period = per }
                    }
                }
            }
            HStack(alignment: .top, spacing: 10) {
                VStack(alignment: .leading, spacing: 4) {
                    fieldLabel("Next renewal")
                    OptionalDate(title: "Set the date", date: plan.nextRenewal)
                }
                VStack(alignment: .leading, spacing: 4) {
                    fieldLabel("Started"); OptionalDate(title: "Date", date: plan.bought)
                }
            }
            VStack(alignment: .leading, spacing: 6) {
                fieldLabel("Remind me before it renews")
                HStack(spacing: 6) {
                    ForEach([0, 1, 3, 7, 14, 30], id: \.self) { d in
                        Chip(title: d == 0 ? "Only on the day" : "\(d) day\(d == 1 ? "" : "s")", on: p.remindDays == d) {
                            plan.wrappedValue.remindDays = d
                        }
                    }
                }
            }
            HStack(spacing: 10) {
                OnOffSwitch(on: p.active) { plan.wrappedValue.active.toggle() }
                Text(p.active ? "Active, renews by itself" : "Cancelled, no reminders and not counted")
                    .font(.system(size: 12)).foregroundStyle(Theme.muted)
            }
        }
    }

    private var bundle: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 4) { fieldLabel("Paid"); MoneyField(value: plan.cost) }
            VStack(alignment: .leading, spacing: 4) { fieldLabel("Worth today"); MoneyField(value: plan.value, placeholder: "List price") }
            VStack(alignment: .leading, spacing: 4) { fieldLabel("Bought"); OptionalDate(title: "Date", date: plan.bought) }
        }
    }

    private var pluginList: some View {
        let list = lic.plugins(in: plan.wrappedValue)
        return VStack(alignment: .leading, spacing: 6) {
            fieldLabel(list.isEmpty ? "No plugins yet. In the library, select plugins and choose License, then Add to this."
                                    : "\(list.count) plugin\(list.count == 1 ? "" : "s") in it")
            if !list.isEmpty {
                VStack(spacing: 0) {
                    ForEach(list) { pl in
                        HStack {
                            Text(pl.name).font(.system(size: 12)).foregroundStyle(Theme.text)
                            Text(pl.manufacturer).font(.system(size: 11)).foregroundStyle(Theme.faint)
                            Spacer()
                            Button { var l = lic.license(pl.id); l.planID = nil; lic.set(l, for: pl.id) } label: {
                                Image(systemName: "xmark").font(.system(size: 10, weight: .semibold)).foregroundStyle(Theme.faint)
                            }
                            .buttonStyle(.plain).help("Take it out")
                        }
                        .padding(.horizontal, 12).frame(height: 28)
                    }
                }
                .background(RoundedRectangle(cornerRadius: Theme.radiusInner).fill(Theme.surface))
            }
        }
    }
}

// MARK: - The Licenses window

@MainActor
final class LicensesWindow {
    static let shared = LicensesWindow()
    private var window: NSWindow?

    func show() {
        let w = window ?? {
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 760, height: 680),
                             styleMask: [.titled, .closable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
            w.titlebarAppearsTransparent = true
            w.titleVisibility = .hidden
            w.isMovableByWindowBackground = true
            w.isReleasedWhenClosed = false
            w.backgroundColor = .black
            w.appearance = NSAppearance(named: .darkAqua)
            w.minSize = NSSize(width: 640, height: 480)
            w.contentView = NSHostingView(rootView: LicensesView())
            w.center()
            window = w
            return w
        }()
        w.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }
}

/// One plugin's license in a window of its own, opened from the Licenses list.
@MainActor
enum PluginLicenseWindow {
    private static var window: NSWindow?

    static func show(_ plugin: Plugin) {
        window?.close()
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 480, height: 460),
                         styleMask: [.titled, .closable, .fullSizeContentView], backing: .buffered, defer: false)
        w.titlebarAppearsTransparent = true
        w.titleVisibility = .hidden
        w.isMovableByWindowBackground = true
        w.isReleasedWhenClosed = false
        w.backgroundColor = .black
        w.appearance = NSAppearance(named: .darkAqua)
        w.contentView = NSHostingView(rootView:
            VStack(alignment: .leading, spacing: 14) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(plugin.name).font(.system(size: 20, weight: .bold)).foregroundStyle(Theme.text)
                    Text(plugin.manufacturer).font(.system(size: 12)).foregroundStyle(Theme.faint)
                }
                LicenseSection(plugin: plugin, showsTitle: false)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 26).padding(.top, 40).padding(.bottom, 22)
            .frame(minWidth: 460, minHeight: 420, alignment: .topLeading)
            .background(Theme.ground)
            .preferredColorScheme(.dark))
        w.center()
        window = w
        w.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }
}

struct LicensesView: View {
    enum Filter: String, CaseIterable { case all = "All", owned = "Owned", subscription = "Subscription", bundle = "Bundle",
                                         trial = "Trial", free = "Free", none = "Not entered" }
    var lic = Licenses.shared
    var store = PluginStore.shared
    @State private var filter: Filter = .all
    @State private var search = ""

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                header
                totals
                comingUp
                plansSection
                pluginsSection
            }
            .padding(.horizontal, 26).padding(.top, 40).padding(.bottom, 26)
        }
        .frame(minWidth: 640, minHeight: 480)
        .background(Theme.ground)
        .preferredColorScheme(.dark)
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Licenses and subscriptions").font(.system(size: 22, weight: .bold)).foregroundStyle(Theme.text)
                Text("Kept on this Mac only. License keys are stored in your Keychain.")
                    .font(.system(size: 12)).foregroundStyle(Theme.faint)
            }
            Spacer()
            HStack(spacing: 4) {
                ForEach(Licenses.currencies, id: \.self) { c in Chip(title: c, on: lic.currency == c) { lic.currency = c } }
            }
            QuietPill(title: "Export", systemImage: "square.and.arrow.up", height: 28) { lic.exportCSV() }
        }
    }

    private var totals: some View {
        let next = lic.plans.filter { $0.isSubscription && $0.active && $0.nextRenewal != nil }
            .min { $0.nextRenewal! < $1.nextRenewal! }
        return HStack(spacing: 10) {
            stat("Collection value", lic.money(lic.collectionValue), "What it would cost to buy")
            stat("Paid", lic.money(lic.paid), "Plugins and bundles")
            stat("Subscriptions", "\(lic.money(lic.perMonth)) a month", "\(lic.money(lic.perYear)) a year")
            stat("Next renewal", next?.name ?? "None",
                 next.map { n in
                     (n.nextRenewal?.formatted(date: .abbreviated, time: .omitted) ?? "")
                         + (n.cost.map { " · " + lic.money($0) } ?? "")
                 } ?? "Add a subscription to see it here")
        }
    }

    private func stat(_ title: String, _ value: String, _ sub: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.system(size: 11)).foregroundStyle(Theme.faint)
            Text(value).font(.system(size: 17, weight: .bold)).foregroundStyle(Theme.text).lineLimit(1).minimumScaleFactor(0.7)
            Text(sub).font(.system(size: 11)).foregroundStyle(Theme.muted).lineLimit(2)
        }
        .padding(14)
        .frame(maxWidth: .infinity, minHeight: 92, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: Theme.radiusInner).fill(Theme.surface))
    }

    @ViewBuilder private var comingUp: some View {
        let list = lic.upcoming()
        if !list.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                sectionTitle("Coming up in the next 60 days")
                VStack(spacing: 0) {
                    ForEach(list) { u in
                        HStack {
                            Image(systemName: "bell").font(.system(size: 11)).foregroundStyle(Theme.accent)
                            Text(u.title).font(.system(size: 13, weight: .medium)).foregroundStyle(Theme.text)
                            Text(u.detail).font(.system(size: 12)).foregroundStyle(Theme.muted)
                            Spacer()
                            Text(u.date.formatted(date: .abbreviated, time: .omitted)).font(.system(size: 12)).foregroundStyle(Theme.text)
                            Text(days(u.date)).font(.system(size: 11)).foregroundStyle(Theme.faint).frame(width: 70, alignment: .trailing)
                        }
                        .padding(.horizontal, 14).frame(height: 34)
                    }
                }
                .background(RoundedRectangle(cornerRadius: Theme.radiusInner).fill(Theme.surface))
            }
        }
    }

    private func days(_ d: Date) -> String {
        let n = Calendar.current.dateComponents([.day], from: Calendar.current.startOfDay(for: Date()), to: d).day ?? 0
        return n == 0 ? "today" : n == 1 ? "tomorrow" : "in \(n) days"
    }

    private func sectionTitle(_ t: String) -> some View {
        Text(t).font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.text)
    }

    private var plansSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                sectionTitle("Subscriptions and bundles")
                Spacer()
                QuietPill(title: "Subscription", systemImage: "plus", height: 26) {
                    if let p = lic.newPlan(.subscription) { PlanWindow.show(p.id) }
                }
                QuietPill(title: "Bundle", systemImage: "plus", height: 26) {
                    if let p = lic.newPlan(.bundle) { PlanWindow.show(p.id) }
                }
            }
            if lic.plans.isEmpty {
                Text("Add a subscription such as Waves Creative Access, or a bundle you bought, then select its plugins in the library and choose License.")
                    .font(.system(size: 12)).foregroundStyle(Theme.faint)
                    .padding(14).frame(maxWidth: .infinity, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: Theme.radiusInner).fill(Theme.surface))
            } else {
                VStack(spacing: 0) {
                    ForEach(lic.plans) { p in
                        Button { PlanWindow.show(p.id) } label: {
                            HStack {
                                Image(systemName: p.isSubscription ? "arrow.triangle.2.circlepath" : "shippingbox")
                                    .font(.system(size: 12)).foregroundStyle(p.active || !p.isSubscription ? Theme.muted : Theme.faint)
                                    .frame(width: 18)
                                Text(p.name).font(.system(size: 13, weight: .medium))
                                    .foregroundStyle(p.active || !p.isSubscription ? Theme.text : Theme.faint)
                                Spacer()
                                Text(PlanSummary.line(p)).font(.system(size: 12)).foregroundStyle(Theme.muted)
                                Image(systemName: "chevron.right").font(.system(size: 10)).foregroundStyle(Theme.faint)
                            }
                            .padding(.horizontal, 14).frame(height: 38)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
                .background(RoundedRectangle(cornerRadius: Theme.radiusInner).fill(Theme.surface))
            }
        }
    }

    private func matches(_ p: Plugin) -> Bool {
        let s = lic.licenses[p.id]?.status
        switch filter {
        case .all: if s == nil { return false }
        case .none: if s != nil { return false }
        case .owned: if s != .owned { return false }
        case .subscription: if s != .subscription { return false }
        case .bundle: if s != .bundle { return false }
        case .trial: if s != .trial { return false }
        case .free: if s != .free { return false }
        }
        let words = search.lowercased().split(separator: " ").map(String.init)
        let hay = "\(p.name) \(p.manufacturer)".lowercased()
        return words.allSatisfy { hay.contains($0) }
    }

    private var pluginsSection: some View {
        let list = store.plugins.filter { !$0.isLogic && matches($0) }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                sectionTitle("Plugins")
                Spacer()
                LicenseTextField(placeholder: "Filter", text: $search, width: 180)
            }
            FlowRow(spacing: 6) {
                ForEach(Filter.allCases, id: \.self) { f in Chip(title: f.rawValue, on: filter == f) { filter = f } }
            }
            if list.isEmpty {
                Text(filter == .all ? "Nothing entered yet. Open a plugin's info and fill in its License, or select many in the library and choose License."
                                    : "No plugins here.")
                    .font(.system(size: 12)).foregroundStyle(Theme.faint)
                    .padding(14).frame(maxWidth: .infinity, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: Theme.radiusInner).fill(Theme.surface))
            } else {
                LazyVStack(spacing: 0) {
                    ForEach(list) { p in row(p) }
                }
                .background(RoundedRectangle(cornerRadius: Theme.radiusInner).fill(Theme.surface))
            }
        }
    }

    private func row(_ p: Plugin) -> some View {
        let l = lic.licenses[p.id]
        var right: [String] = []
        if let pl = lic.plan(l?.planID) { right.append(pl.name) }
        if let v = l?.price { right.append("Paid \(lic.money(v))") }
        if let v = l?.value { right.append("Worth \(lic.money(v))") }
        if l?.status == .trial, let d = l?.trialEnds { right.append("Ends \(d.formatted(date: .abbreviated, time: .omitted))") }
        return Button { PluginLicenseWindow.show(p) } label: {
            HStack {
                VStack(alignment: .leading, spacing: 1) {
                    Text(p.name).font(.system(size: 13, weight: .medium)).foregroundStyle(Theme.text).lineLimit(1)
                    Text(p.manufacturer).font(.system(size: 11)).foregroundStyle(Theme.faint).lineLimit(1)
                }
                Spacer()
                Text(right.joined(separator: " · ")).font(.system(size: 12)).foregroundStyle(Theme.muted).lineLimit(1)
                Text(l?.status?.title ?? "Not entered").font(.system(size: 11, weight: .medium))
                    .foregroundStyle(l?.status == nil ? Theme.faint : Theme.text)
                    .padding(.horizontal, 8).frame(height: 20)
                    .background(Capsule().fill(Theme.raised))
            }
            .padding(.horizontal, 14).frame(height: 42)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Several plugins at once

struct LicenseMenu: View {
    let ids: [String]
    var lic = Licenses.shared

    var body: some View {
        let n = ids.count
        Menu("License for \(n)") {
            ForEach(LicenseInfo.Status.allCases.filter { $0 != .subscription && $0 != .bundle }) { s in
                Button("Mark as \(s.title)") { lic.mark(ids, s); Toast.show("Marked \(n) as \(s.title)") }
            }
            if !lic.plans.isEmpty { Divider() }
            ForEach(lic.plans) { p in
                Button("Add to \(p.name)") { lic.add(ids, to: p.id); Toast.show("Added \(n) to \(p.name)") }
            }
            Divider()
            Button("New Subscription with These…") { if let p = lic.newPlan(.subscription, adding: ids) { PlanWindow.show(p.id) } }
            Button("New Bundle with These…") { if let p = lic.newPlan(.bundle, adding: ids) { PlanWindow.show(p.id) } }
            Divider()
            Button("Licenses and Subscriptions…") { LicensesWindow.shared.show() }
        }
    }
}
