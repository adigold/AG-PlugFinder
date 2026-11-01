import AppKit
import Foundation
import Observation
import Security
import UserNotifications

/// What the user owns and pays for (BL-89): each plugin's license, plus subscriptions and
/// bundles that cover many plugins. Kept on this Mac only, in licenses.json; license keys go
/// to the Keychain, never into the file, and nothing here is ever sent anywhere.
struct LicenseInfo: Codable, Hashable {
    enum Status: String, Codable, CaseIterable, Identifiable {
        case owned, subscription, bundle, trial, free
        var id: String { rawValue }
        var title: String {
            switch self {
            case .owned: return "Owned"
            case .subscription: return "Subscription"
            case .bundle: return "Bundle"
            case .trial: return "Trial"
            case .free: return "Free"
            }
        }
    }

    var status: Status?
    var planID: String?          // the subscription or bundle that covers it
    var price: Double?           // what the user paid
    var value: Double?           // what it costs to buy today, for the collection value
    var bought: Date?
    var trialEnds: Date?
    var store = ""
    var account = ""
    var notes = ""

    var isEmpty: Bool {
        status == nil && planID == nil && price == nil && value == nil && bought == nil && trialEnds == nil
            && store.isEmpty && account.isEmpty && notes.isEmpty
    }
}

/// A subscription (renews) or a bundle (bought once) covering several plugins.
struct LicensePlan: Codable, Hashable, Identifiable {
    enum Kind: String, Codable { case subscription, bundle }
    enum Period: String, Codable, CaseIterable, Identifiable {
        case monthly, yearly
        var id: String { rawValue }
        var title: String { self == .monthly ? "Monthly" : "Yearly" }
        var unit: String { self == .monthly ? "a month" : "a year" }
    }

    var id = UUID().uuidString
    var name: String
    var kind: Kind
    var cost: Double?            // subscription: each renewal; bundle: what the user paid
    var period: Period = .yearly
    var nextRenewal: Date?
    var remindDays = 7
    var active = true            // a cancelled subscription stops counting and reminding
    var value: Double?           // a bundle's worth
    var bought: Date?
    var store = ""
    var account = ""
    var notes = ""

    var isSubscription: Bool { kind == .subscription }
    var perMonth: Double {
        guard isSubscription, active, let cost else { return 0 }
        return period == .monthly ? cost : cost / 12
    }
}

@MainActor
@Observable
final class Licenses {
    static let shared = Licenses()

    var licenses: [String: LicenseInfo] = [:] { didSet { changed() } }
    var plans: [LicensePlan] = [] { didSet { changed() } }
    var currency: String {
        didSet { UserDefaults.standard.set(currency, forKey: "licenses.currency"); changed() }
    }

    /// The currencies offered in the chooser, most used first (BL-92).
    static let currencies = ["USD", "EUR", "GBP", "ILS", "CAD", "AUD", "NZD", "CHF", "JPY", "SEK", "NOK", "DKK",
                             "PLN", "CZK", "HUF", "RON", "TRY", "BRL", "MXN", "ARS", "CLP", "COP", "INR", "CNY",
                             "HKD", "SGD", "KRW", "TWD", "THB", "IDR", "MYR", "PHP", "VND", "ZAR", "AED", "SAR",
                             "EGP", "NGN", "KES", "UAH", "ISK"]

    static func currencyName(_ code: String) -> String {
        Locale(identifier: "en_US").localizedString(forCurrencyCode: code) ?? code
    }
    private let fileURL: URL
    private var loading = false

    private struct Saved: Codable {
        var licenses: [String: LicenseInfo] = [:]
        var plans: [LicensePlan] = []
        // For iCloud sync (BL-95); missing in files saved before it.
        var updatedAt: Date? = nil
        var currency: String? = nil
    }
    private var updatedAt = Date.distantPast

    /// The self-test fills in sample data: it then saves to a temporary file and sets no reminders.
    static var testMode = CommandLine.arguments.contains("--selftest-licenses")

    private init() {
        fileURL = Self.testMode ? FileManager.default.temporaryDirectory.appendingPathComponent("licenses-test.json")
                                : PluginStore.shared.supportDir.appendingPathComponent("licenses.json")
        let local = Locale.current.currency?.identifier ?? "USD"
        currency = UserDefaults.standard.string(forKey: "licenses.currency").flatMap { Self.currencies.contains($0) ? $0 : nil }
            ?? (Self.currencies.contains(local) ? local : "USD")
        load()
        pullFromCloud()
    }

    // MARK: Look-ups

    func license(_ id: String) -> LicenseInfo { licenses[id] ?? LicenseInfo() }
    func plan(_ id: String?) -> LicensePlan? { id.flatMap { id in plans.first { $0.id == id } } }
    func plugins(in plan: LicensePlan) -> [Plugin] {
        PluginStore.shared.plugins.filter { licenses[$0.id]?.planID == plan.id }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    func set(_ info: LicenseInfo, for id: String) { licenses[id] = info.isEmpty ? nil : info }

    /// Marks several plugins at once (from a multi-select).
    func mark(_ ids: [String], _ status: LicenseInfo.Status) {
        var all = licenses
        for id in ids {
            var l = all[id] ?? LicenseInfo()
            l.status = status
            if status != .subscription && status != .bundle { l.planID = nil }
            all[id] = l
        }
        licenses = all
    }

    func add(_ ids: [String], to planID: String) {
        guard let p = plan(planID) else { return }
        var all = licenses
        for id in ids {
            var l = all[id] ?? LicenseInfo()
            l.planID = planID
            l.status = p.isSubscription ? .subscription : .bundle
            all[id] = l
        }
        licenses = all
    }

    @discardableResult
    func newPlan(_ kind: LicensePlan.Kind, adding ids: [String] = []) -> LicensePlan? {
        let sub = kind == .subscription
        guard let name = NamePrompt.ask(sub ? "New subscription" : "New bundle",
                                        placeholder: sub ? "For example Waves Creative Access" : "For example Plugin Alliance MEGA")
        else { return nil }
        var p = LicensePlan(name: name, kind: kind)
        if sub { p.nextRenewal = Calendar.current.date(byAdding: .year, value: 1, to: Calendar.current.startOfDay(for: Date())) }
        plans.append(p)
        if !ids.isEmpty { add(ids, to: p.id) }
        return p
    }

    func deletePlan(_ id: String) {
        var all = licenses
        for (k, var l) in all where l.planID == id {
            l.planID = nil
            all[k] = l.isEmpty ? nil : l
        }
        licenses = all
        plans.removeAll { $0.id == id }
        LicenseKeys.save("", for: id)
    }

    // MARK: Totals

    var perMonth: Double { plans.reduce(0) { $0 + $1.perMonth } }
    var perYear: Double { perMonth * 12 }

    /// What the user paid for plugins and bundles (subscriptions are counted per month instead).
    var paid: Double {
        licenses.values.reduce(0) { $0 + ($1.price ?? 0) }
            + plans.filter { !$0.isSubscription }.reduce(0) { $0 + ($1.cost ?? 0) }
    }

    /// What the collection would cost to buy: each plugin's value (or its price when no value
    /// was entered), plus each bundle's value.
    var collectionValue: Double {
        let plugins: Double = licenses.values.reduce(0) { (sum: Double, l) in sum + (l.value ?? l.price ?? 0) }
        let bundles: Double = plans.reduce(0) { (sum: Double, p) in sum + (p.value ?? 0) }
        return plugins + bundles
    }

    struct Upcoming: Identifiable {
        let id: String
        let title: String
        let detail: String
        let date: Date
    }

    /// Renewals and trial ends in the next `days` days, soonest first.
    func upcoming(days: Int = 60) -> [Upcoming] {
        let today = Calendar.current.startOfDay(for: Date())
        guard let end = Calendar.current.date(byAdding: .day, value: days, to: today) else { return [] }
        var out: [Upcoming] = []
        for p in plans where p.isSubscription && p.active {
            if let d = p.nextRenewal, d >= today, d <= end {
                out.append(.init(id: "p" + p.id, title: "\(p.name) renews",
                                 detail: p.cost.map { "\(money($0)) \(p.period.unit)" } ?? "Amount not entered", date: d))
            }
        }
        let names = Dictionary(PluginStore.shared.plugins.map { ($0.id, $0.name) }, uniquingKeysWith: { a, _ in a })
        for (id, l) in licenses where l.status == .trial {
            if let d = l.trialEnds, d >= today, d <= end {
                out.append(.init(id: "t" + id, title: "\(names[id] ?? "A plugin") trial ends",
                                 detail: l.value.map { "Buying it costs \(money($0))" } ?? "Trial", date: d))
            }
        }
        return out.sorted { $0.date < $1.date }
    }

    // MARK: Money

    private static let formatLocale = Locale(identifier: "en_US")

    func money(_ v: Double) -> String {
        v.formatted(.currency(code: currency).locale(Self.formatLocale)
            .precision(.fractionLength(v.rounded() == v ? 0 : 2)))
    }

    var symbol: String {
        let f = NumberFormatter()
        f.locale = Self.formatLocale
        f.numberStyle = .currency
        f.currencyCode = currency
        return f.currencySymbol ?? currency
    }

    // MARK: Saving

    private func changed() {
        guard !loading else { return }
        updatedAt = Date()
        save(to: fileURL)
        pushToCloud()
        LicenseReminders.reschedule()
    }

    private func save(to url: URL) {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        enc.dateEncodingStrategy = .iso8601
        if let data = try? enc.encode(Saved(licenses: licenses, plans: plans, updatedAt: updatedAt, currency: currency)) {
            try? data.write(to: url, options: .atomic)
        }
    }

    private static func read(_ url: URL) -> Saved? {
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? dec.decode(Saved.self, from: data)
    }

    private func apply(_ s: Saved) {
        loading = true
        licenses = s.licenses
        plans = s.plans
        if let c = s.currency, Self.currencies.contains(c), c != currency { currency = c }
        updatedAt = s.updatedAt ?? .distantPast
        loading = false
    }

    private func load() {
        guard let s = Self.read(fileURL) else { return }
        apply(s)
    }

    // MARK: iCloud sync (BL-95)

    /// Same switch and same iCloud Drive folder as the library sync. License keys are not in
    /// this file: they stay in each Mac's own Keychain.
    static var cloudFile: URL? {
        guard !testMode else { return nil }
        return UserLibrary.cloudFile?.deletingLastPathComponent().appendingPathComponent("licenses.json")
    }

    private func pushToCloud() {
        guard UserLibrary.shared.syncEnabled, let cloud = Self.cloudFile else { return }
        try? FileManager.default.createDirectory(at: cloud.deletingLastPathComponent(), withIntermediateDirectories: true)
        save(to: cloud)
        UserDefaults.standard.set(true, forKey: "licenses.synced")
    }

    /// Takes the iCloud copy when it is newer (at launch and when the app comes to the front).
    /// The first time a Mac syncs, its entries and the iCloud ones are merged, so nothing is lost.
    func pullFromCloud() {
        guard UserLibrary.shared.syncEnabled, let cloud = Self.cloudFile else { return }
        guard let s = Self.read(cloud) else {
            if !licenses.isEmpty || !plans.isEmpty { pushToCloud() }
            return
        }
        if !UserDefaults.standard.bool(forKey: "licenses.synced") {
            var merged = s
            for (k, v) in licenses where merged.licenses[k] == nil { merged.licenses[k] = v }
            for p in plans where !merged.plans.contains(where: { $0.id == p.id }) { merged.plans.append(p) }
            apply(merged)
            changed()
            return
        }
        guard (s.updatedAt ?? .distantPast) > updatedAt.addingTimeInterval(1) else { return }
        apply(s)
        save(to: fileURL)
        LicenseReminders.reschedule()
    }

    /// Called at launch: a renewal date that has passed moves on by one period (the
    /// subscription renewed), then the reminders are set again.
    func refresh() {
        let today = Calendar.current.startOfDay(for: Date())
        var moved = plans
        var any = false
        for i in moved.indices where moved[i].isSubscription && moved[i].active {
            guard var d = moved[i].nextRenewal, d < today else { continue }
            let step: DateComponents = moved[i].period == .monthly ? .init(month: 1) : .init(year: 1)
            var guardCount = 0
            while d < today, guardCount < 600, let n = Calendar.current.date(byAdding: step, to: d) { d = n; guardCount += 1 }
            moved[i].nextRenewal = d
            any = true
        }
        if any { plans = moved } else { LicenseReminders.reschedule() }
    }

    // MARK: Export

    func exportCSV() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "AG PlugFinder licenses.csv"
        panel.allowedContentTypes = [.commaSeparatedText]
        NSApp.activate()
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let date = Date.FormatStyle(date: .numeric, time: .omitted)
        func cell(_ s: String) -> String { "\"" + s.replacingOccurrences(of: "\"", with: "\"\"") + "\"" }
        func num(_ v: Double?) -> String { v.map { String(format: "%.2f", $0) } ?? "" }
        var rows = [["Plugin", "Maker", "Status", "Subscription or bundle", "Paid", "Value", "Bought", "Trial ends",
                     "Store", "Account", "Notes"].map(cell).joined(separator: ",")]
        for p in PluginStore.shared.plugins.sorted(by: { $0.name < $1.name }) {
            guard let l = licenses[p.id] else { continue }
            rows.append([p.name, p.manufacturer, l.status?.title ?? "", plan(l.planID)?.name ?? "", num(l.price), num(l.value),
                         l.bought?.formatted(date) ?? "", l.trialEnds?.formatted(date) ?? "", l.store, l.account, l.notes]
                .map(cell).joined(separator: ","))
        }
        rows.append("")
        rows.append(["Subscription or bundle", "Kind", "Cost", "Period", "Next renewal", "Active", "Value", "Plugins",
                     "Store", "Account", "Notes"].map(cell).joined(separator: ","))
        for p in plans {
            rows.append([p.name, p.isSubscription ? "Subscription" : "Bundle", num(p.cost), p.isSubscription ? p.period.title : "",
                         p.nextRenewal?.formatted(date) ?? "", p.active ? "Yes" : "No", num(p.value), "\(plugins(in: p).count)",
                         p.store, p.account, p.notes].map(cell).joined(separator: ","))
        }
        rows.append("")
        rows.append("\(cell("Currency")),\(cell(currency))")
        do {
            try rows.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
            Toast.show("Saved \(url.lastPathComponent)")
        } catch {
            Toast.show("Couldn't save the file.", warning: true)
        }
    }
}

/// Mac notifications before a subscription renews or a trial ends (BL-89).
@MainActor
enum LicenseReminders {
    private static var pending: Task<Void, Never>?

    static func reschedule() {
        guard !Licenses.testMode else { return }
        pending?.cancel()
        pending = Task { @MainActor in
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled else { return }
            await apply()
        }
    }

    private static func apply() async {
        let lic = Licenses.shared
        let cal = Calendar.current
        let now = Date()
        var requests: [UNNotificationRequest] = []

        func add(_ id: String, _ title: String, _ body: String, on day: Date) {
            guard var fire = cal.date(bySettingHour: 10, minute: 0, second: 0, of: day) else { return }
            if fire <= now, cal.isDateInToday(day) { fire = now.addingTimeInterval(60) }
            guard fire > now else { return }
            let content = UNMutableNotificationContent()
            content.title = title
            content.body = body
            content.sound = .default
            let parts = cal.dateComponents([.year, .month, .day, .hour, .minute], from: fire)
            requests.append(UNNotificationRequest(identifier: "lic." + id, content: content,
                                                  trigger: UNCalendarNotificationTrigger(dateMatching: parts, repeats: false)))
        }

        let date = Date.FormatStyle(date: .abbreviated, time: .omitted)
        for p in lic.plans where p.isSubscription && p.active {
            guard let renew = p.nextRenewal else { continue }
            let amount = p.cost.map { lic.money($0) + " " + p.period.unit } ?? "The subscription"
            if p.remindDays > 0, let before = cal.date(byAdding: .day, value: -p.remindDays, to: renew) {
                add("\(p.id).before", "\(p.name) renews in \(p.remindDays) day\(p.remindDays == 1 ? "" : "s")",
                    "\(amount) will be charged on \(renew.formatted(date)). Cancel before then if you don't need it.", on: before)
            }
            add("\(p.id).day", "\(p.name) renews today", "\(amount).", on: renew)
        }
        let names = Dictionary(PluginStore.shared.plugins.map { ($0.id, $0.name) }, uniquingKeysWith: { a, _ in a })
        for (id, l) in lic.licenses where l.status == .trial {
            guard let ends = l.trialEnds else { continue }
            let name = names[id] ?? "A plugin"
            if let before = cal.date(byAdding: .day, value: -3, to: ends) {
                add("\(id).before", "\(name) trial ends in 3 days",
                    l.value.map { "Buying it costs \(lic.money($0))." } ?? "Buy it or remove it before then.", on: before)
            }
            add("\(id).day", "\(name) trial ends today", "Buy it to keep using it.", on: ends)
        }

        let center = UNUserNotificationCenter.current()
        let old = await center.pendingNotificationRequests().map(\.identifier).filter { $0.hasPrefix("lic.") }
        center.removePendingNotificationRequests(withIdentifiers: old)
        guard !requests.isEmpty else { return }
        guard (try? await center.requestAuthorization(options: [.alert, .sound])) == true else { return }
        // macOS keeps at most 64 waiting notifications per app: the soonest ones go first.
        let soonest = requests.sorted {
            (($0.trigger as? UNCalendarNotificationTrigger)?.nextTriggerDate() ?? .distantFuture)
                < (($1.trigger as? UNCalendarNotificationTrigger)?.nextTriggerDate() ?? .distantFuture)
        }
        for r in soonest.prefix(60) { try? await center.add(r) }
    }
}

/// License keys and serials, one Keychain item per plugin or plan. Never written to a file.
enum LicenseKeys {
    private static let service = "com.adigoldstein.AGPlugFinder.license"

    static func read(_ id: String) -> String? {
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                kSecAttrAccount as String: id, kSecReturnData as String: true,
                                kSecMatchLimit as String: kSecMatchLimitOne]
        var out: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let d = out as? Data else { return nil }
        return String(data: d, encoding: .utf8)
    }

    static func save(_ key: String, for id: String) {
        let base: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                   kSecAttrAccount as String: id]
        SecItemDelete(base as CFDictionary)
        let t = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        var item = base
        item[kSecValueData as String] = Data(t.utf8)
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        SecItemAdd(item as CFDictionary, nil)
    }
}
