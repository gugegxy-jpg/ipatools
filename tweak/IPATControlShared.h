//
//  IPATControlShared.h
//  悬浮控制面板（ControlPanel.dylib）与各功能 dylib（PiPBackground / KeepAlive）之间的约定。
//
//  刻意只用「通知 + NSUserDefaults」通信：
//    - 不引用彼此的类、不链接彼此的符号，谁先加载都不影响
//    - 允许只注入其中一个功能 dylib，面板按注册结果决定显示哪些开关
//
//  加载顺序不用关心：
//    - 功能 dylib 加载后主动 post IPATControlRegister
//    - 面板加载后 post IPATControlDiscover，各功能收到后重新注册一次
//
//  配置读取顺序（功能侧）：面板写入的 NSUserDefaults 值 -> Info.plist 里的初始值。
//  也就是说命令行给的默认值只在用户没在面板里改过时生效。
//

#ifndef IPATOOL_CONTROL_SHARED_H
#define IPATOOL_CONTROL_SHARED_H

#pragma mark - 通知名

/// 面板 -> 功能：开关变了，请重新读取配置并立即应用。userInfo 见 IPATChg*
#define IPATControlDidChangeNotification @"IPATControlDidChange"
/// 功能 -> 面板：我在这儿，userInfo 见 IPATReg*
#define IPATControlRegisterNotification @"IPATControlRegister"
/// 面板 -> 功能：请重新注册一次（面板可能比功能 dylib 晚加载）
#define IPATControlDiscoverNotification @"IPATControlDiscover"
/// 功能 -> 面板：我的运行状态，userInfo: {IPATRegId, IPATStaDetail}
#define IPATControlStatusNotification @"IPATControlStatus"
/// 面板 -> 功能：用户点了某个「动作行」。userInfo 见 IPATAct*
#define IPATControlActionNotification @"IPATControlAction"
/// 功能 -> 面板：请临时隐藏/显示悬浮窗（要弹系统界面时别挡着）。userInfo 见 IPATVis*
#define IPATControlVisibilityNotification @"IPATControlVisibility"

#pragma mark - 功能标识

#define IPATFeaturePiP @"pip"
#define IPATFeatureKeepAlive @"keepalive"
#define IPATFeatureFiles @"files"

#pragma mark - 注册（IPATControlRegisterNotification 的 userInfo）

#define IPATRegId @"id"             // 功能标识，IPATFeature*，必填
#define IPATRegTitle @"title"       // 面板里的小标题，必填
#define IPATRegDetail @"detail"     // 标题下的一行说明，可选
#define IPATRegMasterKey @"masterKey"  // 主开关写进 NSUserDefaults 的键，必填（masterHidden = YES 时可省）
#define IPATRegEnabled @"enabled"   // 主开关当前值 @(BOOL)，必填
#define IPATRegMasterHidden @"masterHidden"  // @(YES)：面板不画主开关，功能按 IPATRegEnabled 常开
#define IPATRegRows @"rows"         // 子选项 @[行]，可选，见 IPATRow*

// 子选项行的键（IPATRegRows 数组元素）
#define IPATRowKey @"key"           // 配置键，必填
#define IPATRowTitle @"title"       // 显示名，必填
#define IPATRowKind @"kind"         // IPATRowKind*，默认 switch
#define IPATRowValue @"value"       // 当前值：switch 用 @(BOOL)，segment 用 NSString
#define IPATRowOptions @"options"   // segment 的显示项 @[NSString]
#define IPATRowValues @"values"     // segment 的取值 @[NSString]，与 options 一一对应
#define IPATRowNote @"note"         // 行下方的小字说明，可选

// 行类型
#define IPATRowKindSwitch @"switch"    // 右侧开关，值写 NSUserDefaults
#define IPATRowKindSegment @"segment"  // 右侧分段控件，值写 NSUserDefaults
// 动作行：整行可点，点了面板会收起并发 IPATControlActionNotification
// （动作行不写 NSUserDefaults，也不需要 IPATRowValue）
#define IPATRowKindAction @"action"

#pragma mark - 变更通知（IPATControlDidChangeNotification 的 userInfo）

#define IPATChgId @"id"             // 功能标识
#define IPATChgEnabled @"enabled"   // 主开关新值 @(BOOL)
#define IPATChgValues @"values"     // 子选项新值 {配置键: 值}

#pragma mark - 状态通知（IPATControlStatusNotification 的 userInfo）

#define IPATStaDetail @"detail"     // 一行状态文字

#pragma mark - 动作通知（IPATControlActionNotification 的 userInfo）

#define IPATActKey @"actionKey"     // 被点击动作行的配置键（IPATRowKey）

#pragma mark - 可见性通知（IPATControlVisibilityNotification 的 userInfo）

#define IPATVisVisible @"visible"   // @(BOOL)，NO = 临时把悬浮窗藏起来

#pragma mark - 面板写入的 NSUserDefaults 键
// 功能侧先用这些键查 NSUserDefaults，查不到再回落到 Info.plist 的初始值。
// 键的取值含义与 Info.plist 里同名配置保持一致（不取反），面板上的文案负责表达。
// 面板只暴露常用项；标注「仅 plist」的没有面板开关，只能用 Info.plist / 命令行参数配置。

#define IPATKeyPiPEnabled @"IPAToolPanelPiPEnabled"
#define IPATKeyPiPMode @"IPAToolPanelPiPMode"
#define IPATKeyPiPStopOnForeground @"IPAToolPanelPiPStopOnForeground"
#define IPATKeyPiPAudio @"IPAToolPanelPiPAudio"  // 仅 plist：画中画的保活音频，默认开，关了可能起不来画中画

#define IPATKeyKAEnabled @"IPAToolPanelKeepAliveEnabled"
#define IPATKeyKASilentAudio @"IPAToolPanelKeepAliveAudio"
#define IPATKeyKARenew @"IPAToolPanelKeepAliveRenew"
#define IPATKeyKAFetch @"IPAToolPanelKeepAliveFetch"        // 仅 plist：开启要重启 App，面板上点了没用
#define IPATKeyKALocation @"IPAToolPanelKeepAliveLocation"  // 仅 plist：要授权、耗电、过不了审

#define IPATKeyFilesEnabled @"IPAToolPanelFilesEnabled"  // 已弃用：文件功能常开，只看 Info.plist 的 Enabled
#define IPATKeyFilesImportDir @"IPAToolPanelFilesImportDir"  // 仅 plist：导入的默认落地目录（相对沙盒）

#define IPATKeyButtonFrame @"IPAToolPanelButtonFrame"  // 悬浮按钮位置，NSStringFromCGRect

#endif /* IPATOOL_CONTROL_SHARED_H */
