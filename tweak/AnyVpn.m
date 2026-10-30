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
#import <netdb.h>   // getaddrinfo（fake-IP 预检用）
#import <ifaddrs.h> // getifaddrs（底层网卡探测兜底：UDP connect 反查网卡）
#import <unistd.h>
#import <time.h>
#import <ctype.h>
#import <sys/sysctl.h>   // 默认路由探测（NET_RT_DUMP）
#import <sys/socket.h>   // NET_RT_DUMP / sockaddr 遍历
#import <CommonCrypto/CommonHMAC.h>   // TOTP 的 HMAC-SHA1（系统库，无额外链接）

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

// 读内核路由表，找 IPv4 默认路由（0.0.0.0/0）所在网卡的 ifindex。
// WiFi 下是 en0，蜂窝下是 pdp_ip0——绑死 en0 的话切到蜂窝后 VPN 自己的
// connect() 直接 ENETUNREACH（实测问题：WiFi 能连、流量连不上）。
// iOS SDK 没有 <net/route.h>，这里自带最小定义（只用到 rt_msghdr 头部
// 固定偏移的字段，内核 ABI 多年未变；常量取值与 Darwin 一致）
struct ipat_rt_msghdr {
    u_short rtm_msglen;   // 本条消息总长（遍历步进用）
    u_char  rtm_version;
    u_char  rtm_type;
    u_short rtm_index;    // 路由所在网卡 ifindex
    int     rtm_flags;
    int     rtm_addrs;    // sockaddr 位掩码
};
#define IPAT_RTM_VERSION 5
#define IPAT_RTM_GET     4     // Darwin 的 RTM_GET
#define IPAT_RTF_GATEWAY 0x2
#define IPAT_RTA_DST     0x1

static int default_route_ifindex(void) {
    int mib[6] = { CTL_NET, PF_ROUTE, 0, AF_INET, NET_RT_DUMP, 0 };
    size_t len = 0;
    if (sysctl(mib, 6, NULL, &len, NULL, 0) != 0) return 0;
    char *buf = (char *)malloc(len);
    if (!buf) return 0;
    int idx = 0, idxAny = 0;
    if (sysctl(mib, 6, buf, &len, NULL, 0) == 0) {
        for (char *p = buf; p + sizeof(struct ipat_rt_msghdr) <= buf + len; ) {
            struct ipat_rt_msghdr *rtm = (struct ipat_rt_msghdr *)p;
            if (rtm->rtm_msglen < (u_short)sizeof(struct ipat_rt_msghdr) ||
                rtm->rtm_version != IPAT_RTM_VERSION) break;
            // 默认路由：目的 0.0.0.0（sockaddr 链按 sa_len 4 字节对齐遍历）。
            // 注意不能要求 RTF_GATEWAY：WiFi 的默认路由是 "default 192.168.x.1"
            // （带 G 标志），蜂窝是 "default link#N"（网关=接口自己，不带 G），
            // 按带 G 过滤会导致蜂窝下永远探测失败
            if (rtm->rtm_type == IPAT_RTM_GET && (rtm->rtm_addrs & IPAT_RTA_DST)) {
                struct sockaddr *sa = (struct sockaddr *)(rtm + 1);
                struct sockaddr_in *dst = NULL;
                if (sa->sa_len > 0 && sa->sa_family == AF_INET) {
                    dst = (struct sockaddr_in *)sa;
                }
                if (dst && dst->sin_addr.s_addr == INADDR_ANY && rtm->rtm_index > 0) {
                    // WiFi（带网关）优先；蜂窝 link 路由记一份兜底
                    if (!idxAny) idxAny = (int)rtm->rtm_index;
                    if (rtm->rtm_flags & IPAT_RTF_GATEWAY) { idx = (int)rtm->rtm_index; break; }
                }
            }
            p += rtm->rtm_msglen;
        }
    }
    free(buf);
    return idx ? idx : idxAny;
}

// 探测承载默认流量的网卡：先用内核路由表（WiFi 场景通常能拿到），
// 拿不到就用「UDP connect 试探 + getifaddrs 反查」兜底——iOS 上 NET_RT_DUMP
// 经常读不到默认路由（探测失败），但 UDP connect 能让内核按真实路由选路，
// 再用本地地址反查网卡名，WiFi→en0 / 蜂窝→pdp_ip0 都能拿到
static int probe_underlying_ifindex(void) {
    int idx = default_route_ifindex();
    if (idx > 0) return idx;

    int s = socket(AF_INET, SOCK_DGRAM, 0);
    if (s < 0) return 0;
    struct sockaddr_in dst;
    memset(&dst, 0, sizeof dst);
    dst.sin_len = sizeof dst;
    dst.sin_family = AF_INET;
    dst.sin_port = htons(53);
    dst.sin_addr.s_addr = htonl(0x08080808);      // 8.8.8.8，只为让内核选路
    if (connect(s, (struct sockaddr *)&dst, sizeof dst) != 0) { close(s); return 0; }
    struct sockaddr_in local;
    socklen_t sl = sizeof local;
    if (getsockname(s, (struct sockaddr *)&local, &sl) != 0) { close(s); return 0; }
    close(s);
    uint32_t localAddr = local.sin_addr.s_addr;

    struct ifaddrs *ifa = NULL;
    if (getifaddrs(&ifa) != 0) return 0;
    int found = 0;
    for (struct ifaddrs *p = ifa; p; p = p->ifa_next) {
        if (!p->ifa_addr || p->ifa_addr->sa_family != AF_INET) continue;
        if (!p->ifa_name) continue;
        // 跳过隧道/虚拟网卡：绑到它们会把 VPN 自己的流量送回隧道
        if (strncmp(p->ifa_name, "utun", 4) == 0 ||
            strncmp(p->ifa_name, "tun", 3) == 0 ||
            strncmp(p->ifa_name, "ipsec", 5) == 0 ||
            strncmp(p->ifa_name, "ppp", 3) == 0) continue;
        struct sockaddr_in *sin = (struct sockaddr_in *)p->ifa_addr;
        if (sin->sin_addr.s_addr == localAddr) {
            found = (int)if_nametoindex(p->ifa_name);
            break;
        }
    }
    freeifaddrs(ifa);
    return found;
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
static NSString *g_totpSecret = nil;  // 当前连接的 TOTP 密钥（Base32），空 = 不用动态码
static NSString *g_certKey = nil;     // TOFU 指纹存 NSUserDefaults 用的键

// TOTP 认证状态机（对齐 Android 端 AuthSession，见 AuthFormResolver.kt）：
// 三段式账号 -> 动态码 -> 密码，每段一张表单；动态码必须当场生成；
// 同窗口被拒要等下个窗口换新码；连续被拒到上限就停手防账号锁定
static long  g_otpWindow = -1;          // 上次生成码的时间窗（30s）
static char  g_lastOtp[8] = {0};
static int   g_otpRejects = 0;          // 动态码连续被拒次数
static BOOL  g_usedOtpThisAttempt = NO; // 本轮尝试里动态码是否已被使用过
static BOOL  g_staticPasswordSubmitted = NO;  // 固定密码是否已交（跨表单记忆）
#define MAX_OTP_REJECTS 3

// Base32 解码（RFC 4648，容忍空格/横杠/填充），返回写入长度或 -1
static int b32_decode(const char *in, unsigned char *out, int cap) {
    static const char *A = "ABCDEFGHIJKLMNOPQRSTUVWXYZ234567";
    int bits = 0, val = 0, idx = 0;
    for (; in && *in; in++) {
        if (*in == '=' || *in == ' ' || *in == '-' || *in == '_') continue;
        const char *p = strchr(A, toupper((unsigned char)*in));
        if (!p) return -1;
        val = (val << 5) | (int)(p - A);
        bits += 5;
        if (bits >= 8) {
            bits -= 8;
            if (idx < cap) out[idx++] = (unsigned char)((val >> bits) & 0xFF);
        }
    }
    return idx;
}

// RFC 6238：SHA1 / 6 位 / 30s（与 Android 端 Totp.kt 默认参数一致）
static void totp_generate(const char *secret, long counter, char out[8]) {
    unsigned char key[64];
    int klen = b32_decode(secret, key, (int)sizeof key);
    if (klen <= 0) { out[0] = 0; return; }
    unsigned char msg[8];
    for (int i = 7; i >= 0; i--) { msg[i] = (unsigned char)(counter & 0xFF); counter >>= 8; }
    unsigned char mac[CC_SHA1_DIGEST_LENGTH];
    CCHmac(kCCHmacAlgSHA1, key, (size_t)klen, msg, 8, mac);
    int off = mac[CC_SHA1_DIGEST_LENGTH - 1] & 0x0F;
    unsigned int bin = ((mac[off] & 0x7F) << 24) | (mac[off + 1] << 16) |
                       (mac[off + 2] << 8) | mac[off + 3];
    snprintf(out, 8, "%06u", bin % 1000000);
}

// 动态码生成入口（对齐 Android 端 AuthSession.otp()）：
//  - 同窗口内已有码且本轮刚被拒（hadError）→ sleep 到下一窗口再生成新码，
//    避免把失效/重复的动态码连续提交触发账号锁定；
//  - 同窗口但没报错（同一次尝试里的后续复用）→ 直接复用上次生成的码；
//  - 跨窗口 → 生成新码
static const char *otp_value(BOOL hadError) {
    if (!g_totpSecret.length) return "";
    long win = (long)(time(NULL) / 30);
    if (g_lastOtp[0] && win == g_otpWindow) {
        if (hadError || g_usedOtpThisAttempt) {
            long remain = 30 - (long)(time(NULL) % 30) + 1;
            IPATAppendLogLine([NSString stringWithFormat:
                @"[anyvpn] 动态码仍在当前窗口，等待 %lds 换新码", remain]);
            sleep((int)remain);
            win = (long)(time(NULL) / 30);
        } else {
            g_usedOtpThisAttempt = YES;
            return g_lastOtp;
        }
    }
    totp_generate(g_totpSecret.UTF8String ?: "", win, g_lastOtp);
    g_otpWindow = win;
    g_usedOtpThisAttempt = YES;
    return g_lastOtp;
}

// 网关是否在要「动态验证码」：依据 message + 字段提示语的子串匹配，
// 与 Android 端 OtpPrompt 同一套关键词（中英文）
static BOOL otp_prompt_match(const char *text) {
    if (!text) return NO;
    static const char *keys[] = { "verification", "verify", "one-time", "one time",
                                  "otp", "token", "challenge", "动态", "验证" };
    char low[512];
    snprintf(low, sizeof low, "%s", text);
    for (char *c = low; *c; c++) *c = (char)tolower((unsigned char)*c);
    for (size_t i = 0; i < sizeof keys / sizeof keys[0]; i++)
        if (strstr(low, keys[i])) return YES;
    return NO;
}

// C 层发状态（面板状态行 + 落盘日志）；cb_auth_form 在类声明之前，不能直接
// 引用 AnyVPNController，走通知协议。面板可能从后台线程收到通知后直接碰 UI，
// 所以这里统一跳主线程再发
static void anyvpn_status_notify(NSString *text) {
    IPATAppendLogLine([NSString stringWithFormat:@"[anyvpn] %@", text]);
    dispatch_async(dispatch_get_main_queue(), ^{
        [[NSNotificationCenter defaultCenter] postNotificationName:IPATControlStatusNotification
                                                            object:nil
                                                          userInfo:@{IPATRegId: IPATFeatureAnyVpn,
                                                                     IPATStaDetail: text}];
    });
}

// 用户名字段识别，对齐 Android 端 isUsernameField：name 含 user/login，
// 或 label 含「用户名/账号/用户」
static BOOL is_username_field(const char *name, const char *label) {
    if (name) {
        char low[128];
        snprintf(low, sizeof low, "%s", name);
        for (char *c = low; *c; c++) *c = (char)tolower((unsigned char)*c);
        if (strstr(low, "user") || strstr(low, "login")) return YES;
    }
    if (label) {
        NSString *l = [NSString stringWithUTF8String:label];
        if ([l containsString:@"用户名"] || [l containsString:@"账号"] ||
            [l containsString:@"用户"]) return YES;
    }
    return NO;
}

#define LOG_DROP_LEVEL 3   // 丢弃 PRG_TRACE 每包日志，同 Android 端

static void cb_progress(void *privdata, int level, const char *fmt, ...) {
    if (level >= LOG_DROP_LEVEL) return;
    char buf[1024];
    va_list ap;
    va_start(ap, fmt);
    vsnprintf(buf, sizeof buf, fmt, ap);
    va_end(ap);
    // 诊断：TLS 被网关干净断开（SSL_ERROR_ZERO_RETURN）的瞬间打一帧 T2S 快照，
    // 用两次断开之间的计数差判断数据面是停摆还是在正常收发
    if (strstr(buf, "Read error on TLS session")) T2SStatsLog("TLS被断时刻");
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

// 认证表单自动回填状态机（对齐 Android 端 AuthSession）：
// 三段式「账号 -> 动态码 -> 密码」，动态码字段用 message/字段名判别、当场生成，
// 被拒同窗口不换码、连续被拒到上限停止（防账号锁定）
static int cb_auth_form(void *privdata, struct oc_auth_form *form) {
    const char *message = form->message ?: "";
    const char *errtext = form->error ?: "";
    if (message[0])
        IPATAppendLogLine([NSString stringWithFormat:@"[anyvpn] 表单：%s", message]);

    // 预扫描：TOKEN 字段、密码字段数、用户名字段（用户名再现 = 整个认证重来）；
    // 同时把字段清单打进日志——排障时一眼看出哪个字段没被识别
    BOOL tokenFieldExists = NO;
    int passwordCount = 0;
    BOOL usernameAgain = NO;
    BOOL askingOtp = otp_prompt_match(message);
    NSMutableArray<NSString *> *fieldDesc = [NSMutableArray array];
    for (struct oc_form_opt *o = form->opts; o; o = o->next) {
        if (!o->name) continue;
        if (o->type == OC_FORM_OPT_TOKEN) tokenFieldExists = YES;
        if (o->type == OC_FORM_OPT_PASSWORD) passwordCount++;
        if (is_username_field(o->name, o->label)) usernameAgain = YES;
        if (o->label && otp_prompt_match(o->label)) askingOtp = YES;
        const char *tn = (o->type == OC_FORM_OPT_TEXT) ? "text"
                       : (o->type == OC_FORM_OPT_PASSWORD) ? "password"
                       : (o->type == OC_FORM_OPT_SELECT) ? "select"
                       : (o->type == OC_FORM_OPT_TOKEN) ? "token"
                       : (o->type == OC_FORM_OPT_HIDDEN) ? "hidden" : "other";
        [fieldDesc addObject:[NSString stringWithFormat:@"%s(%s)", o->name, tn]];
    }
    IPATAppendLogLine([NSString stringWithFormat:@"[anyvpn] 表单字段：%@，密码字段=%d，要验证码=%d",
                       [fieldDesc componentsJoinedByString:@" "], passwordCount, askingOtp]);
    if (usernameAgain) g_staticPasswordSubmitted = NO;

    // 网关要验证码但没配密钥：不能拿固定密码冒充（必被拒还会触发账号锁定）
    if (askingOtp && !g_totpSecret.length) {
        anyvpn_status_notify([NSString stringWithFormat:
            @"网关要求验证码，但账号 \"%@\" 未配置 TOTP 密钥 —— 请在悬浮窗「TOTP 密钥」里补上",
            g_cfgUser ?: @""]);
        return OC_FORM_RESULT_CANCELLED;
    }
    if (g_otpRejects >= MAX_OTP_REJECTS) {
        anyvpn_status_notify(
            [NSString stringWithFormat:@"动态码连续被拒 %d 次，停止重试（避免账号锁定）", g_otpRejects]);
        return OC_FORM_RESULT_CANCELLED;
    }

    // 本张表单报的 error 是针对上一轮提交的结果；本轮刚生成的码还没发出去，
    // 不能被算作"被拒"——所以 here 先记住"之前生成过码"，末尾再据此累计拒绝数
    BOOL hadOtpBefore = (g_lastOtp[0] != 0);

    int passwordIndex = 0;
    int filled = 0;          // 实际填上的字段数（对齐 Android 端 filled）
    BOOL authgroupFilled = NO;
    for (struct oc_form_opt *o = form->opts; o; o = o->next) {
        if (o->type == OC_FORM_OPT_HIDDEN || !o->name) continue;  // 隐藏字段交由库处理
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
                authgroupFilled = YES;
                continue;
            }
            // 普通下拉：按组名匹配，没配或没匹配上就选第一个
            int use = pick >= 0 ? pick : 0;
            if (use < sel->nr_choices && sel->choices[use]->name) {
                openconnect_set_option_value(o, sel->choices[use]->name);
                filled++;
            }
            continue;
        }
        NSString *val = nil;
        if (is_username_field(o->name, o->label) && g_cfgUser.length) {
            val = g_cfgUser;
        } else if (o->type == OC_FORM_OPT_TOKEN) {
            // Cisco 专用一次性口令字段：直接填动态码
            val = @(otp_value(errtext[0] != 0));
        } else if (o->type == OC_FORM_OPT_PASSWORD) {
            // 密码字段判定（对齐 Android 端 isOtp 的 when 顺序）：
            // 有 TOKEN 字段 → 密码；同表单多密码字段按位置分（先密码后动态码）；
            // 提示语在要动态码 → 填码；固定密码已交过 → 这张是验证码段
            int idx = passwordIndex++;
            BOOL isOtp;
            if (tokenFieldExists) isOtp = NO;
            else if (!g_totpSecret.length) isOtp = NO;
            else if (passwordCount >= 2) isOtp = (idx != 0);
            else if (askingOtp) isOtp = YES;
            else if (g_staticPasswordSubmitted) isOtp = YES;
            else isOtp = NO;
            if (isOtp) {
                val = @(otp_value(errtext[0] != 0));
                IPATAppendLogLine([NSString stringWithFormat:@"[anyvpn] 动态码填入字段 %@", name]);
            } else if (g_cfgPass.length) {
                val = g_cfgPass;
            }
        }
        // TEXT：用户名之外的其他文本字段一律跳过（对齐 Android 端 else -> null），
        // 不取消——填不上就提交空值让网关给出提示
        if (val) {
            openconnect_set_option_value(o, val.UTF8String);
            filled++;
        }
    }
    // 交出固定密码（且该字段不是动态码字段）→ 记住进度
    // （上面的实现里只有非 OTP 的密码分支会置位，语义与 Android 端一致）

    // 网关报错且上一轮生成过动态码 → 记一次拒绝
    if (errtext[0] && hadOtpBefore) g_otpRejects++;

    // 一张表单都没填上：字段结构超出预期时取消，避免 openconnect 反复重放同一张表单
    if (filled == 0 && !authgroupFilled) {
        if (!message[0] && !errtext[0]) {
            anyvpn_status_notify(@"表单无提示信息且未识别出可填字段，停止连接");
            return OC_FORM_RESULT_CANCELLED;
        }
        if (passwordCount == 0 && !tokenFieldExists) {
            anyvpn_status_notify(@"表单未识别出可填字段（无密码/验证码项），停止连接");
            return OC_FORM_RESULT_CANCELLED;
        }
        // 有 message/error 提示且有密码类字段：提交空值，让网关给出具体错误
    }
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
@property (nonatomic, assign) BOOL pendingReconnect;  // 切换连接后等 cleanup 完自动重连
@property (nonatomic, copy) NSString *selectedIdMemo; // 本进程已知的选中连接 id（检测面板切换用）
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
        // 连接状态不跨进程存活：上次若连着时杀掉 App，残留的开关值会变成
        // 「显示开着但没有真实连接」的幽灵开关，启动时一律回落为关。
        // （IPATKeyAnyVpnEnabled 只反映当前连接状态，不是用户设置；
        //   初始默认值走 Info.plist 的 Enabled，由 applyConfig 读）
        [[NSUserDefaults standardUserDefaults] removeObjectForKey:IPATKeyAnyVpnEnabled];
        // 启动时就记住「已知的选中连接」。绝不能等到比较时才懒加载去读存储键：
        // 面板发切换通知前已经把新值写进了那个键，第一次比较必然读到新值，
        // 检测不出变化（这就是「连接中切线路没反应」的残留根因）
        self.selectedIdMemo = [[NSUserDefaults standardUserDefaults] stringForKey:IPATKeyAnyVpnActive] ?: @"";
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
    // 面板发变更通知前已经把新值写进了 NSUserDefaults（同一个键），
    // 这里绝不能再读存储键来判断「有没有变化」——读回来永远是新值。
    // 用内存里的 memo 记住本进程已知的选中 id，才能检测出面板传来的切换。
    if (self.selectedIdMemo) return self.selectedIdMemo;
    NSString *a = [[NSUserDefaults standardUserDefaults] stringForKey:IPATKeyAnyVpnActive];
    self.selectedIdMemo = a ?: @"";
    return self.selectedIdMemo;
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

#pragma mark TOTP 密钥表（账号级，对齐 Android 端 TotpVault：按账号取密钥）

// 存储：NSArray<NSDictionary>，每项 {user, secret}；连接时按当前连接的账号匹配

- (NSArray<NSDictionary *> *)totpEntries {
    id v = [[NSUserDefaults standardUserDefaults] objectForKey:IPATKeyAnyVpnTotp];
    return [v isKindOfClass:[NSArray class]] ? v : @[];
}

- (void)saveTotpEntries:(NSArray<NSDictionary *> *)entries {
    [[NSUserDefaults standardUserDefaults] setObject:entries forKey:IPATKeyAnyVpnTotp];
}

/// 连接账号对应的 TOTP 密钥（对齐 Android 端 TotpVault.normalize：trim + 忽略大小写）
- (NSString *)totpSecretForUser:(NSString *)user {
    NSString *key = [user stringByTrimmingCharactersInSet:
        [NSCharacterSet whitespaceAndNewlineCharacterSet]].lowercaseString;
    if (key.length == 0) return nil;
    for (NSDictionary *e in [self totpEntries]) {
        if (![e isKindOfClass:[NSDictionary class]]) continue;
        NSString *u = [e[@"user"] stringByTrimmingCharactersInSet:
            [NSCharacterSet whitespaceAndNewlineCharacterSet]].lowercaseString;
        if ([u isEqualToString:key]) {
            return [e[@"secret"] stringByTrimmingCharactersInSet:
                [NSCharacterSet whitespaceAndNewlineCharacterSet]];
        }
    }
    return nil;
}

/// 把面板 TOTP 行（IPATAnyVpnTotp:<i>:user|secret）的编辑写回密钥表；
/// 账号清空 = 删除该条
- (void)applyTotpEdit:(NSString *)key value:(NSString *)value {
    NSString *prefix = @"IPATAnyVpnTotp:";
    if (![key hasPrefix:prefix]) return;
    NSString *rest = [key substringFromIndex:prefix.length];
    NSRange sep = [rest rangeOfString:@":"];
    if (sep.location == NSNotFound) return;
    NSInteger idx = [rest substringToIndex:sep.location].integerValue;
    NSString *field = [rest substringFromIndex:NSMaxRange(sep)];
    if (field.length == 0) return;

    NSMutableArray<NSDictionary *> *entries = [[self totpEntries] mutableCopy];
    if (idx < 0 || idx >= (NSInteger)entries.count) return;
    NSMutableDictionary *e = [entries[idx] mutableCopy];
    e[field] = value;
    if ([field isEqualToString:@"user"] && value.length == 0) {
        [entries removeObjectAtIndex:idx];   // 账号清空 = 删除该条
    } else {
        entries[idx] = e;
    }
    [self saveTotpEntries:entries];
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
    // 沿用当前连接的账号/密码/认证组做默认值：多网关场景下这些通常相同，
    // 只需要改名称和服务器，省去重复输入
    NSDictionary<NSString *, NSString *> *prev = [self activeProfile];
    UIAlertController *alert = [UIAlertController
        alertControllerWithTitle:@"添加连接"
                         message:(prev ? @"已沿用当前连接的账号/密码/认证组，只需填名称和服务器"
                                       : @"连接名称用于在面板里切换；服务器必填")
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
        tf.text = prev[@"user"] ?: @"";
    }];
    [alert addTextFieldWithConfigurationHandler:^(UITextField *tf) {
        tf.placeholder = @"密码（可留空稍后填）";
        tf.secureTextEntry = YES;
        tf.text = prev[@"password"] ?: @"";
    }];
    [alert addTextFieldWithConfigurationHandler:^(UITextField *tf) {
        tf.placeholder = @"认证组（可留空 = 自动选第一个）";
        tf.text = prev[@"authgroup"] ?: @"";
    }];
    [alert addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    [alert addAction:[UIAlertAction actionWithTitle:@"保存" style:UIAlertActionStyleDefault
                                            handler:^(UIAlertAction *a) {
        NSString *server = alert.textFields[1].text ?: @"";
        if (server.length == 0) {
            [self toast:@"服务器地址不能为空"];
            return;
        }
        NSString *name = alert.textFields[0].text.length ? alert.textFields[0].text : server;
        // 名称即标识（面板分段存的就是名称），重名会在编辑时互相覆盖，这里先挡掉
        for (NSDictionary *q in [self profiles]) {
            if ([q isKindOfClass:[NSDictionary class]] &&
                [q[@"name"] caseInsensitiveCompare:name] == NSOrderedSame) {
                [self toast:@"已存在同名连接"];
                return;
            }
        }
        NSMutableDictionary *p = [NSMutableDictionary dictionary];
        p[@"id"] = name;   // 名称即标识
        p[@"name"] = name;
        p[@"server"] = server;
        p[@"user"] = alert.textFields[2].text ?: @"";
        p[@"password"] = alert.textFields[3].text ?: @"";
        p[@"authgroup"] = alert.textFields[4].text ?: @"";
        NSMutableArray *profs = [[self profiles] mutableCopy];
        [profs addObject:p];
        [self saveProfiles:profs];
        // 不改当前选中的线路——添加 ≠ 切换，用户要换就自己在分段上点
        [self toast:[NSString stringWithFormat:@"已添加 %@（在「连接」里点它切换）", name]];
        [self registerPanel];
    }]];
    [self presentAlert:alert];
}

/// 编辑当前连接的参数（名称/服务器/账号/密码/认证组），改名会同步切换标识
- (void)editActiveProfileAction {
    NSDictionary<NSString *, NSString *> *p = [self activeProfile];
    if (!p) return;
    UIAlertController *alert = [UIAlertController
        alertControllerWithTitle:[NSString stringWithFormat:@"编辑「%@」", p[@"name"] ?: @""]
                         message:@"改完点保存立即生效；改名会影响面板里显示的名称"
                  preferredStyle:UIAlertControllerStyleAlert];
    [alert addTextFieldWithConfigurationHandler:^(UITextField *tf) {
        tf.text = p[@"name"] ?: @"";
        tf.placeholder = @"连接名称";
    }];
    [alert addTextFieldWithConfigurationHandler:^(UITextField *tf) {
        tf.text = p[@"server"] ?: @"";
        tf.placeholder = @"服务器";
        tf.autocorrectionType = UITextAutocorrectionTypeNo;
        tf.autocapitalizationType = UITextAutocapitalizationTypeNone;
    }];
    [alert addTextFieldWithConfigurationHandler:^(UITextField *tf) {
        tf.text = p[@"user"] ?: @"";
        tf.placeholder = @"账号";
    }];
    [alert addTextFieldWithConfigurationHandler:^(UITextField *tf) {
        tf.text = p[@"password"] ?: @"";
        tf.placeholder = @"密码";
        tf.secureTextEntry = YES;
    }];
    [alert addTextFieldWithConfigurationHandler:^(UITextField *tf) {
        tf.text = p[@"authgroup"] ?: @"";
        tf.placeholder = @"认证组（空 = 自动选第一个）";
    }];
    [alert addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    [alert addAction:[UIAlertAction actionWithTitle:@"保存" style:UIAlertActionStyleDefault
                                            handler:^(UIAlertAction *a) {
        NSString *oldId = p[@"id"];
        NSString *newName = [alert.textFields[0].text stringByTrimmingCharactersInSet:
            [NSCharacterSet whitespaceAndNewlineCharacterSet]] ?: @"";
        NSString *server = alert.textFields[1].text ?: @"";
        if (newName.length == 0 || server.length == 0) {
            [self toast:@"名称和服务器不能为空"];
            return;
        }
        // 改名时查重（排除自己）
        for (NSDictionary *q in [self profiles]) {
            if (![q isKindOfClass:[NSDictionary class]]) continue;
            if ([q[@"id"] isEqualToString:oldId]) continue;
            if ([q[@"name"] caseInsensitiveCompare:newName] == NSOrderedSame) {
                [self toast:@"已存在同名连接"];
                return;
            }
        }
        NSMutableArray *out = [NSMutableArray array];
        for (NSDictionary *q in [self profiles]) {
            if (![q isKindOfClass:[NSDictionary class]]) continue;
            if ([q[@"id"] isEqualToString:oldId]) {
                NSMutableDictionary *np = [q mutableCopy];
                np[@"id"] = newName;
                np[@"name"] = newName;
                np[@"server"] = server;
                np[@"user"] = alert.textFields[2].text ?: @"";
                np[@"password"] = alert.textFields[3].text ?: @"";
                np[@"authgroup"] = alert.textFields[4].text ?: @"";
                [out addObject:np];
            } else {
                [out addObject:q];
            }
        }
        [self saveProfiles:out];
        // 当前选中的就是这条 → 同步 active 标识
        if ([[self activeProfileId] isEqualToString:oldId]) {
            [[NSUserDefaults standardUserDefaults] setObject:newName forKey:IPATKeyAnyVpnActive];
            self.selectedIdMemo = newName;
        }
        [self toast:@"已保存"];
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
        self.selectedIdMemo = @"";   // 回落到第一个连接
        [self toast:@"已删除"];
        [self registerPanel];
    }]];
    [self presentAlert:alert];
}

- (void)registerPanel {
    NSMutableArray *rows = [NSMutableArray array];
    NSArray<NSDictionary *> *profs = [self profiles];

    // 「连接」分段：只显示 VPN 名称，点名称即切换（开关开着会自动重连到新的）。
    // 各连接的参数不在主列表平铺，点「编辑当前连接」弹窗修改
    if (profs.count > 0) {
        NSMutableArray *names = [NSMutableArray array];
        for (NSDictionary *p in profs)
            if ([p isKindOfClass:[NSDictionary class]])
                [names addObject:p[@"name"] ?: p[@"server"] ?: @"?"];
        NSDictionary<NSString *, NSString *> *ap = [self activeProfile];
        NSString *cur = ap[@"name"] ?: names.firstObject;
        [rows addObject:@{IPATRowKey: IPATKeyAnyVpnActive, IPATRowTitle: @"连接",
                          IPATRowKind: IPATRowKindSegment,
                          IPATRowOptions: names, IPATRowValues: names,
                          IPATRowValue: cur,
                          IPATRowNote: @"点名称切换连接"}];
        [rows addObject:@{IPATRowKey: IPATKeyAnyVpnEditProfile, IPATRowTitle: @"✎ 编辑当前连接",
                          IPATRowKind: IPATRowKindAction}];
        [rows addObject:@{IPATRowKey: IPATKeyAnyVpnDelProfile, IPATRowTitle: @"－ 删除当前连接",
                          IPATRowKind: IPATRowKindAction}];
    }
    [rows addObject:@{IPATRowKey: IPATKeyAnyVpnAddProfile, IPATRowTitle: @"＋ 添加连接",
                      IPATRowKind: IPATRowKindAction}];
    [rows addObject:@{IPATRowKey: IPATKeyAnyVpnCopyLog, IPATRowTitle: @"⧉ 复制连接日志",
                      IPATRowKind: IPATRowKindAction,
                      IPATRowNote: @"排障用：复制最近 300 行日志，直接粘贴发送"}];
    // 连接/断开直接用面板顶部的「VPN 隧道」主开关（handleDidChange 里驱动），
    // 不再放「立即连接/断开」动作行——功能重复且把面板搞得很长

    // TOTP 密钥表（账号级，对齐 Android 端 TotpVault）：连接时按当前连接的
    // 账号自动取对应密钥；「账号」清空保存即删除该条
    NSArray<NSDictionary *> *totps = [self totpEntries];
    for (NSInteger i = 0; i < (NSInteger)totps.count; i++) {
        NSDictionary *e = totps[i];
        if (![e isKindOfClass:[NSDictionary class]]) continue;
        NSString *u = e[@"user"] ?: @"";
        [rows addObject:@{IPATRowKey: [NSString stringWithFormat:@"IPATAnyVpnTotp:%ld:user", (long)i],
                          IPATRowTitle: [NSString stringWithFormat:@"TOTP 账号 %ld", (long)(i + 1)],
                          IPATRowKind: IPATRowKindText, IPATRowValue: u,
                          IPATRowNote: @"清空并保存 = 删除该条"}];
        [rows addObject:@{IPATRowKey: [NSString stringWithFormat:@"IPATAnyVpnTotp:%ld:secret", (long)i],
                          IPATRowTitle: [NSString stringWithFormat:@"[%@] TOTP 密钥", u.length ? u : @"?"],
                          IPATRowKind: IPATRowKindText, IPATRowValue: e[@"secret"] ?: @"",
                          IPATRowSecure: @YES,
                          IPATRowNote: @"Base32 密钥（Google Authenticator 那串）"}];
    }
    [rows addObject:@{IPATRowKey: IPATKeyAnyVpnAddTotp, IPATRowTitle: @"＋ 添加 TOTP 密钥",
                      IPATRowKind: IPATRowKindAction}];
    if (totps.count > 0) {
        [rows addObject:@{IPATRowKey: IPATKeyAnyVpnDelTotp, IPATRowTitle: @"－ 删除最后一个 TOTP 密钥",
                          IPATRowKind: IPATRowKindAction}];
    }
    // 「注入后自动连接」「禁用 DTLS」子开关已从面板移除（内部保持默认行为）：
    // 主开关即连接/断开，状态随连接结果自动回落

    NSString *detail;
    if (profs.count == 0) {
        detail = @"AnyConnect 协议：先点「＋ 添加连接」配置服务器和账号，然后打开顶部开关连接";
    } else {
        detail = @"选中连接后打开顶部开关连接；连接失败开关会自动弹回";
    }

    NSDictionary *reg = @{
        IPATRegId: IPATFeatureAnyVpn,
        IPATRegTitle: @"VPN 隧道",
        IPATRegDetail: detail,
        IPATRegMasterKey: IPATKeyAnyVpnEnabled,
        IPATRegEnabled: @(self.masterOn),
        IPATRegRows: rows,
    };
    // cleanup 在连接线程里调 registerPanel，通知必须主线程发（面板要重建 UI）
    dispatch_async(dispatch_get_main_queue(), ^{
        [[NSNotificationCenter defaultCenter] postNotificationName:IPATControlRegisterNotification
                                                            object:nil
                                                          userInfo:reg];
    });
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
            IPATAppendLogLine([NSString stringWithFormat:@"[anyvpn] 切换连接：%@ → %@",
                               [self activeProfileId] ?: @"(无)", aid]);
            [[NSUserDefaults standardUserDefaults] setObject:aid forKey:IPATKeyAnyVpnActive];
            self.selectedIdMemo = aid;
            activeChanged = YES;
            NSDictionary<NSString *, NSString *> *p = [self activeProfile];
            [self status:[NSString stringWithFormat:@"已选择连接：%@", p[@"name"] ?: @""]];
        }
    }
    // （activeChanged && running 的重连在下面）
    // 面板 TOTP 行（账号/密钥编辑）→ 写回密钥表
    for (NSString *k in values)
        if ([k hasPrefix:@"IPATAnyVpnTotp:"] && [values[k] isKindOfClass:[NSString class]])
            [self applyTotpEdit:k value:values[k]];
    BOOL enabled = note.userInfo[IPATChgEnabled] ? [note.userInfo[IPATChgEnabled] boolValue] : self.masterOn;
    self.masterOn = enabled;
    // 换连接时若隧道在跑：先断旧隧道（stopConnect 只发取消，running 要等
    // cleanup 才置 NO，所以这里挂起重连意图，cleanup 完成后自动接上）
    if (activeChanged && self.running) {
        if (enabled) self.pendingReconnect = YES;
        [self stopConnect];
    }
    if (enabled && !self.running) [self startConnect];
    if (!enabled && self.running) [self stopConnect];
    [self registerPanel];
}

- (void)handleAction:(NSNotification *)note {
    NSString *key = note.userInfo[IPATActKey];
    if ([key isEqualToString:IPATKeyAnyVpnAddProfile]) {
        [self addProfileAction];
    } else if ([key isEqualToString:IPATKeyAnyVpnEditProfile]) {
        [self editActiveProfileAction];
    } else if ([key isEqualToString:IPATKeyAnyVpnDelProfile]) {
        [self deleteActiveProfileAction];
    } else if ([key isEqualToString:IPATKeyAnyVpnAddTotp]) {
        [self addTotpAction];
    } else if ([key isEqualToString:IPATKeyAnyVpnDelTotp]) {
        [self deleteLastTotpAction];
    } else if ([key isEqualToString:IPATKeyAnyVpnCopyLog]) {
        [self copyLogAction];
    }
    [self registerPanel];
}

/// 添加一条 TOTP 密钥（账号 + Base32 密钥）
- (void)addTotpAction {
    UIAlertController *alert = [UIAlertController
        alertControllerWithTitle:@"添加 TOTP 密钥"
                         message:@"填该密钥所属的账号（要与连接里填的账号一致）"
                  preferredStyle:UIAlertControllerStyleAlert];
    [alert addTextFieldWithConfigurationHandler:^(UITextField *tf) {
        tf.placeholder = @"账号";
        tf.autocapitalizationType = UITextAutocapitalizationTypeNone;
        tf.autocorrectionType = UITextAutocorrectionTypeNo;
    }];
    [alert addTextFieldWithConfigurationHandler:^(UITextField *tf) {
        tf.placeholder = @"TOTP 密钥（Base32，如 JBSWY3DPEHPK3PXP）";
        tf.autocapitalizationType = UITextAutocapitalizationTypeAllCharacters;
        tf.autocorrectionType = UITextAutocorrectionTypeNo;
    }];
    [alert addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    [alert addAction:[UIAlertAction actionWithTitle:@"保存" style:UIAlertActionStyleDefault
                                            handler:^(UIAlertAction *a) {
        NSString *user = [alert.textFields[0].text stringByTrimmingCharactersInSet:
            [NSCharacterSet whitespaceAndNewlineCharacterSet]] ?: @"";
        NSString *secret = [alert.textFields[1].text stringByTrimmingCharactersInSet:
            [NSCharacterSet whitespaceAndNewlineCharacterSet]] ?: @"";
        if (user.length == 0 || secret.length == 0) {
            [self toast:@"账号和密钥都要填"];
            return;
        }
        NSMutableArray *entries = [[self totpEntries] mutableCopy];
        [entries addObject:@{@"user": user, @"secret": secret}];
        [self saveTotpEntries:entries];
        [self toast:[NSString stringWithFormat:@"已添加 %@ 的 TOTP 密钥", user]];
        [self registerPanel];
    }]];
    [self presentAlert:alert];
}

/// 删除最后一条 TOTP 密钥
- (void)deleteLastTotpAction {
    NSMutableArray *entries = [[self totpEntries] mutableCopy];
    if (entries.count == 0) return;
    NSString *user = entries.lastObject[@"user"] ?: @"";
    [entries removeLastObject];
    [self saveTotpEntries:entries];
    [self toast:[NSString stringWithFormat:@"已删除 %@ 的 TOTP 密钥", user]];
    [self registerPanel];
}

/// 复制连接日志尾部到剪贴板（排障用，同 Android 端日志导出）
- (void)copyLogAction {
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_DEFAULT, 0), ^{
        NSString *path = [NSSearchPathForDirectoriesInDomains(NSDocumentDirectory,
                             NSUserDomainMask, YES).firstObject
                          stringByAppendingPathComponent:@"ipatool.log"];
        NSFileManager *fm = [NSFileManager defaultManager];
        NSString *text = [NSString stringWithContentsOfFile:path
                                                   encoding:NSUTF8StringEncoding error:nil];
        NSMutableArray<NSString *> *lines = [[text componentsSeparatedByString:@"\n"] mutableCopy];
        // 内存副本补齐：文件被沙盒清空/轮转/写失败时，至少还有本次会话的日志
        NSArray<NSString *> *mem = [IPATLogMemoryBuffer() copy];
        NSMutableSet<NSString *> *seen = [NSMutableSet setWithArray:lines ?: @[]];
        for (NSString *l in mem) {
            if (l.length && ![seen containsObject:l]) {
                [seen addObject:l];
                [lines addObject:l];
            }
        }
        // 只取尾部 300 行，剪贴板塞几十 KB 足够排障且不卡 UI
        if (lines.count > 300)
            lines = [[lines subarrayWithRange:NSMakeRange(lines.count - 300, 300)] mutableCopy];
        NSString *out = [lines componentsJoinedByString:@"\n"];
        unsigned long long size = [[fm attributesOfItemAtPath:path error:nil][NSFileSize] unsignedLongLongValue];
        dispatch_async(dispatch_get_main_queue(), ^{
            [UIPasteboard generalPasteboard].string = out;
            if (lines.count == 0) {
                [self toast:@"没有任何日志：本进程没产生过日志（功能 dylib 可能没加载）"];
            } else if (!text) {
                [self toast:[NSString stringWithFormat:@"已复制 %lu 行（来自内存，日志文件不存在）",
                             (unsigned long)lines.count]];
            } else {
                [self toast:[NSString stringWithFormat:@"已复制 %lu 行日志到剪贴板（文件 %.1f KB）",
                             (unsigned long)lines.count, (double)size / 1024.0]];
            }
        });
    });
}

/// 屏幕上弹一条几秒消失的提示（面板端渲染）；可能从后台线程调用，跳主线程
- (void)toast:(NSString *)text {
    dispatch_async(dispatch_get_main_queue(), ^{
        [[NSNotificationCenter defaultCenter] postNotificationName:IPATControlToastNotification
                                                            object:nil
                                                          userInfo:@{IPATToastText: text}];
    });
}

- (void)status:(NSString *)text {
    IPATAppendLogLine([NSString stringWithFormat:@"[anyvpn] %@", text]);
    dispatch_async(dispatch_get_main_queue(), ^{
        [[NSNotificationCenter defaultCenter] postNotificationName:IPATControlStatusNotification
                                                            object:nil
                                                          userInfo:@{IPATRegId: IPATFeatureAnyVpn,
                                                                     IPATStaDetail: text}];
    });
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
    // TOTP 密钥是账号级凭据（对齐 Android 端 TotpVault.get(username)）：
    // 按当前连接的账号从密钥表取，找不到再回落 Info.plist 的 TotpSecret
    g_totpSecret = [self totpSecretForUser:g_cfgUser]
                   ?: [self plist:@"TotpSecret" default:@""];
    NSDictionary<NSString *, NSString *> *ap = [self activeProfile];
    if (ap) [self status:[NSString stringWithFormat:@"正在连接 %@ …", ap[@"name"] ?: @""]];
    return YES;
}

- (void)startConnect {
    if (self.running) return;
    if (![self configured]) return;
    // 重置 TOTP 状态机（上一次连接的进度/拒绝计数不能带过来）
    g_otpWindow = -1;
    g_lastOtp[0] = 0;
    g_otpRejects = 0;
    g_usedOtpThisAttempt = NO;
    g_staticPasswordSubmitted = NO;
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

// 连接线程入口：整轮重试（对齐 Android 端 MAX_CONNECT_ATTEMPTS=3 /
// RETRY_DELAY_MS=2000）。认证失败（典型：TOTP 时间窗尾部被网关 401）下一轮
// 重新认证会生成新码，往往第二次就过
- (void)runSession {
    @autoreleasepool {
        for (int attempt = 1; attempt <= 3; attempt++) {
            if (!self.masterOn) return;
            if (attempt > 1) {
                [self status:[NSString stringWithFormat:@"第 %d 次尝试失败，2 秒后重试（共 3 次）",
                              attempt - 1]];
                [NSThread sleepForTimeInterval:2.0];
                if (!self.masterOn) return;
            }
            if ([self runSessionOnce]) return;   // 走完 mainloop 正常断开
            // 本轮失败（多为 401）：这个动态码已经交给网关了，网关普遍有重放保护，
            // 同一个码再交必被拒。标记已用，下轮尝试会在 otp_value 里等到
            // 下一个 30s 窗口换新码再提交
            g_usedOtpThisAttempt = YES;
        }
        [self fail:@"连续 3 次连接失败，已停止（点「复制连接日志」查原因）"];
    }
}

// 单次完整连接尝试。返回 YES = 走完 mainloop 正常断开（结束重试）；
// NO = 本轮失败（fail: 里已 cleanup，可重试）
- (BOOL)runSessionOnce {
    @autoreleasepool {
        // 固定密码的提交记忆是「每轮尝试」级的，要重置；
        // TOTP 的窗口/旧码/拒绝计数必须跨尝试保留——以前在这里整体重置，
        // 重试会在同一个 30s 窗口里把已提交过的码原样再交一遍，
        // 撞上网关重放保护 → 连续 401，直到窗口翻转才成功（表现为重试两次才连上）
        g_staticPasswordSubmitted = NO;

        // 底层网卡绑定策略：
        //  - 越狱（root）模式：utun 接管了系统路由，VPN 自己的 socket 必须绑到
        //    物理网卡，否则会被 utun 路由绕回隧道成环
        //  - 非越狱模式：隧道是「应用级接管」（T2S 引擎 + fishhook），系统路由表
        //    里没有隧道路由，本来就不会成环；而强绑网卡一旦绑错（蜂窝/WiFi 切换
        //    的瞬间）就会 ENETUNREACH 连不上——所以不绑，走系统默认路由
        BOOL root = (geteuid() == 0);
        g_underlying_idx = 0;
        if (root) {
            NSString *underlying = [self plist:@"UnderlyingIface" default:@""];
            if (underlying.length) {
                g_underlying_idx = ifindex_of(underlying.UTF8String);
            } else {
                g_underlying_idx = probe_underlying_ifindex();
            }
        }
        int probedIdx = probe_underlying_ifindex();
        char ifname[IFNAMSIZ] = {0};
        if (probedIdx > 0 && if_indextoname((unsigned)probedIdx, ifname)) {
            IPATAppendLogLine([NSString stringWithFormat:
                @"[anyvpn] 底层网卡：%s（idx %d）%@", ifname, probedIdx,
                root ? @"（已绑定）" : @"（非越狱模式，仅提示，不绑定）"]);
        } else {
            g_underlying_idx = 0;
            IPATAppendLogLine([NSString stringWithFormat:
                @"[anyvpn] 底层网卡：探测失败（%@）", root ? @"不绑定，走系统默认路由"
                                                        : @"非越狱模式，走系统默认路由"]);
        }
        NSString *server = g_cfgServer;

        NSString *host = server;
        NSRange r = [server rangeOfString:@"//"];
        if (r.location != NSNotFound) host = [server substringFromIndex:r.location + 2];
        NSRange slash = [host rangeOfString:@"/"];
        if (slash.location != NSNotFound) host = [host substringToIndex:slash.location];
        NSRange colon = [host rangeOfString:@":"];
        if (colon.location != NSNotFound) host = [host substringToIndex:colon.location];
        g_certKey = [NSString stringWithFormat:@"IPATAnyVpnCertHash_%@", host];

        // DNS 预检：198.18.0.0/15 是 Surge/小火箭/Clash 等 fake-ip 模式的保留网段。
        // 域名解析成这个段说明被设备上的代理软件劫持了，直连假 IP 必然超时，
        // 最后只会得到一个误导性的"认证失败"——在这里就明确报出来
        struct addrinfo fakeHints = {.ai_family = AF_INET};
        struct addrinfo *fakeRes = NULL;
        if (getaddrinfo(host.UTF8String, NULL, &fakeHints, &fakeRes) == 0 && fakeRes) {
            BOOL fakeIp = NO;
            char ipbuf[INET_ADDRSTRLEN] = {0};
            for (struct addrinfo *ai = fakeRes; ai; ai = ai->ai_next) {
                if (ai->ai_family != AF_INET || !ai->ai_addr) continue;
                uint32_t be = ((struct sockaddr_in *)ai->ai_addr)->sin_addr.s_addr;
                uint32_t iph = ntohl(be);
                if ((iph & 0xFFFE0000u) == 0xC6120000u) {   // 198.18.0.0/15
                    fakeIp = YES;
                    struct sockaddr_in *sa = (struct sockaddr_in *)ai->ai_addr;
                    inet_ntop(AF_INET, &sa->sin_addr, ipbuf, sizeof ipbuf);
                    break;
                }
            }
            freeaddrinfo(fakeRes);
            if (fakeIp) {
                [self fail:[NSString stringWithFormat:
                    @"域名解析到了代理软件的 fake-IP（%@）——请关闭 Surge/小火箭等代理，"
                    "或把该域名设为直连", [NSString stringWithUTF8String:ipbuf]]];
                return NO;
            }
        }

        if (openconnect_init_ssl() != 0) {
            [self fail:@"SSL 初始化失败"];
            return NO;
        }
        NSString *ua = [self plist:@"UserAgent" default:@"AnyConnect Darwin/5.0.05042"];
        g_vpninfo = openconnect_vpninfo_new((char *)ua.UTF8String,
                                            cb_validate_peer_cert, NULL,
                                            cb_auth_form, cb_progress, NULL);
        if (!g_vpninfo) {
            [self fail:@"vpninfo 创建失败"];
            return NO;
        }
        openconnect_set_protocol(g_vpninfo, "anyconnect");
        // 诊断：开到 PRG_DEBUG（HTTP/CSTP 层交互细节），排查「连接 3 秒后被网关
        // 干净断开」。PRG_TRACE 的每包 hexdump 仍被 cb_progress 丢弃
        openconnect_set_loglevel(g_vpninfo, 2);   // PRG_DEBUG
        // 注意：不用 openconnect 的 --token-mode=totp（对齐 Android 端决策）——
        // 它把动态码追加到密码后面，而实测网关把动态码作为独立表单字段下发；
        // 动态码在 cb_auth_form 里按安卓 AuthSession 的规则当场生成回填
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
            return NO;
        }
        g_cmd_fd = openconnect_setup_cmd_pipe(g_vpninfo);

        // 认证：可能多轮触发表单回调（账号 -> 动态码 -> 密码）。
        // obtain_cookie 失败可能是 DNS/网络/证书/表单任一环节，统一让用户看日志
        if (openconnect_obtain_cookie(g_vpninfo) != 0) {
            [self fail:@"连接网关失败（DNS/网络/证书/认证，点「复制连接日志」查原因）"];
            return NO;
        }
        if (openconnect_make_cstp_connection(g_vpninfo) != 0) {
            [self fail:@"CSTP 隧道建立失败"];
            return NO;
        }

        const struct oc_ip_info *ip = NULL;
        const struct oc_vpn_option *cstp = NULL, *dtls = NULL;
        openconnect_get_ip_info(g_vpninfo, &ip, &cstp, &dtls);
        if (!ip || !ip->addr) {
            [self fail:@"网关没下发 IP 信息"];
            return NO;
        }

        // TUN 两种模式：
        //  - root（越狱）：建 utun 配地址加路由，系统级接管（老路径）
        //  - 非 root：socketpair 掉包，openconnect 的 tun 对端接 lwIP 用户态
        //    TCP/IP 栈 + fishhook 劫持宿主流量（见 AnyVpnT2S）
        char tunname[IFNAMSIZ] = {0};
        if (root) {
            g_tun_fd = create_utun(tunname);
            if (g_tun_fd < 0) {
                [self fail:@"utun 创建失败"];
                return NO;
            }
            if (ifconfig_tun(tunname, ip->addr,
                             ip->gateway_addr ? ip->gateway_addr : ip->addr,
                             ip->netmask ? ip->netmask : "255.255.255.0") != 0) {
                [self fail:[NSString stringWithFormat:@"utun(%s) 地址配置失败（SIOCAIFADDR）",
                            tunname]];
                return NO;
            }
            if (openconnect_setup_tun_fd(g_vpninfo, g_tun_fd) != 0) {
                [self fail:@"tun fd 交给 openconnect 失败"];
                return NO;
            }
        } else {
            int sp[2];
            // 必须保包边界：openconnect 的 tun 读是按包边界的（一次 read = 一个
            // 完整 IP 包）。SOCK_STREAM 是字节流会粘包 → 服务端收到畸形包秒断
            // CSTP。iOS 的 XNU 不支持 AF_UNIX SEQPACKET，用 DGRAM（同样一次
            // write = 一次 read 一个包，语义等价）
            if (socketpair(AF_UNIX, SOCK_DGRAM, 0, sp) != 0) {
                [self fail:@"socketpair 创建失败（DGRAM）"];
                return NO;
            }
            if (openconnect_setup_tun_fd(g_vpninfo, sp[0]) != 0) {
                close(sp[0]); close(sp[1]);
                [self fail:@"tun fd 交给 openconnect 失败"];
                return NO;
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
                return NO;
            }
            strlcpy(tunname, "t2s", IFNAMSIZ);
        }
        // DTLS（UDP 443）在很多网络里握不上手（实测 DTLS handshake timed out），
        // 且断连循环的总发生在 DTLS 初始化之后——先强制禁用，走纯 CSTP(TCP)。
        // CSTP-only 带宽低但稳定，确认稳定后再修 DTLS 路径
        openconnect_disable_dtls(g_vpninfo);

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

        // ip->addr 是 const char*，喂给 %@ 前必须包成 NSString（类型不匹配还会运行时崩）
        NSString *ipStr = ip->addr ? @(ip->addr) : @"";
        // %s 会把 UTF-8 中文按 Latin-1 解码（日志乱码），一律用 %@ + @() 包裹
        [self status:[NSString stringWithFormat:@"已连接 %@（IP %@ / %@%@）",
                      server, ipStr, @(tunname),
                      root ? @"" : @"，非越狱模式：接管本 App 直连流量"]];
        [self toast:[NSString stringWithFormat:@"✅ VPN 已连接 %@（IP %@）",
                     [self activeProfile][@"name"] ?: server, ipStr]];

        // 主循环：断线重连参数与 Android 端一致
        openconnect_mainloop(g_vpninfo, 300, 10);
        [self teardownRoutesIfNeeded:ip];
        [self status:@"已断开"];
        [self cleanup];
        return YES;
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
    // 主开关状态随连接结果回落：连接失败/被服务端断开时，面板上的开关
    // 不能还停在 ON（那会骗人以为还连着）。切换连接的挂起重连除外——
    // 那种场景马上要重新连上，开关保持 ON 是对的
    if (self.masterOn && !self.pendingReconnect) {
        self.masterOn = NO;
        [[NSUserDefaults standardUserDefaults] setBool:NO forKey:IPATKeyAnyVpnEnabled];
    }
    [self registerPanel];   // 刷新主开关状态显示
    // 切换连接时挂起的重连意图：旧隧道拆干净了，接上新连接
    if (self.pendingReconnect) {
        self.pendingReconnect = NO;
        if (self.masterOn) {
            dispatch_async(dispatch_get_main_queue(), ^{
                if (self.masterOn && !self.running) [self startConnect];
            });
        }
    }
}

@end

#pragma mark - 入口

__attribute__((constructor))
static void IPATAnyVpnLoad(void) {
    // 构建版本戳：dylib 一加载就写进日志。排查「日志 0 行/行为不符」时，
    // 第一行就能确认设备上跑的是哪个构建——防止装到旧包白测一轮
    IPATAppendLogLine(@"[anyvpn] dylib 已加载：构建 DNS-TCP-20261030（DNS over TCP + tcp_tmr）");
    // 尽早装 socket 劫持（引擎没就绪时全部直通原函数，不影响 App 正常运行）
    T2SInstallHooks();
    // 与其他 tweak 一致：延后一点等主线程就绪再初始化
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        [AnyVPNController shared];
    });
}
