import Foundation
import Security

public enum PairingStoreError: Error, LocalizedError {
    case keychain(OSStatus)
    case invalidCode
    case random(OSStatus)

    public var errorDescription: String? {
        switch self {
        case let .keychain(status): return "Keychain operation failed (\(status))."
        case .invalidCode: return "A pairing code must decode to exactly 32 bytes."
        case let .random(status): return "Could not generate a secure pairing code (\(status))."
        }
    }
}

public protocol PairingSecretStoring: AnyObject {
    func load(account: String) throws -> Data?
    func save(_ secret: Data, account: String) throws
    func delete(account: String) throws
}

/// The Keychain service is intentionally independent of the UserDefaults
/// configuration.  This keeps pairing material out of plist files and logs.
public final class KeychainPairingSecretStore: PairingSecretStoring {
    private let service: String

    public init(service: String = "com.yalinalagul.sidecursor.native-v2") {
        self.service = service
    }

    public func load(account: String) throws -> Data? {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account,
            kSecReturnData: true,
            kSecMatchLimit: kSecMatchLimitOne,
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else {
            throw PairingStoreError.keychain(status)
        }
        return data
    }

    public func save(_ secret: Data, account: String) throws {
        guard secret.count == 32 else { throw PairingStoreError.invalidCode }
        let baseQuery: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account,
        ]
        let attributes: [CFString: Any] = [
            kSecValueData: secret,
            kSecAttrAccessible: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]
        let status = SecItemUpdate(baseQuery as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            var item = baseQuery
            for (key, value) in attributes { item[key] = value }
            let addStatus = SecItemAdd(item as CFDictionary, nil)
            guard addStatus == errSecSuccess else { throw PairingStoreError.keychain(addStatus) }
            return
        }
        guard status == errSecSuccess else { throw PairingStoreError.keychain(status) }
    }

    public func delete(account: String) throws {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account,
        ]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw PairingStoreError.keychain(status)
        }
    }
}

public enum PairingCode {
    public static func generate() throws -> Data {
        var bytes = [UInt8](repeating: 0, count: 32)
        let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        guard status == errSecSuccess else { throw PairingStoreError.random(status) }
        return Data(bytes)
    }

    public static func encode(_ secret: Data) throws -> String {
        guard secret.count == 32 else { throw PairingStoreError.invalidCode }
        return secret.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    public static func decode(_ code: String) throws -> Data {
        var normalized = code.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        normalized.append(String(repeating: "=", count: (4 - normalized.count % 4) % 4))
        guard let data = Data(base64Encoded: normalized), data.count == 32 else {
            throw PairingStoreError.invalidCode
        }
        return data
    }
}

public final class InMemoryPairingSecretStore: PairingSecretStoring {
    private var values: [String: Data] = [:]

    public init() {}

    public func load(account: String) throws -> Data? { values[account] }

    public func save(_ secret: Data, account: String) throws {
        guard secret.count == 32 else { throw PairingStoreError.invalidCode }
        values[account] = secret
    }

    public func delete(account: String) throws { values.removeValue(forKey: account) }
}
