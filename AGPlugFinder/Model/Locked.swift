import Foundation

/// A value any thread can read and change safely, one at a time (BL-168).
final class Locked<Value>: @unchecked Sendable {
    private var value: Value
    private let lock = NSLock()

    init(_ value: Value) { self.value = value }

    func read<R>(_ body: (Value) -> R) -> R {
        lock.lock(); defer { lock.unlock() }
        return body(value)
    }

    func change(_ body: (inout Value) -> Void) {
        lock.lock(); defer { lock.unlock() }
        body(&value)
    }
}
