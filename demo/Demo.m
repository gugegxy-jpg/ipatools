//
//  ipatool 注入验证 Demo
//
//  在真机上核对四个 tweak 是否真的生效：
//    PiBackground  -> 切到后台时应出现画中画小窗（iOS 15+ 用内置画面源）
//    KeepAlive     -> 后台心跳 > 0 即说明进程没被挂起
//    FileBridge    -> Documents 目录可见、可写入、可从「文件」App 导入
//    ControlPanel  -> 屏幕右侧的悬浮胶囊按钮，点一下展开面板
//
//  这个 App 只做「显示状态」，不参与任何注入逻辑：dylib 全部是 constructor 自启动，
//  宿主只要有一个可见窗口和 rootViewController 即可。
//
#import <UIKit/UIKit.h>
#import <AVFoundation/AVFoundation.h>
#import <AVKit/AVKit.h>
#import <mach-o/dyld.h>

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"

static UITextView *gText = nil;
static NSMutableArray<NSString *> *gEvents = nil;
static NSDate *gBgStart = nil;
static int gTick = 0;            // 心跳总数
static int gBgTick = 0;          // 处于后台时的心跳数，> 0 说明保活生效
static int gBgCount = 0;         // 进入后台次数
static NSTimeInterval gLastBg = 0;
static NSTimeInterval gTotalBg = 0;

static NSString *TS(void) {
    static NSDateFormatter *f = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        f = [[NSDateFormatter alloc] init];
        f.dateFormat = @"HH:mm:ss";
    });
    return [f stringFromDate:[NSDate date]];
}

static void IPATLog(NSString *s) {
    [gEvents addObject:[NSString stringWithFormat:@"%@  %@", TS(), s]];
    while (gEvents.count > 25) {
        [gEvents removeObjectAtIndex:0];
    }
}

static NSString *DocsDir(void) {
    return NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject;
}

// 已加载的注入库：dyld 里路径含 .app/Frameworks/ 的镜像
static NSString *LoadedTweaks(void) {
    NSMutableArray *out = [NSMutableArray array];
    uint32_t n = _dyld_image_count();
    for (uint32_t i = 0; i < n; i++) {
        const char *p = _dyld_get_image_name(i);
        if (!p) continue;
        NSString *path = [NSString stringWithUTF8String:p];
        if ([path rangeOfString:@".app/Frameworks/"].location == NSNotFound) continue;
        [out addObject:[path lastPathComponent]];
    }
    return out.count ? [out componentsJoinedByString:@"\n  "] : @"（无，注入没生效）";
}

static NSString *ListDocs(void) {
    NSFileManager *fm = [NSFileManager defaultManager];
    NSArray *items = [fm contentsOfDirectoryAtPath:DocsDir() error:nil];
    if (items.count == 0) return @"  （空）";
    NSMutableString *s = [NSMutableString string];
    for (NSString *name in [items sortedArrayUsingSelector:@selector(compare:)]) {
        NSString *p = [DocsDir() stringByAppendingPathComponent:name];
        unsigned long long size = [[fm attributesOfItemAtPath:p error:nil] fileSize];
        [s appendFormat:@"  %@  (%llu B)\n", name, size];
    }
    return s;
}

static NSString *AppStateName(void) {
    UIApplicationState st = [UIApplication sharedApplication].applicationState;
    if (st == UIApplicationStateBackground) return @"后台";
    if (st == UIApplicationStateInactive) return @"非活跃";
    return @"前台";
}

static void Refresh(void) {
    NSDictionary *info = [[NSBundle mainBundle] infoDictionary];
    id modes = info[@"UIBackgroundModes"];
    NSString *bg = [modes isKindOfClass:[NSArray class]] ? [modes componentsJoinedByString:@","] : @"（无）";

    NSString *pip = @"未知";
    if (@available(iOS 14.0, *)) {
        pip = [AVPictureInPictureController isPictureInPictureSupported] ? @"设备支持" : @"设备不支持";
    }

    NSMutableString *t = [NSMutableString string];
    [t appendString:@"===== ipatool 真机验证 =====\n"];
    [t appendString:@"右侧悬浮胶囊 = 控制面板，点一下展开\n\n"];

    [t appendFormat:@"【1】已加载的注入 dylib\n  %@\n\n", LoadedTweaks()];

    [t appendFormat:@"【2】注入写入的配置\n  IPAToolPiP    : %@\n", info[@"IPAToolPiP"] ?: @"（无）"];
    [t appendFormat:@"  IPAToolKeepAlive: %@\n", info[@"IPAToolKeepAlive"] ?: @"（无）"];
    [t appendFormat:@"  IPAToolFiles : %@\n", info[@"IPAToolFiles"] ?: @"（无）"];
    [t appendFormat:@"  IPAToolControl: %@\n", info[@"IPAToolControl"] ?: @"（无）"];
    [t appendFormat:@"  UIBackgroundModes: %@\n\n", bg];

    [t appendString:@"【3】运行状态\n"];
    [t appendFormat:@"  当前状态      : %@\n", AppStateName()];
    [t appendFormat:@"  心跳          : 前台 %d 次 / 后台 %d 次\n", gTick - gBgTick, gBgTick];
    [t appendFormat:@"  ★后台心跳 > 0  = 进程没被挂起，保活生效\n"];
    [t appendFormat:@"  进入后台次数  : %d 次，累计后台 %.0f 秒（上次 %.0f 秒）\n", gBgCount, gTotalBg, gLastBg];
    [t appendFormat:@"  画中画        : %@\n", pip];
    [t appendFormat:@"  音频会话      : %@\n\n", [AVAudioSession sharedInstance].category];

    [t appendFormat:@"【4】Documents（「文件」App 与面板导入都落这里）\n%@\n", ListDocs()];

    [t appendString:@"【5】事件日志\n"];
    for (NSString *e in gEvents) {
        [t appendFormat:@"  %@\n", e];
    }

    gText.text = t;
}

// ---------------------------------------------------------------- 界面
@interface IPATRootVC : UIViewController
@end

@implementation IPATRootVC

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"ipatool 验证";
    if (@available(iOS 13.0, *)) {
        self.view.backgroundColor = [UIColor systemBackgroundColor];
    } else {
        self.view.backgroundColor = [UIColor whiteColor];
    }

    gText = [[UITextView alloc] init];
    gText.editable = NO;
    gText.font = [UIFont fontWithName:@"Menlo" size:11.0] ?: [UIFont systemFontOfSize:12.0];
    gText.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:gText];

    UIButton *writeBtn = [UIButton buttonWithType:UIButtonTypeSystem];
    [writeBtn setTitle:@"写入测试文件" forState:UIControlStateNormal];
    [writeBtn addTarget:self action:@selector(writeTestFile) forControlEvents:UIControlEventTouchUpInside];

    UIButton *clearBtn = [UIButton buttonWithType:UIButtonTypeSystem];
    [clearBtn setTitle:@"清空日志" forState:UIControlStateNormal];
    [clearBtn addTarget:self action:@selector(clearLog) forControlEvents:UIControlEventTouchUpInside];

    UIStackView *bar = [[UIStackView alloc] initWithArrangedSubviews:@[writeBtn, clearBtn]];
    bar.axis = UILayoutConstraintAxisHorizontal;
    bar.distribution = UIStackViewDistributionFillEqually;
    bar.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:bar];

    UILayoutGuide *safe = self.view.safeAreaLayoutGuide;
    [NSLayoutConstraint activateConstraints:@[
        [bar.leadingAnchor constraintEqualToAnchor:safe.leadingAnchor constant:8.0],
        [bar.trailingAnchor constraintEqualToAnchor:safe.trailingAnchor constant:-8.0],
        [bar.bottomAnchor constraintEqualToAnchor:safe.bottomAnchor constant:-8.0],
        [bar.heightAnchor constraintEqualToConstant:44.0],
        [gText.topAnchor constraintEqualToAnchor:safe.topAnchor constant:8.0],
        [gText.leadingAnchor constraintEqualToAnchor:safe.leadingAnchor constant:8.0],
        [gText.trailingAnchor constraintEqualToAnchor:safe.trailingAnchor constant:-8.0],
        [gText.bottomAnchor constraintEqualToAnchor:bar.topAnchor constant:-8.0],
    ]];
}

- (void)writeTestFile {
    NSString *path = [DocsDir() stringByAppendingPathComponent:@"ipatool_demo.txt"];
    NSString *body = [NSString stringWithFormat:@"ipatool demo 写入于 %@\n", [NSDate date]];
    NSError *err = nil;
    [body writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:&err];
    IPATLog(err ? [NSString stringWithFormat:@"写入失败: %@", err.localizedDescription]
                : [NSString stringWithFormat:@"已写入 %@", path.lastPathComponent]);
    Refresh();
}

- (void)clearLog {
    [gEvents removeAllObjects];
    Refresh();
}

@end

// ---------------------------------------------------------------- Scene
@interface IPATSceneDelegate : UIResponder <UIWindowSceneDelegate>
@property (nonatomic, strong) UIWindow *window;
@property (nonatomic, strong) NSTimer *timer;
@end

@implementation IPATSceneDelegate

- (void)scene:(UIScene *)scene
willConnectToSession:(UISceneSession *)session
      options:(UISceneConnectionOptions *)options {
    UIWindowScene *ws = (UIWindowScene *)scene;
    self.window = [[UIWindow alloc] initWithWindowScene:ws];
    self.window.frame = [UIScreen mainScreen].bounds;
    self.window.rootViewController = [[IPATRootVC alloc] init];
    [self.window makeKeyAndVisible];
    IPATLog(@"启动完成，窗口已就绪");

    NSNotificationCenter *nc = [NSNotificationCenter defaultCenter];
    [nc addObserver:self selector:@selector(onEnterBg) name:UIApplicationDidEnterBackgroundNotification object:nil];
    [nc addObserver:self selector:@selector(onEnterFg) name:UIApplicationWillEnterForegroundNotification object:nil];
    [nc addObserver:self selector:@selector(onActive) name:UIApplicationDidBecomeActiveNotification object:nil];

    self.timer = [NSTimer scheduledTimerWithTimeInterval:1.0
                                                  target:self
                                                selector:@selector(onTick)
                                                userInfo:nil
                                                 repeats:YES];
    Refresh();
}

- (void)onTick {
    gTick++;
    if ([UIApplication sharedApplication].applicationState == UIApplicationStateBackground) {
        gBgTick++;
    }
    Refresh();
}

- (void)onEnterBg {
    gBgStart = [NSDate date];
    gBgCount++;
    IPATLog([NSString stringWithFormat:@"进入后台（第 %d 次）", gBgCount]);
}

- (void)onEnterFg {
    if (gBgStart) {
        gLastBg = -[gBgStart timeIntervalSinceNow];
        gTotalBg += gLastBg;
        IPATLog([NSString stringWithFormat:@"回到前台，本次后台 %.0f 秒", gLastBg]);
        gBgStart = nil;
    }
}

- (void)onActive {
    IPATLog(@"已激活");
}

@end

// ---------------------------------------------------------------- App
@interface IPATAppDelegate : UIResponder <UIApplicationDelegate>
@end

@implementation IPATAppDelegate

API_AVAILABLE(ios(13.0))
- (UISceneConfiguration *)application:(UIApplication *)application
configurationForConnectingSceneSession:(UISceneSession *)session
                              options:(UISceneConnectionOptions *)options {
    UISceneConfiguration *cfg = [[UISceneConfiguration alloc] initWithName:@"Default Configuration"
                                                              sessionRole:session.role];
    cfg.delegateClass = [IPATSceneDelegate class];
    return cfg;
}

@end

int main(int argc, char *argv[]) {
    @autoreleasepool {
        gEvents = [NSMutableArray array];
        return UIApplicationMain(argc, argv, nil, NSStringFromClass([IPATAppDelegate class]));
    }
}

#pragma clang diagnostic pop
