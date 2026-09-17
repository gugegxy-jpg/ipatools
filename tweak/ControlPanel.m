//
//  ControlPanel.m
//  ipatool 注入用 dylib：应用内悬浮窗 + 小面板，实时开关「后台保活」「文件导入导出」。
//
//  设计要点：
//    1. 自己建一个高层级 UIWindow（canBecomeKeyWindow = NO）：
//       不抢 App 的 keyWindow，空白区域的触摸直接穿透给 App，不影响正常操作；面板展开时会临时铺一层透明层接住「点空白处收起」，收起后即撤掉。
//    2. 与各功能 dylib 只用「通知 + NSUserDefaults」通信（见 IPATControlShared.h）：
//       面板可以单独注入，也允许只注入其中一个功能，谁先加载都行。
//    3. 各功能把自己支持的开关注册给面板，面板按注册结果动态生成界面，
//       所以以后加新功能不用改这个文件。
//    4. 注册里除了开关(switch)、分段(segment)，还支持动作行(action)：
//       整行可点，点了收起面板并转发给功能侧（比如「导出文件」要弹系统界面，
//       面板挡在上面会点不到，所以功能侧还可以发 IPATControlVisibility 让面板先躲开）。
//
//  可通过 Info.plist 的 IPAToolControl 字典调整：
//    Enabled(bool)   默认 YES；NO 表示完全不注入悬浮窗
//    Title(string)   悬浮按钮上的文字，默认 "IPAT"
//    Expanded(bool)  默认 NO；YES 表示启动就展开面板
//

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>
#import "IPATControlShared.h"

#define IPATCpLog(fmt, ...) NSLog(@"[ipatool-panel] " fmt, ##__VA_ARGS__)

#pragma mark - 布局常量

static const CGFloat IPATCpButtonHeight = 34.0;
static const CGFloat IPATCpPanelWidth = 276.0;
static const CGFloat IPATCpInset = 14.0;
static const CGFloat IPATCpTitleHeight = 42.0;
static const CGFloat IPATCpHeaderHeight = 30.0;
static const CGFloat IPATCpRowHeight = 40.0;
static const CGFloat IPATCpNoteHeight = 15.0;

/// 面板行模型里额外记的「这一行属于哪个功能」，不属于跨 dylib 约定
static NSString *const IPATCpRowFeature = @"ipatool.feature";

#pragma mark - 配置

static NSDictionary *IPATCpConfig(void) {
    static NSDictionary *cfg;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        id value = [[NSBundle mainBundle] objectForInfoDictionaryKey:@"IPAToolControl"];
        cfg = [value isKindOfClass:[NSDictionary class]] ? value : @{};
    });
    return cfg;
}

static BOOL IPATCpConfigBool(NSString *key, BOOL fallback) {
    id value = IPATCpConfig()[key];
    return [value respondsToSelector:@selector(boolValue)] ? [value boolValue] : fallback;
}

static NSString *IPATCpConfigString(NSString *key, NSString *fallback) {
    id value = IPATCpConfig()[key];
    return [value isKindOfClass:[NSString class]] ? value : fallback;
}

#pragma mark - NSUserDefaults 读写（面板改过的值都落在这里，功能侧来读）

static id IPATCpStored(NSString *key, id fallback) {
    if (key.length == 0) return fallback;
    id value = [[NSUserDefaults standardUserDefaults] objectForKey:key];
    return value ?: fallback;
}

static BOOL IPATCpStoredBool(NSString *key, BOOL fallback) {
    id value = IPATCpStored(key, nil);
    return [value respondsToSelector:@selector(boolValue)] ? [value boolValue] : fallback;
}

static NSString *IPATCpStoredString(NSString *key, NSString *fallback) {
    id value = IPATCpStored(key, nil);
    return [value isKindOfClass:[NSString class]] ? value : fallback;
}

static void IPATCpStore(NSString *key, id value) {
    if (key.length == 0 || !value) return;
    [[NSUserDefaults standardUserDefaults] setObject:value forKey:key];
}

#pragma mark - 取当前场景（iOS 13+ 一个 App 可能有多个 scene）

static UIWindowScene *IPATCpActiveWindowScene(void) {
    UIWindowScene *foreground = nil;
    UIWindowScene *fallback = nil;
    if (@available(iOS 13.0, *)) {
        for (UIScene *scene in [UIApplication sharedApplication].connectedScenes) {
            if (![scene isKindOfClass:[UIWindowScene class]]) continue;
            UIWindowScene *windowScene = (UIWindowScene *)scene;
            if (windowScene.activationState == UISceneActivationStateForegroundActive) {
                foreground = windowScene;
            }
            if (!fallback) fallback = windowScene;
        }
    }
    return foreground ?: fallback;
}

#pragma mark - 悬浮窗 / 穿透视图

/// 悬浮窗：绝不能变成 keyWindow，否则 App 自己的窗口会 resignKey（游戏可能直接暂停）
@interface IPATCpWindow : UIWindow
@end

@implementation IPATCpWindow

- (BOOL)canBecomeKeyWindow {
    return NO;
}

@end

/// 根视图：空白区域返回 nil，让触摸继续落到下层（App 的）窗口
@interface IPATCpPassThroughView : UIView
@end

@implementation IPATCpPassThroughView

- (UIView *)hitTest:(CGPoint)point withEvent:(UIEvent *)event {
    UIView *hit = [super hitTest:point withEvent:event];
    return hit == self ? nil : hit;
}

@end

#pragma mark - 控制面板

@interface IPATCpController : NSObject

@property (nonatomic, strong) IPATCpWindow *window;
@property (nonatomic, strong) IPATCpPassThroughView *hostView;
@property (nonatomic, strong) UIView *button;
@property (nonatomic, strong) UILabel *buttonLabel;
@property (nonatomic, strong) UIVisualEffectView *panel;
@property (nonatomic, strong) UIScrollView *scroll;
@property (nonatomic, strong) UIView *contentView;
@property (nonatomic, strong) UIView *dismissOverlay;

@property (nonatomic, strong) NSMutableDictionary<NSString *, NSDictionary *> *features;
@property (nonatomic, strong) NSMutableDictionary<NSString *, UILabel *> *detailLabels;
@property (nonatomic, strong) NSMutableDictionary<NSString *, NSString *> *statuses;
@property (nonatomic, strong) NSMutableArray<NSDictionary *> *rowModels;

@property (nonatomic, assign) BOOL expanded;
@property (nonatomic, assign) CGPoint dragStart;
@property (nonatomic, assign) CGFloat contentHeight;

@end

@implementation IPATCpController

+ (instancetype)shared {
    static IPATCpController *shared;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ shared = [[IPATCpController alloc] init]; });
    return shared;
}

- (instancetype)init {
    if ((self = [super init])) {
        _features = [NSMutableDictionary dictionary];
        _detailLabels = [NSMutableDictionary dictionary];
        _statuses = [NSMutableDictionary dictionary];
        _rowModels = [NSMutableArray array];

        NSNotificationCenter *center = [NSNotificationCenter defaultCenter];
        [center addObserver:self
                   selector:@selector(handleRegister:)
                       name:IPATControlRegisterNotification
                     object:nil];
        [center addObserver:self
                   selector:@selector(handleStatus:)
                       name:IPATControlStatusNotification
                     object:nil];
        [center addObserver:self
                   selector:@selector(handleDidBecomeActive)
                       name:UIApplicationDidBecomeActiveNotification
                     object:nil];
        [center addObserver:self
                   selector:@selector(handleVisibility:)
                       name:IPATControlVisibilityNotification
                     object:nil];
    }
    return self;
}

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

#pragma mark 启动

- (void)start {
    if (!IPATCpConfigBool(@"Enabled", YES)) {
        IPATCpLog(@"面板被配置为不显示（IPAToolControl.Enabled = NO）");
        return;
    }
    [self ensureWindowWithAttempts:40];
    // 我们可能比功能 dylib 晚加载，喊一嗓子让它们重新注册
    [[NSNotificationCenter defaultCenter] postNotificationName:IPATControlDiscoverNotification object:nil];

    if (IPATCpConfigBool(@"Expanded", NO)) {
        self.expanded = YES;
    }
}

/// 等 App 的窗口场景就绪（iOS 13+ 太早建窗口会挂不到 scene 上，显示不出来）
- (void)ensureWindowWithAttempts:(NSInteger)attempts {
    if (self.window) {
        self.window.hidden = NO;
        return;
    }
    UIWindowScene *scene = IPATCpActiveWindowScene();
    if (scene) {
        [self attachWindowInScene:scene];
        return;
    }
    if (attempts <= 0) {
        IPATCpLog(@"没拿到 UIWindowScene，悬浮窗未显示");
        return;
    }
    __weak typeof(self) weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.25 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        [weakSelf ensureWindowWithAttempts:attempts - 1];
    });
}

- (void)attachWindowInScene:(UIWindowScene *)scene {
    IPATCpWindow *window = nil;
    if (scene && [IPATCpWindow instancesRespondToSelector:@selector(initWithWindowScene:)]) {
        window = [[IPATCpWindow alloc] initWithWindowScene:scene];
    } else {
        window = [[IPATCpWindow alloc] initWithFrame:[UIScreen mainScreen].bounds];
    }
    window.frame = [UIScreen mainScreen].bounds;
    // 比 Alert 还高，保证浮在 App 所有界面（含弹出的全屏 VC）之上
    window.windowLevel = UIWindowLevelAlert + 100;
    window.backgroundColor = [UIColor clearColor];
    window.opaque = NO;
    window.hidden = YES;

    UIViewController *root = [[UIViewController alloc] init];
    IPATCpPassThroughView *host = [[IPATCpPassThroughView alloc] initWithFrame:window.bounds];
    host.backgroundColor = [UIColor clearColor];
    host.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    root.view = host;
    window.rootViewController = root;

    self.window = window;
    self.hostView = host;

    [self buildButton];
    [self buildPanel];
    [self buildDismissOverlay];
    [self rebuildContent];

    if (self.expanded) {
        [self setExpanded:YES animated:NO];
    }
    window.hidden = NO;
    IPATCpLog(@"悬浮窗已创建");
}

#pragma mark 悬浮按钮

- (void)buildButton {
    CGFloat height = IPATCpButtonHeight;
    NSString *title = IPATCpConfigString(@"Title", @"IPAT");
    CGSize textSize = [title sizeWithAttributes:@{NSFontAttributeName: [self buttonFont]}];
    CGFloat width = MAX(58.0, ceil(textSize.width) + 26.0);

    UIView *button = [[UIView alloc] initWithFrame:CGRectMake(0, 0, width, height)];
    button.layer.cornerRadius = height / 2.0;
    button.layer.borderWidth = 1.0 / [UIScreen mainScreen].scale;
    button.layer.borderColor = [UIColor colorWithWhite:1.0 alpha:0.22].CGColor;
    button.layer.shadowColor = [UIColor blackColor].CGColor;
    button.layer.shadowOpacity = 0.3;
    button.layer.shadowRadius = 6.0;
    button.layer.shadowOffset = CGSizeMake(0, 2);

    UILabel *label = [[UILabel alloc] initWithFrame:button.bounds];
    label.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    label.textAlignment = NSTextAlignmentCenter;
    label.font = [self buttonFont];
    label.textColor = [UIColor whiteColor];
    label.text = title;
    label.userInteractionEnabled = NO;
    [button addSubview:label];

    [button addGestureRecognizer:[[UITapGestureRecognizer alloc] initWithTarget:self
                                                                        action:@selector(handleButtonTap)]];
    UIPanGestureRecognizer *pan = [[UIPanGestureRecognizer alloc] initWithTarget:self
                                                                        action:@selector(handleButtonPan:)];
    pan.maximumNumberOfTouches = 1;
    [button addGestureRecognizer:pan];

    [self.hostView addSubview:button];
    self.button = button;
    self.buttonLabel = label;

    [self restoreButtonPosition];
    [self refreshButtonAppearance];
}

- (UIFont *)buttonFont {
    return [UIFont systemFontOfSize:12.0 weight:UIFontWeightSemibold];
}

/// 位置记在 NSUserDefaults 里，下次进来还在顺手的位置（存成 "x,y"）
- (void)restoreButtonPosition {
    CGRect host = self.hostView.bounds;
    NSString *saved = IPATCpStoredString(IPATKeyButtonFrame, nil);
    NSArray<NSString *> *parts = saved.length > 0 ? [saved componentsSeparatedByString:@","] : nil;
    if (parts.count == 2) {
        self.button.center = CGPointMake(parts[0].doubleValue + self.button.bounds.size.width / 2.0,
                                        parts[1].doubleValue + self.button.bounds.size.height / 2.0);
        [self clampButton];
        return;
    }
    // 默认：右侧、屏幕偏上，避开大多数 App 的底部操作区
    self.button.center = CGPointMake(host.size.width - self.button.bounds.size.width / 2.0 - 8.0,
                                    host.size.height * 0.32);
    [self clampButton];
}

- (void)persistButtonPosition {
    CGRect frame = self.button.frame;
    IPATCpStore(IPATKeyButtonFrame,
                [NSString stringWithFormat:@"%.0f,%.0f", frame.origin.x, frame.origin.y]);
}

- (void)clampButton {
    CGRect host = self.hostView.bounds;
    if (host.size.width <= 0 || host.size.height <= 0) return;
    UIEdgeInsets insets = UIEdgeInsetsMake(4, 4, 4, 4);
    if (@available(iOS 11.0, *)) {
        UIEdgeInsets safe = self.window.safeAreaInsets;
        insets = UIEdgeInsetsMake(MAX(4.0, safe.top), 4.0, MAX(4.0, safe.bottom), 4.0);
    }
    CGSize size = self.button.bounds.size;
    CGFloat x = MIN(MAX(insets.left, CGRectGetMinX(self.button.frame)),
                    host.size.width - size.width - insets.right);
    CGFloat y = MIN(MAX(insets.top, CGRectGetMinY(self.button.frame)),
                    host.size.height - size.height - insets.bottom);
    self.button.frame = CGRectMake(x, y, size.width, size.height);
}

- (void)refreshButtonAppearance {
    BOOL anyEnabled = NO;
    for (NSString *featureId in self.features) {
        NSDictionary *reg = self.features[featureId];
        if (IPATCpStoredBool(reg[IPATRegMasterKey], [reg[IPATRegEnabled] boolValue])) {
            anyEnabled = YES;
            break;
        }
    }
    UIColor *background = anyEnabled
        ? [UIColor colorWithRed:0.16 green:0.62 blue:0.36 alpha:0.92]   // 有功能开着：绿
        : [UIColor colorWithWhite:0.25 alpha:0.85];                    // 全关：灰
    self.button.backgroundColor = background;
    self.buttonLabel.textColor = [UIColor colorWithWhite:1.0 alpha:anyEnabled ? 1.0 : 0.72];
}

- (void)handleButtonTap {
    [self setExpanded:!self.expanded animated:YES];
}

- (void)handleButtonPan:(UIPanGestureRecognizer *)pan {
    CGPoint translation = [pan translationInView:self.hostView];
    if (pan.state == UIGestureRecognizerStateBegan) {
        self.dragStart = self.button.center;
    } else if (pan.state == UIGestureRecognizerStateChanged) {
        self.button.center = CGPointMake(self.dragStart.x + translation.x,
                                        self.dragStart.y + translation.y);
        [self clampButton];
        if (self.expanded) [self layoutPanel];
    } else if (pan.state == UIGestureRecognizerStateEnded
               || pan.state == UIGestureRecognizerStateCancelled) {
        [self persistButtonPosition];
    }
}

#pragma mark 面板

- (void)buildPanel {
    UIBlurEffect *effect = nil;
    if (@available(iOS 13.0, *)) {
        effect = [UIBlurEffect effectWithStyle:UIBlurEffectStyleSystemThinMaterialDark];
    } else {
        effect = [UIBlurEffect effectWithStyle:UIBlurEffectStyleDark];
    }
    UIVisualEffectView *panel = [[UIVisualEffectView alloc] initWithEffect:effect];
    panel.frame = CGRectMake(0, 0, IPATCpPanelWidth, 160);
    panel.layer.cornerRadius = 16.0;
    panel.layer.masksToBounds = YES;
    panel.layer.borderWidth = 1.0 / [UIScreen mainScreen].scale;
    panel.layer.borderColor = [UIColor colorWithWhite:1.0 alpha:0.16].CGColor;
    panel.hidden = YES;

    UIScrollView *scroll = [[UIScrollView alloc] initWithFrame:panel.bounds];
    scroll.showsVerticalScrollIndicator = YES;
    scroll.alwaysBounceVertical = NO;
    scroll.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;

    UIView *content = [[UIView alloc] initWithFrame:CGRectMake(0, 0, IPATCpPanelWidth, 160)];
    [scroll addSubview:content];
    [panel.contentView addSubview:scroll];

    [self.hostView addSubview:panel];
    self.panel = panel;
    self.scroll = scroll;
    self.contentView = content;
}

/// 面板展开时铺在下面的一层透明视图：点它就收起面板。收起后立刻隐藏，
/// 这样平时它不参与命中测试，App 的触摸照旧穿透（见 IPATCpPassThroughView）
- (void)buildDismissOverlay {
    UIView *overlay = [[UIView alloc] initWithFrame:self.hostView.bounds];
    overlay.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    overlay.backgroundColor = [UIColor clearColor];
    overlay.alpha = 0.0;
    overlay.hidden = YES;
    overlay.userInteractionEnabled = NO;
    [overlay addGestureRecognizer:[[UITapGestureRecognizer alloc] initWithTarget:self
                                                                          action:@selector(handleDismissTap)]];
    // 垫在面板下面：点面板本身不算「点空白」，点按钮也不算（按钮在最上层）
    [self.hostView insertSubview:overlay belowSubview:self.panel];
    self.dismissOverlay = overlay;
}

- (void)handleDismissTap {
    [self setExpanded:NO animated:YES];
}

- (void)setExpanded:(BOOL)expanded animated:(BOOL)animated {
    BOOL alreadyInState = (self.expanded == expanded && self.panel.hidden == !expanded);
    self.expanded = expanded;
    if (alreadyInState) return;

    __weak typeof(self) weakSelf = self;
    if (expanded) {
        [self rebuildContent];
        [self layoutPanel];
        self.panel.hidden = NO;
        self.dismissOverlay.hidden = NO;
        self.dismissOverlay.userInteractionEnabled = YES;
        [self.hostView bringSubviewToFront:self.button];
        if (!animated) {
            self.panel.alpha = 1.0;
            self.panel.transform = CGAffineTransformIdentity;
            self.dismissOverlay.alpha = 1.0;
            return;
        }
        self.panel.alpha = 0.0;
        self.panel.transform = CGAffineTransformMakeScale(0.92, 0.92);
        self.dismissOverlay.alpha = 0.0;
        [UIView animateWithDuration:0.18 animations:^{
            weakSelf.panel.alpha = 1.0;
            weakSelf.panel.transform = CGAffineTransformIdentity;
            weakSelf.dismissOverlay.alpha = 1.0;
        }];
        return;
    }

    // 先停掉「点空白收起」：收起动画期间再点一次会重复跑这段动画
    self.dismissOverlay.userInteractionEnabled = NO;
    if (!animated) {
        self.panel.hidden = YES;
        self.dismissOverlay.hidden = YES;
        self.dismissOverlay.alpha = 0.0;
        return;
    }
    [UIView animateWithDuration:0.14 animations:^{
        weakSelf.panel.alpha = 0.0;
        weakSelf.panel.transform = CGAffineTransformMakeScale(0.92, 0.92);
        weakSelf.dismissOverlay.alpha = 0.0;
    } completion:^(BOOL finished) {
        weakSelf.panel.hidden = YES;
        weakSelf.panel.alpha = 1.0;
        weakSelf.panel.transform = CGAffineTransformIdentity;
        weakSelf.dismissOverlay.hidden = YES;
    }];
}

/// 面板贴着按钮放，优先放在空间更大的那一侧
- (void)layoutPanel {
    CGRect host = self.hostView.bounds;
    CGRect button = self.button.frame;
    CGSize size = self.panel.bounds.size;

    CGFloat x;
    if (CGRectGetMidX(button) < host.size.width / 2.0) {
        x = CGRectGetMaxX(button) + 10.0;
    } else {
        x = CGRectGetMinX(button) - size.width - 10.0;
    }
    x = MAX(8.0, MIN(host.size.width - size.width - 8.0, x));

    CGFloat topInset = 8.0, bottomInset = 8.0;
    if (@available(iOS 11.0, *)) {
        UIEdgeInsets safe = self.window.safeAreaInsets;
        topInset = MAX(8.0, safe.top);
        bottomInset = MAX(8.0, safe.bottom);
    }
    CGFloat y = CGRectGetMidY(button) - size.height / 2.0;
    y = MAX(topInset, MIN(host.size.height - size.height - bottomInset, y));

    self.panel.frame = CGRectMake(x, y, size.width, size.height);
}

#pragma mark 面板内容

- (void)rebuildContent {
    [self.rowModels removeAllObjects];
    [self.detailLabels removeAllObjects];
    for (UIView *subview in [self.contentView.subviews copy]) {
        [subview removeFromSuperview];
    }

    CGFloat width = IPATCpPanelWidth;
    CGFloat y = IPATCpTitleHeight;

    UILabel *title = [[UILabel alloc] initWithFrame:CGRectMake(IPATCpInset, 0,
                                                              width - IPATCpInset * 2, IPATCpTitleHeight)];
    title.font = [UIFont systemFontOfSize:15.0 weight:UIFontWeightSemibold];
    title.textColor = [UIColor whiteColor];
    title.text = @"ipatool 控制面板";
    [self.contentView addSubview:title];

    UILabel *hint = [[UILabel alloc] initWithFrame:CGRectMake(width - IPATCpInset - 90,
                                                              IPATCpTitleHeight - 26, 90, 18)];
    hint.font = [UIFont systemFontOfSize:11.0];
    hint.textColor = [UIColor colorWithWhite:1.0 alpha:0.45];
    hint.textAlignment = NSTextAlignmentRight;
    hint.text = @"点空白收起";
    [self.contentView addSubview:hint];

    for (NSString *featureId in [self sortedFeatureIds]) {
        y = [self addSection:self.features[featureId] y:y width:width];
    }

    if (self.features.count == 0) {
        UILabel *empty = [[UILabel alloc] initWithFrame:CGRectMake(IPATCpInset, y + 6,
                                                                   width - IPATCpInset * 2, 40)];
        empty.numberOfLines = 2;
        empty.font = [UIFont systemFontOfSize:12.0];
        empty.textColor = [UIColor colorWithWhite:1.0 alpha:0.6];
        empty.text = @"没有检测到可控制的功能。\n请确认注入了后台保活 / 文件导入导出组件。";
        [self.contentView addSubview:empty];
        y += 52;
    } else {
        UILabel *footer = [[UILabel alloc] initWithFrame:CGRectMake(IPATCpInset, y + 6,
                                                                    width - IPATCpInset * 2, 16)];
        footer.font = [UIFont systemFontOfSize:10.5];
        footer.textColor = [UIColor colorWithWhite:1.0 alpha:0.42];
        footer.text = @"改动立即生效，并记住到下次启动；拖动按钮可换位置";
        [self.contentView addSubview:footer];
        y += 26;
    }

    self.contentHeight = y + 8.0;
    CGFloat maxHeight = MAX(180.0, self.hostView.bounds.size.height * 0.62);
    CGFloat panelHeight = MIN(self.contentHeight, maxHeight);

    self.contentView.frame = CGRectMake(0, 0, width, self.contentHeight);
    self.scroll.contentSize = CGSizeMake(width, self.contentHeight);
    self.scroll.frame = CGRectMake(0, 0, width, panelHeight);
    self.panel.frame = CGRectMake(self.panel.frame.origin.x, self.panel.frame.origin.y,
                                  width, panelHeight);
    [self refreshButtonAppearance];
}

/// 顺序固定一下，免得每次加载顺序不同导致界面跳来跳去
- (NSArray<NSString *> *)sortedFeatureIds {
    NSArray *order = @[IPATFeatureKeepAlive, IPATFeatureFiles];
    NSMutableArray<NSString *> *ids = [NSMutableArray array];
    for (NSString *featureId in order) {
        if (self.features[featureId]) [ids addObject:featureId];
    }
    for (NSString *featureId in self.features) {
        if (![ids containsObject:featureId]) [ids addObject:featureId];
    }
    return ids;
}

- (CGFloat)addSection:(NSDictionary *)reg y:(CGFloat)y width:(CGFloat)width {
    NSString *featureId = reg[IPATRegId] ?: @"";
    NSString *masterKey = reg[IPATRegMasterKey] ?: @"";
    // 主开关可以整块不画：比如「文件导入导出」注入即可用，没有需要关的场景
    BOOL masterHidden = [reg[IPATRegMasterHidden] respondsToSelector:@selector(boolValue)]
        ? [reg[IPATRegMasterHidden] boolValue] : NO;
    CGFloat contentWidth = width - IPATCpInset * 2;

    UILabel *name = [[UILabel alloc] initWithFrame:CGRectMake(IPATCpInset, y,
                                                              masterHidden ? contentWidth
                                                                           : contentWidth - 60,
                                                              24)];
    name.font = [UIFont systemFontOfSize:14.0 weight:UIFontWeightMedium];
    name.textColor = [UIColor whiteColor];
    name.text = reg[IPATRegTitle] ?: featureId;
    [self.contentView addSubview:name];

    if (!masterHidden) {
        UISwitch *master = [[UISwitch alloc] init];
        master.onTintColor = [UIColor colorWithRed:0.16 green:0.62 blue:0.36 alpha:1.0];
        master.on = IPATCpStoredBool(masterKey, [reg[IPATRegEnabled] boolValue]);
        master.tag = (NSInteger)self.rowModels.count;
        [master addTarget:self action:@selector(handleControlChanged:)
         forControlEvents:UIControlEventValueChanged];
        master.frame = CGRectMake(width - IPATCpInset - master.bounds.size.width,
                                  y + (24.0 - master.bounds.size.height) / 2.0,
                                  master.bounds.size.width, master.bounds.size.height);
        [self.contentView addSubview:master];
        [self.rowModels addObject:@{IPATRowKey: masterKey, IPATCpRowFeature: featureId}];
    }

    y += IPATCpHeaderHeight;

    // 状态行：功能侧通过 IPATControlStatusNotification 实时更新
    UILabel *detail = [[UILabel alloc] initWithFrame:CGRectMake(IPATCpInset, y, contentWidth, 15)];
    detail.font = [UIFont systemFontOfSize:11.0];
    detail.textColor = [UIColor colorWithWhite:1.0 alpha:0.55];
    detail.lineBreakMode = NSLineBreakByTruncatingTail;
    // 面板打开前收到的状态也要显示出来，否则只能看到静态说明
    detail.text = self.statuses[featureId] ?: (reg[IPATRegDetail] ?: @"");
    [self.contentView addSubview:detail];
    if (featureId.length > 0) self.detailLabels[featureId] = detail;

    y += 18.0;

    NSArray *rows = reg[IPATRegRows];
    if (![rows isKindOfClass:[NSArray class]] || rows.count == 0) return y + 6.0;

    UIView *line = [[UIView alloc] initWithFrame:CGRectMake(IPATCpInset, y, contentWidth,
                                                            1.0 / [UIScreen mainScreen].scale)];
    line.backgroundColor = [UIColor colorWithWhite:1.0 alpha:0.12];
    [self.contentView addSubview:line];
    y += 1.0;

    for (NSDictionary *row in rows) {
        if (![row isKindOfClass:[NSDictionary class]]) continue;
        y = [self addRow:row featureId:featureId y:y width:width];
    }
    return y + 8.0;
}

- (CGFloat)addRow:(NSDictionary *)row featureId:(NSString *)featureId y:(CGFloat)y width:(CGFloat)width {
    CGFloat contentWidth = width - IPATCpInset * 2;
    NSString *key = row[IPATRowKey] ?: @"";
    NSString *kind = row[IPATRowKind] ?: IPATRowKindSwitch;
    NSString *note = row[IPATRowNote];

    if ([kind isEqualToString:IPATRowKindAction]) {
        return [self addActionRow:row key:key featureId:featureId y:y width:width note:note];
    }

    UILabel *title = [[UILabel alloc] initWithFrame:CGRectMake(IPATCpInset + 2.0, y,
                                                               contentWidth - 110.0, IPATCpRowHeight)];
    title.font = [UIFont systemFontOfSize:13.0];
    title.textColor = [UIColor colorWithWhite:1.0 alpha:0.92];
    title.text = row[IPATRowTitle] ?: key;
    [self.contentView addSubview:title];

    NSMutableDictionary *model = [row mutableCopy];
    model[IPATCpRowFeature] = featureId;

    UIControl *control = nil;
    if ([kind isEqualToString:IPATRowKindSegment]) {
        NSArray *options = row[IPATRowOptions];
        NSArray *values = row[IPATRowValues];
        if (![options isKindOfClass:[NSArray class]] || options.count == 0) return y + IPATCpRowHeight;
        UISegmentedControl *segmented = [[UISegmentedControl alloc] initWithItems:options];
        [segmented setTitleTextAttributes:@{NSFontAttributeName: [UIFont systemFontOfSize:11.0]}
                                 forState:UIControlStateNormal];
        CGFloat segWidth = MIN(contentWidth - 120.0, 150.0);
        segmented.frame = CGRectMake(width - IPATCpInset - segWidth, y + 7.0, segWidth, 27.0);
        NSString *current = IPATCpStoredString(key, row[IPATRowValue]);
        NSInteger index = [values isKindOfClass:[NSArray class]] ? (NSInteger)[values indexOfObject:current]
                                                                 : NSNotFound;
        segmented.selectedSegmentIndex = (index == NSNotFound) ? 0 : index;
        control = segmented;
    } else {
        UISwitch *toggle = [[UISwitch alloc] init];
        toggle.onTintColor = [UIColor colorWithRed:0.16 green:0.62 blue:0.36 alpha:1.0];
        toggle.on = IPATCpStoredBool(key, [row[IPATRowValue] boolValue]);
        toggle.frame = CGRectMake(width - IPATCpInset - toggle.bounds.size.width,
                                  y + (IPATCpRowHeight - toggle.bounds.size.height) / 2.0,
                                  toggle.bounds.size.width, toggle.bounds.size.height);
        control = toggle;
    }

    control.tag = (NSInteger)self.rowModels.count;
    [control addTarget:self action:@selector(handleControlChanged:)
      forControlEvents:UIControlEventValueChanged];
    [self.contentView addSubview:control];
    [self.rowModels addObject:model];

    y += IPATCpRowHeight;
    if ([note isKindOfClass:[NSString class]] && note.length > 0) {
        UILabel *noteLabel = [[UILabel alloc] initWithFrame:CGRectMake(IPATCpInset + 2.0, y - 4.0,
                                                                      contentWidth - 110.0,
                                                                      IPATCpNoteHeight)];
        noteLabel.font = [UIFont systemFontOfSize:10.0];
        noteLabel.textColor = [UIColor colorWithWhite:1.0 alpha:0.42];
        noteLabel.text = note;
        [self.contentView addSubview:noteLabel];
        y += IPATCpNoteHeight;
    }
    return y;
}

/// 动作行：整行可点，点了收起面板，把动作转给功能侧去处理（一般要弹系统界面）
- (CGFloat)addActionRow:(NSDictionary *)row key:(NSString *)key featureId:(NSString *)featureId
                      y:(CGFloat)y width:(CGFloat)width note:(NSString *)note {
    CGFloat contentWidth = width - IPATCpInset * 2;

    UIButton *action = [UIButton buttonWithType:UIButtonTypeSystem];
    action.frame = CGRectMake(IPATCpInset, y, contentWidth, IPATCpRowHeight);
    action.contentHorizontalAlignment = UIControlContentHorizontalAlignmentLeft;
    action.titleLabel.font = [UIFont systemFontOfSize:13.0];
    action.titleLabel.lineBreakMode = NSLineBreakByTruncatingTail;
    [action setTitle:(row[IPATRowTitle] ?: key) forState:UIControlStateNormal];
    [action setTitleColor:[UIColor colorWithRed:0.32 green:0.72 blue:1.0 alpha:1.0]
                 forState:UIControlStateNormal];
    action.tag = (NSInteger)self.rowModels.count;
    [action addTarget:self action:@selector(handleActionTap:)
     forControlEvents:UIControlEventTouchUpInside];
    [self.contentView addSubview:action];

    // 右侧箭头示意「点了会发生点什么」；盖在按钮上层，但不能吃掉点击
    UILabel *chevron = [[UILabel alloc] initWithFrame:CGRectMake(width - IPATCpInset - 12.0, y,
                                                                12.0, IPATCpRowHeight)];
    chevron.font = [UIFont systemFontOfSize:14.0 weight:UIFontWeightSemibold];
    chevron.textColor = [UIColor colorWithWhite:1.0 alpha:0.4];
    chevron.textAlignment = NSTextAlignmentRight;
    chevron.text = @"›";
    chevron.userInteractionEnabled = NO;
    [self.contentView addSubview:chevron];

    [self.rowModels addObject:@{IPATRowKey: key, IPATCpRowFeature: featureId}];

    y += IPATCpRowHeight;
    if ([note isKindOfClass:[NSString class]] && note.length > 0) {
        UILabel *noteLabel = [[UILabel alloc] initWithFrame:CGRectMake(IPATCpInset + 2.0, y - 4.0,
                                                                      contentWidth - 110.0,
                                                                      IPATCpNoteHeight)];
        noteLabel.font = [UIFont systemFontOfSize:10.0];
        noteLabel.textColor = [UIColor colorWithWhite:1.0 alpha:0.42];
        noteLabel.text = note;
        [self.contentView addSubview:noteLabel];
        y += IPATCpNoteHeight;
    }
    return y;
}

#pragma mark 交互

- (void)handleControlChanged:(UIControl *)control {
    NSInteger index = control.tag;
    if (index < 0 || index >= (NSInteger)self.rowModels.count) return;
    NSDictionary *model = self.rowModels[(NSUInteger)index];
    NSString *key = model[IPATRowKey];
    if (key.length == 0) return;

    id value = nil;
    if ([control isKindOfClass:[UISwitch class]]) {
        value = @([(UISwitch *)control isOn]);
    } else if ([control isKindOfClass:[UISegmentedControl class]]) {
        UISegmentedControl *segmented = (UISegmentedControl *)control;
        NSArray *values = model[IPATRowValues];
        NSInteger selected = segmented.selectedSegmentIndex;
        if (![values isKindOfClass:[NSArray class]] || selected < 0
            || selected >= (NSInteger)values.count) {
            return;
        }
        value = values[(NSUInteger)selected];
    }
    if (!value) return;

    IPATCpStore(key, value);
    [self notifyFeature:model[IPATCpRowFeature]];
    [self refreshButtonAppearance];
}

/// 通知功能侧：配置已经落到 NSUserDefaults，请重新读取并立即生效
- (void)notifyFeature:(NSString *)featureId {
    if (featureId.length == 0) return;
    NSDictionary *reg = self.features[featureId];
    NSMutableDictionary *values = [NSMutableDictionary dictionary];
    NSArray *rows = reg[IPATRegRows];
    if ([rows isKindOfClass:[NSArray class]]) {
        for (NSDictionary *row in rows) {
            if (![row isKindOfClass:[NSDictionary class]]) continue;
            NSString *key = row[IPATRowKey];
            id stored = key.length > 0 ? [[NSUserDefaults standardUserDefaults] objectForKey:key] : nil;
            if (stored) values[key] = stored;
        }
    }
    NSDictionary *userInfo = @{
        IPATChgId: featureId,
        IPATChgEnabled: @(IPATCpStoredBool(reg[IPATRegMasterKey], [reg[IPATRegEnabled] boolValue])),
        IPATChgValues: values,
    };
    [[NSNotificationCenter defaultCenter] postNotificationName:IPATControlDidChangeNotification
                                                        object:nil
                                                      userInfo:userInfo];
}

/// 动作行被点击：先收起面板（省得挡住接下来弹出的系统界面），再把动作转给功能侧
- (void)handleActionTap:(UIButton *)button {
    NSInteger index = button.tag;
    if (index < 0 || index >= (NSInteger)self.rowModels.count) return;
    NSDictionary *model = self.rowModels[(NSUInteger)index];
    NSString *key = model[IPATRowKey];
    if (key.length == 0) return;

    [self setExpanded:NO animated:YES];
    IPATCpLog(@"动作行被点击: %@", key);
    [[NSNotificationCenter defaultCenter] postNotificationName:IPATControlActionNotification
                                                        object:nil
                                                      userInfo:@{IPATChgId: model[IPATCpRowFeature] ?: @"",
                                                                 IPATActKey: key}];
}

/// 功能侧要弹系统界面（文件 App 等）时让悬浮窗先躲开，结束再喊回来
- (void)handleVisibility:(NSNotification *)note {
    id visible = note.userInfo[IPATVisVisible];
    if (![visible respondsToSelector:@selector(boolValue)]) return;
    BOOL show = [visible boolValue];
    self.window.hidden = !show;
    IPATCpLog(@"悬浮窗%@", show ? @"已恢复" : @"临时隐藏");
}

#pragma mark 通知

- (void)handleRegister:(NSNotification *)note {
    NSDictionary *userInfo = note.userInfo;
    if (![userInfo isKindOfClass:[NSDictionary class]]) return;
    NSString *featureId = userInfo[IPATRegId];
    if (![featureId isKindOfClass:[NSString class]] || featureId.length == 0) return;

    self.features[featureId] = userInfo;
    IPATCpLog(@"功能已注册: %@", featureId);
    if (self.expanded) {
        [self rebuildContent];
        [self layoutPanel];
    } else {
        [self refreshButtonAppearance];
    }
}

- (void)handleStatus:(NSNotification *)note {
    NSDictionary *userInfo = note.userInfo;
    if (![userInfo isKindOfClass:[NSDictionary class]]) return;
    NSString *featureId = userInfo[IPATRegId];
    NSString *detail = userInfo[IPATStaDetail];
    if (![featureId isKindOfClass:[NSString class]] || ![detail isKindOfClass:[NSString class]]) return;

    self.statuses[featureId] = detail;
    UILabel *label = self.detailLabels[featureId];
    if (label) label.text = detail;
}

- (void)handleDidBecomeActive {
    // App 可能重建过窗口（比如 scene 重连），窗口没了或挂不到 scene 上就整个重建
    BOOL orphaned = NO;
    if (@available(iOS 13.0, *)) {
        orphaned = (self.window.windowScene == nil);
    }
    if (!self.window || orphaned) {
        self.window = nil;
        self.hostView = nil;
        self.button = nil;
        self.buttonLabel = nil;
        self.panel = nil;
        self.scroll = nil;
        self.contentView = nil;
        self.dismissOverlay = nil;
        [self ensureWindowWithAttempts:8];
    }
}

@end

#pragma mark - 入口

__attribute__((constructor)) static void IPATControlPanelInit(void) {
    // 等主队列起来再碰 UIKit
    dispatch_async(dispatch_get_main_queue(), ^{
        [[IPATCpController shared] start];
    });
}
