import Foundation
import Security

/// Secrets live only in the Keychain, readable after first unlock so background uploads work,
/// and never synced to iCloud or other devices.
enum KeychainStore {
    enum Key: String, CaseIterable {
        case botToken, chatId, passphrase, fileKeySalt, fileMasterKey
        case tdApiId, tdApiHash, tdDatabaseKey, e2eMasterKey
    }

    private static let service = "com.shahil-kv.lelvo"

    private static func query(_ key: Key) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: key.rawValue]
    }

    /// Stores `data`, or removes the item for nil. On a Mac, an item stored by another build of the app (each local
    /// build signs differently) can be read but not deleted; then it's overwritten instead, and a failure is logged
    /// (the key name and status only) rather than ignored.
    @discardableResult
    static func set(_ data: Data?, for key: Key) -> Bool {
        let deleted = SecItemDelete(query(key) as CFDictionary)
        guard let data else {
            if deleted == errSecSuccess || deleted == errSecItemNotFound { return true }
            AppLog.shared.warn("Keychain: couldn't remove \(key.rawValue) (status \(deleted))")
            return false
        }
        var attrs = query(key)
        attrs[kSecValueData as String] = data
        attrs[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let added = SecItemAdd(attrs as CFDictionary, nil)
        if added == errSecDuplicateItem {
            let updated = SecItemUpdate(query(key) as CFDictionary, [kSecValueData as String: data] as CFDictionary)
            if updated != errSecSuccess { AppLog.shared.warn("Keychain: couldn't replace \(key.rawValue) (status \(updated))") }
            return updated == errSecSuccess
        }
        if added != errSecSuccess { AppLog.shared.warn("Keychain: couldn't store \(key.rawValue) (status \(added))") }
        return added == errSecSuccess
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

    /// Removes every item; returns the keys that couldn't be removed.
    @discardableResult
    static func wipe() -> [Key] {
        Key.allCases.filter { !set(nil as Data?, for: $0) }
    }
}
