import Foundation
import NetworkExtension

/// 宿主 App 侧：安装/更新 NETunnelProviderManager 配置并启停隧道。
/// Extension 只从 providerConfiguration 拿 profileId，凭据由 App 写进共享 Keychain。
final class VPNManager: ObservableObject {
    @Published var status: NEVPNStatus = .invalid
    @Published var lastError: String?
    @Published var connectedProfileId: String?

    private var manager: NETunnelProviderManager?

    init() {
        NotificationCenter.default.addObserver(
            self, selector: #selector(statusDidChange(_:)),
            name: .NEVPNStatusDidChange, object: nil)
    }

    @objc private func statusDidChange(_ note: Notification) {
        guard let connection = note.object as? NEVPNConnection else { return }
        DispatchQueue.main.async {
            self.status = connection.status
            if connection.status == .disconnected { self.connectedProfileId = nil }
        }
    }

    var statusText: String {
        switch status {
        case .invalid: return "未安装配置"
        case .disconnected: return "已断开"
        case .connecting: return "连接中…"
        case .connected: return "已连接"
        case .reasserting: return "重连中…"
        case .disconnecting: return "断开中…"
        @unknown default: return "未知状态"
        }
    }

    var isBusy: Bool { status == .connecting || status == .reasserting || status == .disconnecting }

    func refresh() {
        NETunnelProviderManager.loadAllFromPreferences { [weak self] managers, error in
            DispatchQueue.main.async {
                guard let self = self else { return }
                if let e = error { self.lastError = e.localizedDescription; return }
                self.manager = managers?.first
                self.status = self.manager?.connection.status ?? .invalid
            }
        }
    }

    /// 状态通知偶尔会漏（杀进程重启），界面定时调用补一次
    func refreshStatus() {
        DispatchQueue.main.async {
            if let s = self.manager?.connection.status { self.status = s }
        }
    }

    func connect(profile: VpnProfile) {
        ProfileStore.setActiveId(profile.id)
        lastError = nil
        LogStore.append("[app] 正在连接 \(profile.displayName) …")
        loadOrCreate { [weak self] result in
            guard let self = self else { return }
            switch result {
            case .failure(let e):
                self.fail("读取 VPN 配置失败：\(e.localizedDescription)")
            case .success(let m):
                let proto = NETunnelProviderProtocol()
                proto.providerBundleIdentifier = SharedConfig.tunnelBundleIdentifier
                proto.serverAddress = profile.server
                proto.username = profile.username
                proto.providerConfiguration = ["profileId": profile.id]
                proto.disconnectOnSleep = false
                m.protocolConfiguration = proto
                m.localizedDescription = "AnyVpn"
                m.isEnabled = true
                m.isOnDemandEnabled = false
                m.saveToPreferences { [weak self] err in
                    guard let self = self else { return }
                    if let e = err {
                        self.fail("保存 VPN 配置失败：\(e.localizedDescription)")
                        return
                    }
                    // saveToPreferences 之后必须重新 load，直接 start 会拿到陈旧对象
                    NETunnelProviderManager.loadAllFromPreferences { [weak self] managers, _ in
                        DispatchQueue.main.async {
                            guard let self = self else { return }
                            guard let fresh = managers?.first else {
                                self.fail("VPN 配置未生效（系统未返回配置）")
                                return
                            }
                            self.manager = fresh
                            do {
                                try fresh.connection.startVPNTunnel()
                                self.connectedProfileId = profile.id
                                self.status = .connecting
                            } catch {
                                self.fail("启动隧道失败：\(error.localizedDescription)")
                            }
                        }
                    }
                }
            }
        }
    }

    func disconnect() {
        LogStore.append("[app] 正在断开…")
        manager?.connection.stopVPNTunnel()
    }

    func removeConfiguration() {
        manager?.removeFromPreferences { [weak self] err in
            DispatchQueue.main.async {
                guard let self = self else { return }
                if let e = err { self.lastError = e.localizedDescription; return }
                self.manager = nil
                self.status = .invalid
                self.connectedProfileId = nil
                LogStore.append("[app] 已删除系统 VPN 配置")
            }
        }
    }

    private func loadOrCreate(_ done: @escaping (Result<NETunnelProviderManager, Error>) -> Void) {
        if let m = manager { done(.success(m)); return }
        NETunnelProviderManager.loadAllFromPreferences { managers, error in
            if let e = error { done(.failure(e)); return }
            done(.success(managers?.first ?? NETunnelProviderManager()))
        }
    }

    private func fail(_ msg: String) {
        DispatchQueue.main.async {
            self.lastError = msg
            self.status = .disconnected
            LogStore.append("[app] ❌ \(msg)")
        }
    }
}
