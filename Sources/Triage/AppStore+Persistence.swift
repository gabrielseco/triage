import Foundation

/// Settings and state are JSON in UserDefaults. A decode failure reads as nil, so renaming a key or changing a
/// persisted type's shape resets it.
extension AppStore {
    /// Settings and state live here. In mock mode it is a throwaway domain, so the installed app's are untouched.
    static let defaults: UserDefaults = {
        guard MockMode.isActive else { return .standard }
        // Never the real domain: without the suite there is nothing safe to fall back to.
        guard let suite = UserDefaults(suiteName: MockMode.defaultsSuite) else {
            fatalError("Mock mode could not open its own settings domain")
        }
        suite.removePersistentDomain(forName: MockMode.defaultsSuite)
        return suite
    }()

    /// What mock mode starts from instead of saved settings (docs/plans/MOCK.md).
    func applyMockScenario() {
        guard let mock = MockMode.world else { return }
        repos = mock.repos
        gitlabHost = mock.gitlabHost ?? ""
        linearEnabled = mock.hasLinear
        var seen = seenPRs
        seen.startWatching(mock.allRepos, now: mock.watchingSince)
        seenPRs = seen
    }

    func save<T: Encodable>(_ value: T, _ key: String) {
        Self.defaults.set(try? JSONEncoder().encode(value), forKey: key)
    }

    static func load<T: Decodable>(_ key: String) -> T? {
        Self.defaults.data(forKey: key).flatMap { try? JSONDecoder().decode(T.self, from: $0) }
    }
}
