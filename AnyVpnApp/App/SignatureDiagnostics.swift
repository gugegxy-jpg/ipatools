import Foundation

/// 签名/权限自检。
///
/// App 在运行时读不到自己的 entitlements，但能读到内嵌的 provisioning profile，
/// 从里面能反推「实际生效了哪些能力」——重签名没带 NetworkExtension capability 时，
/// 系统会在 NETunnelProviderManager.loadAllFromPreferences 直接报 permission denied，
/// 只能靠这里把原因摊开。
struct SignatureDiagnostics {
    struct Item: Identifiable {
        let id = UUID()
        let title: String
        let value: String
        let ok: Bool
    }

    static var items: [Item] {
        var out: [Item] = []
        out.append(Item(title: "Bundle ID",
                        value: Bundle.main.bundleIdentifier ?? "-", ok: true))

        // 扩展包是否真的打进 App 里
        let appexURL = Bundle.main.builtInPlugInsURL?
            .appendingPathComponent("PacketTunnel.appex")
        let appexExists = appexURL.map { FileManager.default.fileExists(atPath: $0.path) } ?? false
        out.append(Item(title: "扩展包",
                        value: appexExists ? "已打包 ✅" : "缺失 ❌（重签时别丢 PlugIns）",
                        ok: appexExists))

        // App Group 容器：扩展要靠它读线路/凭据
        let container = FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: SharedConfig.appGroup)
        out.append(Item(title: "App Group 容器",
                        value: container?.lastPathComponent ?? "不可访问 ❌",
                        ok: container != nil))

        // 宿主 App 的描述文件
        guard let plist = provisionPlist(in: Bundle.main.bundleURL) else {
            out.append(Item(title: "描述文件",
                            value: "未找到 embedded.mobileprovision（未签名 / 非商店包）", ok: false))
            return out
        }
        out.append(Item(title: "描述文件", value: plist["Name"] as? String ?? "-", ok: true))
        if let exp = plist["ExpirationDate"] as? Date {
            out.append(Item(title: "过期时间",
                            value: exp.formatted(date: .numeric, time: .shortened),
                            ok: exp > Date()))
        }
        if let team = (plist["Entitlements"] as? [String: Any])?["application-identifier"] as? String {
            out.append(Item(title: "Team/前缀", value: team, ok: true))
        }
        let ents = plist["Entitlements"] as? [String: Any] ?? [:]
        let ne = ents["com.apple.developer.networking.networkextension"] as? [String] ?? []
        out.append(Item(title: "NetworkExtension",
                        value: ne.isEmpty ? "缺失 ❌ 装不了 VPN，需重签" : ne.joined(separator: ", "),
                        ok: !ne.isEmpty))
        let groups = ents["com.apple.security.application-groups"] as? [String] ?? []
        out.append(Item(title: "App Group",
                        value: groups.isEmpty ? "缺失 ❌ 扩展读不到凭据" : groups.joined(separator: ", "),
                        ok: !groups.isEmpty))
        let keychain = ents["keychain-access-groups"] as? [String] ?? []
        out.append(Item(title: "Keychain Group",
                        value: keychain.isEmpty ? "缺失 ❌" : keychain.joined(separator: ", "),
                        ok: !keychain.isEmpty))

        // 描述文件是不是给这个 App 用的：application-identifier = TEAMID.<bundle id>
        let appId = ents["application-identifier"] as? String ?? ""
        let myBundle = Bundle.main.bundleIdentifier ?? ""
        if !appId.isEmpty && !myBundle.isEmpty && !appId.hasSuffix(myBundle) {
            out.append(Item(title: "App ID 匹配",
                            value: "描述文件对应的是 \(appId)，不是当前 App（\(myBundle)）❌",
                            ok: false))
        }
        // 通配符 profile（TEAMID.*）永远不可能带 Network Extensions / App Groups，
        // 这类能力必须显式 App ID
        if keychain.contains(where: { $0.hasSuffix("*") }) {
            out.append(Item(title: "描述文件类型",
                            value: "通配符（Wildcard）profile：不可能包含 Network Extensions / "
                                + "App Groups 能力，必须换成显式 App ID 的 profile ❌",
                            ok: false))
        }

        // appex 的描述文件：App 与 appex 是两份签名，任一份缺能力都会失败
        if let appexURL = appexURL, appexExists {
            if let appexPlist = provisionPlist(in: appexURL) {
                let aEnts = appexPlist["Entitlements"] as? [String: Any] ?? [:]
                let aNE = aEnts["com.apple.developer.networking.networkextension"] as? [String] ?? []
                out.append(Item(title: "appex 描述文件",
                                value: appexPlist["Name"] as? String ?? "-", ok: true))
                out.append(Item(title: "appex NetworkExtension",
                                value: aNE.isEmpty ? "缺失 ❌ 扩展没签上" : aNE.joined(separator: ", "),
                                ok: !aNE.isEmpty))
            } else {
                out.append(Item(title: "appex 描述文件",
                                value: "未找到（appex 可能没单独签）❌", ok: false))
            }
        }

        let kc = KeychainStore.selfTest()
        out.append(Item(title: "Keychain 可写", value: kc, ok: kc.hasPrefix("✅")))

        if ne.isEmpty {
            out.append(Item(title: "结论",
                            value: "描述文件没有 Network Extensions 能力："
                                + "需在开发者后台给该 AppID 勾选 Network Extensions 并重新生成描述文件，"
                                + "重签时把 App 与 appex 一起签上。",
                            ok: false))
        }
        return out
    }

    /// 有没有致命项（缺能力/缺扩展包）
    static var hasBlockingIssue: Bool {
        items.contains { !$0.ok && $0.title != "Keychain 可写" }
    }

    static var summary: String {
        items.map { "\($0.ok ? "✅" : "❌") \($0.title)：\($0.value)" }.joined(separator: "\n")
    }

    /// 内嵌描述文件是 CMS 包裹的 plist，直接从二进制里截出那段 XML 解析
    private static func provisionPlist(in bundleURL: URL) -> [String: Any]? {
        let url = bundleURL.appendingPathComponent("embedded.mobileprovision")
        guard let data = try? Data(contentsOf: url) else { return nil }
        let text = String(decoding: data, as: UTF8.self)
        guard let r = text.range(of: "<?xml"), let e = text.range(of: "</plist>") else { return nil }
        let xml = String(text[r.lowerBound..<e.upperBound])
        guard let obj = try? PropertyListSerialization.propertyList(from: Data(xml.utf8), format: nil),
              let dict = obj as? [String: Any] else { return nil }
        return dict
    }
}
