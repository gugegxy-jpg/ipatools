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
//    3. 导入走系统的 UIDocumentPickerViewController（「文件」App）：iOS 不允许文件和文件夹
//       在同一批里混选（混着给 item + folder 类型时文件夹会点不动），
//       所以拆成「导入文件」「导入文件夹」两个入口，两者都先在沙盒浏览器里挑落地目录。
//    4. 弹系统界面之前先发 IPATControlVisibility 让悬浮窗躲开：
//       悬浮窗的 windowLevel 比 Alert 还高，不躲开会盖在文档选择器上面。
//    5. 导入的默认落地目录取 Info.plist 的 ImportDir（相对沙盒），界面里挑完只用于本次。
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
static NSString *const IPATFbActionImportTo = @"files.importTo";
static NSString *const IPATFbActionImportFolders = @"files.importFolders";

/// 浏览器的用途：导出时勾选内容，或给导入挑一个落地文件夹
typedef NS_ENUM(NSInteger, IPATFbBrowserMode) {
    IPATFbBrowserModeExport = 0,     // 勾选文件 / 文件夹后导出
    IPATFbBrowserModeImportTarget,   // 选一个文件夹作为导入落地目录，接着导入文件
    IPATFbBrowserModeImportTargetFolders,  // 同上，接着导入文件夹
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
        self.navigationItem.prompt = @"进入文件夹后点右上角「导入到这里」";
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

    // 根目录没有返回按钮，自己给一个关闭入口（子目录由导航栏自动提供返回）
    if ([self.directory isEqualToString:self.rootDirectory]) {
        self.navigationItem.leftBarButtonItem =
            [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemClose
                                                          target:self
                                                          action:@selector(handleClose)];
    }
    [self reloadEntries];
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

    cell.textLabel.text = entry[@"name"];
    cell.textLabel.font = [UIFont systemFontOfSize:15.0];
    cell.detailTextLabel.text = isDir ? @"文件夹" : [self sizeDescriptionForPath:path];
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
        // 注入即可用，没有「关掉」的场景：面板不画总开关（真要关用 Info.plist 的 Enabled）
        IPATRegMasterHidden: @YES,
        IPATRegEnabled: @(IPATFbEnabled()),
        // 面板只留动作行：导入的落地目录在浏览器里挑，默认取 ImportDir
        // （Info.plist / --files-import-dir，默认 Documents）
        IPATRegRows: @[
            @{IPATRowKey: IPATFbActionBrowse,
              IPATRowTitle: @"浏览并导出文件",
              IPATRowKind: IPATRowKindAction,
              IPATRowNote: @"选文件夹或文件，导出到「文件」App"},
            @{IPATRowKey: IPATFbActionImportTo,
              IPATRowTitle: @"导入文件",
              IPATRowKind: IPATRowKindAction,
              IPATRowNote: [NSString stringWithFormat:@"挑落地目录，默认 %@",
                                                      IPATFbImportRelative()]},
            @{IPATRowKey: IPATFbActionImportFolders,
              IPATRowTitle: @"导入文件夹",
              IPATRowKind: IPATRowKindAction,
              IPATRowNote: @"连里面的内容一起导入"},
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
    } else if ([key isEqualToString:IPATFbActionImportFolders]) {
        [self openBrowserWithMode:IPATFbBrowserModeImportTargetFolders];
    }
}

#pragma mark 浏览器

- (void)openBrowserWithMode:(IPATFbBrowserMode)mode {
    if (!IPATFbEnabled()) {
        [self postStatus:@"功能已关闭"];
        return;
    }
    // 挑落地目录时直接从默认导入目录开始，省得每次从沙盒根一层层点进去
    NSString *root = IPATFbBrowseRoot();
    if (mode != IPATFbBrowserModeExport) {
        NSString *import = IPATFbImportDirectory();
        BOOL importIsDir = NO;
        if ([[NSFileManager defaultManager] fileExistsAtPath:import isDirectory:&importIsDir]
            && importIsDir) {
            root = import;
        }
    }
    BOOL isDir = NO;
    if (![[NSFileManager defaultManager] fileExistsAtPath:root isDirectory:&isDir] || !isDir) {
        [self postStatus:@"浏览根目录不存在"];
        return;
    }

    IPATFbBrowserController *browser =
        [[IPATFbBrowserController alloc] initWithDirectory:root root:root mode:mode];
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
                [weakSelf openImporterToDirectory:path
                                 selectingFolders:(mode == IPATFbBrowserModeImportTargetFolders)];
            });
        }];
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

/// directory 传 nil 表示用面板上选的预设目录
- (void)openImporterToDirectory:(NSString *)directory selectingFolders:(BOOL)foldersOnly {
    if (!IPATFbEnabled()) {
        [self postStatus:@"功能已关闭"];
        return;
    }

    self.purpose = IPATFbPickerImport;
    self.importDirectory = directory.length ? [directory copy] : [IPATFbImportDirectory() copy];
    // 文件和文件夹不能在同一次「文件」App 里混选（混着给类型时文件夹会点不动），
    // 所以按用途分开弹：只给 UTTypeFolder 时文件夹才可选
    UIDocumentPickerViewController *picker = nil;
    if (@available(iOS 14.0, *)) {
        NSArray<UTType *> *types = foldersOnly ? @[UTTypeFolder] : @[UTTypeItem];
        // asCopy:YES 选文件夹有坑：点「打开」后系统要整拷到临时目录，
        // iCloud / 第三方提供方会一直转圈、永不回调。文件夹改 asCopy:NO
        // （回调立即返回安全作用域 URL，拷贝由 importURLs 自己完成）；
        // 文件保持 asCopy:YES，省掉安全作用域访问。
        picker = [[UIDocumentPickerViewController alloc] initForOpeningContentTypes:types
                                                                            asCopy:!foldersOnly];
    } else {
        NSArray<NSString *> *types = foldersOnly ? @[@"public.folder"] : @[@"public.item"];
        picker = [[UIDocumentPickerViewController alloc] initWithDocumentTypes:types
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
    NSFileCoordinator *coordinator = [[NSFileCoordinator alloc] initWithFilePresenter:nil];
    [coordinator coordinateReadingItemAtURL:source
                                    options:0
                                      error:error
                                 byAccessor:^(NSURL *coordinatedURL) {
        items = [fm contentsOfDirectoryAtURL:coordinatedURL
                 includingPropertiesForKeys:@[NSURLIsDirectoryKey]
                                    options:0
                                      error:error];
    }];
    if (!items) return NO;

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

- (void)importURLs:(NSArray<NSURL *> *)urls {
    NSFileManager *fm = [NSFileManager defaultManager];
    NSString *destination = self.importDirectory.length ? self.importDirectory : IPATFbImportDirectory();
    NSError *error = nil;
    if (![fm createDirectoryAtPath:destination
       withIntermediateDirectories:YES
                        attributes:nil
                             error:&error]) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [self finishImport:0 total:(NSInteger)urls.count folders:0 error:error];
        });
        return;
    }

    NSInteger copied = 0;
    NSInteger folders = 0;
    NSError *lastError = nil;
    for (NSURL *url in urls) {
        BOOL scoped = [url startAccessingSecurityScopedResource];
        NSString *target = IPATFbUniquePath(destination, url.lastPathComponent);

        NSNumber *isDirectory = nil;
        [url getResourceValue:&isDirectory forKey:NSURLIsDirectoryKey error:NULL];

        NSError *copyError = nil;
        BOOL ok = NO;
        if ([isDirectory boolValue]) {
            // 文件夹：先让系统整拷，不行再自己递归
            ok = [fm copyItemAtURL:url toURL:[NSURL fileURLWithPath:target] error:&copyError];
            if (!ok) {
                copyError = nil;
                ok = IPATFbCopyDirectory(url, target, &copyError);
            }
            if (ok) folders++;
        } else {
            ok = [fm copyItemAtURL:url toURL:[NSURL fileURLWithPath:target] error:&copyError];
        }

        if (ok) {
            copied++;
        } else {
            lastError = copyError;
        }
        if (scoped) [url stopAccessingSecurityScopedResource];
    }
    dispatch_async(dispatch_get_main_queue(), ^{
        [self finishImport:copied total:(NSInteger)urls.count folders:folders error:lastError];
    });
}

- (void)finishImport:(NSInteger)copied
               total:(NSInteger)total
             folders:(NSInteger)folders
               error:(NSError *)error {
    IPATFbSetOverlayVisible(YES);
    NSString *where = IPATFbDisplayPath(self.importDirectory.length
                                        ? self.importDirectory
                                        : IPATFbImportDirectory());
    if (copied == 0 && error) {
        [self postStatus:[NSString stringWithFormat:@"导入失败：%@", error.localizedDescription]];
    } else if (copied < total) {
        [self postStatus:[NSString stringWithFormat:@"已导入 %ld/%ld 项到 %@",
                                                    (long)copied, (long)total, where]];
    } else if (folders > 0) {
        [self postStatus:[NSString stringWithFormat:@"已导入 %ld 项（含 %ld 个文件夹）到 %@",
                                                    (long)copied, (long)folders, where]];
    } else {
        [self postStatus:[NSString stringWithFormat:@"已导入 %ld 项到 %@", (long)copied, where]];
    }
    IPATFbLog(@"导入完成：%ld/%ld（文件夹 %ld）-> %@",
              (long)copied, (long)total, (long)folders, where);
}

#pragma mark UIDocumentPickerDelegate

- (void)documentPicker:(UIDocumentPickerViewController *)controller
        didPickDocumentsAtURLs:(NSArray<NSURL *> *)urls {
    if (self.purpose == IPATFbPickerExport) {
        [self postStatus:[NSString stringWithFormat:@"已导出 %lu 项", (unsigned long)urls.count]];
        IPATFbLog(@"导出完成：%lu 项", (unsigned long)urls.count);
        return;
    }
    // 拷贝放到后台线程：大文件夹 / iCloud 下载可能很慢，别卡主线程
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        [self importURLs:urls];
    });
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
