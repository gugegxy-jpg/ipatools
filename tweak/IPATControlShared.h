//
//  IPATControlShared.h
//  悬浮控制面板（ControlPanel.dylib）与各功能 dylib（KeepAlive / FileBridge）之间的约定。
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

#include <math.h>

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

#define IPATKeyKAEnabled @"IPAToolPanelKeepAliveEnabled"
#define IPATKeyKAFetch @"IPAToolPanelKeepAliveFetch"        // 仅 plist：开启要重启 App，面板上点了没用
#define IPATKeyKALocation @"IPAToolPanelKeepAliveLocation"  // 仅 plist：要授权、耗电、过不了审

#define IPATKeyFilesEnabled @"IPAToolPanelFilesEnabled"  // 已弃用：文件功能常开，只看 Info.plist 的 Enabled
#define IPATKeyFilesImportDir @"IPAToolPanelFilesImportDir"  // 仅 plist：导入的默认落地目录（相对沙盒）

#define IPATKeyButtonFrame @"IPAToolPanelButtonFrame"  // 悬浮按钮位置，NSStringFromCGRect

#pragma mark - 自建窗口的几何/方向
// 我们自己开的窗口（悬浮窗、弹窗窗口）不归游戏管，默认会按竖屏渲染：
// 横屏游戏里弹出来的界面就「躺」着显示，而且系统文档选择器（远程视图）
// 的方向/坐标对不上时会直接点不动。所以每次用之前都要把窗口对齐到
// 游戏主窗口的实际方向。

/// App 自己的主窗口（exclude 传我们自己的窗口）
static inline UIWindow *IPATAppKeyWindowExcluding(UIWindow *exclude) {
    NSArray<UIWindow *> *windows = nil;
    if (@available(iOS 13.0, *)) {
        NSMutableArray<UIWindow *> *collected = [NSMutableArray array];
        for (UIScene *scene in [UIApplication sharedApplication].connectedScenes) {
            if (![scene isKindOfClass:[UIWindowScene class]]) continue;
            [collected addObjectsFromArray:((UIWindowScene *)scene).windows];
        }
        windows = collected;
    }
    if (windows.count == 0) {
        windows = [UIApplication sharedApplication].windows;
    }
    UIWindow *visible = nil;
    for (UIWindow *candidate in windows) {
        if (candidate == exclude) continue;
        if (candidate.isKeyWindow) return candidate;
        if (!visible && !candidate.hidden && candidate.windowLevel < UIWindowLevelAlert) {
            visible = candidate;
        }
    }
    return visible;
}

/// 当前界面方向（拿不到就当竖屏）
static inline UIInterfaceOrientation IPATInterfaceOrientation(void) {
    UIInterfaceOrientation orientation = UIInterfaceOrientationUnknown;
    if (@available(iOS 16.0, *)) {
        for (UIScene *scene in [UIApplication sharedApplication].connectedScenes) {
            if (![scene isKindOfClass:[UIWindowScene class]]) continue;
            UIWindowScene *windowScene = (UIWindowScene *)scene;
            if (windowScene.activationState != UISceneActivationStateForegroundActive) continue;
            orientation = windowScene.interfaceOrientation;
            break;
        }
    }
    if (orientation == UIInterfaceOrientationUnknown) {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
        orientation = [UIApplication sharedApplication].statusBarOrientation;
#pragma clang diagnostic pop
    }
    return orientation == UIInterfaceOrientationUnknown ? UIInterfaceOrientationPortrait : orientation;
}

/// 把窗口对齐到游戏当前的方向，保证窗口在屏幕上正好铺满一屏。
/// 尺寸只认屏幕自己（iOS 8+ 的 UIScreen.bounds 已经是「当前界面方向」下的尺寸）：
/// App 的 key window 未必全屏（小窗口、带缩放的都有），照抄它会被甩出屏幕；
/// 而 statusBarOrientation 在全屏游戏里基本不更新，拿它判断横竖屏算出来的尺寸
/// 经常跟屏幕反着 —— 窗口盖不满或者盖到屏幕外，悬浮按钮就「飘出去」了。
static inline void IPATAlignWindowToInterface(UIWindow *window, UIWindow *appWindow) {
    if (!window) return;
    window.transform = CGAffineTransformIdentity;

    CGAffineTransform candidate = CGAffineTransformIdentity;
    UIView *appRoot = appWindow ? appWindow.rootViewController.view : nil;
    if (appWindow && !CGAffineTransformIsIdentity(appWindow.transform)) {
        candidate = appWindow.transform;
    } else if (appRoot && !CGAffineTransformIsIdentity(appRoot.transform)) {
        candidate = appRoot.transform;
    }
    CGAffineTransform rotation = CGAffineTransformIdentity;
    if (!CGAffineTransformIsIdentity(candidate)) {
        // 只跟「整 90°/180°」的旋转，而且只取角度、不带缩放
        CGFloat angle = atan2f((float)candidate.b, (float)candidate.a);
        CGFloat quarters = roundf(angle / (float)M_PI_2);
        if (fabs(angle - quarters * (float)M_PI_2) < 0.05f) {
            rotation = CGAffineTransformMakeRotation(quarters * (CGFloat)M_PI_2);
        }
    }

    CGRect screen = [UIScreen mainScreen].bounds;
    if (screen.size.width <= 0 || screen.size.height <= 0) return;

    if (!CGAffineTransformIsIdentity(rotation)) {
        // 游戏是自己转过窗口的（系统不知道）：照抄角度，尺寸用「转回来」的大小，
        // 这样转出去之后正好铺满屏幕
        CGRect unrotated = CGRectApplyAffineTransform(
            CGRectMake(0, 0, screen.size.width, screen.size.height),
            CGAffineTransformInvert(rotation));
        window.bounds = CGRectMake(0, 0, fabs(unrotated.size.width), fabs(unrotated.size.height));
        window.center = CGPointMake(CGRectGetMidX(screen), CGRectGetMidY(screen));
        window.transform = rotation;
    } else {
        window.frame = screen;
    }
    window.rootViewController.view.frame = window.bounds;
}

#endif /* IPATOOL_CONTROL_SHARED_H */
