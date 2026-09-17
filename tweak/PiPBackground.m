//
//  PiPBackground.m
//  ipatool 注入用 dylib：App 切到后台时自动进入画中画，从而在后台继续运行。
//
//  前提（ipatool inject --pip 会自动处理）：
//    1. dylib 被放进 App.app/Frameworks/ 并在主可执行文件里加了对应 LC_LOAD_DYLIB
//    2. Info.plist 的 UIBackgroundModes 里包含 audio
//    3. 重新签名（未签名/描述文件不匹配的包装不上）
//
//  可通过 Info.plist 的 IPAToolPiP 字典调整行为：
//    Enabled(bool)      默认 YES
//    Mode               black（默认，纯黑画面）| mirror（实验性：把 App 当前画面镜像进画中画）
//    VideoFile          App 包内的 mp4 文件名；配置后改用 AVPlayer 播放该视频（iOS 9+）
//    StartOn            background（默认）| resignActive | launch
//    StopOnForeground   默认 YES，回到前台自动退出画中画
//    KeepAliveAudio     默认 YES，播放静音音频保活，避免后台被挂起
//    FrameRate          默认 10
//
//  运行时开关：
//    注入 ControlPanel.dylib 后 App 里会出现悬浮窗，点开即可实时开关画中画及其子选项，
//    面板写入的值存在 NSUserDefaults 里，优先级高于上面的 Info.plist 初始值。
//

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <AVFoundation/AVFoundation.h>
#import <AVKit/AVKit.h>
#import <CoreMedia/CoreMedia.h>
#import <CoreVideo/CoreVideo.h>
#import <QuartzCore/QuartzCore.h>
#import "IPATControlShared.h"

#define IPATPipLog(fmt, ...) NSLog(@"[ipatool-pip] " fmt, ##__VA_ARGS__)

#pragma mark - 配置

static NSDictionary *IPATPipConfig(void) {
    static NSDictionary *cfg;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        id value = [[NSBundle mainBundle] objectForInfoDictionaryKey:@"IPAToolPiP"];
        cfg = [value isKindOfClass:[NSDictionary class]] ? value : @{};
    });
    return cfg;
}

/// Info.plist 键 -> 悬浮面板写入的 NSUserDefaults 键（面板没改过则返回 nil，回落 plist）
static NSString *IPATPipPanelKey(NSString *plistKey) {
    if (plistKey.length == 0) return nil;
    static NSDictionary *map;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        map = @{
            @"Enabled": IPATKeyPiPEnabled,
            @"Mode": IPATKeyPiPMode,
            @"StopOnForeground": IPATKeyPiPStopOnForeground,
            @"KeepAliveAudio": IPATKeyPiPAudio,
        };
    });
    return map[plistKey];
}

static id IPATPipValue(NSString *key) {
    // 面板里改过的值优先于 Info.plist 的初始值
    NSString *panelKey = IPATPipPanelKey(key);
    if (panelKey) {
        id override = [[NSUserDefaults standardUserDefaults] objectForKey:panelKey];
        if (override) return [override isKindOfClass:[NSNull class]] ? nil : override;
    }
    id value = IPATPipConfig()[key];
    return [value isKindOfClass:[NSNull class]] ? nil : value;
}

static BOOL IPATPipBool(NSString *key, BOOL fallback) {
    id value = IPATPipValue(key);
    return [value respondsToSelector:@selector(boolValue)] ? [value boolValue] : fallback;
}

static NSInteger IPATPipInt(NSString *key, NSInteger fallback) {
    id value = IPATPipValue(key);
    return [value respondsToSelector:@selector(integerValue)] ? [value integerValue] : fallback;
}

static NSString *IPATPipString(NSString *key) {
    id value = IPATPipValue(key);
    return [value isKindOfClass:[NSString class]] ? value : nil;
}

#pragma mark - 工具

/// 当前前台窗口（iOS 13+ 走 UIWindowScene，旧系统回退 keyWindow）
static UIWindow *IPATPipKeyWindow(void) {
    // 悬浮控制面板的窗口必须跳过：它的层级比 App 窗口高，
    // 不然画中画会挂到悬浮窗上、甚至把控制面板镜像进画中画
    static NSString *const overlayWindowClass = @"IPATCpWindow";
    UIWindow *fallback = nil;
    NSSet<UIScene *> *scenes = [UIApplication sharedApplication].connectedScenes;
    for (UIScene *scene in scenes) {
        if (![scene isKindOfClass:[UIWindowScene class]]) continue;
        UIWindowScene *windowScene = (UIWindowScene *)scene;
        for (UIWindow *window in windowScene.windows) {
            if ([NSStringFromClass([window class]) isEqualToString:overlayWindowClass]) continue;
            if (window.isKeyWindow && window.hidden == NO) return window;
            if (!fallback) fallback = window;
        }
    }
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
    if (!fallback) {
        UIWindow *legacy = [UIApplication sharedApplication].keyWindow;
        if (legacy.hidden == NO) fallback = legacy;
    }
#pragma clang diagnostic pop
    return fallback;
}

/// 生成一段内存中的静音 WAV（16bit / 单声道）
static NSData *IPATPipSilentWAV(double seconds, uint32_t sampleRate) {
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

/// 纯黑 CVPixelBuffer
static CVPixelBufferRef IPATPipCreateBlackPixelBuffer(size_t width, size_t height) {
    NSDictionary *attrs = @{(id)kCVPixelBufferIOSurfacePropertiesKey: @{}};
    CVPixelBufferRef pixelBuffer = NULL;
    if (CVPixelBufferCreate(kCFAllocatorDefault, width, height, kCVPixelFormatType_32BGRA,
                            (__bridge CFDictionaryRef)attrs, &pixelBuffer) != kCVReturnSuccess) {
        return NULL;
    }
    CVPixelBufferLockBaseAddress(pixelBuffer, 0);
    void *base = CVPixelBufferGetBaseAddress(pixelBuffer);
    if (base) {
        memset(base, 0, CVPixelBufferGetBytesPerRow(pixelBuffer) * CVPixelBufferGetHeight(pixelBuffer));
    }
    CVPixelBufferUnlockBaseAddress(pixelBuffer, 0);
    return pixelBuffer;
}

/// 把 CALayer 当前内容渲染进 CVPixelBuffer（镜像模式，实验性）
static BOOL IPATPipRenderLayerIntoCVPixelBuffer(CALayer *layer, CVPixelBufferRef pixelBuffer) {
    if (!layer || !pixelBuffer) return NO;
    if (CVPixelBufferLockBaseAddress(pixelBuffer, 0) != kCVReturnSuccess) return NO;

    CGColorSpaceRef space = CGColorSpaceCreateDeviceRGB();
    CGContextRef ctx = CGBitmapContextCreate(CVPixelBufferGetBaseAddress(pixelBuffer),
                                             CVPixelBufferGetWidth(pixelBuffer),
                                             CVPixelBufferGetHeight(pixelBuffer),
                                             8,
                                             CVPixelBufferGetBytesPerRow(pixelBuffer),
                                             space,
                                             kCGBitmapByteOrder32Little | kCGImageAlphaPremultipliedFirst);
    CGColorSpaceRelease(space);

    BOOL ok = NO;
    if (ctx) {
        UIGraphicsPushContext(ctx);          // 让 Core Graphics 使用 UIKit 的左上角原点坐标系
        CGContextClearRect(ctx, CGRectMake(0, 0,
                                           CVPixelBufferGetWidth(pixelBuffer),
                                           CVPixelBufferGetHeight(pixelBuffer)));
        [layer renderInContext:ctx];
        UIGraphicsPopContext();
        CGContextRelease(ctx);
        ok = YES;
    }
    CVPixelBufferUnlockBaseAddress(pixelBuffer, 0);
    return ok;
}

/// CVPixelBuffer -> CMSampleBuffer
static CMSampleBufferRef IPATPipCreateSampleBuffer(CVPixelBufferRef pixelBuffer, CMTime pts) {
    CMVideoFormatDescriptionRef format = NULL;
    if (CMVideoFormatDescriptionCreateForImageBuffer(kCFAllocatorDefault, pixelBuffer, &format) != noErr) {
        return NULL;
    }
    CMSampleTimingInfo timing = {kCMTimeInvalid, pts, kCMTimeInvalid};
    CMSampleBufferRef sampleBuffer = NULL;
    OSStatus status = CMSampleBufferCreateReadyWithImageBuffer(kCFAllocatorDefault, pixelBuffer, format,
                                                               &timing, &sampleBuffer);
    CFRelease(format);
    return status == noErr ? sampleBuffer : NULL;
}

#pragma mark - 画中画控制器

@interface IPATPipController : NSObject <AVPictureInPictureControllerDelegate,
                                         AVPictureInPictureSampleBufferPlaybackDelegate>
@property (nonatomic, strong) AVPictureInPictureController *pip;
@property (nonatomic, strong) AVSampleBufferDisplayLayer *displayLayer;
@property (nonatomic, strong) AVPlayerLayer *playerLayer;
@property (nonatomic, strong) AVPlayer *player;
@property (nonatomic, strong) AVAudioPlayer *silencePlayer;
@property (nonatomic, strong) NSTimer *timer;
@property (nonatomic, strong) UIView *hostView;
@property (nonatomic, assign) CVPixelBufferRef renderBuffer;  // CF 类型：手动 CFRetain/CFRelease
@property (nonatomic, assign) CMTime lastPts;
@property (nonatomic, assign) BOOL playbackPaused;
@property (nonatomic, assign) BOOL prepared;
@property (nonatomic, assign) BOOL windowReady;
@end

@implementation IPATPipController

+ (instancetype)shared {
    static IPATPipController *shared;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ shared = [[IPATPipController alloc] init]; });
    return shared;
}

#pragma mark 初始化

- (instancetype)init {
    if ((self = [super init])) {
        _lastPts = kCMTimeZero;
        _playbackPaused = NO;
        [[NSNotificationCenter defaultCenter] addObserver:self
                                                 selector:@selector(handleDidEnterBackground)
                                                     name:UIApplicationDidEnterBackgroundNotification
                                                   object:nil];
        [[NSNotificationCenter defaultCenter] addObserver:self
                                                 selector:@selector(handleWillEnterForeground)
                                                     name:UIApplicationWillEnterForegroundNotification
                                                   object:nil];
        [[NSNotificationCenter defaultCenter] addObserver:self
                                                 selector:@selector(handleWillResignActive)
                                                     name:UIApplicationWillResignActiveNotification
                                                   object:nil];
        // 悬浮控制面板
        [[NSNotificationCenter defaultCenter] addObserver:self
                                                 selector:@selector(handlePanelChange:)
                                                     name:IPATControlDidChangeNotification
                                                   object:nil];
        [[NSNotificationCenter defaultCenter] addObserver:self
                                                 selector:@selector(handlePanelDiscover:)
                                                     name:IPATControlDiscoverNotification
                                                   object:nil];
        // 面板可能比我们晚加载，它会发 Discover 让我们重报一次
        [self registerWithPanel];
    }
    return self;
}

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
    if (_renderBuffer) CVPixelBufferRelease(_renderBuffer);
}

/// 等 App 的第一帧窗口出现后再做准备工作（最多等 ~12s）
- (void)prepareWhenWindowReady:(NSInteger)attempts {
    if (!IPATPipBool(@"Enabled", YES)) return;
    if ([self prepare]) {
        self.windowReady = YES;
        if ([[IPATPipString(@"StartOn") lowercaseString] isEqualToString:@"launch"]) {
            [self startPictureInPicture];
        }
        [self postStatus];
        return;
    }
    if (attempts <= 0) {
        IPATPipLog(@"等待窗口超时，画中画未启用");
        return;
    }
    __weak typeof(self) weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.25 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        [weakSelf prepareWhenWindowReady:attempts - 1];
    });
}

- (BOOL)prepare {
    if (self.prepared) return YES;
    if (![AVPictureInPictureController isPictureInPictureSupported]) {
        IPATPipLog(@"当前设备不支持画中画");
        return NO;
    }
    UIWindow *window = IPATPipKeyWindow();
    if (!window) return NO;

    [self configureAudioSession];

    NSString *videoFile = IPATPipString(@"VideoFile");
    NSURL *videoURL = nil;
    if (videoFile.length > 0) {
        videoURL = [[NSBundle mainBundle] URLForResource:[videoFile stringByDeletingPathExtension]
                                          withExtension:[videoFile pathExtension]];
        if (!videoURL) IPATPipLog(@"Info.plist 里配置的 VideoFile(%@) 不存在，回退到内置画面", videoFile);
    }

    BOOL built = NO;
    if (videoURL) {
        built = [self buildPlayerLayerInWindow:window url:videoURL];
    }
    if (!built) {
        built = [self buildSampleBufferLayerInWindow:window];
    }
    if (!built) {
        IPATPipLog(@"无法建立画中画视频源");
        return NO;
    }

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
    if (@available(iOS 14.2, *)) {
        self.pip.canStartPictureInPictureAutomaticallyFromInline = YES;
    }
#pragma clang diagnostic pop
    self.pip.delegate = self;
    self.prepared = YES;
    IPATPipLog(@"准备完成：%@", videoURL ? @"AVPlayer 视频源" : @"内置画面源");
    return YES;
}

- (void)configureAudioSession {
    if (!IPATPipBool(@"KeepAliveAudio", YES)) return;
    NSError *error = nil;
    AVAudioSession *session = [AVAudioSession sharedInstance];
    [session setCategory:AVAudioSessionCategoryPlayback
             withOptions:AVAudioSessionCategoryOptionMixWithOthers
                   error:&error];
    if (error) IPATPipLog(@"设置音频会话失败: %@", error.localizedDescription);
}

/// 方案 A：播放一段（可自定义的）视频，兼容 iOS 9+
- (BOOL)buildPlayerLayerInWindow:(UIWindow *)window url:(NSURL *)url {
    AVPlayerItem *item = [AVPlayerItem playerItemWithURL:url];
    self.player = [AVPlayer playerWithPlayerItem:item];
    self.player.actionAtItemEnd = AVPlayerActionAtItemEndNone;
    self.player.muted = YES;

    // 循环播放
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(loopPlayback)
                                                 name:AVPlayerItemDidPlayToEndTimeNotification
                                               object:item];

    self.playerLayer = [AVPlayerLayer playerLayerWithPlayer:self.player];
    self.playerLayer.videoGravity = AVLayerVideoGravityResizeAspect;
    [self attachContentView:self.playerLayer inWindow:window];

    if (![AVPictureInPictureController instancesRespondToSelector:@selector(initWithPlayerLayer:)]) return NO;
    self.pip = [[AVPictureInPictureController alloc] initWithPlayerLayer:self.playerLayer];
    [self.player play];
    return self.pip != nil;
}

- (void)loopPlayback {
    [self.player seekToTime:kCMTimeZero];
    [self.player play];
}

/// 方案 B：AVSampleBufferDisplayLayer（iOS 15+，不需要任何素材文件）
- (BOOL)buildSampleBufferLayerInWindow:(UIWindow *)window {
    if (@available(iOS 15.0, *)) {
        Class sourceClass = NSClassFromString(@"AVPictureInPictureControllerContentSource");
        if (!sourceClass) return NO;

        self.displayLayer = [[AVSampleBufferDisplayLayer alloc] init];
        self.displayLayer.videoGravity = AVLayerVideoGravityResizeAspect;
        self.displayLayer.backgroundColor = [UIColor blackColor].CGColor;
        [self attachContentView:self.displayLayer inWindow:window];

        CMTimebaseRef timebase = NULL;
        if (CMTimebaseCreateWithSourceClock(kCFAllocatorDefault, CMClockGetHostTimeClock(), &timebase) == noErr) {
            CMTimebaseSetTime(timebase, kCMTimeZero);
            CMTimebaseSetRate(timebase, 1.0);
            self.displayLayer.controlTimebase = timebase;
            CFRelease(timebase);
        }

        AVPictureInPictureControllerContentSource *source =
            [[sourceClass alloc] initWithSampleBufferDisplayLayer:self.displayLayer playbackDelegate:self];
        if ([AVPictureInPictureController instancesRespondToSelector:@selector(initWithContentSource:)]) {
            self.pip = [[AVPictureInPictureController alloc] initWithContentSource:source];
        }
        return self.pip != nil;
    }
    IPATPipLog(@"系统低于 iOS 15，内置画面源不可用");
    return NO;
}

/// 把视频层挂到窗口上（必须进入视图树，画中画才会认为有内容）
- (void)attachContentView:(CALayer *)layer inWindow:(UIWindow *)window {
    self.hostView = [[UIView alloc] initWithFrame:CGRectMake(-2, -2, 2, 2)];
    self.hostView.userInteractionEnabled = NO;
    self.hostView.backgroundColor = [UIColor clearColor];
    self.hostView.opaque = NO;
    self.hostView.alpha = 0.01;  // 不能是 0/hidden，否则画中画可能拒绝启动
    layer.frame = self.hostView.bounds;
    [self.hostView.layer addSublayer:layer];
    [window addSubview:self.hostView];
    [window bringSubviewToFront:self.hostView];
}

#pragma mark 前后台

- (void)handleWillResignActive {
    if (!IPATPipBool(@"Enabled", YES)) return;
    if (!self.prepared) {
        [self prepare];
    }
    if ([[IPATPipString(@"StartOn") lowercaseString] isEqualToString:@"resignactive"]) {
        [self startPictureInPicture];
    }
}

- (void)handleDidEnterBackground {
    if (!IPATPipBool(@"Enabled", YES)) return;
    if (!self.prepared && !self.windowReady) {
        [self prepare];
    }
    [self startKeepAliveAudio];
    [self startPictureInPicture];
}

- (void)handleWillEnterForeground {
    if (IPATPipBool(@"StopOnForeground", YES)) {
        if (self.pip.isPictureInPictureActive) {
            [self.pip stopPictureInPicture];
        }
        [self stopFrameTimer];
    }
}

/// 静音音频保活：让 App 在后台拿到持续执行时间，给画中画启动留出余量
- (void)startKeepAliveAudio {
    if (!IPATPipBool(@"KeepAliveAudio", YES) || self.silencePlayer) return;
    NSError *error = nil;
    NSData *wav = IPATPipSilentWAV(1.0, 8000);
    self.silencePlayer = [[AVAudioPlayer alloc] initWithData:wav error:&error];
    if (error) {
        IPATPipLog(@"静音保活失败: %@", error.localizedDescription);
        self.silencePlayer = nil;
        return;
    }
    self.silencePlayer.numberOfLoops = -1;
    // 音频本身就是全 0 采样，不需要额外调小音量（音量 0 反而不算"正在播放"）
    [self.silencePlayer play];
}

- (void)stopKeepAliveAudio {
    [self.silencePlayer stop];
    self.silencePlayer = nil;
}

#pragma mark 悬浮控制面板

/// 面板改了开关：重新读配置，把变化立刻落到运行状态上
- (void)applyPanelState {
    if (!IPATPipBool(@"Enabled", YES)) {
        [self stopPictureInPictureNow];
        [self postStatus];
        return;
    }
    // 刚被打开：窗口还没准备好的话重新走一遍准备流程
    if (!self.prepared) {
        [self prepareWhenWindowReady:48];
    }
    // 在后台被打开就直接进画中画；在前台只做准备，等切后台再进
    if ([UIApplication sharedApplication].applicationState != UIApplicationStateActive) {
        [self startKeepAliveAudio];
        [self startPictureInPicture];
    }
    [self postStatus];
}

/// 彻底退出画中画（面板把开关关掉时调用）
- (void)stopPictureInPictureNow {
    [self stopFrameTimer];
    if (self.pip.isPictureInPictureActive) {
        IPATPipLog(@"面板关闭画中画，正在退出");
        [self.pip stopPictureInPicture];
    }
    [self stopKeepAliveAudio];
}

- (void)handlePanelChange:(NSNotification *)note {
    if (![note.userInfo[IPATChgId] isEqual:IPATFeaturePiP]) return;
    [self applyPanelState];
}

- (void)handlePanelDiscover:(NSNotification *)note {
    [self registerWithPanel];
}

/// 把我的开关和能力报给面板，面板按这个生成界面
- (void)registerWithPanel {
    NSDictionary *reg = @{
        IPATRegId: IPATFeaturePiP,
        IPATRegTitle: @"画中画",
        IPATRegDetail: @"切后台自动进入画中画",
        IPATRegMasterKey: IPATKeyPiPEnabled,
        IPATRegEnabled: @(IPATPipBool(@"Enabled", YES)),
        IPATRegRows: @[
            @{IPATRowKey: IPATKeyPiPMode,
              IPATRowTitle: @"画面",
              IPATRowKind: IPATRowKindSegment,
              IPATRowOptions: @[@"黑屏", @"镜像"],
              IPATRowValues: @[@"black", @"mirror"],
              // 跟随 --pip-mode；喂帧逻辑每帧都会重读它，所以切换基本立刻可见
              IPATRowValue: IPATPipString(@"Mode") ?: @"black"},
            @{IPATRowKey: IPATKeyPiPStopOnForeground,
              IPATRowTitle: @"回前台自动退出",
              IPATRowValue: @(IPATPipBool(@"StopOnForeground", YES))},
            @{IPATRowKey: IPATKeyPiPAudio,
              IPATRowTitle: @"静音音频保活",
              IPATRowValue: @(IPATPipBool(@"KeepAliveAudio", YES))},
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
    if (!IPATPipBool(@"Enabled", YES)) {
        detail = @"已关闭";
    } else if (self.pip.isPictureInPictureActive) {
        detail = @"画中画运行中";
    } else if (!self.prepared) {
        detail = @"等待窗口就绪";
    } else {
        BOOL mirror = [[IPATPipString(@"Mode") lowercaseString] isEqualToString:@"mirror"];
        detail = [NSString stringWithFormat:@"已就绪 · %@", mirror ? @"镜像画面" : @"黑画面"];
    }
    [[NSNotificationCenter defaultCenter] postNotificationName:IPATControlStatusNotification
                                                        object:nil
                                                      userInfo:@{IPATRegId: IPATFeaturePiP,
                                                                 IPATStaDetail: detail}];
}

#pragma mark 画中画

- (void)startPictureInPicture {
    if (!self.prepared && ![self prepare]) return;
    if (self.pip.isPictureInPictureActive) return;
    if (self.player && self.player.rate == 0) {
        [self.player play];
    }
    [self startFrameTimer];

    // isPictureInPicturePossible 需要一点时间才变 YES，重试几次
    [self attemptStart:20];
}

- (void)attemptStart:(NSInteger)attempts {
    if (self.pip.isPictureInPictureActive) return;
    if (self.pip.isPictureInPicturePossible) {
        [self.pip startPictureInPicture];
        return;
    }
    if (attempts <= 0) {
        IPATPipLog(@"画中画暂时无法启动（isPictureInPicturePossible = NO）");
        return;
    }
    __weak typeof(self) weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.2 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        [weakSelf attemptStart:attempts - 1];
    });
}

- (void)startFrameTimer {
    if (self.timer || !self.displayLayer) return;
    NSInteger fps = MAX(1, MIN(60, IPATPipInt(@"FrameRate", 10)));
    self.timer = [NSTimer timerWithTimeInterval:1.0 / (double)fps
                                        target:self
                                      selector:@selector(tick)
                                      userInfo:nil
                                       repeats:YES];
    [[NSRunLoop mainRunLoop] addTimer:self.timer forMode:NSRunLoopCommonModes];
}

- (void)stopFrameTimer {
    [self.timer invalidate];
    self.timer = nil;
}

/// 持续喂帧，保证图层一直有内容、画中画不会因为"没在播放"被系统关掉
- (void)tick {
    if (!self.displayLayer) return;

    UIWindow *window = IPATPipKeyWindow();
    CGSize size = window ? window.bounds.size : CGSizeMake(480, 854);
    size_t width = (size_t)MAX(2.0, MIN(1080.0, size.width));
    size_t height = (size_t)MAX(2.0, MIN(1920.0, size.height));

    if (!self.renderBuffer
        || CVPixelBufferGetWidth(self.renderBuffer) != width
        || CVPixelBufferGetHeight(self.renderBuffer) != height) {
        if (self.renderBuffer) CVPixelBufferRelease(self.renderBuffer);
        self.renderBuffer = IPATPipCreateBlackPixelBuffer(width, height);
    }
    if (!self.renderBuffer) return;

    if ([[IPATPipString(@"Mode") lowercaseString] isEqualToString:@"mirror"] && window) {
        IPATPipRenderLayerIntoCVPixelBuffer(window.layer, self.renderBuffer);
    }

    CMSampleBufferRef sampleBuffer = IPATPipCreateSampleBuffer(self.renderBuffer, self.lastPts);
    if (sampleBuffer) {
        if (self.displayLayer.status == AVQueuedSampleBufferRenderingStatusFailed) {
            IPATPipLog(@"图层渲染失败: %@", self.displayLayer.error);
            [self.displayLayer flush];
        }
        if ([self.displayLayer isReadyForMoreMediaData]) {
            [self.displayLayer enqueueSampleBuffer:sampleBuffer];
            self.lastPts = CMTimeAdd(self.lastPts, CMTimeMake(1, 30));
        }
        CFRelease(sampleBuffer);
    }
}

#pragma mark AVPictureInPictureControllerDelegate

- (void)pictureInPictureControllerDidStartPictureInPicture:(AVPictureInPictureController *)controller {
    IPATPipLog(@"已进入画中画");
    [self postStatus];
}

- (void)pictureInPictureControllerDidStopPictureInPicture:(AVPictureInPictureController *)controller {
    IPATPipLog(@"已退出画中画");
    if ([UIApplication sharedApplication].applicationState != UIApplicationStateActive) {
        // 用户手动关闭画中画：停掉保活，让 App 正常进入后台休眠
        [self stopFrameTimer];
        [self stopKeepAliveAudio];
    }
    [self postStatus];
}

- (void)pictureInPictureController:(AVPictureInPictureController *)controller
    failedToStartPictureInPictureWithError:(NSError *)error {
    IPATPipLog(@"画中画启动失败: %@", error.localizedDescription);
    [self stopFrameTimer];
}

- (void)pictureInPictureController:(AVPictureInPictureController *)controller
    restoreUserInterfaceForPictureInPictureStopWithCompletionHandler:(void (^)(BOOL))completionHandler {
    completionHandler(YES);
}

#pragma mark AVPictureInPictureSampleBufferPlaybackDelegate

- (void)pictureInPictureController:(AVPictureInPictureController *)controller setPlaying:(BOOL)playing {
    self.playbackPaused = !playing;
    if (self.player) self.player.rate = playing ? 1.0 : 0.0;
    if (playing) {
        [self startFrameTimer];
    } else {
        [self stopFrameTimer];
    }
}

- (CMTimeRange)pictureInPictureControllerTimeRangeForPlayback:(AVPictureInPictureController *)controller {
    return CMTimeRangeMake(kCMTimeZero, kCMTimePositiveInfinity);
}

- (BOOL)pictureInPictureControllerIsPlaybackPaused:(AVPictureInPictureController *)controller {
    return self.playbackPaused;
}

- (void)pictureInPictureController:(AVPictureInPictureController *)controller
                   skipByInterval:(CMTime)skipInterval
                completionHandler:(void (^)(void))completionHandler {
    completionHandler();
}

@end

#pragma mark - 入口

__attribute__((constructor)) static void IPATPipBackgroundInit(void) {
    // 等主线程起来后再做，避免在 dyld 阶段碰 UIKit
    dispatch_async(dispatch_get_main_queue(), ^{
        [[IPATPipController shared] prepareWhenWindowReady:48];
    });
}
