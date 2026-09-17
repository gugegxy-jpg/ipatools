# ipatool

一个用于**修改 IPA 包 Bundle ID / 显示名称、注入 dylib 并重新签名**的命令行工具（纯 Python 标准库实现）。

改 Bundle ID 不只是改一个 `CFBundleIdentifier`：内嵌的 Extension / WatchApp / Framework 的 ID、`WKAppBundleIdentifier`、`CFBundleURLName` 等引用都会跟着变，改完还必须**重新签名**才能安装。注入 dylib 同理：需要改 Mach-O、放库、改 Info.plist，再整体重签。这个工具把这些步骤串成一条命令。

## 功能

- **图形界面**：`python -m ipatool gui` 打开窗口操作（tkinter，无第三方依赖）
- 查看 IPA 信息（`info`，支持 `--json`，含内嵌 bundle、后台模式、已注入 dylib）
- 列出可用签名证书（`certs`，支持 `--json`）
- **ID 签名**：用系统已安装的证书身份签名（`--identity`，macOS 钥匙串名称/SHA-1，Windows 证书指纹）
- **证书签名**：直接提供 p12/pfx 文件签名（`--p12`，macOS 会导入到临时钥匙串，用完即删）
- 修改主 App 的 `CFBundleIdentifier`、`CFBundleDisplayName`、`CFBundleName`
- 自动联动修改内嵌 bundle（`.appex` / `.framework` / Watch App）的 ID（按前缀映射）
- 递归替换 plist 中所有引用旧 Bundle ID 的字符串
- 同步修改 `*.lproj/InfoPlist.strings` 中的本地化显示名（可用 `--no-localized` 关闭）
- **注入 dylib**（`inject`）：放进 `Frameworks/` 并给主可执行文件追加 `LC_LOAD_DYLIB`，支持 fat 二进制、幂等
- **切后台继续运行**：`inject --keep-alive` 注入保活 tweak（静音音频 + 后台任务续期，可选后台定位/系统定时唤醒），适合游戏切后台继续热更、下载
- **文件导入导出**：`inject --files` 注入文件桥，在悬浮面板里浏览 App 沙盒，把热更资源（补丁/配置/存档）导出到系统「文件」App，或从「文件」App 导入回沙盒
- **应用内悬浮控制面板**：上面这些功能会顺带注入一个悬浮窗，点开即可在 App 里实时开关 / 操作它们（`--no-panel` 可关掉）
- 重打包时尽量保留 Mach-O 可执行权限
- 可选重签名（`codesign` / `zsign`）

## 环境

- Python >= 3.8，无第三方依赖（Mach-O 解析/改写是纯 Python 实现的）
- 签名工具（二选一，可选）：
  - macOS：系统自带 `codesign`
  - 任意平台：`zsign` <https://github.com/zhlynn/zsign>
- 编译注入用的 dylib **必须 macOS + Xcode 命令行工具**（iOS SDK 只在 macOS 上有）

## 用法

```bash
# 查看信息
python -m ipatool info app.ipa
python -m ipatool info app.ipa --json

# 列出可用签名身份（ID 签名前先查 ID）
python -m ipatool certs
python -m ipatool certs --json

# 修改 Bundle ID 和名称（自动选择签名后端）
python -m ipatool modify app.ipa -i com.company.newapp -n "新名称" -o out.ipa

# ID 签名：用钥匙串里已安装的证书（macOS / codesign）
python -m ipatool modify app.ipa \
  -i com.company.newapp -n "新名称" \
  --identity "Apple Development: xxx (TEAMID)" \
  --provision app.mobileprovision \
  -o out.ipa

# 证书签名：直接给 p12 文件（macOS 导入临时钥匙串；Windows/Linux 交给 zsign）
python -m ipatool modify app.ipa -i com.company.newapp -n "新名称" \
  --p12 cert.p12 --p12-password 123456 \
  --provision app.mobileprovision \
  -o out.ipa

# 证书签名时指定用 p12 里的哪个身份（名称或 SHA-1 子串）
python -m ipatool modify app.ipa -i com.company.newapp \
  --p12 cert.p12 --identity "Apple Distribution" -o out.ipa

# 先看看会改什么，不落盘
python -m ipatool modify app.ipa -i com.company.newapp -n "新名称" --dry-run
```

## 图形界面

```bash
python -m ipatool gui
# 等价写法
python -m ipatool.gui
```

界面分成四个页签，功能与命令行一一对应：

| 页签 | 对应子命令 | 内容 |
| --- | --- | --- |
| 信息 | `info --json` | Bundle ID / 名称 / 版本 / 后台模式 / 内嵌 bundle / 已注入 dylib |
| 改 ID / 名称 | `modify` | Bundle Identifier、显示名称、CFBundleName、本地化开关 |
| 注入功能 | `inject` | 后台保活、文件导入导出、悬浮窗、自定义 dylib、后台模式、ATS |
| 签名 | `modify` / `inject` 公共参数 | 签名后端、`--identity`、p12 与密码、描述文件、entitlements、dry-run |

用法要点：

- 顶部选输入（`.ipa` 或已解包且含 `Payload` 的目录）和输出路径；选完输入会自动解析一次信息。
- 「签名」页的「读取系统证书」会列出可用身份并填进下拉框，和 `certs` 一样。
- 「预览（dry-run）」= 在当前页签的参数上追加 `--dry-run`，先看会改什么；「开始执行」才真正落盘。
- 日志区实时滚动命令输出（等价于把拼出来的命令行贴进终端），证书密码在回显里打码。
- 任务跑在后台线程，界面不会卡死；同一时刻只允许一个任务。
- 界面不重复实现业务逻辑：它只是把控件上的值拼成一份 argv 再交给 `cli.main()`，所以提示、警告、退出码和命令行完全一致。

> 界面依赖 Python 自带的 tkinter（Windows / macOS 官方安装包都自带；Linux 上需装 `python3-tk`）。

### 证书签名 vs ID 签名

| | 用法 | macOS（codesign） | Windows / Linux（zsign） |
| --- | --- | --- | --- |
| ID 签名 | `--identity <ID>` | 钥匙串中的证书名称或 SHA-1 | Windows 指纹（从证书存储导出后签名，需私钥可导出） |
| 证书签名 | `--p12 cert.p12` | 导入到临时钥匙串后签名，用完自动删除 | 直接交给 zsign |

- 两者可同时给：`--p12` 导入后按 `--identity` 匹配其中某个身份（匹配不到会列出证书内所有身份）。
- 都不给时退化为 ad-hoc 签名（`--identity -`），真机无法安装。
- `--p12-password` 缺省时会交互输入，也可放到环境变量 `IPATOOL_P12_PASSWORD`。

### modify 主要参数

| 参数 | 说明 |
| --- | --- |
| `-i, --bundle-id` | 新的 Bundle Identifier |
| `-n, --name` | 新的显示名称（`CFBundleDisplayName`） |
| `--bundle-name` | 新的 `CFBundleName`，默认跟随 `--name` |
| `--no-localized` | 不同步本地化名称 |

## 注入 dylib

```bash
# 只注入自己的 dylib（除 Mach-O 外不改其它东西）
python -m ipatool inject app.ipa --dylib MyTweak.dylib --sign codesign \
  --identity "Apple Development: xxx (TEAMID)" \
  --provision app.mobileprovision -o out.ipa

# 查看包里已经注入了什么
python -m ipatool inject app.ipa --list

# 先预览
python -m ipatool inject app.ipa --dylib MyTweak.dylib --dry-run
```

注入做了三件事：

1. 把 dylib 复制到 `Payload/App.app/Frameworks/<名字>.dylib`
2. 给主可执行文件追加一条 `LC_LOAD_DYLIB` → `@executable_path/Frameworks/<名字>.dylib`
3. 交回给统一的打包 + 重签名流程（`codesign` 会按「由深到浅」的顺序先签 dylib，最后签主 App）

实现要点：

- **不会破坏原文件**：只在 Mach-O 头部空隙（load commands 结束 → 第一个 section 偏移之间）里追加命令，不移动任何内容、不改变任何 offset，所以 fat 二进制（arm64 + arm64e 多切片）也是安全的；空隙不够时直接报错退出，不会写坏文件。
- **幂等**：同一路径已存在时跳过，重复注入不会叠加。
- **必须重签**：改了主可执行文件后原签名必然失效，`--sign none` 出来的包只能越狱设备用，工具会明确警告。


### 切后台继续运行（`--keep-alive`）

给 App 注入保活组件：切到后台后进程不被挂起，网络下载 / 热更继续跑。

```bash
# 默认方式：静音音频保活（最稳）
python -m ipatool inject game.ipa --keep-alive \
  --p12 cert.p12 --p12-password 123456 \
  --provision app.mobileprovision -o out.ipa

# 再加系统定时唤醒，并允许明文 HTTP（热更服务器很常见）
python -m ipatool inject game.ipa --keep-alive --keep-alive-fetch \
  --allow-arbitrary-loads \
  --identity "Apple Development: xxx (TEAMID)" -o out.ipa

# 用近乎无声的底噪代替纯静音
python -m ipatool inject game.ipa --keep-alive --keep-alive-audio-file quiet.m4a -o out.ipa

```

| 参数 | 说明 |
| --- | --- |
| `--keep-alive` | 注入保活 tweak，自动补 `UIBackgroundModes: audio`，并移除 `UIApplicationExitsOnSuspend` |
| `--keep-alive-dylib` | 保活 dylib 路径，默认找 `tweak/build/`（macOS 上找不到会自动编译） |
| `--keep-alive-start-on` | 静音音频何时开始：`launch`（默认，最稳）/ `background`（省电，但可能来不及） |
| `--keep-alive-no-audio` | 不播静音音频，只靠后台任务续期（通常只能多撑几十秒） |
| `--keep-alive-audio-file` | 改用指定音频文件循环播放（放到 App 包内并写入 `AudioFile`） |
| `--keep-alive-no-task-renew` | 不再续期 `beginBackgroundTask` |
| `--keep-alive-renew-lead-time` | 提前多少秒续期后台任务，默认 10 |
| `--keep-alive-location` | 追加 `location` 后台模式并写定位权限说明（耗电、要授权、App Store 会拒） |
| `--keep-alive-location-indicator` | 显示定位蓝色指示条（默认隐藏） |
| `--keep-alive-fetch` / `--keep-alive-processing` | 注册 `BGAppRefreshTask` / `BGProcessingTask`，并补 `BGTaskSchedulerPermittedIdentifiers` |
| `--keep-alive-refresh-interval` | 定时唤醒的最短间隔，默认 900 秒 |
| `--background-mode` | 额外追加到 `UIBackgroundModes` 的值，如 `processing` |
| `--dylib` | 注入任意 dylib，可重复指定 |
| `--allow-arbitrary-loads` | 写 `NSAllowsArbitraryLoads=YES`，热更走明文 HTTP 时需要 |

保活原理（`tweak/KeepAlive.m`），按可靠性排序：

1. **静音音频**（默认开）：以 `.playback` 类别循环播放一段全 0 采样的音频。iOS 只要认为 App 在播放音频，就不会把进程挂起 —— 这是最可靠的一招，也是「后台热更」能成立的关键。
2. **后台任务续期**（默认开）：不断 `beginBackgroundTaskWithName:`，在音频被电话/其它 App 抢断时兜底。
3. **后台定位**（可选）：`CLLocationManager` 开后台定位，需要用户授「始终」权限。
4. **定时唤醒**（可选）：`BGTaskScheduler` 定期把进程唤醒并续注册下一个任务。

配置写在 `Info.plist` 的 `IPAToolKeepAlive` 字典里，上面的参数就是往里写键，也可以事后自己改：

```xml
<key>IPAToolKeepAlive</key>
<dict>
  <key>SilentAudio</key><true/>
  <key>StartAtLaunch</key><true/>
  <key>RenewBackgroundTask</key><true/>
  <key>RenewLeadTime</key><real>10</real>
  <key>Location</key><false/>
  <key>Fetch</key><false/>
  <key>Processing</key><false/>
  <key>RefreshInterval</key><integer>900</integer>
  <key>Log</key><true/>
</dict>
```

> ⚠️ **边界要说清楚**
> - 注入只能保证「进程不被挂起」，**不能改变 App 自己的暂停逻辑**。很多游戏/引擎会在 `applicationDidEnterBackground` 里主动暂停热更与下载，这种情况注入改不了，需要游戏侧配合（如 Unity 的 `Application.runInBackground`）。
> - 保活是尽力而为：低电量模式、系统内存回收、用户上滑杀进程都会终止它。
> - `--keep-alive-location` 耗电、需定位权限，且不符合 App Store 审核条款，只建议自用或内部分发。
> - 真机排查看控制台里 `[ipatool-keepalive]` 前缀的日志。

### 应用内悬浮控制面板（`ControlPanel.dylib`）

注入 `--keep-alive` 或 `--files` 时会**顺带注入一个悬浮窗**：App 里出现一个可拖动的小胶囊按钮，点开就是控制面板，能实时开关上面这些功能，不用改包重启。

- 按钮默认显示 `IPAT`（`--panel-title` 可改）；有功能开着是绿色，全关是灰色
- 按钮可拖到任意位置，位置会被记住；面板贴着按钮弹出
- 收起方式：点面板以外的任意位置，或再点一次悬浮按钮（只有面板展开时才会接住触摸，收起后触摸照旧穿透给 App）
- 面板里的改动**立即生效**，同时记到下次启动
- 不要界面就用 `--no-panel`

```bash
python -m ipatool inject game.ipa --keep-alive -o out.ipa                # 默认带悬浮窗
python -m ipatool inject game.ipa --keep-alive --no-panel -o out.ipa      # 只要功能，不要界面
python -m ipatool inject game.ipa --panel --panel-title 调试 -o out.ipa  # 只要悬浮窗
python -m ipatool inject game.ipa --files -o out.ipa                     # 文件导入导出（带悬浮窗）
```

| 参数 | 说明 |
| --- | --- |
| `--panel` | 强制注入悬浮窗（不配 `--keep-alive/--files` 也能单独用，会显示“没有可控制的功能”） |
| `--no-panel` | 不注入悬浮窗 |
| `--panel-dylib` | 悬浮窗 dylib 路径，默认找 `tweak/build/`（macOS 上找不到会自动编译） |
| `--panel-title` | 悬浮按钮上的文字，默认 `IPAT` |

面板里能改什么，以及改动是否立刻生效：

| 面板项 | 对应配置 | 立即生效 |
| --- | --- | --- |
| 后台保活（总开关） | `IPAToolKeepAlive.Enabled` | 是 |
| 文件导入导出（常开） | `IPAToolFiles.Enabled` | 否（注入即用，面板没有开关；要关只能改 Info.plist） |
| ├ 浏览并导出文件（动作行） | — | 打开沙盒文件浏览器 |
| ├ 导入文件（动作行） | `IPAToolFiles.ImportDir`（默认落地目录） | 挑好落地目录后，在「文件」App 里选文件（可多选） |
| └ 导入文件夹（动作行） | 同上 | 挑好落地目录后，在「文件」App 里选文件夹，连内容一起导入 |

面板刻意只放常用项。下面这些**没有面板开关**，需要就用命令行参数（会写进 Info.plist）：

| 隐藏项 | 参数 / 配置键 | 为什么不在面板里 |
| --- | --- | --- |
| 静音音频 / 任务续期 | `--keep-alive-no-audio` / `SilentAudio`、`--keep-alive-no-task-renew` / `RenewBackgroundTask` | 默认全开，面板只留一个总开关 |
| 后台定位 | `--keep-alive-location` / `Location` | 要用户授「始终」权限、耗电，且不符合 App Store 审核 |
| 定时唤醒 | `--keep-alive-fetch` / `Fetch` | 开启要重启 App（launch handler 只能在启动阶段注册），面板上点了也没用 |
| 导入默认落地目录 | `--files-import-dir` / `ImportDir` | 导入时现挑目录更直观，面板不再预设 |

面板写入的值存在 `NSUserDefaults`（键名前缀 `IPAToolPanel`），**优先级高于 Info.plist 里的初始值**：命令行参数只决定"用户还没在面板里改过时"的默认状态。想回到命令行给的默认值，就删掉 App 的偏好设置或卸载重装。

实现约定在 `tweak/IPATControlShared.h`：面板和功能 dylib 之间**只用「通知 + NSUserDefaults」通信**，不引用彼此的类、不链接彼此的符号。因此三者可以任意组合注入、加载顺序随意，单独删掉面板也不影响功能；以后加新功能只要向面板"注册"自己的开关，`ControlPanel.m` 不用改。

> ⚠️ 悬浮窗是一个独立的高层级 `UIWindow`（`windowLevel = UIWindowLevelAlert + 100`），并重写 `canBecomeKeyWindow` 返回 `NO`：不抢 App 的 keyWindow，空白区域的触摸会穿透给 App。但 App 若自己遍历窗口（录屏、镜像、越狱检测）仍可能看到这个多余窗口。
> 面板只能在 App 前台点开——App 退到后台之后是点不到它的。

### 文件导入导出（`--files`）

游戏热更资源（补丁、配置、存档）一般躺在 App 沙盒里，PC 上不好直接取。注入 `FileBridge.dylib` 后，可以在 App 内的悬浮面板里**浏览沙盒、导出到系统「文件」App，或从「文件」App 导回来**，不用连电脑。

```bash
python -m ipatool inject game.ipa --files -o out.ipa                      # 注入文件导入导出（默认带悬浮窗）
python -m ipatool inject game.ipa --files --files-root Documents -o out.ipa
python -m ipatool inject game.ipa --files --files-import-dir Library/Caches -o out.ipa
python -m ipatool inject game.ipa --files --no-files-sharing -o out.ipa   # 不让 Documents 出现在「文件」App 里
```

怎么用（都在悬浮面板的「文件导入导出」一节里）：

1. **浏览并导出文件**
   - 点文件夹进入；点文件夹右侧的圆圈 = 勾选整个文件夹，点文件 = 勾选该文件，两者可混选；
   - 右上角「导出」导出勾选的内容；顶部还有「全选本目录文件」「导出整个文件夹」两个快捷入口；
   - 导出的内容会**自动打包成一个 zip**（store 不压缩，速度快；超 4G 自动启用 ZIP64），
     打包在后台进行、面板显示进度；单选时 zip 跟原文件/文件夹同名，多选用时间戳命名；
   - 接着系统的「文件」App 选择器会让你挑 zip 的保存位置（我的 iPhone / iCloud 云盘均可）；
   - 到 Windows / Mac 上解开即可；导回来的 zip 走「导入文件」会自动解压（见下）。
2. **导入文件 / 导入文件夹**（两个入口的前半段一样）
   - 先打开沙盒目录选择器，停在默认落地目录（`--files-import-dir`，默认 `Documents`），
     进到想放的目录后点右上角「导入到这里」；
   - 再在系统「文件」App 里选：**导入文件**选文件（可多选），**导入文件夹**选文件夹（连里面的内容一起带进来）；
   - 之所以分两个入口：系统的文档选择器不允许文件和文件夹在同一批里混选，
     混着给类型时文件夹会点不动。
3. **导入 zip 压缩包**（推荐的大体积姿势）
   - 热更资源打成 `.zip` 后走「导入文件」，导入时**自动解压**到落地目录；
   - 支持 store / deflate、ZIP64（4G+ 的包）、Windows 压缩的 GBK 中文文件名；
   - 解压前会做沙盒空间预检，不够会直接报错；解压过程在面板状态行显示进度；
   - 先解到临时目录、全部成功后才挪进落地目录，中途失败不留半成品；
   - 不支持加密 zip；怀疑选择器卡转圈时，压缩包这条路基本都能走通。

| 参数 | 说明 |
| --- | --- |
| `--files` | 注入文件导入导出 tweak（默认一起注入悬浮窗，否则 App 里没有入口） |
| `--no-files` | 不注入文件导入导出 tweak |
| `--files-dylib` | dylib 路径，默认找 `tweak/build/`（macOS 上找不到会自动编译） |
| `--files-root` | 浏览界面的根目录，相对沙盒，默认沙盒根（沙盒根下就是 `Documents` / `Library` / `tmp`） |
| `--files-import-dir` | 从「文件」App 导入的落地目录，相对沙盒，默认 `Documents` |
| `--no-files-sharing` | 不写 `UIFileSharingEnabled` / `LSSupportsOpeningDocumentsInPlace`（默认写，让 App 的 `Documents` 出现在系统「文件」App 的「我的 iPhone」里） |

写入的 Info.plist：

```xml
<key>IPAToolFiles</key>
<dict>
  <key>Enabled</key><true/>
  <key>Root</key><string></string>              <!-- 留空 = 沙盒根 -->
  <key>ImportDir</key><string>Documents</string>
</dict>
<key>UIFileSharingEnabled</key><true/>
<key>LSSupportsOpeningDocumentsInPlace</key><true/>
```

> - 导出走系统文档选择器，会**先让悬浮窗躲起来**（悬浮窗层级比系统弹窗还高，不躲会盖在选择器上），关掉后自动回来。这是通过共享头里的 `IPATControlVisibility` 通知实现的。
> - 导出走系统文档选择器（`asCopy`），沙盒里的原文件不受影响；导入一律 `asCopy:NO`：
>   回调立即返回安全作用域 URL，拷贝由 tweak 自己做（`asCopy:YES` 选文件夹会卡转圈、
>   选大文件会先被系统白拷一份到临时目录）。
> - 导入同名文件**不覆盖**，自动加 `-2`、`-3` 后缀；浏览界面默认跳过 `.` 开头的隐藏项。
> - `--files-import-dir` 指定的是导入的**默认落地目录**：面板「导入文件」会停在这个目录，动作行下方也会显示它，临时想换别的文件夹在界面里点进去即可。
> - 装完在「文件」App 里看不到该 App，卸载重装一次（可见性在安装时被系统读取）。
> - 真机排查看控制台里 `[ipatool-files]` 前缀的日志。

### 编译内置 tweak

```bash
./tweak/build.sh                                       # 产物：tweak/build/{KeepAlive,ControlPanel,FileBridge}.dylib
IPATOOL_TARGETS=KeepAlive ./tweak/build.sh             # 只编译保活
IPATOOL_TARGETS=ControlPanel ./tweak/build.sh          # 只编译悬浮窗
IPATOOL_TARGETS=FileBridge ./tweak/build.sh            # 只编译文件导入导出
IPATOOL_ARCHS="arm64 arm64e" ./tweak/build.sh
IPATOOL_MIN_IOS=15.0 ./tweak/build.sh
```

> ⚠️ 这些 tweak 的源码是按 Apple 公开 API 写的，但我无法在这里编译/真机验证（需要 macOS + Xcode + 真实设备）。
>
> 另外请只对你自己有权修改的 App 使用注入功能。

## 签名说明

- **auto**：macOS 上用 `codesign`，否则若 PATH 中有 `zsign` 就用 zsign，都不满足则只重打包并给出警告。
- `codesign` 后端会：按「由深到浅」的顺序签名 dylib、Framework、Extension，最后签主 App；并自动从原签名里导出 entitlements 重新注入，避免丢权限。
- 没有 `codesign` / `zsign` 时输出的 IPA **未签名**，真机无法安装，仅供越狱设备或后续用其它工具签名。
- 若旧描述文件不是通配符 App ID，改 Bundle ID 后必须配合 `--provision` 提供匹配的描述文件。

## 目录结构

```
ipatool/
  cli.py       命令行入口（info / certs / modify / inject / gui）
  gui.py       图形界面（tkinter，把控件拼成命令行再交给 cli）
  ipa.py       解包 / 打包，权限位处理
  plistutil.py plist 与 InfoPlist.strings 读写
  bundle.py    bundle 发现与 ID / 名称改写
  macho.py     Mach-O 解析与 LC_LOAD_DYLIB 注入
  inject.py    dylib 落位、Info.plist 注入配置（后台保活 / 文件导入导出 / 后台模式 / ATS）
  keystore.py  签名身份管理：身份列举 / p12 导入钥匙串 / Windows 证书导出
  signer.py    codesign / zsign 重签名
tweak/
  KeepAlive.m           后台保活注入 dylib 源码
  ControlPanel.m        应用内悬浮控制面板（悬浮按钮 + 开关小窗口）
  FileBridge.m          沙盒文件浏览 / 导出到「文件」App / 从「文件」App 导入
  IPATControlShared.h   面板与各功能 dylib 之间的约定（通知名 / 配置键）
  build.sh              编译脚本（需要 macOS + Xcode，可编译单个目标）
```
