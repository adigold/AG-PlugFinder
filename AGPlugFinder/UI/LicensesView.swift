import AppKit
import SwiftUI

// MARK: - Small fields

private func fieldLabel(_ text: String) -> some View {
    Text(text).font(.system(size: Theme.ts(11))).foregroundStyle(Theme.faint)
}

/// A one-line text field in the app's style.
struct LicenseTextField: View {
    let placeholder: String
    @Binding var text: String
    var width: CGFloat? = nil

    var body: some View {
        TextField(placeholder, text: $text)
            .textFieldStyle(.plain)
            .font(.system(size: Theme.ts(13)))
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
            Text(lic.symbol).font(.system(size: Theme.ts(13))).foregroundStyle(Theme.faint)
            TextField(placeholder, text: $text)
                .textFieldStyle(.plain).font(.system(size: Theme.ts(13))).monospacedDigit()
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
    @State private var open = false

    var body: some View {
        HStack(spacing: 6) {
            Chip(title: date.map { $0.formatted(.dateTime.day().month(.abbreviated).year().locale(Locale(identifier: "en_GB"))) } ?? title,
                 systemImage: "calendar", on: false) { open.toggle() }
                .popover(isPresented: $open, arrowEdge: .bottom) {
                    CalendarPicker(date: Binding(get: { date ?? start() }, set: { date = $0 })) { open = false }
                }
            if date != nil {
                Button { date = nil } label: {
                    Image(systemName: "xmark.circle.fill").font(.system(size: Theme.ts(13))).foregroundStyle(Theme.faint)
                }
                .buttonStyle(.plain).help("Clear the date")
            }
        }
    }
}

/// A month calendar in the app's style (BL-93): white for the chosen day, an amber ring on
/// today, arrows for the month and quick choices underneath.
struct CalendarPicker: View {
    @Binding var date: Date
    var done: () -> Void
    @State private var month = Date()
    private var cal: Calendar { var c = Calendar.current; c.locale = Locale(identifier: "en_US"); return c }

    var body: some View {
        VStack(spacing: 12) {
            HStack {
                Text(month.formatted(.dateTime.month(.wide).year().locale(Locale(identifier: "en_US"))))
                    .font(.system(size: Theme.ts(15), weight: .semibold)).foregroundStyle(Theme.text)
                Spacer()
                BarIconButton(systemImage: "chevron.left", help: "Previous month") { step(-1) }
                BarIconButton(systemImage: "chevron.right", help: "Next month") { step(1) }
            }
            let names = weekdayNames
            HStack(spacing: 0) {
                ForEach(names.indices, id: \.self) { i in
                    Text(names[i]).font(.system(size: Theme.ts(11), weight: .medium)).foregroundStyle(Theme.faint).frame(maxWidth: .infinity)
                }
            }
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 4), count: 7), spacing: 4) {
                ForEach(days, id: \.self) { d in dayCell(d) }
            }
            HStack(spacing: 6) {
                quick("Today", 0, .day)
                quick("In 1 month", 1, .month)
                quick("In 1 year", 1, .year)
            }
        }
        .padding(14)
        .frame(width: 300)
        .background(Theme.surface)
        .preferredColorScheme(Theme.scheme)
        .onAppear { month = firstOfMonth(date) }
    }

    private var weekdayNames: [String] {
        let s = cal.veryShortStandaloneWeekdaySymbols
        let f = cal.firstWeekday - 1
        return Array(s[f...] + s[..<f])
    }

    private func firstOfMonth(_ d: Date) -> Date {
        cal.date(from: cal.dateComponents([.year, .month], from: d)) ?? d
    }

    /// The month's days, with the days before the first one shown as blanks (distantPast).
    private var days: [Date] {
        guard let range = cal.range(of: .day, in: .month, for: month) else { return [] }
        let lead = (cal.component(.weekday, from: month) - cal.firstWeekday + 7) % 7
        let blanks = (0..<lead).map { Date.distantPast.addingTimeInterval(Double($0)) }
        return blanks + range.compactMap { cal.date(byAdding: .day, value: $0 - 1, to: month) }
    }

    @ViewBuilder private func dayCell(_ d: Date) -> some View {
        if d < Date.distantPast.addingTimeInterval(10) {
            Color.clear.frame(height: 32)
        } else {
            let chosen = cal.isDate(d, inSameDayAs: date)
            let today = cal.isDateInToday(d)
            Button { date = d; done() } label: {
                Text("\(cal.component(.day, from: d))")
                    .font(.system(size: Theme.ts(13), weight: chosen ? .bold : .regular)).monospacedDigit()
                    .foregroundStyle(chosen ? Theme.onInk : Theme.text)
                    .frame(maxWidth: .infinity).frame(height: 32)
                    .background(RoundedRectangle(cornerRadius: 8).fill(chosen ? Theme.ink : Theme.raised.opacity(0.55)))
                    .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Theme.accent, lineWidth: today && !chosen ? 1.5 : 0))
                    .contentShape(Rectangle())
            }
            .buttonStyle(PressScale())
        }
    }

    private func step(_ n: Int) {
        if let m = cal.date(byAdding: .month, value: n, to: month) { withAnimation(.easeOut(duration: 0.15)) { month = m } }
    }

    private func quick(_ title: String, _ n: Int, _ unit: Calendar.Component) -> some View {
        Chip(title: title, on: false) {
            let base = cal.startOfDay(for: Date())
            if let d = cal.date(byAdding: unit, value: n, to: base) { date = d; month = firstOfMonth(d); done() }
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
            .textFieldStyle(.plain).font(.system(size: Theme.ts(13), design: .monospaced))
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
                    Text("License").font(.system(size: Theme.ts(12))).foregroundStyle(Theme.faint)
                    Spacer()
                    Button("All licenses") { LicensesWindow.shared.show() }
                        .buttonStyle(.plain).font(.system(size: Theme.ts(11))).foregroundStyle(Theme.muted)
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
                        Text(PlanSummary.line(p)).font(.system(size: Theme.ts(12))).foregroundStyle(Theme.muted)
                        Text("Edit").font(.system(size: Theme.ts(12), weight: .medium)).foregroundStyle(Theme.text)
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
            w.backgroundColor = Theme.nsGround
            w.appearance = Theme.nsAppearance
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

    private var plan: Binding<LicensePlan> {
        Binding(get: { lic.plan(id) ?? LicensePlan(name: "", kind: .subscription) },
                set: { new in if let i = lic.plans.firstIndex(where: { $0.id == id }) { lic.plans[i] = new } })
    }

    var body: some View {
        let p = plan.wrappedValue
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text(p.isSubscription ? "Subscription" : "Bundle").font(.system(size: Theme.ts(12))).foregroundStyle(Theme.faint)
                TextField("Name", text: plan.name)
                    .textFieldStyle(.plain).font(.system(size: Theme.ts(22), weight: .bold)).foregroundStyle(Theme.text)
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
                    Button("Delete \(p.isSubscription ? "Subscription" : "Bundle")") {
                        if Dialog.confirm("Delete \(p.name)?",
                                          message: "The plugins in it stay, without this \(p.isSubscription ? "subscription" : "bundle").",
                                          ok: "Delete", destructive: true) {
                            lic.deletePlan(id); PlanWindow.close(id)
                        }
                    }
                        .buttonStyle(.plain).font(.system(size: Theme.ts(12))).foregroundStyle(Theme.negative)
                    Spacer()
                    PrimaryPill(title: "Done") { close() }
                }
            }
            .padding(.horizontal, 26).padding(.top, 40).padding(.bottom, 22)
        }
        .frame(minWidth: 480, minHeight: 480)
        .background(Theme.ground)
        .preferredColorScheme(Theme.scheme)
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
                    .font(.system(size: Theme.ts(12))).foregroundStyle(Theme.muted)
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
                            Text(pl.name).font(.system(size: Theme.ts(12))).foregroundStyle(Theme.text)
                            Text(pl.manufacturer).font(.system(size: Theme.ts(11))).foregroundStyle(Theme.faint)
                            Spacer()
                            Button { var l = lic.license(pl.id); l.planID = nil; lic.set(l, for: pl.id) } label: {
                                Image(systemName: "xmark").font(.system(size: Theme.ts(10), weight: .semibold)).foregroundStyle(Theme.faint)
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
            w.backgroundColor = Theme.nsGround
            w.appearance = Theme.nsAppearance
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
        w.backgroundColor = Theme.nsGround
        w.appearance = Theme.nsAppearance
        w.contentView = NSHostingView(rootView:
            VStack(alignment: .leading, spacing: 14) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(plugin.name).font(.system(size: Theme.ts(20), weight: .bold)).foregroundStyle(Theme.text)
                    Text(plugin.manufacturer).font(.system(size: Theme.ts(12))).foregroundStyle(Theme.faint)
                }
                LicenseSection(plugin: plugin, showsTitle: false)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 26).padding(.top, 40).padding(.bottom, 22)
            .frame(minWidth: 460, minHeight: 420, alignment: .topLeading)
            .background(Theme.ground)
            .preferredColorScheme(Theme.scheme))
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
    /// The window leaves room for its hidden title bar; the Settings tab needs less.
    var topPadding: CGFloat = 40
    @State private var filter: Filter = .all
    @State private var choosePlugin = false
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
            .padding(.horizontal, 26).padding(.top, topPadding).padding(.bottom, 26)
        }
        .frame(minWidth: 640, minHeight: 480)
        .background(Theme.ground)
        .preferredColorScheme(Theme.scheme)
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 4) {
                Text("My Purchases").font(.system(size: Theme.ts(22), weight: .bold)).foregroundStyle(Theme.text)
                Text(UserLibrary.shared.syncEnabled && Licenses.cloudFile != nil
                     ? "Synced with your other Macs through iCloud Drive. License keys stay in this Mac's Keychain."
                     : "Kept on this Mac only. License keys are stored in your Keychain.")
                    .font(.system(size: Theme.ts(12))).foregroundStyle(Theme.faint)
            }
            Spacer()
            CurrencyButton()
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
            Text(title).font(.system(size: Theme.ts(11))).foregroundStyle(Theme.faint)
            Text(value).font(.system(size: Theme.ts(17), weight: .bold)).foregroundStyle(Theme.text).lineLimit(1).minimumScaleFactor(0.7)
            Text(sub).font(.system(size: Theme.ts(11))).foregroundStyle(Theme.muted).lineLimit(2)
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
                            Image(systemName: "bell").font(.system(size: Theme.ts(11))).foregroundStyle(Theme.accent)
                            Text(u.title).font(.system(size: Theme.ts(13), weight: .medium)).foregroundStyle(Theme.text)
                            Text(u.detail).font(.system(size: Theme.ts(12))).foregroundStyle(Theme.muted)
                            Spacer()
                            Text(u.date.formatted(date: .abbreviated, time: .omitted)).font(.system(size: Theme.ts(12))).foregroundStyle(Theme.text)
                            Text(days(u.date)).font(.system(size: Theme.ts(11))).foregroundStyle(Theme.faint).frame(width: 70, alignment: .trailing)
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
        Text(t).font(.system(size: Theme.ts(13), weight: .semibold)).foregroundStyle(Theme.text)
    }

    private var plansSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                sectionTitle("Subscriptions and bundles")
                Spacer()
                QuietPill(title: "Single License", systemImage: "plus", height: 26) { choosePlugin = true }
                    .popover(isPresented: $choosePlugin, arrowEdge: .bottom) {
                        PluginChooser { p in
                            choosePlugin = false
                            if lic.licenses[p.id]?.status == nil { var l = lic.license(p.id); l.status = .owned; lic.set(l, for: p.id) }
                            PluginLicenseWindow.show(p)
                        }
                    }
                QuietPill(title: "Subscription", systemImage: "plus", height: 26) {
                    if let p = lic.newPlan(.subscription) { PlanWindow.show(p.id) }
                }
                QuietPill(title: "Bundle", systemImage: "plus", height: 26) {
                    if let p = lic.newPlan(.bundle) { PlanWindow.show(p.id) }
                }
            }
            if lic.plans.isEmpty {
                Text("Add a subscription such as Waves Creative Access, or a bundle you bought, then select its plugins in the library and choose License.")
                    .font(.system(size: Theme.ts(12))).foregroundStyle(Theme.faint)
                    .padding(14).frame(maxWidth: .infinity, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: Theme.radiusInner).fill(Theme.surface))
            } else {
                VStack(spacing: 0) {
                    ForEach(lic.plans) { p in
                        Button { PlanWindow.show(p.id) } label: {
                            HStack {
                                Image(systemName: p.isSubscription ? "arrow.triangle.2.circlepath" : "shippingbox")
                                    .font(.system(size: Theme.ts(12))).foregroundStyle(p.active || !p.isSubscription ? Theme.muted : Theme.faint)
                                    .frame(width: 18)
                                Text(p.name).font(.system(size: Theme.ts(13), weight: .medium))
                                    .foregroundStyle(p.active || !p.isSubscription ? Theme.text : Theme.faint)
                                Spacer()
                                Text(PlanSummary.line(p)).font(.system(size: Theme.ts(12))).foregroundStyle(Theme.muted)
                                Image(systemName: "chevron.right").font(.system(size: Theme.ts(10))).foregroundStyle(Theme.faint)
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
                    .font(.system(size: Theme.ts(12))).foregroundStyle(Theme.faint)
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
                    Text(p.name).font(.system(size: Theme.ts(13), weight: .medium)).foregroundStyle(Theme.text).lineLimit(1)
                    Text(p.manufacturer).font(.system(size: Theme.ts(11))).foregroundStyle(Theme.faint).lineLimit(1)
                }
                Spacer()
                Text(right.joined(separator: " · ")).font(.system(size: Theme.ts(12))).foregroundStyle(Theme.muted).lineLimit(1)
                Text(l?.status?.title ?? "Not entered").font(.system(size: Theme.ts(11), weight: .medium))
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
            Button("My Purchases…") { LicensesWindow.shared.show() }
        }
    }
}

// MARK: - Currency (BL-92)

/// The chosen currency; opens a searchable list in the app's own style.
struct CurrencyButton: View {
    var lic = Licenses.shared
    @State private var open = false

    var body: some View {
        QuietPill(title: "\(lic.symbol)  \(lic.currency)", systemImage: "chevron.down", height: 28) { open.toggle() }
            .help("Currency")
            .popover(isPresented: $open, arrowEdge: .bottom) { CurrencyList { open = false } }
    }
}

struct CurrencyList: View {
    var lic = Licenses.shared
    var done: () -> Void
    @State private var search = ""

    private var list: [String] {
        let w = search.lowercased().trimmingCharacters(in: .whitespaces)
        guard !w.isEmpty else { return Licenses.currencies }
        return Licenses.currencies.filter { $0.lowercased().contains(w) || Licenses.currencyName($0).lowercased().contains(w) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            LicenseTextField(placeholder: "Search currencies", text: $search)
            ScrollView {
                VStack(spacing: 2) {
                    ForEach(list, id: \.self) { c in
                        Button { lic.currency = c; done() } label: {
                            HStack(spacing: 10) {
                                Text(c).font(.system(size: Theme.ts(12), weight: .semibold)).monospaced().frame(width: 36, alignment: .leading)
                                Text(Licenses.currencyName(c)).font(.system(size: Theme.ts(13))).lineLimit(1)
                                Spacer()
                                if lic.currency == c { Image(systemName: "checkmark").font(.system(size: Theme.ts(11), weight: .bold)) }
                            }
                            .foregroundStyle(lic.currency == c ? Theme.onInk : Theme.text)
                            .padding(.horizontal, 10).frame(height: 30)
                            .background(RoundedRectangle(cornerRadius: 7).fill(lic.currency == c ? Theme.ink : Color.clear))
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
        .padding(10)
        .frame(width: 280, height: 360)
        .background(Theme.surface)
        .preferredColorScheme(Theme.scheme)
    }
}

/// Pick one plugin to record a single license for (BL-94).
struct PluginChooser: View {
    var pick: (Plugin) -> Void
    @State private var search = ""

    private var list: [Plugin] {
        let words = search.lowercased().split(separator: " ").map(String.init)
        return PluginStore.shared.plugins.filter { !$0.isLogic }
            .filter { p in let hay = "\(p.name) \(p.manufacturer)".lowercased(); return words.allSatisfy { hay.contains($0) } }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            LicenseTextField(placeholder: "Which plugin?", text: $search)
            ScrollView {
                LazyVStack(spacing: 2) {
                    ForEach(list) { p in
                        Button { pick(p) } label: {
                            HStack {
                                Text(p.name).font(.system(size: Theme.ts(13))).foregroundStyle(Theme.text).lineLimit(1)
                                Text(p.manufacturer).font(.system(size: Theme.ts(11))).foregroundStyle(Theme.faint).lineLimit(1)
                                Spacer()
                                if let s = Licenses.shared.licenses[p.id]?.status {
                                    Text(s.title).font(.system(size: Theme.ts(10), weight: .medium)).foregroundStyle(Theme.muted)
                                }
                            }
                            .padding(.horizontal, 10).frame(height: 30)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
        .padding(10)
        .frame(width: 320, height: 380)
        .background(Theme.surface)
        .preferredColorScheme(Theme.scheme)
    }
}
