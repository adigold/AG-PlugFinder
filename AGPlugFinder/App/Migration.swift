import Foundation
import Security

/// One-time move from the app's old name (AU Plugin Helper, com.adigoldstein.AUPluginHelper):
/// copies settings, favorites, hidden plugins, screenshots and the API key, if it can read it
/// without asking. The old files stay where they are.
enum Migration {
    private static let oldDomain = "com.adigoldstein.AUPluginHelper"
    private static let doneKey = "migratedFromAUPluginHelper"

    static func run() {
        let d = UserDefaults.standard
        guard !d.bool(forKey: doneKey) else { return }
        d.set(true, forKey: doneKey)

        if let old = UserDefaults.standard.persistentDomain(forName: oldDomain) {
            for (key, value) in old where d.object(forKey: key) == nil && key != "didApplyLaunchAtLoginDefault" {
                d.set(value, forKey: key)
            }
        }

        let fm = FileManager.default
        let base = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let oldDir = base.appendingPathComponent("AU Plugin Helper", isDirectory: true)
        let newDir = base.appendingPathComponent("AG PlugFinder", isDirectory: true)
        if fm.fileExists(atPath: oldDir.path), !fm.fileExists(atPath: newDir.path) {
            try? fm.copyItem(at: oldDir, to: newDir)
        }

        if Keychain.read() == nil, let key = readOldKey() { Keychain.save(key) }
    }

    /// Reads the old app's API key only if macOS allows it silently; never shows a prompt.
    private static func readOldKey() -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "\(oldDomain).anthropic",
            kSecAttrAccount as String: "api-key",
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecUseAuthenticationUI as String: kSecUseAuthenticationUISkip,
        ]
        var out: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &out) == errSecSuccess,
              let data = out as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }
}
