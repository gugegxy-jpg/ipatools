//
//  KeepAlive.m
//  ipatool 注入用 dylib：让 App 切到后台后**继续运行**（典型场景：游戏切后台继续热更/下载）。
//
//  前提（ipatool inject --keep-alive 会自动处理）：
//    1. dylib 被放进 App.app/Frameworks/ 并在主可执行文件里加了对应 LC_LOAD_DYLIB
//    2. Info.plist 的 UIBackgroundModes 里包含 audio（定位/定时唤醒模式另外加 location/fetch/processing）
//    3. 重新签名（未签名/描述文件不匹配的包装不上）
//
//  保活手段（按可靠性从高到低，前两项默认开启）：
//    1) 静音音频：以 .playback 类别循环播放一段全 0 采样的音频。
//       iOS 只要认为 App 在播放音频，就不会把进程挂起 —— 这是最稳定的保活方式。
//    2) 后台任务续期：不断 beginBackgroundTask，作为音频被抢断（电话/其它 App）时的兜底。
//    3) 定位更新：CLLocationManager 后台定位（需要用户授权，耗电，App Store 会拒，仅自用/内部分发）。
//    4) 定时唤醒：注册 BGAppRefreshTask / BGProcessingTask，被系统唤醒后再续注册。
//       注意：这只是把进程唤醒，是否继续下载取决于 App 自己的逻辑。
//
//  可通过 Info.plist 的 IPAToolKeepAlive 字典调整行为：
//    Enabled(bool)              默认 YES
//    SilentAudio(bool)          默认 YES，静音音频保活
//    StartAtLaunch(bool)        默认 YES；NO 表示等切到后台再开始播（更省电，但不如 YES 稳）
//    AudioFile(string)          改用 App 包内的音频文件循环播放（如近乎无声的底噪，更"像"在播放）
//    Volume(double)             默认不设置（音频本身是全 0 采样）
//    RenewBackgroundTask(bool)  默认 YES，续期 beginBackgroundTask
//    RenewLeadTime(double)      默认 10，提前多少秒续期
//    Location(bool)             默认 NO，用后台定位保活
//    LocationIndicator(bool)    默认 NO，是否显示定位蓝色指示条
//    Fetch(bool)                默认 NO，注册 BGAppRefreshTask
//    Processing(bool)           默认 NO，注册 BGProcessingTask
//    RefreshInterval(integer)   默认 900（秒），定时唤醒的最短间隔
//    Log(bool)                  默认 YES，打印 [ipatool-keepalive] 日志
//
//  运行时开关：
//    注入 ControlPanel.dylib 后 App 里会出现悬浮窗，点开即可实时开关保活及其子选项，
//    面板写入的值存在 NSUserDefaults 里，优先级高于上面的 Info.plist 初始值。
//    注意：定时唤醒的 launch handler 只能在启动阶段注册，所以「定时唤醒」开关
//    打开后要下次启动才真正生效（关闭是立刻生效的），面板上会显示当前状态。
//
//  ⚠️ 保活是"尽力而为"：低电量模式、系统内存回收、用户上滑杀掉进程都会终止它；
//     并且很多游戏自己会在 applicationDidEnterBackground 里主动暂停热更逻辑，
//     这种情况下注入只能保证进程不被挂起，无法改变 App 自身的暂停行为。
//

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <AVFoundation/AVFoundation.h>
#import <CoreLocation/CoreLocation.h>
#import <BackgroundTasks/BackgroundTasks.h>
#import "IPATControlShared.h"

#pragma mark - 配置

static NSDictionary *IPATKAConfig(void) {
    static NSDictionary *cfg;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        id value = [[NSBundle mainBundle] objectForInfoDictionaryKey:@"IPAToolKeepAlive"];
        cfg = [value isKindOfClass:[NSDictionary class]] ? value : @{};
    });
    return cfg;
}

/// Info.plist 键 -> 悬浮面板写入的 NSUserDefaults 键（面板没改过则返回 nil，回落 plist）
static NSString *IPATKAPanelKey(NSString *plistKey) {
    if (plistKey.length == 0) return nil;
    static NSDictionary *map;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        map = @{
            @"Enabled": IPATKeyKAEnabled,
            @"SilentAudio": IPATKeyKASilentAudio,
            @"RenewBackgroundTask": IPATKeyKARenew,
            @"Fetch": IPATKeyKAFetch,
            @"Location": IPATKeyKALocation,
        };
    });
    return map[plistKey];
}

static id IPATKAValue(NSString *key) {
    // 面板里改过的值优先于 Info.plist 的初始值
    NSString *panelKey = IPATKAPanelKey(key);
    if (panelKey) {
        id override = [[NSUserDefaults standardUserDefaults] objectForKey:panelKey];
        if (override) return [override isKindOfClass:[NSNull class]] ? nil : override;
    }
    id value = IPATKAConfig()[key];
    return [value isKindOfClass:[NSNull class]] ? nil : value;
}

static BOOL IPATKABool(NSString *key, BOOL fallback) {
    id value = IPATKAValue(key);
    return [value respondsToSelector:@selector(boolValue)] ? [value boolValue] : fallback;
}

static double IPATKADouble(NSString *key, double fallback) {
    id value = IPATKAValue(key);
    return [value respondsToSelector:@selector(doubleValue)] ? [value doubleValue] : fallback;
}

static NSInteger IPATKAInt(NSString *key, NSInteger fallback) {
    id value = IPATKAValue(key);
    return [value respondsToSelector:@selector(integerValue)] ? [value integerValue] : fallback;
}

static NSString *IPATKAString(NSString *key) {
    id value = IPATKAValue(key);
    return [value isKindOfClass:[NSString class]] ? value : nil;
}

#define IPATKALog(fmt, ...) \
    do { if (IPATKABool(@"Log", YES)) NSLog(@"[ipatool-keepalive] " fmt, ##__VA_ARGS__); } while (0)

static NSString *const IPATKARefreshTaskID = @"com.ipatool.keepalive.refresh";
static NSString *const IPATKAProcessingTaskID = @"com.ipatool.keepalive.processing";

#pragma mark - 工具

/// 生成一段内存中的静音 WAV（16bit / 单声道），避免往包里塞素材文件
static NSData *IPATKASilentWAV(double seconds, uint32_t sampleRate) {
    uint32_t samples = (uint32_t)(seconds * sampleRate);
    uint32_t dataSize = samples * 2;
    uint8_t header[44] = {0};
    uint32_t riffSize = 36 + dataSize;
    uint32_t fmtSize = 16;
    uint16_t audioFormat = 1, channels = 1, bitsPerSample = 16, blockAlign = 2;
    uint32_t byteRate = sampleRate * 2;

    memcpy(header, "RIFF", 4);
    memcpy(header + 4, &riffSize, 4);
    memcpy(header + 8, "WAVEfmt ", 8);
    memcpy(header + 16, &fmtSize, 4);
    memcpy(header + 20, &audioFormat, 2);
    memcpy(header + 22, &channels, 2);
    memcpy(header + 24, &sampleRate, 4);
    memcpy(header + 28, &byteRate, 4);
    memcpy(header + 32, &blockAlign, 2);
    memcpy(header + 34, &bitsPerSample, 2);
    memcpy(header + 36, "data", 4);
    memcpy(header + 40, &dataSize, 4);

    NSMutableData *data = [NSMutableData dataWithCapacity:44 + dataSize];
    [data appendBytes:header length:44];
    [data appendData:[NSMutableData dataWithLength:dataSize]];
    return data;
}

#pragma mark - 保活控制器

@interface IPATKeepAliveController : NSObject <CLLocationManagerDelegate>
@property (nonatomic, strong) AVAudioPlayer *player;
@property (nonatomic, strong) NSTimer *renewTimer;
@property (nonatomic, assign) UIBackgroundTaskIdentifier task;
@property (nonatomic, strong) CLLocationManager *location;
@property (nonatomic, assign) BOOL started;
@property (nonatomic, assign) BOOL schedulerRegistered;
@property (nonatomic, assign) BOOL fetchRegistered;
@property (nonatomic, assign) BOOL processingRegistered;
@property (nonatomic, assign) NSUInteger renewCount;
@end

@implementation IPATKeepAliveController

+ (instancetype)shared {
    static IPATKeepAliveController *shared;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ shared = [[IPATKeepAliveController alloc] init]; });
    return shared;
}

- (instancetype)init {
    if ((self = [super init])) {
        _task = UIBackgroundTaskInvalid;
        NSNotificationCenter *center = [NSNotificationCenter defaultCenter];
        [center addObserver:self
                   selector:@selector(handleDidEnterBackground)
                       name:UIApplicationDidEnterBackgroundNotification
                     object:nil];
        [center addObserver:self
                   selector:@selector(handleWillEnterForeground)
                       name:UIApplicationWillEnterForegroundNotification
                     object:nil];
        [center addObserver:self
                   selector:@selector(handleAudioInterruption:)
                       name:AVAudioSessionInterruptionNotification
                     object:nil];
        [center addObserver:self
                   selector:@selector(handleMediaServicesReset:)
                       name:AVAudioSessionMediaServicesWereResetNotification
                     object:nil];
        [center addObserver:self
                   selector:@selector(handleRouteChange:)
                       name:AVAudioSessionRouteChangeNotification
                     object:nil];
        // 悬浮控制面板
        [center addObserver:self
                   selector:@selector(handlePanelChange:)
                       name:IPATControlDidChangeNotification
                     object:nil];
        [center addObserver:self
                   selector:@selector(handlePanelDiscover:)
                       name:IPATControlDiscoverNotification
                     object:nil];
    }
    return self;
}

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

#pragma mark 启动

- (void)start {
    if (!IPATKABool(@"Enabled", YES)) return;
    if (self.started) return;
    self.started = YES;
    IPATKALog(@"启用保活：silentAudio=%d renew=%d location=%d fetch=%d processing=%d",
              IPATKABool(@"SilentAudio", YES),
              IPATKABool(@"RenewBackgroundTask", YES),
              IPATKABool(@"Location", NO),
              IPATKABool(@"Fetch", NO),
              IPATKABool(@"Processing", NO));

    if (IPATKABool(@"SilentAudio", YES)) {
        [self activateAudioSession];
        [self startSilentAudio];
    }
    if (IPATKABool(@"RenewBackgroundTask", YES)) {
        [self startRenewTimer];
    }
    if (IPATKABool(@"Location", NO)) {
        [self startLocation];
    }
    [self registerSchedulerTasksIfNeeded];
    [self postStatus];
}

/// 完全停止保活（面板把开关关掉时调用）
- (void)stop {
    if (!self.started) return;
    self.started = NO;
    [self stopSilentAudio];
    [self.renewTimer invalidate];
    self.renewTimer = nil;
    [self endBackgroundTask];
    [self stopLocation];
    [self cancelSchedulerTasks];
    IPATKALog(@"保活已停止");
}

#pragma mark 悬浮控制面板

/// 面板改了开关：重新读一遍配置，把变化立刻落到运行状态上
- (void)applyPanelState {
    if (!IPATKABool(@"Enabled", YES)) {
        [self stop];
        [self postStatus];
        return;
    }
    if (!self.started) [self start];
    if (!self.started) return;

    if (IPATKABool(@"SilentAudio", YES)) {
        [self activateAudioSession];
        [self startSilentAudio];
    } else {
        [self stopSilentAudio];
    }
    if (IPATKABool(@"RenewBackgroundTask", YES)) {
        [self startRenewTimer];
    } else {
        [self.renewTimer invalidate];
        self.renewTimer = nil;
        [self endBackgroundTask];
    }
    if (IPATKABool(@"Location", NO)) {
        [self startLocation];
    } else {
        [self stopLocation];
    }
    [self applySchedulerState];
    [self postStatus];
}

- (void)handlePanelChange:(NSNotification *)note {
    if (![note.userInfo[IPATChgId] isEqual:IPATFeatureKeepAlive]) return;
    [self applyPanelState];
}

- (void)handlePanelDiscover:(NSNotification *)note {
    [self registerWithPanel];
}

/// 把我的开关和能力报给面板，面板按这个生成界面
- (void)registerWithPanel {
    NSDictionary *reg = @{
        IPATRegId: IPATFeatureKeepAlive,
        IPATRegTitle: @"后台保活",
        IPATRegDetail: @"切后台后进程不被挂起",
        IPATRegMasterKey: IPATKeyKAEnabled,
        IPATRegEnabled: @(IPATKABool(@"Enabled", YES)),
        IPATRegRows: @[
            @{IPATRowKey: IPATKeyKASilentAudio,
              IPATRowTitle: @"静音音频",
              IPATRowValue: @(IPATKABool(@"SilentAudio", YES))},
            @{IPATRowKey: IPATKeyKARenew,
              IPATRowTitle: @"后台任务续期",
              IPATRowValue: @(IPATKABool(@"RenewBackgroundTask", YES))},
            @{IPATRowKey: IPATKeyKAFetch,
              IPATRowTitle: @"定时唤醒",
              IPATRowValue: @(IPATKABool(@"Fetch", NO)),
              IPATRowNote: @"注册只能在启动时做，开启需重启 App"},
            @{IPATRowKey: IPATKeyKALocation,
              IPATRowTitle: @"后台定位",
              IPATRowValue: @(IPATKABool(@"Location", NO)),
              IPATRowNote: @"耗电，需「始终允许」定位权限"},
        ],
    };
    [[NSNotificationCenter defaultCenter] postNotificationName:IPATControlRegisterNotification
                                                        object:nil
                                                      userInfo:reg];
    [self postStatus];
}

/// 给面板上报一行运行状态
- (void)postStatus {
    NSString *detail;
    if (!IPATKABool(@"Enabled", YES)) {
        detail = @"已关闭";
    } else {
        NSMutableArray<NSString *> *parts = [NSMutableArray array];
        [parts addObject:(self.player.isPlaying ? @"音频播放中" : @"音频未播放")];
        if (IPATKABool(@"RenewBackgroundTask", YES)) {
            [parts addObject:[NSString stringWithFormat:@"续期 %lu 次", (unsigned long)self.renewCount]];
        }
        if (IPATKABool(@"Location", NO)) {
            [parts addObject:(self.location ? @"定位中" : @"定位待授权")];
        }
        if (IPATKABool(@"Fetch", NO) || IPATKABool(@"Processing", NO)) {
            [parts addObject:(self.fetchRegistered || self.processingRegistered)
                                 ? @"定时唤醒已注册" : @"定时唤醒重启后生效"];
        }
        detail = [parts componentsJoinedByString:@" · "];
    }
    [[NSNotificationCenter defaultCenter] postNotificationName:IPATControlStatusNotification
                                                        object:nil
                                                      userInfo:@{IPATRegId: IPATFeatureKeepAlive,
                                                                 IPATStaDetail: detail}];
}

#pragma mark 静音音频保活

- (void)activateAudioSession {
    NSError *error = nil;
    AVAudioSession *session = [AVAudioSession sharedInstance];
    // MixWithOthers：不影响用户其它 App 的声音（游戏自己配过会话也不至于互相打断）
    if (![session setCategory:AVAudioSessionCategoryPlayback
                  withOptions:AVAudioSessionCategoryOptionMixWithOthers
                        error:&error]) {
        IPATKALog(@"设置音频会话失败: %@", error.localizedDescription);
        return;
    }
    error = nil;
    if (![session setActive:YES error:&error]) {
        IPATKALog(@"激活音频会话失败: %@", error.localizedDescription);
    }
}

- (void)startSilentAudio {
    if (self.player) {
        if (!self.player.isPlaying) [self.player play];
        return;
    }

    NSError *error = nil;
    AVAudioPlayer *player = nil;
    NSString *audioFile = IPATKAString(@"AudioFile");
    if (audioFile.length > 0) {
        NSURL *url = [[NSBundle mainBundle] URLForResource:[audioFile stringByDeletingPathExtension]
                                            withExtension:[audioFile pathExtension]];
        if (url) {
            player = [[AVAudioPlayer alloc] initWithContentsOfURL:url error:&error];
            if (!player) {
                IPATKALog(@"加载 AudioFile(%@) 失败(%@)，回退到内置静音",
                          audioFile, error.localizedDescription);
                error = nil;
            }
        } else {
            IPATKALog(@"配置的 AudioFile(%@) 不存在，回退到内置静音", audioFile);
        }
    }
    if (!player) {
        // 8kHz 单声道 1 秒：够小，循环播放时几乎不占 CPU
        player = [[AVAudioPlayer alloc] initWithData:IPATKASilentWAV(1.0, 8000) error:&error];
    }
    if (error || !player) {
        IPATKALog(@"创建播放器失败: %@", error.localizedDescription ?: @"未知错误");
        return;
    }

    id volume = IPATKAValue(@"Volume");
    if ([volume respondsToSelector:@selector(doubleValue)]) {
        player.volume = (float)MAX(0.0, MIN(1.0, [volume doubleValue]));
    }
    player.numberOfLoops = -1;  // 无限循环
    player.enableRate = NO;
    if (![player play]) {
        IPATKALog(@"播放器启动失败（音频会被系统用来裁定是否挂起，这一步很关键）");
        return;
    }
    self.player = player;
    IPATKALog(@"静音保活音频已开始循环播放");
}

- (void)stopSilentAudio {
    [self.player stop];
    self.player = nil;
}

- (void)handleAudioInterruption:(NSNotification *)note {
    if (!IPATKABool(@"SilentAudio", YES)) return;
    NSNumber *type = note.userInfo[AVAudioSessionInterruptionTypeKey];
    if (type.unsignedIntegerValue == AVAudioSessionInterruptionTypeEnded) {
        IPATKALog(@"音频中断结束，恢复保活播放");
        [self activateAudioSession];
        [self startSilentAudio];
    }
}

- (void)handleMediaServicesReset:(NSNotification *)note {
    if (!IPATKABool(@"SilentAudio", YES)) return;
    IPATKALog(@"媒体服务被重置，重建保活播放器");
    [self stopSilentAudio];
    [self activateAudioSession];
    [self startSilentAudio];
}

- (void)handleRouteChange:(NSNotification *)note {
    if (!IPATKABool(@"SilentAudio", YES) || !self.player) return;
    NSNumber *reason = note.userInfo[AVAudioSessionRouteChangeReasonKey];
    if (reason.unsignedIntegerValue == AVAudioSessionRouteChangeReasonOldDeviceUnavailable
        && !self.player.isPlaying) {
        IPATKALog(@"音频路由变化后播放停止，重新播放");
        [self activateAudioSession];
        [self startSilentAudio];
    }
}

#pragma mark 后台任务续期（兜底）

- (void)startRenewTimer {
    if (self.renewTimer) return;
    double lead = MAX(3.0, MIN(60.0, IPATKADouble(@"RenewLeadTime", 10.0)));
    self.renewTimer = [NSTimer timerWithTimeInterval:lead
                                             target:self
                                           selector:@selector(tickRenew)
                                           userInfo:nil
                                            repeats:YES];
    // 放进 common modes，滚动/游戏渲染时也不会被漏掉
    [[NSRunLoop mainRunLoop] addTimer:self.renewTimer forMode:NSRunLoopCommonModes];
}

- (void)tickRenew {
    if ([UIApplication sharedApplication].applicationState == UIApplicationStateActive) {
        [self endBackgroundTask];
        return;
    }
    [self renewBackgroundTask];
}

- (void)renewBackgroundTask {
    __weak typeof(self) weakSelf = self;
    UIApplication *app = [UIApplication sharedApplication];
    [self endBackgroundTask];
    self.task = [app beginBackgroundTaskWithName:@"ipatool-keepalive"
                               expirationHandler:^{
        // 单次任务到期：交给定时器下一轮再续（音频保活才是主力，这里只是兜底）
        IPATKALog(@"后台任务到期");
        [weakSelf endBackgroundTask];
    }];
    if (self.task == UIBackgroundTaskInvalid) {
        IPATKALog(@"申请后台任务失败（系统已不再给时间）");
    } else {
        self.renewCount++;
        IPATKALog(@"后台任务续期，剩余时间约 %.0f 秒", app.backgroundTimeRemaining);
    }
}

- (void)endBackgroundTask {
    if (self.task == UIBackgroundTaskInvalid) return;
    [[UIApplication sharedApplication] endBackgroundTask:self.task];
    self.task = UIBackgroundTaskInvalid;
}

#pragma mark 定位保活（可选）

- (void)startLocation {
    if (self.location) return;
    if (NSClassFromString(@"CLLocationManager") == Nil) return;

    CLLocationManager *manager = [[CLLocationManager alloc] init];
    manager.delegate = self;
    manager.desiredAccuracy = kCLLocationAccuracyThreeKilometers;
    manager.distanceFilter = 1000.0;
    if ([manager respondsToSelector:@selector(setPausesLocationUpdatesAutomatically:)]) {
        manager.pausesLocationUpdatesAutomatically = NO;
    }
    if ([manager respondsToSelector:@selector(setShowsBackgroundLocationIndicator:)]) {
        // 默认不显示蓝色指示条；Apple 审核要求显示，自用包才这么干
        manager.showsBackgroundLocationIndicator = IPATKABool(@"LocationIndicator", NO);
    }
    if ([manager respondsToSelector:@selector(setAllowsBackgroundLocationUpdates:)]) {
        manager.allowsBackgroundLocationUpdates = YES;
    }
    self.location = manager;

    CLAuthorizationStatus status = kCLAuthorizationStatusNotDetermined;
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
    if ([CLLocationManager respondsToSelector:@selector(authorizationStatus)]) {
        status = [CLLocationManager authorizationStatus];
    }
#pragma clang diagnostic pop
    if (status == kCLAuthorizationStatusNotDetermined) {
        if ([manager respondsToSelector:@selector(requestAlwaysAuthorization)]) {
            [manager requestAlwaysAuthorization];
            IPATKALog(@"已请求定位权限（后台定位保活需要选择始终允许）");
        }
    } else if (status == kCLAuthorizationStatusDenied || status == kCLAuthorizationStatusRestricted) {
        IPATKALog(@"定位权限被拒绝，定位保活不会生效");
    }
    [manager startUpdatingLocation];
}

- (void)stopLocation {
    if (!self.location) return;
    [self.location stopUpdatingLocation];
    self.location.delegate = nil;
    self.location = nil;
}

- (void)locationManager:(CLLocationManager *)manager didUpdateLocations:(NSArray<CLLocation *> *)locations {
    // 只要有回调就说明进程在跑；这里不需要做任何事
}

- (void)locationManager:(CLLocationManager *)manager didFailWithError:(NSError *)error {
    IPATKALog(@"定位失败: %@", error.localizedDescription);
}

- (void)locationManager:(CLLocationManager *)manager didChangeAuthorizationStatus:(CLAuthorizationStatus)status {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
    BOOL granted = (status == kCLAuthorizationStatusAuthorizedAlways
                    || status == kCLAuthorizationStatusAuthorized);
#pragma clang diagnostic pop
    if (granted) {
        IPATKALog(@"定位权限已授予，重启后台定位");
        [manager startUpdatingLocation];
    }
}

#pragma mark 定时唤醒（可选）

- (void)registerSchedulerTasksIfNeeded {
    if (self.schedulerRegistered) return;
    BOOL wantFetch = IPATKABool(@"Fetch", NO);
    BOOL wantProcessing = IPATKABool(@"Processing", NO);
    if (@available(iOS 13.0, *)) {
        if (NSClassFromString(@"BGTaskScheduler") == Nil) {
            IPATKALog(@"系统不支持 BGTaskScheduler");
            return;
        }
        if (!wantFetch && !wantProcessing) {
            // 这次启动不要定时唤醒，把上一轮遗留的请求撤掉
            [self cancelSchedulerTasks];
            return;
        }
        self.schedulerRegistered = YES;
        BGTaskScheduler *scheduler = [BGTaskScheduler sharedScheduler];
        __weak typeof(self) weakSelf = self;

        if (wantFetch) {
            self.fetchRegistered = YES;
            [scheduler registerForTaskWithIdentifier:IPATKARefreshTaskID
                                          usingQueue:nil
                                       launchHandler:^(BGTask *task) {
                IPATKALog(@"收到后台刷新唤醒");
                [weakSelf scheduleRefresh];
                [task setExpirationHandler:^{}];
                // 进程已被唤醒：给 App 一点时间继续它自己的下载/上报逻辑
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(20.0 * NSEC_PER_SEC)),
                               dispatch_get_main_queue(), ^{
                    [task setTaskCompletedWithSuccess:YES];
                });
            }];
            [self scheduleRefresh];
        }
        if (wantProcessing) {
            self.processingRegistered = YES;
            [scheduler registerForTaskWithIdentifier:IPATKAProcessingTaskID
                                          usingQueue:nil
                                       launchHandler:^(BGTask *task) {
                IPATKALog(@"收到后台长任务唤醒");
                [weakSelf scheduleProcessing];
                [task setExpirationHandler:^{}];
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(60.0 * NSEC_PER_SEC)),
                               dispatch_get_main_queue(), ^{
                    [task setTaskCompletedWithSuccess:YES];
                });
            }];
            [self scheduleProcessing];
        }
        // 只想要一种的，把另一种遗留的请求撤掉
        if (!wantFetch) [self cancelSchedulerTask:IPATKARefreshTaskID];
        if (!wantProcessing) [self cancelSchedulerTask:IPATKAProcessingTaskID];
    } else {
        IPATKALog(@"系统低于 iOS 13，不支持 BGTaskScheduler");
    }
}

- (void)scheduleRefresh API_AVAILABLE(ios(13.0)) {
    if (!IPATKABool(@"Fetch", NO)) return;
    BGAppRefreshTaskRequest *request =
        [[BGAppRefreshTaskRequest alloc] initWithIdentifier:IPATKARefreshTaskID];
    request.earliestBeginDate = [NSDate dateWithTimeIntervalSinceNow:
                                 MAX(60.0, IPATKADouble(@"RefreshInterval", 900.0))];
    NSError *error = nil;
    if (![[BGTaskScheduler sharedScheduler] submitTaskRequest:request error:&error]) {
        IPATKALog(@"注册后台刷新任务失败: %@", error.localizedDescription);
    }
}

- (void)scheduleProcessing API_AVAILABLE(ios(13.0)) {
    if (!IPATKABool(@"Processing", NO)) return;
    BGProcessingTaskRequest *request =
        [[BGProcessingTaskRequest alloc] initWithIdentifier:IPATKAProcessingTaskID];
    request.requiresNetworkConnectivity = YES;   // 热更需要网络
    request.requiresExternalPower = NO;
    request.earliestBeginDate = [NSDate dateWithTimeIntervalSinceNow:
                                 MAX(60.0, IPATKADouble(@"RefreshInterval", 900.0))];
    NSError *error = nil;
    if (![[BGTaskScheduler sharedScheduler] submitTaskRequest:request error:&error]) {
        IPATKALog(@"注册后台长任务失败: %@", error.localizedDescription);
    }
}

/// 面板改「定时唤醒」时：注册只能在启动阶段做，所以这里只能提交/撤销请求
- (void)applySchedulerState {
    if (@available(iOS 13.0, *)) {
        if (IPATKABool(@"Fetch", NO)) {
            if (self.fetchRegistered) {
                [self scheduleRefresh];
            } else {
                IPATKALog(@"定时唤醒的注册只能在启动时完成，改动会在下次启动生效");
            }
        } else {
            [self cancelSchedulerTask:IPATKARefreshTaskID];
        }
        if (IPATKABool(@"Processing", NO)) {
            if (self.processingRegistered) {
                [self scheduleProcessing];
            } else {
                IPATKALog(@"后台长任务的注册只能在启动时完成，改动会在下次启动生效");
            }
        } else {
            [self cancelSchedulerTask:IPATKAProcessingTaskID];
        }
    }
}

- (void)cancelSchedulerTasks {
    if (@available(iOS 13.0, *)) {
        [self cancelSchedulerTask:IPATKARefreshTaskID];
        [self cancelSchedulerTask:IPATKAProcessingTaskID];
    }
}

- (void)cancelSchedulerTask:(NSString *)identifier API_AVAILABLE(ios(13.0)) {
    if (NSClassFromString(@"BGTaskScheduler") == Nil) return;
    BGTaskScheduler *scheduler = [BGTaskScheduler sharedScheduler];
    if ([scheduler respondsToSelector:@selector(cancelTaskRequestWithIdentifier:)]) {
        [scheduler cancelTaskRequestWithIdentifier:identifier];
    }
}

#pragma mark 前后台

- (void)handleDidEnterBackground {
    if (!IPATKABool(@"Enabled", YES)) return;
    if (!self.started) [self start];
    if (!self.started) return;
    // 有些 App 会在自己启动后重设音频会话，这里再确认一次
    if (IPATKABool(@"SilentAudio", YES)) {
        [self activateAudioSession];
        [self startSilentAudio];
    }
    if (IPATKABool(@"RenewBackgroundTask", YES)) {
        [self startRenewTimer];
        [self renewBackgroundTask];
    }
    [self postStatus];
}

- (void)handleWillEnterForeground {
    [self endBackgroundTask];
}

@end

#pragma mark - 入口

__attribute__((constructor)) static void IPATKeepAliveInit(void) {
    // BGTaskScheduler 的 launch handler 必须在「App 完成启动前」注册好，
    // 等主队列就晚了（会抛 NSInternalInconsistencyException），所以这里同步注册。
    [[IPATKeepAliveController shared] registerSchedulerTasksIfNeeded];

    // 其余等主队列开始调度再做：静音音频越早开始播，后台越不容易被挂起。
    // 早于 App 完成启动时 beginBackgroundTask 会失败，切后台时还会再续一次，不影响。
    dispatch_async(dispatch_get_main_queue(), ^{
        [[IPATKeepAliveController shared] start];
    });
}
