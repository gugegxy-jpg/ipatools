import SwiftUI
import UIKit
import NetworkExtension

struct ContentView: View {
    @EnvironmentObject private var vpn: VPNManager

    @State private var profiles: [VpnProfile] = []
    @State private var selectedId: String?
    @State private var editTarget: VpnProfile?
    @State private var editIsNew = false
    @State private var showLog = false
    @State private var showDiag = false
    @State private var diagItems: [SignatureDiagnostics.Item] = []

    private let ticker = Timer.publish(every: 1, on: .main, in: .common).autoconnect()
    private var selected: VpnProfile? { profiles.first { $0.id == selectedId } }
    private var hasBlockingIssue: Bool {
        diagItems.contains { !$0.ok && $0.title != "Keychain 可写" }
    }

    var body: some View {
        NavigationView {
            ScrollView {
                VStack(spacing: 16) {
                    statusCard
                    profilesSection
                    notesCard
                    footerButtons
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 16)
            }
            .navigationTitle("AnyVpn")
            .appGlassScene()
            .onAppear { reload(); vpn.refresh(); refreshDiag() }
            .onReceive(ticker) { _ in vpn.refreshStatus() }
            .sheet(item: $editTarget) { p in
                ProfileEditView(profile: p, isNew: editIsNew, onSave: reload)
            }
            .sheet(isPresented: $showLog) { LogView() }
            .sheet(isPresented: $showDiag) { SignatureDiagnosticsView() }
        }
        .navigationViewStyle(.stack)
    }

    // MARK: - 状态卡

    private var statusCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                Circle()
                    .fill(vpn.status == .connected ? Color.green : Color.secondary)
                    .frame(width: 10, height: 10)
                Text(vpn.statusText).font(.title3).fontWeight(.semibold)
                Spacer()
                if let p = selected {
                    Text(p.displayName).font(.subheadline).foregroundColor(.secondary)
                }
            }
            if let e = vpn.lastError {
                Text(e).font(.footnote).foregroundColor(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if hasBlockingIssue {
                Button { showDiag = true } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "exclamationmark.triangle.fill")
                        Text("签名能力可能缺失，VPN 连不上：点这里看诊断")
                    }
                    .font(.footnote)
                    .foregroundColor(.orange)
                }
            }
            Button(vpn.status == .connected ? "断开" : "连接") {
                if vpn.status == .connected {
                    vpn.disconnect()
                } else if let p = selected {
                    vpn.connect(profile: p)
                }
            }
            .frame(maxWidth: .infinity)
            .disabled(selected == nil || vpn.isBusy)
            .appGlassButton(prominent: true)
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .appGlassCard(tint: vpn.status == .connected ? .green : .blue, prominent: true)
    }

    // MARK: - 线路

    private var profilesSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("线路").font(.headline).padding(.leading, 4)
            if profiles.isEmpty {
                Text("还没有线路，先添加一条")
                    .font(.footnote).foregroundColor(.secondary)
                    .padding(.leading, 4)
            }
            ForEach(profiles) { p in profileRow(p) }
            Text("点按选中线路，再点一次可编辑")
                .font(.caption).foregroundColor(.secondary)
                .padding(.leading, 4)
            Button("＋ 添加线路") {
                editTarget = VpnProfile()
                editIsNew = true
            }
            .frame(maxWidth: .infinity)
            .appGlassButton(prominent: false)
        }
    }

    private func profileRow(_ p: VpnProfile) -> some View {
        HStack(spacing: 12) {
            Image(systemName: p.id == selectedId ? "checkmark.circle.fill" : "circle")
                .font(.title3)
                .foregroundColor(p.id == selectedId ? .blue : .secondary)
            VStack(alignment: .leading, spacing: 3) {
                Text(p.displayName).font(.body).fontWeight(.medium)
                Text(p.server).font(.caption).foregroundColor(.secondary)
            }
            Spacer()
            if p.id == selectedId {
                Text("已选中").font(.caption).foregroundColor(.blue)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .appGlassCard(tint: .blue, prominent: p.id == selectedId)
        .onTapGesture {
            if selectedId == p.id {
                // 再次点已选中的行 = 编辑
                editTarget = p
                editIsNew = false
            } else {
                selectedId = p.id
                ProfileStore.setActiveId(p.id)
            }
        }
    }

    private var notesCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("DNS 与选线").font(.headline)
            Text("DNS 由系统的 VPN 配置统一接管，不再有「回落系统解析」路径。"
                 + "若网关 DNS 不服务，在编辑页把游戏域名填进「仅这些域名走隧道 DNS」，"
                 + "其余域名仍走系统 DNS，避免全机断网。")
                .font(.footnote).foregroundColor(.secondary)
            Text("首次点「连接」时，iOS 会弹出「AnyVpnApp 想要添加 VPN 配置」，必须点「允许」；"
                 + "配置会写进「设置 → 通用 → VPN 与设备管理」。"
                 + "若之前误点过「不允许」，请到那里重新允许。")
                .font(.footnote).foregroundColor(.secondary)
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .appGlassCard(tint: .purple)
    }

    private var footerButtons: some View {
        HStack(spacing: 12) {
            Button("连接日志") { showLog = true }
                .frame(maxWidth: .infinity)
                .appGlassButton(prominent: false)
            Button("签名诊断") { showDiag = true }
                .frame(maxWidth: .infinity)
                .appGlassButton(prominent: false)
        }
    }

    // MARK: - 数据

    private func reload() {
        profiles = ProfileStore.all()
        selectedId = ProfileStore.activeId() ?? profiles.first?.id
        if let id = selectedId { ProfileStore.setActiveId(id) }
    }

    private func refreshDiag() {
        diagItems = SignatureDiagnostics.items
    }
}

struct LogView: View {
    @Environment(\.presentationMode) private var presentation
    @EnvironmentObject private var vpn: VPNManager
    @State private var text = ""
    @State private var showRemoveConfirm = false
    @State private var copied = false
    private let ticker = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        NavigationView {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    Text(text.isEmpty ? "（暂无日志）" : text)
                        .font(.system(size: 11, design: .monospaced))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                    Button(copied ? "已复制 ✅" : "复制日志") {
                        UIPasteboard.general.string = text
                        copied = true
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { copied = false }
                    }
                    .frame(maxWidth: .infinity)
                    .appGlassButton(prominent: true)
                }
                .padding(16)
            }
            .navigationTitle("连接日志")
            .appGlassScene()
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    HStack(spacing: 10) {
                        Button("复制") { UIPasteboard.general.string = text }
                            .appGlassButton(prominent: false)
                        Button("清空") { LogStore.clear(); text = "" }
                            .appGlassButton(prominent: false)
                    }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Menu {
                        Button("删除系统 VPN 配置", role: .destructive) { showRemoveConfirm = true }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                }
            }
            .onAppear { text = LogStore.read() }
            .onReceive(ticker) { _ in text = LogStore.read() }
            .alert(isPresented: $showRemoveConfirm) {
                Alert(title: Text("删除系统 VPN 配置？"),
                      message: Text("只会删掉系统里的 VPN 描述，线路和密钥保留。"),
                      primaryButton: .destructive(Text("删除")) { vpn.removeConfiguration() },
                      secondaryButton: .cancel())
            }
        }
        .navigationViewStyle(.stack)
    }
}

/// 签名诊断详情：把「实际生效了哪些能力」摊开给用户看
struct SignatureDiagnosticsView: View {
    @Environment(\.presentationMode) private var presentation
    @State private var items: [SignatureDiagnostics.Item] = []
    @State private var neText = "正在向系统查询 VPN 配置权限…"
    @State private var neOK = false

    var body: some View {
        NavigationView {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    Text("VPN 能否安装取决于签名：描述文件缺能力时系统直接 permission denied。")
                        .font(.footnote).foregroundColor(.secondary)

                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 6) {
                            Text(neOK ? "✅" : "❌")
                            Text("系统权限实测").font(.subheadline).fontWeight(.semibold)
                        }
                        Text(neText)
                            .font(.system(size: 12, design: .monospaced))
                            .foregroundColor(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .appGlassCard(tint: neOK ? .green : .red, prominent: false)

                    ForEach(items) { item in
                        VStack(alignment: .leading, spacing: 4) {
                            HStack(spacing: 6) {
                                Text(item.ok ? "✅" : "❌")
                                Text(item.title).font(.subheadline).fontWeight(.semibold)
                            }
                            Text(item.value)
                                .font(.system(size: 12, design: .monospaced))
                                .foregroundColor(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .appGlassCard(tint: item.ok ? .green : .red, prominent: false)
                    }
                    VStack(alignment: .leading, spacing: 6) {
                        Text("重签要点").font(.subheadline).fontWeight(.semibold)
                        Text("① 开发者后台给该 AppID 勾选 Network Extensions（顺便 App Groups / Keychain Sharing），重新生成描述文件。\n"
                             + "② App 与 appex 分别签，签名里都要含 com.apple.developer.networking.networkextension = packet-tunnel-provider。\n"
                             + "③ 别让重签工具重建 appex 的 Info.plist（会再把 NSExtension 弄丢 → 装不上）。")
                            .font(.footnote).foregroundColor(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .appGlassCard(tint: .purple, prominent: false)
                }
                .padding(16)
            }
            .navigationTitle("签名诊断")
            .appGlassScene()
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("复制") { UIPasteboard.general.string = SignatureDiagnostics.summary }
                        .appGlassButton(prominent: false)
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("关闭") { presentation.wrappedValue.dismiss() }
                        .appGlassButton(prominent: true)
                }
            }
            .onAppear {
                items = SignatureDiagnostics.items
                NETunnelProviderManager.loadAllFromPreferences { managers, error in
                    DispatchQueue.main.async {
                        if let e = error {
                            let ns = e as NSError
                            neText = "\(ns.localizedDescription)（\(ns.domain) #\(ns.code)）"
                            neOK = false
                        } else {
                            neText = "系统允许读写 VPN 配置（已有 \(managers?.count ?? 0) 条）"
                            neOK = true
                        }
                    }
                }
            }
        }
        .navigationViewStyle(.stack)
    }
}
