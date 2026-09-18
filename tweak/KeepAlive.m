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
//    0) 画中画（默认开启）：切后台自动进系统画中画、回前台自动退出。
//       App 在为画中画提供画面时系统不会挂起进程，这是目前最不容易被系统掐断的方式。
//       能用画中画时静音音频会自动让位（两个手段做的是同一件事，不叠加）。
//       画中画起不来（App 不支持 / 被系统拒）时自动退回静音音频。
//       画面内容是运行时生成的循环占位视频：iOS 不允许把 App 实时画面直接送进画中画。
//    1) 静音音频：以 .playback 类别循环播放一段全 0 采样的音频。
//       iOS 只要认为 App 在播放音频，就不会把进程挂起 —— 这是最稳定的保活方式。
//    2) 后台任务续期：不断 beginBackgroundTask，作为音频被抢断（电话/其它 App）时的兜底。
//    3) 定位更新：CLLocationManager 后台定位（需要用户授权，耗电，App Store 会拒，仅自用/内部分发）。
//    4) 定时唤醒：注册 BGAppRefreshTask / BGProcessingTask，被系统唤醒后再续注册。
//       注意：这只是把进程唤醒，是否继续下载取决于 App 自己的逻辑。
//
//  可通过 Info.plist 的 IPAToolKeepAlive 字典调整行为：
//    Enabled(bool)              默认 YES
//    PictureInPicture(bool)     默认 YES，画中画保活：切后台自动开画中画、回前台自动关，
//                               可用时静音音频自动让位；不支持/起不来时自动退回静音音频
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
//    带了悬浮窗时 App 里会出现可拖动的悬浮按钮，点开即可实时开关保活
//    （面板上没有总开关，直接在「画中画 / 静音音频」里选用哪种；两个都关掉就是关保活），
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
#import <AVKit/AVKit.h>
#import <CoreMedia/CoreMedia.h>
#import <CoreVideo/CoreVideo.h>
#import <QuartzCore/QuartzCore.h>
#import <CoreLocation/CoreLocation.h>
#import <BackgroundTasks/BackgroundTasks.h>
#import <objc/runtime.h>
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
        // 面板上能改的只有两个手段（画中画 / 静音音频），没有总开关：
        // 两个都关掉就等于关保活。剩下的（任务续期 / 定时唤醒 / 定位）只认 Info.plist
        // 「Enabled」刻意不放进面板：旧版本在面板上改过一次会留下旧值，容易改不回来
        map = @{
            @"PictureInPicture": IPATKeyKAPiP,
            @"SilentAudio": IPATKeyKASilentAudio,
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
    do { if (IPATKABool(@"Log", YES)) { \
        NSString *__ipat_line = [NSString stringWithFormat:(fmt), ##__VA_ARGS__]; \
        NSLog(@"[ipatool-keepalive] %@", __ipat_line); \
        IPATAppendLogLine(__ipat_line); \
    } } while (0)

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

#pragma mark - 画中画保活
//
//  用系统画中画（AVPictureInPictureController）代替静音音频保活：切后台自动开画中画，
//  回前台自动关。App「正在为画中画提供画面」时系统不会把进程挂起，热更下载也就不断。
//
//  两个前提（--keep-alive 注入时都已满足）：
//    1. Info.plist 的 UIBackgroundModes 含 audio
//    2. 音频会话是 playback 类别（上面 IPATKAInstallCategoryGuard 已经护住了）
//  不满足时 AVPictureInPictureController.isPictureInPictureSupported 会返回 NO，
//  这时一律回退到静音音频保活，绝不让「换保活方式」把原来的能力弄丢。
//
//  ⚠️ 画面内容是占位画面，不是游戏实时画面：iOS 不允许把 App 的实时画面直接塞进
//     画中画（ReplayKit 采集出来的帧只能喂给 AVSampleBufferDisplayLayer，
//     走 iOS 15+ 的 sampleBuffer 内容源，代价是常驻采集、耗电、游戏掉帧）。
//     保活只需要「系统在替我们渲染一层画面」，所以这里放一段运行时生成的循环
//     占位视频（深色底 + 一行字，2 秒一循环），解码开销可以忽略。

static NSString *IPATPIPVideoPath(void) {
    NSArray<NSString *> *dirs = NSSearchPathForDirectoriesInDomains(NSCachesDirectory,
                                                                    NSUserDomainMask, YES);
    return [[dirs firstObject] stringByAppendingPathComponent:@"ipatool-pip.mp4"];
}

/// 占位画面（深色底 + 一行字）。UIKit 的绘制只在主线程用，所以由调用方在主线程生成
static UIImage *IPATPIPPlaceholderImage(CGSize size) {
    UIGraphicsBeginImageContextWithOptions(size, YES, 1.0);
    [[UIColor colorWithRed:0.07 green:0.08 blue:0.10 alpha:1.0] setFill];
    UIRectFill(CGRectMake(0, 0, size.width, size.height));
    NSString *text = @"ipatool 后台保活中";
    NSDictionary *textAttrs = @{NSFontAttributeName: [UIFont boldSystemFontOfSize:24.0],
                                NSForegroundColorAttributeName: [UIColor colorWithWhite:1.0 alpha:0.9]};
    CGSize textSize = [text sizeWithAttributes:textAttrs];
    [text drawAtPoint:CGPointMake((size.width - textSize.width) / 2.0,
                                  (size.height - textSize.height) / 2.0)
       withAttributes:textAttrs];
    UIImage *image = UIGraphicsGetImageFromCurrentImageContext();
    UIGraphicsEndImageContext();
    return image;
}

/// 把占位画面画进 CVPixelBuffer（调用方负责 CFRelease）
static CVPixelBufferRef IPATPIPMakeFrame(CGSize size, UIImage *image) {
    NSDictionary *attrs = @{(id)kCVPixelBufferCGImageCompatibilityKey: @YES,
                            (id)kCVPixelBufferCGBitmapContextCompatibilityKey: @YES};
    CVPixelBufferRef buffer = NULL;
    CVReturn status = CVPixelBufferCreate(kCFAllocatorDefault, (size_t)size.width, (size_t)size.height,
                                          kCVPixelFormatType_32ARGB,
                                          (__bridge CFDictionaryRef)attrs, &buffer);
    if (status != kCVReturnSuccess || !buffer) return NULL;

    if (image) {
        CVPixelBufferLockBaseAddress(buffer, 0);
        CGColorSpaceRef space = CGColorSpaceCreateDeviceRGB();
        CGContextRef ctx = CGBitmapContextCreate(CVPixelBufferGetBaseAddress(buffer),
                                                 (size_t)size.width, (size_t)size.height, 8,
                                                 CVPixelBufferGetBytesPerRow(buffer), space,
                                                 kCGBitmapByteOrder32Host | kCGImageAlphaNoneSkipFirst);
        if (ctx) {
            // CGBitmapContext 的原点在左下，翻一下再画，不然字是倒的
            CGContextTranslateCTM(ctx, 0, size.height);
            CGContextScaleCTM(ctx, 1.0, -1.0);
            CGContextDrawImage(ctx, CGRectMake(0, 0, size.width, size.height), image.CGImage);
            CGContextRelease(ctx);
        }
        CGColorSpaceRelease(space);
        CVPixelBufferUnlockBaseAddress(buffer, 0);
    }
    return buffer;
}

/// 写一段 2 秒的循环占位视频（H.264 / mp4）。只在第一次启动时写，之后直接复用
static BOOL IPATPIPWriteVideoFile(NSString *path, UIImage *image) {
    [[NSFileManager defaultManager] removeItemAtPath:path error:nil];
    NSURL *url = [NSURL fileURLWithPath:path];
    NSError *error = nil;
    AVAssetWriter *writer = [[AVAssetWriter alloc] initWithURL:url fileType:AVFileTypeMPEG4 error:&error];
    if (error || !writer) return NO;

    CGSize size = CGSizeMake(640.0, 360.0);
    NSDictionary *settings = @{AVVideoCodecKey: AVVideoCodecTypeH264,
                               AVVideoWidthKey: @(size.width),
                               AVVideoHeightKey: @(size.height)};
    AVAssetWriterInput *input = [AVAssetWriterInput assetWriterInputWithMediaType:AVMediaTypeVideo
                                                                  outputSettings:settings];
    input.expectsMediaDataInRealTime = NO;
    NSDictionary *sourceAttrs = @{(id)kCVPixelBufferPixelFormatTypeKey: @(kCVPixelFormatType_32ARGB),
                                  (id)kCVPixelBufferWidthKey: @(size.width),
                                  (id)kCVPixelBufferHeightKey: @(size.height)};
    AVAssetWriterInputPixelBufferAdaptor *adaptor =
        [AVAssetWriterInputPixelBufferAdaptor assetWriterInputPixelBufferAdaptorWithAssetWriterInput:input
                                                                        sourcePixelBufferAttributes:sourceAttrs];
    if (![writer canAddInput:input]) return NO;
    [writer addInput:input];
    if (![writer startWriting]) return NO;
    [writer startSessionAtSourceTime:kCMTimeZero];

    CVPixelBufferRef frame = IPATPIPMakeFrame(size, image);
    if (!frame) {
        [writer cancelWriting];
        return NO;
    }
    int32_t fps = 10;
    NSInteger appended = 0;
    for (NSInteger i = 0; i < 20; i++) {          // 2 秒
        if (!input.readyForMoreMediaData) {
            [NSThread sleepForTimeInterval:0.05];
        }
        if ([adaptor appendPixelBuffer:frame withPresentationTime:CMTimeMake((int64_t)i, fps)]) {
            appended++;
        }
    }
    CVPixelBufferRelease(frame);
    [input markAsFinished];
    [writer endSessionAtSourceTime:CMTimeMake((int64_t)MAX(1, appended), fps)];

    // 导出完成是异步回调：这里在后台线程等它（生成只在启动时做一次，卡不到游戏）
    __block BOOL done = NO;
    __block BOOL ok = NO;
    [writer finishWritingWithCompletionHandler:^{
        ok = (writer.status == AVAssetWriterStatusCompleted);
        done = YES;
    }];
    NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:5.0];
    while (!done && [deadline timeIntervalSinceNow] > 0) {
        [[NSRunLoop currentRunLoop] runMode:NSDefaultRunLoopMode
                                 beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.05]];
    }
    return ok && [[NSFileManager defaultManager] fileExistsAtPath:path];
}

@interface IPATPIPController : NSObject <AVPictureInPictureControllerDelegate>

@property (nonatomic, strong) AVPlayer *player;
@property (nonatomic, strong) AVPlayerLayer *playerLayer;
@property (nonatomic, strong) UIView *hostView;
@property (nonatomic, strong) AVPictureInPictureController *pip;
@property (nonatomic, assign) BOOL prepared;    // player / 控制器已建好
@property (nonatomic, assign) BOOL preparing;   // 正在生成占位视频
@property (nonatomic, assign) BOOL active;      // 正在画中画
@property (nonatomic, assign) BOOL starting;
@property (nonatomic, assign) BOOL gaveUp;      // 已确认用不了（系统/包不支持），不再重试
@property (nonatomic, assign) NSInteger prepareAttempts;
/// 不可用的具体原因，面板上直接显示，省得猜
@property (nonatomic, copy) NSString *unavailableReason;
/// 状态变了（就绪 / 启动 / 停止 / 失败）回调给保活控制器，让它决定要不要补音频
@property (nonatomic, copy) void (^onStateChange)(void);

@end

@implementation IPATPIPController

+ (instancetype)shared {
    static IPATPIPController *shared;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        shared = [[IPATPIPController alloc] init];
        // dylib 的 constructor 跑得比 App 建窗口还早，第一次准备经常拿不到窗口。
        // 盯着「窗口出现 / App 变活跃」再补一次，别让第一次失败把画中画判死。
        NSNotificationCenter *center = [NSNotificationCenter defaultCenter];
        [center addObserver:shared
                   selector:@selector(handleRetryChance:)
                       name:UIWindowDidBecomeKeyNotification
                     object:nil];
        [center addObserver:shared
                   selector:@selector(handleRetryChance:)
                       name:UIWindowDidBecomeVisibleNotification
                     object:nil];
        [center addObserver:shared
                   selector:@selector(handleRetryChance:)
                       name:UIApplicationDidBecomeActiveNotification
                     object:nil];
    });
    return shared;
}

- (void)handleRetryChance:(NSNotification *)note {
    if (self.prepared || self.gaveUp) return;
    [self prepareIfNeeded];
}

/// player 和控制器都建好了才叫「能顶上」
- (BOOL)isReady {
    return (self.prepared && self.pip != nil);
}

#pragma mark 准备

- (void)prepareIfNeeded {
    if (![NSThread isMainThread]) {
        dispatch_async(dispatch_get_main_queue(), ^{ [self prepareIfNeeded]; });
        return;
    }
    if (self.prepared || self.preparing || self.gaveUp) return;
    if (self.prepareAttempts >= 8) {
        // 试了很多次都没成，别再刷日志了
        self.gaveUp = YES;
        IPATKALog(@"画中画准备重试 %ld 次仍未成功，放弃并只用静音音频保活", (long)self.prepareAttempts);
        return;
    }
    self.prepareAttempts += 1;

    Class cls = NSClassFromString(@"AVPictureInPictureController");
    if (!cls) {
        self.gaveUp = YES;
        self.unavailableReason = @"系统无画中画";
        IPATKALog(@"系统没有画中画（AVPictureInPictureController），回退静音音频保活");
        if (self.onStateChange) self.onStateChange();
        return;
    }
    if (![cls isPictureInPictureSupported]) {
        // 最常见的原因是包里没有 UIBackgroundModes: audio，或者音频会话不是 playback
        NSArray *modes = [[NSBundle mainBundle] objectForInfoDictionaryKey:@"UIBackgroundModes"];
        self.gaveUp = YES;
        self.unavailableReason = ([modes containsObject:@"audio"] ? @"会话非 playback" : @"缺后台模式 audio");
        IPATKALog(@"当前 App 不支持画中画，回退静音音频保活（iOS %@，UIBackgroundModes=%@，会话=%@；"
                  @"画中画要求 UIBackgroundModes 含 audio 且会话是 playback）",
                  [UIDevice currentDevice].systemVersion, modes ?: @[],
                  [AVAudioSession sharedInstance].category);
        if (self.onStateChange) self.onStateChange();
        return;
    }

    self.preparing = YES;
    NSString *path = IPATPIPVideoPath();
    if ([[NSFileManager defaultManager] fileExistsAtPath:path]) {
        [self finishPreparingWithPath:path];
        return;
    }
    // 画面在主线程画好（UIKit 绘制），编码放后台队列，别卡住主线程
    UIImage *placeholder = IPATPIPPlaceholderImage(CGSizeMake(640.0, 360.0));
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        BOOL ok = IPATPIPWriteVideoFile(path, placeholder);
        dispatch_async(dispatch_get_main_queue(), ^{
            self.preparing = NO;
            if (!ok) {
                self.gaveUp = YES;
                self.unavailableReason = @"占位视频生成失败";
                IPATKALog(@"画中画占位视频生成失败，回退静音音频保活");
                if (self.onStateChange) self.onStateChange();
                return;
            }
            [self finishPreparingWithPath:path];
        });
    });
}

- (void)finishPreparingWithPath:(NSString *)path {
    self.preparing = NO;

    AVPlayerItem *item = [AVPlayerItem playerItemWithURL:[NSURL fileURLWithPath:path]];
    AVPlayer *player = [AVPlayer playerWithPlayerItem:item];
    player.actionAtItemEnd = AVPlayerActionAtItemEndNone;   // 播完自己 seek 回 0 循环
    player.muted = YES;

    AVPlayerLayer *layer = [AVPlayerLayer playerLayerWithPlayer:player];
    layer.videoGravity = AVLayerVideoGravityResizeAspect;
    layer.frame = CGRectMake(0, 0, 2, 2);

    // 宿主视图：2x2 挂在游戏窗口上。不能用 hidden —— 画中画要求这个 layer 真的在
    // 屏幕上，所以只把透明度压到几乎看不见（对画面没影响，触摸也穿透不了）
    UIView *host = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 2, 2)];
    host.alpha = 0.02;
    host.userInteractionEnabled = NO;
    host.backgroundColor = [UIColor clearColor];
    host.clipsToBounds = YES;
    [host.layer addSublayer:layer];

    UIWindow *appWindow = IPATAppKeyWindowExcluding(nil);
    if (!appWindow) {
        // 窗口还没建出来：不判死，等 UIWindowDidBecomeKey / App 变活跃再补一次。
        // 以前这里会把「已准备」置成 YES，之后再也不重试，面板就一直显示「画中画不可用」。
        self.prepared = NO;
        self.unavailableReason = @"未拿到 App 窗口";
        self.player = nil;
        self.playerLayer = nil;
        self.hostView = nil;
        IPATKALog(@"画中画的宿主视图暂时挂不上（App 窗口还没建好），等窗口出现后重试");
        return;
    }
    [appWindow addSubview:host];

    self.player = player;
    self.playerLayer = layer;
    self.hostView = host;

    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(handleItemDidEnd:)
                                                 name:AVPlayerItemDidPlayToEndTimeNotification
                                               object:item];

    AVPictureInPictureController *pip = nil;
    if (@available(iOS 14.0, *)) {
        AVPictureInPictureControllerContentSource *source =
            [[AVPictureInPictureControllerContentSource alloc] initWithPlayerLayer:layer];
        pip = [[AVPictureInPictureController alloc] initWithContentSource:source];
    } else {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
        pip = [[AVPictureInPictureController alloc] initWithPlayerLayer:layer];
#pragma clang diagnostic pop
    }
    if (!pip) {
        // 同样不判死：控制器创建可能因为 playerLayer 还没就绪而返回 nil，过一会儿再试
        self.prepared = NO;
        self.unavailableReason = @"控制器创建失败";
        self.player = nil;
        self.playerLayer = nil;
        [host removeFromSuperview];
        self.hostView = nil;
        IPATKALog(@"创建画中画控制器失败（稍后重试），先回退静音音频保活");
        if (self.onStateChange) self.onStateChange();
        return;
    }
    self.prepared = YES;
    self.unavailableReason = nil;
    pip.delegate = self;
    self.pip = pip;
    [player play];   // 保持播放状态，切后台才能立刻进画中画
    IPATKALog(@"画中画保活已就绪（占位视频 %@）", path.lastPathComponent);
    if (self.onStateChange) self.onStateChange();
}

- (void)handleItemDidEnd:(NSNotification *)note {
    AVPlayerItem *item = self.player.currentItem;
    if (!item) return;
    __weak typeof(self) weakSelf = self;
    [item seekToTime:kCMTimeZero
     toleranceBefore:kCMTimeZero
      toleranceAfter:kCMTimeZero
   completionHandler:^(BOOL finished) {
        [weakSelf.player play];
    }];
}

#pragma mark 启动 / 停止

/// 切后台时调用：能进画中画就进，进不去由 onStateChange 通知保活侧补音频
- (void)startIfNeeded {
    if (self.active || self.starting) return;
    if (!self.pip) {
        [self prepareIfNeeded];     // 第一次还没准备好，这次切后台先由音频顶着
        if (!self.pip) return;      // 占位视频已存在时 prepare 是同步的，这次就能用上
    }
    if (self.hostView && !self.hostView.window) {
        // 游戏把窗口重建过（切场景 / 换根视图），宿主视图掉了：重新挂回去，
        // 不然画中画没有内容源，start 会静默失败
        UIWindow *appWindow = IPATAppKeyWindowExcluding(nil);
        if (appWindow) [appWindow addSubview:self.hostView];
    }
    self.starting = YES;
    [self.player play];
    [self attemptStart:0];
}

- (void)attemptStart:(NSInteger)attempt {
    __weak typeof(self) weakSelf = self;
    if (self.active) { self.starting = NO; return; }

    if (self.pip.isPictureInPicturePossible) {
        IPATKALog(@"启动画中画");
        [self.pip startPictureInPicture];
        // 起不来就别干等：让保活侧把静音音频补上
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.8 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            if (weakSelf.active) return;
            weakSelf.starting = NO;
            IPATKALog(@"画中画没能启动（系统没让进），回退静音音频保活");
            if (weakSelf.onStateChange) weakSelf.onStateChange();
        });
        return;
    }
    if (attempt >= 12) {   // 最多等约 1.2 秒
        self.starting = NO;
        AVPlayerItem *item = self.player.currentItem;
        // 这三项基本能定位「为什么起不来」：item 没就绪 / 画面没渲染出来 / 宿主视图不在窗口里
        IPATKALog(@"画中画当前不可用（possible=NO，item=%ld，layerReady=%d，宿主视图在窗口里=%d），回退静音音频保活",
                  (long)item.status, self.playerLayer.readyForDisplay, self.hostView.window != nil);
        self.unavailableReason = (self.playerLayer && !self.playerLayer.readyForDisplay)
            ? @"画面未渲染" : @"系统拒绝启动";
        if (self.onStateChange) self.onStateChange();
        return;
    }
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.1 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        [weakSelf attemptStart:attempt + 1];
    });
}

/// 回前台时调用
- (void)stopIfActive {
    self.starting = NO;
    if (!self.pip) return;
    if (self.active) [self.pip stopPictureInPicture];
    [self.player pause];   // 前台不用播，省一点电；切后台时会重新 play
}

#pragma mark AVPictureInPictureControllerDelegate

- (void)pictureInPictureControllerDidStartPictureInPicture:(AVPictureInPictureController *)controller {
    self.active = YES;
    self.starting = NO;
    IPATKALog(@"画中画已启动：由系统撑着进程，切后台不再挂起");
    if (self.onStateChange) self.onStateChange();
}

- (void)pictureInPictureControllerDidStopPictureInPicture:(AVPictureInPictureController *)controller {
    BOOL wasActive = self.active;
    self.active = NO;
    self.starting = NO;
    IPATKALog(@"画中画已停止");
    // 还在后台就被关掉了（用户划掉 / 系统收回）：把音频保活补上
    if (wasActive && self.onStateChange) self.onStateChange();
}

- (void)pictureInPictureController:(AVPictureInPictureController *)controller
failedToStartPictureInPictureWithError:(NSError *)error {
    self.active = NO;
    self.starting = NO;
    IPATKALog(@"画中画启动失败: %@", error.localizedDescription ?: @"未知错误");
    if (self.onStateChange) self.onStateChange();
}

@end

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
@property (nonatomic, strong) NSTimer *heartbeatTimer;
@property (nonatomic, assign) NSUInteger heartbeat;              // 心跳总次数
@property (nonatomic, assign) NSUInteger heartbeatAtBackground;  // 进入后台时的心跳数
@property (nonatomic, assign) NSTimeInterval enterBackgroundTime;
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
                   selector:@selector(handleWillResignActive)
                       name:UIApplicationWillResignActiveNotification
                     object:nil];
        [center addObserver:self
                   selector:@selector(handleDidEnterBackground)
                       name:UIApplicationDidEnterBackgroundNotification
                     object:nil];
        [center addObserver:self
                   selector:@selector(handleWillEnterForeground)
                       name:UIApplicationWillEnterForegroundNotification
                     object:nil];
        [center addObserver:self
                   selector:@selector(handleDidBecomeActive)
                       name:UIApplicationDidBecomeActiveNotification
                     object:nil];
        // 画中画状态一变（就绪/启动/被关掉/起不来），重新决定要不要用静音音频兜底
        __weak typeof(self) weakSelf = self;
        [IPATPIPController shared].onStateChange = ^{ [weakSelf applyRuntimePolicy]; };
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
    if (![self hasAnyMethod]) {
        IPATKALog(@"保活未启动：没有选中任何保活方式（画中画 / 静音音频都关着）");
        return;
    }
    if (self.started) return;
    self.started = YES;
    IPATKALog(@"启用保活：pip=%d silentAudio=%d renew=%d location=%d fetch=%d processing=%d",
              IPATKABool(@"PictureInPicture", YES),
              IPATKABool(@"SilentAudio", YES),
              IPATKABool(@"RenewBackgroundTask", YES),
              IPATKABool(@"Location", NO),
              IPATKABool(@"Fetch", NO),
              IPATKABool(@"Processing", NO));

    // 先把「音频类别」这层护住：静音音频和画中画都要求会话是 playback 类别
    IPATKAInstallCategoryGuard();
    [self activateAudioSession];
    IPATKALog(@"保活环境：iOS %@，UIBackgroundModes=%@，会话=%@",
              [UIDevice currentDevice].systemVersion,
              [[NSBundle mainBundle] objectForInfoDictionaryKey:@"UIBackgroundModes"] ?: @[],
              [AVAudioSession sharedInstance].category);

    if (IPATKABool(@"PictureInPicture", YES)) {
        [[IPATPIPController shared] prepareIfNeeded];
    }
    if ([self wantsSilentAudio]) {
        [self startSilentAudio];
    }
    if ([self wantsBackgroundTask]) {
        [self startRenewTimer];
    }
    [self startHeartbeat];
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
    [[IPATPIPController shared] stopIfActive];
    [self stopSilentAudio];
    [self.renewTimer invalidate];
    self.renewTimer = nil;
    [self.heartbeatTimer invalidate];
    self.heartbeatTimer = nil;
    [self endBackgroundTask];
    [self stopLocation];
    [self cancelSchedulerTasks];
    IPATKALog(@"保活已停止");
}

#pragma mark 悬浮控制面板

/// 面板改了开关：重新读一遍配置，把变化立刻落到运行状态上
- (void)applyPanelState {
    if (!IPATKABool(@"Enabled", YES) || ![self hasAnyMethod]) {
        [self stop];
        [self postStatus];
        return;
    }
    if (!self.started) [self start];
    if (!self.started) return;

    [self applyRuntimePolicy];
    if (IPATKABool(@"Location", NO)) {
        [self startLocation];
    } else {
        [self stopLocation];
    }
    [self applySchedulerState];
    [self postStatus];
}

#pragma mark 画中画 / 静音音频 的分工

/// 有没有选中任何一种保活手段。面板上没有总开关，两个手段都关掉就等于关保活：
/// 这时候要真的把画中画、音频、续期、定位全停掉，而不是留一堆定时器空转
- (BOOL)hasAnyMethod {
    return IPATKABool(@"PictureInPicture", YES)
        || IPATKABool(@"SilentAudio", YES)
        || IPATKABool(@"Location", NO)
        || IPATKABool(@"Fetch", NO)
        || IPATKABool(@"Processing", NO);
}

/// 画中画开关开着、而且真的能用（player + 控制器都就绪）时，由画中画顶替静音音频
- (BOOL)pipTakesOver {
    if (!IPATKABool(@"PictureInPicture", YES)) return NO;
    return [[IPATPIPController shared] isReady];
}

/// 画中画已经顶上了就别再播静音音频（它本来就是被画中画替代的那个手段）
- (BOOL)wantsSilentAudio {
    if (!IPATKABool(@"SilentAudio", YES)) return NO;
    if (!IPATKABool(@"PictureInPicture", YES)) return YES;
    IPATPIPController *pip = [IPATPIPController shared];
    if (pip.active) return NO;        // 画中画正在跑
    if (!pip.isReady) return YES;     // 不支持 / 还没准备好：音频先顶着
    // 就绪但没在画中画：前台说明还没切后台（用不上音频）；
    // 后台说明画中画没能起来，必须靠音频兜底
    return ([UIApplication sharedApplication].applicationState != UIApplicationStateActive);
}

- (BOOL)wantsBackgroundTask {
    if (!IPATKABool(@"RenewBackgroundTask", YES)) return NO;
    if (!IPATKABool(@"PictureInPicture", YES)) return YES;
    IPATPIPController *pip = [IPATPIPController shared];
    if (pip.active) return NO;
    if (!pip.isReady) return YES;
    return ([UIApplication sharedApplication].applicationState != UIApplicationStateActive);
}

/// 把运行状态对齐到当前配置 + 画中画状态（面板改动 / 前后台切换 / 画中画状态变化都走这里）
- (void)applyRuntimePolicy {
    if (!IPATKABool(@"Enabled", YES) || ![self hasAnyMethod]) {
        [self stop];
        [self postStatus];
        return;
    }
    if (!self.started) {
        [self start];
        return;
    }
    if (IPATKABool(@"PictureInPicture", YES)) {
        [[IPATPIPController shared] prepareIfNeeded];
    }
    if ([self wantsSilentAudio]) {
        [self activateAudioSession];
        [self startSilentAudio];
    } else {
        [self stopSilentAudio];
    }
    if ([self wantsBackgroundTask]) {
        [self startRenewTimer];
    } else {
        [self.renewTimer invalidate];
        self.renewTimer = nil;
        [self endBackgroundTask];
    }
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
        // 没有总开关：默认就是开着的，用户直接在下面挑用哪种手段，两个都关掉等于关保活
        IPATRegMasterHidden: @YES,
        // 面板上两个手段各自的开关：画中画优先，静音音频当兜底。
        // 两个都开着时画中画一跑起来，静音音频会自动停掉（同一件事不叠加）
        IPATRegRows: @[
            @{
                IPATRowKey: IPATKeyKAPiP,
                IPATRowTitle: @"画中画保活",
                IPATRowKind: IPATRowKindSwitch,
                IPATRowValue: @(IPATKABool(@"PictureInPicture", YES)),
                IPATRowNote: @"切后台自动开画中画、回前台自动关；起不来时靠下面的静音音频兜底",
            },
            @{
                IPATRowKey: IPATKeyKASilentAudio,
                IPATRowTitle: @"静音音频保活",
                IPATRowKind: IPATRowKindSwitch,
                IPATRowValue: @(IPATKABool(@"SilentAudio", YES)),
                IPATRowNote: @"循环播放全 0 音频让系统不挂起；画中画在跑时自动停，关掉则完全不播",
            },
        ],
        // 剩下的子项（后台任务续期）默认开，
        // 定位要授权还费电、定时唤醒改了要重启 App，这两项留给 Info.plist
        //（--keep-alive-no-task-renew / --keep-alive-location / --keep-alive-fetch）
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
    } else if (![self hasAnyMethod]) {
        detail = @"未选择保活方式";
    } else {
        NSMutableArray<NSString *> *parts = [NSMutableArray array];
        IPATPIPController *pip = [IPATPIPController shared];
        if (IPATKABool(@"PictureInPicture", YES)) {
            NSString *pipText;
            if (pip.active) {
                pipText = @"画中画进行中";
            } else if (pip.isReady) {
                pipText = @"画中画就绪";
            } else if (pip.unavailableReason.length > 0) {
                pipText = [NSString stringWithFormat:@"画中画不可用（%@）", pip.unavailableReason];
            } else {
                pipText = @"画中画准备中";
            }
            [parts addObject:pipText];
        }
        if (IPATKABool(@"SilentAudio", YES)) {
            NSString *audio = self.player.isPlaying ? @"音频播放中"
                            : ([self wantsSilentAudio] ? @"音频未播放" : @"音频已让位画中画");
            [parts addObject:audio];
        }
        if (IPATKABool(@"RenewBackgroundTask", YES)) {
            [parts addObject:[NSString stringWithFormat:@"续期 %lu 次", (unsigned long)self.renewCount]];
        }
        [parts addObject:[NSString stringWithFormat:@"心跳 %lu", (unsigned long)self.heartbeat]];
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

#pragma mark 音频类别保护

/// 游戏（音频引擎、各种 SDK）随时可能把音频类别设成 ambient / soloAmbient，
/// 这两个类别**不支持后台播放**——一设上去我们的静音保活就废了，
/// 而且系统不会发任何通知，界面上完全看不出来。所以这里顶回去：
/// 一律改回 playback（带上 MixWithOthers，尽量不影响别的 App）。
/// Info.plist 里 ForcePlaybackCategory=NO 可以关掉这个行为。
static BOOL IPATKAForceCategory(AVAudioSessionCategory *category,
                                AVAudioSessionCategoryOptions *options) {
    // 画中画同样要求会话是 playback 类别，所以两种保活方式都要这层保护
    if (!IPATKABool(@"SilentAudio", YES) && !IPATKABool(@"PictureInPicture", YES)) return NO;
    if (!IPATKABool(@"ForcePlaybackCategory", YES)) return NO;
    if ([*category isEqualToString:AVAudioSessionCategoryPlayback]) return NO;
    static NSTimeInterval lastLog = 0;
    NSTimeInterval now = [NSDate timeIntervalSinceReferenceDate];
    if (now - lastLog > 3.0) {   // 游戏可能一秒设好几次，别刷屏
        lastLog = now;
        IPATKALog(@"游戏把音频类别设成 %@（这个类别不能后台播放），强制改回 playback", *category);
    }
    *category = AVAudioSessionCategoryPlayback;
    if (options) *options |= AVAudioSessionCategoryOptionMixWithOthers;
    return YES;
}

static BOOL (*IPATKAOrigSetCategory)(id, SEL, AVAudioSessionCategory, NSError **) = NULL;
static BOOL (*IPATKAOrigSetCategoryOptions)(id, SEL, AVAudioSessionCategory,
                                            AVAudioSessionCategoryOptions, NSError **) = NULL;
static BOOL (*IPATKAOrigSetCategoryModeOptions)(id, SEL, AVAudioSessionCategory, AVAudioSessionMode,
                                                AVAudioSessionCategoryOptions, NSError **) = NULL;

static BOOL IPATKASetCategory(id self, SEL _cmd, AVAudioSessionCategory category, NSError **error) {
    IPATKAForceCategory(&category, NULL);
    if (IPATKAOrigSetCategory) return IPATKAOrigSetCategory(self, _cmd, category, error);
    return NO;
}

static BOOL IPATKASetCategoryOptions(id self, SEL _cmd, AVAudioSessionCategory category,
                                     AVAudioSessionCategoryOptions options, NSError **error) {
    IPATKAForceCategory(&category, &options);
    if (IPATKAOrigSetCategoryOptions) {
        return IPATKAOrigSetCategoryOptions(self, _cmd, category, options, error);
    }
    return NO;
}

static BOOL IPATKASetCategoryModeOptions(id self, SEL _cmd, AVAudioSessionCategory category,
                                         AVAudioSessionMode mode,
                                         AVAudioSessionCategoryOptions options, NSError **error) {
    IPATKAForceCategory(&category, &options);
    if (IPATKAOrigSetCategoryModeOptions) {
        return IPATKAOrigSetCategoryModeOptions(self, _cmd, category, mode, options, error);
    }
    return NO;
}

static void IPATKAInstallCategoryGuard(void) {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        Class cls = [AVAudioSession class];
        struct { SEL sel; IMP imp; void **out; } entries[] = {
            { @selector(setCategory:error:), (IMP)IPATKASetCategory, (void **)&IPATKAOrigSetCategory },
            { @selector(setCategory:withOptions:error:), (IMP)IPATKASetCategoryOptions,
              (void **)&IPATKAOrigSetCategoryOptions },
            { @selector(setCategory:mode:options:error:), (IMP)IPATKASetCategoryModeOptions,
              (void **)&IPATKAOrigSetCategoryModeOptions },
        };
        for (size_t i = 0; i < sizeof(entries) / sizeof(entries[0]); i++) {
            Method method = class_getInstanceMethod(cls, entries[i].sel);
            if (!method) continue;
            *entries[i].out = (void *)method_getImplementation(method);
            method_setImplementation(method, entries[i].imp);
        }
        IPATKALog(@"音频类别保护已安装（游戏改成 ambient 时自动顶回 playback）");
    });
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
    if (![self wantsSilentAudio]) return;
    NSNumber *type = note.userInfo[AVAudioSessionInterruptionTypeKey];
    if (type.unsignedIntegerValue == AVAudioSessionInterruptionTypeEnded) {
        IPATKALog(@"音频中断结束，恢复保活播放");
        [self activateAudioSession];
        [self startSilentAudio];
    }
}

- (void)handleMediaServicesReset:(NSNotification *)note {
    if (![self wantsSilentAudio]) return;
    IPATKALog(@"媒体服务被重置，重建保活播放器");
    [self stopSilentAudio];
    [self activateAudioSession];
    [self startSilentAudio];
}

- (void)handleRouteChange:(NSNotification *)note {
    if (![self wantsSilentAudio] || !self.player) return;
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
        // 前台时 backgroundTimeRemaining 是 DBL_MAX（不是真的秒数），
        // 直接打出来会把日志文件撑爆，看着也莫名其妙
        NSTimeInterval remaining = app.backgroundTimeRemaining;
        if (remaining > 1e9) {
            IPATKALog(@"后台任务已续期（当前在前台，系统不限时）");
        } else {
            IPATKALog(@"后台任务续期，剩余时间约 %.0f 秒", remaining);
        }
    }
}

- (void)endBackgroundTask {
    if (self.task == UIBackgroundTaskInvalid) return;
    [[UIApplication sharedApplication] endBackgroundTask:self.task];
    self.task = UIBackgroundTaskInvalid;
}

#pragma mark 心跳（判断进程到底有没有被挂起）

- (void)startHeartbeat {
    if (self.heartbeatTimer) return;
    self.heartbeatTimer = [NSTimer timerWithTimeInterval:5.0
                                                  target:self
                                                selector:@selector(tickHeartbeat)
                                                userInfo:nil
                                                 repeats:YES];
    [[NSRunLoop mainRunLoop] addTimer:self.heartbeatTimer forMode:NSRunLoopCommonModes];
}

/// 心跳是最直接的证据：日志里有心跳 = 进程没被挂起（保活生效，下载能继续）；
/// 切后台之后心跳就断了 = 进程被挂起，下载当然停在切出去那一刻。
- (void)tickHeartbeat {
    self.heartbeat++;
    // 该播却没播：多半是游戏自己改了音频会话（这种情况没有系统通知），立刻补上
    if ([self wantsSilentAudio] && !self.player.isPlaying) {
        IPATKALog(@"心跳发现音频停了，重新起播（游戏可能改过音频会话）");
        [self activateAudioSession];
        [self startSilentAudio];
    }

    UIApplication *app = [UIApplication sharedApplication];
    BOOL inBackground = (app.applicationState != UIApplicationStateActive);
    if (!inBackground && self.heartbeat % 12 != 0) return;   // 前台一分钟记一条就够

    AVAudioSession *session = [AVAudioSession sharedInstance];
    NSTimeInterval remaining = app.backgroundTimeRemaining;
    NSTimeInterval behind = self.enterBackgroundTime > 0
        ? [NSDate timeIntervalSinceReferenceDate] - self.enterBackgroundTime : 0;
    IPATKALog(@"心跳 %lu 状态=%@ 已后台%.0fs 画中画=%d 音频播放=%d 会话=%@ 其它音频在播=%d 后台任务剩余=%@",
              (unsigned long)self.heartbeat,
              inBackground ? @"后台" : @"前台",
              behind,
              [IPATPIPController shared].active,
              self.player.isPlaying,
              session.category,
              session.isOtherAudioPlaying,
              remaining > 1e9 ? @"不限(前台)" : [NSString stringWithFormat:@"%.0fs", remaining]);
    [self postStatus];
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

/// 即将失去活跃（切后台 / 下拉通知栏 / 来电话）：画中画要趁 App 还"在前台"就起来，
/// 等真的进了后台再启动，系统往往已经不给这个机会了
- (void)handleWillResignActive {
    if (!IPATKABool(@"Enabled", YES)) return;
    if (!IPATKABool(@"PictureInPicture", YES)) return;
    [[IPATPIPController shared] prepareIfNeeded];
    [[IPATPIPController shared] startIfNeeded];
}

- (void)handleDidEnterBackground {
    if (!IPATKABool(@"Enabled", YES)) return;
    if (!self.started) [self start];
    if (!self.started) return;
    self.enterBackgroundTime = [NSDate timeIntervalSinceReferenceDate];
    self.heartbeatAtBackground = self.heartbeat;
    AVAudioSession *session = [AVAudioSession sharedInstance];
    IPATKALog(@"进入后台：画中画=%d 音频播放=%d 会话=%@ 其它音频在播=%d",
              [IPATPIPController shared].active, self.player.isPlaying,
              session.category, session.isOtherAudioPlaying);
    // willResignActive 里没起来的，这里再试一次
    if (IPATKABool(@"PictureInPicture", YES)) {
        [[IPATPIPController shared] startIfNeeded];
    }
    // 有些 App 会在自己启动后重设音频会话，这里再确认一次
    if ([self wantsSilentAudio]) {
        [self activateAudioSession];
        [self startSilentAudio];
    }
    if ([self wantsBackgroundTask]) {
        [self startRenewTimer];
        [self renewBackgroundTask];
    }
    [self postStatus];
}

- (void)handleDidBecomeActive {
    if (IPATKABool(@"PictureInPicture", YES)) {
        [[IPATPIPController shared] stopIfActive];
    }
    [self applyRuntimePolicy];
}

- (void)handleWillEnterForeground {
    [[IPATPIPController shared] stopIfActive];
    NSTimeInterval behind = self.enterBackgroundTime > 0
        ? [NSDate timeIntervalSinceReferenceDate] - self.enterBackgroundTime : 0;
    IPATKALog(@"回到前台：后台共 %.0fs，其间心跳 %lu 次，音频播放=%d",
              behind, (unsigned long)(self.heartbeat - self.heartbeatAtBackground),
              self.player.isPlaying);
    self.enterBackgroundTime = 0;
    self.heartbeatAtBackground = self.heartbeat;
    [self endBackgroundTask];
    [self postStatus];
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
