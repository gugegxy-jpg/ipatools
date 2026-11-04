import Foundation

/// App 与 Packet Tunnel Extension 的共享常量。
/// 改 bundle id / Team 时，App Group 与 Keychain Group 必须与 entitlements 同步修改。
enum SharedConfig {
    static let appGroup = "group.com.anyvpn.app"
    static let tunnelBundleIdentifier = "com.anyvpn.app.tunnel"
    static let keychainService = "com.anyvpn.app"
    static let logFileName = "anyvpn.log"
    static let maxLogBytes = 256 * 1024

    static var defaults: UserDefaults {
        UserDefaults(suiteName: appGroup) ?? .standard
    }

    static var containerURL: URL {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroup)
            ?? FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    }
}

/// 一条「线路」。机密（密码 / TOTP 密钥 / 证书指纹）不放在这里，走 Keychain。
struct VpnProfile: Codable, Identifiable, Equatable {
    var id: String = UUID().uuidString
    var name: String = ""
    var server: String = ""
    var username: String = ""
    var authgroup: String = ""
    /// 覆盖网关下发的隧道 DNS，逗号分隔。留空 = 用网关下发的。
    var tunnelDNS: String = ""
    /// split-DNS：只把这些域名交给隧道 DNS，其余走系统 DNS。
    /// 配了它就能绕开「网关 DNS 不服务导致全机断网」；留空 = 全部走隧道 DNS。
    var dnsMatchDomains: String = ""
    /// 实测 DTLS/UDP 443 在多数网络握不上手，默认纯 CSTP(TCP)
    var disableDtls: Bool = true

    var displayName: String { name.isEmpty ? server : name }
}

enum ProfileStore {
    private static let kProfiles = "com.anyvpn.profiles"
    private static let kActive = "com.anyvpn.activeProfileId"

    static func all() -> [VpnProfile] {
        guard let data = SharedConfig.defaults.data(forKey: kProfiles),
              let list = try? JSONDecoder().decode([VpnProfile].self, from: data) else { return [] }
        return list
    }

    static func save(_ list: [VpnProfile]) {
        guard let data = try? JSONEncoder().encode(list) else { return }
        SharedConfig.defaults.set(data, forKey: kProfiles)
    }

    static func activeId() -> String? { SharedConfig.defaults.string(forKey: kActive) }

    static func setActiveId(_ id: String) { SharedConfig.defaults.set(id, forKey: kActive) }

    static func profile(withId id: String) -> VpnProfile? { all().first { $0.id == id } }

    static func active() -> VpnProfile? {
        let list = all()
        if let id = activeId(), let hit = list.first(where: { $0.id == id }) { return hit }
        return list.first
    }
}

extension VpnProfile {
    /// 逗号/换行分隔的配置串 → 去空白后的数组
    static func list(_ text: String) -> [String] {
        text.split(whereSeparator: { $0 == "," || $0 == "\n" || $0 == " " })
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    var tunnelDNSList: [String] { VpnProfile.list(tunnelDNS) }
    var dnsMatchDomainList: [String] { VpnProfile.list(dnsMatchDomains) }

    func secret(_ field: String) -> String {
        if let v = KeychainStore.get("\(id).\(field)"), !v.isEmpty { return v }
        // TOTP 密钥对齐安卓端「按账号」的索引方式：同账号换线路不必重填
        if field == "totpSecret" {
            let u = username.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if !u.isEmpty { return KeychainStore.get("totp.\(u)") ?? "" }
        }
        return ""
    }

    func setSecret(_ value: String, field: String) {
        KeychainStore.set(value, for: "\(id).\(field)")
    }
}
