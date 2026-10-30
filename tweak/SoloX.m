//
//  SoloX.m
//  性能悬浮窗插件（独立 dylib）：注入游戏后，在屏幕顶部漂浮显示
//  CPU / 内存 / 网络 / FPS / 电量 / 温度；悬浮层 isUserInteractionEnabled = NO，
//  点击直接穿透到游戏。开关行（总开关 + 6 个指标子开关）通过
//  IPATControlRegisterNotification 注册进 ipatool 的游戏内悬浮窗，
//  面板里切换时由 IPATControlDidChangeNotification 回传。
//
//  依赖 IPATControlShared.h 的整套「通知 + NSUserDefaults」协议（与 QNet 一致），
//  不链接 ControlPanel 的符号，谁先加载都不影响。
//
#import <UIKit/UIKit.h>
#import "IPATControlShared.h"
#import <mach/mach.h>
#import <sys/sysctl.h>
#import <ifaddrs.h>
#import <net/if.h>
#import <net/if_dl.h>
#import <dlfcn.h>

#pragma mark - 配置键（与悬浮窗写入的 NSUserDefaults 键一致）

#define IPATFeatureSoloX    @"solox"
#define IPATKeySoloXEnabled @"IPAToolPanelSoloXEnabled"   // 总开关
#define IPATKeySoloXCPU     @"IPAToolPanelSoloXCPU"
#define IPATKeySoloXMEM     @"IPAToolPanelSoloXMEM"
#define IPATKeySoloXNET     @"IPAToolPanelSoloXNET"
#define IPATKeySoloXFPS     @"IPAToolPanelSoloXFPS"
#define IPATKeySoloXBAT     @"IPAToolPanelSoloXBAT"
#define IPATKeySoloXTEMP    @"IPAToolPanelSoloXTEMP"
#define IPATKeySoloXExport  @"IPAToolPanelSoloXExport"    // 导出报告（动作行）
#define IPAToolSoloXPlistKey @"IPAToolSoloX"              // Info.plist 初始配置字典

// 导出 HTML 报告内嵌的图表脚本：纯原生 Canvas 绘制，无外部依赖，可离线打开看走势。
// 仅用单引号，避免与 ObjC 字符串的双引号冲突。
static NSString *const kSoloXChartJS =
@"var specs=[{f:'cpu',l:'CPU 使用率',u:'%',c:'#33ff66'},"
@"{f:'mem',l:'内存',u:'MB',c:'#4aa3ff'},"
@"{f:'net',l:'网络吞吐',u:'B/s',c:'#ffcc33'},"
@"{f:'fps',l:'FPS',u:'',c:'#ff66cc'},"
@"{f:'bat',l:'电量',u:'%',c:'#66ffcc'},"
@"{f:'temp',l:'温度',u:'℃',c:'#ff7744'}];"
@"var host=document.getElementById('charts');"
@"function vals(f){var a=[];for(var i=0;i<data.length;i++){var v=data[i][f];a.push(v===null||v===undefined?null:v);}return a;}"
@"function draw(s){"
@"var v=vals(s.f);var cv=document.createElement('canvas');"
@"cv.style.width='100%';cv.style.height='170px';cv.style.background='#0d1117';"
@"cv.style.borderRadius='8px';cv.style.display='block';cv.style.margin='6px 0';"
@"var t=document.createElement('div');t.style.color=s.c;t.style.font='13px sans-serif';"
@"t.style.margin='10px 0 2px';t.textContent=s.l+' ('+s.u+')';"
@"host.appendChild(t);host.appendChild(cv);"
@"var dpr=window.devicePixelRatio||1;var w=cv.clientWidth||(window.innerWidth-32);var h=cv.clientHeight;"
@"cv.width=w*dpr;cv.height=h*dpr;var ctx=cv.getContext('2d');ctx.scale(dpr,dpr);"
@"var valid=v.filter(function(x){return x!==null;});"
@"if(valid.length<2){ctx.fillStyle='#888';ctx.font='12px sans-serif';ctx.fillText('数据不足',8,24);return;}"
@"var min=Math.min.apply(null,valid),max=Math.max.apply(null,valid);"
@"if(max-min<1e-6){max=min+1;}"
@"var padL=42,padR=8,padT=10,padB=16;var gw=w-padL-padR,gh=h-padT-padB;"
@"ctx.strokeStyle='#222';ctx.fillStyle='#888';ctx.font='10px sans-serif';ctx.lineWidth=1;"
@"for(var g=0;g<=4;g++){var yy=padT+gh*g/4;ctx.beginPath();ctx.moveTo(padL,yy);ctx.lineTo(w-padR,yy);ctx.stroke();"
@"var val=max-(max-min)*g/4;ctx.fillText(val.toFixed(max>100?0:1),2,yy+3);}"
@"ctx.strokeStyle=s.c;ctx.lineWidth=1.5;ctx.beginPath();var started=false;"
@"for(var i=0;i<v.length;i++){if(v[i]===null){started=false;continue;}"
@"var x=padL+gw*i/(v.length-1);var y=padT+gh*(1-(v[i]-min)/(max-min));"
@"if(!started){ctx.moveTo(x,y);started=true;}else ctx.lineTo(x,y);}"
@"ctx.stroke();"
@"var last=valid[valid.length-1];ctx.fillStyle=s.c;ctx.font='12px sans-serif';"
@"ctx.fillText(s.l+'：'+last.toFixed(max>100?0:1)+s.u,padL,padT+12);}"
@"specs.forEach(draw);";

@interface SoloXMonitor : NSObject
+ (void)loadPlugin;
- (void)applyVisibility;
- (void)refreshMetrics;
@end

/// 根控制器：允许转到「游戏现在这个方向」。用裸 UIViewController 的话窗口的
/// 方向策略回落到 App 的 Info.plist——横屏游戏里窗口被系统锁成竖屏，
/// 性能条就竖着挂在屏幕边上。与悬浮面板（IPATCpRootController）同一套做法
@interface SoloXRootVC : UIViewController
@end

@implementation SoloXRootVC
- (BOOL)shouldAutorotate { return YES; }
- (UIInterfaceOrientationMask)supportedInterfaceOrientations { return IPATAppOrientationMask(); }
@end

@implementation SoloXMonitor {
    UIWindow *_window;
    UIView *_bar;
    NSLayoutConstraint *_barTop;   // 性能条顶部距离（竖屏要让出刘海/灵动岛）
    UILabel *_cpu, *_mem, *_net, *_fps, *_bat, *_temp;
    CADisplayLink *_link;
    NSInteger _frameCount;
    double _fpsValue;
    NSTimer *_timer;

    // 总开关 + 各指标是否显示（默认全开）
    BOOL _masterOn;
    BOOL _showCPU, _showMEM, _showNET, _showFPS, _showBAT, _showTEMP;

    // CPU / 网络采样用的上一拍数据
    uint64_t _lastCPU;
    CFAbsoluteTime _lastCPUTime;
    uint64_t _lastNet;

    // 当次运行采样记录（每秒一条，封顶 3600 = 1 小时，超出丢弃最旧）
    NSMutableArray<NSDictionary *> *_samples;
    NSDateFormatter *_tsFormatter;
}

+ (void)load {
    // dylib 加载时在 App 进程里，延到主线程再搭界面，避免过早碰 UIKit。
    dispatch_async(dispatch_get_main_queue(), ^{
        [self loadPlugin];
    });
}

+ (void)loadPlugin {
    static SoloXMonitor *m;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        m = [[SoloXMonitor alloc] init];
    });
}

- (instancetype)init {
    self = [super init];
    if (!self) return nil;

    // 初始状态：先看 NSUserDefaults（面板写过的），再看 Info.plist，都没有就默认全开
    _masterOn = [self boolForKey:IPATKeySoloXEnabled plistSub:@"Enabled" dflt:NO];
    // 子项开关已从面板移除（只留总开关），全部恒开；
    // 清掉历史版本可能存下的 NO，避免某项被旧数据藏掉
    _showCPU = _showMEM = _showNET = _showFPS = _showBAT = _showTEMP = YES;
    [[NSUserDefaults standardUserDefaults] removeObjectForKey:IPATKeySoloXCPU];
    [[NSUserDefaults standardUserDefaults] removeObjectForKey:IPATKeySoloXMEM];
    [[NSUserDefaults standardUserDefaults] removeObjectForKey:IPATKeySoloXNET];
    [[NSUserDefaults standardUserDefaults] removeObjectForKey:IPATKeySoloXFPS];
    [[NSUserDefaults standardUserDefaults] removeObjectForKey:IPATKeySoloXBAT];
    [[NSUserDefaults standardUserDefaults] removeObjectForKey:IPATKeySoloXTEMP];

    [self buildWindow];
    [self registerPanel];
    [self observe];

    // FPS：主线程 CADisplayLink 计帧
    _link = [CADisplayLink displayLinkWithTarget:self selector:@selector(tickFPS:)];
    [_link addToRunLoop:[NSRunLoop mainRunLoop] forMode:NSRunLoopCommonModes];

    // 其它指标 1s 一刷
    _timer = [NSTimer scheduledTimerWithTimeInterval:1.0
                                             target:self
                                           selector:@selector(refreshMetrics)
                                           userInfo:nil
                                            repeats:YES];
    [self refreshMetrics];
    [self applyVisibility];   // 若 App 此刻已在前台（如运行中注入），直接显示并对齐

    // 冷启动兜底：App/scene 可能在观察者注册前就已经激活，生命周期通知被错过，
    // 导致默认开启时悬浮窗不显示、要手动开关一次。延迟再显示+对齐几次，直到游戏窗口就绪。
    for (NSNumber *delay in @[@1.0, @3.0]) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
                                     (int64_t)(delay.doubleValue * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            [self applyVisibility];
        });
    }
    return self;
}

#pragma mark - 状态读取

- (BOOL)boolForKey:(NSString *)key plistSub:(NSString *)sub dflt:(BOOL)dflt {
    id v = [[NSUserDefaults standardUserDefaults] objectForKey:key];
    if (v) return [v boolValue];
    if (sub) {
        NSDictionary *d = [[NSBundle mainBundle].infoDictionary objectForKey:IPAToolSoloXPlistKey];
        if ([d isKindOfClass:[NSDictionary class]] && d[sub]) return [d[sub] boolValue];
    }
    return dflt;
}

- (BOOL)boolForKey:(NSString *)key dflt:(BOOL)dflt {
    return [self boolForKey:key plistSub:nil dflt:dflt];
}

#pragma mark - 悬浮层（顶部性能条，触摸穿透）

- (UIWindowScene *)activeWindowScene {
    if (@available(iOS 13.0, *)) {
        for (UIScene *s in [UIApplication sharedApplication].connectedScenes) {
            if ([s isKindOfClass:[UIWindowScene class]] &&
                ((UIWindowScene *)s).activationState == UISceneActivationStateForegroundActive)
                return (UIWindowScene *)s;
        }
    }
    return nil;
}

- (void)buildWindow {
    // 只靠 hidden 控制显隐，绝不 makeKeyAndVisible：抢成 key 窗口会让游戏暂停。
    // 用「场景窗口」并挂到「前台激活」的 scene 上：launch 阶段 scene 可能还没激活，
    // 所以先建好、隐藏，等 didBecomeActive / scene 激活后再由 applyVisibility 挂到激活
    // scene 并显示（否则窗口会卡在竖屏 / 不显示，要切后台才转正）。
    UIWindow *window = nil;
    if (@available(iOS 13.0, *)) {
        UIWindowScene *scene = [self activeWindowScene];
        if (scene && [UIWindow instancesRespondToSelector:@selector(initWithWindowScene:)]) {
            window = [[UIWindow alloc] initWithWindowScene:scene];
        }
    }
    if (!window) window = [[UIWindow alloc] initWithFrame:[UIScreen mainScreen].bounds];
    _window = window;
    // 关键：整窗不接收触摸事件 -> 全部穿透到游戏
    _window.userInteractionEnabled = NO;
    _window.windowLevel = UIWindowLevelStatusBar + 100;
    _window.backgroundColor = [UIColor clearColor];
    _window.hidden = YES;   // 先隐藏；等 App 真正进入前台（didBecomeActive）后由 applyVisibility 显示，
                            // 否则 launch 阶段挂在未激活窗口上会一直不显示，要手动开关一次才出
    _window.rootViewController = [[SoloXRootVC alloc] init];

    UIView *rootView = _window.rootViewController.view;

    _bar = [[UIView alloc] init];
    _bar.translatesAutoresizingMaskIntoConstraints = NO;
    _bar.backgroundColor = [UIColor colorWithWhite:0.0 alpha:0.55];
    _bar.layer.cornerRadius = 6;            // 自身小圆角，避免和屏幕圆角打架
    _bar.clipsToBounds = YES;
    [rootView addSubview:_bar];
    // 钉在窗口自身 bounds 上（align 把窗口铺满屏幕，scene 负责把它转到正确方向）；
    // 不用 safeAreaLayoutGuide，避免随界面方向变化时安全区计算错位。
    // 顶部距离由 align() 动态算：竖屏让出刘海/灵动岛，横屏贴顶 8pt。
    // 两侧留 16pt 空白，避免被屏幕物理圆角把性能条两侧圆角裁掉。
    _barTop = [_bar.topAnchor constraintEqualToAnchor:rootView.topAnchor constant:8];
    [NSLayoutConstraint activateConstraints:@[
        _barTop,
        [_bar.leadingAnchor constraintEqualToAnchor:rootView.leadingAnchor constant:16],
        [_bar.trailingAnchor constraintEqualToAnchor:rootView.trailingAnchor constant:-16],
        [_bar.heightAnchor constraintEqualToConstant:22],
    ]];

    UIFont *font = [UIFont monospacedDigitSystemFontOfSize:11 weight:UIFontWeightMedium];
    UIColor *fg = [UIColor colorWithRed:0.40 green:1.0 blue:0.50 alpha:1.0];   // 绿色字体

    _cpu = [self makeLabel:font fg:fg];
    _mem = [self makeLabel:font fg:fg];
    _net = [self makeLabel:font fg:fg];
    _fps = [self makeLabel:font fg:fg];
    _bat = [self makeLabel:font fg:fg];
    _temp = [self makeLabel:font fg:fg];

    UIStackView *stack = [[UIStackView alloc] initWithArrangedSubviews:@[_cpu, _mem, _net, _fps, _bat, _temp]];
    stack.translatesAutoresizingMaskIntoConstraints = NO;
    stack.axis = UILayoutConstraintAxisHorizontal;
    stack.alignment = UIStackViewAlignmentCenter;
    stack.distribution = UIStackViewDistributionEqualSpacing;
    stack.spacing = 10;
    [stack setLayoutMarginsRelativeArrangement:YES];
    stack.layoutMargins = UIEdgeInsetsMake(0, 6, 0, 6);
    [_bar addSubview:stack];
    [NSLayoutConstraint activateConstraints:@[
        [stack.topAnchor constraintEqualToAnchor:_bar.topAnchor],
        [stack.bottomAnchor constraintEqualToAnchor:_bar.bottomAnchor],
        [stack.leadingAnchor constraintEqualToAnchor:_bar.leadingAnchor],
        [stack.trailingAnchor constraintEqualToAnchor:_bar.trailingAnchor],
    ]];

    // 不 makeKeyAndVisible：保持游戏为 key 窗口，游戏窗口的旋转 transform 才不会被系统收回
    [self align];
}

- (UILabel *)makeLabel:(UIFont *)font fg:(UIColor *)fg {
    UILabel *l = [[UILabel alloc] init];
    l.font = font;
    l.textColor = fg;
    l.text = @"--";
    l.userInteractionEnabled = NO;   // 子视图也不拦截，确保穿透
    return l;
}

- (void)align {
    // 直接对齐到游戏主窗口的实际几何与旋转（抄它的 bounds/center/transform），
    // 不依赖 scene/状态栏方向：横屏游戏锁方向、或自己转 transform 时都不会跑偏。
    // 拿不到游戏窗口（冷启动瞬间）就退回按屏幕尺寸铺满。
    UIWindow *app = IPATAppKeyWindowExcluding(_window);
    IPATAlignWindowToInterface(_window, app);

    // 顶部距离：竖屏时刘海/灵动岛（约 50-60pt）会正好压在 top+8 的性能条上，
    // 数据文字全被遮住（看起来就是一条没有字的半透明条）；横屏时刘海在侧边，
    // 贴顶即可。窗口是抄游戏旋转的，transform 非单位阵 = 显示上是横屏。
    BOOL rotated = !CGAffineTransformIsIdentity(_window.transform);
    BOOL portrait = !rotated && _window.bounds.size.height > _window.bounds.size.width;
    CGFloat top = 8.0;
    if (portrait) {
        CGFloat safeTop = 0;
        if (@available(iOS 11.0, *)) {
            // 优先读游戏窗口的安全区（未旋转、数值可靠），拿不到再读自己的。
            // 两种来源都可能给出未结算的异常值（窗口刚重建/scene 刚激活时），
            // 超过 200pt 的一律不采用——顶条被推出屏幕外比贴顶更糟
            UIWindow *src = app ?: _window;
            safeTop = src.safeAreaInsets.top;
            if (safeTop <= 0 || safeTop > 200) safeTop = _window.safeAreaInsets.top;
            if (safeTop <= 0 || safeTop > 200) safeTop = 0;
        }
        top = MAX(top, safeTop + 4.0);
    }
    _barTop.constant = top;
}

/// 转屏动画约 0.4s，动画期间读到的 safeAreaInsets 还是旧的；
/// 等动画收尾再算一次顶部距离（align 自身幂等，多跑一次无害）
- (void)alignLate {
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{ [self align]; });
}

- (void)applyVisibility {
    // 把窗口挂到当前前台激活的 scene：launch 阶段可能挂到了未激活 scene，
    // 导致一直不显示 / 卡竖屏，激活后再挂一次即可转正
    if (@available(iOS 13.0, *)) {
        UIWindowScene *scene = [self activeWindowScene];
        if (scene && _window.windowScene != scene) _window.windowScene = scene;
    }
    _window.hidden = !_masterOn;
    _cpu.hidden = !_showCPU;
    _mem.hidden = !_showMEM;
    _net.hidden = !_showNET;
    _fps.hidden = !_showFPS;
    _bat.hidden = !_showBAT;
    _temp.hidden = !_showTEMP;
    if (_masterOn) {
        [self align];
        // 首次显示时窗口/scene 的几何和安全区可能还没结算完，同步 align 算出的
        // 位置可能是错的（性能条整个跑到屏幕外，表现为「不显示任何数据」）。
        // 延迟再对齐一次；转屏通知已有同样的 alignLate 兜底
        [self alignLate];
    }
}

#pragma mark - 注册到游戏内悬浮窗

- (void)registerPanel {
    NSDictionary *reg = @{
        IPATRegId: IPATFeatureSoloX,
        IPATRegTitle: @"性能悬浮窗",
        IPATRegDetail: @"顶部显示 CPU/内存/网络/FPS/电量/温度（穿透点击）",
        IPATRegMasterKey: IPATKeySoloXEnabled,
        IPATRegEnabled: @(_masterOn),
        IPATRegRows: @[
            // CPU/内存/网络/FPS/电量/温度子开关已简化掉：恒开
            @{IPATRowKey: IPATKeySoloXExport, IPATRowTitle: @"导出报告", IPATRowKind: IPATRowKindAction},
        ],
    };
    [[NSNotificationCenter defaultCenter] postNotificationName:IPATControlRegisterNotification
                                                        object:nil
                                                      userInfo:reg];
}

- (void)observe {
    NSNotificationCenter *c = [NSNotificationCenter defaultCenter];
    [c addObserver:self selector:@selector(handleChange:)   name:IPATControlDidChangeNotification object:nil];
    [c addObserver:self selector:@selector(handleAction:)   name:IPATControlActionNotification object:nil];
    [c addObserver:self selector:@selector(handleDiscover:) name:IPATControlDiscoverNotification object:nil];
    [c addObserver:self selector:@selector(align)          name:UIDeviceOrientationDidChangeNotification object:nil];
    [c addObserver:self selector:@selector(alignLate)      name:UIDeviceOrientationDidChangeNotification object:nil];
    // App 进入前台 / scene 激活后再显示并对齐一次：解决「启动不显示 + 横屏不转正」
    [c addObserver:self selector:@selector(applyVisibility) name:UIApplicationDidBecomeActiveNotification object:nil];
    if (@available(iOS 13.0, *)) {
        [c addObserver:self selector:@selector(applyVisibility) name:UISceneDidActivateNotification object:nil];
        [c addObserver:self selector:@selector(applyVisibility) name:UISceneWillEnterForegroundNotification object:nil];
    }
    [[UIDevice currentDevice] beginGeneratingDeviceOrientationNotifications];
}

- (void)handleDiscover:(NSNotification *)note {
    [self registerPanel];   // 面板可能比本 dylib 晚加载，收到重注册请求后补一次
}

- (void)handleChange:(NSNotification *)note {
    if (![note.userInfo[IPATChgId] isEqualToString:IPATFeatureSoloX]) return;
    NSNumber *en = note.userInfo[IPATChgEnabled];
    if (en) _masterOn = en.boolValue;
    // 子项开关已移除，全部恒开，不再读面板值
    _showCPU = _showMEM = _showNET = _showFPS = _showBAT = _showTEMP = YES;
    [self applyVisibility];
}

- (void)handleAction:(NSNotification *)note {
    if (![note.userInfo[IPATActKey] isEqualToString:IPATKeySoloXExport]) return;
    [self exportReport];
}

#pragma mark - 报告导出

- (void)exportReport {
    if (_samples.count == 0) {
        [self alertWithTitle:@"暂无数据"
                     message:@"性能窗开启并运行一段时间后才有采样可导出。"];
        return;
    }
    // 拼内嵌数据：var data=[{t,cpu,mem,net,fps,bat,temp},...]（读不到的以 null 表示断点）
    NSMutableString *dataJS = [NSMutableString stringWithString:@"var data=["];
    for (NSDictionary *s in _samples) {
        double cpu  = [s[@"cpu"]  doubleValue];
        double mem  = [s[@"mem"]  doubleValue];
        uint64_t net = [s[@"net"] unsignedLongLongValue];
        double fps  = [s[@"fps"]  doubleValue];
        double bat  = [s[@"bat"]  doubleValue];
        double temp = [s[@"temp"] doubleValue];
        [dataJS appendFormat:@"{t:\"%@\",cpu:%@,mem:%@,net:%llu,fps:%@,bat:%@,temp:%@},",
            s[@"t"],
            cpu  >= 0 ? @(cpu)  : @"null",
            mem  >= 0 ? @(mem)  : @"null",
            net,
            @(fps),
            bat  >= 0 ? @(bat)  : @"null",
            temp >= 0 ? @(temp) : @"null"];
    }
    [dataJS appendString:@"];"];

    NSDate *now = [NSDate date];
    NSDateFormatter *stamp = [[NSDateFormatter alloc] init];
    stamp.dateFormat = @"yyyyMMdd_HHmmss";
    stamp.locale = [NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"];
    NSDateFormatter *disp = [[NSDateFormatter alloc] init];
    disp.dateFormat = @"yyyy-MM-dd HH:mm:ss";
    disp.locale = [NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"];
    NSString *stampStr = [stamp stringFromDate:now];
    NSString *dispStr  = [disp stringFromDate:now];

    NSString *head = [NSString stringWithFormat:
        @"<!doctype html><html lang=\"zh\"><head><meta charset=\"utf-8\">"
        @"<meta name=\"viewport\" content=\"width=device-width,initial-scale=1\">"
        @"<title>SoloX 性能报告</title><style>"
        @"body{background:#0d1117;color:#e6edf3;font-family:-apple-system,Segoe UI,sans-serif;margin:0;padding:16px}"
        @"h1{font-size:18px;margin:0 0 4px}#charts{margin-top:8px}"
        @"</style></head><body><h1>SoloX 性能报告</h1>"
        @"<p style=\"color:#8b949e;font-size:13px\">样本数：%lu · 生成时间：%@</p>"
        @"<div id=\"charts\"></div>",
        (unsigned long)_samples.count, dispStr];

    NSMutableString *html = [NSMutableString string];
    [html appendString:head];
    [html appendString:@"<script>"];
    [html appendString:dataJS];
    [html appendString:kSoloXChartJS];
    [html appendString:@"</script></body></html>"];

    // 落盘到 App 沙盒 Documents（可用「文件」/Finder 取出；无 Documents 则退到 tmp）
    NSArray<NSString *> *dirs = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory,
                                                                   NSUserDomainMask, YES);
    NSString *dir = dirs.firstObject ?: NSTemporaryDirectory();
    NSString *path = [dir stringByAppendingPathComponent:
        [NSString stringWithFormat:@"SoloX_%@.html", stampStr]];
    [html writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:nil];

    // 弹系统分享：可存到「文件」、AirDrop、拷贝等
    UIActivityViewController *avc =
        [[UIActivityViewController alloc] initWithActivityItems:@[[NSURL fileURLWithPath:path]]
                                          applicationActivities:nil];
    [self presentViewController:avc];
}

// 找一个能 present 的 VC：优先游戏 key 窗口的 rootViewController（可交互），
// 否则退回我们自己的窗口。分享面板是系统独立窗口，不受我们窗口 userInteractionEnabled=NO 影响。
- (void)presentViewController:(UIViewController *)vc {
    UIViewController *presenter = nil;
    UIWindow *app = IPATAppKeyWindowExcluding(_window);
    if (app && app.rootViewController) presenter = app.rootViewController;
    if (!presenter) presenter = _window.rootViewController;
    if (!presenter) return;
    if ([UIDevice currentDevice].userInterfaceIdiom == UIUserInterfaceIdiomPad) {
        vc.popoverPresentationController.sourceView = presenter.view;
        vc.popoverPresentationController.sourceRect =
            CGRectMake(CGRectGetMidX(presenter.view.bounds),
                       CGRectGetMidY(presenter.view.bounds), 0, 0);
    }
    [presenter presentViewController:vc animated:YES completion:nil];
}

- (void)alertWithTitle:(NSString *)title message:(NSString *)message {
    UIAlertController *ac = [UIAlertController alertControllerWithTitle:title
                                                              message:message
                                                       preferredStyle:UIAlertControllerStyleAlert];
    [ac addAction:[UIAlertAction actionWithTitle:@"好的"
                                          style:UIAlertActionStyleDefault
                                        handler:nil]];
    [self presentViewController:ac];
}

#pragma mark - 指标采样

- (void)tickFPS:(CADisplayLink *)link {
    _frameCount++;   // 仅计帧；界面方向由所在 scene 负责，无需每帧手动对齐
}

- (void)refreshMetrics {
    // FPS：用上一秒的帧数
    _fpsValue = (double)_frameCount;
    _frameCount = 0;

    float cpu = [self sampleCPU];
    double mem = [self sampleMemory];
    uint64_t net = [self sampleNetwork];
    float bat = [self sampleBattery];
    float temp = [self sampleTemperature];

    if (_showCPU)  _cpu.text  = [NSString stringWithFormat:@"CPU %@%%",
                                 cpu >= 0 ? [NSNumber numberWithInt:(int)(cpu + 0.5)] : @"--"];
    if (_showMEM)  _mem.text  = [NSString stringWithFormat:@"MEM %.0fMB", mem];
    if (_showNET)  _net.text  = [NSString stringWithFormat:@"NET %@", [self fmtBytes:net]];
    if (_showFPS)  _fps.text  = [NSString stringWithFormat:@"FPS %.0f", _fpsValue];
    if (_showBAT)  _bat.text  = [NSString stringWithFormat:@"BAT %.0f%%", bat];
    if (_showTEMP) _temp.text = [NSString stringWithFormat:@"TEMP %@℃",
                                 temp >= 0 ? [NSNumber numberWithInt:(int)(temp + 0.5)] : @"--"];

    // 记录当次运行采样（每秒一条，封顶 3600 = 1 小时，超出丢弃最旧）
    if (!_tsFormatter) {
        _tsFormatter = [[NSDateFormatter alloc] init];
        _tsFormatter.dateFormat = @"HH:mm:ss";
        _tsFormatter.locale = [NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"];
    }
    if (!_samples) _samples = [NSMutableArray array];
    [_samples addObject:@{
        @"t":   [_tsFormatter stringFromDate:[NSDate date]],
        @"cpu": @(cpu),
        @"mem": @(mem),
        @"net": @(net),
        @"fps": @(_fpsValue),
        @"bat": @(bat),
        @"temp":@(temp),
    }];
    if (_samples.count > 3600) [_samples removeObjectAtIndex:0];

    // 每拍顺带对齐一次：游戏窗口出现得比我们晚、或生命周期通知被错过时，
    // 也能在 1 秒内自动转正/铺满，不必靠后台切换或手动开关。（align 内部对未变化会跳过）
    if (_masterOn) [self align];
}

// 进程 CPU：汇总所有线程时间，按采样间隔求增量，再除以活跃核数归一。
- (float)sampleCPU {
    thread_act_array_t threads;
    mach_msg_type_number_t count = 0;
    if (task_threads(mach_task_self(), &threads, &count) != KERN_SUCCESS) return -1;
    uint64_t total = 0;
    for (mach_msg_type_number_t i = 0; i < count; i++) {
        thread_basic_info_data_t info;
        mach_msg_type_number_t tc = THREAD_BASIC_INFO_COUNT;
        if (thread_info(threads[i], THREAD_BASIC_INFO, (thread_info_t)&info, &tc) == KERN_SUCCESS) {
            if ((info.flags & TH_FLAGS_IDLE) == 0) {
                total += info.user_time.seconds * 1e6 + info.user_time.microseconds;
                total += info.system_time.seconds * 1e6 + info.system_time.microseconds;
            }
        }
    }
    vm_deallocate(mach_task_self(), (vm_address_t)threads, count * sizeof(thread_act_t));

    CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
    float cpu = -1;
    if (_lastCPUTime > 0 && _lastCPU > 0) {
        double dt = now - _lastCPUTime;
        if (dt > 0) {
            cpu = (double)(total - _lastCPU) / (dt * 1e6) * 100.0 / (float)[self activeCPU];
            if (cpu < 0) cpu = 0;
            if (cpu > 100) cpu = 100;
        }
    }
    _lastCPU = total;
    _lastCPUTime = now;
    return cpu;
}

- (int)activeCPU {
    int n = 1;
    size_t len = sizeof(n);
    sysctlbyname("hw.activecpu", &n, &len, NULL, 0);
    return n > 0 ? n : 1;
}

// 内存 footprint（MB）
- (double)sampleMemory {
    task_vm_info_data_t info;
    mach_msg_type_number_t count = TASK_VM_INFO_COUNT;
    if (task_info(mach_task_self(), TASK_VM_INFO, (task_info_t)&info, &count) == KERN_SUCCESS) {
        return (double)info.phys_footprint / (1024.0 * 1024.0);
    }
    return -1;
}

// 网络：getifaddrs 取系统级 RX/TX 字节增量（整机近似，非单 App；iOS 无公开单 App API）。
// 精确单 App 需私有 NStat，留作后续。
- (uint64_t)sampleNetwork {
    uint64_t total = 0;
    struct ifaddrs *ifa = NULL;
    if (getifaddrs(&ifa) == 0) {
        for (struct ifaddrs *c = ifa; c; c = c->ifa_next) {
            if (c->ifa_addr && c->ifa_addr->sa_family == AF_LINK) {
                struct if_data *d = (struct if_data *)c->ifa_data;
                if (d) total += d->ifi_ibytes + d->ifi_obytes;
            }
        }
        freeifaddrs(ifa);
    }
    uint64_t delta = (_lastNet > 0 && total >= _lastNet) ? (total - _lastNet) : 0;
    _lastNet = total;
    return delta;
}

- (NSString *)fmtBytes:(uint64_t)b {
    if (b < 1024) return [NSString stringWithFormat:@"%lluB/s", b];
    if (b < 1024 * 1024) return [NSString stringWithFormat:@"%.1fKB/s", b / 1024.0];
    return [NSString stringWithFormat:@"%.2fMB/s", b / (1024.0 * 1024.0)];
}

- (float)sampleBattery {
    UIDevice *dev = UIDevice.currentDevice;
    dev.batteryMonitoringEnabled = YES;
    return dev.batteryLevel * 100.0f;
}

// 温度：通过 IOKit 读电源/电池/PMU 的 Temperature（私有属性，非越狱可用）。
// iOS 13+ 用 IOMainPort 取代 IOMasterPort（iOS 17+ 后 IOMasterPort 符号被移除），两个都试。
// 多个服务名 / 键名兜底，应对不同机型与 iOS 版本；部分来源单位是 0.1℃，
// 读数 > 150℃ 视为该单位并 ÷10。读不到回退 -1（界面显示 --）。
- (float)sampleTemperature {
    float temp = -1;
    void *io = dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_LAZY);
    if (!io) return -1;
    typedef void *(*MachPortPtr)(mach_port_t, void *);
    typedef void *(*MatchPtr)(const char *);
    typedef void *(*GetPtr)(void *, void *);
    typedef CFTypeRef (*PropPtr)(void *, CFStringRef, CFAllocatorRef, uint32_t);
    typedef kern_return_t (*RelPtr)(void *);
    // 先取 IOMainPort，取不到再回退 IOMasterPort；否则 iOS 27 上 dlsym 拿到 NULL，
    // 整个温度读取路径走不进去，界面一直显示 --（读不出来）
    MachPortPtr MachPort = dlsym(io, "IOMainPort");
    if (!MachPort) MachPort = dlsym(io, "IOMasterPort");
    MatchPtr Match = dlsym(io, "IOServiceMatching");
    GetPtr Get = dlsym(io, "IOServiceGetMatchingService");
    PropPtr Prop = dlsym(io, "IORegistryEntryCreateCFProperty");
    RelPtr Rel = dlsym(io, "IOObjectRelease");
    if (MachPort && Match && Get && Prop && Rel) {
        void *port = NULL;
        MachPort(0, &port);
        if (port) {
            // 依次尝试不同温度传感器服务；iOS 27 上 IOPMPowerSource 可能被沙盒限制，
            // 退而求其次读 PMU / RTC 的温度服务
            const char *services[] = {"IOPMPowerSource", "IOPMUPowerSource", "AppleARMPMURTC", NULL};
            const char *keys[] = {"Temperature", "temperature", "current-temperature", "AvgTemperature", NULL};
            for (int s = 0; services[s]; s++) {
                void *svc = Get(port, Match(services[s]));
                if (!svc) continue;
                for (int k = 0; keys[k]; k++) {
                    CFStringRef keyRef = CFStringCreateWithCString(kCFAllocatorDefault,
                                                                  keys[k], kCFStringEncodingUTF8);
                    if (!keyRef) continue;
                    CFTypeRef v = Prop(svc, keyRef, kCFAllocatorDefault, 0);
                    if (v) {
                        if (CFGetTypeID(v) == CFNumberGetTypeID()) {
                            float raw = 0;
                            CFNumberGetValue((CFNumberRef)v, kCFNumberFloatType, &raw);
                            if (raw > 150.0f) raw /= 10.0f;   // 0.1℃ 单位修正
                            if (raw > 0 && raw <= 150.0f) temp = raw;
                        }
                        CFRelease(v);
                    }
                    CFRelease(keyRef);
                    if (temp > 0) break;
                }
                Rel(svc);
                if (temp > 0) break;
            }
        }
    }
    dlclose(io);
    return temp;
}

@end
