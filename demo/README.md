# 真机验证 Demo（IPATDemo）

一个最小的 iOS App，用来在真机上核对注入的 tweak 是否真的生效。
App 本身只负责「把状态显示出来」，不参与任何注入逻辑——
dylib 都是 `constructor` 自启动，宿主只要有可见窗口和 rootViewController 即可。

本 Demo 同时是 **VPN 连接测试包**：注入 `IPATool.dylib`（悬浮面板）+ `AnyVpn.dylib`（VPN 隧道插件）。

## 产物

由 GitHub Actions（`Build iOS Tweaks`）在 macOS runner 上编译并注入：

- `demo/build/IPATDemo.ipa`：arm64 / min iOS 14.0，已注入
  `IPATool.dylib` + `AnyVpn.dylib`，**未签名**
- artifact 名：`ipatool-demo-vpn`

## 安装

产物未签名，必须用重签工具装到真机：Sideloadly / 爱思助手 / AltStore / zsign。
免费 Apple ID 签 7 天，付费开发者账号 1 年。重签会连 `Frameworks/` 里的 dylib 一起签，
注入不会被破坏（可以装完用 `python -m ipatool inject 你的.ipa --list` 复核）。

## 界面上能看什么

| 区块 | 含义 |
| --- | --- |
| 【1】已加载的注入 dylib | dyld 里路径含 `.app/Frameworks/` 的镜像，应有 `IPATool.dylib` 与 `AnyVpn.dylib` |
| 【2】注入写入的配置 | `IPAToolFiles` / `IPAToolControl` / `UIBackgroundModes` |
| 【3】VPN 状态 | AnyVpn 是否加载、连接开关、禁用 DTLS、连接列表（名称/网关/账号）、当前选中 |
| 【4】运行状态 | 前后台心跳、进入后台次数与时长 |
| 【5】Documents | 「文件」App 与面板导入的文件都落在这里 |
| 【6】事件日志 | 前后台切换、写文件等记录 |
| 【7】VPN 连接日志 | `Documents/ipatool.log` 尾部 40 行（面板与 AnyVpn 共用这个文件） |

底部三个按钮：写入测试文件 / **复制 VPN 日志** / 清空日志。

## 怎么测 VPN

1. 装好打开 App，屏幕右侧有个**悬浮胶囊**，点一下展开控制面板。
2. 面板里找到「**VPN 隧道**」分组：
   - 没有连接 → 点「**＋ 添加连接**」，填网关地址 / 账号 / 密码 / 认证组（认证组留空 = 自动选第一个）；
   - 已有连接 → 主列表点一下切换到要连的那条。
3. 打开分组顶部的「VPN 隧道」**主开关**即开始连接（关闭 = 断开）。
4. 回到 Demo 界面看【3】VPN 状态与【7】连接日志；
   要排障就点底部「**复制 VPN 日志**」，把剪贴板内容发回来即可。

### 配置从哪来

优先级：**面板里保存的连接（NSUserDefaults）> Info.plist 的 `IPAToolAnyVpn` 初始值**。

`demo/Info.plist` 里预置了这些初始值（AnyVpn 支持的全部字段）：

| 键 | 含义 |
| --- | --- |
| `Server` | 网关地址（必填，初始留空 → 在面板里加连接） |
| `User` / `Password` / `AuthGroup` | 账号 / 密码 / 认证组（空 = 自动选第一个） |
| `DisableDTLS` | `true` = 只走 CSTP(TCP)。DTLS/UDP 443 在多数网络握不上手，真机建议直接 true |
| `UnderlyingIface` | `en0` = openconnect 的 socket 绑到底层网卡，防路由环路 |
| `AutoConnect` | `true` = 启动即连（默认 false，避免一启动就弹网关登录） |
| `TotpSecret` | Base32 TOTP 密钥（可选；账号级密钥优先） |
| `TunnelDNS` | 覆盖网关下发的隧道 DNS，`"ip1,ip2"`（网关 DNS 不服务时用） |

### 已知限制（非越狱机）

- 非越狱设备上 `utun` 能创建、VPN 协议能握手，但**配不了 utun 地址与系统路由**（要 root），
  流量过不去。插件会明确打日志提示，不会假装已连上。
- 越狱设备注入后有 root 权限配路由，这条路才真正跑得通。
- 无论哪种情况，**协议握手成功就说明账号/密码/TOTP 正确**，可用来验凭据。

## 本地编译（需要 macOS）

```bash
./demo/build-demo.sh                       # 产出 demo/build/IPATDemo.ipa
python -m ipatool inject demo/build/IPATDemo.ipa \
  --dylib tweak/build/IPATool.dylib \
  --dylib tweak/build/AnyVpn.dylib \
  --in-place --sign none
```

链接时带了 `-Wl,-headerpad_max_install_names`：给 Mach-O 头部预留空间，
否则塞不下 `LC_LOAD_DYLIB`，注入会报「头部空隙不足」。
