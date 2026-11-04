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

    /// 自检：写一条临时项再读回，确认 keychain-access-groups 真的可用。
    /// 重签没带 keychain-access-groups 时会拿到 -34018 (errSecMissingEntitlement)。
    static func selfTest() -> String {
        let account = "__selftest__"
        defer { remove(account) }
        guard let data = "ok".data(using: .utf8) else { return "❌ 编码失败" }
        let query = baseQuery(account)
        SecItemDelete(query as CFDictionary)
        var add = query
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let status = SecItemAdd(add as CFDictionary, nil)
        guard status == errSecSuccess else {
            return "❌ 写入失败 OSStatus=\(status) \(statusText(status))"
        }
        guard let back = get(account) else { return "❌ 写入成功但读不回来" }
        return back == "ok" ? "✅ 可写可读" : "❌ 读回内容异常"
    }

    private static func statusText(_ status: OSStatus) -> String {
        switch status {
        case errSecMissingEntitlement: return "缺少权限（重签没带 keychain-access-groups）"
        case errSecDuplicateItem: return "已存在同名项"
        case errSecItemNotFound: return "找不到条目"
        case errSecInteractionNotAllowed: return "设备未解锁"
        default: return "未知错误"
        }
    }

    private static func baseQuery(_ account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: SharedConfig.keychainService,
            kSecAttrAccount as String: account,
        ]
    }
}
