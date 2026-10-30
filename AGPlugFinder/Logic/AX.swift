import ApplicationServices
import AppKit

/// Small helpers over the Accessibility C API.
struct AXNode {
    let el: AXUIElement

    func attr<T>(_ name: String) -> T? {
        var v: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, name as CFString, &v) == .success else { return nil }
        return v as? T
    }

    var role: String { attr(kAXRoleAttribute) ?? "" }
    var subrole: String { attr(kAXSubroleAttribute) ?? "" }
    var title: String { attr(kAXTitleAttribute) ?? "" }
    var desc: String { attr(kAXDescriptionAttribute) ?? "" }
    var help: String { attr(kAXHelpAttribute) ?? "" }
    var identifier: String { attr(kAXIdentifierAttribute) ?? "" }
    var placeholder: String { attr(kAXPlaceholderValueAttribute) ?? "" }
    var stringValue: String {
        if let s: String = attr(kAXValueAttribute) { return s }
        return ""
    }
    var children: [AXNode] {
        (attr(kAXChildrenAttribute) as [AXUIElement]?)?.map(AXNode.init) ?? []
    }
    var isEnabled: Bool { attr(kAXEnabledAttribute) ?? true }

    var frame: CGRect {
        var pos = CGPoint.zero, size = CGSize.zero
        if let v: AXValue = attr(kAXPositionAttribute) { AXValueGetValue(v, .cgPoint, &pos) }
        if let v: AXValue = attr(kAXSizeAttribute) { AXValueGetValue(v, .cgSize, &size) }
        return CGRect(origin: pos, size: size)
    }

    /// All the text an element exposes, for matching.
    var allText: String { [title, desc, help, stringValue, identifier].joined(separator: " | ") }

    var actions: [String] {
        var names: CFArray?
        guard AXUIElementCopyActionNames(el, &names) == .success else { return [] }
        return (names as? [String]) ?? []
    }

    @discardableResult
    func perform(_ action: String) -> Bool {
        AXUIElementPerformAction(el, action as CFString) == .success
    }

    @discardableResult
    func setValue(_ value: String) -> Bool {
        AXUIElementSetAttributeValue(el, kAXValueAttribute as CFString, value as CFTypeRef) == .success
    }

    func setFocused() {
        AXUIElementSetAttributeValue(el, kAXFocusedAttribute as CFString, kCFBooleanTrue)
    }

    /// Breadth-first search with a node budget so a huge Logic window cannot stall us.
    func findAll(maxNodes: Int = 25_000, skipRoles: Set<String> = [],
                 where match: (AXNode) -> Bool) -> [AXNode] {
        var out: [AXNode] = []
        var queue: [AXNode] = [self]
        var visited = 0
        var i = 0
        while i < queue.count, visited < maxNodes {
            let node = queue[i]; i += 1; visited += 1
            if match(node) { out.append(node) }
            if skipRoles.contains(node.role) { continue }
            queue.append(contentsOf: node.children)
        }
        return out
    }

    func first(maxNodes: Int = 25_000, where match: (AXNode) -> Bool) -> AXNode? {
        var queue: [AXNode] = [self]
        var i = 0
        while i < queue.count, i < maxNodes {
            let node = queue[i]; i += 1
            if match(node) { return node }
            queue.append(contentsOf: node.children)
        }
        return nil
    }
}

enum AXAccess {
    static var isTrusted: Bool { AXIsProcessTrusted() }

    /// Shows the system prompt that sends the user to Privacy & Security → Accessibility.
    static func requestTrust() {
        let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(opts)
    }

    static func openSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }
}

/// Types text into a process as real key presses.
enum Keyboard {
    static func type(_ text: String, pid: pid_t) {
        let source = CGEventSource(stateID: .hidSystemState)
        for ch in text.utf16 {
            var c = ch
            for down in [true, false] {
                guard let e = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: down) else { continue }
                e.keyboardSetUnicodeString(stringLength: 1, unicodeString: &c)
                e.postToPid(pid)
            }
            usleep(8_000)
        }
    }

    static func press(_ key: CGKeyCode, pid: pid_t) {
        let source = CGEventSource(stateID: .hidSystemState)
        for down in [true, false] {
            CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: down)?.postToPid(pid)
        }
    }
}
