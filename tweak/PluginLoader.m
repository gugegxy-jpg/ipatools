//
//  PluginLoader.m
//  运行时插件加载器（功能 id: plugins）
//
//  解决的问题：改一次 dylib 就要重新打包 / 签名 / 装一次，调试太慢。
//  这个插件注入一次之后，之后想试的插件只要丢进 App 沙盒，就能在 App 里
//  直接 dlopen 起来，不用再碰 IPA。
//
//  iOS 上 dlopen 的三条硬约束（不是这个插件的限制，是系统的）：
//    1. 插件 dylib 必须有效签名，而且要和主 App 同一个 Team ID
//       （iOS 的 library validation）。用 ipatool 重签 App 的那把证书签插件就行：
//           ipatool signdylib plugin.dylib --identity "Apple Development: xxx"
//       ad-hoc 签名的 App 基本加载不了任何 dylib（ad-hoc 没有 Team ID）。
//    2. 必须是 iOS 架构、和 App 同一个 slice（模拟器编的要装在模拟器上）。
//    3. dlclose 在 iOS 上通常不会真正卸载镜像，改完插件要重启 App 才干净；
//       插件的 __DATA,__interpose 也只对 dlopen 之后新绑定的调用生效。
//
//  插件放进 App 沙盒的两条路：
//    - 面板里的「文件导入导出」（--files）从「文件」App 导到 Documents
//    - ipatool inject 时用 --plugin-file 顺手塞进 Documents（打包前放好）
//
//  加载进来的插件如果也按 IPATControlShared.h 的协议 post 注册通知，
//  悬浮面板会自动多出它自己那一节 —— 面板不用改任何代码。
//

#import <UIKit/UIKit.h>
#import <dlfcn.h>
#import <libkern/OSByteOrder.h>
#import <mach-o/arch.h>
#import <mach-o/fat.h>
#import <mach-o/loader.h>
#import <mach/mach.h>
#import <pthread.h>
#import "IPATControlShared.h"

#define IPATPlLog(fmt, ...)                                                    \
    do {                                                                       \
        NSString *ipatPlLine__ = [NSString stringWithFormat:@"[ipatool-plugins] " fmt, ##__VA_ARGS__]; \
        NSLog(@"%@", ipatPlLine__);                                            \
        IPATAppendLogLine(ipatPlLine__);                                       \
    } while (0)

#pragma mark - 配置

/// Info.plist 里的键（初始值），面板改过之后以 NSUserDefaults 为准
static NSString *const IPATPlInfoKey = @"IPAToolPlugins";

typedef struct {
    BOOL enabled;
    BOOL autoLoad;      // 启动时自动加载上次加载过的插件
} IPATPlConfig;

static NSArray<NSString *> *IPATPlDefaultDirs(void) {
    // 相对沙盒根目录；「文件」App 导入的插件落在 Documents
    return @[@"Documents", @"Documents/Dylibs", @"Library/Caches", @"tmp"];
}

static IPATPlConfig IPATPlReadConfig(void) {
    IPATPlConfig config = {NO, NO};

    NSDictionary *plist = nil;
    id raw = [[NSBundle mainBundle] objectForInfoDictionaryKey:IPATPlInfoKey];
    if ([raw isKindOfClass:[NSDictionary class]]) plist = raw;

    id enabled = plist[@"Enabled"];
    if ([enabled respondsToSelector:@selector(boolValue)]) config.enabled = [enabled boolValue];

    id autoLoad = plist[@"AutoLoad"];
    if ([autoLoad respondsToSelector:@selector(boolValue)]) config.autoLoad = [autoLoad boolValue];

    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    id storedEnabled = [defaults objectForKey:IPATKeyPluginsEnabled];
    if (storedEnabled != nil) config.enabled = [storedEnabled boolValue];
    id storedAuto = [defaults objectForKey:IPATKeyPluginsAutoLoad];
    if (storedAuto != nil) config.autoLoad = [storedAuto boolValue];

    return config;
}

static NSString *IPATPlSandboxRoot(void) {
    return NSHomeDirectory();
}

/// 把配置里的相对路径（Documents/xxx.dylib）按沙盒根目录补全
static NSString *IPATPlResolvePath(NSString *path) {
    if (path.length == 0) return @"";
    if ([path hasPrefix:@"/"]) return [path stringByStandardizingPath];
    return [[[IPATPlSandboxRoot() stringByAppendingPathComponent:path] stringByStandardizingPath]
            copy];
}

/// 递归扫目录（写成普通 C 函数：block 递归要 __block 才安全，没必要绕这一圈）
static void IPATPlScanInto(NSMutableArray<NSString *> *found, NSMutableSet<NSString *> *seen,
                           NSString *dir, NSInteger depth) {
    NSFileManager *manager = [NSFileManager defaultManager];
    BOOL isDir = NO;
    if (![manager fileExistsAtPath:dir isDirectory:&isDir] || !isDir) return;
    NSArray<NSString *> *entries = [manager contentsOfDirectoryAtPath:dir error:nil] ?: @[];

    for (NSString *name in entries) {
        if ([name hasPrefix:@"."]) continue;
        NSString *full = [dir stringByAppendingPathComponent:name];
        if ([name.pathExtension.lowercaseString isEqualToString:@"dylib"]) {
            if (![seen containsObject:full]) {
                [seen addObject:full];
                [found addObject:full];
            }
            continue;
        }
        if (depth <= 0) continue;
        BOOL childIsDir = NO;
        if ([manager fileExistsAtPath:full isDirectory:&childIsDir] && childIsDir) {
            IPATPlScanInto(found, seen, full, depth - 1);
        }
    }
}

/// 扫描候选目录，找出所有 .dylib（只往下钻两层，够用又不至于把沙盒翻个底朝天）
static NSArray<NSString *> *IPATPlScanDylibs(NSArray<NSString *> *dirs) {
    NSMutableArray<NSString *> *found = [NSMutableArray array];
    NSMutableSet<NSString *> *seen = [NSMutableSet set];

    for (NSString *dir in dirs) {
        IPATPlScanInto(found, seen, IPATPlResolvePath(dir), 2);
    }
    // 随包注入的 dylib（Frameworks/）也列出来，方便区分哪些是内置的
    NSString *frameworks = [[[NSBundle mainBundle] bundlePath] stringByAppendingPathComponent:@"Frameworks"];
    IPATPlScanInto(found, seen, frameworks, 0);

    [found sortUsingSelector:@selector(localizedStandardCompare:)];
    return found;
}

#pragma mark - Mach-O 预检

/// 本机 CPU 类型（arm64 真机 / 模拟器各自匹配）
static cpu_type_t IPATPlHostCPUType(void) {
    const NXArchInfo *info = NXGetLocalArchInfo();
    if (info) return info->cputype;
#if defined(__arm64__)
    return CPU_TYPE_ARM64;
#elif defined(__x86_64__)
    return CPU_TYPE_X86_64;
#else
    return CPU_TYPE_ARM;
#endif
}

/// 只做「能不能试着 dlopen」这一层的检查，签名问题留给 dlopen 自己报错（那才是权威结论）。
/// ok = NO 时返回给用户看的原因。
static NSString *IPATPlCheckFile(NSString *path, BOOL *ok) {
    *ok = NO;
    NSFileManager *manager = [NSFileManager defaultManager];
    BOOL isDir = NO;
    if (![manager fileExistsAtPath:path isDirectory:&isDir]) {
        return @"文件不存在（可能被删了，或路径写错了）";
    }
    if (isDir) return @"这是一个目录，不是 dylib 文件";

    NSDictionary *attrs = [manager attributesOfItemAtPath:path error:nil];
    unsigned long long size = [attrs[NSFileSize] unsignedLongLongValue];
    if (size < sizeof(struct mach_header)) return @"文件太小，不像 Mach-O";

    NSFileHandle *handle = [NSFileHandle fileHandleForReadingAtPath:path];
    if (!handle) return @"读不了这个文件（权限问题？）";
    NSData *head = nil;
    @try {
        head = [handle readDataOfLength:4096];
    } @catch (NSException *exception) {
        head = nil;
    }
    [handle closeFile];
    if (head.length < 4) return @"文件读出来是空的";

    const uint8_t *bytes = head.bytes;
    uint32_t magic = 0;
    memcpy(&magic, bytes, 4);

    cpu_type_t host = IPATPlHostCPUType();

    if (magic == FAT_MAGIC || magic == FAT_CIGAM || magic == FAT_MAGIC_64 || magic == FAT_CIGAM_64) {
        BOOL swapped = (magic == FAT_CIGAM || magic == FAT_CIGAM_64);
        BOOL is64 = (magic == FAT_MAGIC_64 || magic == FAT_CIGAM_64);
        uint32_t count = 0;
        memcpy(&count, bytes + 4, 4);
        if (swapped) count = OSSwapInt32(count);
        size_t entrySize = is64 ? sizeof(struct fat_arch_64) : sizeof(struct fat_arch);
        if (head.length < 8 + entrySize * count) return @"fat 头不完整，文件可能被截断了";
        for (uint32_t i = 0; i < count; i++) {
            const uint8_t *entry = bytes + 8 + entrySize * i;
            cpu_type_t cpu = 0;
            memcpy(&cpu, entry, sizeof(cpu_type_t));
            if (swapped) cpu = (cpu_type_t)OSSwapInt32((uint32_t)cpu);
            if (cpu == host) {
                *ok = YES;
                return nil;
            }
        }
        return [NSString stringWithFormat:@"fat 包里没有本机架构（需要 %s）",
                                          (host == CPU_TYPE_ARM64) ? "arm64" : "x86_64/arm64"];
    }

    if (magic != MH_MAGIC && magic != MH_CIGAM && magic != MH_MAGIC_64 && magic != MH_CIGAM_64) {
        return @"不是 Mach-O 文件（可能是 zip / apk，或者放错了文件）";
    }

    BOOL swapped = (magic == MH_CIGAM || magic == MH_CIGAM_64);
    cpu_type_t cpu = 0;
    memcpy(&cpu, bytes + 4, sizeof(cpu_type_t));
    if (swapped) cpu = (cpu_type_t)OSSwapInt32((uint32_t)cpu);
    if (cpu != host) {
        // 模拟器上最容易踩这个坑：真机编的 dylib 装不进模拟器，反之亦然
        return [NSString stringWithFormat:@"架构不匹配（插件是 %s，当前进程需要 %s）",
                                          (cpu == CPU_TYPE_ARM64) ? "arm64" : "其它架构",
                                          (host == CPU_TYPE_ARM64) ? "arm64" : "x86_64"];
    }

    *ok = YES;
    return nil;
}

#pragma mark - 加载 / 卸载

static pthread_mutex_t IPATPlLock = PTHREAD_MUTEX_INITIALIZER;
static NSMutableDictionary<NSString *, NSValue *> *IPATPlHandleMap(void) {
    static NSMutableDictionary<NSString *, NSValue *> *map;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ map = [NSMutableDictionary dictionary]; });
    return map;
}

/// dlopen 的报错信息交给用户自己看没意义，翻译成「该去改什么」
static NSString *IPATPlFriendlyError(NSString *raw) {
    NSMutableString *text = [NSMutableString stringWithString:raw ?: @"dlopen 失败（没有更多信息）"];
    NSString *hint = nil;

    if ([raw containsString:@"code signature"] || [raw containsString:@"not valid for use in process"]) {
        hint = @"签名无效，或插件不是用签主 App 的同一把证书签的。\n"
               @"iOS 的 library validation 要求插件和 App 同 Team ID：\n"
               @"  ipatool signdylib 插件.dylib --identity \"你的证书名\"\n"
               @"（如果 App 本身是 ad-hoc 签的，只能用真实证书重签 App 才行）";
    } else if ([raw containsString:@"no suitable image found"]) {
        hint = @"找不到可加载的镜像：多半是架构不匹配，或签名不被系统信任。";
    } else if ([raw containsString:@"Library not loaded"] || [raw containsString:@"image not found"]) {
        hint = @"插件依赖的库没有一起放进来（它可能链接了别的 dylib / framework，"
               @"需要把那几个文件也放到沙盒里）。";
    } else if ([raw containsString:@"Symbol not found"]) {
        hint = @"插件引用了当前系统 / App 里不存在的符号（编译时的部署目标和系统版本对不上）。";
    } else if ([raw containsString:@"already loaded"]) {
        hint = @"这个库已经加载过了。";
    }

    if (hint) [text appendFormat:@"\n\n提示：%@", hint];
    return text;
}

static void IPATPlRemember(NSString *path, BOOL add);   // 实现在「自动加载清单」段

static BOOL IPATPlIsLoaded(NSString *path) {
    pthread_mutex_lock(&IPATPlLock);
    BOOL loaded = IPATPlHandleMap()[path] != nil;
    pthread_mutex_unlock(&IPATPlLock);
    return loaded;
}

static NSArray<NSString *> *IPATPlLoadedPaths(void) {
    pthread_mutex_lock(&IPATPlLock);
    NSArray<NSString *> *paths = [IPATPlHandleMap().allKeys sortedArrayUsingSelector:@selector(localizedStandardCompare:)];
    pthread_mutex_unlock(&IPATPlLock);
    return paths;
}

/// 加载一个插件。成功返回 nil，失败返回可以直接显示给用户的原因。
static NSString *IPATPlLoad(NSString *path) {
    if (path.length == 0) return @"路径为空";
    NSString *full = IPATPlResolvePath(path);

    if (IPATPlIsLoaded(full)) return nil;   // 已经加载过，当成功处理

    BOOL ok = NO;
    NSString *problem = IPATPlCheckFile(full, &ok);
    if (!ok) return problem;

    dlerror();  // 先清掉历史错误，否则下面可能拿到上一次的残留
    void *handle = dlopen(full.fileSystemRepresentation, RTLD_NOW);
    if (!handle) {
        const char *error = dlerror();
        NSString *raw = error ? [NSString stringWithUTF8String:error] : nil;
        IPATPlLog(@"加载失败：%@ -> %@", full, raw);
        return IPATPlFriendlyError(raw);
    }

    pthread_mutex_lock(&IPATPlLock);
    IPATPlHandleMap()[full] = [NSValue valueWithPointer:handle];
    pthread_mutex_unlock(&IPATPlLock);

    IPATPlLog(@"已加载插件：%@", full);
    [IPATPlRemember(full, YES)];

    // 插件要是按面板协议写了注册逻辑，重新广播一次 Discover 它就会自己冒出来
    dispatch_async(dispatch_get_main_queue(), ^{
        [[NSNotificationCenter defaultCenter] postNotificationName:IPATControlDiscoverNotification object:nil];
    });
    return nil;
}

/// dlclose 只是「告诉系统我用完了」：iOS 上通常不会真的卸载镜像
/// （库一旦被引用过、或有线程局部存储，卸载会失败/被忽略），所以别指望换文件能立刻生效。
static NSString *IPATPlUnload(NSString *path) {
    NSString *full = IPATPlResolvePath(path);
    pthread_mutex_lock(&IPATPlLock);
    NSValue *boxed = IPATPlHandleMap()[full];
    [IPATPlHandleMap() removeObjectForKey:full];
    pthread_mutex_unlock(&IPATPlLock);

    [IPATPlRemember(full, NO)];
    if (!boxed) return nil;

    int result = dlclose(boxed.pointerValue);
    IPATPlLog(@"卸载插件（dlclose=%d）：%@", result, full);
    // 即使 dlclose 返回 0，镜像也很可能还在，所以这里不骗用户说「已彻底卸载」
    return nil;
}

#pragma mark - 自动加载清单（NSUserDefaults）

static void IPATPlRemember(NSString *path, BOOL add) {
    if (path.length == 0) return;
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    NSArray *stored = [defaults arrayForKey:IPATKeyPluginsLoaded];
    NSMutableArray<NSString *> *list = [NSMutableArray array];
    for (id item in stored) {
        if ([item isKindOfClass:[NSString class]] && ![list containsObject:item]) [list addObject:item];
    }
    if (add) {
        if (![list containsObject:path]) [list addObject:path];
    } else {
        [list removeObject:path];
    }
    [defaults setObject:list forKey:IPATKeyPluginsLoaded];
    [defaults synchronize];
}

static NSArray<NSString *> *IPATPlAutoLoadPaths(void) {
    NSArray *stored = [[NSUserDefaults standardUserDefaults] arrayForKey:IPATKeyPluginsLoaded];
    NSMutableArray<NSString *> *list = [NSMutableArray array];
    for (id item in stored) {
        if ([item isKindOfClass:[NSString class]]) [list addObject:item];
    }
    return list;
}

#pragma mark - 列表里的一行

@interface IPATPlEntry : NSObject

@property (nonatomic, copy) NSString *path;
@property (nonatomic, copy) NSString *displayPath;
@property (nonatomic, copy) NSString *sizeText;
@property (nonatomic, assign) BOOL loaded;
@property (nonatomic, copy) NSString *error;   // 上一次加载失败的原因

@end

@implementation IPATPlEntry
@end

static NSString *IPATPlSizeText(unsigned long long bytes) {
    double kb = (double)bytes / 1024.0;
    if (kb < 1024.0) return [NSString stringWithFormat:@"%.0f KB", kb];
    return [NSString stringWithFormat:@"%.1f MB", kb / 1024.0];
}

/// 显示用路径：把沙盒根目录那一段去掉，不然一行塞不下
static NSString *IPATPlDisplayPath(NSString *path) {
    NSString *root = IPATPlSandboxRoot();
    if (root.length > 0 && [path hasPrefix:root]) {
        NSString *rel = [path substringFromIndex:root.length];
        return [rel hasPrefix:@"/"] ? [rel substringFromIndex:1] : rel;
    }
    return path;
}

static IPATPlEntry *IPATPlMakeEntry(NSString *path) {
    IPATPlEntry *entry = [[IPATPlEntry alloc] init];
    entry.path = path;
    entry.displayPath = IPATPlDisplayPath(path);
    entry.loaded = IPATPlIsLoaded(path);
    NSDictionary *attrs = [[NSFileManager defaultManager] attributesOfItemAtPath:path error:nil];
    entry.sizeText = IPATPlSizeText([attrs[NSFileSize] unsignedLongLongValue]);
    return entry;
}

#pragma mark - 插件列表卡片

@interface IPATPlCard : UIView

@property (nonatomic, strong) NSArray<IPATPlEntry *> *entries;
@property (nonatomic, strong) UIView *headerView;
@property (nonatomic, strong) UIScrollView *scrollView;
@property (nonatomic, strong) UIButton *refreshButton;
@property (nonatomic, assign) CGFloat contentHeight;
@property (nonatomic, copy) void (^onClose)(void);
@property (nonatomic, copy) void (^onChanged)(void);   // 状态变了（加载/重载）
@property (nonatomic, copy) void (^onRescan)(void);    // 点了「重新扫描沙盒」

@end

@implementation IPATPlCard

- (instancetype)initWithFrame:(CGRect)frame {
    if ((self = [super initWithFrame:frame])) {
        self.backgroundColor = [[UIColor blackColor] colorWithAlphaComponent:0.88];
        self.layer.cornerRadius = 12.0;
        self.layer.masksToBounds = YES;
        self.layer.borderWidth = 1.0;
        self.layer.borderColor = [[UIColor colorWithWhite:1.0 alpha:0.15] CGColor];
        [self buildViews];
    }
    return self;
}

- (void)buildViews {
    CGFloat width = self.bounds.size.width;
    CGFloat margin = 14.0;

    UIView *header = [[UIView alloc] initWithFrame:CGRectMake(0, 0, width, 46.0)];
    header.backgroundColor = [[UIColor whiteColor] colorWithAlphaComponent:0.08];
    [self addSubview:header];
    self.headerView = header;

    UILabel *title = [[UILabel alloc] initWithFrame:CGRectMake(margin, 5.0, width - 70.0, 21.0)];
    title.text = @"插件加载 Plugins";
    title.textColor = [UIColor whiteColor];
    title.font = [UIFont boldSystemFontOfSize:15.0];
    [header addSubview:title];

    UILabel *subtitle = [[UILabel alloc] initWithFrame:CGRectMake(margin, 26.0, width - 70.0, 15.0)];
    subtitle.text = @"拖动这里移动窗口";
    subtitle.textColor = [UIColor colorWithWhite:1.0 alpha:0.55];
    subtitle.font = [UIFont systemFontOfSize:11.0];
    [header addSubview:subtitle];

    UIButton *close = [UIButton buttonWithType:UIButtonTypeSystem];
    close.frame = CGRectMake(width - 44.0, 6.0, 38.0, 34.0);
    [close setTitle:@"✕" forState:UIControlStateNormal];
    [close setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
    close.titleLabel.font = [UIFont systemFontOfSize:17.0];
    [close addTarget:self action:@selector(handleClose) forControlEvents:UIControlEventTouchUpInside];
    [header addSubview:close];

    UIScrollView *scroll = [[UIScrollView alloc]
        initWithFrame:CGRectMake(0, 46.0, width, MAX(0.0, self.bounds.size.height - 46.0 - 60.0))];
    scroll.backgroundColor = [UIColor clearColor];
    scroll.showsVerticalScrollIndicator = YES;
    [self addSubview:scroll];
    self.scrollView = scroll;

    // 底部：刷新按钮 + 一句怎么用
    UIView *footer = [[UIView alloc] initWithFrame:CGRectMake(0, self.bounds.size.height - 60.0, width, 60.0)];
    footer.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleTopMargin;
    footer.backgroundColor = [[UIColor whiteColor] colorWithAlphaComponent:0.05];
    [self addSubview:footer];

    UIButton *refresh = [UIButton buttonWithType:UIButtonTypeSystem];
    refresh.frame = CGRectMake(margin, 8.0, width - margin * 2, 30.0);
    [refresh setTitle:@"重新扫描沙盒" forState:UIControlStateNormal];
    [refresh setTitleColor:[UIColor greenColor] forState:UIControlStateNormal];
    refresh.titleLabel.font = [UIFont systemFontOfSize:13.0];
    refresh.layer.cornerRadius = 6.0;
    refresh.layer.borderWidth = 1.0;
    refresh.layer.borderColor = [[UIColor greenColor] CGColor];
    [refresh addTarget:self action:@selector(handleRefresh) forControlEvents:UIControlEventTouchUpInside];
    [footer addSubview:refresh];
    self.refreshButton = refresh;

    UILabel *hint = [[UILabel alloc] initWithFrame:CGRectMake(margin, 40.0, width - margin * 2, 16.0)];
    hint.text = @"用「文件导入导出」把签好名的 dylib 放进 Documents";
    hint.textColor = [UIColor colorWithWhite:1.0 alpha:0.5];
    hint.font = [UIFont systemFontOfSize:11.0];
    [footer addSubview:hint];
}

- (void)layoutSubviews {
    [super layoutSubviews];
    CGFloat width = self.bounds.size.width;
    self.headerView.frame = CGRectMake(0, 0, width, 46.0);
    self.scrollView.frame = CGRectMake(0, 46.0, width, MAX(0.0, self.bounds.size.height - 46.0 - 60.0));
}

/// 内容完整展开需要的高度；外面按这个值决定卡片高度，不够就滚
- (CGFloat)preferredHeight {
    return 46.0 + 60.0 + MAX(self.contentHeight, 120.0);
}

- (void)reloadList {
    for (UIView *subview in [self.scrollView.subviews copy]) {
        [subview removeFromSuperview];
    }

    CGFloat width = self.scrollView.bounds.size.width;
    if (width <= 0) width = self.bounds.size.width;
    CGFloat margin = 12.0;
    CGFloat rowWidth = width - margin * 2;
    CGFloat y = 8.0;

    if (self.entries.count == 0) {
        UILabel *empty = [[UILabel alloc] initWithFrame:CGRectMake(margin, y, rowWidth, 40.0)];
        empty.text = @"沙盒里没找到 .dylib\n把签好名的插件放进 Documents 后点「重新扫描沙盒」";
        empty.numberOfLines = 2;
        empty.textColor = [UIColor colorWithWhite:1.0 alpha:0.6];
        empty.font = [UIFont systemFontOfSize:12.0];
        [self.scrollView addSubview:empty];
        y += 48.0;
    }

    for (NSUInteger i = 0; i < self.entries.count; i++) {
        IPATPlEntry *entry = self.entries[i];
        CGFloat rowHeight = entry.error.length > 0 ? 96.0 : 54.0;

        UIButton *row = [UIButton buttonWithType:UIButtonTypeCustom];
        row.frame = CGRectMake(margin, y, rowWidth, 46.0);
        row.tag = (NSInteger)i;
        row.backgroundColor = [[UIColor whiteColor] colorWithAlphaComponent:0.07];
        row.layer.cornerRadius = 6.0;
        [row addTarget:self action:@selector(handleRowTap:) forControlEvents:UIControlEventTouchUpInside];
        [self.scrollView addSubview:row];

        UILabel *name = [[UILabel alloc] initWithFrame:CGRectMake(8.0, 4.0, rowWidth - 90.0, 20.0)];
        name.text = entry.path.lastPathComponent;
        name.textColor = [UIColor whiteColor];
        name.font = [UIFont systemFontOfSize:13.0];
        [row addSubview:name];

        UILabel *path = [[UILabel alloc] initWithFrame:CGRectMake(8.0, 24.0, rowWidth - 90.0, 16.0)];
        path.text = [NSString stringWithFormat:@"%@ · %@", entry.displayPath, entry.sizeText];
        path.textColor = [UIColor colorWithWhite:1.0 alpha:0.5];
        path.font = [UIFont systemFontOfSize:10.0];
        path.lineBreakMode = NSLineBreakByTruncatingMiddle;
        [row addSubview:path];

        UILabel *state = [[UILabel alloc] initWithFrame:CGRectMake(rowWidth - 86.0, 8.0, 78.0, 30.0)];
        state.textAlignment = NSTextAlignmentRight;
        state.font = [UIFont systemFontOfSize:11.0];
        if (entry.loaded) {
            state.text = @"✓ 已加载\n点此重载";
            state.numberOfLines = 2;
            state.textColor = [UIColor greenColor];
        } else {
            state.text = @"加载 ›";
            state.textColor = [UIColor colorWithRed:0.32 green:0.72 blue:1.0 alpha:1.0];
        }
        [row addSubview:state];

        y += 54.0;

        if (entry.error.length > 0) {
            // 加载失败：把 dlopen 的原文（翻译过）整段显示出来，别只说「失败」
            UILabel *error = [[UILabel alloc] initWithFrame:CGRectMake(margin + 4.0, y - 4.0, rowWidth - 8.0, 40.0)];
            error.text = entry.error;
            error.numberOfLines = 3;
            error.textColor = [UIColor colorWithRed:1.0 green:0.45 blue:0.45 alpha:1.0];
            error.font = [UIFont systemFontOfSize:10.0];
            [self.scrollView addSubview:error];
            y += 42.0;
        }
    }

    self.contentHeight = y + 8.0;
    self.scrollView.contentSize = CGSizeMake(width, self.contentHeight);
}

#pragma mark 卡片上的操作

- (void)handleRowTap:(UIButton *)sender {
    NSInteger index = sender.tag;
    if (index < 0 || index >= (NSInteger)self.entries.count) return;
    IPATPlEntry *entry = self.entries[index];

    NSString *error = nil;
    if (entry.loaded) {
        // iOS 上 dlclose 基本不真卸载，重载多半还是旧代码 —— 提示里说清楚
        IPATPlUnload(entry.path);
        error = IPATPlLoad(entry.path);
        if (!error) IPATPlLog(@"重新加载：%@（注意 dlclose 通常不会真卸载，改动可能不生效）", entry.path);
    } else {
        error = IPATPlLoad(entry.path);
    }
    entry.error = error;
    entry.loaded = IPATPlIsLoaded(entry.path);
    // 只重画这一张列表，不要重新扫描：否则刚得到的失败原因会被冲掉
    [self reloadList];
    if (self.onChanged) self.onChanged();
}

- (void)handleRefresh {
    if (self.onRescan) self.onRescan();
}

- (void)handleClose {
    if (self.onClose) self.onClose();
}

@end

#pragma mark - 弹窗窗口

/// 不抢焦点（游戏不会因为弹窗被暂停），窗口空白区也不吃触摸 —— 点空白处不会关掉弹窗
@interface IPATPlWindow : UIWindow
@end

@implementation IPATPlWindow

- (BOOL)canBecomeKeyWindow { return NO; }

- (UIView *)hitTest:(CGPoint)point withEvent:(UIEvent *)event {
    UIView *hit = [super hitTest:point withEvent:event];
    return hit == self ? nil : hit;
}

@end

@interface IPATPlRootView : UIView
@end

@implementation IPATPlRootView

- (UIView *)hitTest:(CGPoint)point withEvent:(UIEvent *)event {
    UIView *hit = [super hitTest:point withEvent:event];
    return hit == self ? nil : hit;   // 空白处穿透给游戏
}

@end

@interface IPATPlRootController : UIViewController
@end

@implementation IPATPlRootController

- (BOOL)shouldAutorotate { return YES; }

- (UIInterfaceOrientationMask)supportedInterfaceOrientations { return IPATAppOrientationMask(); }

@end

#pragma mark - 与悬浮面板对接

static NSString *const IPATPlActionBrowse = @"plugins.browse";

@interface IPATPlBridge : NSObject <UIGestureRecognizerDelegate>

@property (nonatomic, strong) UIWindow *settingsWindow;
@property (nonatomic, strong) IPATPlCard *card;
@property (nonatomic, assign) CGPoint dragStart;
@property (nonatomic, assign) CGRect cardFrame;

@end

@implementation IPATPlBridge

+ (instancetype)shared {
    static IPATPlBridge *shared;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ shared = [[IPATPlBridge alloc] init]; });
    return shared;
}

- (void)start {
    NSNotificationCenter *center = [NSNotificationCenter defaultCenter];
    [center addObserver:self selector:@selector(handlePanelChange:) name:IPATControlDidChangeNotification object:nil];
    [center addObserver:self selector:@selector(handlePanelDiscover:) name:IPATControlDiscoverNotification object:nil];
    [center addObserver:self selector:@selector(handleAction:) name:IPATControlActionNotification object:nil];
    [[UIDevice currentDevice] beginGeneratingDeviceOrientationNotifications];
    [center addObserver:self selector:@selector(handleOrientationChange)
                   name:UIDeviceOrientationDidChangeNotification object:nil];
    [self registerWithPanel];

    // 自动加载晚一拍再跑：别拖慢启动，也让插件里的 UI 代码有主线程可用
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        [self autoLoad];
    });
}

- (void)autoLoad {
    IPATPlConfig cfg = IPATPlReadConfig();
    if (!cfg.enabled || !cfg.autoLoad) return;
    NSArray<NSString *> *paths = IPATPlAutoLoadPaths();
    if (paths.count == 0) return;

    NSInteger loaded = 0;
    for (NSString *path in paths) {
        NSString *error = IPATPlLoad(path);
        if (error) {
            IPATPlLog(@"自动加载失败：%@ -> %@", path.lastPathComponent, error);
        } else {
            loaded++;
        }
    }
    IPATPlLog(@"自动加载完成：%ld/%lu 个", (long)loaded, (unsigned long)paths.count);
    [self refreshList];
    [self registerWithPanel];
}

#pragma mark 面板

- (void)registerWithPanel {
    IPATPlConfig cfg = IPATPlReadConfig();
    NSArray<NSString *> *loaded = IPATPlLoadedPaths();
    NSString *detail = loaded.count > 0
        ? [NSString stringWithFormat:@"已加载 %lu 个插件", (unsigned long)loaded.count]
        : @"还没加载插件";

    NSDictionary *reg = @{
        IPATRegId: IPATFeaturePlugins,
        IPATRegTitle: @"插件加载（Plugins）",
        IPATRegDetail: detail,
        IPATRegMasterKey: IPATKeyPluginsEnabled,
        IPATRegEnabled: @(cfg.enabled ? YES : NO),
        IPATRegRows: @[
            @{
                IPATRowKey: IPATPlActionBrowse,
                IPATRowTitle: @"浏览并加载插件…",
                IPATRowKind: IPATRowKindAction,
                IPATRowNote: @"从沙盒里挑 dylib 直接 dlopen，不用重新打包签名",
            },
            @{
                IPATRowKey: IPATKeyPluginsAutoLoad,
                IPATRowTitle: @"启动时自动加载",
                IPATRowKind: IPATRowKindSwitch,
                IPATRowValue: @(cfg.autoLoad ? YES : NO),
                IPATRowNote: @"下次启动自动加载这次加载过的插件",
            },
        ],
    };
    [[NSNotificationCenter defaultCenter] postNotificationName:IPATControlRegisterNotification
                                                        object:nil
                                                      userInfo:reg];
    [self postStatus];
}

- (void)postStatus {
    NSArray<NSString *> *loaded = IPATPlLoadedPaths();
    NSString *text = loaded.count > 0
        ? [NSString stringWithFormat:@"已加载 %lu 个：%@", (unsigned long)loaded.count,
                                     [[loaded valueForKeyPath:@"lastPathComponent"] componentsJoinedByString:@", "]]
        : @"未加载（点「浏览并加载插件…」）";
    [[NSNotificationCenter defaultCenter] postNotificationName:IPATControlStatusNotification
                                                        object:nil
                                                      userInfo:@{IPATRegId: IPATFeaturePlugins,
                                                                 IPATStaDetail: text}];
}

- (void)handlePanelDiscover:(NSNotification *)note {
    [self registerWithPanel];
}

- (void)handlePanelChange:(NSNotification *)note {
    if (![note.userInfo[IPATChgId] isEqualToString:IPATFeaturePlugins]) return;
    id enabled = note.userInfo[IPATChgEnabled];
    if ([enabled respondsToSelector:@selector(boolValue)]) {
        NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
        [defaults setBool:[enabled boolValue] forKey:IPATKeyPluginsEnabled];
        [defaults synchronize];
    }
    NSDictionary *values = note.userInfo[IPATChgValues];
    if ([values isKindOfClass:[NSDictionary class]]) {
        id autoLoad = values[IPATKeyPluginsAutoLoad];
        if (autoLoad) {
            NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
            [defaults setBool:[autoLoad boolValue] forKey:IPATKeyPluginsAutoLoad];
            [defaults synchronize];
        }
    }
    [self registerWithPanel];
}

- (void)handleAction:(NSNotification *)note {
    if (![note.userInfo[IPATChgId] isEqualToString:IPATFeaturePlugins]) return;
    if (![note.userInfo[IPATActKey] isEqualToString:IPATPlActionBrowse]) return;

    IPATPlConfig cfg = IPATPlReadConfig();
    if (!cfg.enabled) {
        IPATPlLog(@"插件加载总开关是关的，先打开它再加载插件");
        return;
    }
    [self openSettings];
}

#pragma mark 弹窗

- (UIWindow *)makeWindow {
    if (self.settingsWindow) return self.settingsWindow;
    UIWindow *window = nil;
    if (@available(iOS 13.0, *)) {
        UIWindowScene *scene = nil;
        for (UIScene *candidate in [UIApplication sharedApplication].connectedScenes) {
            if (![candidate isKindOfClass:[UIWindowScene class]]) continue;
            scene = (UIWindowScene *)candidate;
            if (candidate.activationState == UISceneActivationStateForegroundActive) break;
        }
        if (scene && [UIWindow instancesRespondToSelector:@selector(initWithWindowScene:)]) {
            IPATPlWindow *made = [[IPATPlWindow alloc] initWithWindowScene:scene];
            made.frame = [UIScreen mainScreen].bounds;
            made.windowLevel = UIWindowLevelAlert + 150;
            made.backgroundColor = [UIColor clearColor];
            made.opaque = NO;
            IPATPlRootController *root = [[IPATPlRootController alloc] init];
            IPATPlRootView *view = [[IPATPlRootView alloc] initWithFrame:made.bounds];
            view.backgroundColor = [UIColor clearColor];
            view.opaque = NO;
            view.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
            root.view = view;
            made.rootViewController = root;
            window = made;
        }
    }
    if (!window) {
        IPATPlLog(@"拿不到 windowScene，插件窗口弹不出来");
        return nil;
    }
    self.settingsWindow = window;
    return window;
}

- (void)openSettings {
    dispatch_async(dispatch_get_main_queue(), ^{
        UIWindow *window = [self makeWindow];
        if (!window) return;
        [self syncWindowGeometry];
        window.hidden = NO;

        if (!self.card) {
            CGFloat width = MIN(340.0, window.bounds.size.width - 32.0);
            IPATPlCard *card = [[IPATPlCard alloc] initWithFrame:CGRectMake(0, 0, width, 480.0)];
            __weak typeof(self) weakSelf = self;
            card.onClose = ^{ [weakSelf closeSettings]; };
            card.onChanged = ^{ [weakSelf registerWithPanel]; };
            card.onRescan = ^{ [weakSelf refreshList]; [weakSelf registerWithPanel]; };
            UIPanGestureRecognizer *pan =
                [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(handleDrag:)];
            pan.delegate = self;
            [card.headerView addGestureRecognizer:pan];
            [window.rootViewController.view addSubview:card];
            self.card = card;
        }
        [self refreshList];
        [self layoutCard];

        [[NSNotificationCenter defaultCenter] postNotificationName:IPATControlVisibilityNotification
                                                            object:nil
                                                          userInfo:@{IPATVisVisible: @NO}];
        IPATPlLog(@"插件窗口已打开");
    });
}

- (void)closeSettings {
    dispatch_async(dispatch_get_main_queue(), ^{
        [self saveCardFrame];
        [self.card removeFromSuperview];
        self.card = nil;
        if (self.settingsWindow) {
            NSArray<UIView *> *subs = [self.settingsWindow.rootViewController.view.subviews copy];
            for (UIView *subview in subs) {
                [subview removeFromSuperview];
            }
            self.settingsWindow.hidden = YES;
        }
        [[NSNotificationCenter defaultCenter] postNotificationName:IPATControlVisibilityNotification
                                                            object:nil
                                                          userInfo:@{IPATVisVisible: @YES}];
        [self registerWithPanel];
        IPATPlLog(@"插件窗口已关闭");
    });
}

/// 重新扫一遍沙盒，把新的 dylib 列出来
- (void)refreshList {
    if (!self.card) return;
    NSArray<NSString *> *paths = IPATPlScanDylibs(IPATPlDefaultDirs());
    NSMutableArray<IPATPlEntry *> *entries = [NSMutableArray arrayWithCapacity:paths.count];
    for (NSString *path in paths) {
        IPATPlEntry *entry = IPATPlMakeEntry(path);
        // 「已加载」状态要跟着当前句柄表走，扫描出来的不带历史错误
        [entries addObject:entry];
    }
    self.card.entries = entries;
    [self.card reloadList];
}

- (BOOL)gestureRecognizer:(UIGestureRecognizer *)gestureRecognizer shouldReceiveTouch:(UITouch *)touch {
    for (UIView *candidate = touch.view; candidate; candidate = candidate.superview) {
        if ([candidate isKindOfClass:[UIControl class]]) return NO;
    }
    return YES;
}

- (void)handleDrag:(UIPanGestureRecognizer *)pan {
    UIView *card = self.card;
    UIView *superview = card.superview;
    if (!card || !superview) return;

    if (pan.state == UIGestureRecognizerStateBegan) {
        self.dragStart = card.center;
    }
    CGPoint delta = [pan translationInView:superview];
    CGPoint center = CGPointMake(self.dragStart.x + delta.x, self.dragStart.y + delta.y);
    CGFloat halfWidth = card.bounds.size.width / 2.0;
    CGFloat halfHeight = card.bounds.size.height / 2.0;
    center.x = MIN(MAX(halfWidth + 4.0, center.x), superview.bounds.size.width - halfWidth - 4.0);
    center.y = MIN(MAX(halfHeight + 4.0, center.y), superview.bounds.size.height - halfHeight - 4.0);
    card.center = center;

    if (pan.state == UIGestureRecognizerStateEnded || pan.state == UIGestureRecognizerStateCancelled) {
        self.cardFrame = card.frame;
        [self saveCardFrame];
    }
}

- (void)saveCardFrame {
    if (CGRectIsEmpty(self.cardFrame)) return;
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    [defaults setObject:NSStringFromCGRect(self.cardFrame) forKey:IPATKeyPluginsCardFrame];
    [defaults synchronize];
}

- (void)layoutCard {
    UIWindow *window = self.settingsWindow;
    IPATPlCard *card = self.card;
    if (!window || !card) return;

    CGRect bounds = window.bounds;
    CGRect frame = card.frame;
    frame.size.width = MIN(340.0, bounds.size.width - 32.0);
    frame.size.height = MIN([card preferredHeight], bounds.size.height - 24.0);

    if (CGRectIsEmpty(self.cardFrame)) {
        NSString *saved = [[NSUserDefaults standardUserDefaults] objectForKey:IPATKeyPluginsCardFrame];
        if (saved.length > 0) self.cardFrame = CGRectFromString(saved);
    }
    if (!CGRectIsEmpty(self.cardFrame)) {
        frame.origin = self.cardFrame.origin;
    } else {
        frame.origin.x = (bounds.size.width - frame.size.width) / 2.0;
        frame.origin.y = (bounds.size.height - frame.size.height) / 2.0;
    }
    frame.origin.x = MIN(MAX(8.0, frame.origin.x), bounds.size.width - frame.size.width - 8.0);
    frame.origin.y = MIN(MAX(8.0, frame.origin.y), bounds.size.height - frame.size.height - 8.0);
    card.frame = frame;
    self.cardFrame = frame;
}

- (void)syncWindowGeometry {
    UIWindow *window = self.settingsWindow;
    if (!window) return;
    IPATAlignWindowToInterface(window, IPATAppKeyWindowExcluding(window));
}

- (void)handleOrientationChange {
    if (!self.settingsWindow || self.settingsWindow.isHidden) return;
    dispatch_async(dispatch_get_main_queue(), ^{
        [self syncWindowGeometry];
        [self layoutCard];
    });
}

@end

__attribute__((constructor)) static void IPATPluginLoaderInit(void) {
    IPATPlConfig cfg = IPATPlReadConfig();
    IPATPlLog(@"插件加载器已就绪（启用=%d 自动加载=%d）", cfg.enabled, cfg.autoLoad);
    dispatch_async(dispatch_get_main_queue(), ^{
        [[IPATPlBridge shared] start];
    });
}
