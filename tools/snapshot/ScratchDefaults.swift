import Foundation

// In-memory defaults for every component of the snapshot tool that takes a `UserDefaults`
// (main.swift's AppController, the Settings, menu and overlay scenes).

/// UserDefaults that keeps every value in memory: nothing reaches the disk or the app's real
/// preferences domain. Covers what `Preferences` uses. Shared by every scene.
final class ScratchDefaults: UserDefaults {
    private var values: [String: Any] = [:]
    private var registered: [String: Any] = [:]

    override init?(suiteName suitename: String?) { super.init(suiteName: suitename) }

    override func register(defaults registrationDictionary: [String: Any]) { registered.merge(registrationDictionary) { $1 } }
    override func object(forKey defaultName: String) -> Any? { values[defaultName] ?? registered[defaultName] }
    override func set(_ value: Any?, forKey defaultName: String) { values[defaultName] = value }
    override func set(_ value: Bool, forKey defaultName: String) { values[defaultName] = value }
    override func set(_ value: Int, forKey defaultName: String) { values[defaultName] = value }
    override func set(_ value: Double, forKey defaultName: String) { values[defaultName] = value }
    override func removeObject(forKey defaultName: String) { values[defaultName] = nil }
    override func string(forKey defaultName: String) -> String? { object(forKey: defaultName) as? String }
    override func data(forKey defaultName: String) -> Data? { object(forKey: defaultName) as? Data }
    override func dictionary(forKey defaultName: String) -> [String: Any]? { object(forKey: defaultName) as? [String: Any] }
    override func stringArray(forKey defaultName: String) -> [String]? { object(forKey: defaultName) as? [String] }
    override func integer(forKey defaultName: String) -> Int { (object(forKey: defaultName) as? NSNumber)?.intValue ?? 0 }
    override func double(forKey defaultName: String) -> Double { (object(forKey: defaultName) as? NSNumber)?.doubleValue ?? 0 }
    override func bool(forKey defaultName: String) -> Bool { (object(forKey: defaultName) as? NSNumber)?.boolValue ?? false }
    override func persistentDomain(forName domainName: String) -> [String: Any]? { values }
    override func setPersistentDomain(_ domain: [String: Any], forName domainName: String) { values = domain }
    override func removePersistentDomain(forName domainName: String) { values.removeAll() }
    override func synchronize() -> Bool { true }
}
