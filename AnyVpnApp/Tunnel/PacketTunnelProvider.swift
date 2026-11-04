import Foundation
import NetworkExtension
import Darwin

private func tunnelError(_ msg: String) -> NSError {
    NSError(domain: "com.anyvpn.tunnel", code: 1,
            userInfo: [NSLocalizedDescriptionKey: msg])
}

@objc(PacketTunnelProvider)
final class PacketTunnelProvider: NEPacketTunnelProvider {
    private var session: OCSession?
    private var pump: TunnelPump?
    private var ocFd: Int32 = -1
    private let mainloopQueue = DispatchQueue(label: "com.anyvpn.tunnel.mainloop",
                                              qos: .userInitiated)
    private let log: (String) -> Void = { LogStore.append($0) }

    override func startTunnel(options: [String: NSObject]? = nil,
                              completionHandler: @escaping (Error?) -> Void) {
        LogStore.append("[tunnel] startTunnel 开始")
        guard
            let proto = protocolConfiguration as? NETunnelProviderProtocol,
            let cfg = proto.providerConfiguration as? [String: Any],
            let profileId = cfg["profileId"] as? String,
            let profile = ProfileStore.profile(withId: profileId)
        else {
            LogStore.append("[tunnel] ❌ 缺少线路配置")
            completionHandler(tunnelError("缺少线路配置：请先在 App 里选择并保存一条线路"))
            return
        }

        let ocConfig: [String: Any] = [
            "server": profile.server,
            "username": profile.username,
            "password": profile.secret("password"),
            "authgroup": profile.authgroup,
            "totpSecret": profile.secret("totpSecret"),
            "expectedCertHash": profile.secret("acceptedCertHash"),
            "disableDtls": profile.disableDtls,
            "appGroup": SharedConfig.appGroup,
            "profileId": profile.id,
        ]

        let sess = OCSession(config: ocConfig, log: log)
        session = sess

        // ① 先认证 + CSTP 握手拿到网关真实下发的 IP/DNS/路由/MTU，
        //    再安装接口参数（对齐安卓端 NativeBridge 的四步顺序，避免假地址闪断）
        guard let info = sess.connectAndGetIPInfo() else {
            let e = tunnelError(sess.lastError.isEmpty ? "认证失败" : sess.lastError)
            LogStore.append("[tunnel] ❌ \(e.localizedDescription)")
            completionHandler(e)
            return
        }

        let settings = makeSettings(info: info, profile: profile,
                                    remote: proto.serverAddress ?? profile.server)
        setTunnelNetworkSettings(settings) { [weak self] error in
            guard let self = self else { return }
            if let error = error {
                LogStore.append("[tunnel] ❌ 安装网络设置失败：\(error.localizedDescription)")
                completionHandler(error)
                return
            }

            // ② socketpair(DGRAM) 保包边界：一端交给 openconnect，另一端给 packetFlow 泵
            var fds: [Int32] = [-1, -1]
            guard socketpair(AF_UNIX, Int32(SOCK_DGRAM), 0, &fds) == 0 else {
                LogStore.append("[tunnel] ❌ socketpair 失败 errno=\(errno)")
                completionHandler(tunnelError("socketpair 创建失败"))
                return
            }
            self.ocFd = fds[0]
            guard sess.attachTunFd(fds[0]) else {
                close(fds[0]); close(fds[1])
                completionHandler(tunnelError("openconnect 接管 tun fd 失败"))
                return
            }

            let p = TunnelPump(flow: self.packetFlow, fd: fds[1], log: self.log)
            self.pump = p
            p.start()
            self.mainloopQueue.async {
                sess.runMainloop()
                LogStore.append("[tunnel] 会话结束")
                p.stop()
                sess.shutdown()
                if self.ocFd >= 0 { close(self.ocFd); self.ocFd = -1 }
            }

            LogStore.append("[tunnel] 隧道就绪：IP \(info["addr"] as? String ?? "?")"
                            + " / DNS \(self.dnsDescription(settings))")
            completionHandler(nil)
        }
    }

    override func stopTunnel(with reason: NEProviderStopReason,
                             completionHandler: @escaping () -> Void) {
        LogStore.append("[tunnel] stopTunnel reason=\(reason.rawValue)")
        session?.cancel()
        pump?.stop()
        // 排在 mainloop 之后，等 openconnect 真正退出再回 completion
        mainloopQueue.async { completionHandler() }
    }

    // MARK: - NEPacketTunnelNetworkSettings

    private func makeSettings(info: [String: Any], profile: VpnProfile,
                              remote: String) -> NEPacketTunnelNetworkSettings {
        let gateway = (info["gateway"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        let settings = NEPacketTunnelNetworkSettings(tunnelRemoteAddress: gateway ?? remote)

        let addr = info["addr"] as? String ?? "192.168.123.20"
        let mask = info["netmask"] as? String ?? "255.255.255.0"
        let v4 = NEIPv4Settings(addresses: [addr], subnetMasks: [mask])
        let routes = (info["splitIncludes"] as? [String] ?? []).compactMap { ipv4Route($0) }
        v4.includedRoutes = routes.isEmpty ? [NEIPv4Route.default()] : routes

        var v6Settings: NEIPv6Settings?
        if let addr6 = info["addr6"] as? String, !addr6.isEmpty {
            let prefix = Int(info["netmask6"] as? String ?? "") ?? 64
            let v6 = NEIPv6Settings(addresses: [addr6],
                                    networkPrefixLengths: [NSNumber(value: prefix)])
            v6.includedRoutes = [NEIPv6Route.default()]
            v6Settings = v6
        }

        var servers = info["dns"] as? [String] ?? []
        let overrideDNS = profile.tunnelDNSList
        if !overrideDNS.isEmpty { servers = overrideDNS }

        var dnsSettings: NEDNSSettings?
        if !servers.isEmpty {
            let dns = NEDNSSettings(servers: servers)
            if let domain = info["domain"] as? String, !domain.isEmpty {
                dns.searchDomains = [domain]
            }
            // 关键：matchDomains 含 "" = 隧道 DNS 接管全部域名；只填具体域名
            // 则形成 split-DNS，其余域名继续用系统 DNS（网关 DNS 不服务时
            // 用这个避免全机断网，同时游戏域名仍能拿到线路专属地址）。
            let match = profile.dnsMatchDomainList
            dns.matchDomains = match.isEmpty ? [""] : match
            dnsSettings = dns
        }

        apply(settings, ipv4: v4, ipv6: v6Settings, dns: dnsSettings)
        settings.mtu = NSNumber(value: info["mtu"] as? Int ?? 1400)
        return settings
    }

    /// iOS 26 SDK（Xcode 26 / Swift 6.2）把 NetworkExtension 的这几个属性
    /// 按 Swift 命名规范改成了小写开头；旧 SDK 仍是大写。用编译期分支兼容两者。
    private func apply(_ s: NEPacketTunnelNetworkSettings,
                       ipv4: NEIPv4Settings?,
                       ipv6: NEIPv6Settings?,
                       dns: NEDNSSettings?) {
        #if compiler(>=6.2)
        if let v = ipv4 { s.ipv4Settings = v }
        if let v = ipv6 { s.ipv6Settings = v }
        if let v = dns { s.dnsSettings = v }
        #else
        if let v = ipv4 { s.IPv4Settings = v }
        if let v = ipv6 { s.IPv6Settings = v }
        if let v = dns { s.DNSSettings = v }
        #endif
    }

    private func ipv4Route(_ text: String) -> NEIPv4Route? {
        let parts = text.split(separator: "/", maxSplits: 1, omittingEmptySubsequences: false)
        let dest = String(parts[0])
        guard !dest.isEmpty else { return nil }
        guard parts.count == 2 else {
            return NEIPv4Route(destinationAddress: dest, subnetMask: "255.255.255.255")
        }
        let m = String(parts[1])
        if let bits = Int(m), bits >= 0, bits <= 32 {
            let octets = (0..<4).map { i -> Int in
                let n = min(max(bits - i * 8, 0), 8)
                return n == 0 ? 0 : (0xFF << (8 - n)) & 0xFF
            }
            return NEIPv4Route(destinationAddress: dest,
                               subnetMask: octets.map(String.init).joined(separator: "."))
        }
        return NEIPv4Route(destinationAddress: dest, subnetMask: m)
    }

    private func dnsDescription(_ s: NEPacketTunnelNetworkSettings) -> String {
        #if compiler(>=6.2)
        let dns: NEDNSSettings? = s.dnsSettings
        #else
        let dns: NEDNSSettings? = s.DNSSettings
        #endif
        guard let d = dns else { return "（未设置，走系统 DNS）" }
        let match = d.matchDomains ?? []
        return d.servers.joined(separator: ",") + "（匹配：\(match.joined(separator: ","))）"
    }
}
