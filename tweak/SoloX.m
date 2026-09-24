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
#import "IPATControlShared.h"
#import <UIKit/UIKit.h>
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
#define IPAToolSoloXPlistKey @"IPAToolSoloX"              // Info.plist 初始配置字典

@interface SoloXMonitor : NSObject
+ (void)loadPlugin;
- (void)applyVisibility;
- (void)refreshMetrics;
@end

@implementation SoloXMonitor {
    UIWindow *_window;
    UIView *_bar;
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
    _masterOn = [self boolForKey:IPATKeySoloXEnabled plistSub:@"Enabled" dflt:YES];
    _showCPU = [self boolForKey:IPATKeySoloXCPU dflt:YES];
    _showMEM = [self boolForKey:IPATKeySoloXMEM dflt:YES];
    _showNET = [self boolForKey:IPATKeySoloXNET dflt:YES];
    _showFPS = [self boolForKey:IPATKeySoloXFPS dflt:YES];
    _showBAT = [self boolForKey:IPATKeySoloXBAT dflt:YES];
    _showTEMP = [self boolForKey:IPATKeySoloXTEMP dflt:YES];

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

- (void)buildWindow {
    _window = [[UIWindow alloc] initWithFrame:[UIScreen mainScreen].bounds];
    // 关键：整窗不接收触摸事件 -> 全部穿透到游戏
    _window.userInteractionEnabled = NO;
    _window.windowLevel = UIWindowLevelStatusBar + 100;
    _window.backgroundColor = [UIColor clearColor];
    _window.hidden = !_masterOn;
    _window.rootViewController = [[UIViewController alloc] init];

    _bar = [[UIView alloc] initWithFrame:CGRectMake(0, 0, _window.bounds.size.width, 22)];
    _bar.autoresizingMask = UIViewAutoresizingFlexibleWidth;
    _bar.backgroundColor = [UIColor colorWithWhite:0.0 alpha:0.55];
    [_window.rootViewController.view addSubview:_bar];

    UIFont *font = [UIFont monospacedDigitSystemFontOfSize:11 weight:UIFontWeightMedium];
    UIColor *fg = [UIColor colorWithWhite:0.95 alpha:1.0];

    _cpu = [self makeLabel:font fg:fg];
    _mem = [self makeLabel:font fg:fg];
    _net = [self makeLabel:font fg:fg];
    _fps = [self makeLabel:font fg:fg];
    _bat = [self makeLabel:font fg:fg];
    _temp = [self makeLabel:font fg:fg];

    UIStackView *stack = [[UIStackView alloc] initWithArrangedSubviews:@[_cpu, _mem, _net, _fps, _bat, _temp]];
    stack.axis = UILayoutConstraintAxisHorizontal;
    stack.alignment = UIStackViewAlignmentCenter;
    stack.distribution = UIStackViewDistributionEqualSpacing;
    stack.spacing = 10;
    stack.frame = CGRectMake(8, 0, _bar.bounds.size.width - 16, _bar.bounds.size.height);
    stack.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    [_bar addSubview:stack];

    [_window makeKeyAndVisible];
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
    // 横屏游戏里窗口被转过，照抄主窗口的方向/坐标，保证性能条贴在屏幕顶部
    UIWindow *app = IPATAppKeyWindowExcluding(_window);
    IPATAlignWindowToInterface(_window, app);
}

- (void)applyVisibility {
    _window.hidden = !_masterOn;
    _cpu.hidden = !_showCPU;
    _mem.hidden = !_showMEM;
    _net.hidden = !_showNET;
    _fps.hidden = !_showFPS;
    _bat.hidden = !_showBAT;
    _temp.hidden = !_showTEMP;
    if (_masterOn) [self align];
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
            @{IPATRowKey: IPATKeySoloXCPU,  IPATRowTitle: @"CPU",  IPATRowKind: IPATRowKindSwitch, IPATRowValue: @(_showCPU)},
            @{IPATRowKey: IPATKeySoloXMEM,  IPATRowTitle: @"内存", IPATRowKind: IPATRowKindSwitch, IPATRowValue: @(_showMEM)},
            @{IPATRowKey: IPATKeySoloXNET,  IPATRowTitle: @"网络", IPATRowKind: IPATRowKindSwitch, IPATRowValue: @(_showNET)},
            @{IPATRowKey: IPATKeySoloXFPS,  IPATRowTitle: @"FPS",  IPATRowKind: IPATRowKindSwitch, IPATRowValue: @(_showFPS)},
            @{IPATRowKey: IPATKeySoloXBAT,  IPATRowTitle: @"电量", IPATRowKind: IPATRowKindSwitch, IPATRowValue: @(_showBAT)},
            @{IPATRowKey: IPATKeySoloXTEMP, IPATRowTitle: @"温度", IPATRowKind: IPATRowKindSwitch, IPATRowValue: @(_showTEMP)},
        ],
    };
    [[NSNotificationCenter defaultCenter] postNotificationName:IPATControlRegisterNotification
                                                        object:nil
                                                      userInfo:reg];
}

- (void)observe {
    NSNotificationCenter *c = [NSNotificationCenter defaultCenter];
    [c addObserver:self selector:@selector(handleChange:)   name:IPATControlDidChangeNotification object:nil];
    [c addObserver:self selector:@selector(handleDiscover:) name:IPATControlDiscoverNotification object:nil];
    [c addObserver:self selector:@selector(align)          name:UIDeviceOrientationDidChangeNotification object:nil];
    [[UIDevice currentDevice] beginGeneratingDeviceOrientationNotifications];
}

- (void)handleDiscover:(NSNotification *)note {
    [self registerPanel];   // 面板可能比本 dylib 晚加载，收到重注册请求后补一次
}

- (void)handleChange:(NSNotification *)note {
    if (![note.userInfo[IPATChgId] isEqualToString:IPATFeatureSoloX]) return;
    NSNumber *en = note.userInfo[IPATChgEnabled];
    if (en) _masterOn = en.boolValue;
    NSDictionary *vals = note.userInfo[IPATChgValues];
    if ([vals isKindOfClass:[NSDictionary class]]) {
        if (vals[IPATKeySoloXCPU])  _showCPU  = [vals[IPATKeySoloXCPU]  boolValue];
        if (vals[IPATKeySoloXMEM])  _showMEM  = [vals[IPATKeySoloXMEM]  boolValue];
        if (vals[IPATKeySoloXNET])  _showNET  = [vals[IPATKeySoloXNET]  boolValue];
        if (vals[IPATKeySoloXFPS])  _showFPS  = [vals[IPATKeySoloXFPS]  boolValue];
        if (vals[IPATKeySoloXBAT])  _showBAT  = [vals[IPATKeySoloXBAT]  boolValue];
        if (vals[IPATKeySoloXTEMP]) _showTEMP = [vals[IPATKeySoloXTEMP] boolValue];
    }
    [self applyVisibility];
}

#pragma mark - 指标采样

- (void)tickFPS:(CADisplayLink *)link {
    _frameCount++;
}

- (void)refreshMetrics {
    [self align];

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

// 温度：通过 IOKit 读电源/电池 Temperature（私有属性，非越狱可用）。失败回退 --。
- (float)sampleTemperature {
    float temp = -1;
    void *io = dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_LAZY);
    if (!io) return -1;
    typedef void *(*MachPortPtr)(mach_port_t, void *);
    typedef void *(*MatchPtr)(const char *);
    typedef void *(*GetPtr)(void *, void *);
    typedef CFTypeRef (*PropPtr)(void *, CFStringRef, CFAllocatorRef, uint32_t);
    typedef kern_return_t (*RelPtr)(void *);
    MachPortPtr MachPort = dlsym(io, "IOMasterPort");
    MatchPtr Match = dlsym(io, "IOServiceMatching");
    GetPtr Get = dlsym(io, "IOServiceGetMatchingService");
    PropPtr Prop = dlsym(io, "IORegistryEntryCreateCFProperty");
    RelPtr Rel = dlsym(io, "IOObjectRelease");
    if (MachPort && Match && Get && Prop && Rel) {
        void *port = NULL;
        MachPort(0, &port);
        void *svc = Get(port, Match("IOPMPowerSource"));
        if (svc) {
            CFTypeRef v = Prop(svc, CFSTR("Temperature"), kCFAllocatorDefault, 0);
            if (v) {
                if (CFGetTypeID(v) == CFNumberGetTypeID())
                    CFNumberGetValue((CFNumberRef)v, kCFNumberFloatType, &temp);
                CFRelease(v);
            }
            Rel(svc);
        }
    }
    dlclose(io);
    return temp;
}

@end
