import Foundation

/// Where settings are read from and written to. The app uses user defaults;
/// tests use the in-memory store.
public protocol SettingsStoring: AnyObject, Sendable {
    func load() -> AppSettings
    func save(_ settings: AppSettings)
}

public final class InMemorySettingsStore: SettingsStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var settings: AppSettings

    public init(_ settings: AppSettings = AppSettings()) {
        self.settings = settings
    }

    public func load() -> AppSettings {
        lock.lock()
        defer { lock.unlock() }
        return settings
    }

    public func save(_ settings: AppSettings) {
        lock.lock()
        defer { lock.unlock() }
        self.settings = settings
    }
}

/// Settings in user defaults, stored as one JSON blob so adding a field never
/// leaves half-written state behind.
public final class UserDefaultsSettingsStore: SettingsStoring, @unchecked Sendable {
    /// Both the app and the command line tool read the same suite, so a
    /// setting changed in one is visible in the other.
    public static let suiteName = "com.punkjazz.minutes"

    private let defaults: UserDefaults
    private let key = "minutes.settings.v1"

    public init(defaults: UserDefaults = UserDefaults(suiteName: UserDefaultsSettingsStore.suiteName) ?? .standard) {
        self.defaults = defaults
    }

    public func load() -> AppSettings {
        guard
            let data = defaults.data(forKey: key),
            let decoded = try? JSONDecoder().decode(AppSettings.self, from: data)
        else {
            return AppSettings()
        }
        return decoded
    }

    public func save(_ settings: AppSettings) {
        guard let data = try? JSONEncoder().encode(settings) else { return }
        defaults.set(data, forKey: key)
    }
}
