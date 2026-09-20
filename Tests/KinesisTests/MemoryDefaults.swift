import Foundation

/// Preferences that live in memory. A suite made with `UserDefaults(suiteName:)` leaves an
/// empty file in ~/Library/Preferences for ever, even after its domain is removed, and a
/// test run made thirty-six of them. Foundation's typed getters and setters all go through
/// `object(forKey:)` and `set(_:forKey:)`, so these few overrides are the whole store.
final class MemoryDefaults: UserDefaults, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: Any] = [:]

    init() { super.init(suiteName: nil)! }

    /// Everything stored so far, the way `persistentDomain(forName:)` would report it.
    var contents: [String: Any] {
        lock.lock(); defer { lock.unlock() }
        return values
    }

    override func object(forKey defaultName: String) -> Any? {
        lock.lock(); defer { lock.unlock() }
        return values[defaultName]
    }

    override func set(_ value: Any?, forKey defaultName: String) {
        lock.lock(); defer { lock.unlock() }
        values[defaultName] = value
    }

    override func removeObject(forKey defaultName: String) {
        lock.lock(); defer { lock.unlock() }
        values[defaultName] = nil
    }
}
