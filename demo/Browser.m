//
//  Browser.m
//  ipatool demo：简易内网浏览器（裸 socket）
//
//  为什么不用 WKWebView / NSURLSession：
//  它们在 CFNetwork / WebContent 进程里建连，AnyVpn.dylib 的 fishhook 劫持不到，
//  内网站点必然打不开——那是「非越狱模式」的硬边界，不是 bug。
//  这里用裸 BSD socket 自己发请求，和游戏自研网络层是同一条通道，
//  connect/sendto/getaddrinfo 会被劫持进 CSTP 隧道。
//  内网页面能在这里打开 = 隧道真的在跑流量。
//
//  能力：
//    http://host[:port]/path   → 完整响应（状态行 + 头 + 正文，HTML 抽标题和纯文本）
//    https://host[:port]/path  → TLS 握手探测：证明隧道把包送到了 443（不解密内容）
//    直接填 IP:端口           → 绕过 DNS（线路 DNS 不通时的唯一通道）
//    「对照」按钮             → 用 NSURLSession 请求同一地址（系统网络栈，劫持不到），
//                              和上面的结果并排看，差别一目了然
//

#import "Browser.h"

#import <sys/socket.h>
#import <netinet/in.h>
#import <arpa/inet.h>
#import <netdb.h>
#import <unistd.h>
#import <errno.h>
#import <stdlib.h>
#import <string.h>

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"

// ---------------------------------------------------------------- URL

typedef struct {
    NSString *host;
    int port;
    NSString *path;
    BOOL isTLS;
} IPATURL;

static BOOL IPATParseURL(NSString *input, IPATURL *out, NSString **err) {
    NSString *s = [input stringByTrimmingCharactersInSet:
                   [NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (!s.length) { *err = @"请输入地址"; return NO; }
    BOOL isTLS = NO;
    NSString *low = s.lowercaseString;
    if ([low hasPrefix:@"https://"])      { isTLS = YES; s = [s substringFromIndex:8]; }
    else if ([low hasPrefix:@"http://"])  { s = [s substringFromIndex:7]; }
    else if ([low hasPrefix:@"tls://"])    { isTLS = YES; s = [s substringFromIndex:6]; }

    NSRange fr = [s rangeOfString:@"#"];
    if (fr.location != NSNotFound) s = [s substringToIndex:fr.location];
    if (!s.length) { *err = @"地址不完整"; return NO; }

    NSString *path = @"/";
    NSRange slash = [s rangeOfString:@"/"];
    if (slash.location != NSNotFound) {
        path = [s substringFromIndex:slash.location];
        s = [s substringToIndex:slash.location];
    }
    NSString *host = s;
    int port = isTLS ? 443 : 80;
    NSRange colon = [s rangeOfString:@":" options:NSBackwardsSearch];
    if (colon.location != NSNotFound) {
        host = [s substringToIndex:colon.location];
        int v = [[s substringFromIndex:colon.location + 1] intValue];
        if (v > 0 && v < 65536) port = v;
    }
    if (!host.length) { *err = @"缺少主机名"; return NO; }
    out->host = host;
    out->port = port;
    out->path = path.length ? path : @"/";
    out->isTLS = isTLS;
    return YES;
}

// ---------------------------------------------------------------- HTTP 工具

/// 从 HTTP 头里取 Content-Length；没有该头返回 -1
static long IPATContentLength(NSString *head) {
    if (!head.length) return -1;
    for (NSString *line in [head componentsSeparatedByString:@"\r\n"]) {
        NSString *t = [line stringByTrimmingCharactersInSet:
                       [NSCharacterSet whitespaceAndNewlineCharacterSet]];
        if ([t.lowercaseString hasPrefix:@"content-length:"]) {
            NSString *v = [[t substringFromIndex:15] stringByTrimmingCharactersInSet:
                           [NSCharacterSet whitespaceAndNewlineCharacterSet]];
            return (long)v.integerValue;
        }
    }
    return -1;
}

/// 响应体解码：先 UTF-8，再 GB18030（国内内网页面常见），最后 Latin-1 兜底
static NSString *IPATDecode(NSData *d) {
    NSString *s = [[NSString alloc] initWithData:d encoding:NSUTF8StringEncoding];
    if (!s) s = [[NSString alloc] initWithData:d encoding:NSGB18030StringEncoding];
    if (!s) s = [[NSString alloc] initWithData:d encoding:NSISOLatin1StringEncoding];
    return s ?: @"";
}

/// HTML → 纯文本（抽标题 + 去标签），只看得到文字，别被样式表淹没
static NSString *IPATHtmlToText(NSString *html, NSString **outTitle) {
    if (outTitle) *outTitle = @"";
    if (!html.length) return @"";
    NSMutableString *t = [html mutableCopy];

    // title
    NSRange tl = [t rangeOfString:@"<title" options:NSCaseInsensitiveSearch];
    if (tl.location != NSNotFound) {
        NSRange gt = [t rangeOfString:@">" options:0 range:NSMakeRange(tl.location, MIN(200, t.length - tl.location))];
        if (gt.location != NSNotFound) {
            NSRange end = [t rangeOfString:@"</title>" options:NSCaseInsensitiveSearch
                              range:NSMakeRange(gt.location + 1, t.length - gt.location - 1)];
            if (end.location != NSNotFound) {
                NSString *ti = [t substringWithRange:NSMakeRange(gt.location + 1,
                                 end.location - gt.location - 1)];
                if (outTitle) *outTitle = [ti stringByTrimmingCharactersInSet:
                    [NSCharacterSet whitespaceAndNewlineCharacterSet]];
            }
        }
    }

    // 去掉 script / style 整段
    static NSArray *drops = nil;
    if (!drops) drops = @[@"script", @"style"];
    for (NSString *tag in drops) {
        NSString *open = [NSString stringWithFormat:@"<%@", tag];
        NSString *close = [NSString stringWithFormat:@"</%@>", tag];
        while (YES) {
            NSRange a = [t rangeOfString:open options:NSCaseInsensitiveSearch];
            if (a.location == NSNotFound) break;
            NSRange b = [t rangeOfString:close options:NSCaseInsensitiveSearch
                              range:NSMakeRange(a.location, t.length - a.location)];
            if (b.location == NSNotFound) break;
            [t replaceCharactersInRange:NSMakeRange(a.location, b.location + b.length - a.location)
                             withString:@" "];
        }
    }

    // 块级标签 → 换行
    NSArray *blocks = @[@"<br", @"</p", @"</div", @"</tr", @"</li", @"</h1", @"</h2",
                        @"</h3", @"</h4", @"</table", @"<hr"];
    for (NSString *b in blocks) {
        while (YES) {
            NSRange r = [t rangeOfString:b options:NSCaseInsensitiveSearch];
            if (r.location == NSNotFound) break;
            [t replaceCharactersInRange:r withString:@"\n"];
        }
    }
    // 去所有标签
    while (YES) {
        NSRange a = [t rangeOfString:@"<"];
        if (a.location == NSNotFound) break;
        NSRange b = [t rangeOfString:@">" options:0 range:NSMakeRange(a.location, t.length - a.location)];
        if (b.location == NSNotFound) break;
        [t replaceCharactersInRange:NSMakeRange(a.location, b.location + 1 - a.location) withString:@" "];
    }
    // 常见实体
    NSArray *ents = @[@"&nbsp;", @"&amp;", @"&lt;", @"&gt;", @"&quot;", @"&#39;", @"&apos;"];
    NSArray *reps = @[@" ", @"&", @"<", @">", @"\"", @"'", @"'"];
    for (NSUInteger i = 0; i < ents.count; i++) {
        [t replaceOccurrencesOfString:ents[i] withString:reps[i]
                               options:NSCaseInsensitiveSearch range:NSMakeRange(0, t.length)
                                 range:NULL];
    }
    // 折叠空白：连续空格压成一个，行首尾去掉，空行压成一行
    NSArray *lines = [t componentsSeparatedByString:@"\n"];
    NSMutableString *out = [NSMutableString string];
    BOOL lastBlank = YES;
    for (NSString *ln in lines) {
        NSString *s = [ln stringByTrimmingCharactersInSet:
                       [NSCharacterSet whitespaceAndNewlineCharacterSet]];
        if (!s.length) {
            if (lastBlank) continue;
            lastBlank = YES;
            [out appendString:@"\n"];
            continue;
        }
        lastBlank = NO;
        [out appendFormat:@"%@\n", s];
    }
    if (out.length > 8000) {
        [out appendString:@"\n…（正文已截断，完整内容见「复制结果」）"];
    }
    return out;
}

// ---------------------------------------------------------------- 裸 socket 请求

typedef struct {
    BOOL ok;
    NSString *status;      // 状态行
    NSString *headers;     // 响应头
    NSString *body;        // 正文（HTML 已转纯文本）
    NSString *raw;         // 原始响应
    NSString *errText;
    NSString *note;        // 补充说明（如 TLS 探测结论）
    NSTimeInterval ms;
    unsigned long long bytes;
} IPATFetch;

/// 连目标（connect 会被劫持进隧道）；返回 fd 或 -1
static int IPATConnect(const char *host, int port, NSString **err) {
    struct addrinfo hints, *res = NULL;
    memset(&hints, 0, sizeof hints);
    hints.ai_family = AF_INET;              // 只走 IPv4：IPv6 不进隧道
    hints.ai_socktype = SOCK_STREAM;
    char portStr[8];
    snprintf(portStr, sizeof portStr, "%d", port);
    int rc = getaddrinfo(host, portStr, &hints, &res);
    if (rc != 0 || !res) {
        *err = [NSString stringWithFormat:@"域名解析失败：%s",
                gai_strerror(rc)];
        return -1;
    }
    int fd = socket(AF_INET, SOCK_STREAM, 0);
    if (fd < 0) {
        *err = @"socket 创建失败";
        freeaddrinfo(res);
        return -1;
    }
    struct timeval tv = {8, 0};
    setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof tv);
    setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, sizeof tv);
    // 关键：这一行会被 AnyVpn.dylib 的 fishhook 劫持 → 127.0.0.1 中继 → CSTP 隧道
    if (connect(fd, res->ai_addr, (socklen_t)res->ai_addrlen) != 0) {
        *err = [NSString stringWithFormat:@"连接失败：%s（errno %d）", strerror(errno), errno];
        freeaddrinfo(res);
        close(fd);
        return -1;
    }
    freeaddrinfo(res);
    return fd;
}

/// 明文 HTTP GET（按 Content-Length 收满，收不到就靠超时收尾）
static NSString *IPATHttpGet(int fd, NSString *host, NSString *path, unsigned long long *bytes) {
    NSMutableString *req = [NSMutableString string];
    [req appendFormat:@"GET %@ HTTP/1.1\r\n", path];
    [req appendFormat:@"Host: %@\r\n", host];
    [req appendString:@"User-Agent: IPATDemoBrowser/1.0\r\n"];
    [req appendString:@"Accept: text/html,text/plain,*/*\r\n"];
    [req appendString:@"Accept-Encoding: identity\r\n"];
    [req appendString:@"Connection: close\r\n\r\n"];

    const char *raw = req.UTF8String;
    size_t len = strlen(raw), sent = 0;
    while (sent < len) {
        ssize_t n = send(fd, raw + sent, len - sent, 0);
        if (n <= 0) return nil;
        sent += (size_t)n;
    }

    NSMutableData *buf = [NSMutableData data];
    uint8_t tmp[4096];
    size_t want = 0;
    BOOL headDone = NO;
    while (YES) {
        ssize_t n = recv(fd, tmp, sizeof tmp, 0);
        if (n <= 0) break;                       // 超时或对端关闭
        [buf appendBytes:tmp length:(NSUInteger)n];
        if (!headDone) {
            NSString *s = [[NSString alloc] initWithData:buf encoding:NSISOLatin1StringEncoding];
            NSRange sep = [s rangeOfString:@"\r\n\r\n"];
            if (sep.location != NSNotFound) {
                headDone = YES;
                long cl = IPATContentLength([s substringToIndex:sep.location]);
                if (cl == 0) break;               // 明确没有正文
                if (cl > 0) want = sep.location + 4 + (size_t)cl;
            }
        } else if (want && buf.length >= want) {
            break;
        }
        if (buf.length > 512 * 1024) break;      // 兜底
    }
    *bytes = (unsigned long long)buf.length;
    return [[NSString alloc] initWithData:buf encoding:NSISOLatin1StringEncoding];
}

/// 最小 TLS 1.2 ClientHello（带 SNI）：只验证「隧道把包送到了 443 且对端在回 TLS」
static NSString *IPATTlsProbe(int fd, NSString *host, unsigned long long *bytes) {
    NSMutableData *ext = [NSMutableData data];
    NSData *hostData = [host dataUsingEncoding:NSASCIIStringEncoding];
    uint8_t sni[5] = {0};
    sni[0] = 0;                                  // type = host_name
    uint16_t hlen = (uint16_t)hostData.length;
    sni[1] = (uint8_t)(hlen >> 8); sni[2] = (uint8_t)(hlen & 0xFF);
    [ext appendBytes:hostData length:hostData.length];
    NSMutableData *sniExt = [NSMutableData data];
    uint16_t sniLen = (uint16_t)(hostData.length + 3);
    uint8_t sniLenBytes[2] = {(uint8_t)(sniLen >> 8), (uint8_t)(sniLen & 0xFF)};
    [sniExt appendBytes:sniLenBytes length:2];
    [sniExt appendBytes:sni bytes:4];
    [sniExt appendBytes:hostData length:hostData.length];
    uint8_t extHdr[4] = {0x00, 0x00, 0, 0};
    extHdr[2] = (uint8_t)(sniExt.length >> 8);
    extHdr[3] = (uint8_t)(sniExt.length & 0xFF);
    [ext appendBytes:extHdr length:4];
    [ext appendData:sniExt];

    NSMutableData *hs = [NSMutableData data];
    uint8_t ver[2] = {0x03, 0x03};
    [hs appendBytes:ver length:2];
    uint8_t rnd[32];
    arc4random_buf(rnd, sizeof rnd);
    [hs appendBytes:rnd length:32];
    uint8_t sid = 0;
    [hs appendBytes:&sid length:1];              // session_id 长度
    uint8_t csLen[2] = {0x00, 0x08};
    [hs appendBytes:csLen length:2];
    uint8_t ciphers[8] = {0xC0, 0x2F, 0xC0, 0x30, 0x00, 0x9C, 0x00, 0x9D};
    [hs appendBytes:ciphers length:8];
    uint8_t comp[2] = {0x01, 0x00};
    [hs appendBytes:comp length:2];
    uint8_t extLen[2] = {(uint8_t)(ext.length >> 8), (uint8_t)(ext.length & 0xFF)};
    [hs appendBytes:extLen length:2];
    [hs appendData:ext];

    NSMutableData *rec = [NSMutableData data];
    uint8_t recHdr[5] = {0x16, 0x03, 0x01,
                          (uint8_t)((hs.length + 4) >> 8),
                          (uint8_t)((hs.length + 4) & 0xFF)};
    [rec appendBytes:recHdr length:5];
    uint8_t hsHdr[4] = {0x01, (uint8_t)(hs.length >> 16),
                         (uint8_t)((hs.length >> 8) & 0xFF), (uint8_t)(hs.length & 0xFF)};
    [rec appendBytes:hsHdr length:4];
    [rec appendData:hs];

    const uint8_t *p = rec.bytes;
    size_t left = rec.length, done = 0;
    while (done < left) {
        ssize_t n = send(fd, p + done, left - done, 0);
        if (n <= 0) return nil;
        done += (size_t)n;
    }

    uint8_t head[5];
    ssize_t got = recv(fd, head, sizeof head, 0);
    *bytes = (unsigned long long)(got > 0 ? got : 0);
    if (got <= 0) return nil;
    if (head[0] == 0x16) {
        return [NSString stringWithFormat:
                @"服务端回了 TLS 握手记录（类型 0x%02x，版本 0x%02x%02x）→ "
                @"隧道已把包送到 %@:443，且对端在正常应答",
                head[0], head[1], head[2], host];
    }
    if (head[0] == 0x15) {
        return [NSString stringWithFormat:
                @"服务端回了 TLS Alert（类型 0x15）→ 端口 %@:443 可达，"
                @"但握手被拒（可能需要客户端证书或协议版本不匹配）", host];
    }
    if (head[0] == 0x00) {
        return @"服务端直接回了 ChangeCipherSpec（异常）";
    }
    return [NSString stringWithFormat:@"收到非预期首字节 0x%02x", head[0]];
}

/// 完整取一次资源
static void IPATFetchURL(const IPATURL *u, IPATFetch *out) {
    memset(out, 0, sizeof *out);
    NSString *err = nil;
    NSTimeInterval t0 = [NSDate timeIntervalSinceReferenceDate];
    int fd = IPATConnect(u.host.UTF8String, u.port, &err);
    if (fd < 0) {
        out->errText = err ?: @"连接失败";
        out->ms = ([NSDate timeIntervalSinceReferenceDate] - t0) * 1000.0;
        return;
    }
    unsigned long long bytes = 0;
    if (u->isTLS) {
        NSString *note = IPATTlsProbe(fd, u.host, &bytes);
        out->ok = (note.length > 0);
        out->note = note;
        out->bytes = bytes;
        out->status = note.length ? @"TLS 握手探测" : nil;
        close(fd);
        out->ms = ([NSDate timeIntervalSinceReferenceDate] - t0) * 1000.0;
        if (!out->ok) out->errText = @"TLS 探测失败（隧道没把包送到对端？）";
        return;
    }

    NSString *resp = IPATHttpGet(fd, u.host, u.path, &bytes);
    close(fd);
    out->ms = ([NSDate timeIntervalSinceReferenceDate] - t0) * 1000.0;
    out->bytes = bytes;
    if (!resp.length) {
        out->errText = @"没收到任何响应（超时或对端直接断开）";
        return;
    }
    out->raw = resp;
    NSRange sep = [resp rangeOfString:@"\r\n\r\n"];
    NSString *head = (sep.location != NSNotFound) ? [resp substringToIndex:sep.location] : resp;
    NSString *bodyRaw = (sep.location != NSNotFound)
        ? [resp substringFromIndex:sep.location + 4] : @"";
    out->status = ([head componentsSeparatedByString:@"\r\n"]).firstObject ?: @"";
    out->headers = head;
    NSString *decoded = IPATDecode([bodyRaw dataUsingEncoding:NSISOLatin1StringEncoding]);
    NSString *ctype = @"";
    for (NSString *line in [head componentsSeparatedByString:@"\r\n"]) {
        if ([line.lowercaseString hasPrefix:@"content-type:"]) {
            ctype = [line substringFromIndex:13];
            break;
        }
    }
    if ([ctype.lowercaseString containsString:@"html"] || [decoded containsString:@"<html"]) {
        NSString *title = @"";
        NSString *text = IPATHtmlToText(decoded, &title);
        out->body = title.length ? [NSString stringWithFormat:@"[标题] %@\n\n%@", title, text]
                                 : text;
    } else {
        out->body = decoded;
    }
    out->ok = YES;
}

// ---------------------------------------------------------------- 界面

@interface IPATBrowserVC () <UITextFieldDelegate>
@property (nonatomic, strong) UITextField *urlField;
@property (nonatomic, strong) UITextView *outView;
@property (nonatomic, strong) UILabel *tipLabel;
@property (nonatomic, assign) BOOL busy;
@end

@implementation IPATBrowserVC

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"内网浏览器";
    if (@available(iOS 13.0, *)) {
        self.view.backgroundColor = [UIColor systemBackgroundColor];
    } else {
        self.view.backgroundColor = [UIColor whiteColor];
    }

    self.urlField = [[UITextField alloc] init];
    self.urlField.borderStyle = UITextBorderStyleRoundedRect;
    self.urlField.placeholder = @"http://192.168.1.10/ 或 http://内网域名/";
    self.urlField.font = [UIFont systemFontOfSize:14.0];
    self.urlField.autocapitalizationType = UITextAutocapitalizationTypeNone;
    self.urlField.autocorrectionType = UITextAutocorrectionTypeNo;
    self.urlField.keyboardType = UIKeyboardTypeURL;
    self.urlField.returnKeyType = UIReturnKeyGo;
    self.urlField.delegate = self;
    self.urlField.text = @"http://192.168.123.1/";
    self.urlField.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:self.urlField];

    UIButton *go = [UIButton buttonWithType:UIButtonTypeSystem];
    [go setTitle:@"打开" forState:UIControlStateNormal];
    go.titleLabel.font = [UIFont systemFontOfSize:15.0];
    [go addTarget:self action:@selector(onOpen) forControlEvents:UIControlEventTouchUpInside];
    go.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:go];

    self.tipLabel = [[UILabel alloc] init];
    self.tipLabel.numberOfLines = 0;
    self.tipLabel.font = [UIFont systemFontOfSize:11.0];
    self.tipLabel.textColor = [UIColor grayColor];
    self.tipLabel.text = @"裸 socket 请求 → 会被 AnyVpn 劫持进 CSTP 隧道（与游戏同一条通道）。\n"
                         "WKWebView/NSURLSession 走系统网络栈，劫持不到，别用它们判断。\n"
                         @"线路 DNS 不通时直接填 IP:端口；https:// 只做 TLS 握手探测（不解密）。";
    self.tipLabel.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:self.tipLabel];

    self.outView = [[UITextView alloc] init];
    self.outView.editable = NO;
    self.outView.font = [UIFont fontWithName:@"Menlo" size:11.0] ?: [UIFont systemFontOfSize:12.0];
    self.outView.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:self.outView];

    UIButton *cmp = [UIButton buttonWithType:UIButtonTypeSystem];
    [cmp setTitle:@"对照(系统栈)" forState:UIControlStateNormal];
    [cmp addTarget:self action:@selector(onCompare) forControlEvents:UIControlEventTouchUpInside];

    UIButton *cp = [UIButton buttonWithType:UIButtonTypeSystem];
    [cp setTitle:@"复制结果" forState:UIControlStateNormal];
    [cp addTarget:self action:@selector(onCopy) forControlEvents:UIControlEventTouchUpInside];

    UIStackView *bar = [[UIStackView alloc] initWithArrangedSubviews:@[cmp, cp]];
    bar.axis = UILayoutConstraintAxisHorizontal;
    bar.distribution = UIStackViewDistributionFillEqually;
    bar.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:bar];

    UILayoutGuide *safe = self.view.safeAreaLayoutGuide;
    [NSLayoutConstraint activateConstraints:@[
        [self.urlField.topAnchor constraintEqualToAnchor:safe.topAnchor constant:8.0],
        [self.urlField.leadingAnchor constraintEqualToAnchor:safe.leadingAnchor constant:8.0],
        [go.topAnchor constraintEqualToAnchor:self.urlField.topAnchor constant:0.0],
        [go.leadingAnchor constraintEqualToAnchor:self.urlField.trailingAnchor constant:6.0],
        [go.trailingAnchor constraintEqualToAnchor:safe.trailingAnchor constant:-8.0],
        [go.widthAnchor constraintEqualToConstant:56.0],
        [go.heightAnchor constraintEqualToAnchor:self.urlField.heightAnchor],

        [self.tipLabel.topAnchor constraintEqualToAnchor:self.urlField.bottomAnchor constant:8.0],
        [self.tipLabel.leadingAnchor constraintEqualToAnchor:safe.leadingAnchor constant:10.0],
        [self.tipLabel.trailingAnchor constraintEqualToAnchor:safe.trailingAnchor constant:-10.0],

        [self.outView.topAnchor constraintEqualToAnchor:self.tipLabel.bottomAnchor constant:8.0],
        [self.outView.leadingAnchor constraintEqualToAnchor:safe.leadingAnchor constant:8.0],
        [self.outView.trailingAnchor constraintEqualToAnchor:safe.trailingAnchor constant:-8.0],
        [self.outView.bottomAnchor constraintEqualToAnchor:bar.topAnchor constant:-8.0],

        [bar.leadingAnchor constraintEqualToAnchor:safe.leadingAnchor constant:8.0],
        [bar.trailingAnchor constraintEqualToAnchor:safe.trailingAnchor constant:-8.0],
        [bar.bottomAnchor constraintEqualToAnchor:safe.bottomAnchor constant:-8.0],
        [bar.heightAnchor constraintEqualToConstant:40.0],
    ]];

    self.outView.text = @"输入内网地址后点「打开」。\n\n"
                        @"怎么判断隧道生效：\n"
                        @"· 裸 socket 能拿到内网页面 → 隧道在跑流量（连接被劫持进了隧道）\n"
                        @"· 「对照(系统栈)」同时请求 → 走物理网络，内网多半打不开\n"
                        @"两者差异 = 隧道确实把流量带进了内网。";
}

- (BOOL)textFieldShouldReturn:(UITextField *)tf {
    [self onOpen];
    return YES;
}

- (void)onOpen {
    if (self.busy) return;
    IPATURL u;
    NSString *err = nil;
    if (!IPATParseURL(self.urlField.text, &u, &err)) {
        [self show:err];
        return;
    }
    self.busy = YES;
    [self show:[NSString stringWithFormat:@"正在请求 %@:%d …", u.host, u.port]];
    __weak typeof(self) w = self;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        IPATFetch r;
        IPATFetchURL(&u, &r);
        NSMutableString *s = [NSMutableString string];
        [s appendFormat:@"目标      : %@:%d%@\n", u.host, u.port,
            u.isTLS ? @"（TLS 探测）" : @""];
        [s appendFormat:@"耗时      : %.0f ms   收到 %llu 字节\n", r.ms, r.bytes];
        if (!r.ok) {
            [s appendFormat:@"结果      : ❌ %@\n", r.errText ?: @"失败"];
        } else if (u.isTLS) {
            [s appendFormat:@"结果      : ✅ %@\n", r.note ?: @"TLS 端点可达"];
        } else {
            [s appendFormat:@"状态      : %@\n", r.status ?: @"?"];
            [s appendFormat:@"响应头    :\n%@\n\n", r.headers ?: @""];
            [s appendString:@"正文      :\n"];
            [s appendString:r.body.length ? r.body : @"(空)"];
        }
        dispatch_async(dispatch_get_main_queue(), ^{
            typeof(self) s2 = w;
            s2.busy = NO;
            [s2 show:s];
        });
    });
}

- (void)onCompare {
    NSString *text = [self.urlField.text stringByTrimmingCharactersInSet:
                      [NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (!text.length) return;
    if (![text.lowercaseString hasPrefix:@"http"]) text = [@"http://" stringByAppendingString:text];
    NSURL *url = [NSURL URLWithString:text];
    if (!url) {
        [self show:@"地址无法解析"];
        return;
    }
    [self show:@"系统栈（NSURLSession）请求中 …\n"
                  @"注意：这条路径在系统库里建连，劫持不到，走的是物理网络。"];
    NSURLSessionConfiguration *cfg = [NSURLSessionConfiguration ephemeralSessionConfiguration];
    cfg.timeoutIntervalForRequest = 8.0;
    NSURLSession *sess = [NSURLSession sessionWithConfiguration:cfg];
    __weak typeof(self) w = self;
    [[sess dataTaskWithURL:url completionHandler:^(NSData *data, NSURLResponse *resp, NSError *err) {
        NSMutableString *t = [NSMutableString string];
        [t appendFormat:@"系统栈（NSURLSession，劫持不到 → 物理网络）\n"];
        [t appendFormat:@"地址      : %@\n", url.absoluteString];
        if (err) {
            [t appendFormat:@"结果      : ❌ %@\n", err.localizedDescription];
        } else {
            NSHTTPURLResponse *hr = [resp isKindOfClass:[NSHTTPURLResponse class]]
                ? (NSHTTPURLResponse *)resp : nil;
            [t appendFormat:@"状态      : %ld %@\n", (long)hr.statusCode,
                hr.allHeaderFields[@"Content-Type"] ?: @""];
            [t appendFormat:@"正文长度  : %lu 字节\n", (unsigned long)data.length];
            NSString *txt = IPATDecode(data);
            [t appendFormat:@"正文开头  : %@\n",
                txt.length > 400 ? [[txt substringToIndex:400] stringByReplacingOccurrencesOfString:@"\n"
                                                                                     withString:@" "] : txt];
        }
        dispatch_async(dispatch_get_main_queue(), ^{
            typeof(self) s2 = w;
            [s2 show:t];
        });
    }] resume];
}

- (void)onCopy {
    UIPasteboard.generalPasteboard.string = self.outView.text ?: @"";
    [self show:[NSString stringWithFormat:@"已复制 %lu 字节",
                 (unsigned long)self.outView.text.length]];
}

- (void)show:(NSString *)text {
    self.outView.text = text ?: @"";
}

@end

#pragma clang diagnostic pop

