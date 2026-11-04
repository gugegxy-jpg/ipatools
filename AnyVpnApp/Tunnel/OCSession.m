#import "OCSession.h"

#import <openconnect.h>
#import <CommonCrypto/CommonHMAC.h>
#import <arpa/inet.h>
#import <ctype.h>
#import <stdarg.h>
#import <string.h>
#import <sys/socket.h>
#import <time.h>
#import <unistd.h>

// 一个 Packet Tunnel 扩展进程只跑一条会话，用文件内静态状态承接
// openconnect 的 C 回调（没有 privdata 可用时也安全）。
static struct openconnect_info *g_vpninfo = NULL;
static int   g_cmd_fd = -1;
static NSString *g_cfgServer, *g_cfgUser, *g_cfgPass, *g_cfgGroup, *g_totpSecret;
static NSString *g_expectedCertHash, *g_appGroup, *g_profileId;
static BOOL  g_disableDtls;
static OCLogBlock g_log;

static long  g_otpWindow = -1;
static char  g_lastOtp[8] = {0};
static int   g_otpRejects = 0;
static BOOL  g_usedOtpThisAttempt = NO;
static BOOL  g_staticPasswordSubmitted = NO;
#define MAX_OTP_REJECTS 3
#define LOG_DROP_LEVEL  3   // 丢 PRG_TRACE 的每包 hexdump（对齐安卓端）

static void oc_log(NSString *fmt, ...) NS_FORMAT_FUNCTION(1, 2);
static void oc_log(NSString *fmt, ...) {
    va_list ap;
    va_start(ap, fmt);
    NSString *line = [[NSString alloc] initWithFormat:fmt arguments:ap];
    va_end(ap);
    if (g_log) g_log(line);
}

#pragma mark - TOTP / 表单判定（从 tweak/AnyVpn.m 移植，逻辑与安卓 AuthSession 对齐）

// Base32 解码（RFC 4648，容忍空格/横杠/填充）
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

// RFC 6238：SHA1 / 6 位 / 30s
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

// 同窗口被拒要等下一个窗口换新码，避免连续撞库锁定账号
static const char *otp_value(BOOL hadError) {
    if (!g_totpSecret.length) return "";
    long win = (long)(time(NULL) / 30);
    if (g_lastOtp[0] && win == g_otpWindow) {
        if (hadError || g_usedOtpThisAttempt) {
            long remain = 30 - (long)(time(NULL) % 30) + 1;
            oc_log(@"[oc] 动态码仍在当前窗口，等待 %lds 换新码", remain);
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

// 网关要动态码的依据是提示语，不是字段名（实测三段式里字段名与提示语交叉）
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

#pragma mark - openconnect 回调

static void cb_progress(void *privdata, int level, const char *fmt, ...) {
    if (level >= LOG_DROP_LEVEL) return;
    char buf[1024];
    va_list ap;
    va_start(ap, fmt);
    vsnprintf(buf, sizeof buf, fmt, ap);
    va_end(ap);
    size_t n = strlen(buf);
    while (n && (buf[n - 1] == '\n' || buf[n - 1] == '\r')) buf[--n] = 0;
    oc_log(@"[oc] %s", buf);
}

// 证书：填了期望指纹就严格比对，否则 TOFU（首次记录，之后变化即拒绝）
static int cb_validate_peer_cert(void *privdata, const char *reason) {
    const char *hash = openconnect_get_peer_cert_hash(g_vpninfo);
    NSString *fp = hash ? [NSString stringWithUTF8String:hash] : @"";
    if (g_expectedCertHash.length) {
        if ([g_expectedCertHash isEqualToString:fp]) return 0;
        oc_log(@"[oc] ❌ 证书指纹与期望值不符（期望 %@ 实得 %@，原因 %s）",
               g_expectedCertHash, fp, reason ?: "");
        return 1;
    }
    NSString *key = [NSString stringWithFormat:@"com.anyvpn.cert.%@", g_profileId];
    NSUserDefaults *ud = [[NSUserDefaults alloc] initWithSuiteName:g_appGroup];
    NSString *saved = [ud stringForKey:key];
    if (!saved.length) {
        [ud setObject:fp forKey:key];
        oc_log(@"[oc] 首次连接，已记录网关证书指纹 %@", fp);
        return 0;
    }
    if ([saved isEqualToString:fp]) return 0;
    oc_log(@"[oc] ❌ 证书指纹变化，拒绝连接（旧 %@ 新 %@）", saved, fp);
    return 1;
}

// 认证表单自动回填：账号 → 动态码 → 固定密码
static int cb_auth_form(void *privdata, struct oc_auth_form *form) {
    const char *message = form->message ?: "";
    const char *errtext = form->error ?: "";
    if (message[0]) oc_log(@"[oc] 表单：%s", message);

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
    oc_log(@"[oc] 表单字段：%@，密码字段=%d，要验证码=%d",
           [fieldDesc componentsJoinedByString:@" "], passwordCount, askingOtp);
    if (usernameAgain) g_staticPasswordSubmitted = NO;

    if (askingOtp && !g_totpSecret.length) {
        oc_log(@"[oc] ❌ 网关要求验证码，但账号 %@ 未配置 TOTP 密钥", g_cfgUser ?: @"");
        return OC_FORM_RESULT_CANCELLED;
    }
    if (g_otpRejects >= MAX_OTP_REJECTS) {
        oc_log(@"[oc] ❌ 动态码连续被拒 %d 次，停止重试（避免账号锁定）", g_otpRejects);
        return OC_FORM_RESULT_CANCELLED;
    }
    BOOL hadOtpBefore = (g_lastOtp[0] != 0);

    int passwordIndex = 0;
    int filled = 0;
    BOOL authgroupFilled = NO;
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
                form->authgroup_selection = pick >= 0 ? pick : 0;
                authgroupFilled = YES;
                continue;
            }
            int use = pick >= 0 ? pick : 0;
            if (use < sel->nr_choices && sel->choices[use]->name) {
                openconnect_set_option_value(o, (char *)sel->choices[use]->name);
                filled++;
            }
            continue;
        }
        NSString *val = nil;
        if (is_username_field(o->name, o->label) && g_cfgUser.length) {
            val = g_cfgUser;
        } else if (o->type == OC_FORM_OPT_TOKEN) {
            val = @(otp_value(errtext[0] != 0));
        } else if (o->type == OC_FORM_OPT_PASSWORD) {
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
                oc_log(@"[oc] 动态码填入字段 %@", name);
            } else if (g_cfgPass.length) {
                val = g_cfgPass;
                // 修掉 dylib 里「从未置 YES」的缺陷：交过固定密码后，
                // 下一张密码表单就是验证码段
                g_staticPasswordSubmitted = YES;
            }
        }
        if (val) {
            openconnect_set_option_value(o, (char *)val.UTF8String);
            filled++;
        }
    }

    if (errtext[0] && hadOtpBefore) g_otpRejects++;
    if (filled == 0 && !authgroupFilled) {
        if (!message[0] && !errtext[0]) {
            oc_log(@"[oc] ❌ 表单无提示信息且未识别出可填字段，停止连接");
            return OC_FORM_RESULT_CANCELLED;
        }
        if (passwordCount == 0 && !tokenFieldExists) {
            oc_log(@"[oc] ❌ 表单未识别出可填字段（无密码/验证码项），停止连接");
            return OC_FORM_RESULT_CANCELLED;
        }
    }
    return OC_FORM_RESULT_OK;
}

#pragma mark - OCSession

@implementation OCSession {
    NSString *_lastError;
}

- (NSString *)lastError { return _lastError ?: @""; }

- (instancetype)initWithConfig:(NSDictionary<NSString *, id> *)config log:(OCLogBlock)log {
    if ((self = [super init])) {
        g_log = [log copy];
        NSString *s;
#define CFG_STR(field, key) s = config[key]; field = ([s isKindOfClass:NSString.class] ? [s copy] : @"")
        CFG_STR(g_cfgServer, @"server");
        CFG_STR(g_cfgUser, @"username");
        CFG_STR(g_cfgPass, @"password");
        CFG_STR(g_cfgGroup, @"authgroup");
        CFG_STR(g_totpSecret, @"totpSecret");
        CFG_STR(g_expectedCertHash, @"expectedCertHash");
        CFG_STR(g_appGroup, @"appGroup");
        CFG_STR(g_profileId, @"profileId");
#undef CFG_STR
        g_disableDtls = [config[@"disableDtls"] boolValue];

        g_vpninfo = NULL;
        g_cmd_fd = -1;
        g_otpWindow = -1;
        g_lastOtp[0] = 0;
        g_otpRejects = 0;
        g_usedOtpThisAttempt = NO;
        g_staticPasswordSubmitted = NO;
    }
    return self;
}

- (NSDictionary<NSString *, id> *)fail:(NSString *)msg {
    _lastError = [msg copy];
    oc_log(@"[oc] ❌ %@", msg);
    [self shutdown];
    return nil;
}

- (NSDictionary<NSString *, id> * _Nullable)connectAndGetIPInfo {
    if (openconnect_init_ssl() != 0) return [self fail:@"SSL 初始化失败"];

    g_vpninfo = openconnect_vpninfo_new(
        (char *)"AnyConnect Darwin/5.0.05042",
        cb_validate_peer_cert, NULL, cb_auth_form, cb_progress, NULL);
    if (!g_vpninfo) return [self fail:@"vpninfo 创建失败"];

    openconnect_set_protocol(g_vpninfo, "anyconnect");
    openconnect_set_loglevel(g_vpninfo, 2);                       // PRG_DEBUG
    openconnect_set_version_string(g_vpninfo, (char *)"5.0.05042");
    openconnect_set_reported_os(g_vpninfo, (char *)"iOS");
    openconnect_set_mobile_info(g_vpninfo, (char *)"iOS", (char *)"iOS",
                                (char *)"0000000000000000");
    // NetworkExtension 由系统托管扩展自身的外联 socket，不需要
    // Android 的 VpnService.protect()，也不要 IP_BOUND_IF（蜂窝切换会 ENETUNREACH）
    if (g_disableDtls) openconnect_disable_dtls(g_vpninfo);

    if (openconnect_parse_url(g_vpninfo, g_cfgServer.UTF8String) != 0)
        return [self fail:@"服务器地址解析失败"];
    g_cmd_fd = openconnect_setup_cmd_pipe(g_vpninfo);

    oc_log(@"[oc] 开始认证 %@", g_cfgServer);
    if (openconnect_obtain_cookie(g_vpninfo) != 0)
        return [self fail:@"连接网关失败（DNS/证书/表单认证，看日志）"];
    if (openconnect_make_cstp_connection(g_vpninfo) != 0)
        return [self fail:@"CSTP 隧道建立失败"];

    const struct oc_ip_info *ip = NULL;
    const struct oc_vpn_option *cstp = NULL, *dtls = NULL;
    openconnect_get_ip_info(g_vpninfo, &ip, &cstp, &dtls);
    if (!ip || !ip->addr) return [self fail:@"网关没下发 IP 信息"];

    NSMutableDictionary<NSString *, id> *d = [NSMutableDictionary dictionary];
#define PUT_STR(k, v) do { if ((v) && (v)[0]) d[k] = [NSString stringWithUTF8String:(v)]; } while (0)
    PUT_STR(@"addr", ip->addr);
    PUT_STR(@"netmask", ip->netmask);
    PUT_STR(@"addr6", ip->addr6);
    PUT_STR(@"netmask6", ip->netmask6);
    PUT_STR(@"gateway", ip->gateway_addr);
    PUT_STR(@"domain", ip->domain);
#undef PUT_STR
    d[@"mtu"] = @(ip->mtu > 0 ? ip->mtu : 1400);

    NSMutableArray<NSString *> *dns = [NSMutableArray array];
    for (int i = 0; i < 3; i++)
        if (ip->dns[i] && ip->dns[i][0]) [dns addObject:@(ip->dns[i])];
    d[@"dns"] = dns;

    NSMutableArray<NSString *> *routes = [NSMutableArray array];
    for (struct oc_split_include *r = ip->split_includes; r; r = r->next)
        if (r->route && r->route[0]) [routes addObject:@(r->route)];
    d[@"splitIncludes"] = routes;

    oc_log(@"[oc] 网关配置：IP %@ / DNS %@ / MTU %@ / 路由 %lu 条",
           d[@"addr"] ?: @"?", [dns componentsJoinedByString:@","],
           d[@"mtu"], (unsigned long)routes.count);
    return d;
}

- (BOOL)attachTunFd:(int)fd {
    if (!g_vpninfo) return NO;
    int r = openconnect_setup_tun_fd(g_vpninfo, fd);
    if (r != 0) {
        oc_log(@"[oc] ❌ setup_tun_fd 失败：%d", r);
        return NO;
    }
    return YES;
}

- (void)runMainloop {
    if (!g_vpninfo) return;
    oc_log(@"[oc] mainloop 启动");
    openconnect_mainloop(g_vpninfo, 300, 10);
    oc_log(@"[oc] mainloop 退出");
}

- (void)cancel {
    if (g_cmd_fd >= 0) {
        char c = OC_CMD_CANCEL;
        ssize_t w = write(g_cmd_fd, &c, 1);
        (void)w;
    }
}

- (void)shutdown {
    if (g_vpninfo) {
        openconnect_vpninfo_free(g_vpninfo);
        g_vpninfo = NULL;
    }
    // cmd pipe 归 openconnect 管，vpninfo_free 已回收，这里只清编号
    g_cmd_fd = -1;
}

@end
