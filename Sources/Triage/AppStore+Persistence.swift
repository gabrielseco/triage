import Foundation

/// Settings and state are JSON in UserDefaults. A decode failure reads as nil, so renaming a key or changing a
/// persisted type's shape resets it.
extension AppStore {
    func save<T: Encodable>(_ value: T, _ key: String) {
        UserDefaults.standard.set(try? JSONEncoder().encode(value), forKey: key)
    }

    static func load<T: Decodable>(_ key: String) -> T? {
        UserDefaults.standard.data(forKey: key).flatMap { try? JSONDecoder().decode(T.self, from: $0) }
    }
}
