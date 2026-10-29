//
//  AnyVpn.m
//  VPN 隧道插件（独立 dylib）：把 anyvpn 项目（libopenconnect / Cisco AnyConnect
//  协议客户端）编译进 iOS tweak，注入宿主 App 后在游戏内悬浮窗里挂「VPN 隧道」
//  一节，可连接 / 断开 / 自动连接。
//
//  架构对齐 anyvpn 的 Android 端（anyvpn-jni.c）：
//    - 认证表单自动回填（账号 / 密码 / 认证组），多段式认证零交互
//    - 证书校验走 TOFU：第一次连接记指纹，之后不一致才拒绝
//    - openconnect 的 socket 绑定到底层网卡（等价 VpnService.protect），防路由环路
//    - TUN：创建 utun 内核接口，把 openconnect 的 tun fd 接进去
//
//  平台限制（务必知晓）：
//    - iOS 上配置 utun 地址 / 加系统路由需要 root（越狱）。非越狱环境 utun
//      能创建、隧道协议能握手，但没有 root 配不了地址与路由，流量过不去 ——
//      这种情况下插件会明确打日志提示，而不是假装已连上。
//    - 系统级 VPN 的正规途径是 NetworkExtension App（另立工程），不在本 dylib 范围。
//
//  配置（Info.plist IPAToolAnyVpn 字典，由 ipatool --anyvpn-* 写入）：
//    Server / User / Password / AuthGroup / DisableDTLS / AutoConnect /
//    UnderlyingIface（默认 en0） / VersionString / ReportedOS
//  自动连接与禁用 DTLS 也可以在游戏内悬浮窗里改（NSUserDefaults 优先）。
//
//  依赖 tweak/anyvpn/prebuilt/ 下的 iOS arm64 静态库
//  （libopenconnect / libssl / libcrypto / libxml2），
//  编译方法见 anyvpn/build-openconnect-ios.sh。
//
#import <UIKit/UIKit.h>
#import "IPATControlShared.h"
#import "AnyVpnT2S.h"

#import <openconnect.h>

#import <sys/socket.h>
#import <sys/ioctl.h>
// iPhoneOS SDK 不带 sys/kern_control.h（macOS 才有），按 xnu 固定 ABI 自备；
// 若哪天 SDK 带了则优先用系统的
#if __has_include(<sys/kern_control.h>)
#import <sys/kern_control.h>
#else
#define MAX_KCTL_NAME 96
struct ctl_info {
    u_int32_t ctl_id;                     /* 控制器内核分配的 id */
    char      ctl_name[MAX_KCTL_NAME];
};
struct sockaddr_ctl {
    u_char    sc_len;                     /* sizeof(struct sockaddr_ctl) */
    u_char    sc_family;                  /* AF_SYSTEM */
    u_int16_t ss_sysaddr;                 /* AF_SYS_CONTROL */
    u_int32_t sc_id;                      /* 控制器 id（CTLIOCGINFO 查得） */
    u_int32_t sc_unit;                    /* 0 = 内核自动分配 */
    u_int32_t sc_reserved[5];
};
#ifndef CTLIOCGINFO
#define CTLIOCGINFO _IOWR('N', 3, struct ctl_info)  /* 由名字查 id */
#endif
/* AF_SYSTEM 域的 control 协议号（iOS 的 sys/socket.h 不带；xnu 固定为 2） */
#ifndef SYSPROTO_CONTROL
#define SYSPROTO_CONTROL 2
#endif
#endif
#import <net/if.h>
// net/if_utun.h 同样只有 macOS SDK 有
#if __has_include(<net/if_utun.h>)
#import <net/if_utun.h>
#else
#define UTUN_CONTROL_NAME       "com.apple.net.utun_control"
#define UTUN_FLAGS              0
#define UTUN_CTRL_FLAGS         0
#define UTUN_UNIT_NAME          "utun"
#define UTUN_UNIT_NUMBER_OFFSET 9
#endif
// iPhoneOS SDK 不带 net/route.h（macOS 才有），按 xnu ABI 自备老式 BSD 路由
// ioctl 所需的 ortentry；哪天 SDK 带了则优先用系统的
#if __has_include(<net/route.h>)
#import <net/route.h>
#else
struct ifnet;   /* ortentry 里只有指针字段，用户态无需完整定义 */
struct ortentry {
    u_long          rt_hash;
    struct sockaddr rt_dst;
    struct sockaddr rt_gateway;
    short           rt_flags;
    short           rt_refcnt;
    u_long          rt_use;
    struct ifnet   *rt_ifp;
};
#ifndef RTF_UP
#define RTF_UP      0x1
#define RTF_GATEWAY 0x2
#endif
#ifndef SIOCADDRT
#define SIOCADDRT   _IOWR('r', 10, struct ortentry)
#define SIOCDELRT   _IOWR('r', 11, struct ortentry)
#endif
#endif
#import <netinet/in.h>
#import <arpa/inet.h>
#import <unistd.h>

#pragma mark - 配置键

#define IPATFeatureAnyVpn     @"anyvpn"
#define IPATKeyAnyVpnEnabled  @"IPAToolPanelAnyVpnEnabled"   // 总开关（连接状态）
#define IPATKeyAnyVpnAuto     @"IPAToolPanelAnyVpnAuto"      // 启动自动连接
#define IPATKeyAnyVpnNoDTLS   @"IPAToolPanelAnyVpnNoDTLS"    // 禁用 DTLS
#define IPATKeyAnyVpnConnect  @"IPAToolPanelAnyVpnConnect"   // 动作行：连接
#define IPATKeyAnyVpnDisc     @"IPAToolPanelAnyVpnDisconnect"// 动作行：断开
#define IPAToolAnyVpnPlistKey @"IPAToolAnyVpn"               // Info.plist 初始配置字典

#pragma mark - C 辅助：utun 创建与 root 网络配置

// xnu 的 utun 控制接口；getsockopt(SYSPROTO_CONTROL, 2) 取回接口名（utunN）。
// 这个 optname 没有公开宏，xnu net/utun_ctl.c 里固定为 2。
static int create_utun(char ifname[IFNAMSIZ]) {
    int s = socket(PF_SYSTEM, SOCK_DGRAM, SYSPROTO_CONTROL);
    if (s < 0) return -1;
    struct ctl_info ci;
    memset(&ci, 0, sizeof ci);
    strlcpy(ci.ctl_name, UTUN_CONTROL_NAME, sizeof ci.ctl_name);
    if (ioctl(s, CTLIOCGINFO, &ci) < 0) { close(s); return -1; }
    struct sockaddr_ctl sc;
    memset(&sc, 0, sizeof sc);
    sc.sc_len = sizeof sc;
    sc.sc_family = AF_SYSTEM;
    sc.ss_sysaddr = SYSPROTO_CONTROL;
    sc.sc_id = ci.ctl_id;
    sc.sc_unit = 0;   // 0 = 内核自动挑一个空闲 unit
    if (connect(s, (struct sockaddr *)&sc, sizeof sc) < 0) { close(s); return -1; }
    socklen_t len = IFNAMSIZ;
    if (getsockopt(s, SYSPROTO_CONTROL, 2, ifname, &len) < 0) { close(s); return -1; }
    return s;
}

static int make_sin(struct sockaddr_in *sin, const char *text) {
    memset(sin, 0, sizeof *sin);
    sin->sin_len = sizeof *sin;
    sin->sin_family = AF_INET;
    return text && *text && inet_pton(AF_INET, text, &sin->sin_addr) == 1;
}

// 给 utun 配 IPv4 地址 + 点对点对端 + 掩码，并把接口置 UP（都需要 root）
static int ifconfig_tun(const char *ifname, const char *addr,
                        const char *dest, const char *mask) {
    int s = socket(AF_INET, SOCK_DGRAM, 0);
    if (s < 0) return -1;
    int rc = -1;
    struct ifaliasreq ifra;
    memset(&ifra, 0, sizeof ifra);
    strlcpy(ifra.ifra_name, ifname, IFNAMSIZ);
    if (make_sin((struct sockaddr_in *)&ifra.ifra_addr, addr) &&
        make_sin((struct sockaddr_in *)&ifra.ifra_broadaddr, dest) &&
        make_sin((struct sockaddr_in *)&ifra.ifra_mask, mask) &&
        ioctl(s, SIOCAIFADDR, &ifra) == 0) {
        struct ifreq ifr;
        memset(&ifr, 0, sizeof ifr);
        strlcpy(ifr.ifr_name, ifname, IFNAMSIZ);
        if (ioctl(s, SIOCGIFFLAGS, &ifr) == 0) {
            ifr.ifr_flags |= IFF_UP | IFF_RUNNING;
            rc = (ioctl(s, SIOCSIFFLAGS, &ifr) == 0) ? 0 : -1;
        }
    }
    close(s);
    return rc;
}

// 加一条 IPv4 路由（网关 = 隧道本端地址，内核按点对点对端解析到 utun）
// dest == NULL 时加默认路由（0.0.0.0/1 + 128.0.0.0/1 两段覆盖，不惊动原默认路由）。
static int route_add(int s, const char *dest, const char *gw) {
    struct ortentry ro;
    memset(&ro, 0, sizeof ro);
    ro.rt_flags = RTF_UP | RTF_GATEWAY;
    struct sockaddr_in sin;
    if (!make_sin(&sin, dest ? dest : "0.0.0.0")) return -1;
    ro.rt_dst = *(struct sockaddr *)&sin;
    if (!make_sin(&sin, gw)) return -1;
    ro.rt_gateway = *(struct sockaddr *)&sin;
    // BSD ortentry 没有 genmask 字段（部分掩码路由需 PF_ROUTE 消息接口，
    // 老式 ioctl 只支持 host/默认路由；dest 为空即默认路由 0.0.0.0）
    return ioctl(s, SIOCADDRT, &ro) == 0 ? 0 : -1;
}

static int route_del(int s, const char *dest, const char *gw) {
    struct ortentry ro;
    memset(&ro, 0, sizeof ro);
    ro.rt_flags = RTF_UP | RTF_GATEWAY;
    struct sockaddr_in sin;
    if (!make_sin(&sin, dest ? dest : "0.0.0.0")) return -1;
    ro.rt_dst = *(struct sockaddr *)&sin;
    if (!make_sin(&sin, gw)) return -1;
    ro.rt_gateway = *(struct sockaddr *)&sin;
    return ioctl(s, SIOCDELRT, &ro) == 0 ? 0 : -1;
}

static int ifindex_of(const char *ifname) {
    if (!ifname || !*ifname) return 0;
    unsigned idx = if_nametoindex(ifname);
    return idx ? (int)idx : 0;
}

#pragma mark - openconnect 回调（静态全局，对齐 anyvpn-jni.c 的做法）

static struct openconnect_info *g_vpninfo = NULL;
static int g_cmd_fd = -1;
static int g_underlying_idx = 0;      // VPN 自身 socket 绑定的底层网卡（防环路）
static int g_tun_fd = -1;

// 会话配置（连接前由 ObjC 侧填好）
static NSString *g_cfgUser = nil;
static NSString *g_cfgPass = nil;
static NSString *g_cfgGroup = nil;
static NSString *g_cfgServer = nil;
static NSString *g_certKey = nil;     // TOFU 指纹存 NSUserDefaults 用的键

#define LOG_DROP_LEVEL 3   // 丢弃 PRG_TRACE 每包日志，同 Android 端

static void cb_progress(void *privdata, int level, const char *fmt, ...) {
    if (level >= LOG_DROP_LEVEL) return;
    char buf[1024];
    va_list ap;
    va_start(ap, fmt);
    vsnprintf(buf, sizeof buf, fmt, ap);
    va_end(ap);
    IPATAppendLogLine([NSString stringWithFormat:@"[anyvpn] %s", buf]);
}

// TOFU：第一次记住网关证书指纹并放行，之后不一致才拒绝
static int cb_validate_peer_cert(void *privdata, const char *reason) {
    const char *hash = openconnect_get_peer_cert_hash(g_vpninfo);
    NSString *fp = hash ? [NSString stringWithUTF8String:hash] : @"";
    NSUserDefaults *ud = [NSUserDefaults standardUserDefaults];
    NSString *saved = [ud stringForKey:g_certKey];
    if (!saved) {
        [ud setObject:fp forKey:g_certKey];
        IPATAppendLogLine([NSString stringWithFormat:@"[anyvpn] 首次连接，已记录网关证书指纹 %@", fp]);
        return 0;
    }
    if ([saved isEqualToString:fp]) return 0;
    IPATAppendLogLine([NSString stringWithFormat:
        @"[anyvpn] 证书指纹变化，拒绝连接（旧 %@ 新 %@，原因 %s）", saved, fp, reason ?: ""]);
    return 1;
}

// 认证表单自动回填：账号 / 密码 / 认证组；识别不了的字段一律取消并提示
static int cb_auth_form(void *privdata, struct oc_auth_form *form) {
    if (form->message && form->message[0])
        IPATAppendLogLine([NSString stringWithFormat:@"[anyvpn] 表单：%s", form->message]);

    BOOL allKnown = YES;
    for (struct oc_form_opt *o = form->opts; o; o = o->next) {
        if (o->type == OC_FORM_OPT_HIDDEN || !o->name) continue;
        NSString *name = [NSString stringWithUTF8String:o->name];
        if (o->type == OC_FORM_OPT_SELECT) {
            struct oc_form_opt_select *sel = (struct oc_form_opt_select *)o;
            NSString *want = g_cfgGroup;
            int pick = -1;
            if (want.length) {
                for (int c = 0; c < sel->nr_choices; c++) {
                    const char *ln = sel->choices[c]->label;
                    const char *nn = sel->choices[c]->name;
                    if ((ln && [want caseInsensitiveCompare:[NSString stringWithUTF8String:ln]] == NSOrderedSame) ||
                        (nn && [want caseInsensitiveCompare:[NSString stringWithUTF8String:nn]] == NSOrderedSame)) {
                        pick = c;
                        break;
                    }
                }
            }
            if (o == (struct oc_form_opt *)form->authgroup_opt) {
                // 认证组是专用字段，走 authgroup_selection
                form->authgroup_selection = pick >= 0 ? pick : 0;
                continue;
            }
            // 普通下拉：按组名匹配，没配或没匹配上就选第一个
            int use = pick >= 0 ? pick : 0;
            if (use < sel->nr_choices && sel->choices[use]->name)
                openconnect_set_option_value(o, sel->choices[use]->name);
            continue;
        }
        NSString *val = nil;
        if ([name rangeOfString:@"user" options:NSCaseInsensitiveSearch].length &&
            g_cfgUser.length) val = g_cfgUser;
        else if ([name rangeOfString:@"pass" options:NSCaseInsensitiveSearch].length &&
                 g_cfgPass.length) val = g_cfgPass;
        else if (o->value && o->value[0]) {
            // 已有值：TOTP 模式下库会把动态码自动填进 secondary auth 字段
        }
        else if (o->type == OC_FORM_OPT_TEXT || o->type == OC_FORM_OPT_PASSWORD) {
            // v9.12 没有 OC_FORM_OPT_NONBLANK 宏了（旧版 API），
            // 文本/密码类型的表单项就当作可能必填
            allKnown = NO;
            IPATAppendLogLine([NSString stringWithFormat:
                @"[anyvpn] 表单必填项 %@ 无法自动回填（请在 Info.plist 配置 User/Password）", name]);
        }
        if (val) openconnect_set_option_value(o, val.UTF8String);
    }
    if (!allKnown) return OC_FORM_RESULT_CANCELLED;
    return OC_FORM_RESULT_OK;
}

// VPN 自身 socket 绑到底层网卡（等价 Android VpnService.protect，防路由环路）；
// 非越狱模式下还要登记进引擎的免劫持名单
static void cb_protect_socket(void *privdata, int fd) {
    T2SProtectFD(fd);
    if (g_underlying_idx > 0) {
        setsockopt(fd, IPPROTO_IP, IP_BOUND_IF,
                   &g_underlying_idx, sizeof g_underlying_idx);
        setsockopt(fd, IPPROTO_IPV6, IPV6_BOUND_IF,
                   &g_underlying_idx, sizeof g_underlying_idx);
    }
}

#pragma mark - 会话控制器

@interface AnyVPNController : NSObject
+ (instancetype)shared;
- (void)applyConfig;
- (void)registerPanel;
- (void)startConnect;
- (void)stopConnect;
@property (nonatomic, assign) BOOL masterOn;
@property (nonatomic, assign) BOOL autoConnect;
@property (nonatomic, assign) BOOL noDTLS;
@property (nonatomic, assign) BOOL running;
@end

@implementation AnyVPNController

+ (instancetype)shared {
    static AnyVPNController *c;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ c = [[AnyVPNController alloc] init]; });
    return c;
}

+ (void)load {
    [self shared];
}

- (instancetype)init {
    if ((self = [super init])) {
        _masterOn = NO;
        _running = NO;
        [self applyConfig];
        [[NSNotificationCenter defaultCenter] addObserver:self
                                                 selector:@selector(handleChange:)
                                                     name:IPATControlDidChangeNotification
                                                   object:nil];
        [[NSNotificationCenter defaultCenter] addObserver:self
                                                 selector:@selector(handleAction:)
                                                     name:IPATControlActionNotification
                                                   object:nil];
        [[NSNotificationCenter defaultCenter] addObserver:self
                                                 selector:@selector(handleDiscover:)
                                                     name:IPATControlDiscoverNotification
                                                   object:nil];
        // 悬浮窗可能比我们晚加载，延迟注册一次；再等 Discover 兜底
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{ [self registerPanel]; });
        // 自动连接：等 App 起来再连，别抢启动窗口
        if (_autoConnect && _masterOn) {
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(5 * NSEC_PER_SEC)),
                           dispatch_get_main_queue(), ^{ [self startConnect]; });
        }
    }
    return self;
}

- (NSString *)plist:(NSString *)key default:(NSString *)def {
    NSDictionary *cfg = [[NSBundle mainBundle] objectForInfoDictionaryKey:IPAToolAnyVpnPlistKey];
    id v = cfg[key];
    return [v isKindOfClass:NSString.class] ? v : def;
}

- (BOOL)flag:(NSString *)nsKey plistKey:(NSString *)plistKey def:(BOOL)def {
    NSUserDefaults *ud = [NSUserDefaults standardUserDefaults];
    id v = [ud objectForKey:nsKey];
    if (v) return [v boolValue];
    NSDictionary *cfg = [[NSBundle mainBundle] objectForInfoDictionaryKey:IPAToolAnyVpnPlistKey];
    id p = cfg[plistKey];
    return [p isKindOfClass:NSNumber.class] ? [p boolValue] : def;
}

- (void)applyConfig {
    // 配置读取顺序与协议一致：面板写入的 NSUserDefaults -> Info.plist 初始值
    _autoConnect = [self flag:IPATKeyAnyVpnAuto plistKey:@"AutoConnect" def:NO];
    _noDTLS = [self flag:IPATKeyAnyVpnNoDTLS plistKey:@"DisableDTLS" def:NO];
    id m = [[NSUserDefaults standardUserDefaults] objectForKey:IPATKeyAnyVpnEnabled];
    if (m) _masterOn = [m boolValue];
    else {
        NSDictionary *cfg = [[NSBundle mainBundle] objectForInfoDictionaryKey:IPAToolAnyVpnPlistKey];
        id p = cfg[@"Enabled"];
        _masterOn = [p isKindOfClass:NSNumber.class] ? [p boolValue] : NO;
    }
}

#pragma mark 多连接配置（profiles 存 NSUserDefaults，本机持久化）

// profiles：NSArray<NSDictionary>，每项 {id, name, server, user, password, authGroup}
// active：NSString = 当前选中的 profile id（空 = 第一个）
// 行键 IPATAnyVpnProf:<id>:<field> 是面板的展示缓存，主存储是 profiles 数组

- (NSArray<NSDictionary *> *)profiles {
    id v = [[NSUserDefaults standardUserDefaults] objectForKey:IPATKeyAnyVpnProfiles];
    return [v isKindOfClass:[NSArray class]] ? v : @[];
}

- (void)saveProfiles:(NSArray<NSDictionary *> *)profs {
    [[NSUserDefaults standardUserDefaults] setObject:profs forKey:IPATKeyAnyVpnProfiles];
}

- (NSString *)activeProfileId {
    NSString *a = [[NSUserDefaults standardUserDefaults] stringForKey:IPATKeyAnyVpnActive];
    return a ?: @"";
}

/// 当前选中的 profile；activeId 无效时回落第一个，都没有返回 nil
- (NSDictionary<NSString *, NSString *> *)activeProfile {
    NSArray<NSDictionary *> *profs = [self profiles];
    if (profs.count == 0) return nil;
    NSString *aid = [self activeProfileId];
    for (NSDictionary *p in profs)
        if ([p isKindOfClass:[NSDictionary class]] && [p[@"id"] isEqualToString:aid]) return p;
    return profs.firstObject;
}

/// 把单个 profile 字段的编辑（面板 text 行）写回 profiles 数组
- (void)applyProfileFieldEdit:(NSString *)key value:(NSString *)value {
    // 行键格式：IPATAnyVpnProf:<id>:<field>
    NSString *prefix = @"IPATAnyVpnProf:";
    if (![key hasPrefix:prefix]) return;
    NSString *rest = [key substringFromIndex:prefix.length];
    NSRange sep = [rest rangeOfString:@":"];
    if (sep.location == NSNotFound || sep.location == 0) return;
    NSString *pid = [rest substringToIndex:sep.location];
    NSString *field = [rest substringFromIndex:NSMaxRange(sep)];
    if (![@[ @"name", @"server", @"user", @"password", @"authgroup", @"totp" ] containsObject:field]) return;

    NSMutableArray<NSDictionary *> *profs = [[self profiles] mutableCopy];
    NSMutableArray *out = [NSMutableArray array];
    for (NSDictionary *p in profs) {
        if (![p isKindOfClass:[NSDictionary class]]) continue;
        if ([p[@"id"] isEqualToString:pid]) {
            NSMutableDictionary *np = [p mutableCopy];
            np[field] = value;
            if ([field isEqualToString:@"name"]) np[@"id"] = p[@"id"];  // id 不随名称变
            [out addObject:np];
        } else {
            [out addObject:p];
        }
    }
    [self saveProfiles:out];
}

#pragma mark 注册到游戏内悬浮窗

/// 弹系统输入框前先让悬浮窗躲开（与文件功能的系统界面同一套路）
- (void)presentAlert:(UIAlertController *)alert {
    dispatch_async(dispatch_get_main_queue(), ^{
        [[NSNotificationCenter defaultCenter] postNotificationName:IPATControlVisibilityNotification
                                                            object:nil
                                                          userInfo:@{IPATVisVisible: @NO}];
        UIWindow *win = IPATAppKeyWindowExcluding(nil);
        UIViewController *vc = win.rootViewController ?: [UIApplication sharedApplication].keyWindow.rootViewController;
        while (vc.presentedViewController) vc = vc.presentedViewController;
        if (!vc) {
            [[NSNotificationCenter defaultCenter] postNotificationName:IPATControlVisibilityNotification
                                                                object:nil
                                                              userInfo:@{IPATVisVisible: @YES}];
            return;
        }
        [vc presentViewController:alert animated:YES completion:nil];
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            // 输入框盖在游戏画面上时悬浮窗保持隐藏，关闭后喊回来
            [[NSNotificationCenter defaultCenter] postNotificationName:IPATControlVisibilityNotification
                                                                object:nil
                                                              userInfo:@{IPATVisVisible: @YES}];
        });
    });
}

- (void)addProfileAction {
    UIAlertController *alert = [UIAlertController
        alertControllerWithTitle:@"添加连接"
                         message:@"填服务器地址（账号/密码之后可在面板里改）"
                  preferredStyle:UIAlertControllerStyleAlert];
    [alert addTextFieldWithConfigurationHandler:^(UITextField *tf) {
        tf.placeholder = @"连接名称（如 公司 VPN）";
    }];
    [alert addTextFieldWithConfigurationHandler:^(UITextField *tf) {
        tf.placeholder = @"服务器 如 https://vpn.example.com";
        tf.autocorrectionType = UITextAutocorrectionTypeNo;
        tf.autocapitalizationType = UITextAutocapitalizationTypeNone;
    }];
    [alert addTextFieldWithConfigurationHandler:^(UITextField *tf) {
        tf.placeholder = @"账号（可留空稍后填）";
    }];
    [alert addTextFieldWithConfigurationHandler:^(UITextField *tf) {
        tf.placeholder = @"密码（可留空稍后填）";
        tf.secureTextEntry = YES;
    }];
    [alert addTextFieldWithConfigurationHandler:^(UITextField *tf) {
        tf.placeholder = @"TOTP 密钥（可选，Base32）";
        tf.autocorrectionType = UITextAutocorrectionTypeNo;
        tf.autocapitalizationType = UITextAutocapitalizationTypeNone;
    }];
    [alert addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    [alert addAction:[UIAlertAction actionWithTitle:@"保存" style:UIAlertActionStyleDefault
                                            handler:^(UIAlertAction *a) {
        NSString *server = alert.textFields[1].text ?: @"";
        if (server.length == 0) {
            [self toast:@"服务器地址不能为空"];
            return;
        }
        NSMutableDictionary *p = [NSMutableDictionary dictionary];
        p[@"id"] = [[NSUUID UUID] UUIDString];
        p[@"name"] = (alert.textFields[0].text.length ? alert.textFields[0].text : server);
        p[@"server"] = server;
        p[@"user"] = alert.textFields[2].text ?: @"";
        p[@"password"] = alert.textFields[3].text ?: @"";
        p[@"totp"] = alert.textFields[4].text ?: @"";
        p[@"authgroup"] = @"";
        NSMutableArray *profs = [[self profiles] mutableCopy];
        [profs addObject:p];
        [self saveProfiles:profs];
        [[NSUserDefaults standardUserDefaults] setObject:p[@"id"] forKey:IPATKeyAnyVpnActive];
        [self toast:[NSString stringWithFormat:@"已添加 %@", p[@"name"]]];
        [self registerPanel];
    }]];
    [self presentAlert:alert];
}

- (void)deleteActiveProfileAction {
    NSDictionary<NSString *, NSString *> *p = [self activeProfile];
    if (!p) return;
    UIAlertController *alert = [UIAlertController
        alertControllerWithTitle:@"删除连接"
                         message:[NSString stringWithFormat:@"删除「%@」？", p[@"name"] ?: @""]
                  preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    [alert addAction:[UIAlertAction actionWithTitle:@"删除" style:UIAlertActionStyleDestructive
                                            handler:^(UIAlertAction *a) {
        NSString *pid = p[@"id"];
        NSMutableArray *out = [NSMutableArray array];
        for (NSDictionary *q in [self profiles])
            if (![q[@"id"] isEqualToString:pid]) [out addObject:q];
        [self saveProfiles:out];
        [[NSUserDefaults standardUserDefaults] removeObjectForKey:IPATKeyAnyVpnActive];
        [self toast:@"已删除"];
        [self registerPanel];
    }]];
    [self presentAlert:alert];
}

- (void)registerPanel {
    NSMutableArray *rows = [NSMutableArray array];
    NSArray<NSDictionary *> *profs = [self profiles];

    // 「连接」分段：一个 profile 一段，选中值存 IPATKeyAnyVpnActive
    if (profs.count > 0) {
        NSMutableArray *names = [NSMutableArray array];
        for (NSDictionary *p in profs)
            if ([p isKindOfClass:[NSDictionary class]])
                [names addObject:p[@"name"] ?: p[@"server"] ?: @"?"];
        [rows addObject:@{IPATRowKey: IPATKeyAnyVpnActive, IPATRowTitle: @"连接",
                          IPATRowKind: IPATRowKindSegment,
                          IPATRowOptions: names, IPATRowValues: names,
                          IPATRowValue: names.firstObject,
                          IPATRowNote: @"多个连接时点这里切换"}];
        // 每个 profile 的可编辑参数（行键带 profile id，改完同步回 profiles）
        NSString *aid = [self activeProfileId];
        for (NSDictionary *p in profs) {
            if (![p isKindOfClass:[NSDictionary class]]) continue;
            NSString *pid = p[@"id"] ?: @"";
            NSString *title = p[@"name"] ?: pid;
            NSString *sec = p[@"password"] ?: @"";
            [rows addObject:@{IPATRowKey: [NSString stringWithFormat:@"IPATAnyVpnProf:%@:server", pid],
                              IPATRowTitle: [NSString stringWithFormat:@"[%@] 服务器", title],
                              IPATRowKind: IPATRowKindText, IPATRowValue: p[@"server"] ?: @""}];
            [rows addObject:@{IPATRowKey: [NSString stringWithFormat:@"IPATAnyVpnProf:%@:user", pid],
                              IPATRowTitle: [NSString stringWithFormat:@"[%@] 账号", title],
                              IPATRowKind: IPATRowKindText, IPATRowValue: p[@"user"] ?: @""}];
            [rows addObject:@{IPATRowKey: [NSString stringWithFormat:@"IPATAnyVpnProf:%@:password", pid],
                              IPATRowTitle: [NSString stringWithFormat:@"[%@] 密码", title],
                              IPATRowKind: IPATRowKindText, IPATRowValue: sec,
                              IPATRowSecure: @YES}];
            [rows addObject:@{IPATRowKey: [NSString stringWithFormat:@"IPATAnyVpnProf:%@:authgroup", pid],
                              IPATRowTitle: [NSString stringWithFormat:@"[%@] 认证组", title],
                              IPATRowKind: IPATRowKindText, IPATRowValue: p[@"authgroup"] ?: @""}];
            [rows addObject:@{IPATRowKey: [NSString stringWithFormat:@"IPATAnyVpnProf:%@:totp", pid],
                              IPATRowTitle: [NSString stringWithFormat:@"[%@] TOTP 密钥", title],
                              IPATRowKind: IPATRowKindText, IPATRowValue: p[@"totp"] ?: @"",
                              IPATRowNote: @"Base32 密钥（Google Authenticator 那串）；网关要动态码时填"}];
        }
        [rows addObject:@{IPATRowKey: IPATKeyAnyVpnDelProfile, IPATRowTitle: @"删除当前连接",
                          IPATRowKind: IPATRowKindAction}];
    }
    [rows addObject:@{IPATRowKey: IPATKeyAnyVpnAddProfile, IPATRowTitle: @"＋ 添加连接",
                      IPATRowKind: IPATRowKindAction}];
    [rows addObject:@{IPATRowKey: IPATKeyAnyVpnAuto,   IPATRowTitle: @"启动自动连接", IPATRowKind: IPATRowKindSwitch, IPATRowValue: @(self.autoConnect)}];
    [rows addObject:@{IPATRowKey: IPATKeyAnyVpnNoDTLS, IPATRowTitle: @"禁用 DTLS",   IPATRowKind: IPATRowKindSwitch, IPATRowValue: @(self.noDTLS)}];
    [rows addObject:@{IPATRowKey: IPATKeyAnyVpnConnect, IPATRowTitle: @"立即连接",   IPATRowKind: IPATRowKindAction}];
    [rows addObject:@{IPATRowKey: IPATKeyAnyVpnDisc,    IPATRowTitle: @"立即断开",   IPATRowKind: IPATRowKindAction}];

    NSString *detail;
    if (profs.count == 0) {
        detail = @"AnyConnect 协议：先点「＋ 添加连接」配置服务器和账号，再点「立即连接」";
    } else {
        detail = @"选中连接后点「立即连接」；行内可直接改服务器/账号/密码";
    }

    NSDictionary *reg = @{
        IPATRegId: IPATFeatureAnyVpn,
        IPATRegTitle: @"VPN 隧道",
        IPATRegDetail: detail,
        IPATRegMasterKey: IPATKeyAnyVpnEnabled,
        IPATRegEnabled: @(self.masterOn),
        IPATRegRows: rows,
    };
    [[NSNotificationCenter defaultCenter] postNotificationName:IPATControlRegisterNotification
                                                        object:nil
                                                      userInfo:reg];
}

- (void)handleDiscover:(NSNotification *)note {
    [self registerPanel];
}

- (void)handleChange:(NSNotification *)note {
    if (![note.userInfo[IPATChgId] isEqualToString:IPATFeatureAnyVpn]) return;
    NSDictionary *values = note.userInfo[IPATChgValues] ?: @{};
    if (values[IPATKeyAnyVpnAuto]) self.autoConnect = [values[IPATKeyAnyVpnAuto] boolValue];
    if (values[IPATKeyAnyVpnNoDTLS]) self.noDTLS = [values[IPATKeyAnyVpnNoDTLS] boolValue];
    BOOL activeChanged = NO;
    if (values[IPATKeyAnyVpnActive]) {
        NSString *aid = values[IPATKeyAnyVpnActive];
        if (![aid isEqualToString:[self activeProfileId]]) {
            [[NSUserDefaults standardUserDefaults] setObject:aid forKey:IPATKeyAnyVpnActive];
            activeChanged = YES;
            NSDictionary<NSString *, NSString *> *p = [self activeProfile];
            [self status:[NSString stringWithFormat:@"已选择连接：%@", p[@"name"] ?: @""]];
        }
    }
    // 面板 text 行（profile 字段编辑）→ 写回 profiles 主存储
    for (NSString *k in values)
        if ([k hasPrefix:@"IPATAnyVpnProf:"] && [values[k] isKindOfClass:[NSString class]])
            [self applyProfileFieldEdit:k value:values[k]];
    BOOL enabled = note.userInfo[IPATChgEnabled] ? [note.userInfo[IPATChgEnabled] boolValue] : self.masterOn;
    self.masterOn = enabled;
    if (activeChanged && self.running) [self stopConnect];   // 换连接：断开旧隧道，下面自动重连新的
    if (enabled && !self.running) [self startConnect];
    if (!enabled && self.running) [self stopConnect];
    [self registerPanel];
}

- (void)handleAction:(NSNotification *)note {
    NSString *key = note.userInfo[IPATActKey];
    if ([key isEqualToString:IPATKeyAnyVpnConnect]) {
        self.masterOn = YES;
        [[NSUserDefaults standardUserDefaults] setBool:YES forKey:IPATKeyAnyVpnEnabled];
        [self startConnect];
    } else if ([key isEqualToString:IPATKeyAnyVpnDisc]) {
        self.masterOn = NO;
        [[NSUserDefaults standardUserDefaults] setBool:NO forKey:IPATKeyAnyVpnEnabled];
        [self stopConnect];
    } else if ([key isEqualToString:IPATKeyAnyVpnAddProfile]) {
        [self addProfileAction];
    } else if ([key isEqualToString:IPATKeyAnyVpnDelProfile]) {
        [self deleteActiveProfileAction];
    }
    [self registerPanel];
}

/// 屏幕上弹一条几秒消失的提示（面板端渲染）
- (void)toast:(NSString *)text {
    [[NSNotificationCenter defaultCenter] postNotificationName:IPATControlToastNotification
                                                        object:nil
                                                      userInfo:@{IPATToastText: text}];
}

- (void)status:(NSString *)text {
    IPATAppendLogLine([NSString stringWithFormat:@"[anyvpn] %@", text]);
    [[NSNotificationCenter defaultCenter] postNotificationName:IPATControlStatusNotification
                                                        object:nil
                                                      userInfo:@{IPATRegId: IPATFeatureAnyVpn,
                                                                 IPATStaDetail: text}];
}

#pragma mark 连接 / 断开

- (BOOL)configured {
    // 优先级：面板保存的 profiles（选中的连接） -> Info.plist 注入时的初始值
    NSDictionary<NSString *, NSString *> *p = [self activeProfile];
    g_cfgServer = p[@"server"].length ? p[@"server"]
                                      : [self plist:@"Server" default:nil];
    if (!g_cfgServer.length) {
        [self status:@"未配置服务器：打开悬浮窗 VPN 分组，点「＋ 添加连接」"];
        [self toast:@"未配置服务器，先在悬浮窗添加连接"];
        return NO;
    }
    g_cfgUser  = p[@"user"].length     ? p[@"user"]     : [self plist:@"User" default:@""];
    g_cfgPass  = p[@"password"].length ? p[@"password"] : [self plist:@"Password" default:@""];
    g_cfgGroup = p[@"authgroup"].length ? p[@"authgroup"] : [self plist:@"AuthGroup" default:@""];
    NSDictionary<NSString *, NSString *> *ap = [self activeProfile];
    if (ap) [self status:[NSString stringWithFormat:@"正在连接 %@ …", ap[@"name"] ?: @""]];
    return YES;
}

- (void)startConnect {
    if (self.running) return;
    if (![self configured]) return;
    self.running = YES;
    [self status:@"连接中…"];
    [NSThread detachNewThreadSelector:@selector(runSession) toTarget:self withObject:nil];
}

- (void)stopConnect {
    if (!self.running) return;
    if (g_cmd_fd >= 0) {
        char c = OC_CMD_CANCEL;
        ssize_t w = write(g_cmd_fd, &c, 1);
        (void)w;
    }
    [self status:@"正在断开…"];
}

- (void)runSession {
    @autoreleasepool {
        NSString *underlying = [self plist:@"UnderlyingIface" default:@"en0"];
        g_underlying_idx = ifindex_of(underlying.UTF8String);
        NSString *server = g_cfgServer;

        NSString *host = server;
        NSRange r = [server rangeOfString:@"//"];
        if (r.location != NSNotFound) host = [server substringFromIndex:r.location + 2];
        NSRange slash = [host rangeOfString:@"/"];
        if (slash.location != NSNotFound) host = [host substringToIndex:slash.location];
        NSRange colon = [host rangeOfString:@":"];
        if (colon.location != NSNotFound) host = [host substringToIndex:colon.location];
        g_certKey = [NSString stringWithFormat:@"IPATAnyVpnCertHash_%@", host];

        if (openconnect_init_ssl() != 0) {
            [self fail:@"SSL 初始化失败"];
            return;
        }
        NSString *ua = [self plist:@"UserAgent" default:@"AnyConnect Darwin/5.0.05042"];
        g_vpninfo = openconnect_vpninfo_new((char *)ua.UTF8String,
                                            cb_validate_peer_cert, NULL,
                                            cb_auth_form, cb_progress, NULL);
        if (!g_vpninfo) {
            [self fail:@"vpninfo 创建失败"];
            return;
        }
        openconnect_set_protocol(g_vpninfo, "anyconnect");
        // TOTP 动态码：profile 里存了 Base32 密钥就启用（库内置 OATH 实现），
        // 网关弹 secondary auth 时 openconnect 自动生成并填入
        NSString *totp = [self activeProfile][@"totp"];
        if (totp.length) {
            int tm = openconnect_set_token_mode(g_vpninfo, OC_TOKEN_MODE_TOTP,
                                                (char *)totp.UTF8String);
            IPATAppendLogLine([NSString stringWithFormat:@"[anyvpn] TOTP %s",
                               tm == 0 ? "已启用" : "启用失败（密钥格式或库支持问题）"]);
        }
        NSString *ver = [self plist:@"VersionString" default:@"5.0.05042"];
        if (ver.length) openconnect_set_version_string(g_vpninfo, ver.UTF8String);
        NSString *ros = [self plist:@"ReportedOS" default:@"iOS"];
        if (ros.length) openconnect_set_reported_os(g_vpninfo, ros.UTF8String);
        openconnect_set_mobile_info(g_vpninfo, (char *)"iOS", (char *)"iOS",
                                    (char *)"0000000000000000");
        openconnect_set_protect_socket_handler(g_vpninfo, cb_protect_socket);
        if (self.noDTLS) openconnect_disable_dtls(g_vpninfo);
        if (openconnect_parse_url(g_vpninfo, server.UTF8String) != 0) {
            [self fail:[NSString stringWithFormat:@"服务器地址解析失败：%@", server]];
            return;
        }
        g_cmd_fd = openconnect_setup_cmd_pipe(g_vpninfo);

        // 认证：可能多轮触发表单回调（账号 -> 动态码 -> 密码）
        if (openconnect_obtain_cookie(g_vpninfo) != 0) {
            [self fail:@"认证失败（看日志：表单字段没配置或密码错）"];
            return;
        }
        if (openconnect_make_cstp_connection(g_vpninfo) != 0) {
            [self fail:@"CSTP 隧道建立失败"];
            return;
        }

        const struct oc_ip_info *ip = NULL;
        const struct oc_vpn_option *cstp = NULL, *dtls = NULL;
        openconnect_get_ip_info(g_vpninfo, &ip, &cstp, &dtls);
        if (!ip || !ip->addr) {
            [self fail:@"网关没下发 IP 信息"];
            return;
        }

        // TUN 两种模式：
        //  - root（越狱）：建 utun 配地址加路由，系统级接管（老路径）
        //  - 非 root：socketpair 掉包，openconnect 的 tun 对端接 lwIP 用户态
        //    TCP/IP 栈 + fishhook 劫持宿主流量（见 AnyVpnT2S）
        char ifname[IFNAMSIZ] = {0};
        BOOL root = (geteuid() == 0);
        if (root) {
            g_tun_fd = create_utun(ifname);
            if (g_tun_fd < 0) {
                [self fail:@"utun 创建失败"];
                return;
            }
            if (ifconfig_tun(ifname, ip->addr,
                             ip->gateway_addr ? ip->gateway_addr : ip->addr,
                             ip->netmask ? ip->netmask : "255.255.255.0") != 0) {
                [self fail:[NSString stringWithFormat:@"utun(%s) 地址配置失败（SIOCAIFADDR）",
                            ifname]];
                return;
            }
            if (openconnect_setup_tun_fd(g_vpninfo, g_tun_fd) != 0) {
                [self fail:@"tun fd 交给 openconnect 失败"];
                return;
            }
        } else {
            int sp[2];
            if (socketpair(AF_UNIX, SOCK_STREAM, 0, sp) != 0) {
                [self fail:@"socketpair 创建失败"];
                return;
            }
            if (openconnect_setup_tun_fd(g_vpninfo, sp[0]) != 0) {
                close(sp[0]); close(sp[1]);
                [self fail:@"tun fd 交给 openconnect 失败"];
                return;
            }
            NSString *err = nil;
            NSMutableArray<NSString *> *dns = [NSMutableArray array];
            for (int i = 0; i < 3 && ip->dns[i]; i++) [dns addObject:@(ip->dns[i])];
            if (!T2SEngineStart(sp[1],
                                @(ip->addr),
                                ip->netmask ? @(ip->netmask) : @"255.255.255.0",
                                ip->gateway_addr ? @(ip->gateway_addr) : @(ip->addr),
                                ip->mtu > 0 ? (int)ip->mtu : 1400,
                                dns, &err)) {
                close(sp[1]);
                [self fail:[NSString stringWithFormat:@"非越狱引擎启动失败：%@", err ?: @""]];
                return;
            }
            strlcpy(ifname, "t2s", IFNAMSIZ);
        }
        if (!self.noDTLS) openconnect_setup_dtls(g_vpninfo, 60);

        // 路由：root 才能加。有 split_include 按网关下发的走；否则 /1 两段接管全部
        if (root) {
            int rs = socket(AF_INET, SOCK_DGRAM, 0);
            if (rs >= 0) {
                const char *gw = ip->addr;
                if (ip->split_includes) {
                    for (const struct oc_split_include *s2 = ip->split_includes; s2; s2 = s2->next)
                        route_add(rs, s2->route, gw);
                } else {
                    route_add(rs, NULL, gw);
                    route_add(rs, "128.0.0.0", gw);
                }
                for (int i = 0; i < 3 && ip->dns[i]; i++)
                    route_add(rs, ip->dns[i], gw);   // DNS 也得走隧道，不然解析泄露
            }
            close(rs);
        }

        [self status:[NSString stringWithFormat:@"已连接 %@（IP %@ / %@%s）",
                      server, ip->addr ?: "", ifname,
                      root ? "" : "，非越狱模式：接管本 App 直连流量"]];
        [self toast:[NSString stringWithFormat:@"✅ VPN 已连接 %@（IP %@）",
                     [self activeProfile][@"name"] ?: server, ip->addr ?: @""]];

        // 主循环：断线重连参数与 Android 端一致
        openconnect_mainloop(g_vpninfo, 300, 10);
        [self teardownRoutesIfNeeded:ip];
        [self status:@"已断开"];
        [self cleanup];
    }
}

- (void)teardownRoutesIfNeeded:(const struct oc_ip_info *)ip {
    if (geteuid() != 0 || !ip) return;
    int rs = socket(AF_INET, SOCK_DGRAM, 0);
    if (rs < 0) return;
    const char *gw = ip->addr;
    if (ip->split_includes) {
        for (const struct oc_split_include *s2 = ip->split_includes; s2; s2 = s2->next)
            route_del(rs, s2->route, gw);
    } else {
        route_del(rs, NULL, gw);
        route_del(rs, "128.0.0.0", gw);
    }
    for (int i = 0; i < 3 && ip->dns[i]; i++)
        route_del(rs, ip->dns[i], gw);
    close(rs);
}

- (void)fail:(NSString *)msg {
    [self status:msg];
    [self toast:[NSString stringWithFormat:@"❌ %@", msg]];
    [self cleanup];
}

- (void)cleanup {
    self.running = NO;
    T2SEngineStop();   // 非越狱模式引擎（root 模式下是空操作）
    if (g_tun_fd >= 0) { close(g_tun_fd); g_tun_fd = -1; }
    if (g_vpninfo) {
        openconnect_vpninfo_free(g_vpninfo);
        g_vpninfo = NULL;
    }
    g_cmd_fd = -1;
    [self registerPanel];   // 刷新主开关状态显示
}

@end

#pragma mark - 入口

__attribute__((constructor))
static void IPATAnyVpnLoad(void) {
    // 尽早装 socket 劫持（引擎没就绪时全部直通原函数，不影响 App 正常运行）
    T2SInstallHooks();
    // 与其他 tweak 一致：延后一点等主线程就绪再初始化
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        [AnyVPNController shared];
    });
}
