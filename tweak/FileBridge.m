//
//  FileBridge.m
//  ipatool 注入用 dylib：浏览沙盒里的游戏热更文件，导出到「文件」App / 从「文件」App 导入。
//
//  设计要点：
//    1. 平时不占资源：只有用户在悬浮面板上点「动作行」时才干活，没有常驻循环。
//    2. 浏览界面用自带的 UITableViewController：
//         点目录 = 进入；点文件 = 勾选；文件夹行右侧的圆圈 = 勾选整个文件夹；
//         右上角「导出」= 导出勾选的内容（文件和文件夹可以混着选）。
//         顶部还有「全选本目录文件」和「导出整个文件夹」两个快捷入口。
//       这样「手动选择导出哪个文件夹或文件」用同一个界面就能满足，
//       也避免连续弹 UIAlertController 带来的 present 时序问题。
//    3. 导入走系统的 UIDocumentPickerViewController（「文件」App），只有「导入文件」
//       一个入口（文件夹场景让用户在电脑/文件 App 里打成 zip，导入时自动解压；
//       iOS 文档选择器对文件夹的支持坑太多，asCopy:YES 选文件夹会卡到永不回调），
//       先在沙盒浏览器里挑落地目录。
//    4. 弹系统界面之前先发 IPATControlVisibility 让悬浮窗躲开：
//       悬浮窗的 windowLevel 比 Alert 还高，不躲开会盖在文档选择器上面。
//    5. 导入的默认落地目录取 Info.plist 的 ImportDir（相对沙盒），界面里挑完只用于本次。
//    6. 导入一律覆盖：落地目录里已有的同名文件 / 文件夹直接顶掉（文件夹整棵替换），
//       不再生成 xxx-2 这种副本——热更资源就是要整体换。覆盖走系统的
//       replaceItemAtURL（同卷原子操作），游戏只会看到旧的完整内容或新的完整内容。
//
//  Info.plist（ipatool --files 会自动写入 IPAToolFiles）：
//    Enabled(bool)    默认 YES；NO 表示面板上的动作行点了只提示「功能已关闭」
//    Root(string)     浏览根目录，相对沙盒，默认空 = 沙盒根
//    ImportDir(string) 导入落地目录，相对沙盒，默认 Documents
//    ImportLock(bool)  默认 YES：导入完把落地内容锁成只读，挡住游戏热更继续往里写。
//                      下次启动自动恢复可写；设 NO 则只替换不设权限
//

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>
#include <stdio.h>
#include <stdlib.h>
#include <sys/stat.h>
#include <zlib.h>
#import "IPATControlShared.h"

#define IPATFbLog(fmt, ...) NSLog(@"[ipatool-files] " fmt, ##__VA_ARGS__)

/// 动作行的标识（只是本 dylib 内部的字符串，不写 NSUserDefaults）
static NSString *const IPATFbActionBrowse = @"files.browse";
static NSString *const IPATFbActionImportTo = @"files.importTo";

/// 上次导入锁成只读的路径。记下来是为了下次启动恢复成可写——
/// 进程可能随时被用户杀掉，不记就永远恢复不了，游戏以后也更新不了
static NSString *const IPATFbLockedPathsKey = @"IPATFbLockedPaths";

/// 浏览器的用途：导出时勾选内容，或给导入挑一个落地文件夹
typedef NS_ENUM(NSInteger, IPATFbBrowserMode) {
    IPATFbBrowserModeExport = 0,     // 勾选文件 / 文件夹后导出
    IPATFbBrowserModeImportTarget,   // 选一个文件夹作为导入落地目录，接着导入文件 / zip
};

static NSString *const IPATFbDefaultImportRelative = @"Documents";
static NSString *const IPATFbDefaultStatus = @"可导出 / 导入沙盒文件";

#pragma mark - 配置

static NSDictionary *IPATFbConfig(void) {
    static NSDictionary *cfg;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        id value = [[NSBundle mainBundle] objectForInfoDictionaryKey:@"IPAToolFiles"];
        cfg = [value isKindOfClass:[NSDictionary class]] ? value : @{};
    });
    return cfg;
}

/// 面板里改过的值优先于 Info.plist 的初始值
static id IPATFbStored(NSString *panelKey) {
    if (panelKey.length == 0) return nil;
    return [[NSUserDefaults standardUserDefaults] objectForKey:panelKey];
}

/// 注入即可用：面板上没有开关，所以只看 Info.plist（故意不读 NSUserDefaults，
/// 免得以前在面板上关过一次留下 NO，开关拿掉之后就再也开不回来）
static BOOL IPATFbEnabled(void) {
    id value = IPATFbConfig()[@"Enabled"];
    return [value respondsToSelector:@selector(boolValue)] ? [value boolValue] : YES;
}

/// 相对沙盒路径 -> 绝对路径，并保证不跑到沙盒外面去
static NSString *IPATFbSandboxPath(NSString *relative) {
    NSString *home = NSHomeDirectory();
    NSString *path = relative.length ? [home stringByAppendingPathComponent:relative] : home;
    path = [path stringByStandardizingPath];
    if (![path isEqualToString:home] && ![path hasPrefix:[home stringByAppendingString:@"/"]]) {
        return [home stringByAppendingPathComponent:IPATFbDefaultImportRelative];
    }
    return path;
}

/// child 是否就是 root 或位于 root 之下（判断能不能从起始目录往上回到浏览根）
static BOOL IPATFbIsWithin(NSString *child, NSString *root) {
    if (child.length == 0 || root.length == 0) return NO;
    if ([child isEqualToString:root]) return YES;
    return [child hasPrefix:[root stringByAppendingString:@"/"]];
}

static NSString *IPATFbImportRelative(void) {
    id stored = IPATFbStored(IPATKeyFilesImportDir);
    id value = [stored isKindOfClass:[NSString class]] ? stored : IPATFbConfig()[@"ImportDir"];
    if ([value isKindOfClass:[NSString class]] && [value length] > 0) return value;
    return IPATFbDefaultImportRelative;
}

static NSString *IPATFbImportDirectory(void) {
    return IPATFbSandboxPath(IPATFbImportRelative());
}

static NSString *IPATFbBrowseRoot(void) {
    id value = IPATFbConfig()[@"Root"];
    NSString *relative = [value isKindOfClass:[NSString class]] ? value : @"";
    return IPATFbSandboxPath(relative);
}

#pragma mark - 悬浮窗 / 弹窗

/// 让悬浮窗先躲开（系统文档选择器会盖住它，反过来它也会盖住选择器）
static void IPATFbSetOverlayVisible(BOOL visible) {
    [[NSNotificationCenter defaultCenter] postNotificationName:IPATControlVisibilityNotification
                                                        object:nil
                                                      userInfo:@{IPATVisVisible: @(visible)}];
}

/// 当前最上层、适合 present 的控制器（避开悬浮窗自己的窗口）
static UIViewController *IPATFbTopViewController(void) {
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

    UIWindow *window = nil;
    for (UIWindow *candidate in windows) {
        if (candidate.isKeyWindow) {
            window = candidate;
            break;
        }
    }
    if (!window) {
        // 悬浮窗的 windowLevel 比 Alert 还高，别选中它
        for (UIWindow *candidate in windows) {
            if (!candidate.hidden && candidate.windowLevel < UIWindowLevelAlert) {
                window = candidate;
                break;
            }
        }
    }
    UIViewController *controller = window.rootViewController;
    while (controller.presentedViewController) controller = controller.presentedViewController;
    return controller;
}

#pragma mark - 弹窗专用窗口

/// 之前弹窗都挂在「App 当前最上层的控制器」上，宿主窗口由游戏决定：
/// 游戏自己的窗口、SDK 的透明窗口、我们的悬浮窗（level 比 Alert 还高）
/// 都可能盖在上面，弹窗显示出来了但触摸落不到它身上——看得见点不动。
/// 所以自己开一个窗口当宿主，level 压过所有这些，弹窗一定在最上层。
@interface IPATFbWindow : UIWindow
@end

@implementation IPATFbWindow

/// 必须能当 key window：系统的文档选择器（「文件」App 界面）是远程视图，
/// 跑在另一个进程里，只有挂在 key window 上才收得到触摸——否则界面出来了
/// 却完全点不动。平时不抢焦点，只在弹系统界面时才 makeKeyAndVisible
- (BOOL)canBecomeKeyWindow { return YES; }

@end

/// 根视图：空白区域返回 nil，触摸继续落到下层窗口，
/// 免得这个常驻的透明窗口把游戏自己的触摸全吃掉
@interface IPATFbWindowRootView : UIView
@end

@implementation IPATFbWindowRootView

- (UIView *)hitTest:(CGPoint)point withEvent:(UIEvent *)event {
    // 窗口上已经没有弹窗了就一律穿透：文档选择器这类远程视图退场后，
    // 它的容器视图不一定会被系统收走，剩下的全屏透明视图就是一层看不见的
    // 遮罩，会把游戏的触摸全吃掉（表现：界面关掉了但游戏点不动）
    UIViewController *root = self.window.rootViewController;
    if (!root.presentedViewController) return nil;
    UIView *hit = [super hitTest:point withEvent:event];
    return hit == self ? nil : hit;
}

@end

/// 根控制器：允许转到任意方向。不给全方向的话，横屏游戏里系统会把
/// 我们这个窗口按竖屏渲染——弹出来的界面就是「躺」着的
@interface IPATFbWindowRootController : UIViewController
@end

@implementation IPATFbWindowRootController

- (BOOL)shouldAutorotate { return YES; }

- (UIInterfaceOrientationMask)supportedInterfaceOrientations { return UIInterfaceOrientationMaskAll; }

@end

/// 窗口的根控制器（透明、点击穿透）。窗口上留下收不走的残留视图时整个换掉重建
static UIViewController *IPATFbMakeWindowRoot(CGRect frame) {
    UIViewController *root = [[IPATFbWindowRootController alloc] init];
    IPATFbWindowRootView *view = [[IPATFbWindowRootView alloc] initWithFrame:frame];
    view.backgroundColor = [UIColor clearColor];
    view.opaque = NO;
    view.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    root.view = view;
    return root;
}

static void IPATFbSyncWindowGeometry(void);

static UIWindow *IPATFbAlertWindow(void) {
    static UIWindow *window;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        if (@available(iOS 13.0, *)) {
            // iOS 13 起窗口必须挂在 windowScene 上，否则根本不显示
            UIWindowScene *scene = nil;
            for (UIScene *candidate in [UIApplication sharedApplication].connectedScenes) {
                if (![candidate isKindOfClass:[UIWindowScene class]]) continue;
                scene = (UIWindowScene *)candidate;
                if (candidate.activationState == UISceneActivationStateForegroundActive) break;
            }
            if (scene && [UIWindow instancesRespondToSelector:@selector(initWithWindowScene:)]) {
                IPATFbWindow *w = [[IPATFbWindow alloc] initWithWindowScene:scene];
                w.frame = [UIScreen mainScreen].bounds;
                w.windowLevel = UIWindowLevelAlert + 200;   // 比悬浮窗（+100）还高
                w.backgroundColor = [UIColor clearColor];
                w.opaque = NO;
                w.rootViewController = IPATFbMakeWindowRoot(w.bounds);
                w.hidden = NO;
                window = w;
                // 屏幕方向一变就跟着转，不然横屏游戏里这个窗口一直是竖的
                [[UIDevice currentDevice] beginGeneratingDeviceOrientationNotifications];
                [[NSNotificationCenter defaultCenter]
                    addObserverForName:UIDeviceOrientationDidChangeNotification
                                object:nil
                                 queue:[NSOperationQueue mainQueue]
                            usingBlock:^(NSNotification *note) {
                    IPATFbSyncWindowGeometry();
                }];
            }
        }
        if (!window) IPATFbLog(@"拿不到 windowScene，弹窗退回挂在 App 自己的控制器上");
    });
    return window;
}

/// App 自己的 key window（排除我们的弹窗窗口）
static UIWindow *IPATFbAppKeyWindow(void) {
    UIWindow *alertWindow = IPATFbAlertWindow();
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
    for (UIWindow *candidate in windows) {
        if (candidate.isKeyWindow && candidate != alertWindow) return candidate;
    }
    return nil;
}

/// 弹系统界面前记下焦点在谁身上，收起后还回去（不然游戏的键盘输入会失灵）
static UIWindow *IPATFbPreviousKeyWindow = nil;

static void IPATFbTakeKeyWindow(void) {
    UIWindow *window = IPATFbAlertWindow();
    if (!window) return;
    UIWindow *previous = IPATFbAppKeyWindow();
    if (previous) IPATFbPreviousKeyWindow = previous;
    if (!window.isKeyWindow) [window makeKeyAndVisible];
}

static void IPATFbGiveBackKeyWindow(void) {
    UIWindow *previous = IPATFbPreviousKeyWindow;
    IPATFbPreviousKeyWindow = nil;
    if (previous && !previous.isKeyWindow) {
        [previous makeKeyAndVisible];
        return;
    }
    if (!previous) {
        UIWindow *app = IPATFbAppKeyWindow();
        if (app && !app.isKeyWindow) [app makeKeyAndVisible];
    }
}

/// 把弹窗窗口对齐到游戏当前的方向/尺寸。
/// 这个窗口是我们自己开的，不跟着游戏转屏：横屏游戏里它一直按竖屏渲染，
/// 弹出来的界面是「躺」着的；更麻烦的是系统文档选择器（远程视图）方向对不上
/// 时收不到触摸——界面明明在屏幕上，就是点不动。
static void IPATFbSyncWindowGeometry(void) {
    UIWindow *window = IPATFbAlertWindow();
    if (!window) return;
    // 抢过焦点之后游戏窗口就不是 key 了，所以还要能退回「可见的 App 窗口」
    UIWindow *app = IPATFbAppKeyWindow() ?: IPATAppKeyWindowExcluding(window);
    IPATAlignWindowToInterface(window, app);
}

/// 弹窗退干净之后把焦点还给 App，顺手清掉窗口上的残留。
/// 文档选择器是远程视图，退场后它的容器视图不一定会被系统收走，剩下的
/// 全屏透明视图就是一层看不见的遮罩，会盖在游戏上面让游戏完全点不动。
/// （窗口本身保持显示：文档选择器要在已经挂好的窗口上才稳定，退场后靠
///  IPATFbWindowRootView 的 hitTest 穿透保证不吃触摸）
static void IPATFbCollapseAlertWindowIfIdle(void) {
    UIWindow *window = IPATFbAlertWindow();
    if (!window) return;
    UIViewController *root = window.rootViewController;
    if (!root) return;
    if (root.presentedViewController) return;              // 还有弹窗（或正在退场）
    if (root.view.subviews.count > 0) {
        // 弹窗没了却还有子视图：远程视图/转场容器没收干净，连根一起换掉
        IPATFbLog(@"窗口上有收不走的残留视图，重建根控制器");
        window.rootViewController = IPATFbMakeWindowRoot(window.bounds);
    }
    IPATFbGiveBackKeyWindow();
}

static BOOL IPATFbWatchingAlertWindow = NO;
static NSInteger IPATFbWatchTicks = 0;

static void IPATFbWatchAlertWindowStep(void);

/// 盯着专用窗口，空了就收起来
static void IPATFbWatchAlertWindow(void) {
    if (IPATFbWatchingAlertWindow) return;
    IPATFbWatchingAlertWindow = YES;
    IPATFbWatchTicks = 0;
    // 给 present 动画留时间，不然刚弹出来就被判定成「空窗口」收掉了
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{ IPATFbWatchAlertWindowStep(); });
}

static void IPATFbWatchAlertWindowStep(void) {
    IPATFbCollapseAlertWindowIfIdle();
    UIWindow *window = IPATFbAlertWindow();
    BOOL idle = !window || !window.rootViewController.presentedViewController;
    if (idle || ++IPATFbWatchTicks > 600) {   // 最多盯 5 分钟
        IPATFbWatchingAlertWindow = NO;
        IPATFbWatchTicks = 0;
        return;
    }
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{ IPATFbWatchAlertWindowStep(); });
}

/// 弹窗收起之后把悬浮窗放回来（导入/导出期间它是藏着的）。
/// UIAlertController 的按钮没有统一的「关闭」回调，只能盯着它的窗口
static void IPATFbWatchDismiss(UIViewController *controller) {
    __weak UIViewController *weakController = controller;
    IPATFbWatchAlertWindow();   // 顺带盯着窗口，等它空了收起来
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_LOW, 0), ^{
        for (NSInteger i = 0; i < 600; i++) {   // 最多盯 5 分钟
            [NSThread sleepForTimeInterval:0.5];
            UIViewController *current = weakController;
            if (!current || current.view.window == nil || current.isBeingDismissed) {
                dispatch_async(dispatch_get_main_queue(), ^{
                    IPATFbSetOverlayVisible(YES);
                    // 收尾（还焦点、收窗口）交给 IPATFbWatchAlertWindow 统一处理，
                    // 这里可能还有后续弹窗要接着弹
                    IPATFbWatchAlertWindow();
                });
                return;
            }
        }
    });
}

/// 导入的落地路径。同名不再避让（不生成 xxx-2），直接指向目标位置，
/// 由 IPATFbReplaceIntoPlace 负责覆盖——导入本来就是为了顶掉旧内容。
static NSString *IPATFbImportPath(NSString *directory, NSString *name) {
    return [directory stringByAppendingPathComponent:name];
}

/// 整棵改成只读 / 恢复可写（只动权限位，不动内容）：目录 0555、文件 0444。
///
/// 这是「挡住游戏热更」唯一稳妥的做法。我们和游戏在同一个进程里，
/// 挂起它的下载线程会让它停在任意一条指令上——很可能正拿着 malloc / 运行时 /
/// 文件系统的锁，别的线程再来申请同一把锁就是死锁，整个进程卡死；
/// 挂起整个进程则会把我们自己一起冻住，没法继续替换。所以不去碰线程，
/// 改成让它写不进来：热更线程继续下载也落不到资源目录里，落盘时拿 EACCES，
/// 最多是更新失败 / 重试，不会把我们导进去的内容盖回去。
static void IPATFbSetTreeWritable(NSString *path, BOOL writable) {
    NSFileManager *fm = [NSFileManager defaultManager];
    NSURL *root = [NSURL fileURLWithPath:path];
    NSNumber *rootIsDir = nil;
    [root getResourceValue:&rootIsDir forKey:NSURLIsDirectoryKey error:NULL];

    NSDirectoryEnumerator *it = [fm enumeratorAtURL:root
                         includingPropertiesForKeys:@[NSURLIsDirectoryKey]
                                            options:0
                                       errorHandler:^BOOL(NSURL *url, NSError *e) { return YES; }];
    NSInteger n = 0;
    for (NSURL *url in it) {
        if (++n > 200000) break;
        NSNumber *isDir = nil;
        [url getResourceValue:&isDir forKey:NSURLIsDirectoryKey error:NULL];
        chmod(url.fileSystemRepresentation,
              [isDir boolValue] ? (writable ? 0755 : 0555) : (writable ? 0644 : 0444));
    }
    chmod(path.fileSystemRepresentation,
          [rootIsDir boolValue] ? (writable ? 0755 : 0555) : (writable ? 0644 : 0444));
}

/// 导入后是否把落地内容锁成只读（Info.plist 的 ImportLock，默认 YES）
static BOOL IPATFbLockAfterImport(void) {
    id value = IPATFbConfig()[@"ImportLock"];
    return [value respondsToSelector:@selector(boolValue)] ? [value boolValue] : YES;
}

/// 上次锁成只读、还没恢复成可写的路径
static NSArray<NSString *> *IPATFbLockedPaths(void) {
    id value = [[NSUserDefaults standardUserDefaults] objectForKey:IPATFbLockedPathsKey];
    return [value isKindOfClass:[NSArray class]] ? value : @[];
}

static void IPATFbRememberLockedPaths(NSArray<NSString *> *paths) {
    if (paths.count == 0) return;
    NSMutableArray<NSString *> *all = [IPATFbLockedPaths() mutableCopy];
    for (NSString *path in paths) {
        if (![all containsObject:path]) [all addObject:path];
    }
    NSUserDefaults *ud = [NSUserDefaults standardUserDefaults];
    [ud setObject:all forKey:IPATFbLockedPathsKey];
    [ud synchronize];   // 进程随时会被杀，别等系统的延迟落盘
}

/// 把已经备好的临时项（同卷）放到 final 位置上；final 上已有同名项就覆盖：
/// 文件换掉、文件夹整棵替换，保证导入完的内容和包里完全一致（热更目录就是要整体换）。
///
/// 替换刻意做成两次 rename，不走「递归删除旧目录 + 移动新目录」：
/// 删几个 G 的热更目录要几秒到十几秒，这段空窗里游戏扫目录会看到资源没了
/// （贴图丢失 / 报资源错误 / 闪退）。rename 是同卷原子操作，只有一瞬间；
/// 旧内容先挂到旁边的垃圾桶名，删它放到后台慢慢做，不挡着替换完成。
/// 中途失败会把旧内容换回原位，不让目录凭空消失。
static BOOL IPATFbReplaceIntoPlace(NSString *staging, NSString *final, NSError **error) {
    NSFileManager *fm = [NSFileManager defaultManager];
    if (![fm fileExistsAtPath:final]) {
        return [fm moveItemAtPath:staging toPath:final error:error];
    }

    NSString *trash = [final stringByAppendingFormat:@".ipatool-trash-%@",
                       [NSUUID UUID].UUIDString];
    if (![fm moveItemAtPath:final toPath:trash error:error]) return NO;

    NSError *moveError = nil;
    if (![fm moveItemAtPath:staging toPath:final error:&moveError]) {
        [fm moveItemAtPath:trash toPath:final error:NULL];   // 换回原位，别让目录消失
        if (error) *error = moveError;
        return NO;
    }
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_BACKGROUND, 0), ^{
        // 旧内容可能上次被锁成只读了，只读目录里的文件删不掉，先放开权限再清
        IPATFbSetTreeWritable(trash, YES);
        [[NSFileManager defaultManager] removeItemAtPath:trash error:NULL];
    });
    return YES;
}

/// 导入用的临时工作目录（tmp 下，每次导入重建）。
/// 故意不放落地目录里：热更过程中游戏会扫资源目录，看到一个正在解压的
/// 半成品目录容易被当成异常资源（或把它的条目算进校验）。tmp 和沙盒同一卷，
/// 从这儿 rename 到落地目录依然是原子操作。
static NSString *IPATFbImportWorkRoot(void) {
    return [NSTemporaryDirectory() stringByAppendingPathComponent:@"IPAToolImport"];
}

/// 清掉上一次导入留下的临时残骸：tmp 的工作目录整个重建，落地目录里
/// 旧版本可能留下的 .ipatool-part / .ipatool-zip / .ipatool-trash-xxx 也顺手删掉
static void IPATFbCleanStagingLeftovers(NSString *directory) {
    NSFileManager *fm = [NSFileManager defaultManager];
    NSString *workRoot = IPATFbImportWorkRoot();
    [fm removeItemAtPath:workRoot error:NULL];
    [fm createDirectoryAtPath:workRoot withIntermediateDirectories:YES attributes:nil error:NULL];

    NSArray<NSURL *> *items = [fm contentsOfDirectoryAtURL:[NSURL fileURLWithPath:directory]
                               includingPropertiesForKeys:nil options:0 error:NULL] ?: @[];
    for (NSURL *item in items) {
        NSString *name = item.lastPathComponent;
        if ([name hasSuffix:@".ipatool-part"] || [name hasSuffix:@".ipatool-zip"] ||
            [name containsString:@".ipatool-trash-"]) {
            IPATFbLog(@"清理上次导入残留：%@", name);
            [fm removeItemAtURL:item error:NULL];
        }
    }
}

/// 目录（或文件）里有没有在 since 之后被改动过的东西：用来判断「我们换完之后
/// 游戏还在往里写」——热更没停的情况下它可能会把下载的内容继续写进来
static BOOL IPATFbModifiedAfter(NSString *path, NSDate *since, NSInteger limit) {
    NSFileManager *fm = [NSFileManager defaultManager];
    NSDate *latest = nil;
    NSURL *item = [NSURL fileURLWithPath:path];
    NSDate *m = nil;
    if ([item getResourceValue:&m forKey:NSURLContentModificationDateKey error:NULL] && m) latest = m;

    NSDirectoryEnumerator *it = [fm enumeratorAtURL:item
                         includingPropertiesForKeys:@[NSURLContentModificationDateKey]
                                            options:0
                                       errorHandler:^BOOL(NSURL *url, NSError *e) { return YES; }];
    NSInteger n = 0;
    for (NSURL *u in it) {
        if (++n > limit) break;
        NSDate *d = nil;
        if ([u getResourceValue:&d forKey:NSURLContentModificationDateKey error:NULL] && d) {
            if (!latest || [d compare:latest] == NSOrderedDescending) latest = d;
        }
    }
    return latest && [latest compare:since] == NSOrderedDescending;
}

/// 先拷到同卷临时名（.ipatool-part），成功后再挪到最终位置。
/// 热更期间游戏可能在扫描目标目录，直接往里拷会读到半成品；
/// 同卷 rename 是原子操作，游戏要么看到完整的旧内容、要么看到完整的新内容。
/// 前向声明：实现在下面（C 不允许调用未声明的函数）
static BOOL IPATFbCopyDirectory(NSURL *source, NSString *destination, NSError **error);

static BOOL IPATFbCopyThenRename(NSURL *source, NSString *target, BOOL isDirectory, NSError **error) {
    NSFileManager *fm = [NSFileManager defaultManager];
    NSString *workRoot = IPATFbImportWorkRoot();
    [fm createDirectoryAtPath:workRoot withIntermediateDirectories:YES attributes:nil error:NULL];
    // 半成品放 tmp 的工作目录，不放在落地目录里被游戏扫到
    NSString *staging = [workRoot stringByAppendingPathComponent:
                         [target.lastPathComponent stringByAppendingString:@".ipatool-part"]];
    for (NSInteger i = 2; [fm fileExistsAtPath:staging]; i++) {
        staging = [workRoot stringByAppendingPathComponent:
                   [NSString stringWithFormat:@"%@-%ld.ipatool-part",
                    target.lastPathComponent, (long)i]];
    }

    BOOL ok = NO;
    if (isDirectory) {
        ok = [fm copyItemAtURL:source toURL:[NSURL fileURLWithPath:staging] error:error];
        if (!ok) {
            NSError *fallbackError = nil;
            ok = IPATFbCopyDirectory(source, staging, &fallbackError);
            if (error && !ok && fallbackError) *error = fallbackError;
        }
    } else {
        ok = [fm copyItemAtURL:source toURL:[NSURL fileURLWithPath:staging] error:error];
    }
    if (!ok) {
        [fm removeItemAtPath:staging error:NULL];   // 拷一半失败不留残缺目录
        return NO;
    }

    // 拷贝期间目标位可能被游戏新建了同名项，最终名再确认一遍（同名直接覆盖）
    if (!IPATFbReplaceIntoPlace(staging, target, error)) {
        [fm removeItemAtPath:staging error:NULL];
        return NO;
    }
    return YES;
}

/// 绝对路径 -> 相对沙盒的显示文本，给面板状态用
static NSString *IPATFbDisplayPath(NSString *path) {
    NSString *home = NSHomeDirectory();
    NSString *relative = [path hasPrefix:home] ? [path substringFromIndex:home.length] : path;
    relative = [relative stringByTrimmingCharactersInSet:
        [NSCharacterSet characterSetWithCharactersInString:@"/"]];
    return relative.length ? relative : @"沙盒";
}

#pragma mark - 文件浏览器

@interface IPATFbBrowserController : UITableViewController

@property (nonatomic, copy) NSString *directory;
@property (nonatomic, copy) NSString *rootDirectory;
@property (nonatomic, assign) IPATFbBrowserMode mode;
@property (nonatomic, strong) NSArray<NSDictionary *> *entries;
@property (nonatomic, strong) NSMutableSet<NSString *> *selectedPaths;

/// 界面被关掉时回调（用来恢复悬浮窗）
@property (nonatomic, copy) void (^onDismiss)(void);
/// 用户点了「导出」，参数是要导出的绝对路径（文件或文件夹）
@property (nonatomic, copy) void (^onExport)(NSArray<NSString *> *paths);
/// 选目录模式下用户确认了某个目录
@property (nonatomic, copy) void (^onPickDirectory)(NSString *path);

@end

@implementation IPATFbBrowserController

- (instancetype)initWithDirectory:(NSString *)directory root:(NSString *)root mode:(IPATFbBrowserMode)mode {
    if ((self = [super initWithStyle:UITableViewStylePlain])) {
        _directory = [directory copy];
        _rootDirectory = [root copy];
        _mode = mode;
        _selectedPaths = [NSMutableSet set];
        _entries = @[];
    }
    return self;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.tableView.rowHeight = 52.0;

    if (self.mode != IPATFbBrowserModeExport) {
        self.navigationItem.prompt = @"进入文件夹后点右上角「导入到这里」（同名直接覆盖）";
        self.navigationItem.rightBarButtonItem =
            [[UIBarButtonItem alloc] initWithTitle:@"导入到这里"
                                            style:UIBarButtonItemStyleDone
                                           target:self
                                           action:@selector(handlePickHere)];
    } else {
        self.navigationItem.prompt = @"点文件夹右侧圆圈可勾选 · 点文件夹名进入";
        self.navigationItem.rightBarButtonItem =
            [[UIBarButtonItem alloc] initWithTitle:@"导出"
                                            style:UIBarButtonItemStyleDone
                                           target:self
                                           action:@selector(handleExport)];
        [self setupHeaderActions];
    }

    // 栈底那一页没有系统返回按钮，自己给一个关闭入口（子目录由导航栏自动提供返回）
    if (self.navigationController.viewControllers.firstObject == self ||
        [self.directory isEqualToString:self.rootDirectory]) {
        self.navigationItem.leftBarButtonItem =
            [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemClose
                                                          target:self
                                                          action:@selector(handleClose)];
    }
    [self setupUpLevelHeaderIfNeeded];
    [self reloadEntries];
}

/// 上一级：只在浏览根之内给。起始页停在默认导入目录（Documents）时，
/// 靠它才能回到沙盒根去挑 Library / tmp 这些同级目录；也挡住了越出配置范围
- (NSString *)upLevelDirectory {
    NSString *root = self.rootDirectory;
    if (root.length == 0 || [self.directory isEqualToString:root]) return nil;
    NSString *parent = [self.directory stringByDeletingLastPathComponent];
    if (parent.length == 0 || [parent isEqualToString:self.directory]) return nil;
    if (!IPATFbIsWithin(root, parent)) return nil;
    return parent;
}

- (void)setupUpLevelHeaderIfNeeded {
    NSString *parent = [self.upLevelDirectory copy];
    if (!parent) return;

    UIView *header = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 320.0, 38.0)];
    UIButton *up = [UIButton buttonWithType:UIButtonTypeSystem];
    up.frame = CGRectMake(12.0, 0, 296.0, 38.0);
    up.autoresizingMask = UIViewAutoresizingFlexibleWidth;
    up.contentHorizontalAlignment = UIControlContentHorizontalAlignmentLeft;
    up.titleLabel.font = [UIFont systemFontOfSize:14.0];
    [up setTitle:[NSString stringWithFormat:@"↑ 上一级（%@）", IPATFbDisplayPath(parent)]
        forState:UIControlStateNormal];
    [up addTarget:self action:@selector(handleGoUp) forControlEvents:UIControlEventTouchUpInside];
    [header addSubview:up];
    self.tableView.tableHeaderView = header;
}

- (void)handleGoUp {
    NSString *parent = [self.upLevelDirectory copy];
    if (!parent) return;
    IPATFbBrowserController *up =
        [[IPATFbBrowserController alloc] initWithDirectory:parent root:self.rootDirectory mode:self.mode];
    up.onDismiss = self.onDismiss;
    up.onExport = self.onExport;
    up.onPickDirectory = self.onPickDirectory;
    [self.navigationController pushViewController:up animated:YES];
}

/// 导出模式顶部加两个快捷操作，省得一个个勾
- (void)setupHeaderActions {
    UIView *header = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 320.0, 44.0)];

    UIButton *selectAll = [UIButton buttonWithType:UIButtonTypeSystem];
    [selectAll setTitle:@"全选本目录文件" forState:UIControlStateNormal];
    selectAll.titleLabel.font = [UIFont systemFontOfSize:14.0];
    [selectAll addTarget:self action:@selector(handleSelectAll) forControlEvents:UIControlEventTouchUpInside];

    UIButton *exportDir = [UIButton buttonWithType:UIButtonTypeSystem];
    [exportDir setTitle:@"导出整个文件夹" forState:UIControlStateNormal];
    exportDir.titleLabel.font = [UIFont systemFontOfSize:14.0];
    [exportDir addTarget:self action:@selector(handleExportDirectory) forControlEvents:UIControlEventTouchUpInside];

    UIStackView *stack = [[UIStackView alloc] initWithArrangedSubviews:@[selectAll, exportDir]];
    stack.axis = UILayoutConstraintAxisHorizontal;
    stack.distribution = UIStackViewDistributionFillEqually;
    stack.translatesAutoresizingMaskIntoConstraints = NO;
    [header addSubview:stack];
    [NSLayoutConstraint activateConstraints:@[
        [stack.leadingAnchor constraintEqualToAnchor:header.leadingAnchor constant:12.0],
        [stack.trailingAnchor constraintEqualToAnchor:header.trailingAnchor constant:-12.0],
        [stack.topAnchor constraintEqualToAnchor:header.topAnchor constant:4.0],
        [stack.bottomAnchor constraintEqualToAnchor:header.bottomAnchor constant:-4.0],
    ]];
    self.tableView.tableHeaderView = header;
}

- (void)handleSelectAll {
    for (NSDictionary *entry in self.entries) {
        if ([entry[@"dir"] boolValue]) continue;
        [self.selectedPaths addObject:entry[@"path"]];
    }
    [self.tableView reloadData];
    [self updateExportButton];
}

/// 不勾任何东西，直接把当前所在的整个文件夹导出去
- (void)handleExportDirectory {
    if (self.onExport) self.onExport(@[self.directory]);
}

- (void)handlePickHere {
    if (self.onPickDirectory) self.onPickDirectory(self.directory);
}

- (void)handleClose {
    [self dismissViewControllerAnimated:YES completion:nil];
}

- (void)viewDidDisappear:(BOOL)animated {
    [super viewDidDisappear:animated];
    BOOL dismissed = self.isBeingDismissed || self.navigationController.isBeingDismissed;
    if (dismissed && self.onDismiss) self.onDismiss();
}

- (void)reloadEntries {
    [self updateTitle];

    NSFileManager *fm = [NSFileManager defaultManager];
    NSArray<NSString *> *names = [fm contentsOfDirectoryAtPath:self.directory error:NULL] ?: @[];
    NSMutableArray<NSDictionary *> *items = [NSMutableArray array];
    NSString *realDir = self.directory.stringByResolvingSymlinksInPath;
    for (NSString *name in [names sortedArrayUsingSelector:@selector(localizedStandardCompare:)]) {
        if ([name hasPrefix:@"."]) continue;  // 跳过隐藏项，沙盒里大多是系统文件
        NSString *path = [self.directory stringByAppendingPathComponent:name];
        BOOL isDir = NO;
        if (![fm fileExistsAtPath:path isDirectory:&isDir]) continue;
        NSMutableDictionary *item = [NSMutableDictionary dictionaryWithDictionary:
                                     @{@"name": name, @"path": path, @"dir": @(isDir)}];
        // 符号链接单独标出来：浏览器跟随链接，链接指回上层时点进去还是同一堆东西，
        // 看着像「无限个下一级文件夹」，其实只有一个（tmp 里常见）
        BOOL isLink = [[fm attributesOfItemAtPath:path error:NULL][NSFileType]
                       isEqualToString:NSFileTypeSymbolicLink];
        if (isLink) {
            item[@"link"] = @YES;
            NSString *real = path.stringByResolvingSymlinksInPath;
            if ([real isEqualToString:realDir] ||
                [realDir hasPrefix:[real stringByAppendingString:@"/"]]) {
                item[@"loop"] = @YES;
            }
        }
        [items addObject:item];
    }
    self.entries = items;
    [self.tableView reloadData];
    [self updateExportButton];

    if (items.count == 0) {
        UILabel *empty = [[UILabel alloc] initWithFrame:CGRectMake(0, 0, self.tableView.bounds.size.width, 60)];
        empty.text = @"这个目录是空的";
        empty.textAlignment = NSTextAlignmentCenter;
        empty.font = [UIFont systemFontOfSize:13.0];
        empty.textColor = [UIColor secondaryLabelColor];
        self.tableView.tableFooterView = empty;
    } else {
        self.tableView.tableFooterView = nil;
    }
}

- (void)updateTitle {
    NSString *home = NSHomeDirectory();
    NSString *relative = [self.directory hasPrefix:home]
        ? [self.directory substringFromIndex:home.length]
        : self.directory;
    relative = [relative stringByTrimmingCharactersInSet:
        [NSCharacterSet characterSetWithCharactersInString:@"/"]];
    self.title = relative.length ? relative : @"沙盒";
}

- (void)updateExportButton {
    if (self.mode != IPATFbBrowserModeExport) return;   // 选目录模式右上角是「导入到这里」，别动它
    NSString *title = self.selectedPaths.count > 0
        ? [NSString stringWithFormat:@"导出(%lu)", (unsigned long)self.selectedPaths.count]
        : @"导出";
    self.navigationItem.rightBarButtonItem.title = title;
}

- (NSString *)sizeDescriptionForPath:(NSString *)path {
    NSDictionary *attrs = [[NSFileManager defaultManager] attributesOfItemAtPath:path error:NULL];
    unsigned long long size = [attrs[NSFileSize] unsignedLongLongValue];
    if (size < 1024) return [NSString stringWithFormat:@"%llu B", size];
    if (size < 1024ULL * 1024ULL) return [NSString stringWithFormat:@"%.1f KB", size / 1024.0];
    return [NSString stringWithFormat:@"%.1f MB", size / (1024.0 * 1024.0)];
}

#pragma mark 表格

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    return (NSInteger)self.entries.count;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    static NSString *identifier = @"ipatool.file";
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:identifier];
    if (!cell) {
        cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle
                                      reuseIdentifier:identifier];
    }
    NSDictionary *entry = self.entries[(NSUInteger)indexPath.row];
    BOOL isDir = [entry[@"dir"] boolValue];
    NSString *path = entry[@"path"];

    BOOL isLink = [entry[@"link"] boolValue];
    cell.textLabel.text = isLink ? [NSString stringWithFormat:@"%@ ↪", entry[@"name"]]
                                 : entry[@"name"];
    cell.textLabel.font = [UIFont systemFontOfSize:15.0];
    NSString *kind = isDir ? @"文件夹" : [self sizeDescriptionForPath:path];
    if ([entry[@"loop"] boolValue]) kind = @"符号链接 → 回到上层，点进去还是这里";
    else if (isLink) kind = isDir ? @"符号链接 → 文件夹" : @"符号链接";
    cell.detailTextLabel.text = kind;
    cell.accessoryView = nil;
    cell.accessoryType = UITableViewCellAccessoryNone;

    if (isDir && self.mode == IPATFbBrowserModeExport) {
        // 右侧圆圈 = 勾选整个文件夹；点行本身还是进入
        cell.accessoryView = [self folderAccessorySelected:[self.selectedPaths containsObject:path]
                                                       row:(NSInteger)indexPath.row];
    } else if (isDir) {
        cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
    } else if (self.mode == IPATFbBrowserModeExport) {
        cell.accessoryType = [self.selectedPaths containsObject:path]
            ? UITableViewCellAccessoryCheckmark
            : UITableViewCellAccessoryNone;
    }
    return cell;
}

/// 文件夹行右侧：圆圈勾选（整文件夹导出）+ 箭头（提示点行可进入）
- (UIView *)folderAccessorySelected:(BOOL)selected row:(NSInteger)row {
    UIView *container = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 58.0, 30.0)];

    UIButton *check = [UIButton buttonWithType:UIButtonTypeCustom];
    check.frame = CGRectMake(0, 2, 26, 26);
    check.layer.cornerRadius = 13.0;
    check.layer.borderWidth = 1.5;
    check.selected = selected;
    check.titleLabel.font = [UIFont systemFontOfSize:15.0];
    [check setTitle:@"✓" forState:UIControlStateSelected];
    [check setTitleColor:[UIColor whiteColor] forState:UIControlStateSelected];
    UIColor *tint = selected ? [UIColor blueColor] : [UIColor lightGrayColor];
    check.layer.borderColor = tint.CGColor;
    check.backgroundColor = selected ? [UIColor blueColor] : [UIColor clearColor];
    check.tag = row;
    [check addTarget:self action:@selector(toggleFolder:) forControlEvents:UIControlEventTouchUpInside];
    [container addSubview:check];

    UILabel *arrow = [[UILabel alloc] initWithFrame:CGRectMake(30, 0, 24, 30)];
    arrow.text = @"›";
    arrow.textAlignment = NSTextAlignmentRight;
    arrow.font = [UIFont systemFontOfSize:24.0];
    arrow.textColor = [UIColor lightGrayColor];
    [container addSubview:arrow];

    return container;
}

- (void)toggleFolder:(UIButton *)sender {
    NSInteger row = sender.tag;
    if (row < 0 || (NSUInteger)row >= self.entries.count) return;
    NSDictionary *entry = self.entries[(NSUInteger)row];
    if (![entry[@"dir"] boolValue]) return;

    NSString *path = entry[@"path"];
    if ([self.selectedPaths containsObject:path]) {
        [self.selectedPaths removeObject:path];
    } else {
        [self.selectedPaths addObject:path];
    }
    [self.tableView reloadRowsAtIndexPaths:@[[NSIndexPath indexPathForRow:row inSection:0]]
                          withRowAnimation:UITableViewRowAnimationNone];
    [self updateExportButton];
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    NSDictionary *entry = self.entries[(NSUInteger)indexPath.row];
    NSString *path = entry[@"path"];

    if ([entry[@"dir"] boolValue]) {
        IPATFbBrowserController *child =
            [[IPATFbBrowserController alloc] initWithDirectory:path root:self.rootDirectory mode:self.mode];
        child.onDismiss = self.onDismiss;
        child.onExport = self.onExport;
        child.onPickDirectory = self.onPickDirectory;
        [self.navigationController pushViewController:child animated:YES];
        return;
    }

    if (self.mode != IPATFbBrowserModeExport) return;   // 选目录模式下文件不可选

    if ([self.selectedPaths containsObject:path]) {
        [self.selectedPaths removeObject:path];
    } else {
        [self.selectedPaths addObject:path];
    }
    [tableView reloadRowsAtIndexPaths:@[indexPath] withRowAnimation:UITableViewRowAnimationNone];
    [self updateExportButton];
}

#pragma mark 导出

- (void)handleExport {
    NSArray<NSString *> *paths = nil;
    if (self.selectedPaths.count > 0) {
        paths = [self.selectedPaths.allObjects sortedArrayUsingSelector:@selector(localizedStandardCompare:)];
    } else {
        // 没勾选任何文件：把当前文件夹整个导出
        paths = @[self.directory];
    }
    if (self.onExport) self.onExport(paths);
}

@end

#pragma mark - 与「文件」App 的桥接

typedef NS_ENUM(NSInteger, IPATFbPickerPurpose) {
    IPATFbPickerExport = 0,
    IPATFbPickerImport,
};

@interface IPATFbBridge : NSObject <UIDocumentPickerDelegate>

@property (nonatomic, assign) IPATFbPickerPurpose purpose;
@property (nonatomic, copy) NSString *lastStatus;
/// 本次导出打的临时 zip（导出完成后清理）
@property (nonatomic, copy) NSString *currentExportZip;
/// 本次导出打包的条目数（状态行用）
@property (nonatomic, assign) NSInteger exportItemCount;
/// 导入进度弹窗（导入期间悬浮面板是藏着的，状态行看不见）
@property (nonatomic, strong) UIAlertController *importAlert;
/// 本次导入的落地目录（用「导入到指定文件夹」挑过之后才有值）
@property (nonatomic, copy) NSString *importDirectory;

@end

@implementation IPATFbBridge

+ (instancetype)shared {
    static IPATFbBridge *shared;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ shared = [[IPATFbBridge alloc] init]; });
    return shared;
}

- (instancetype)init {
    if ((self = [super init])) {
        _purpose = IPATFbPickerExport;
    }
    return self;
}

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

- (void)start {
    // 三个功能合编在同一个 dylib 里，不检查的话没选文件功能也会挂上悬浮窗入口
    if (!IPATFbEnabled()) {
        IPATFbLog(@"文件功能未启用（IPAToolFiles.Enabled = NO）");
        return;
    }
    NSNotificationCenter *center = [NSNotificationCenter defaultCenter];
    [center addObserver:self
               selector:@selector(handlePanelChange:)
                   name:IPATControlDidChangeNotification
                 object:nil];
    [center addObserver:self
               selector:@selector(handlePanelDiscover:)
                   name:IPATControlDiscoverNotification
                 object:nil];
    [center addObserver:self
               selector:@selector(handleAction:)
                   name:IPATControlActionNotification
                 object:nil];
    [self restoreWritableLocks];   // 上次导入锁成只读的目录，这趟启动恢复成可写
    [self registerWithPanel];
    IPATFbLog(@"文件导入导出已就绪（导入目录：%@）", IPATFbImportRelative());
}

#pragma mark 面板注册

- (void)registerWithPanel {
    NSDictionary *reg = @{
        IPATRegId: IPATFeatureFiles,
        IPATRegTitle: @"文件导入导出",
        IPATRegDetail: @"导出 / 导入游戏热更资源",
        // 注入即可用，没有「关掉」的场景：面板不画总开关（真要关用 Info.plist 的 Enabled）
        IPATRegMasterHidden: @YES,
        IPATRegEnabled: @(IPATFbEnabled()),
        // 面板只留动作行：导入的落地目录在浏览器里挑，默认取 ImportDir
        // （Info.plist / --files-import-dir，默认 Documents）
        IPATRegRows: @[
            @{IPATRowKey: IPATFbActionBrowse,
              IPATRowTitle: @"浏览并导出文件",
              IPATRowKind: IPATRowKindAction,
              IPATRowNote: @"选文件夹或文件，打包 zip 导出到「文件」App"},
            @{IPATRowKey: IPATFbActionImportTo,
              IPATRowTitle: @"导入文件",
              IPATRowKind: IPATRowKindAction,
              IPATRowNote: [NSString stringWithFormat:@"挑落地目录，默认 %@（zip 自动解压，同名覆盖）",
                                                      IPATFbImportRelative()]},
        ],
    };
    [[NSNotificationCenter defaultCenter] postNotificationName:IPATControlRegisterNotification
                                                        object:nil
                                                      userInfo:reg];
    [self postStatus:nil];
}

/// 给面板上报一行状态
- (void)postStatus:(NSString *)detail {
    if (detail.length > 0) self.lastStatus = detail;
    NSString *text = self.lastStatus.length > 0 ? self.lastStatus : IPATFbDefaultStatus;
    [[NSNotificationCenter defaultCenter] postNotificationName:IPATControlStatusNotification
                                                        object:nil
                                                      userInfo:@{IPATRegId: IPATFeatureFiles,
                                                                 IPATStaDetail: text}];
}

#pragma mark 面板事件

- (void)handlePanelDiscover:(NSNotification *)note {
    [self registerWithPanel];
}

- (void)handlePanelChange:(NSNotification *)note {
    NSDictionary *userInfo = note.userInfo;
    if (![userInfo isKindOfClass:[NSDictionary class]]) return;
    if (![userInfo[IPATChgId] isEqual:IPATFeatureFiles]) return;
    BOOL enabled = [userInfo[IPATChgEnabled] boolValue];
    [self postStatus:enabled ? nil : @"已关闭"];
    IPATFbLog(@"配置已更新：%@", enabled ? @"开启" : @"关闭");
}

- (void)handleAction:(NSNotification *)note {
    NSDictionary *userInfo = note.userInfo;
    if (![userInfo isKindOfClass:[NSDictionary class]]) return;
    if (![userInfo[IPATChgId] isEqual:IPATFeatureFiles]) return;
    NSString *key = userInfo[IPATActKey];
    if ([key isEqualToString:IPATFbActionBrowse]) {
        [self openBrowserWithMode:IPATFbBrowserModeExport];
    } else if ([key isEqualToString:IPATFbActionImportTo]) {
        [self openBrowserWithMode:IPATFbBrowserModeImportTarget];
    }
}

#pragma mark 浏览器

- (void)openBrowserWithMode:(IPATFbBrowserMode)mode {
    if (!IPATFbEnabled()) {
        [self postStatus:@"功能已关闭"];
        return;
    }
    // 挑落地目录时从默认导入目录起步，省得每次从沙盒根一层层点进去；
    // 但可浏览的最上层仍然是 BrowseRoot（默认沙盒根），这样还能往上挑
    // Documents 同级的 Library / tmp 之类的目录
    NSString *root = IPATFbBrowseRoot();
    NSString *start = root;
    if (mode != IPATFbBrowserModeExport) {
        NSString *import = IPATFbImportDirectory();
        BOOL importIsDir = NO;
        if ([[NSFileManager defaultManager] fileExistsAtPath:import isDirectory:&importIsDir]
            && importIsDir && IPATFbIsWithin(import, root)) {
            start = import;
        }
    }
    BOOL isDir = NO;
    if (![[NSFileManager defaultManager] fileExistsAtPath:root isDirectory:&isDir] || !isDir) {
        [self postStatus:@"浏览根目录不存在"];
        return;
    }
    if (![[NSFileManager defaultManager] fileExistsAtPath:start isDirectory:&isDir] || !isDir) {
        start = root;
    }

    IPATFbBrowserController *browser =
        [[IPATFbBrowserController alloc] initWithDirectory:start root:root mode:mode];
    __weak typeof(self) weakSelf = self;
    __weak IPATFbBrowserController *weakBrowser = browser;
    browser.onDismiss = ^{
        IPATFbSetOverlayVisible(YES);
        [weakSelf postStatus:nil];
    };
    browser.onExport = ^(NSArray<NSString *> *paths) {
        [weakSelf exportPaths:paths from:weakBrowser];
    };
    browser.onPickDirectory = ^(NSString *path) {
        // 先收起浏览器，下一帧再弹系统选择器，避免两个 present 撞车
        IPATFbBrowserController *strongBrowser = weakBrowser;
        [strongBrowser dismissViewControllerAnimated:YES completion:^{
            dispatch_async(dispatch_get_main_queue(), ^{
                [weakSelf openImporterToDirectory:path];
            });
        }];
    };

    UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:browser];
    nav.modalPresentationStyle = UIModalPresentationFullScreen;
    IPATFbSetOverlayVisible(NO);
    [self presentFromTop:nav];
}

/// 弹窗统一从这里出：挂在专用窗口上（没有就退回 App 自己的顶层控制器）
- (void)presentNow:(UIViewController *)controller {
    UIWindow *window = IPATFbAlertWindow();
    if (window) {
        IPATFbSyncWindowGeometry();   // 弹之前先把窗口对齐到游戏的方向（横屏游戏里默认是竖的）
        if (window.hidden) window.hidden = NO;
    }
    UIViewController *host = window ? window.rootViewController : IPATFbTopViewController();
    while (host.presentedViewController) host = host.presentedViewController;   // 挂在最上层那个上面
    if (!host) {
        IPATFbSetOverlayVisible(YES);
        IPATFbLog(@"没有可用的控制器来弹窗");
        return;
    }
    void (^go)(void) = ^{
        // 系统文档选择器（「文件」App）是远程视图，宿主窗口必须是 key window，
        // 不然界面出来了却点不动，所以弹它之前先把焦点抢过来
        if ([controller isKindOfClass:[UIDocumentPickerViewController class]]) {
            IPATFbTakeKeyWindow();
        }
        [host presentViewController:controller animated:YES completion:nil];
        IPATFbWatchDismiss(controller);
    };
    if (host.presentedViewController && host.presentedViewController != controller) {
        // 上一个还没退干净时 present 会静默失败：表现就是弹不出来，或者弹出来点不动
        IPATFbLog(@"上一个弹窗还没退干净，先收起再弹");
        [host dismissViewControllerAnimated:NO completion:^{
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.2 * NSEC_PER_SEC)),
                           dispatch_get_main_queue(), go);
        }];
        return;
    }
    go();
}

/// 下一帧再弹，避开「前一个弹窗正在退场」这个坑
- (void)presentFromTop:(UIViewController *)controller {
    dispatch_async(dispatch_get_main_queue(), ^{
        [self presentNow:controller];
    });
}

#pragma mark - ZIP 打包（导出用）

/// 导出统一打成 zip（store 不压缩 + ZIP64）：热更资源多是已压缩格式，
/// deflate 只费电不省空间；store 是纯 I/O，几个 G 也是分钟级。
/// 生成的包用「导入文件」导回来会自动解压，正好配套。

static void IPATFbZipAppend16(NSMutableData *d, uint16_t v) {
    uint8_t b[2] = { (uint8_t)(v & 0xFF), (uint8_t)(v >> 8) };
    [d appendBytes:b length:2];
}

static void IPATFbZipAppend32(NSMutableData *d, uint32_t v) {
    uint8_t b[4] = { (uint8_t)(v & 0xFF), (uint8_t)((v >> 8) & 0xFF),
                     (uint8_t)((v >> 16) & 0xFF), (uint8_t)(v >> 24) };
    [d appendBytes:b length:4];
}

static void IPATFbZipAppend64(NSMutableData *d, uint64_t v) {
    IPATFbZipAppend32(d, (uint32_t)(v & 0xFFFFFFFFULL));
    IPATFbZipAppend32(d, (uint32_t)(v >> 32));
}

static void IPATFbZipDosTimestamp(uint16_t *dosTime, uint16_t *dosDate) {
    NSDateComponents *c = [[NSCalendar currentCalendar]
        components:(NSCalendarUnitHour | NSCalendarUnitMinute | NSCalendarUnitSecond |
                    NSCalendarUnitYear | NSCalendarUnitMonth | NSCalendarUnitDay)
          fromDate:[NSDate date]];
    *dosTime = (uint16_t)(((c.hour & 0x1F) << 11) | ((c.minute & 0x3F) << 5) | ((c.second / 2) & 0x1F));
    *dosDate = (uint16_t)((((c.year - 1980) & 0x7F) << 9) | ((c.month & 0xF) << 5) | (c.day & 0x1F));
}

/// 目录的唯一标识（设备号 + inode）。判断「是不是同一个目录」时用它最靠谱：
/// 不受 /var 与 /private/var 这类写法差异影响，也能认出指回自己的循环链接。
static NSString *IPATFbNodeKey(NSDictionary *attr) {
    NSNumber *ino = attr[NSFileSystemFileNumber];
    if (!ino) return nil;
    return [NSString stringWithFormat:@"%@:%@", attr[NSFileSystemNumber] ?: @0, ino];
}

/// 收集一个导出项（文件或整个目录）的条目列表；name 是 zip 内的相对路径。
/// 刻意用和沙盒浏览器同一套列目录方式（contentsOfDirectoryAtPath + fileExists），
/// 保证「浏览器里看得到，包里就一定有」——深枚举在部分目录上会静默返回空。
/// 几个防呆：
///  - excludeDir / excludeFile：导出包所在的目录和包本身不进包。之前包直接写
///    在 tmp 根下，导出 tmp 时上一次的 zip 会被当成普通文件一起打进新包，
///    体积一轮轮翻倍（几 MB 的目录导出半天就是这么来的）；目录按 inode 比对，
///    免得路径写法不一样（/var 与 /private/var）时漏掉；
///  - 符号链接不进包：跟着递归会绕回父目录，直接死循环；
///  - dirChain：同一条路径上出现过同一个目录就停手。tmp 里那种「下一层还是 tmp」
///    的循环目录，靠它拦住，不然会一路递归到 64 层，包里全是空目录；
///  - depth / limit：层级过深或条目极多时及时停手，别让打包变成假死。
static BOOL IPATFbZipCollectEntry(NSString *path, NSString *name,
                                  NSMutableArray<NSDictionary *> *entries,
                                  uint64_t *totalBytes,
                                  NSString *excludeDir,
                                  NSString *excludeDirKey,
                                  NSString *excludeFile,
                                  NSInteger depth,
                                  NSInteger *counter,
                                  NSInteger limit,
                                  NSMutableSet<NSString *> *dirChain,
                                  void (^tick)(NSInteger count),
                                  NSError **error) {
    NSFileManager *fm = [NSFileManager defaultManager];

    if ((excludeDir.length && [path isEqualToString:excludeDir]) ||
        (excludeFile.length && [path isEqualToString:excludeFile])) {
        IPATFbLog(@"收集时跳过导出临时目录：%@", path);
        return YES;
    }
    if (depth > 64) {
        IPATFbLog(@"目录层级过深，不再往下：%@", path);
        return YES;
    }
    if (*counter >= limit) {
        if (error) *error = [NSError errorWithDomain:@"IPAToolFiles" code:8
                                        userInfo:@{NSLocalizedDescriptionKey:
                                                   [NSString stringWithFormat:
                                                    @"条目过多（超过 %ld 项），打包已中止",
                                                    (long)limit]}];
        return NO;
    }

    NSDictionary *attr = [fm attributesOfItemAtPath:path error:NULL];
    if (!attr) {   // 读不到的（权限 / 已消失）跳过，别让整个导出失败
        IPATFbLog(@"收集时跳过读不到的项：%@", path);
        return YES;
    }
    NSString *fileType = attr[NSFileType];
    if ([fileType isEqualToString:NSFileTypeSymbolicLink]) {
        IPATFbLog(@"收集时跳过符号链接：%@", path);
        return YES;
    }

    (*counter)++;
    if (tick && (*counter % 500) == 0) tick(*counter);

    if ([fileType isEqualToString:NSFileTypeDirectory]) {
        NSString *key = IPATFbNodeKey(attr);
        if (key.length && excludeDirKey.length && [key isEqualToString:excludeDirKey]) {
            IPATFbLog(@"收集时跳过导出临时目录：%@", path);
            return YES;
        }
        if (key.length && [dirChain containsObject:key]) {
            IPATFbLog(@"收集时跳过循环目录（下一层还是它自己）：%@", path);
            return YES;
        }
        if (key.length) [dirChain addObject:key];

        [entries addObject:@{@"path": [NSNull null], @"name": [name stringByAppendingString:@"/"],
                             @"size": @0, @"dir": @YES}];
        NSArray<NSString *> *names = [fm contentsOfDirectoryAtPath:path error:NULL] ?: @[];
        BOOL ok = YES;
        for (NSString *child in [names sortedArrayUsingSelector:@selector(localizedStandardCompare:)]) {
            NSString *childPath = [path stringByAppendingPathComponent:child];
            NSString *entryName = [name stringByAppendingPathComponent:child];
            if (!IPATFbZipCollectEntry(childPath, entryName, entries, totalBytes,
                                       excludeDir, excludeDirKey, excludeFile, depth + 1,
                                       counter, limit, dirChain, tick, error)) {
                ok = NO;
                break;
            }
        }
        if (key.length) [dirChain removeObject:key];
        return ok;
    }

    uint64_t size = [attr[NSFileSize] unsignedLongLongValue];
    [entries addObject:@{@"path": path, @"name": name,
                         @"size": @(size), @"dir": @NO}];
    *totalBytes += size;
    return YES;
}

/// 打包：entries 先收集好（顺带得到总体积），逐条写入并回填 CRC
static BOOL IPATFbZipWrite(NSArray<NSDictionary *> *entries, uint64_t totalBytes,
                           NSString *zipPath,
                           void (^progress)(uint64_t done, uint64_t total),
                           NSError **error) {
    // ZIP64：数据超 4G 或条目超 65535 才启用；平时保持最普通的 zip 格式
    BOOL need64 = totalBytes > 0xFFFFFFFFULL || (uint64_t)entries.count > 0xFFFF;
    for (NSDictionary *e in entries) {
        if ([e[@"size"] unsignedLongLongValue] > 0xFFFFFFFFULL) { need64 = YES; break; }
    }

    FILE *out = fopen(zipPath.fileSystemRepresentation, "wb");
    if (!out) {
        if (error) *error = [NSError errorWithDomain:@"IPAToolFiles" code:9
                                         userInfo:@{NSLocalizedDescriptionKey: @"创建临时 zip 失败"}];
        return NO;
    }

    BOOL ok = NO;
    NSMutableData *cd = [NSMutableData data];
    uint8_t *buf = malloc(1024 * 1024);
    uint16_t dosTime, dosDate;
    IPATFbZipDosTimestamp(&dosTime, &dosDate);
    uint64_t offset = 0, done = 0, lastReport = 0;
    NSInteger fileIndex = 0;
    uint16_t version = need64 ? 45 : 20;

    for (NSDictionary *e in entries) {
        if ([e[@"dir"] boolValue]) {
            // 目录条目：只有头，没有数据
            NSData *name = [e[@"name"] dataUsingEncoding:NSUTF8StringEncoding];
            NSMutableData *h = [NSMutableData data];
            IPATFbZipAppend32(h, 0x04034b50);
            IPATFbZipAppend16(h, version);
            IPATFbZipAppend16(h, 0x800);          // UTF-8 文件名
            IPATFbZipAppend16(h, 0);              // store
            IPATFbZipAppend16(h, dosTime);
            IPATFbZipAppend16(h, dosDate);
            IPATFbZipAppend32(h, 0);              // crc
            IPATFbZipAppend32(h, 0);              // comp size
            IPATFbZipAppend32(h, 0);              // uncomp size
            IPATFbZipAppend16(h, (uint16_t)name.length);
            IPATFbZipAppend16(h, 0);              // extra len
            [h appendData:name];
            uint64_t headerOffset = offset;       // 注意先记位置再写：CD 记的是 LFH 起始
            if (fwrite(h.bytes, 1, h.length, out) != h.length) goto fail;
            offset += h.length;

            IPATFbZipAppend32(cd, 0x02014b50);
            IPATFbZipAppend16(cd, version);       // made by
            IPATFbZipAppend16(cd, version);
            IPATFbZipAppend16(cd, 0x800);
            IPATFbZipAppend16(cd, 0);
            IPATFbZipAppend16(cd, dosTime);
            IPATFbZipAppend16(cd, dosDate);
            IPATFbZipAppend32(cd, 0);
            IPATFbZipAppend32(cd, 0);
            IPATFbZipAppend32(cd, 0);
            IPATFbZipAppend16(cd, (uint16_t)name.length);
            IPATFbZipAppend16(cd, 0);
            IPATFbZipAppend16(cd, 0);             // comment
            IPATFbZipAppend16(cd, 0);             // disk start
            IPATFbZipAppend16(cd, 0);             // internal attr
            IPATFbZipAppend32(cd, 0x10);          // external attr：目录位
            IPATFbZipAppend32(cd, (uint32_t)headerOffset);
            [cd appendData:name];
            continue;
        }

        uint64_t size = [e[@"size"] unsignedLongLongValue];
        NSData *name = [e[@"name"] dataUsingEncoding:NSUTF8StringEncoding];
        NSMutableData *h = [NSMutableData data];
        IPATFbZipAppend32(h, 0x04034b50);
        IPATFbZipAppend16(h, version);
        IPATFbZipAppend16(h, 0x800);
        IPATFbZipAppend16(h, 0);                  // store
        IPATFbZipAppend16(h, dosTime);
        IPATFbZipAppend16(h, dosDate);
        IPATFbZipAppend32(h, 0);                  // crc 占位，写完回填
        if (need64) {
            IPATFbZipAppend32(h, 0xFFFFFFFF);
            IPATFbZipAppend32(h, 0xFFFFFFFF);
        } else {
            IPATFbZipAppend32(h, (uint32_t)size);
            IPATFbZipAppend32(h, (uint32_t)size);
        }
        IPATFbZipAppend16(h, (uint16_t)name.length);
        if (need64) {
            IPATFbZipAppend16(h, 20);             // zip64 extra：uncomp + comp
        } else {
            IPATFbZipAppend16(h, 0);
        }
        [h appendData:name];
        if (need64) {
            IPATFbZipAppend16(h, 0x0001);
            IPATFbZipAppend16(h, 16);
            IPATFbZipAppend64(h, size);
            IPATFbZipAppend64(h, size);
        }
        uint64_t headerOffset = offset;
        if (fwrite(h.bytes, 1, h.length, out) != h.length) goto fail;
        offset += h.length;

        FILE *in = fopen([e[@"path"] fileSystemRepresentation], "rb");
        if (!in) goto fail;
        uLong crc = crc32(0, Z_NULL, 0);
        uint64_t remaining = size;
        for (;;) {
            size_t n = fread(buf, 1, remaining < 1024 * 1024 ? (size_t)remaining : 1024 * 1024, in);
            if (n == 0) break;
            if (fwrite(buf, 1, n, out) != n) { fclose(in); goto fail; }
            crc = crc32(crc, buf, (uInt)n);
            done += n;
            remaining -= n;
        }
        fclose(in);
        offset += size;
        fileIndex++;
        // 每 32MB 或每 200 个文件报一次进度：小文件也要看得到在动，
        // 之前 256MB 一报，导出小目录时进度条会一直停在同一个数字上
        if (progress && (done - lastReport >= 32ULL * 1024 * 1024 || (fileIndex % 200) == 0)) {
            lastReport = done;
            progress(done, totalBytes);
        }

        // 回填 CRC（little endian）
        uint8_t cb[4] = { (uint8_t)(crc & 0xFF), (uint8_t)((crc >> 8) & 0xFF),
                          (uint8_t)((crc >> 16) & 0xFF), (uint8_t)((crc >> 24) & 0xFF) };
        if (fseeko(out, (off_t)(headerOffset + 14), SEEK_SET) != 0 ||
            fwrite(cb, 1, 4, out) != 4 ||
            fseeko(out, (off_t)offset, SEEK_SET) != 0) goto fail;

        IPATFbZipAppend32(cd, 0x02014b50);
        IPATFbZipAppend16(cd, version);
        IPATFbZipAppend16(cd, version);
        IPATFbZipAppend16(cd, 0x800);
        IPATFbZipAppend16(cd, 0);
        IPATFbZipAppend16(cd, dosTime);
        IPATFbZipAppend16(cd, dosDate);
        IPATFbZipAppend32(cd, (uint32_t)crc);
        if (need64) {
            IPATFbZipAppend32(cd, 0xFFFFFFFF);
            IPATFbZipAppend32(cd, 0xFFFFFFFF);
        } else {
            IPATFbZipAppend32(cd, (uint32_t)size);
            IPATFbZipAppend32(cd, (uint32_t)size);
        }
        IPATFbZipAppend16(cd, (uint16_t)name.length);
        if (need64) IPATFbZipAppend16(cd, 28);    // zip64 extra：uncomp + comp + offset
        else IPATFbZipAppend16(cd, 0);
        IPATFbZipAppend16(cd, 0);
        IPATFbZipAppend16(cd, 0);
        IPATFbZipAppend16(cd, 0);
        IPATFbZipAppend32(cd, 0x20);              // external attr：普通文件
        if (need64) IPATFbZipAppend32(cd, 0xFFFFFFFF);
        else IPATFbZipAppend32(cd, (uint32_t)headerOffset);
        [cd appendData:name];
        if (need64) {
            IPATFbZipAppend16(cd, 0x0001);
            IPATFbZipAppend16(cd, 24);
            IPATFbZipAppend64(cd, size);
            IPATFbZipAppend64(cd, size);
            IPATFbZipAppend64(cd, headerOffset);
        }
    }

    uint64_t cdOffset = offset;
    if (fwrite(cd.bytes, 1, cd.length, out) != cd.length) goto fail;
    offset += cd.length;

    if (need64) {
        // ZIP64 EOCD + 定位器
        NSMutableData *z = [NSMutableData data];
        IPATFbZipAppend32(z, 0x06064b50);
        IPATFbZipAppend64(z, 44);                 // 本记录剩余长度
        IPATFbZipAppend16(z, 45);
        IPATFbZipAppend16(z, 45);
        IPATFbZipAppend32(z, 0);
        IPATFbZipAppend32(z, 0);
        IPATFbZipAppend64(z, entries.count);
        IPATFbZipAppend64(z, entries.count);
        IPATFbZipAppend64(z, cd.length);
        IPATFbZipAppend64(z, cdOffset);
        if (fwrite(z.bytes, 1, z.length, out) != z.length) goto fail;

        NSMutableData *loc = [NSMutableData data];
        IPATFbZipAppend32(loc, 0x07064b50);
        IPATFbZipAppend32(loc, 0);
        IPATFbZipAppend64(loc, offset);
        IPATFbZipAppend32(loc, 1);
        if (fwrite(loc.bytes, 1, loc.length, out) != loc.length) goto fail;
        offset += z.length + loc.length;
    }

    {
        NSMutableData *eocd = [NSMutableData data];
        IPATFbZipAppend32(eocd, 0x06054b50);
        IPATFbZipAppend16(eocd, 0);
        IPATFbZipAppend16(eocd, 0);
        IPATFbZipAppend16(eocd, need64 ? 0xFFFF : (uint16_t)entries.count);
        IPATFbZipAppend16(eocd, need64 ? 0xFFFF : (uint16_t)entries.count);
        IPATFbZipAppend32(eocd, need64 ? 0xFFFFFFFF : (uint32_t)cd.length);
        IPATFbZipAppend32(eocd, need64 ? 0xFFFFFFFF : (uint32_t)cdOffset);
        IPATFbZipAppend16(eocd, 0);
        if (fwrite(eocd.bytes, 1, eocd.length, out) != eocd.length) goto fail;
    }

    ok = YES;
    if (progress) progress(totalBytes, totalBytes);

fail:
    if (!ok) {
        if (error && !*error)
            *error = [NSError errorWithDomain:@"IPAToolFiles" code:9
                                 userInfo:@{NSLocalizedDescriptionKey:
                                            [NSString stringWithFormat:@"打包中断（%@）：沙盒空间不足或文件被热更改动",
                                                       zipPath.lastPathComponent]}];
        [[NSFileManager defaultManager] removeItemAtPath:zipPath error:NULL];
    }
    free(buf);
    fclose(out);
    return ok;
}

#pragma mark 导出

- (void)exportPaths:(NSArray<NSString *> *)paths from:(UIViewController *)presenter {
    NSFileManager *fm = [NSFileManager defaultManager];
    NSMutableArray<NSString *> *valid = [NSMutableArray array];
    NSInteger missing = 0;
    for (NSString *path in paths) {
        if ([fm fileExistsAtPath:path]) {
            [valid addObject:path];
        } else {
            missing++;   // 常见于热更把文件删了 / 改名了，浏览器列表是旧快照
        }
    }
    if (valid.count == 0) {
        [self postStatus:missing > 0
            ? @"没有可导出的内容（所选文件已不存在，可能被热更删除）"
            : @"没有可导出的内容"];
        return;
    }
    if (missing > 0) {
        [self postStatus:[NSString stringWithFormat:@"有 %ld 项已不存在被跳过（可能被热更删除）",
                                                    (long)missing]];
        IPATFbLog(@"导出跳过 %ld 个不存在的路径", (long)missing);
    }

    // 清掉旧版本留在 tmp 根下的临时 zip
    for (NSURL *f in [fm contentsOfDirectoryAtURL:[NSURL fileURLWithPath:NSTemporaryDirectory()]
                    includingPropertiesForKeys:nil options:0 error:NULL]) {
        if ([f.lastPathComponent hasPrefix:@"IPAToolExport-"]) [fm removeItemAtURL:f error:NULL];
    }
    // 导出包统一放 tmp/IPAToolExport/，每次重建。
    // 之前直接写 tmp 根下：导出 tmp 这类目录时，上一次的 zip 会被当成普通文件
    // 一起打进新包，包里套包，体积一轮轮翻倍（几 MB 的目录导出半天就是这么来的）
    NSString *workDir = [NSTemporaryDirectory() stringByAppendingPathComponent:@"IPAToolExport"];
    [fm removeItemAtPath:workDir error:NULL];
    [fm createDirectoryAtPath:workDir withIntermediateDirectories:YES attributes:nil error:NULL];

    // 包名：单选跟原名字，多选用时间戳
    NSDateFormatter *fmt = [[NSDateFormatter alloc] init];
    fmt.dateFormat = @"yyyyMMdd-HHmmss";
    NSString *base = valid.count == 1
        ? [valid[0].lastPathComponent stringByDeletingPathExtension]
        : [NSString stringWithFormat:@"IPAToolExport-%@", [fmt stringFromDate:[NSDate date]]];
    if (base.length == 0) base = @"IPAToolExport";
    NSString *zipPath = [workDir stringByAppendingPathComponent:
                         [NSString stringWithFormat:@"%@.zip", base]];

    self.exportItemCount = (NSInteger)valid.count;
    [self postStatus:[NSString stringWithFormat:@"正在打包 %ld 项为 zip…", (long)valid.count]];

    // 打包大目录要跑好几分钟，进度直接显示在浏览器上——
    // 悬浮面板这时是藏起来的，状态行发了也看不见
    UIAlertController *packAlert =
        [UIAlertController alertControllerWithTitle:@"正在打包 zip…"
                                            message:@"扫描文件中…"
                                     preferredStyle:UIAlertControllerStyleAlert];
    [presenter presentViewController:packAlert animated:YES completion:nil];

    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        IPATFbLog(@"开始导出 %ld 项：%@", (long)valid.count, valid);
        // 先收集条目（顺带统计总体积），再打包
        NSMutableArray<NSDictionary *> *entries = [NSMutableArray array];
        uint64_t totalBytes = 0;
        NSError *error = nil;
        BOOL ok = YES;
        NSInteger counter = 0;
        __weak UIAlertController *weakAlert = packAlert;
        void (^tick)(NSInteger) = ^(NSInteger count) {
            dispatch_async(dispatch_get_main_queue(), ^{
                weakAlert.message = [NSString stringWithFormat:@"扫描中：%ld 项…", (long)count];
            });
        };
        NSString *workDirKey = IPATFbNodeKey([fm attributesOfItemAtPath:workDir error:NULL] ?: @{});
        for (NSString *path in valid) {
            NSString *name = path.lastPathComponent;
            NSMutableSet<NSString *> *dirChain = [NSMutableSet set];   // 每个顶层项各自一条链
            if (!IPATFbZipCollectEntry(path, name, entries, &totalBytes,
                                       workDir, workDirKey, zipPath, 0, &counter, 300000,
                                       dirChain, tick, &error)) {
                ok = NO;
                break;
            }
        }
        NSInteger collectedFiles = 0, collectedDirs = 0;
        for (NSDictionary *e in entries) {
            if ([e[@"dir"] boolValue]) collectedDirs++; else collectedFiles++;
        }
        IPATFbLog(@"收集完成：文件 %ld、目录 %ld，共 %.2f GB",
                  (long)collectedFiles, (long)collectedDirs, totalBytes / 1073741824.0);
        // 收集不到任何文件就不出包：免得生成一个空 zip，让人以为导入坏了
        if (ok && collectedFiles == 0) {
            ok = NO;
            NSString *reason = collectedDirs > 0
                ? [NSString stringWithFormat:
                   @"里面只有 %ld 个空目录，没有可打包的文件"
                   @"（比如 tmp 那种一层层点下去还是 tmp 的循环链接，已自动跳过）",
                   (long)collectedDirs]
                : @"没有收集到任何内容（可能已被游戏清空或正在重写）";
            error = [NSError errorWithDomain:@"IPAToolFiles" code:10
                                 userInfo:@{NSLocalizedDescriptionKey: reason}];
        }
        if (ok) {
            dispatch_async(dispatch_get_main_queue(), ^{
                packAlert.message = [NSString stringWithFormat:
                                     @"文件 %ld、目录 %ld，共 %.2f GB\n写入中…",
                                     (long)collectedFiles, (long)collectedDirs,
                                     totalBytes / 1073741824.0];
            });
            ok = IPATFbZipWrite(entries, totalBytes, zipPath,
                ^(uint64_t done, uint64_t total) {
                    long percent = total > 0 ? (long)((double)done / (double)total * 100.0) : 0;
                    NSString *text = [NSString stringWithFormat:
                                      @"文件 %ld、目录 %ld，共 %.2f GB\n写入中 %ld%%",
                                      (long)collectedFiles, (long)collectedDirs,
                                      totalBytes / 1073741824.0, percent];
                    dispatch_async(dispatch_get_main_queue(), ^{
                        packAlert.message = text;
                        [self postStatus:[NSString stringWithFormat:@"打包中 %ld%%", percent]];
                    });
                }, &error);
        }
        dispatch_async(dispatch_get_main_queue(), ^{
            void (^showResult)(void) = ^{
                NSInteger fileCount = 0, dirCount = 0;
                uint64_t zipBytes = 0;
                for (NSDictionary *e in entries) {
                    if ([e[@"dir"] boolValue]) dirCount++;
                    else { fileCount++; zipBytes += [e[@"size"] unsignedLongLongValue]; }
                }
                if (!ok) {
                    IPATFbLog(@"打包失败：%@", error.localizedDescription ?: @"未知错误");
                    [self postStatus:[NSString stringWithFormat:@"打包失败：%@",
                                                                error.localizedDescription ?: @"未知错误"]];
                    UIAlertController *alert =
                        [UIAlertController alertControllerWithTitle:@"打包失败"
                            message:error.localizedDescription ?: @"未知错误"
                            preferredStyle:UIAlertControllerStyleAlert];
                    [alert addAction:[UIAlertAction actionWithTitle:@"好"
                                                              style:UIAlertActionStyleDefault
                                                            handler:nil]];
                    [self presentFromTop:alert];
                    return;
                }
                self.currentExportZip = zipPath;
                self.purpose = IPATFbPickerExport;
                // asCopy:YES —— 系统把 zip 拷到用户选的位置，沙盒原文件不受影响
                UIDocumentPickerViewController *picker =
                    [[UIDocumentPickerViewController alloc] initForExportingURLs:
                        @[[NSURL fileURLWithPath:zipPath]] asCopy:YES];
                picker.delegate = self;
                IPATFbLog(@"导出 zip 就绪：%ld 项（文件 %ld、目录 %ld，共 %.2f GB）-> %@",
                          (long)valid.count, (long)fileCount, (long)dirCount,
                          zipBytes / 1073741824.0, zipPath);
                [self presentFromTop:picker];
            };
            // 等打包提示框收完再弹下一个，否则会撞上「正在 present」的静默失败：
            // 表现就是打包完了但什么都没弹出来
            if (packAlert.view.window && packAlert.presentingViewController) {
                [packAlert dismissViewControllerAnimated:YES completion:^{
                    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
                                                 (int64_t)(0.25 * NSEC_PER_SEC)),
                                   dispatch_get_main_queue(), showResult);
                }];
            } else {
                showResult();
            }
        });
    });
}

#pragma mark 导入

/// directory 传 nil 表示用面板上选的预设目录。
/// 只保留文件入口：文件夹在 iOS 文档选择器里坑太多（asCopy 卡转圈），
/// 文件夹场景统一改成打成 zip 再导，导入时自动解压。
- (void)openImporterToDirectory:(NSString *)directory {
    if (!IPATFbEnabled()) {
        [self postStatus:@"功能已关闭"];
        return;
    }

    self.purpose = IPATFbPickerImport;
    self.importDirectory = directory.length ? [directory copy] : [IPATFbImportDirectory() copy];
    UIDocumentPickerViewController *picker = nil;
    if (@available(iOS 14.0, *)) {
        // asCopy:YES：系统先把选中的文件拷到本 App 的 tmp 再回调。
        // 之前试过 asCopy:NO（省掉这份拷贝），但从第三方文件提供方
        // （网盘 App、其他 App 的共享目录）选文件时，提供方不支持
        // 「就地打开」，点「打开」既不关闭选择器也不回调——只能退回来。
        // 代价是 4G 的 zip 会先占一份 tmp 空间，导入完成后由
        // importURLs 主动删掉这份副本。
        picker = [[UIDocumentPickerViewController alloc] initForOpeningContentTypes:@[UTTypeItem]
                                                                            asCopy:YES];
    } else {
        picker = [[UIDocumentPickerViewController alloc] initWithDocumentTypes:@[@"public.item"]
                                                                       inMode:UIDocumentPickerModeImport];
    }
    picker.allowsMultipleSelection = YES;
    picker.delegate = self;
    IPATFbSetOverlayVisible(NO);
    [self presentFromTop:picker];
}

/// 目录复制的兜底：某些来源（比如 iCloud 上还没下载完的文件夹）copyItemAtURL 会失败，
/// 这时自己递归建目录再逐个拷
static BOOL IPATFbCopyDirectory(NSURL *source, NSString *destination, NSError **error) {
    NSFileManager *fm = [NSFileManager defaultManager];
    if (![fm createDirectoryAtPath:destination withIntermediateDirectories:YES attributes:nil error:error]) {
        return NO;
    }
    // 安全作用域 / iCloud 的目录要经 NSFileCoordinator 协调后再枚举，
    // 否则没下载完的项会直接枚举失败
    __block NSArray<NSURL *> *items = nil;
    __block NSError *coordError = nil;
    NSFileCoordinator *coordinator = [[NSFileCoordinator alloc] initWithFilePresenter:nil];
    [coordinator coordinateReadingItemAtURL:source
                                    options:0
                                      error:&coordError
                                 byAccessor:^(NSURL *coordinatedURL) {
        items = [fm contentsOfDirectoryAtURL:coordinatedURL
                 includingPropertiesForKeys:@[NSURLIsDirectoryKey]
                                    options:0
                                      error:&coordError];
    }];
    if (!items) {
        if (error && coordError) *error = coordError;
        return NO;
    }

    BOOL ok = YES;
    for (NSURL *item in items) {
        NSNumber *isDirectory = nil;
        [item getResourceValue:&isDirectory forKey:NSURLIsDirectoryKey error:NULL];
        NSString *target = [destination stringByAppendingPathComponent:item.lastPathComponent];
        NSError *itemError = nil;
        if ([isDirectory boolValue]) {
            if (!IPATFbCopyDirectory(item, target, &itemError)) {
                ok = NO;
                if (error && !*error) *error = itemError;
            }
        } else if (![fm copyItemAtURL:item toURL:[NSURL fileURLWithPath:target] error:&itemError]) {
            ok = NO;
            if (error && !*error) *error = itemError;
        }
    }
    return ok;
}

#pragma mark - ZIP 解压

/// 大 zip（热更资源 4G 级别）直接走解压，别让用户在 PC 上先解开再导。
/// 支持 store / deflate（zlib 流式，条目再大也不进整块内存）、ZIP64、
/// Windows 压缩的 GBK 中文文件名；解压到临时目录成功后才挪进落地目录。

static uint16_t IPATFbZipU16(const uint8_t *p) {
    return (uint16_t)(p[0] | ((uint16_t)p[1] << 8));
}

static uint32_t IPATFbZipU32(const uint8_t *p) {
    return (uint32_t)p[0] | ((uint32_t)p[1] << 8) | ((uint32_t)p[2] << 16) | ((uint32_t)p[3] << 24);
}

static uint64_t IPATFbZipU64(const uint8_t *p) {
    return (uint64_t)IPATFbZipU32(p) | ((uint64_t)IPATFbZipU32(p + 4) << 32);
}

/// 文件名解码：打包工具一般会标 UTF-8；Windows 资源管理器压缩的中文包
/// 不带 UTF-8 标志，按 GB18030 解
static NSString *IPATFbZipDecodeName(const uint8_t *bytes, uint16_t length, uint16_t flags) {
    if (length == 0) return @"";
    NSData *data = [NSData dataWithBytes:bytes length:length];
    if (!(flags & 0x800)) {
        NSStringEncoding gbk = CFStringConvertEncodingToNSStringEncoding(kCFStringEncodingGB_18030_2000);
        NSString *decoded = [[NSString alloc] initWithData:data encoding:gbk];
        if (decoded) return decoded;
    }
    return [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding]
        ?: [[NSString alloc] initWithData:data encoding:NSISOLatin1StringEncoding]
        ?: @"";
}

/// 拒绝 zip 里的路径穿越（../、盘符、绝对路径）
static BOOL IPATFbZipSafePath(NSString *root, NSString *name, NSString **outPath) {
    NSMutableArray<NSString *> *parts = [NSMutableArray array];
    for (NSString *part in [name pathComponents]) {
        if (part.length == 0 || [part isEqualToString:@"."]) continue;
        if ([part isEqualToString:@".."]) return NO;
        if ([part containsString:@":"]) return NO;
        [parts addObject:part];
    }
    if (parts.count == 0) return NO;
    NSString *path = root;
    for (NSString *part in parts) path = [path stringByAppendingPathComponent:part];
    *outPath = path;
    return YES;
}

/// 单个条目的解压：method 0 直拷，method 8 zlib 流式 inflate
static BOOL IPATFbZipInflateEntry(FILE *fp, off_t dataOffset, uint16_t method,
                                  uint64_t compSize,
                                  NSString *outPath,
                                  void (^progress)(uint64_t added),
                                  NSError **error) {
    if (fseeko(fp, dataOffset, SEEK_SET) != 0) {
        if (error) *error = [NSError errorWithDomain:@"IPAToolFiles" code:1
                                         userInfo:@{NSLocalizedDescriptionKey: @"zip 内定位数据失败"}];
        return NO;
    }
    FILE *out = fopen(outPath.fileSystemRepresentation, "wb");
    if (!out) {
        if (error) *error = [NSError errorWithDomain:@"IPAToolFiles" code:2
                                         userInfo:@{NSLocalizedDescriptionKey:
                                                    [NSString stringWithFormat:@"写文件失败：%@",
                                                               outPath.lastPathComponent]}];
        return NO;
    }

    static const size_t kChunk = 256 * 1024;
    BOOL ok = NO;
    BOOL badWrite = NO;

    if (method == 0) {
        // store：直接落盘
        uint8_t *buf = malloc(kChunk);
        uint64_t remaining = compSize;
        while (remaining > 0) {
            size_t n = fread(buf, 1, remaining < kChunk ? (size_t)remaining : kChunk, fp);
            if (n == 0) break;
            if (fwrite(buf, 1, n, out) != n) { badWrite = YES; break; }
            progress(n);
            remaining -= n;
        }
        free(buf);
        ok = !badWrite && remaining == 0;
    } else {
        // deflate：raw inflate 流式解
        uint8_t *inBuf = malloc(kChunk);
        uint8_t *outBuf = malloc(kChunk);
        z_stream zs = {0};
        BOOL haveEnd = NO;
        if (inflateInit2(&zs, -MAX_WBITS) == Z_OK) {
            uint64_t remaining = compSize;
            for (;;) {
                if (zs.avail_in == 0 && remaining > 0) {
                    size_t n = fread(inBuf, 1, remaining < kChunk ? (size_t)remaining : kChunk, fp);
                    if (n == 0) break;
                    zs.next_in = inBuf;
                    zs.avail_in = (uInt)n;
                    remaining -= n;
                }
                zs.next_out = outBuf;
                zs.avail_out = (uInt)kChunk;
                int ret = inflate(&zs, Z_NO_FLUSH);
                uInt produced = kChunk - zs.avail_out;
                if (produced > 0) {
                    if (fwrite(outBuf, 1, produced, out) != produced) { badWrite = YES; break; }
                    progress(produced);
                }
                if (ret == Z_STREAM_END) { haveEnd = YES; break; }
                if (ret != Z_OK) break;                          // 数据损坏 / 不支持
                if (remaining == 0 && zs.avail_in == 0) break;   // 输入耗尽但流没结束
            }
            inflateEnd(&zs);
        }
        free(inBuf);
        free(outBuf);
        ok = !badWrite && haveEnd;
    }

    fclose(out);
    if (!ok) {
        [[NSFileManager defaultManager] removeItemAtPath:outPath error:NULL];
        if (error) {
            NSString *msg = badWrite ? @"写文件失败（沙盒空间不足？）"
                                     : @"zip 数据不完整或已损坏";
            *error = [NSError errorWithDomain:@"IPAToolFiles" code:3
                                  userInfo:@{NSLocalizedDescriptionKey:
                                             [NSString stringWithFormat:@"%@（%@）", msg,
                                                        outPath.lastPathComponent]}];
        }
    }
    return ok;
}

/// 解析中央目录的一个条目，pos 前移到下一个条目；ZIP64 的超限字段从 extra 里补
static BOOL IPATFbZipParseEntry(const uint8_t *cd, uint64_t cdSize, uint64_t *pos,
                                NSString **name, uint16_t *method, uint16_t *flags,
                                uint64_t *compSize, uint64_t *uncompSize,
                                uint64_t *localOffset, BOOL *isDirectory) {
    if (*pos + 46 > cdSize || IPATFbZipU32(cd + *pos) != 0x02014b50) return NO;
    const uint8_t *e = cd + *pos;
    *flags = IPATFbZipU16(e + 8);
    *method = IPATFbZipU16(e + 10);
    *compSize = IPATFbZipU32(e + 20);
    *uncompSize = IPATFbZipU32(e + 24);
    uint16_t nameLen = IPATFbZipU16(e + 28);
    uint16_t extraLen = IPATFbZipU16(e + 30);
    uint16_t commentLen = IPATFbZipU16(e + 32);
    uint32_t extAttr = IPATFbZipU32(e + 38);
    *localOffset = IPATFbZipU32(e + 42);
    if (*pos + 46 + (uint64_t)nameLen + extraLen + commentLen > cdSize) return NO;

    const uint8_t *extra = e + 46 + nameLen;
    uint16_t off = 0;
    while (off + 4 <= extraLen) {
        uint16_t id = IPATFbZipU16(extra + off);
        uint16_t size = IPATFbZipU16(extra + off + 2);
        if (off + 4 + (uint64_t)size > extraLen) break;
        if (id == 0x0001) {   // ZIP64
            const uint8_t *p = extra + off + 4;
            const uint8_t *end = extra + off + 4 + size;
            if (*uncompSize == 0xFFFFFFFFFFFFFFFFULL && p + 8 <= end) { *uncompSize = IPATFbZipU64(p); p += 8; }
            if (*compSize == 0xFFFFFFFFFFFFFFFFULL && p + 8 <= end) { *compSize = IPATFbZipU64(p); p += 8; }
            if (*localOffset == 0xFFFFFFFFFFFFFFFFULL && p + 8 <= end) { *localOffset = IPATFbZipU64(p); p += 8; }
        }
        off = (uint16_t)(off + 4 + size);
    }

    *name = IPATFbZipDecodeName(e + 46, nameLen, *flags);
    *isDirectory = [*name hasSuffix:@"/"] || (extAttr & 0x10) != 0;
    *pos += 46 + (uint64_t)nameLen + extraLen + commentLen;
    return YES;
}

/// 解开整个 zip 到 stagingDir；先扫一遍中央目录做空间预检，再逐条解
static BOOL IPATFbZipExtract(NSURL *zipURL, NSString *stagingDir,
                             NSInteger *outFiles, NSInteger *outDirs, uint64_t *outTotalBytes,
                             void (^progress)(uint64_t added), NSError **error) {
    NSFileManager *fm = [NSFileManager defaultManager];
    FILE *fp = fopen(zipURL.path.fileSystemRepresentation, "rb");
    if (!fp) {
        if (error) *error = [NSError errorWithDomain:@"IPAToolFiles" code:4
                                         userInfo:@{NSLocalizedDescriptionKey: @"打不开 zip 文件"}];
        return NO;
    }

    BOOL ok = NO;
    uint8_t *tail = NULL;
    uint8_t *cd = NULL;
    // 注意：ARC 下 goto 不能跨过 __strong 变量的初始化，所以 ObjC 指针
    // 一律先声明在这里，后面只赋值
    NSDictionary *fsAttr = nil;

    fseeko(fp, 0, SEEK_END);
    off_t fileSize = ftello(fp);

    // 1) 从尾部找 EOCD（0x06054b50）
    uint64_t tailLen = MIN((uint64_t)fileSize, 22 + 65535);
    tail = malloc(tailLen);
    fseeko(fp, (off_t)(fileSize - (off_t)tailLen), SEEK_SET);
    if (fread(tail, 1, tailLen, fp) != tailLen || tailLen < 22) {
        if (error) *error = [NSError errorWithDomain:@"IPAToolFiles" code:4
                                         userInfo:@{NSLocalizedDescriptionKey: @"读取 zip 结尾失败"}];
        goto done;
    }
    uint64_t eocdInTail = UINT64_MAX;
    for (uint64_t i = tailLen - 21; i-- > 0;) {
        if (IPATFbZipU32(tail + i) == 0x06054b50 &&
            i + 22 + (uint64_t)IPATFbZipU16(tail + i + 20) == tailLen) {
            eocdInTail = i;
            break;
        }
    }
    if (eocdInTail == UINT64_MAX) {
        if (error) *error = [NSError errorWithDomain:@"IPAToolFiles" code:5
                                         userInfo:@{NSLocalizedDescriptionKey: @"不是有效的 zip 文件"}];
        goto done;
    }
    uint64_t eocdOffset = (uint64_t)fileSize - tailLen + eocdInTail;
    uint64_t cdOffset = IPATFbZipU32(tail + eocdInTail + 16);
    uint64_t cdSize = IPATFbZipU32(tail + eocdInTail + 12);
    uint64_t entryCount = IPATFbZipU16(tail + eocdInTail + 10);

    // 2) ZIP64：EOCD 里的字段装不下时走 ZIP64 EOCD
    if (eocdOffset >= 20) {
        uint8_t locator[20];
        fseeko(fp, (off_t)(eocdOffset - 20), SEEK_SET);
        if (fread(locator, 1, 20, fp) == 20 && IPATFbZipU32(locator) == 0x07064b50) {
            uint8_t z64[56];
            fseeko(fp, (off_t)IPATFbZipU64(locator + 8), SEEK_SET);
            if (fread(z64, 1, 56, fp) == 56 && IPATFbZipU32(z64) == 0x06064b50) {
                entryCount = IPATFbZipU64(z64 + 32);
                cdSize = IPATFbZipU64(z64 + 40);
                cdOffset = IPATFbZipU64(z64 + 48);
            } else {
                if (error) *error = [NSError errorWithDomain:@"IPAToolFiles" code:5
                                                 userInfo:@{NSLocalizedDescriptionKey: @"ZIP64 目录损坏"}];
                goto done;
            }
        }
    }

    // 3) 读入中央目录
    if (cdSize == 0 || cdSize > (uint64_t)fileSize) {
        if (error) *error = [NSError errorWithDomain:@"IPAToolFiles" code:5
                                         userInfo:@{NSLocalizedDescriptionKey: @"zip 中央目录损坏"}];
        goto done;
    }
    cd = malloc((size_t)cdSize);
    fseeko(fp, (off_t)cdOffset, SEEK_SET);
    if (fread(cd, 1, (size_t)cdSize, fp) != cdSize) {
        if (error) *error = [NSError errorWithDomain:@"IPAToolFiles" code:4
                                         userInfo:@{NSLocalizedDescriptionKey: @"读取 zip 中央目录失败"}];
        goto done;
    }
    free(tail);
    tail = NULL;

    // 4) 第一遍：统计解压后的总体积，做空间预检
    uint64_t totalBytes = 0;
    for (uint64_t pos = 0, i = 0; i < entryCount && pos < cdSize; i++) {
        NSString *name = nil;
        uint16_t method = 0, flags = 0;
        BOOL isDir = NO;
        uint64_t compSize = 0, uncompSize = 0, localOffset = 0;
        if (!IPATFbZipParseEntry(cd, cdSize, &pos, &name, &method, &flags,
                                 &compSize, &uncompSize, &localOffset, &isDir)) break;
        totalBytes += uncompSize;
    }
    if (outTotalBytes) *outTotalBytes = totalBytes;
    fsAttr = [fm attributesOfFileSystemForPath:stagingDir error:NULL];
    uint64_t freeBytes = [fsAttr[NSFileSystemFreeSize] unsignedLongLongValue];
    if (freeBytes > 0 && totalBytes > freeBytes) {
        if (error) *error = [NSError errorWithDomain:@"IPAToolFiles" code:6
                                         userInfo:@{NSLocalizedDescriptionKey:
                                                    [NSString stringWithFormat:
                                                     @"沙盒空间不足：解压需要约 %.1f GB，剩余 %.1f GB",
                                                     totalBytes / 1073741824.0,
                                                     freeBytes / 1073741824.0]}];
        goto done;
    }

    // 5) 第二遍：逐条解压
    NSInteger files = 0, dirs = 0;
    for (uint64_t pos = 0, i = 0; i < entryCount && pos < cdSize; i++) {
        NSString *name = nil;
        uint16_t method = 0, flags = 0;
        BOOL isDir = NO;
        uint64_t compSize = 0, uncompSize = 0, localOffset = 0;
        if (!IPATFbZipParseEntry(cd, cdSize, &pos, &name, &method, &flags,
                                 &compSize, &uncompSize, &localOffset, &isDir)) {
            // 之前这里是静默 break，目录解出来了、文件全丢，表面看就是"导入成功
            // 但只有一个空文件夹"。改成显式报错，把进度说清楚
            if (error && !*error)
                *error = [NSError errorWithDomain:@"IPAToolFiles" code:5
                                       userInfo:@{NSLocalizedDescriptionKey:
                                                  [NSString stringWithFormat:
                                                   @"zip 中央目录第 %ld 条解析失败（共 %ld 条），文件可能不完整",
                                                   (long)(i + 1), (long)entryCount]}];
            goto done;
        }
        if (name.length == 0) continue;

        if (flags & 0x1) {
            if (error && !*error)
                *error = [NSError errorWithDomain:@"IPAToolFiles" code:7
                                       userInfo:@{NSLocalizedDescriptionKey:
                                                  [NSString stringWithFormat:@"不支持加密 zip（%@）", name]}];
            goto done;
        }
        if (method != 0 && method != 8) {
            if (error && !*error)
                *error = [NSError errorWithDomain:@"IPAToolFiles" code:7
                                       userInfo:@{NSLocalizedDescriptionKey:
                                                  [NSString stringWithFormat:@"不支持的压缩方式（%@）", name]}];
            goto done;
        }

        NSString *path = nil;
        if (!IPATFbZipSafePath(stagingDir, name, &path)) {
            IPATFbLog(@"跳过可疑路径：%@", name);
            continue;
        }

        if (isDir) {
            if (![fm fileExistsAtPath:path]) {
                if (![fm createDirectoryAtPath:path withIntermediateDirectories:YES attributes:nil error:error])
                    goto done;
            }
            dirs++;
            continue;
        }

        NSError *parentError = nil;
        if (![fm createDirectoryAtPath:[path stringByDeletingLastPathComponent]
           withIntermediateDirectories:YES attributes:nil error:&parentError]) {
            if (error && !*error) *error = parentError;
            goto done;
        }

        // 从 local header 拿真实的名字/extra 长度，跳到数据区
        uint8_t lh[30];
        fseeko(fp, (off_t)localOffset, SEEK_SET);
        if (fread(lh, 1, 30, fp) != 30 || IPATFbZipU32(lh) != 0x04034b50) {
            if (error && !*error)
                *error = [NSError errorWithDomain:@"IPAToolFiles" code:5
                                       userInfo:@{NSLocalizedDescriptionKey: @"zip 局部文件头损坏"}];
            goto done;
        }
        off_t dataOffset = (off_t)localOffset + 30 + IPATFbZipU16(lh + 26) + IPATFbZipU16(lh + 28);

        if (!IPATFbZipInflateEntry(fp, dataOffset, method, compSize, path, progress, error))
            goto done;
        files++;
    }

    if (outFiles) *outFiles = files;
    if (outDirs) *outDirs = dirs;
    ok = YES;

done:
    free(tail);
    free(cd);
    fclose(fp);
    return ok;
}

/// 导入 .zip：解压到同名 .ipatool-zip 临时目录，全部成功后再把顶层条目
/// 挪进落地目录（同名覆盖，中途失败不留半成品）。
/// extractedFiles 返回解出的文件数，overwrote 返回被覆盖掉的同名项数
- (BOOL)importZip:(NSURL *)url toDirectory:(NSString *)destination
            files:(NSInteger *)extractedFiles
        overwrote:(NSInteger *)overwrote
           landed:(NSMutableArray<NSString *> *)landed error:(NSError **)error {
    NSFileManager *fm = [NSFileManager defaultManager];

    NSString *base = [url.lastPathComponent stringByDeletingPathExtension];
    // 解压到 tmp 的工作目录：落地目录里不会出现正在解压的半成品
    NSString *workRoot = IPATFbImportWorkRoot();
    NSString *staging = [workRoot stringByAppendingPathComponent:
                         [NSString stringWithFormat:@"%@.ipatool-zip", base]];
    for (NSInteger i = 2; [fm fileExistsAtPath:staging]; i++) {
        staging = [workRoot stringByAppendingPathComponent:
                   [NSString stringWithFormat:@"%@-%ld.ipatool-zip", base, (long)i]];
    }
    if (![fm createDirectoryAtPath:staging withIntermediateDirectories:YES attributes:nil error:error]) {
        return NO;
    }

    NSString *zipName = url.lastPathComponent;
    IPATFbLog(@"解压 %@ -> 临时目录 %@", zipName, staging);
    __block uint64_t totalBytes = 0, doneBytes = 0, lastReport = 0;
    void (^progress)(uint64_t) = ^(uint64_t added) {
        doneBytes += added;
        if (doneBytes - lastReport >= 256ULL * 1024 * 1024) {   // 每 256MB 报一次进度
            lastReport = doneBytes;
            long percent = totalBytes > 0 ? (long)((double)doneBytes / (double)totalBytes * 100.0) : 0;
            dispatch_async(dispatch_get_main_queue(), ^{
                [self postStatus:[NSString stringWithFormat:@"解压 %@：%ld%%", zipName, percent]];
                self.importAlert.message =
                    [NSString stringWithFormat:@"解压 %@：%ld%%", zipName, percent];
            });
        }
    };

    NSInteger files = 0, dirs = 0;
    if (!IPATFbZipExtract(url, staging, &files, &dirs, &totalBytes, progress, error)) {
        [fm removeItemAtPath:staging error:NULL];
        return NO;
    }

    // 顶层条目挪进落地目录（同卷 move 是原子操作，重名直接覆盖）
    NSArray<NSURL *> *topLevel =
        [fm contentsOfDirectoryAtURL:[NSURL fileURLWithPath:staging]
          includingPropertiesForKeys:@[NSURLIsDirectoryKey]
                             options:0
                               error:error];
    if (!topLevel) {
        [fm removeItemAtPath:staging error:NULL];
        return NO;
    }
    for (NSURL *item in topLevel) {
        NSString *final = IPATFbImportPath(destination, item.lastPathComponent);
        if ([fm fileExistsAtPath:final]) {
            if (overwrote) (*overwrote)++;
            IPATFbLog(@"导入覆盖同名项：%@", final);
        }
        if (!IPATFbReplaceIntoPlace(item.path, final, error)) {
            [fm removeItemAtPath:staging error:NULL];
            return NO;
        }
        if (landed) [landed addObject:final];
    }
    [fm removeItemAtPath:staging error:NULL];   // 挪完应该只剩空壳，顺手清掉
    IPATFbLog(@"解压 %@：%ld 个文件、%ld 个目录（%.2f GB）",
              zipName, (long)files, (long)dirs, totalBytes / 1073741824.0);
    if (extractedFiles) *extractedFiles = files;
    return YES;
}

- (void)importURLs:(NSArray<NSURL *> *)urls {
    NSFileManager *fm = [NSFileManager defaultManager];
    NSString *destination = self.importDirectory.length ? self.importDirectory : IPATFbImportDirectory();
    IPATFbLog(@"导入落地目录：%@", destination);
    NSError *error = nil;
    if (![fm createDirectoryAtPath:destination
       withIntermediateDirectories:YES
                        attributes:nil
                             error:&error]) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [self finishImport:0 total:(NSInteger)urls.count folders:0 zips:0 extracted:0
                   overwritten:0 error:error];
        });
        return;
    }

    IPATFbCleanStagingLeftovers(destination);

    NSInteger copied = 0;
    NSInteger folders = 0;
    NSInteger zips = 0;
    NSInteger extractedFiles = 0;
    NSInteger overwritten = 0;
    NSMutableArray<NSString *> *landed = [NSMutableArray array];   // 本次落地的条目，事后复查用
    NSError *lastError = nil;
    for (NSURL *url in urls) {
        BOOL scoped = [url startAccessingSecurityScopedResource];

        NSNumber *isDirectory = nil;
        [url getResourceValue:&isDirectory forKey:NSURLIsDirectoryKey error:NULL];
        BOOL isDir = [isDirectory boolValue];

        NSError *copyError = nil;
        BOOL ok = NO;
        // .zip 走解压（热更资源动辄几个 G，整包拷一份没意义）；其余临时目录 + 原子 rename
        BOOL isZip = !isDir && [url.pathExtension.lowercaseString isEqualToString:@"zip"];
        if (isZip) {
            NSInteger extracted = 0;
            IPATFbLog(@"按 zip 解压：%@（%.2f GB）", url.lastPathComponent,
                      [[fm attributesOfItemAtPath:url.path error:NULL][NSFileSize]
                       unsignedLongLongValue] / 1073741824.0);
            dispatch_async(dispatch_get_main_queue(), ^{
                [self postStatus:[NSString stringWithFormat:@"开始解压 %@…", url.lastPathComponent]];
                self.importAlert.message =
                    [NSString stringWithFormat:@"解压 %@…", url.lastPathComponent];
            });
            NSInteger overwrote = 0;
            ok = [self importZip:url toDirectory:destination
                           files:&extracted overwrote:&overwrote
                          landed:landed error:&copyError];
            if (ok) {
                zips++;
                extractedFiles += extracted;
                overwritten += overwrote;
            }
        } else {
            NSString *target = IPATFbImportPath(destination, url.lastPathComponent);
            if ([fm fileExistsAtPath:target]) {
                overwritten++;
                IPATFbLog(@"导入覆盖同名项：%@", target);
            }
            ok = IPATFbCopyThenRename(url, target, isDir, &copyError);
            if (ok) {
                if (isDir) folders++;
                [landed addObject:target];
            }
        }

        if (ok) {
            copied++;
        } else {
            lastError = copyError;
        }
        if (scoped) [url stopAccessingSecurityScopedResource];

        // asCopy:YES 的回调 URL 是系统拷进 tmp 的副本，导入完就把
        // 这份副本删掉（4G 的 zip 不删要一直占着空间）
        if ([url.path hasPrefix:NSTemporaryDirectory()]) {
            [fm removeItemAtURL:url error:NULL];
        }
    }
    NSArray<NSString *> *watched = [landed copy];
    NSDate *landedAt = [NSDate date];
    dispatch_async(dispatch_get_main_queue(), ^{
        [self finishImport:copied total:(NSInteger)urls.count folders:folders
                      zips:zips extracted:extractedFiles overwritten:overwritten
                     error:lastError];
        if (copied > 0) {
            [self watchImportedPaths:watched since:landedAt];
            [self lockImportedPaths:watched];   // 挡住热更线程继续往里写
        }
    });
}

/// 落地之后复查：等几秒再看这些条目有没有被改动过。
/// 热更没停时游戏可能在我们换完之后继续往里写（下载/解压），那导入的内容
/// 就有被盖回去的风险，这里明确告诉用户「还在被写」，让他决定要不要重来 / 杀进程。
- (void)watchImportedPaths:(NSArray<NSString *> *)paths since:(NSDate *)since {
    if (paths.count == 0) return;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(5.0 * NSEC_PER_SEC)),
                   dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_BACKGROUND, 0), ^{
        NSMutableArray<NSString *> *changed = [NSMutableArray array];
        for (NSString *path in paths) {
            if (IPATFbModifiedAfter(path, since, 50000)) [changed addObject:path.lastPathComponent];
        }
        if (changed.count == 0) return;
        IPATFbLog(@"导入后仍在被写入：%@", changed);
        dispatch_async(dispatch_get_main_queue(), ^{
            [self postStatus:[NSString stringWithFormat:
                              @"注意：%@ 在导入后仍被游戏写入（热更可能还在跑），"
                              @"建议杀掉游戏进程冷启动，否则可能被它盖回去",
                              [changed componentsJoinedByString:@"、"]]];
        });
    });
}

/// 导入落地之后把内容锁成只读：热更线程没停的话会继续往资源目录写，
/// 写不进来就不会把我们刚放进去的内容盖回去（相当于给它踩一脚刹车）。
/// 锁了哪些路径记进 NSUserDefaults，下次启动（或下次覆盖前）恢复成可写
- (void)lockImportedPaths:(NSArray<NSString *> *)paths {
    if (paths.count == 0 || !IPATFbLockAfterImport()) return;
    IPATFbRememberLockedPaths(paths);
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_BACKGROUND, 0), ^{
        for (NSString *path in paths) IPATFbSetTreeWritable(path, NO);
        IPATFbLog(@"导入内容已锁成只读，热更写不进来：%@", paths);
    });
}

/// 把上次导入锁成只读的目录恢复成可写：不恢复的话游戏以后也没法正常更新了
- (void)restoreWritableLocks {
    NSArray<NSString *> *paths = IPATFbLockedPaths();
    if (paths.count == 0) return;
    NSUserDefaults *ud = [NSUserDefaults standardUserDefaults];
    [ud removeObjectForKey:IPATFbLockedPathsKey];
    [ud synchronize];
    IPATFbLog(@"恢复上次锁定的目录为可写：%@", paths);
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_BACKGROUND, 0), ^{
        NSFileManager *fm = [NSFileManager defaultManager];
        for (NSString *path in paths) {
            if ([fm fileExistsAtPath:path]) IPATFbSetTreeWritable(path, YES);
        }
    });
}

- (void)finishImport:(NSInteger)copied
               total:(NSInteger)total
             folders:(NSInteger)folders
                zips:(NSInteger)zips
           extracted:(NSInteger)extractedFiles
         overwritten:(NSInteger)overwritten
               error:(NSError *)error {
    IPATFbSetOverlayVisible(YES);
    // 收起导入进度弹窗后再显示结果（都在主线程）
    UIAlertController *alert = self.importAlert;
    self.importAlert = nil;
    void (^body)(void) = ^{
    NSString *where = IPATFbDisplayPath(self.importDirectory.length
                                        ? self.importDirectory
                                        : IPATFbImportDirectory());
    // 覆盖了多少个同名项，明确告诉用户旧内容是被顶掉的，不是多出一份
    NSString *over = overwritten > 0
        ? [NSString stringWithFormat:@"，覆盖 %ld 个同名项", (long)overwritten]
        : @"";
    if (copied == 0 && error) {
        [self postStatus:[NSString stringWithFormat:@"导入失败：%@", error.localizedDescription]];
    } else if (copied < total) {
        [self postStatus:[NSString stringWithFormat:@"已导入 %ld/%ld 项到 %@%@",
                                                    (long)copied, (long)total, where, over]];
    } else if (zips > 0) {
        [self postStatus:[NSString stringWithFormat:@"已导入 %ld 项（解压 %ld 个文件）到 %@%@",
                                                    (long)copied, (long)extractedFiles, where, over]];
    } else if (folders > 0) {
        [self postStatus:[NSString stringWithFormat:@"已导入 %ld 项（含 %ld 个文件夹）到 %@%@",
                                                    (long)copied, (long)folders, where, over]];
    } else {
        [self postStatus:[NSString stringWithFormat:@"已导入 %ld 项到 %@%@", (long)copied, where, over]];
    }
    IPATFbLog(@"导入完成：%ld/%ld（文件夹 %ld，压缩包 %ld，覆盖 %ld）-> %@",
              (long)copied, (long)total, (long)folders, (long)zips, (long)overwritten, where);

    // 成功落地后给个「冷启动」的出口：内存里已经加载的旧资源不会因为换目录就变，
    // 只有冷启动才会按新内容重新加载；同时热更没停时进程一退就不会再往里写，
    // 免得把我们导进去的内容又盖回去
    if (copied > 0) {
        UIAlertController *done =
            [UIAlertController alertControllerWithTitle:@"导入完成"
                                                message:[NSString stringWithFormat:
                                                         @"内容已覆盖到 %@%@。\n\n"
                                                         @"已把导入的内容锁成只读，热更线程"
                                                         @"写不进来（重开游戏会自动恢复可写）；"
                                                         @"进程里已加载的旧资源不会跟着换，"
                                                         @"杀掉游戏冷启动才会按新内容重新加载。",
                                                         where, over]
                                         preferredStyle:UIAlertControllerStyleAlert];
        // 只留「退出游戏」：导入完就是要冷启动按新资源加载，不给「知道了」的退路，
        // 免得留在旧进程里继续跑，白导一趟（不点就一直停在这个框上）
        [done addAction:[UIAlertAction actionWithTitle:@"退出游戏"
                                                 style:UIAlertActionStyleDestructive
                                               handler:^(UIAlertAction *action) {
            IPATFbLog(@"用户选择退出游戏进程（冷启动后按新资源加载）");
            exit(0);
        }]];
        [self presentFromTop:done];
    }
    };
    if (alert.view.window) {
        [alert dismissViewControllerAnimated:YES completion:body];
    } else {
        body();
    }
}

#pragma mark UIDocumentPickerDelegate

- (void)documentPicker:(UIDocumentPickerViewController *)controller
        didPickDocumentsAtURLs:(NSArray<NSURL *> *)urls {
    IPATFbLog(@"选择器回调：%lu 项 -> %@", (unsigned long)urls.count, urls);
    if (urls.count == 0) {
        [self postStatus:@"没有选中任何内容"];
        return;
    }
    if (self.purpose == IPATFbPickerExport) {
        IPATFbSetOverlayVisible(YES);   // 「文件」App 收起来了，悬浮窗放回来
        [self postStatus:[NSString stringWithFormat:@"已导出 zip（%ld 项）", (long)self.exportItemCount]];
        IPATFbLog(@"导出完成：zip（%ld 项）", (long)self.exportItemCount);
        // 系统已把 zip 拷到用户选的位置，临时文件清掉（就算还没拷完，
        // 下次导出开头也会按前缀统一清理，不会堆积）
        if (self.currentExportZip) {
            [[NSFileManager defaultManager] removeItemAtPath:self.currentExportZip error:NULL];
        }
        self.currentExportZip = nil;
        return;
    }
    // 拷贝放到后台线程：大文件夹 / iCloud 下载可能很慢，别卡主线程。
    // 进度直接显示成弹窗——导入期间悬浮面板是藏着的，状态行看不见
    UIAlertController *progress =
        [UIAlertController alertControllerWithTitle:@"正在导入…"
                                            message:@"请稍候（大文件要等一会儿）"
                                     preferredStyle:UIAlertControllerStyleAlert];
    self.importAlert = progress;
    // 同步弹：接下来导入是在后台跑的，进度框必须已经挂上窗口，
    // 否则小文件瞬间导完时「导入完成」会排在它前面弹出来
    [self presentNow:progress];
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        [self importURLs:urls];
    });
}

- (void)documentPickerWasCancelled:(UIDocumentPickerViewController *)controller {
    if (self.purpose == IPATFbPickerImport) {
        IPATFbSetOverlayVisible(YES);   // 导出模式下悬浮窗由浏览器负责恢复
    }
    if (self.currentExportZip) {
        [[NSFileManager defaultManager] removeItemAtPath:self.currentExportZip error:NULL];
        self.currentExportZip = nil;
    }
    [self postStatus:@"已取消"];
}

@end

#pragma mark - 入口

__attribute__((constructor)) static void IPATFileBridgeInit(void) {
    // 等主队列起来再碰 UIKit
    dispatch_async(dispatch_get_main_queue(), ^{
        [[IPATFbBridge shared] start];
    });
}
