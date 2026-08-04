import Foundation
import Security

/// The gateway API key. It is a secret even when the local gateway does not
/// check it, so it never goes into user defaults or into a file in the repo.
public protocol APIKeyStoring: AnyObject, Sendable {
    func readKey() -> String?
    func writeKey(_ key: String) throws
    func deleteKey() throws
}

extension APIKeyStoring {
    /// The key to send. Falls back to a non-secret placeholder because
    /// OpenAI-compatible clients require a non-empty field and a local LiteLLM
    /// gateway accepts anything there.
    public func effectiveKey() -> String {
        let stored = readKey()?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return stored.isEmpty ? APIKeyDefaults.placeholder : stored
    }
}

public enum APIKeyDefaults {
    /// Not a secret. Documented as a placeholder in the README.
    public static let placeholder = "local-placeholder"
}

public enum KeychainError: Error, LocalizedError {
    case status(OSStatus)

    public var errorDescription: String? {
        switch self {
        case .status(let code):
            let message = SecCopyErrorMessageString(code, nil) as String? ?? "unknown error"
            return "The keychain refused the request: \(message) (\(code))."
        }
    }
}

/// Generic-password item in the login keychain.
public final class KeychainAPIKeyStore: APIKeyStoring, @unchecked Sendable {
    private let service: String
    private let account: String

    public init(service: String = "com.punkjazz.minutes", account: String = "notes-endpoint-api-key") {
        self.service = service
        self.account = account
    }

    private var baseQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }

    public func readKey() -> String? {
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess, let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    public func writeKey(_ key: String) throws {
        let data = Data(key.utf8)
        let update: [String: Any] = [kSecValueData as String: data]
        let status = SecItemUpdate(baseQuery as CFDictionary, update as CFDictionary)
        if status == errSecSuccess { return }
        if status == errSecItemNotFound {
            var insert = baseQuery
            insert[kSecValueData as String] = data
            let addStatus = SecItemAdd(insert as CFDictionary, nil)
            guard addStatus == errSecSuccess else { throw KeychainError.status(addStatus) }
            return
        }
        throw KeychainError.status(status)
    }

    public func deleteKey() throws {
        let status = SecItemDelete(baseQuery as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError.status(status)
        }
    }
}

/// Keychain access needs a signed bundle and a user session. The CLI and the
/// tests use this instead.
public final class EnvironmentAPIKeyStore: APIKeyStoring, @unchecked Sendable {
    public static let variableName = "MINUTES_API_KEY"
    private let variable: String

    public init(variable: String = EnvironmentAPIKeyStore.variableName) {
        self.variable = variable
    }

    public func readKey() -> String? {
        ProcessInfo.processInfo.environment[variable]
    }

    public func writeKey(_ key: String) throws {}
    public func deleteKey() throws {}
}
