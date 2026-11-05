# 真机验证 Demo（IPATDemo）

一个最小的 iOS App，用来在真机上核对注入的 tweak 是否真的生效。
App 本身只负责「把状态显示出来」，不参与任何注入逻辑——
dylib 都是 `constructor` 自启动，宿主只要有可见窗口和 rootViewController 即可。

## 产物

由 GitHub Actions（`Build iOS Tweaks`）在 macOS runner 上编译并注入：

- `demo/build/IPATDemo.ipa`：arm64 / min iOS 14.0，已注入 `IPATool.dylib`，**未签名**
- artifact 名：`ipatool-demo-vpn`

## 安装

产物未签名，必须用重签工具装到真机：Sideloadly / 爱思助手 / AltStore / zsign。
免费 Apple ID 签 7 天，付费开发者账号 1 年。重签会连 `Frameworks/` 里的 dylib 一起签，
注入不会被破坏（可以装完用 `python -m ipatool inject 你的.ipa --list` 复核）。

## 界面上能看什么

| 区块 | 含义 |
| --- | --- |
| 【1】已加载的注入 dylib | dyld 里路径含 `.app/Frameworks/` 的镜像，应有 `IPATool.dylib` |
| 【2】注入写入的配置 | `IPAToolFiles` / `IPAToolControl` / `UIBackgroundModes` |
| 【3】运行状态 | 前后台心跳、进入后台次数与时长 |
| 【4】Documents | 「文件」App 与面板导入的文件都落在这里 |
| 【5】事件日志 | 前后台切换、写文件等记录 |
| 【6】面板日志 | `Documents/ipatool.log` 尾部 40 行（各注入功能共用这个文件） |

底部三个按钮：写入测试文件 / **复制日志** / 清空日志。

## 怎么测注入是否生效

1. 装好打开 App，屏幕右侧有个**悬浮胶囊**，点一下展开控制面板。
2. 面板能展开即说明 `IPATool.dylib` 注入成功（点「文件」分组能导入/导出文件即验证完整链路）。
3. 回到 Demo 界面看【1】已加载的 dylib 与【6】面板日志；
   要排障就点底部「**复制日志**」，把剪贴板内容发回来即可。

## 本地编译（需要 macOS）

```bash
./demo/build-demo.sh                       # 产出 demo/build/IPATDemo.ipa
python -m ipatool inject demo/build/IPATDemo.ipa \
  --dylib tweak/build/IPATool.dylib \
  --in-place --sign none
```

链接时带了 `-Wl,-headerpad_max_install_names`：给 Mach-O 头部预留空间，
否则塞不下 `LC_LOAD_DYLIB`，注入会报「头部空隙不足」。
