import SwiftUI

struct ProfileEditView: View {
    @Environment(\.presentationMode) private var presentation

    @State private var profile: VpnProfile
    @State private var password: String
    @State private var totpSecret: String
    @State private var certHash: String
    @State private var errorMsg: String?
    @State private var showDeleteConfirm = false

    let isNew: Bool
    let onSave: () -> Void

    init(profile: VpnProfile, isNew: Bool, onSave: @escaping () -> Void) {
        _profile = State(initialValue: profile)
        _password = State(initialValue: profile.secret("password"))
        _totpSecret = State(initialValue: profile.secret("totpSecret"))
        _certHash = State(initialValue: profile.secret("acceptedCertHash"))
        self.isNew = isNew
        self.onSave = onSave
    }

    var body: some View {
        NavigationView {
            ScrollView {
                VStack(spacing: 18) {
                    glassGroup("连接参数",
                               footer: "网关需要三段式认证：账号 → 动态验证码 → 固定密码；认证组一般留空。") {
                        TextField("名称（ceshi / qa …）", text: $profile.name)
                        TextField("网关 URL", text: $profile.server)
                            .keyboardType(.URL)
                        TextField("账号", text: $profile.username)
                        SecureField("固定密码", text: $password)
                        TextField("认证组（可留空）", text: $profile.authgroup)
                    }

                    glassGroup("动态验证码",
                               footer: "TOTP Base32 密钥，网关第二段表单为 Verification code 时必填。同时按账号共享给同账号的其它线路。") {
                        TextField("Base32 密钥", text: $totpSecret)
                    }

                    glassGroup("DNS（决定选线是否生效）",
                               footer: "隧道 DNS 不可用时，把游戏域名填进第二项，其余域名继续走系统 DNS，避免全机断网。留空 = 全部走隧道 DNS。") {
                        TextField("隧道 DNS 覆盖，逗号分隔（留空用网关下发）", text: $profile.tunnelDNS)
                        TextField("仅这些域名走隧道 DNS，逗号分隔", text: $profile.dnsMatchDomains)
                    }

                    glassGroup("证书指纹（可选）",
                               footer: "留空 = 首次连接自动记录并固定（TOFU）；填写则严格比对，指纹变化直接拒绝连接。") {
                        TextField("期望 SHA 指纹", text: $certHash)
                    }

                    glassGroup("传输", footer: "DTLS/UDP 443 在多数网络握不上手，默认只用 CSTP(TCP)。") {
                        Toggle("禁用 DTLS，只用 CSTP/TCP", isOn: $profile.disableDtls)
                    }

                    if let e = errorMsg {
                        Text(e).font(.footnote).foregroundColor(.red)
                    }

                    HStack(spacing: 12) {
                        Button("保存") { save() }.appGlassButton(prominent: true)
                        Button("取消") { presentation.wrappedValue.dismiss() }
                            .appGlassButton(prominent: false)
                    }

                    if !isNew {
                        Button("删除此线路") { showDeleteConfirm = true }
                            .appGlassButton(prominent: false)
                            .foregroundColor(.red)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 20)
            }
            .navigationTitle(isNew ? "添加线路" : "编辑线路")
            .appGlassScene()
            .alert(isPresented: $showDeleteConfirm) {
                Alert(title: Text("删除这条线路？"),
                      message: Text("同时删除它的密码、TOTP 密钥与证书指纹记录。"),
                      primaryButton: .destructive(Text("删除")) { deleteProfile() },
                      secondaryButton: .cancel())
            }
        }
        .navigationViewStyle(.stack)
    }

    private func glassGroup<Content: View>(
        _ title: String,
        footer: String? = nil,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title).font(.headline)
            VStack(alignment: .leading, spacing: 12) { content() }
                .textFieldStyle(.plain)
            if let f = footer {
                Text(f).font(.caption).foregroundColor(.secondary)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .appGlassCard()
    }

    private func save() {
        let server = profile.server.trimmingCharacters(in: .whitespacesAndNewlines)
        let user = profile.username.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !server.isEmpty, !user.isEmpty else {
            errorMsg = "网关 URL 和账号不能为空"
            return
        }
        if profile.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            profile.name = server
        }
        var list = ProfileStore.all()
        if let i = list.firstIndex(where: { $0.id == profile.id }) { list[i] = profile }
        else { list.append(profile) }
        ProfileStore.save(list)

        profile.setSecret(password, field: "password")
        profile.setSecret(totpSecret, field: "totpSecret")
        // 按账号共享一份（对齐安卓端 TotpVault 的按账号索引）
        KeychainStore.set(totpSecret, for: "totp.\(user.lowercased())")
        if certHash.isEmpty {
            KeychainStore.remove("\(profile.id).acceptedCertHash")
        } else {
            profile.setSecret(certHash, field: "acceptedCertHash")
        }
        if isNew { ProfileStore.setActiveId(profile.id) }

        onSave()
        presentation.wrappedValue.dismiss()
    }

    private func deleteProfile() {
        var list = ProfileStore.all()
        list.removeAll { $0.id == profile.id }
        ProfileStore.save(list)
        KeychainStore.remove("\(profile.id).password")
        KeychainStore.remove("\(profile.id).totpSecret")
        KeychainStore.remove("\(profile.id).acceptedCertHash")
        onSave()
        presentation.wrappedValue.dismiss()
    }
}
