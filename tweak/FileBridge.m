//
//  FileBridge.m
//  ipatool 注入用 dylib：浏览沙盒里的游戏热更文件，导出到「文件」App / 从「文件」App 导入。
//
//  设计要点：
//    1. 平时不占资源：只有用户在悬浮面板上点「动作行」时才干活，没有常驻循环。
//    2. 浏览界面用自带的 UITableViewController：
//         点目录 = 进入；点文件 = 勾选；右上角「导出」= 导出勾选的文件，
//         什么都没勾选就导出当前文件夹本身。
//       这样「手动选择导出哪个文件夹或文件」用同一个界面就能满足，
//       也避免连续弹 UIAlertController 带来的 present 时序问题。
//    3. 导入走系统的 UIDocumentPickerViewController（「文件」App），支持多选文件 / 文件夹。
//    4. 弹系统界面之前先发 IPATControlVisibility 让悬浮窗躲开：
//       悬浮窗的 windowLevel 比 Alert 还高，不躲开会盖在文档选择器上面。
//    5. 导入落地目录可以在面板上改（写进 NSUserDefaults），优先级高于 Info.plist。
//
//  Info.plist（ipatool --files 会自动写入 IPAToolFiles）：
//    Enabled(bool)    默认 YES；NO 表示面板上的动作行点了只提示「功能已关闭」
//    Root(string)     浏览根目录，相对沙盒，默认空 = 沙盒根
//    ImportDir(string) 导入落地目录，相对沙盒，默认 Documents
//

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>
#import "IPATControlShared.h"

#define IPATFbLog(fmt, ...) NSLog(@"[ipatool-files] " fmt, ##__VA_ARGS__)

/// 动作行的标识（只是本 dylib 内部的字符串，不写 NSUserDefaults）
static NSString *const IPATFbActionBrowse = @"files.browse";
static NSString *const IPATFbActionImport = @"files.import";

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

static BOOL IPATFbEnabled(void) {
    id stored = IPATFbStored(IPATKeyFilesEnabled);
    if (stored) return [stored boolValue];
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

/// 同目录下不覆盖已有文件的重名处理
static NSString *IPATFbUniquePath(NSString *directory, NSString *name) {
    NSFileManager *fm = [NSFileManager defaultManager];
    NSString *candidate = [directory stringByAppendingPathComponent:name];
    if (![fm fileExistsAtPath:candidate]) return candidate;

    NSString *base = [name stringByDeletingPathExtension];
    NSString *ext = [name pathExtension];
    for (NSInteger i = 2; i < 10000; i++) {
        NSString *variant = ext.length
            ? [NSString stringWithFormat:@"%@-%ld.%@", base, (long)i, ext]
            : [NSString stringWithFormat:@"%@-%ld", base, (long)i];
        candidate = [directory stringByAppendingPathComponent:variant];
        if (![fm fileExistsAtPath:candidate]) return candidate;
    }
    return [directory stringByAppendingPathComponent:[NSUUID UUID].UUIDString];
}

#pragma mark - 文件浏览器

@interface IPATFbBrowserController : UITableViewController

@property (nonatomic, copy) NSString *directory;
@property (nonatomic, copy) NSString *rootDirectory;
@property (nonatomic, strong) NSArray<NSDictionary *> *entries;
@property (nonatomic, strong) NSMutableSet<NSString *> *selectedPaths;

/// 界面被关掉时回调（用来恢复悬浮窗）
@property (nonatomic, copy) void (^onDismiss)(void);
/// 用户点了「导出」，参数是要导出的绝对路径（文件或文件夹）
@property (nonatomic, copy) void (^onExport)(NSArray<NSString *> *paths);

@end

@implementation IPATFbBrowserController

- (instancetype)initWithDirectory:(NSString *)directory root:(NSString *)root {
    if ((self = [super initWithStyle:UITableViewStylePlain])) {
        _directory = [directory copy];
        _rootDirectory = [root copy];
        _selectedPaths = [NSMutableSet set];
        _entries = @[];
    }
    return self;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.tableView.rowHeight = 50.0;
    self.navigationItem.prompt = @"点目录进入 · 点文件勾选 · 右上角导出";
    self.navigationItem.rightBarButtonItem =
        [[UIBarButtonItem alloc] initWithTitle:@"导出"
                                        style:UIBarButtonItemStyleDone
                                       target:self
                                       action:@selector(handleExport)];
    // 根目录没有返回按钮，自己给一个关闭入口（子目录由导航栏自动提供返回）
    if ([self.directory isEqualToString:self.rootDirectory]) {
        self.navigationItem.leftBarButtonItem =
            [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemClose
                                                          target:self
                                                          action:@selector(handleClose)];
    }
    [self reloadEntries];
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
    for (NSString *name in [names sortedArrayUsingSelector:@selector(localizedStandardCompare:)]) {
        if ([name hasPrefix:@"."]) continue;  // 跳过隐藏项，沙盒里大多是系统文件
        NSString *path = [self.directory stringByAppendingPathComponent:name];
        BOOL isDir = NO;
        if (![fm fileExistsAtPath:path isDirectory:&isDir]) continue;
        [items addObject:@{@"name": name, @"path": path, @"dir": @(isDir)}];
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

    cell.textLabel.text = entry[@"name"];
    cell.textLabel.font = [UIFont systemFontOfSize:15.0];
    cell.detailTextLabel.text = isDir ? @"文件夹" : [self sizeDescriptionForPath:path];
    if (isDir) {
        cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
    } else {
        cell.accessoryType = [self.selectedPaths containsObject:path]
            ? UITableViewCellAccessoryCheckmark
            : UITableViewCellAccessoryNone;
    }
    return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    NSDictionary *entry = self.entries[(NSUInteger)indexPath.row];
    NSString *path = entry[@"path"];

    if ([entry[@"dir"] boolValue]) {
        IPATFbBrowserController *child =
            [[IPATFbBrowserController alloc] initWithDirectory:path root:self.rootDirectory];
        [self.navigationController pushViewController:child animated:YES];
        return;
    }

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
    [self registerWithPanel];
    IPATFbLog(@"文件导入导出已就绪（导入目录：%@）", IPATFbImportRelative());
}

#pragma mark 面板注册

- (void)registerWithPanel {
    NSDictionary *reg = @{
        IPATRegId: IPATFeatureFiles,
        IPATRegTitle: @"文件导入导出",
        IPATRegDetail: @"导出 / 导入游戏热更资源",
        IPATRegMasterKey: IPATKeyFilesEnabled,
        IPATRegEnabled: @(IPATFbEnabled()),
        IPATRegRows: @[
            @{IPATRowKey: IPATKeyFilesImportDir,
              IPATRowTitle: @"导入到",
              IPATRowKind: IPATRowKindSegment,
              IPATRowOptions: @[@"Documents", @"Library/Caches", @"Library/Application Support"],
              IPATRowValues: @[@"Documents", @"Library/Caches", @"Library/Application Support"],
              IPATRowValue: IPATFbImportRelative()},
            @{IPATRowKey: IPATFbActionBrowse,
              IPATRowTitle: @"浏览并导出文件",
              IPATRowKind: IPATRowKindAction,
              IPATRowNote: @"选文件夹或文件，导出到「文件」App"},
            @{IPATRowKey: IPATFbActionImport,
              IPATRowTitle: @"从「文件」App 导入",
              IPATRowKind: IPATRowKindAction,
              IPATRowNote: @"支持多选文件 / 文件夹，落到上面的目录"},
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
        [self openBrowser];
    } else if ([key isEqualToString:IPATFbActionImport]) {
        [self openImporter];
    }
}

#pragma mark 浏览器

- (void)openBrowser {
    if (!IPATFbEnabled()) {
        [self postStatus:@"功能已关闭"];
        return;
    }
    NSString *root = IPATFbBrowseRoot();
    BOOL isDir = NO;
    if (![[NSFileManager defaultManager] fileExistsAtPath:root isDirectory:&isDir] || !isDir) {
        [self postStatus:@"浏览根目录不存在"];
        return;
    }

    IPATFbBrowserController *browser =
        [[IPATFbBrowserController alloc] initWithDirectory:root root:root];
    __weak typeof(self) weakSelf = self;
    __weak IPATFbBrowserController *weakBrowser = browser;
    browser.onDismiss = ^{
        IPATFbSetOverlayVisible(YES);
        [weakSelf postStatus:nil];
    };
    browser.onExport = ^(NSArray<NSString *> *paths) {
        [weakSelf exportPaths:paths from:weakBrowser];
    };

    UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:browser];
    nav.modalPresentationStyle = UIModalPresentationFullScreen;
    IPATFbSetOverlayVisible(NO);
    [self presentFromTop:nav];
}

- (void)presentFromTop:(UIViewController *)controller {
    UIViewController *top = IPATFbTopViewController();
    if (!top) {
        IPATFbSetOverlayVisible(YES);
        IPATFbLog(@"没有可用的控制器来弹窗");
        return;
    }
    [top presentViewController:controller animated:YES completion:nil];
}

#pragma mark 导出

- (void)exportPaths:(NSArray<NSString *> *)paths from:(UIViewController *)presenter {
    NSMutableArray<NSURL *> *urls = [NSMutableArray array];
    for (NSString *path in paths) {
        if ([[NSFileManager defaultManager] fileExistsAtPath:path]) {
            [urls addObject:[NSURL fileURLWithPath:path]];
        }
    }
    if (urls.count == 0) {
        [self postStatus:@"没有可导出的内容"];
        return;
    }

    self.purpose = IPATFbPickerExport;
    // asCopy:YES —— 导出的是副本，沙盒里的原文件留着不动
    UIDocumentPickerViewController *picker =
        [[UIDocumentPickerViewController alloc] initForExportingURLs:urls asCopy:YES];
    picker.delegate = self;
    IPATFbLog(@"准备导出 %lu 项", (unsigned long)urls.count);
    [presenter presentViewController:picker animated:YES completion:nil];
}

#pragma mark 导入

- (void)openImporter {
    if (!IPATFbEnabled()) {
        [self postStatus:@"功能已关闭"];
        return;
    }

    self.purpose = IPATFbPickerImport;
    UIDocumentPickerViewController *picker = nil;
    if (@available(iOS 14.0, *)) {
        // asCopy:YES —— 系统先复制到临时目录，省掉安全作用域访问的坑
        picker = [[UIDocumentPickerViewController alloc] initForOpeningContentTypes:@[UTTypeItem, UTTypeFolder]
                                                                           asCopy:YES];
    } else {
        picker = [[UIDocumentPickerViewController alloc] initWithDocumentTypes:@[@"public.item", @"public.folder"]
                                                                      inMode:UIDocumentPickerModeImport];
    }
    picker.allowsMultipleSelection = YES;
    picker.delegate = self;
    IPATFbSetOverlayVisible(NO);
    [self presentFromTop:picker];
}

- (void)importURLs:(NSArray<NSURL *> *)urls {
    NSFileManager *fm = [NSFileManager defaultManager];
    NSString *destination = IPATFbImportDirectory();
    NSError *error = nil;
    if (![fm createDirectoryAtPath:destination
       withIntermediateDirectories:YES
                        attributes:nil
                             error:&error]) {
        [self finishImport:0 total:(NSInteger)urls.count error:error];
        return;
    }

    NSInteger copied = 0;
    NSError *lastError = nil;
    for (NSURL *url in urls) {
        BOOL scoped = [url startAccessingSecurityScopedResource];
        NSString *target = IPATFbUniquePath(destination, url.lastPathComponent);
        NSError *copyError = nil;
        if ([fm copyItemAtURL:url toURL:[NSURL fileURLWithPath:target] error:&copyError]) {
            copied++;
        } else {
            lastError = copyError;
        }
        if (scoped) [url stopAccessingSecurityScopedResource];
    }
    [self finishImport:copied total:(NSInteger)urls.count error:lastError];
}

- (void)finishImport:(NSInteger)copied total:(NSInteger)total error:(NSError *)error {
    IPATFbSetOverlayVisible(YES);
    if (copied == 0 && error) {
        [self postStatus:[NSString stringWithFormat:@"导入失败：%@", error.localizedDescription]];
    } else if (copied < total) {
        [self postStatus:[NSString stringWithFormat:@"已导入 %ld/%ld 项",
                                                    (long)copied, (long)total]];
    } else {
        [self postStatus:[NSString stringWithFormat:@"已导入 %ld 项到 %@",
                                                    (long)copied, IPATFbImportRelative()]];
    }
    IPATFbLog(@"导入完成：%ld/%ld -> %@", (long)copied, (long)total, IPATFbImportRelative());
}

#pragma mark UIDocumentPickerDelegate

- (void)documentPicker:(UIDocumentPickerViewController *)controller
        didPickDocumentsAtURLs:(NSArray<NSURL *> *)urls {
    if (self.purpose == IPATFbPickerExport) {
        [self postStatus:[NSString stringWithFormat:@"已导出 %lu 项", (unsigned long)urls.count]];
        IPATFbLog(@"导出完成：%lu 项", (unsigned long)urls.count);
        return;
    }
    [self importURLs:urls];
}

- (void)documentPickerWasCancelled:(UIDocumentPickerViewController *)controller {
    if (self.purpose == IPATFbPickerImport) {
        IPATFbSetOverlayVisible(YES);   // 导出模式下悬浮窗由浏览器负责恢复
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
