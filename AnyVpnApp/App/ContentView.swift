import SwiftUI
import UIKit

struct ContentView: View {
    @EnvironmentObject private var vpn: VPNManager

    @State private var profiles: [VpnProfile] = []
    @State private var selectedId: String?
    @State private var editTarget: VpnProfile?
    @State private var editIsNew = false
    @State private var showLog = false
    @State private var showRemoveConfirm = false

    private let ticker = Timer.publish(every: 1, on: .main, in: .common).autoconnect()
    private var selected: VpnProfile? { profiles.first { $0.id == selectedId } }

    var body: some View {
        NavigationView {
            ScrollView {
                VStack(spacing: 20) {
                    statusCard

                    VStack(alignment: .leading, spacing: 10) {
                        Text("线路").font(.headline).padding(.leading, 4)
                        if profiles.isEmpty {
                            Text("还没有线路，先添加一条")
                                .font(.footnote).foregroundColor(.secondary)
                                .padding(.leading, 4)
                        }
                        ForEach(profiles) { p in profileRow(p) }
                        Button("＋ 添加线路") {
                            editTarget = VpnProfile()
                            editIsNew = true
                        }
                        .appGlassButton(prominent: false)
                    }

                    notesCard

                    Button("查看 / 复制连接日志") { showLog = true }
                        .appGlassButton(prominent: false)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 20)
            }
            .navigationTitle("AnyVpn")
            .appGlassScene()
            .onAppear { reload(); vpn.refresh() }
            .onReceive(ticker) { _ in vpn.refreshStatus() }
            .sheet(item: $editTarget) { p in
                ProfileEditView(profile: p, isNew: editIsNew, onSave: reload)
            }
            .sheet(isPresented: $showLog) { LogView() }
            .alert(isPresented: $showRemoveConfirm) {
                Alert(title: Text("删除系统 VPN 配置？"),
                      message: Text("只会删掉系统里的 VPN 描述，线路和密钥保留。"),
                      primaryButton: .destructive(Text("删除")) { vpn.removeConfiguration() },
                      secondaryButton: .cancel())
            }
        }
        .navigationViewStyle(.stack)
    }

    // MARK: - 卡片

    private var statusCard: some View {
        VStack(alignment: .leading, spacing: 16) {
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
            }
            HStack(spacing: 12) {
                Button(vpn.status == .connected ? "断开" : "连接") {
                    if vpn.status == .connected {
                        vpn.disconnect()
                    } else if let p = selected {
                        vpn.connect(profile: p)
                    }
                }
                .disabled(selected == nil || vpn.isBusy)
                .appGlassButton(prominent: true)

                Button("删除配置") { showRemoveConfirm = true }
                    .appGlassButton(prominent: false)
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .appGlassCard(tint: vpn.status == .connected ? .green : .blue, prominent: true)
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
            Button("编辑") { editTarget = p; editIsNew = false }
                .appGlassButton(prominent: false)
                .font(.subheadline)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .appGlassCard(tint: .blue, prominent: p.id == selectedId)
        .onTapGesture {
            selectedId = p.id
            ProfileStore.setActiveId(p.id)
        }
    }

    private var notesCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("DNS 与选线").font(.headline)
            Text("DNS 由系统的 VPN 配置统一接管，不再有「回落系统解析」路径。"
                 + "若网关 DNS 不服务，在编辑页把游戏域名填进「仅这些域名走隧道 DNS」，"
                 + "其余域名仍走系统 DNS，避免全机断网。")
                .font(.footnote).foregroundColor(.secondary)
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .appGlassCard(tint: .purple)
    }

    // MARK: - 数据

    private func reload() {
        profiles = ProfileStore.all()
        selectedId = ProfileStore.activeId() ?? profiles.first?.id
        if let id = selectedId { ProfileStore.setActiveId(id) }
    }
}

struct LogView: View {
    @Environment(\.presentationMode) private var presentation
    @State private var text = ""
    private let ticker = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        NavigationView {
            ScrollView {
                VStack(alignment: .leading) {
                    Text(text.isEmpty ? "（暂无日志）" : text)
                        .font(.system(size: 11, design: .monospaced))
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
                .appGlassCard(tint: .gray)
                .padding()
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
                    Button("关闭") { presentation.wrappedValue.dismiss() }
                        .appGlassButton(prominent: true)
                }
            }
            .onAppear { text = LogStore.read() }
            .onReceive(ticker) { _ in text = LogStore.read() }
        }
        .navigationViewStyle(.stack)
    }
}
