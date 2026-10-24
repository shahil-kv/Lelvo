import Foundation
import Security

/// Secrets live only in the Keychain, readable after first unlock so background uploads work,
/// and never synced to iCloud or other devices.
enum KeychainStore {
    enum Key: String, CaseIterable {
        case botToken, chatId, passphrase, fileKeySalt, fileMasterKey
        case tdApiId, tdApiHash, tdDatabaseKey, e2eMasterKey
    }

    private static let service = "com.shahil-kv.memvo"

    private static func query(_ key: Key) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: key.rawValue]
    }

    @discardableResult
    static func set(_ data: Data?, for key: Key) -> Bool {
        SecItemDelete(query(key) as CFDictionary)
        guard let data else { return true }
        var attrs = query(key)
        attrs[kSecValueData as String] = data
        attrs[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        return SecItemAdd(attrs as CFDictionary, nil) == errSecSuccess
    }

    static func data(for key: Key) -> Data? {
        var q = query(key)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess else { return nil }
        return out as? Data
    }

    @discardableResult
    static func set(_ string: String?, for key: Key) -> Bool {
        set(string.map { Data($0.utf8) }, for: key)
    }

    static func string(for key: Key) -> String? {
        data(for: key).map { String(decoding: $0, as: UTF8.self) }
    }

    static func wipe() {
        Key.allCases.forEach { set(nil as Data?, for: $0) }
    }
}
