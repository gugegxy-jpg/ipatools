import Foundation
import Security

/// App / Extension 共享的 Keychain 封装。
/// 不显式指定 kSecAttrAccessGroup：entitlements 的 keychain-access-groups 第一项
/// 就是默认 group，两个 target 用同一份 entitlement 因此天然共享。
/// AfterFirstUnlockThisDeviceOnly：锁屏后扩展仍可读，且不进 iCloud/备份。
enum KeychainStore {
    @discardableResult
    static func set(_ value: String, for account: String) -> Bool {
        guard let data = value.data(using: .utf8) else { return false }
        let query = baseQuery(account)
        SecItemDelete(query as CFDictionary)
        var add = query
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        return SecItemAdd(add as CFDictionary, nil) == errSecSuccess
    }

    static func get(_ account: String) -> String? {
        var query = baseQuery(account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func remove(_ account: String) {
        SecItemDelete(baseQuery(account) as CFDictionary)
    }

    private static func baseQuery(_ account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: SharedConfig.keychainService,
            kSecAttrAccount as String: account,
        ]
    }
}
