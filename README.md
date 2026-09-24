# ipatool

一个用于**修改 IPA 包 Bundle ID / 显示名称、注入 dylib 并重新签名**的命令行工具（纯 Python 标准库实现）。

改 Bundle ID 不只是改一个 `CFBundleIdentifier`：内嵌的 Extension / WatchApp / Framework 的 ID、`WKAppBundleIdentifier`、`CFBundleURLName` 等引用都会跟着变，改完还必须**重新签名**才能安装。注入 dylib 同理：需要改 Mach-O、放库、改 Info.plist，再整体重签。这个工具把这些步骤串成一条命令。

## 功能

- **图形界面**：`python -m ipatool gui` 打开窗口操作（tkinter，无第三方依赖）
- 查看 IPA 信息（`info`，支持 `--json`，含内嵌 bundle、后台模式、已注入 dylib）
- 列出可用签名证书（`certs`，支持 `--json`）
- **列出连着的设备**（`devices`，支持 `--json`）：装 IPA 前先看装到哪台
- **安装到设备**（`install`）：把签好名的 IPA 装到连着的 iPhone / iPad 上（走设备上的 `installation_proxy`），只连一台时不用选设备，失败时把原始报错翻成「下一步做什么」
  - 安装过程实时显示**百分比 / 速度 / 剩余时间**：pymobiledevice3 那条命令行**不接进度回调**（只有一个心跳），所以默认改走它的 Python API 自己接回调；拿不到百分比时退化为「已用时间」心跳 + 结束时的平均速度
  - 想强制走命令行（例如 API 版本不匹配）：设 `IPATOOL_INSTALL_CLI=1`
  - 设备上已经装了**同一个 App**（同 bundle id）时会先问一句，提示里显示的是**设备上那个 App 的名字**（不是 bundle id）：`y` 卸载后重装 / `n` 不卸载直接装 / `q` 取消；已取消不算失败（退出码 3）
  - `--reinstall` 不问直接卸载重装（脚本 / 自动化用）；`--no-uninstall-check` 跳过这个检查，保持老行为；非交互环境默认按「不卸载直接装」继续
- **ID 签名**：用系统已安装的证书身份签名（`--identity`，macOS 钥匙串名称/SHA-1，Windows 证书指纹）
- **证书签名**：直接提供 p12/pfx 文件签名（`--p12`，macOS 会导入到临时钥匙串，用完即删）
- 修改主 App 的 `CFBundleIdentifier`、`CFBundleDisplayName`、`CFBundleName`
- 自动联动修改内嵌 bundle（`.appex` / `.framework` / Watch App）的 ID（按前缀映射）
- 递归替换 plist 中所有引用旧 Bundle ID 的字符串
- 同步修改 `*.lproj/InfoPlist.strings` 中的本地化显示名（可用 `--no-localized` 关闭）
- **注入 dylib**（`inject`）：放进 `Frameworks/` 并给主可执行文件追加 `LC_LOAD_DYLIB`，支持 fat 二进制、幂等
- **只重新签名**（`sign`）：不改 ID、不注入，只解包后重新签名再打包（`inject` / `modify` 都会顺带签名，但都要求至少改点东西）
- **文件导入导出**：`inject --files` 注入文件桥，在悬浮面板里浏览 App 沙盒，把热更资源（补丁/配置/存档）导出到系统「文件」App，或从「文件」App 导入回沙盒
- **弱网测试**：`inject --qnet` 注入弱网工具，在游戏内的弹窗里实时调限速 / 延迟 / 抖动 / 丢包，**只对当前 App 生效**，不动系统设置、不影响其它 App
- **运行时插件加载**：`inject --plugins` 注入一次之后，之后想试的 dylib 丢进 App 沙盒就能在悬浮窗里直接加载，**不用再重新打包签名安装**
- **应用内悬浮控制面板**：上面这些功能会顺带注入一个悬浮窗，点开即可在 App 里实时开关 / 操作它们（`--no-panel` 可关掉）
- **性能悬浮窗**：`inject --solox` 注入独立 dylib（`SoloX.dylib`），在游戏内悬浮窗里挂「性能悬浮窗」开关；开启后屏幕顶部漂浮显示 CPU / 内存 / 网络 / FPS / 电量 / 温度，且**点击穿透到游戏**（开关在游戏内悬浮窗里控制，需同时注入悬浮窗或任一内置功能）
- 重打包时尽量保留 Mach-O 可执行权限
- 可选重签名（`codesign` / `zsign`）

## 环境

- Python >= 3.8，无第三方依赖（Mach-O 解析/改写是纯 Python 实现的）
- 签名工具（二选一，可选）：
  - macOS：系统自带 `codesign`
  - 任意平台：`zsign` —— **项目里已经放了一份**（Windows：`zsign/zsign.exe`），直接就能签，不用配任何环境变量
  - 换平台时把对应版本的 zsign 丢进 `zsign/` 即可（文件名保持 `zsign` 或 `zsign.exe`）；装进 PATH 也认。下载：<https://github.com/zhlynn/zsign>
- 编译注入用的 dylib **必须 macOS + Xcode 命令行工具**（iOS SDK 只在 macOS 上有）
- 装到设备（可选，`devices` / `install` 用）：二选一
  - `pymobiledevice3`：`pip install pymobiledevice3`（纯 Python，三平台通用，推荐）
  - `ideviceinstaller`：libimobiledevice 那套（macOS `brew install libimobiledevice ideviceinstaller`）
  - Windows 上两者都需要 Apple 的 usbmuxd 驱动（装 iTunes 或 Apple Mobile Device Support），设备要解锁并在弹窗点「信任」

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

# 只重新打包 + 重新签名：不改 ID、不注入任何东西
# （inject / modify 虽然都会顺带签名，但两者都要求至少改点东西；只想签一下就用这个）
python -m ipatool sign app.ipa \
  --sign codesign --identity "Apple Development: xxx (TEAMID)" \
  --provision app.mobileprovision -o out.ipa

# 先看看会改什么，不落盘
python -m ipatool modify app.ipa -i com.company.newapp -n "新名称" --dry-run

# 列出连着的设备（拿 UDID）
python -m ipatool devices
python -m ipatool devices --json

# 把签好名的产物装到设备上（只连一台时可以不给 --udid）
python -m ipatool install out.ipa
python -m ipatool install out.ipa --udid 00008110-000A1B2C3D4E5F6G

# 设备上已有同名 App 时：不询问，直接卸载后重装
python -m ipatool install out.ipa --reinstall
```

## 图形界面

```bash
python -m ipatool gui
# 等价写法
python -m ipatool.gui
```

界面分成两个页签：

| 页签 | 对应子命令 | 内容 |
| --- | --- | --- |
| 改 ID · 注入 · 签名 | `modify` + `inject` + `sign` + `install` | Bundle Identifier / 显示名称、要注入的 dylib 列表、签名参数（后端 / p12 与密码 / 描述文件）、安装到设备、记住设置 |
| 信息 | `info --json` | Bundle ID / 名称 / 版本 / 后台模式 / 内嵌 bundle / 已注入 dylib |

用法要点：

- 顶部选输入（`.ipa` 或已解包且含 `Payload` 的目录）和输出路径；**选中输入不会自动解析**，要看包内信息就点「读取信息」。
- **「输出」留空不用管**：产物会生成在**输入包旁边**，文件名按做的事区分——注入 `-injected.ipa`、改 ID `-modified.ipa`、只签名 `-signed.ipa`（命令行同理，不再落到"敲命令时所在目录"）。下面那行摘要会实时显示这个默认路径。
- 底部只有「开始执行 / 预览（dry-run）」两个按钮，按当前填写自动决定做哪件事（见下条），不用先挑模式。
- 底部的「开始执行」按当前填写自动选：列表里有 dylib 就注入 → 填了 ID / 名称就改名 → 什么都没填就只重新打包 + 签名（所以「不改 ID、不注入，只签一下」直接点它就行）。
- 签名参数两个操作共用，配一次就行；证书用「添加证书…」导入 p12（系统证书那一堆大多和苹果签名无关，已去掉）。
- 「安装到设备」在签名区下面：**「安装包」留空就用「输出」里的产物，也可以点「选择…」指定任意一个 IPA**（选过之后不再跟随「输出」，点「清除」回到自动）；旁边还有「打开产物文件夹 / 复制路径」，方便把产物交给爱思之类的工具。下面那行摘要随时显示「装到哪台 + 装哪个包」，包不存在会直接标出来。日志和命令行完全一致（等价于 `install` 子命令）。
- 设备列表**不用手点**：打开界面就读一次，之后空闲时每 30 秒静默刷新——插上 / 拔掉手机会自动反映，只连一台还会自动选中；列表没变化时不写日志。「刷新设备」按钮留着需要立刻刷的时候用。
- 点「安装到设备」时，如果设备上已经有**同一个 App**，会弹一个三选一：**是 = 卸载后重装 / 否 = 不卸载直接装 / 取消 = 什么都不做**（弹窗里写的是设备上那个 App 的名字）。
- 证书 / 密码 / ID 签名会被记住，下次打开自动填好；明文存在本机配置文件里，界面上可以取消勾选或一键清除。
- 「预览（dry-run）」= 在当前参数上追加 `--dry-run`，先看会改什么；「开始执行」才真正落盘。
- 日志区实时滚动命令输出（等价于把拼出来的命令行贴进终端），证书密码在回显里打码。
- 任务跑在后台线程，界面不会卡死；同一时刻只允许一个任务。
- 界面不重复实现业务逻辑：它只是把控件上的值拼成一份 argv 再交给 `cli.main()`，所以提示、警告、退出码和命令行完全一致。
- 内置的文件导入导出 / 弱网测试 / 插件加载 / 悬浮窗只在命令行提供：`python -m ipatool inject <包> --files --qnet --plugins`。

> 界面是**深色主题**（近黑蓝底 + 青色主色，卡片式排版）。配色和字体都集中在 `ipatool/gui.py` 顶部的常量里（`BG` / `CARD` / `BORDER` / `ACCENT` / `FONT`…），想换风格改那一块即可整体生效。
>
> 界面依赖 Python 自带的 tkinter（Windows / macOS 官方安装包都自带；Linux 上需装 `python3-tk`）。

### 证书签名 vs ID 签名

| | 用法 | macOS（codesign） | Windows / Linux（zsign） |
| --- | --- | --- | --- |
| ID 签名 | `--identity <ID>` | 钥匙串中的证书名称或 SHA-1 | Windows 指纹（从证书存储导出后签名，需私钥可导出） |
| 证书签名 | `--p12 cert.p12` | 导入到临时钥匙串后签名，用完自动删除 | 直接交给 zsign |

- 两者可同时给：`--p12` 导入后按 `--identity` 匹配其中某个身份（匹配不到会列出证书内所有身份）。
- 都不给时退化为 ad-hoc 签名（`--identity -`），真机无法安装。
- `--p12-password` 缺省时会交互输入，也可放到环境变量 `IPATOOL_P12_PASSWORD`。
- 图形界面只走「p12 证书文件」这一条路（系统证书列表里绝大多数和苹果签名无关，已去掉；命令行 `certs` / `--identity` 还在）。

### 手里没有证书？（交给爱思 / Sideloadly 签）

Apple ID 签名（免费账号 7 天证书）这件事，**交给爱思助手 / Sideloadly 这类现成工具最省事**——它们自带 Apple ID 认证（含 6 位验证码），
不需要额外装命令行工具。本工具负责前半段（改 ID / 注入 dylib / 出 IPA）：

1. 在本工具里填好 ID、dylib、签名参数（`--sign none` 也行），点「开始执行」生成 IPA
2. 点「**打开产物文件夹**」——会直接打开资源管理器并**选中那个 IPA**，拖进爱思 / Sideloadly 即可
3. 在那边用 Apple ID 签名并安装（免费账号同样 7 天有效）

「复制路径」按钮是给只能粘贴路径、不能拖文件的工具用的。

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

### 注入 + 签名是同一条命令

`inject` 一次就把「解包 → 注入 → 写配置 → 打包 → 重签」全做完，签名后端由 `--sign` 挑：

| 想做什么 | 怎么写 |
| --- | --- |
| 注入 + 签名 | `--sign codesign --identity "Apple Development: …"`（macOS）/ `--sign zsign --p12 cert.p12`（跨平台） |
| 只注入，不签名 | `--sign none`（输出未签名 IPA，随后交给别的工具签） |
| 自动挑 | 默认 `--sign auto`：macOS 上有 codesign 就用 codesign，否则有 zsign 就用 zsign |

**别**「用本工具注入出未签名包，再拿另一个工具签一遍」——那样会白白多一次解包 + 一次打包，
大包上就是几分钟到十几分钟的差别。

打包是耗时大头，用 `--zip-level` 控制：

| 值 | 含义 |
| --- | --- |
| `auto`（默认） | 已经压缩过的资源（png / jpg / mp4 / astc / zip / 字体…）直接存储，其余 deflate |
| `0` | 全部存储：最快、体积最大 |
| `1`-`9` | 全部 deflate，数字越小越快 |

每次跑完会打印 `解包耗时 / 阶段耗时（签名 · 打包）/ 总耗时`，先看数字再决定往哪优化。
（`zsign` 后端还要把中间包重新打一次，所以那种情况下中间包一律不压缩。）

### 应用内悬浮控制面板（悬浮窗）

注入 `--files` / `--qnet` 时会**顺带注入一个悬浮窗**：App 里出现一个可拖动的小胶囊按钮，点开就是控制面板，能实时开关上面这些功能，不用改包重启。

- 按钮默认显示 `IPAT`（`--panel-title` 可改）；有功能开着是绿色，全关是灰色
- 按钮可拖到任意位置，位置会被记住；面板贴着按钮弹出
- 收起方式：点面板以外的任意位置，或再点一次悬浮按钮（只有面板展开时才会接住触摸，收起后触摸照旧穿透给 App）
- 面板里的改动**立即生效**，同时记到下次启动
- 不要界面就用 `--no-panel`

```bash
python -m ipatool inject game.ipa --files -o out.ipa                     # 文件导入导出（带悬浮窗）
python -m ipatool inject game.ipa --files --no-panel -o out.ipa          # 只要功能，不要界面
python -m ipatool inject game.ipa --panel --panel-title 调试 -o out.ipa  # 只要悬浮窗
```

| 参数 | 说明 |
| --- | --- |
| `--panel` | 强制注入悬浮窗（不配 `--files` 也能单独用，会显示“没有可控制的功能”） |
| `--no-panel` | 不注入悬浮窗 |
| `--panel-dylib` | 悬浮窗 dylib 路径，默认找 `tweak/build/`（macOS 上找不到会自动编译） |
| `--panel-title` | 悬浮按钮上的文字，默认 `IPAT` |

面板里能改什么，以及改动是否立刻生效：

| 面板项 | 对应配置 | 立即生效 |
| --- | --- | --- |
| 弱网测试（`--qnet`） | `IPAToolQNet.Enabled` | 是（总开关） |
| └ 网络参数设置（动作行） | 带宽 / 延迟 / 抖动 / 丢包 | 打开参数弹窗：可拖动、右上角 ✕ 关闭、点空白处不关；改完立即生效 |
| 插件加载（`--plugins`） | `IPAToolPlugins.Enabled` | 是（关掉后不再自动加载，入口也不可用） |
| └ 浏览并加载插件…（动作行） | —— | 打开插件窗口：列出沙盒里的 dylib，点一下就 dlopen |
| └ 启动时自动加载 | `IPAToolPlugins.AutoLoad` | 是（下次启动自动加载这次加载过的插件） |
| 文件导入导出（常开） | `IPAToolFiles.Enabled` | 否（注入即用，面板没有开关；要关只能改 Info.plist） |
| ├ 浏览并导出文件（动作行） | — | 打开沙盒文件浏览器，导出自动打包 zip |
| └ 导入文件（动作行） | `IPAToolFiles.ImportDir`（默认落地目录） | 挑好落地目录后，在「文件」App 里选文件 / zip（可多选，zip 自动解压） |

面板刻意只放常用项。下面这些**没有面板开关**，需要就用命令行参数（会写进 Info.plist）：

| 隐藏项 | 参数 / 配置键 | 为什么不在面板里 |
| --- | --- | --- |
| 导入默认落地目录 | `--files-import-dir` / `ImportDir` | 导入时现挑目录更直观，面板不再预设 |

面板写入的值存在 `NSUserDefaults`（键名前缀 `IPAToolPanel`），**优先级高于 Info.plist 里的初始值**：命令行参数只决定"用户还没在面板里改过时"的默认状态。想回到命令行给的默认值，就删掉 App 的偏好设置或卸载重装。

实现约定在 `tweak/IPATControlShared.h`：面板和功能 dylib 之间**只用「通知 + NSUserDefaults」通信**，不引用彼此的类、不链接彼此的符号。因此三者可以任意组合注入、加载顺序随意，单独删掉面板也不影响功能；以后加新功能只要向面板"注册"自己的开关，`ControlPanel.m` 不用改。

> ⚠️ 悬浮窗是一个独立的高层级 `UIWindow`（`windowLevel = UIWindowLevelAlert + 100`），并重写 `canBecomeKeyWindow` 返回 `NO`：不抢 App 的 keyWindow，空白区域的触摸会穿透给 App。但 App 若自己遍历窗口（录屏、镜像、越狱检测）仍可能看到这个多余窗口。
> 面板只能在 App 前台点开——App 退到后台之后是点不到它的。

### 文件导入导出（`--files`）

游戏热更资源（补丁、配置、存档）一般躺在 App 沙盒里，PC 上不好直接取。注入文件功能后，可以在 App 内的悬浮面板里**浏览沙盒、导出到系统「文件」App，或从「文件」App 导回来**，不用连电脑。

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
2. **导入文件**（zip 自动解压）
   - 先打开沙盒目录选择器，停在默认落地目录（`--files-import-dir`，默认 `Documents`），
     进到想放的目录后点右上角「导入到这里」；
   - 再在系统「文件」App 里选文件（可多选）；选到 `.zip` 会**自动解压**到落地目录；
   - 之前还有一个「导入文件夹」入口，已移除：文件夹在 iOS 文档选择器里问题太多
     （选文件夹点「打开」会一直转圈），文件夹场景请打成 zip 再导入。
3. **导入 zip 压缩包**（推荐的大体积姿势）
   - 热更资源打成 `.zip` 后走「导入文件」，导入时**自动解压**到落地目录；
   - 支持 store / deflate、ZIP64（4G+ 的包）、Windows 压缩的 GBK 中文文件名；
   - 解压前会做沙盒空间预检，不够会直接报错；解压过程在面板状态行显示进度；
   - 先解到临时目录、全部成功后才挪进落地目录，中途失败不留半成品；
   - 不支持加密 zip；怀疑选择器卡转圈时，压缩包这条路基本都能走通。
4. **大包（几个 G）怎么导才不翻车**
   - **空间要够**：峰值占用 ≈ 压缩包 1 份（系统 `asCopy` 拷进来的副本）+ 解压后的体积 1 份 +
     落地目录里被覆盖的旧内容（旧内容删掉前一直占着）。2.5G 的包覆盖同名热更目录，
     实际要 8～10G 空闲才稳；解压前会预检，不够会直接报「沙盒空间不足」（含具体 GB 数）。
   - **别切后台 / 别锁屏**：导入跑在 App 进程里，进程被挂起或回收就前功尽弃，
     进度框消失、重开游戏资源没变就是这个。
   - **解压中途也会看剩余空间**：剩不到 0.5G 会主动中止并说清原因，不会等到写失败
     （以前的表现是进度停在某个数字后提示消失，分不清是空间不够还是包坏了）。
   - **失败一定弹窗**：不再只写状态行（面板折叠时看不见，看起来就像"没提示了"）。
   - **实在导不动就分批**：拆成几个 500M～1G 的 zip，一次多选几个（会逐个解压落地），
     或者先把旧资源目录删掉再导。
   - 排查看控制台 `[ipatool-files]` 日志（或沙盒 `Documents/ipatool.log`，可用
     「浏览并导出文件」把它导出来）：会记录空间预检的「需要 / 剩余」、解压进度和失败原因。

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
> - 导出走系统文档选择器（`asCopy`），沙盒里的原文件不受影响；导入用 `asCopy:YES`：
>   系统先把选中的文件拷进本 App 的 tmp 再回调（所有文件来源都支持）。
>   试过 `asCopy:NO` 省掉这份拷贝，但从网盘等第三方文件来源选文件时
>   「打开」按钮会毫无反应，只能退回来；tmp 副本在导入完成后会自动删掉。
> - 导入同名文件 / 文件夹**直接覆盖**（旧内容顶掉，不是多出一份 `xxx-2`）；浏览界面默认跳过 `.` 开头的隐藏项。
> - `--files-import-dir` 指定的是导入的**默认落地目录**：面板「导入文件」会停在这个目录，动作行下方也会显示它，临时想换别的文件夹在界面里点进去即可。
> - 装完在「文件」App 里看不到该 App，卸载重装一次（可见性在安装时被系统读取）。
> - 真机排查看控制台里 `[ipatool-files]` 前缀的日志。

### 弱网测试（`--qnet`）

在游戏里直接模拟弱网，**只对当前 App 生效**：dylib 注入在 App 进程里，改的是这个进程自己的
socket 读写。系统设置、Wi-Fi、蜂窝、其它 App 的网络完全不受影响，也不用装描述文件、
VPN 或代理（不像 QNET 官方客户端那样要装东西）。

```bash
python -m ipatool inject game.ipa --qnet -o out.ipa                     # 3G 档默认值，带悬浮窗
python -m ipatool inject game.ipa --qnet --qnet-down 50 --qnet-delay 500 --qnet-loss 5 -o out.ipa
python -m ipatool inject game.ipa --files --qnet -o out.ipa             # 文件 + 弱网一起注入
```

**怎么调**：悬浮按钮 →「弱网测试（QNet）」→ 点**网络参数设置**打开弹窗

- 弹窗**点空白处不会关闭**（空白处的触摸直接穿透给游戏），只有右上角 **✕** 才关
- **拖动标题栏（或卡片空白处）换位置**，位置会被记住，下次打开还在原处
- 弹窗里实时可调：上下行带宽、延迟、抖动、丢包率，改完立即生效，不用重启
- 五个预设一键切换：正常 / 3G / 2G / 极差 / 断网
- 底部实时显示上下行速率，方便对照限速到底有没有生效

| 参数 | 说明 |
| --- | --- |
| `--qnet` | 注入弱网测试 tweak（不给细项时套用 3G 档：下行 300 / 上行 150 KB/s，延迟 150±40 ms，丢包 2%） |
| `--no-qnet` | 不注入弱网测试 tweak |
| `--qnet-dylib` | dylib 路径，默认找 `tweak/build/`（macOS 上找不到会自动编译） |
| `--qnet-down` / `--qnet-up` | 下行 / 上行带宽上限，KB/s，`0` = 不限 |
| `--qnet-delay` | 单向附加延迟，毫秒 |
| `--qnet-jitter` | 延迟抖动，毫秒（在延迟上随机 ±该值） |
| `--qnet-loss` | 丢包率，0-100 |

写入的 Info.plist：

```xml
<key>IPAToolQNet</key>
<dict>
  <key>Enabled</key><true/>
  <key>DownKbps</key><integer>300</integer>   <!-- 0 = 不限 -->
  <key>UpKbps</key><integer>150</integer>
  <key>DelayMs</key><integer>150</integer>
  <key>JitterMs</key><integer>40</integer>
  <key>LossPct</key><integer>2</integer>      <!-- 0-100 -->
</dict>
```

实现方式和要注意的：

- 拦截 `send` / `sendto` / `recv` / `recvfrom` / `read` / `write`，用的是 dyld 自带的
  `__DATA,__interpose`（不需要 fishhook 之类的第三方库）；调用原函数一律走 `syscall()`
  直接进内核，不会绕回自己的实现。
- 限速用令牌桶；`read` / `write` 会先用 `getsockopt` 判断 fd 是不是 socket，
  文件读写直接放行（结果按 fd 缓存），不会拖慢游戏读资源。
- 上行延迟是「异步晚一点再发」，不阻塞游戏线程（免得掉帧）；下行延迟阻塞在
  等数据的网络线程上，这才是弱网该有的体感。
- 丢包：上行直接不发但对游戏说「发了」，让它自己的重传逻辑跑起来；下行丢掉这一段后
  继续等下一个包（最多连丢 3 次，免得把线程卡死、看起来像断线）。
- 只对跑在 libc 之上的 socket 调用生效，而且符号插入不追溯「已经绑定过的调用」：
  启动瞬间建立的连接可能不受限，之后新建的连接一定生效。
- 想确认有没有生效，看弹窗底部的实时速率，或控制台 `[ipatool-qnet]` 日志。

### 运行时插件加载（`--plugins`）

改一次 dylib 就要「重新打包 → 签名 → 装一次」，调试起来很慢。注入这个插件一次之后，
**之后想试的 dylib 只要丢进 App 沙盒，就能在悬浮窗里直接 `dlopen` 起来**，不用再碰 IPA。

```bash
# 1) 只打这一次包：把插件加载器和「文件导入导出」（用来把插件放进沙盒）一起注入
python -m ipatool inject game.ipa --plugins --files -o out.ipa

# 2) 插件必须用签主 App 的同一把证书签名（这步省不了）
ipatool signdylib MyPlugin.dylib --identity "Apple Development: you (TEAMID)"

# 3) 手机上：悬浮窗 →「文件导入导出」把 MyPlugin.dylib 导到 Documents
# 4) 悬浮窗 →「插件加载」→「浏览并加载插件…」→ 点一下那个文件就加载了
```

**先搞清楚这三条限制**（不是这个工具的限制，是 iOS 的）：

1. **插件必须有效签名，且 Team ID 要和主 App 一致** —— iOS 的 library validation。
   用签 App 的那把证书签插件就行；**ad-hoc 签的 App 基本加载不了任何 dylib**
   （ad-hoc 没有 Team ID），所以重签时别用 `--identity -`。
2. **架构要一致**：真机包只能加载 arm64 的 iOS dylib，模拟器编的装不进去。
   加载前会先读 Mach-O 头检查，不匹配会把这话直接写出来。
3. **`dlclose` 在 iOS 上基本不会真正卸载镜像**：改完插件要重启 App 才干净；
   插件的 `__DATA,__interpose` 也只对 dlopen 之后**新绑定**的调用生效。

| 参数 | 说明 |
| --- | --- |
| `--plugins` | 注入插件加载器 |
| `--no-plugins` | 不注入插件加载器 |
| `--plugins-dylib` | dylib 路径，默认找 `tweak/build/` |
| `--plugins-autoload` | 启动时自动加载上次加载过的插件（面板里也能随时开关） |

写入的 Info.plist：

```xml
<key>IPAToolPlugins</key>
<dict>
  <key>Enabled</key><true/>
  <key>AutoLoad</key><true/>
</dict>
```

插件窗口的行为和弱网弹窗一致：右上角 **✕** 关闭、**点空白处不关闭**（空白触摸穿透给游戏）、
**拖标题栏换位置**且位置会被记住。列表里每个 dylib 一行，已加载的显示 ✓ 并且可以重载；
**加载失败会把 `dlopen` 的原文翻译后整段显示出来**（签名不对 / 架构不对 /
依赖的库没一起放进来，各说各的，不用自己去猜）。

顺带一个好处：加载进来的插件如果也按 `tweak/IPATControlShared.h` 的协议 post 一次
`IPATControlRegister`，**悬浮面板会自动多出它自己那一节**，面板不用改一行代码
（加载完会广播一次 Discover，晚加载的插件也能把注册补上）。

### 编译内置 tweak

四个内置功能（悬浮窗 / 文件导入导出 / 弱网测试 / 插件加载）的源码是分开的。
默认编出两个 dylib：**`IPATool.dylib`**（悬浮窗 + 文件导入导出 + 插件加载合编）和 **`QNet.dylib`**（弱网测试单独一个）。
`QNet.dylib` 靠 `ipatool inject --qnet` 注入 `Frameworks/` 或运行时当插件加载，加载后自己 `post IPATControlRegister` 注册到面板，
所以改弱网测试不用重编主 dylib。四者之间只用「通知 + NSUserDefaults」通信（见 `tweak/IPATControlShared.h`），
顶层函数全是 `static`、类名前缀各不相同，所以合编不会撞符号。

```bash
./tweak/build.sh                                       # 产物：tweak/build/IPATool.dylib + QNet.dylib
IPATOOL_TARGETS=FileBridge ./tweak/build.sh            # 只编译文件功能（单独出一个 dylib）
IPATOOL_TARGETS="ControlPanel FileBridge" ./tweak/build.sh  # 一次编译多个目标
IPATOOL_ARCHS="arm64 arm64e" ./tweak/build.sh
IPATOOL_MIN_IOS=15.0 ./tweak/build.sh
```

想让某个功能用自己编译的单独 dylib，注入时显式给路径即可，
那时会退回「一个功能一个 dylib」的老方式（`--files-dylib` / `--panel-dylib`）。

> ⚠️ 这些 tweak 的源码是按 Apple 公开 API 写的，但我无法在这里编译/真机验证（需要 macOS + Xcode + 真实设备）。
>
> 另外请只对你自己有权修改的 App 使用注入功能。

## 签名说明

- **auto**：macOS 上用 `codesign`；其他平台用项目自带的 `zsign`（`zsign/zsign.exe`，没有就看 PATH）。两者都没有时只重打包并给出警告。
- zsign 签名**必须带证书**：给了 zsign 但没给 `--p12` / `--identity` 时，不会报错，而是退回「只打包不签名」并说明原因（日志里会写清楚）。
- `codesign` 后端会：按「由深到浅」的顺序签名 dylib、Framework、Extension，最后签主 App；并自动从原签名里导出 entitlements 重新注入，避免丢权限。
- 没有 `codesign` / `zsign` 时输出的 IPA **未签名**，真机无法安装，仅供越狱设备或后续用其它工具签名。
- 若旧描述文件不是通配符 App ID，改 Bundle ID 后必须配合 `--provision` 提供匹配的描述文件。

## 目录结构

```
ipatool/
  cli.py       命令行入口（info / certs / devices / install / sign / modify / inject / signdylib / gui）
  gui.py       图形界面（tkinter，把控件拼成命令行再交给 cli）
  ipa.py       解包 / 打包，权限位处理
  plistutil.py plist 与 InfoPlist.strings 读写
  bundle.py    bundle 发现与 ID / 名称改写
  macho.py     Mach-O 解析与 LC_LOAD_DYLIB 注入
  inject.py    dylib 落位、Info.plist 注入配置（文件导入导出 / 弱网测试 / 后台模式 / ATS）
  keystore.py  签名身份管理：身份列举 / p12 导入钥匙串 / Windows 证书导出
  signer.py    codesign / zsign 重签名
  device.py    连设备：列设备 / 装 IPA（pymobiledevice3 或 ideviceinstaller）
tweak/
  ControlPanel.m        应用内悬浮控制面板（悬浮按钮 + 开关小窗口）
  FileBridge.m          沙盒文件浏览 / 导出到「文件」App / 从「文件」App 导入
  QNet.m                弱网测试：拦截 socket 读写做限速 / 延迟 / 抖动 / 丢包 + 参数弹窗
  PluginLoader.m        运行时插件加载：扫描沙盒里的 dylib 并 dlopen（不用重打包）+ 插件窗口
  IPATControlShared.h   面板与各功能 dylib 之间的约定（通知名 / 配置键）
  build.sh              编译脚本（需要 macOS + Xcode，默认编出 IPATool.dylib 和单独的 QNet.dylib）
zsign/
  zsign.exe    Windows 版 zsign（签名用，程序会自动找到它；换平台就放对应版本进来）
```
