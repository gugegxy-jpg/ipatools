//
//  QNet.m
//  ipatool 注入用 dylib：应用内弱网测试（限速 / 延迟 / 抖动 / 丢包）。
//
//  设计要点：
//    1. 只对当前 App 生效：dylib 注入在游戏进程里，改的是这个进程自己的 socket 读写
//       （send / sendto / recv / recvfrom / read / write），系统设置、Wi-Fi、
//       其它 App 的网络完全不受影响，也不用装描述文件 / VPN / 代理。
//    2. 拦截方式用 dyld 的 __DATA,__interpose（系统自带的符号插入，不需要第三方库）：
//       我们只替换 libc 的 socket 读写函数。原函数一律用 syscall() 直接调内核，
//       不走 libc 符号，所以不会递归回自己的实现。
//    3. 四类参数，全部可以在游戏里的弹窗中实时调：
//         下行带宽 / 上行带宽（KB/s，0 = 不限，令牌桶限速）
//         延迟（ms，单向附加延迟）+ 抖动（ms，在延迟上随机 ±抖动）
//         丢包（%，上行直接丢弃不算发送；下行丢弃后继续等下一个包）
//       参数在弹窗里直接输数字（超过上限会自动夹回来）；常用的组合可以存成预设，
//       预设列表同一时刻只启用一条——启用另一条会先把当前这条关掉。
//       手动改参数 / 手动关开关，都会把「启用中的预设」清掉，免得状态和参数对不上。
//       上行延迟是「异步晚一点再发」：不阻塞游戏线程，免得游戏掉帧。
//       下行延迟阻塞在网络线程上（本来就是等数据的线程），这才是弱网该有的体感。
//    4. 只对 socket 生效：read / write 也会被拦，但先用 getsockopt 判断 fd 是不是
//       socket（结果按 fd 缓存），文件读写直接放行，不会拖慢游戏读资源。
//    5. 实时速率：统计上下行字节数，弹窗里每 0.5 秒刷一次，方便对照限速有没有生效。
//
//  已知边界（说在前面，免得到时候当成 bug）：
//    - 只对「被注入的进程里、跑在 libc 之上的 socket 调用」生效。游戏自己用
//      NSURLSession / 引擎自带网络库的，最终一般都会走到 send/recv；个别引擎
//      用 sendmsg / recvmsg 的直接调用不受影响。
//    - 符号插入对「已经绑定过的调用」不追溯：第一次调用时才生效，
//      所以启动瞬间建立的连接可能不受限，之后新建的连接一定生效。
//    - 丢包会让游戏自己的重传/超时逻辑跑起来，这正是弱网测试要看的东西。
//
//  Info.plist（ipatool --qnet 会自动写入 IPAToolQNet）：
//    Enabled(bool)    默认 NO；YES 表示启动就按下面的参数模拟弱网
//    DownKbps(int)    下行带宽，KB/s，0 = 不限
//    UpKbps(int)      上行带宽，KB/s，0 = 不限
//    DelayMs(int)     单向附加延迟，ms
//    JitterMs(int)    抖动，ms（延迟随机 ±该值）
//    LossPct(int)     丢包率，0-100
//

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#include <dispatch/dispatch.h>
#include <errno.h>
#include <math.h>
#include <pthread.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/syscall.h>
#include <sys/types.h>
#include <sys/uio.h>
#include <time.h>
#include <unistd.h>
#import <QuartzCore/QuartzCore.h>
#import "IPATControlShared.h"

// 老 SDK 里不一定有这些编号，缺了就按 Darwin 的通用值补上
#ifndef SYS_read
#define SYS_read 3
#endif
#ifndef SYS_write
#define SYS_write 4
#endif
#ifndef SYS_close
#define SYS_close 6
#endif
#ifndef SYS_sendto
#define SYS_sendto 133
#endif
#ifndef SYS_recvfrom
#define SYS_recvfrom 134
#endif

#define IPATQnLog(fmt, ...) do { \
    NSString *__ipat_line = [NSString stringWithFormat:(fmt), ##__VA_ARGS__]; \
    NSLog(@"[ipatool-qnet] %@", __ipat_line); \
    IPATAppendLogLine(__ipat_line); \
} while (0)

#pragma mark - 面板动作与本地存储

static NSString *const IPATQnActionSettings = @"qnet.settings";

#pragma mark - 弱网引擎（纯 C，hook 里不跑 ObjC 消息）

#define IPAT_QN_FD_MAX 4096

typedef struct {
    int enabled;
    int downKbps;
    int upKbps;
    int delayMs;
    int jitterMs;
    int lossPct;
} IPATQnConfig;

typedef struct {
    double rate;        // 字节/秒，0 = 不限
    double tokens;      // 令牌桶里剩余的字节
    double capacity;    // 桶容量（允许的突发）
    uint64_t lastUs;    // 上次结算时间
} IPATQnBucket;

static pthread_mutex_t gQnLock = PTHREAD_MUTEX_INITIALIZER;
static IPATQnConfig gQnConfig;
static IPATQnBucket gQnDown;
static IPATQnBucket gQnUp;
static uint64_t gQnDownBytes = 0;
static uint64_t gQnUpBytes = 0;
// 诊断用：到底有没有拦到调用（hook 有没有生效，一眼就能看出来）
static uint64_t gQnHookCalls = 0;    // 进 hook 的总次数（含文件读写）
static uint64_t gQnSockCalls = 0;    // 其中确实是 socket 的次数
static uint64_t gQnDropped = 0;      // 被丢掉的包数
// 0 = 还没自检，1 = 符号插入生效，-1 = 没生效（弱网一定不起作用）
static int gQnHookVerified = 0;
// 0 = 还没问过内核，1 = 是 socket，2 = 不是 socket（文件 / pipe 之类）
static int8_t gQnFdKind[IPAT_QN_FD_MAX];

/// 上行延迟发送用的串行队列：保证延迟发出去的包顺序不乱
static dispatch_queue_t IPATQnUpQueue(void) {
    static dispatch_queue_t queue;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        queue = dispatch_queue_create("ipat.qnet.uplink", DISPATCH_QUEUE_SERIAL);
    });
    return queue;
}

static uint64_t IPATQnNowUs(void) {
    struct timespec ts;
    if (clock_gettime(CLOCK_MONOTONIC, &ts) != 0) return 0;
    return (uint64_t)ts.tv_sec * 1000000ull + (uint64_t)(ts.tv_nsec / 1000);
}

static void IPATQnSleepUs(uint64_t us) {
    if (us == 0) return;
    if (us > 3000000ull) us = 3000000ull;   // 一次最多等 3 秒，别把线程彻底卡死
    struct timespec req;
    req.tv_sec = (time_t)(us / 1000000ull);
    req.tv_nsec = (long)((us % 1000000ull) * 1000);
    struct timespec remain;
    while (nanosleep(&req, &remain) == -1 && errno == EINTR) {
        req = remain;
    }
}

static BOOL IPATQnHitLoss(int lossPct) {
    if (lossPct <= 0) return NO;
    if (lossPct >= 100) return YES;
    return arc4random_uniform(100) < (uint32_t)lossPct;
}

/// 这一趟的延迟：基准延迟 + 随机抖动（±jitter）
static uint64_t IPATQnDelayUs(int delayMs, int jitterMs) {
    if (delayMs <= 0 && jitterMs <= 0) return 0;
    int jitter = 0;
    if (jitterMs > 0) {
        uint32_t span = (uint32_t)jitterMs * 2u + 1u;
        jitter = (int)arc4random_uniform(span) - jitterMs;
    }
    int total = delayMs + jitter;
    if (total < 0) total = 0;
    if (total > 60000) total = 60000;
    return (uint64_t)total * 1000ull;
}

/// 这个 fd 是不是 socket（结果缓存下来，read/write 就不会每次都去问内核）
static BOOL IPATQnIsSocketFd(int fd) {
    if (fd < 0 || fd >= IPAT_QN_FD_MAX) return NO;
    pthread_mutex_lock(&gQnLock);
    int8_t kind = gQnFdKind[fd];
    pthread_mutex_unlock(&gQnLock);
    if (kind != 0) return kind == 1;

    int result = 2;
    int type = 0;
    socklen_t len = sizeof(type);
    if (getsockopt(fd, SOL_SOCKET, SO_TYPE, &type, &len) == 0) result = 1;
    pthread_mutex_lock(&gQnLock);
    gQnFdKind[fd] = (int8_t)result;
    pthread_mutex_unlock(&gQnLock);
    return result == 1;
}

/// 原函数：直接进内核，不经过 libc 的符号（否则会绕回我们的实现）
static ssize_t IPATQnRawSend(int fd, const void *buf, size_t nbytes, int flags,
                             const struct sockaddr *addr, socklen_t addrlen) {
    return (ssize_t)syscall(SYS_sendto, fd, buf, nbytes, flags, addr, addrlen);
}

static ssize_t IPATQnRawRecv(int fd, void *buf, size_t nbytes, int flags,
                             struct sockaddr *addr, socklen_t *addrlen) {
    return (ssize_t)syscall(SYS_recvfrom, fd, buf, nbytes, flags, addr, addrlen);
}

static void IPATQnBucketReset(IPATQnBucket *bucket, double bytesPerSec) {
    bucket->rate = bytesPerSec;
    bucket->capacity = bytesPerSec > 0 ? MAX(bytesPerSec * 0.25, 16384.0) : 0.0;
    bucket->tokens = bucket->capacity;
    bucket->lastUs = IPATQnNowUs();
}

/// 令牌桶：不够就睡到够为止。调用前必须持锁，返回时仍持锁（睡觉期间会把锁放开）
static void IPATQnThrottleLocked(IPATQnBucket *bucket, size_t bytes) {
    if (bucket->rate <= 0) return;
    uint64_t now = IPATQnNowUs();
    if (bucket->lastUs > 0 && now > bucket->lastUs) {
        bucket->tokens += (double)(now - bucket->lastUs) / 1000000.0 * bucket->rate;
        if (bucket->tokens > bucket->capacity) bucket->tokens = bucket->capacity;
    }
    bucket->lastUs = now;
    if (bucket->tokens >= (double)bytes) {
        bucket->tokens -= (double)bytes;
        return;
    }
    double need = (double)bytes - bucket->tokens;
    double waitUs = need / bucket->rate * 1000000.0;
    bucket->tokens = 0.0;
    pthread_mutex_unlock(&gQnLock);
    IPATQnSleepUs((uint64_t)waitUs);
    pthread_mutex_lock(&gQnLock);
    bucket->lastUs = IPATQnNowUs();
}

#pragma mark - 配置（面板改过的值优先于 Info.plist）

static NSDictionary *IPATQnPlistConfig(void) {
    static NSDictionary *cfg;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        id value = [[NSBundle mainBundle] objectForInfoDictionaryKey:@"IPAToolQNet"];
        cfg = [value isKindOfClass:[NSDictionary class]] ? value : @{};
    });
    return cfg;
}

static int IPATQnIntOf(id value) {
    return [value respondsToSelector:@selector(intValue)] ? [value intValue] : 0;
}

static int IPATQnIntSetting(NSString *panelKey, NSString *plistKey, int fallback) {
    id stored = [[NSUserDefaults standardUserDefaults] objectForKey:panelKey];
    id value = stored ?: IPATQnPlistConfig()[plistKey];
    if ([value respondsToSelector:@selector(intValue)]) return [value intValue];
    return fallback;
}

static IPATQnConfig IPATQnReadConfig(void) {
    IPATQnConfig cfg;
    memset(&cfg, 0, sizeof(cfg));

    id stored = [[NSUserDefaults standardUserDefaults] objectForKey:IPATKeyQNetEnabled];
    id enabled = stored ?: IPATQnPlistConfig()[@"Enabled"];
    cfg.enabled = [enabled respondsToSelector:@selector(boolValue)] ? [enabled boolValue] : NO;

    cfg.downKbps = MAX(0, IPATQnIntSetting(IPATKeyQNetDownKbps, @"DownKbps", 0));
    cfg.upKbps = MAX(0, IPATQnIntSetting(IPATKeyQNetUpKbps, @"UpKbps", 0));
    cfg.delayMs = MAX(0, IPATQnIntSetting(IPATKeyQNetDelayMs, @"DelayMs", 0));
    cfg.jitterMs = MAX(0, IPATQnIntSetting(IPATKeyQNetJitterMs, @"JitterMs", 0));
    cfg.lossPct = MIN(100, MAX(0, IPATQnIntSetting(IPATKeyQNetLossPct, @"LossPct", 0)));
    return cfg;
}

/// 重新装载配置并重建令牌桶（开关、改参数、启动时都会调一次）
static void IPATQnReloadConfig(void) {
    IPATQnConfig cfg = IPATQnReadConfig();
    pthread_mutex_lock(&gQnLock);
    gQnConfig = cfg;
    IPATQnBucketReset(&gQnDown, cfg.downKbps > 0 ? (double)cfg.downKbps * 1024.0 : 0.0);
    IPATQnBucketReset(&gQnUp, cfg.upKbps > 0 ? (double)cfg.upKbps * 1024.0 : 0.0);
    pthread_mutex_unlock(&gQnLock);
}

static IPATQnConfig IPATQnSnapshot(void) {
    pthread_mutex_lock(&gQnLock);
    IPATQnConfig cfg = gQnConfig;
    pthread_mutex_unlock(&gQnLock);
    return cfg;
}

static void IPATQnStats(uint64_t *up, uint64_t *down) {
    pthread_mutex_lock(&gQnLock);
    if (up) *up = gQnUpBytes;
    if (down) *down = gQnDownBytes;
    pthread_mutex_unlock(&gQnLock);
}

/// 统计（不管有没有开弱网都记，这样弹窗里能一直看到真实速率）
static void IPATQnAddStats(BOOL uplink, size_t bytes) {
    pthread_mutex_lock(&gQnLock);
    if (uplink) gQnUpBytes += (uint64_t)bytes;
    else gQnDownBytes += (uint64_t)bytes;
    pthread_mutex_unlock(&gQnLock);
}

/// 记一次「hook 被调用了」——弹窗里靠它判断符号插入到底有没有生效
static void IPATQnNoteCall(BOOL isSocket) {
    pthread_mutex_lock(&gQnLock);
    gQnHookCalls++;
    if (isSocket) gQnSockCalls++;
    pthread_mutex_unlock(&gQnLock);
}

static void IPATQnNoteDrop(void) {
    pthread_mutex_lock(&gQnLock);
    gQnDropped++;
    pthread_mutex_unlock(&gQnLock);
}

static void IPATQnHookStats(uint64_t *calls, uint64_t *sockCalls, uint64_t *dropped) {
    pthread_mutex_lock(&gQnLock);
    if (calls) *calls = gQnHookCalls;
    if (sockCalls) *sockCalls = gQnSockCalls;
    if (dropped) *dropped = gQnDropped;
    pthread_mutex_unlock(&gQnLock);
}

static int IPATQnHookState(void) {
    pthread_mutex_lock(&gQnLock);
    int state = gQnHookVerified;
    pthread_mutex_unlock(&gQnLock);
    return state;
}

#pragma mark - 拦截实现

/// 上行：限速（阻塞调用线程）+ 丢包 + 延迟异步发送
static ssize_t IPATQnSendHook(int fd, const void *buf, size_t nbytes, int flags,
                              const struct sockaddr *addr, socklen_t addrlen) {
    BOOL isSocket = IPATQnIsSocketFd(fd);
    IPATQnNoteCall(isSocket);
    if (nbytes == 0 || !isSocket) return IPATQnRawSend(fd, buf, nbytes, flags, addr, addrlen);

    IPATQnConfig cfg = IPATQnSnapshot();
    IPATQnAddStats(YES, nbytes);

    if (!cfg.enabled) return IPATQnRawSend(fd, buf, nbytes, flags, addr, addrlen);

    // 丢包：数据不发出去，但对游戏说「发了」，让它的重传逻辑自己跑起来
    if (IPATQnHitLoss(cfg.lossPct)) {
        IPATQnNoteDrop();
        return (ssize_t)nbytes;
    }

    if (cfg.upKbps > 0) {
        pthread_mutex_lock(&gQnLock);
        IPATQnThrottleLocked(&gQnUp, nbytes);
        pthread_mutex_unlock(&gQnLock);
    }

    uint64_t delayUs = IPATQnDelayUs(cfg.delayMs, cfg.jitterMs);
    if (delayUs > 0 && nbytes <= 1024 * 1024) {
        void *copy = malloc(nbytes);
        if (copy) {
            memcpy(copy, buf, nbytes);
            // 调用方给的 sockaddr 可能在栈上，异步之前必须自己留一份
            struct sockaddr_storage remote;
            memset(&remote, 0, sizeof(remote));
            socklen_t remoteLen = 0;
            if (addr && addrlen > 0) {
                remoteLen = MIN(addrlen, (socklen_t)sizeof(remote));
                memcpy(&remote, addr, (size_t)remoteLen);
            }
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)delayUs * 1000),
                           IPATQnUpQueue(), ^{
                // remote 是 block 捕获的副本，这里取它的地址是安全的
                const struct sockaddr *dest = remoteLen > 0 ? (const struct sockaddr *)&remote : NULL;
                IPATQnRawSend(fd, copy, nbytes, flags, dest, remoteLen);
                free(copy);
            });
            return (ssize_t)nbytes;
        }
    }
    if (delayUs > 0) IPATQnSleepUs(delayUs);   // 超大块数据不复制，只能同步等
    return IPATQnRawSend(fd, buf, nbytes, flags, addr, addrlen);
}

/// 下行：限速 + 延迟（阻塞在等数据的线程上）+ 丢包（丢掉这段，继续等下一个包）
static ssize_t IPATQnRecvHook(int fd, void *buf, size_t nbytes, int flags,
                              struct sockaddr *addr, socklen_t *addrlen) {
    BOOL isSocket = IPATQnIsSocketFd(fd);
    IPATQnNoteCall(isSocket);
    if (!isSocket) return IPATQnRawRecv(fd, buf, nbytes, flags, addr, addrlen);

    IPATQnConfig cfg = IPATQnSnapshot();
    if (!cfg.enabled) {
        ssize_t got = IPATQnRawRecv(fd, buf, nbytes, flags, addr, addrlen);
        if (got > 0) IPATQnAddStats(NO, (size_t)got);
        return got;
    }

    uint64_t delayUs = IPATQnDelayUs(cfg.delayMs, cfg.jitterMs);
    ssize_t result = 0;
    // 丢包最多连丢 3 次：一直丢下去会把线程卡死，看起来像游戏断线
    for (int attempt = 0; attempt < 4; attempt++) {
        ssize_t got = IPATQnRawRecv(fd, buf, nbytes, flags, addr, addrlen);
        if (got <= 0) return got;   // 出错 / 断开 / 非阻塞没数据，原样交回去
        result = got;
        IPATQnAddStats(NO, (size_t)got);

        if (cfg.downKbps > 0) {
            pthread_mutex_lock(&gQnLock);
            IPATQnThrottleLocked(&gQnDown, (size_t)got);
            pthread_mutex_unlock(&gQnLock);
        }
        if (delayUs > 0) IPATQnSleepUs(delayUs);
        if (!IPATQnHitLoss(cfg.lossPct)) return got;
        IPATQnNoteDrop();   // 这一段丢了，继续收下一个
    }
    return result;
}

static ssize_t ipat_qn_send(int fd, const void *buf, size_t nbytes, int flags) {
    return IPATQnSendHook(fd, buf, nbytes, flags, NULL, 0);
}

static ssize_t ipat_qn_sendto(int fd, const void *buf, size_t nbytes, int flags,
                              const struct sockaddr *addr, socklen_t addrlen) {
    return IPATQnSendHook(fd, buf, nbytes, flags, addr, addrlen);
}

static ssize_t ipat_qn_recv(int fd, void *buf, size_t nbytes, int flags) {
    return IPATQnRecvHook(fd, buf, nbytes, flags, NULL, NULL);
}

static ssize_t ipat_qn_recvfrom(int fd, void *buf, size_t nbytes, int flags,
                                struct sockaddr *addr, socklen_t *addrlen) {
    return IPATQnRecvHook(fd, buf, nbytes, flags, addr, addrlen);
}

static ssize_t ipat_qn_read(int fd, void *buf, size_t nbytes) {
    if (!IPATQnIsSocketFd(fd)) return (ssize_t)syscall(SYS_read, fd, buf, nbytes);
    return IPATQnRecvHook(fd, buf, nbytes, 0, NULL, NULL);
}

static ssize_t ipat_qn_write(int fd, const void *buf, size_t nbytes) {
    if (!IPATQnIsSocketFd(fd)) return (ssize_t)syscall(SYS_write, fd, buf, nbytes);
    return IPATQnSendHook(fd, buf, nbytes, 0, NULL, 0);
}

/// 不少网络库（尤其引擎自带的那套）走的是 sendmsg / writev，不是 send，
/// 只插 send/recv 就会「参数调了但完全没感觉」。这几个入口一并补上。
/// 保守的地方：带控制消息、一次收多段的，一律交回原函数——宁可不限速，
/// 也不能为了限速把数据弄丢。
static ssize_t ipat_qn_sendmsg(int fd, const struct msghdr *msg, int flags) {
    if (!msg || !msg->msg_iov || msg->msg_iovlen <= 0 || msg->msg_control) {
        return sendmsg(fd, msg, flags);
    }
    BOOL isSocket = IPATQnIsSocketFd(fd);
    IPATQnNoteCall(isSocket);
    if (!isSocket) return sendmsg(fd, msg, flags);

    size_t total = 0;
    for (int i = 0; i < msg->msg_iovlen; i++) total += msg->msg_iov[i].iov_len;
    void *buf = total > 0 ? malloc(total) : NULL;
    if (!buf) return sendmsg(fd, msg, flags);
    size_t off = 0;
    for (int i = 0; i < msg->msg_iovlen; i++) {
        if (msg->msg_iov[i].iov_len > 0 && msg->msg_iov[i].iov_base) {
            memcpy((char *)buf + off, msg->msg_iov[i].iov_base, msg->msg_iov[i].iov_len);
            off += msg->msg_iov[i].iov_len;
        }
    }
    // sendmsg / recvmsg / writev / readv 我们不插桩，所以这里直接调 libc 就是原函数
    ssize_t sent = IPATQnSendHook(fd, buf, total, flags,
                                  (const struct sockaddr *)msg->msg_name, msg->msg_namelen);
    free(buf);
    return sent;
}

static ssize_t ipat_qn_recvmsg(int fd, struct msghdr *msg, int flags) {
    if (!msg || !msg->msg_iov || msg->msg_iovlen != 1) return recvmsg(fd, msg, flags);
    BOOL isSocket = IPATQnIsSocketFd(fd);
    IPATQnNoteCall(isSocket);
    if (!isSocket) return recvmsg(fd, msg, flags);

    struct iovec *iov = msg->msg_iov;
    ssize_t got = IPATQnRecvHook(fd, iov[0].iov_base, iov[0].iov_len, flags,
                                 (struct sockaddr *)msg->msg_name, &msg->msg_namelen);
    if (got < 0) return got;
    iov[0].iov_len = (size_t)got;
    msg->msg_controllen = 0;   // 控制消息没处理，如实说 0，别让调用方读到脏数据
    msg->msg_flags = 0;
    return got;
}

static ssize_t ipat_qn_writev(int fd, const struct iovec *iov, int iovcnt) {
    if (!iov || iovcnt <= 0) return writev(fd, iov, iovcnt);
    BOOL isSocket = IPATQnIsSocketFd(fd);
    IPATQnNoteCall(isSocket);
    if (!isSocket) return writev(fd, iov, iovcnt);

    size_t total = 0;
    for (int i = 0; i < iovcnt; i++) total += iov[i].iov_len;
    void *buf = total > 0 ? malloc(total) : NULL;
    if (!buf) return writev(fd, iov, iovcnt);
    size_t off = 0;
    for (int i = 0; i < iovcnt; i++) {
        if (iov[i].iov_len > 0 && iov[i].iov_base) {
            memcpy((char *)buf + off, iov[i].iov_base, iov[i].iov_len);
            off += iov[i].iov_len;
        }
    }
    ssize_t sent = IPATQnSendHook(fd, buf, total, 0, NULL, 0);
    free(buf);
    return sent;
}

static ssize_t ipat_qn_readv(int fd, const struct iovec *iov, int iovcnt) {
    if (!iov || iovcnt != 1 || !iov[0].iov_base) return readv(fd, iov, iovcnt);
    BOOL isSocket = IPATQnIsSocketFd(fd);
    IPATQnNoteCall(isSocket);
    if (!isSocket) return readv(fd, iov, iovcnt);
    return IPATQnRecvHook(fd, iov[0].iov_base, iov[0].iov_len, 0, NULL, NULL);
}

static int ipat_qn_close(int fd) {
    // fd 会被复用，不清理的话下一个文件可能顶着「socket」的旧结论走限速
    if (fd >= 0 && fd < IPAT_QN_FD_MAX) {
        pthread_mutex_lock(&gQnLock);
        gQnFdKind[fd] = 0;
        pthread_mutex_unlock(&gQnLock);
    }
    return (int)syscall(SYS_close, fd);
}

/// dyld 的符号插入：{新函数, 被替换的函数}。系统自带的机制，不需要 fishhook
#define IPAT_QN_INTERPOSE(replacement, target) \
    __attribute__((used, section("__DATA,__interpose"))) \
    static struct { const void *replacement; const void *replacee; } \
    _ipat_qn_interpose_##target = { (const void *)&replacement, (const void *)&target };

IPAT_QN_INTERPOSE(ipat_qn_send, send)
IPAT_QN_INTERPOSE(ipat_qn_sendto, sendto)
IPAT_QN_INTERPOSE(ipat_qn_recv, recv)
IPAT_QN_INTERPOSE(ipat_qn_recvfrom, recvfrom)
IPAT_QN_INTERPOSE(ipat_qn_read, read)
IPAT_QN_INTERPOSE(ipat_qn_write, write)
IPAT_QN_INTERPOSE(ipat_qn_close, close)

#pragma mark - 参数定义

typedef NS_ENUM(NSInteger, IPATQnParam) {
    IPATQnParamDown = 0,
    IPATQnParamUp,
    IPATQnParamDelay,
    IPATQnParamJitter,
    IPATQnParamLoss,
    IPATQnParamCount,
};

static NSString *IPATQnParamUserKey(IPATQnParam param) {
    switch (param) {
        case IPATQnParamDown:   return IPATKeyQNetDownKbps;
        case IPATQnParamUp:     return IPATKeyQNetUpKbps;
        case IPATQnParamDelay:  return IPATKeyQNetDelayMs;
        case IPATQnParamJitter: return IPATKeyQNetJitterMs;
        case IPATQnParamLoss:   return IPATKeyQNetLossPct;
        default:                return @"";
    }
}

static NSString *IPATQnParamTitle(IPATQnParam param) {
    switch (param) {
        case IPATQnParamDown:   return @"下行带宽";
        case IPATQnParamUp:     return @"上行带宽";
        case IPATQnParamDelay:  return @"延迟";
        case IPATQnParamJitter: return @"抖动";
        case IPATQnParamLoss:   return @"丢包率";
        default:                return @"";
    }
}

static int IPATQnParamMax(IPATQnParam param) {
    switch (param) {
        case IPATQnParamDown:   return 2000;   // KB/s
        case IPATQnParamUp:     return 2000;
        case IPATQnParamDelay:  return 2000;   // ms
        case IPATQnParamJitter: return 500;    // ms
        case IPATQnParamLoss:   return 100;    // %
        default:                return 100;
    }
}

/// 输入框后面的单位提示
static NSString *IPATQnParamUnit(IPATQnParam param) {
    switch (param) {
        case IPATQnParamDown:
        case IPATQnParamUp:     return @"KB/s";
        case IPATQnParamDelay:
        case IPATQnParamJitter: return @"ms";
        case IPATQnParamLoss:   return @"%";
        default:                return @"";
    }
}

static NSString *IPATQnParamText(IPATQnParam param, int value) {
    switch (param) {
        case IPATQnParamDown:
        case IPATQnParamUp:
            return value <= 0 ? @"不限" : [NSString stringWithFormat:@"%d KB/s", value];
        case IPATQnParamDelay:
        case IPATQnParamJitter:
            return [NSString stringWithFormat:@"%d ms", value];
        case IPATQnParamLoss:
            return [NSString stringWithFormat:@"%d%%", value];
        default:
            return @"";
    }
}

static int IPATQnParamValue(IPATQnParam param) {
    IPATQnConfig cfg = IPATQnSnapshot();
    switch (param) {
        case IPATQnParamDown:   return cfg.downKbps;
        case IPATQnParamUp:     return cfg.upKbps;
        case IPATQnParamDelay:  return cfg.delayMs;
        case IPATQnParamJitter: return cfg.jitterMs;
        case IPATQnParamLoss:   return cfg.lossPct;
        default:                return 0;
    }
}

#pragma mark - 预设

@interface IPATQnPresetItem : NSObject

@property (nonatomic, copy) NSString *presetId;
@property (nonatomic, copy) NSString *name;
@property (nonatomic, assign) int downKbps;
@property (nonatomic, assign) int upKbps;
@property (nonatomic, assign) int delayMs;
@property (nonatomic, assign) int jitterMs;
@property (nonatomic, assign) int lossPct;

@end

@implementation IPATQnPresetItem

- (instancetype)initWithDictionary:(NSDictionary *)dict {
    if ((self = [super init])) {
        self.presetId = [dict[@"id"] isKindOfClass:[NSString class]] ? dict[@"id"] : @"";
        self.name = [dict[@"name"] isKindOfClass:[NSString class]] ? dict[@"name"] : @"未命名";
        self.downKbps = IPATQnIntOf(dict[@"down"]);
        self.upKbps = IPATQnIntOf(dict[@"up"]);
        self.delayMs = IPATQnIntOf(dict[@"delay"]);
        self.jitterMs = IPATQnIntOf(dict[@"jitter"]);
        self.lossPct = MIN(100, MAX(0, IPATQnIntOf(dict[@"loss"])));
        if (self.presetId.length == 0) self.presetId = [[NSUUID UUID] UUIDString];
    }
    return self;
}

- (NSDictionary *)dictionaryValue {
    return @{@"id": self.presetId ?: @"",
             @"name": self.name ?: @"",
             @"down": @(self.downKbps),
             @"up": @(self.upKbps),
             @"delay": @(self.delayMs),
             @"jitter": @(self.jitterMs),
             @"loss": @(self.lossPct)};
}

@end

static IPATQnPresetItem *IPATQnMakePreset(NSString *presetId, NSString *name,
                                          int down, int up, int delay, int jitter, int loss) {
    IPATQnPresetItem *item = [[IPATQnPresetItem alloc] init];
    item.presetId = presetId.length > 0 ? presetId : [[NSUUID UUID] UUIDString];
    item.name = name.length > 0 ? name : @"未命名";
    item.downKbps = MAX(0, down);
    item.upKbps = MAX(0, up);
    item.delayMs = MAX(0, delay);
    item.jitterMs = MAX(0, jitter);
    item.lossPct = MIN(100, MAX(0, loss));
    return item;
}

/// 第一次用时给的内置预设，之后就都按用户自己存的列表走
static NSArray<IPATQnPresetItem *> *IPATQnBuiltinPresets(void) {
    //                                 id                   名称        下行 上行 延迟  抖动 丢包
    return @[
        IPATQnMakePreset(@"builtin.normal",  @"正常网络",  0,   0,   0,    0,   0),
        IPATQnMakePreset(@"builtin.3g",      @"3G",       300, 150, 150,  40,  2),
        IPATQnMakePreset(@"builtin.2g",      @"2G",       50,  30,  500,  120, 8),
        IPATQnMakePreset(@"builtin.bad",     @"极差网络",  20,  10,  1000, 300, 25),
        IPATQnMakePreset(@"builtin.offline", @"断网",      0,   0,   0,    0,   100),
    ];
}

static void IPATQnSavePresets(NSArray<IPATQnPresetItem *> *presets) {
    NSMutableArray *stored = [NSMutableArray array];
    for (IPATQnPresetItem *item in presets) [stored addObject:[item dictionaryValue]];
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    [defaults setObject:stored forKey:IPATKeyQNetPresets];
    [defaults synchronize];
}

static NSArray<IPATQnPresetItem *> *IPATQnLoadPresets(void) {
    id stored = [[NSUserDefaults standardUserDefaults] objectForKey:IPATKeyQNetPresets];
    if ([stored isKindOfClass:[NSArray class]]) {
        NSMutableArray *items = [NSMutableArray array];
        for (id entry in (NSArray *)stored) {
            if (![entry isKindOfClass:[NSDictionary class]]) continue;
            [items addObject:[[IPATQnPresetItem alloc] initWithDictionary:entry]];
        }
        if (items.count > 0) return items;
    }
    NSArray<IPATQnPresetItem *> *builtin = IPATQnBuiltinPresets();
    IPATQnSavePresets(builtin);
    return builtin;
}

static NSString *IPATQnActivePresetId(void) {
    id value = [[NSUserDefaults standardUserDefaults] objectForKey:IPATKeyQNetActivePreset];
    return [value isKindOfClass:[NSString class]] ? value : @"";
}

static void IPATQnSetActivePresetId(NSString *presetId) {
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    [defaults setObject:presetId ?: @"" forKey:IPATKeyQNetActivePreset];
    [defaults synchronize];
}

static IPATQnPresetItem *IPATQnActivePreset(void) {
    NSString *active = IPATQnActivePresetId();
    if (active.length == 0) return nil;
    for (IPATQnPresetItem *item in IPATQnLoadPresets()) {
        if ([item.presetId isEqualToString:active]) return item;
    }
    return nil;
}

/// 启用一条预设。同一时刻只会有一条生效：
/// 已经有启用中的那一条时，先把它关掉（弱网停用 + 清掉启用标记），再启用新的这条。
static void IPATQnEnablePreset(IPATQnPresetItem *item) {
    if (!item) return;
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    NSString *active = IPATQnActivePresetId();
    if (active.length > 0 && ![active isEqualToString:item.presetId]) {
        IPATQnLog(@"关掉当前预设，改启用「%@」", item.name);
        [defaults setBool:NO forKey:IPATKeyQNetEnabled];
        IPATQnSetActivePresetId(@"");
        IPATQnReloadConfig();
    }
    [defaults setInteger:item.downKbps forKey:IPATKeyQNetDownKbps];
    [defaults setInteger:item.upKbps forKey:IPATKeyQNetUpKbps];
    [defaults setInteger:item.delayMs forKey:IPATKeyQNetDelayMs];
    [defaults setInteger:item.jitterMs forKey:IPATKeyQNetJitterMs];
    [defaults setInteger:item.lossPct forKey:IPATKeyQNetLossPct];
    [defaults setBool:YES forKey:IPATKeyQNetEnabled];
    IPATQnSetActivePresetId(item.presetId);
    [defaults synchronize];
    IPATQnReloadConfig();
    IPATQnLog(@"已启用预设「%@」：下行 %@ / 上行 %@ / 延迟 %d±%d ms / 丢包 %d%%",
              item.name,
              IPATQnParamText(IPATQnParamDown, item.downKbps),
              IPATQnParamText(IPATQnParamUp, item.upKbps),
              item.delayMs, item.jitterMs, item.lossPct);
}

/// 关掉当前启用的那条预设：弱网一起停用，启用标记清空
static void IPATQnDisableActivePreset(void) {
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    [defaults setBool:NO forKey:IPATKeyQNetEnabled];
    IPATQnSetActivePresetId(@"");
    [defaults synchronize];
    IPATQnReloadConfig();
}

static NSString *IPATQnPresetSummary(IPATQnPresetItem *item) {
    return [NSString stringWithFormat:@"↓%@ ↑%@ · %@±%@ · 丢%@",
            IPATQnParamText(IPATQnParamDown, item.downKbps),
            IPATQnParamText(IPATQnParamUp, item.upKbps),
            IPATQnParamText(IPATQnParamDelay, item.delayMs),
            IPATQnParamText(IPATQnParamJitter, item.jitterMs),
            IPATQnParamText(IPATQnParamLoss, item.lossPct)];
}

#pragma mark - 参数弹窗（可拖动 / 右上角关闭 / 点空白处不关闭）

@interface IPATQnCard : UIView <UITextFieldDelegate>

@property (nonatomic, strong) UISwitch *enableSwitch;
@property (nonatomic, strong) NSMutableArray<UITextField *> *fields;      // 五个参数直接输数字
@property (nonatomic, strong) NSMutableArray<UILabel *> *unitLabels;      // 输入框右边的单位
@property (nonatomic, strong) UILabel *rateLabel;
@property (nonatomic, strong) UILabel *hookLabel;         // 拦截诊断：到底拦没拦到
@property (nonatomic, strong) UIView *presetSection;      // 预设列表（增删后整段重建）
@property (nonatomic, strong) UILabel *noteLabel;         // 最下面那行说明，跟着预设列表走
@property (nonatomic, strong) UITextField *presetNameField;
@property (nonatomic, strong) UIView *headerView;          // 标题栏，拖动窗口的地方
@property (nonatomic, strong) UIScrollView *scrollView;   // 横屏高度不够时内容可以滚
@property (nonatomic, assign) CGFloat contentHeight;
@property (nonatomic, copy) void (^onClose)(void);
@property (nonatomic, copy) void (^onChanged)(void);
@property (nonatomic, copy) void (^onResize)(void);        // 内容变高了，让外面重新排版

@end

@implementation IPATQnCard

- (instancetype)initWithFrame:(CGRect)frame {
    if ((self = [super initWithFrame:frame])) {
        self.backgroundColor = [[UIColor blackColor] colorWithAlphaComponent:0.88];
        self.layer.cornerRadius = 12.0;
        self.layer.masksToBounds = YES;
        self.layer.borderWidth = 1.0;
        self.layer.borderColor = [[UIColor colorWithWhite:1.0 alpha:0.15] CGColor];
        self.fields = [NSMutableArray array];
        self.unitLabels = [NSMutableArray array];
        UIScrollView *scroll = [[UIScrollView alloc]
            initWithFrame:CGRectMake(0, 46.0, frame.size.width, MAX(0.0, frame.size.height - 46.0))];
        scroll.backgroundColor = [UIColor clearColor];
        scroll.showsVerticalScrollIndicator = YES;
        [self addSubview:scroll];
        self.scrollView = scroll;
        [self buildViews];
        [self refreshValues];
    }
    return self;
}

- (void)buildViews {
    CGFloat width = self.bounds.size.width;
    CGFloat margin = 14.0;
    CGFloat rowWidth = width - margin * 2;

    // 标题栏：就是拖窗口的地方
    UIView *header = [[UIView alloc] initWithFrame:CGRectMake(0, 0, width, 46.0)];
    header.backgroundColor = [[UIColor whiteColor] colorWithAlphaComponent:0.08];
    [self addSubview:header];
    self.headerView = header;

    UILabel *title = [[UILabel alloc] initWithFrame:CGRectMake(margin, 5.0, width - 70.0, 21.0)];
    title.text = @"弱网测试 QNet";
    title.textColor = [UIColor whiteColor];
    title.font = [UIFont boldSystemFontOfSize:15.0];
    [header addSubview:title];

    UILabel *subtitle = [[UILabel alloc] initWithFrame:CGRectMake(margin, 26.0, width - 70.0, 15.0)];
    subtitle.text = @"拖动这里移动窗口";
    subtitle.textColor = [UIColor colorWithWhite:1.0 alpha:0.55];
    subtitle.font = [UIFont systemFontOfSize:11.0];
    [header addSubview:subtitle];

    UIButton *close = [UIButton buttonWithType:UIButtonTypeSystem];
    close.frame = CGRectMake(width - 44.0, 6.0, 38.0, 34.0);
    [close setTitle:@"✕" forState:UIControlStateNormal];
    [close setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
    close.titleLabel.font = [UIFont systemFontOfSize:17.0];
    [close addTarget:self action:@selector(handleClose) forControlEvents:UIControlEventTouchUpInside];
    [header addSubview:close];

    CGFloat y = 8.0;   // 下面这些都在 scrollView 里，从顶部留点空隙开始

    UILabel *switchTitle = [[UILabel alloc] initWithFrame:CGRectMake(margin, y, 120.0, 30.0)];
    switchTitle.text = @"启用弱网";
    switchTitle.textColor = [UIColor whiteColor];
    switchTitle.font = [UIFont systemFontOfSize:14.0];
    [self.scrollView addSubview:switchTitle];

    UISwitch *toggle = [[UISwitch alloc] initWithFrame:CGRectMake(width - margin - 51.0, y, 51.0, 30.0)];
    if ([toggle respondsToSelector:@selector(setOnTintColor:)] &&
        [UIColor respondsToSelector:@selector(systemGreenColor)]) {
        toggle.onTintColor = [UIColor systemGreenColor];
    }
    [toggle addTarget:self action:@selector(handleToggle:) forControlEvents:UIControlEventValueChanged];
    [self.scrollView addSubview:toggle];
    self.enableSwitch = toggle;
    y += 38.0;

    for (NSInteger i = 0; i < IPATQnParamCount; i++) {
        IPATQnParam param = (IPATQnParam)i;

        UILabel *name = [[UILabel alloc] initWithFrame:CGRectMake(margin, y + 5.0, 70.0, 20.0)];
        name.text = IPATQnParamTitle(param);
        name.textColor = [UIColor colorWithWhite:1.0 alpha:0.9];
        name.font = [UIFont systemFontOfSize:13.0];
        [self.scrollView addSubview:name];

        UITextField *field =
            [[UITextField alloc] initWithFrame:CGRectMake(margin + 74.0, y, rowWidth - 74.0 - 44.0, 30.0)];
        field.borderStyle = UITextBorderStyleRoundedRect;
        field.keyboardType = UIKeyboardTypeNumberPad;
        field.textAlignment = NSTextAlignmentRight;
        field.textColor = [UIColor greenColor];
        field.font = [UIFont systemFontOfSize:13.0];
        field.backgroundColor = [[UIColor whiteColor] colorWithAlphaComponent:0.14];
        field.clearButtonMode = UITextFieldViewModeWhileEditing;
        field.returnKeyType = UIReturnKeyDone;
        field.tag = i;
        field.delegate = self;
        field.inputAccessoryView = [self ipatDoneToolbar];
        [field addTarget:self
                  action:@selector(handleParamChanged:)
        forControlEvents:UIControlEventEditingDidEnd];
        [self.scrollView addSubview:field];
        [self.fields addObject:field];

        UILabel *unit = [[UILabel alloc] initWithFrame:CGRectMake(width - margin - 40.0, y + 5.0, 40.0, 20.0)];
        unit.text = IPATQnParamUnit(param);
        unit.textColor = [UIColor colorWithWhite:1.0 alpha:0.7];
        unit.font = [UIFont systemFontOfSize:12.0];
        [self.scrollView addSubview:unit];
        [self.unitLabels addObject:unit];
        y += 36.0;
    }

    UILabel *rate = [[UILabel alloc] initWithFrame:CGRectMake(margin, y, rowWidth, 20.0)];
    rate.text = @"实时 ↑ 0 KB/s  ↓ 0 KB/s";
    rate.textColor = [UIColor colorWithWhite:1.0 alpha:0.75];
    rate.font = [UIFont systemFontOfSize:12.0];
    [self.scrollView addSubview:rate];
    self.rateLabel = rate;
    y += 22.0;

    // 拦截诊断：看这一行就知道弱网为什么没反应
    UILabel *hookInfo = [[UILabel alloc] initWithFrame:CGRectMake(margin, y, rowWidth, 30.0)];
    hookInfo.text = @"";
    hookInfo.textColor = [UIColor colorWithWhite:1.0 alpha:0.55];
    hookInfo.font = [UIFont systemFontOfSize:10.0];
    hookInfo.numberOfLines = 2;
    [self.scrollView addSubview:hookInfo];
    self.hookLabel = hookInfo;
    y += 34.0;

    // 预设列表放在最后：条目增减时整段重建，后面的说明跟着往下挪
    UIView *section = [[UIView alloc] initWithFrame:CGRectMake(margin, y, rowWidth, 80.0)];
    section.backgroundColor = [UIColor clearColor];
    [self.scrollView addSubview:section];
    self.presetSection = section;

    UILabel *note = [[UILabel alloc] initWithFrame:CGRectMake(margin, y, rowWidth, 32.0)];
    note.text = @"只对当前 App 生效，不动系统设置，也不影响其它 App";
    note.textColor = [UIColor colorWithWhite:1.0 alpha:0.5];
    note.font = [UIFont systemFontOfSize:11.0];
    note.numberOfLines = 2;
    [self.scrollView addSubview:note];
    self.noteLabel = note;

    [self rebuildPresetSection];   // 会把说明行的位置和卡片高度一起算好
}

- (void)layoutSubviews {
    [super layoutSubviews];
    CGFloat headerHeight = 46.0;
    self.scrollView.frame = CGRectMake(0, headerHeight, self.bounds.size.width,
                                       MAX(0.0, self.bounds.size.height - headerHeight));
}

/// 内容完整展开需要的高度；外面按这个值决定卡片实际高度，高度不够就靠滚动
- (CGFloat)preferredHeight {
    return 46.0 + MAX(self.contentHeight, 120.0);
}

#pragma mark 输入框

/// 数字键盘没有回车键，给个「完成」把键盘收掉（收掉时参数就顺带写进去了）
- (UIToolbar *)ipatDoneToolbar {
    UIToolbar *bar = [[UIToolbar alloc] initWithFrame:CGRectMake(0, 0, self.bounds.size.width, 36.0)];
    bar.barStyle = UIBarStyleBlack;
    bar.translucent = YES;
    UIBarButtonItem *space =
        [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemFlexibleSpace
                                                     target:nil
                                                     action:nil];
    UIBarButtonItem *done =
        [[UIBarButtonItem alloc] initWithTitle:@"完成"
                                         style:UIBarButtonItemStyleDone
                                        target:self
                                        action:@selector(handleInputDone)];
    bar.items = @[space, done];
    [bar sizeToFit];
    return bar;
}

- (void)handleInputDone {
    [self endEditing:YES];
}

- (BOOL)textFieldShouldReturn:(UITextField *)textField {
    [textField resignFirstResponder];
    return YES;
}

- (void)refreshValues {
    IPATQnConfig cfg = IPATQnSnapshot();
    self.enableSwitch.on = cfg.enabled ? YES : NO;
    for (NSInteger i = 0; i < IPATQnParamCount; i++) {
        IPATQnParam param = (IPATQnParam)i;
        if (i >= (NSInteger)self.fields.count) continue;
        UITextField *field = self.fields[i];
        if (field.isEditing) continue;   // 正在输的数别被覆盖掉
        field.text = [NSString stringWithFormat:@"%d", IPATQnParamValue(param)];
    }
    [self rebuildPresetSection];
    [self updateHookInfo];
}

- (void)handleToggle:(UISwitch *)sender {
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    [defaults setBool:sender.isOn forKey:IPATKeyQNetEnabled];
    // 手动关掉弱网 = 预设也不再算启用中
    if (!sender.isOn) IPATQnSetActivePresetId(@"");
    [defaults synchronize];
    IPATQnReloadConfig();
    IPATQnConfig cfg = IPATQnSnapshot();
    IPATQnLog(@"弱网%@：下行 %@ / 上行 %@ / 延迟 %d±%d ms / 丢包 %d%%",
              cfg.enabled ? @"已开启" : @"已关闭",
              IPATQnParamText(IPATQnParamDown, cfg.downKbps),
              IPATQnParamText(IPATQnParamUp, cfg.upKbps),
              cfg.delayMs, cfg.jitterMs, cfg.lossPct);
    [self rebuildPresetSection];
    if (self.onChanged) self.onChanged();
}

/// 输完一个参数：夹到合法范围里存起来；手动改过之后就不再算某条预设了
- (void)handleParamChanged:(UITextField *)sender {
    IPATQnParam param = (IPATQnParam)sender.tag;
    int max = IPATQnParamMax(param);
    int value = [sender.text intValue];
    if (value < 0) value = 0;
    if (value > max) value = max;
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    [defaults setInteger:value forKey:IPATQnParamUserKey(param)];
    if (IPATQnActivePresetId().length > 0) IPATQnSetActivePresetId(@"");
    [defaults synchronize];
    IPATQnReloadConfig();
    sender.text = [NSString stringWithFormat:@"%d", value];
    [self rebuildPresetSection];
    if (self.onChanged) self.onChanged();
}

#pragma mark 预设列表

/// 预设条目是动态的（可增删），所以整段重建：列表 → 下面那行说明 → 卡片高度
- (void)rebuildPresetSection {
    UIView *section = self.presetSection;
    if (!section) return;
    for (UIView *subview in [section.subviews copy]) [subview removeFromSuperview];

    CGFloat width = section.bounds.size.width;
    CGFloat y = 0.0;

    UILabel *caption = [[UILabel alloc] initWithFrame:CGRectMake(0, y, width, 20.0)];
    caption.text = @"预设（同一时刻只启用一条）";
    caption.textColor = [UIColor whiteColor];
    caption.font = [UIFont boldSystemFontOfSize:13.0];
    [section addSubview:caption];
    y += 24.0;

    NSString *activeId = IPATQnActivePresetId();
    NSArray<IPATQnPresetItem *> *presets = IPATQnLoadPresets();
    for (NSUInteger index = 0; index < presets.count; index++) {
        IPATQnPresetItem *item = presets[index];
        BOOL active = [item.presetId isEqualToString:activeId];

        UIView *row = [[UIView alloc] initWithFrame:CGRectMake(0, y, width, 40.0)];
        row.backgroundColor = active ? [[UIColor greenColor] colorWithAlphaComponent:0.16]
                                     : [[UIColor whiteColor] colorWithAlphaComponent:0.05];
        row.layer.cornerRadius = 6.0;
        [section addSubview:row];

        UILabel *name = [[UILabel alloc] initWithFrame:CGRectMake(8.0, 3.0, width - 108.0, 18.0)];
        name.text = item.name;
        name.textColor = active ? [UIColor greenColor] : [UIColor whiteColor];
        name.font = [UIFont boldSystemFontOfSize:13.0];
        [row addSubview:name];

        UILabel *summary = [[UILabel alloc] initWithFrame:CGRectMake(8.0, 20.0, width - 108.0, 20.0)];
        summary.text = IPATQnPresetSummary(item);
        summary.textColor = [UIColor colorWithWhite:1.0 alpha:0.55];
        summary.font = [UIFont systemFontOfSize:10.0];
        summary.numberOfLines = 2;
        [row addSubview:summary];

        UIButton *remove = [UIButton buttonWithType:UIButtonTypeSystem];
        remove.frame = CGRectMake(width - 96.0, 6.0, 26.0, 28.0);
        [remove setTitle:@"✕" forState:UIControlStateNormal];
        [remove setTitleColor:[UIColor colorWithWhite:1.0 alpha:0.6] forState:UIControlStateNormal];
        remove.titleLabel.font = [UIFont systemFontOfSize:14.0];
        remove.tag = 2000 + (NSInteger)index;
        [remove addTarget:self
                   action:@selector(handlePresetRemove:)
         forControlEvents:UIControlEventTouchUpInside];
        [row addSubview:remove];

        UIButton *toggle = [UIButton buttonWithType:UIButtonTypeSystem];
        toggle.frame = CGRectMake(width - 66.0, 6.0, 62.0, 28.0);
        [toggle setTitle:active ? @"已启用" : @"启用" forState:UIControlStateNormal];
        [toggle setTitleColor:active ? [UIColor orangeColor] : [UIColor greenColor]
                     forState:UIControlStateNormal];
        toggle.titleLabel.font = [UIFont systemFontOfSize:13.0];
        toggle.layer.cornerRadius = 6.0;
        toggle.layer.borderWidth = 1.0;
        toggle.layer.borderColor = active ? [[UIColor orangeColor] CGColor]
                                          : [[UIColor greenColor] CGColor];
        toggle.tag = 1000 + (NSInteger)index;
        [toggle addTarget:self
                   action:@selector(handlePresetToggle:)
         forControlEvents:UIControlEventTouchUpInside];
        [row addSubview:toggle];

        y += 44.0;
    }

    UITextField *nameField =
        [[UITextField alloc] initWithFrame:CGRectMake(0, y + 1.0, width - 92.0, 30.0)];
    nameField.borderStyle = UITextBorderStyleRoundedRect;
    nameField.placeholder = @"预设名称（可留空）";
    nameField.textColor = [UIColor whiteColor];
    nameField.font = [UIFont systemFontOfSize:12.0];
    nameField.backgroundColor = [[UIColor whiteColor] colorWithAlphaComponent:0.14];
    nameField.returnKeyType = UIReturnKeyDone;
    nameField.delegate = self;
    nameField.inputAccessoryView = [self ipatDoneToolbar];
    [section addSubview:nameField];
    self.presetNameField = nameField;

    UIButton *save = [UIButton buttonWithType:UIButtonTypeSystem];
    save.frame = CGRectMake(width - 86.0, y + 1.0, 86.0, 30.0);
    [save setTitle:@"保存当前" forState:UIControlStateNormal];
    [save setTitleColor:[UIColor greenColor] forState:UIControlStateNormal];
    save.titleLabel.font = [UIFont systemFontOfSize:13.0];
    save.layer.cornerRadius = 6.0;
    save.layer.borderWidth = 1.0;
    save.layer.borderColor = [[UIColor greenColor] CGColor];
    [save addTarget:self
             action:@selector(handlePresetSave:)
   forControlEvents:UIControlEventTouchUpInside];
    [section addSubview:save];
    y += 38.0;

    CGRect frame = section.frame;
    frame.size.height = y;
    section.frame = frame;
    [self updateContentLayout];
}

/// 预设区高度变了，后面的说明行往下挪，卡片高度和内容高度一起更新
- (void)updateContentLayout {
    if (!self.presetSection || !self.noteLabel) return;
    CGFloat width = self.bounds.size.width;
    CGRect note = self.noteLabel.frame;
    note.origin.y = CGRectGetMaxY(self.presetSection.frame) + 6.0;
    self.noteLabel.frame = note;

    CGFloat total = CGRectGetMaxY(note) + 8.0;
    self.contentHeight = total;
    self.scrollView.contentSize = CGSizeMake(width, total);
    CGRect frame = self.frame;
    frame.size.height = 46.0 + total;
    self.frame = frame;
    if (self.onResize) self.onResize();
}

- (void)handlePresetToggle:(UIButton *)sender {
    NSArray<IPATQnPresetItem *> *presets = IPATQnLoadPresets();
    NSInteger index = sender.tag - 1000;
    if (index < 0 || index >= (NSInteger)presets.count) return;
    IPATQnPresetItem *item = presets[index];
    if ([item.presetId isEqualToString:IPATQnActivePresetId()]) {
        IPATQnDisableActivePreset();            // 再点一次 = 关掉这一条
        IPATQnLog(@"已关闭预设「%@」", item.name);
    } else {
        IPATQnEnablePreset(item);               // 有别的在启用时，里面会先把那条关掉
    }
    [self finishPresetChange];
}

- (void)handlePresetRemove:(UIButton *)sender {
    NSMutableArray<IPATQnPresetItem *> *presets = [IPATQnLoadPresets() mutableCopy];
    NSInteger index = sender.tag - 2000;
    if (index < 0 || index >= (NSInteger)presets.count) return;
    IPATQnPresetItem *item = presets[index];
    if ([item.presetId isEqualToString:IPATQnActivePresetId()]) IPATQnDisableActivePreset();
    [presets removeObjectAtIndex:(NSUInteger)index];
    IPATQnSavePresets(presets);
    IPATQnLog(@"已删除预设「%@」", item.name);
    [self finishPresetChange];
}

/// 把当前五个参数存成一条新预设
- (void)handlePresetSave:(UIButton *)sender {
    IPATQnConfig cfg = IPATQnSnapshot();
    NSMutableArray<IPATQnPresetItem *> *presets = [IPATQnLoadPresets() mutableCopy];
    NSString *name = [self.presetNameField.text
        stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (name.length == 0) {
        name = [NSString stringWithFormat:@"自定义 %lu", (unsigned long)(presets.count + 1)];
    }
    IPATQnPresetItem *item = IPATQnMakePreset([[NSUUID UUID] UUIDString], name,
                                              cfg.downKbps, cfg.upKbps,
                                              cfg.delayMs, cfg.jitterMs, cfg.lossPct);
    [presets addObject:item];
    IPATQnSavePresets(presets);
    IPATQnLog(@"已把当前参数存为预设「%@」：下行 %@ / 上行 %@ / 延迟 %d±%d ms / 丢包 %d%%",
              name,
              IPATQnParamText(IPATQnParamDown, cfg.downKbps),
              IPATQnParamText(IPATQnParamUp, cfg.upKbps),
              cfg.delayMs, cfg.jitterMs, cfg.lossPct);
    [self.presetNameField resignFirstResponder];
    [self finishPresetChange];
}

- (void)finishPresetChange {
    [self refreshValues];
    if (self.onChanged) self.onChanged();
}

- (void)handleClose {
    if (self.onClose) self.onClose();
}

/// 每 0.5 秒刷一次实时速率（不管开关状态都显示，方便对照限速有没有生效）
- (void)updateRate {
    static uint64_t lastUp = 0;
    static uint64_t lastDown = 0;
    static NSTimeInterval lastTime = 0;

    uint64_t up = 0;
    uint64_t down = 0;
    IPATQnStats(&up, &down);
    NSTimeInterval now = [NSDate timeIntervalSinceReferenceDate];
    if (lastTime > 0) {
        double elapsed = now - lastTime;
        if (elapsed < 0.05) elapsed = 0.05;
        double upRate = (double)(up - lastUp) / elapsed / 1024.0;
        double downRate = (double)(down - lastDown) / elapsed / 1024.0;
        if (upRate < 0) upRate = 0;
        if (downRate < 0) downRate = 0;
        self.rateLabel.text = [NSString stringWithFormat:@"实时 ↑ %.0f KB/s  ↓ %.0f KB/s",
                               upRate, downRate];
    }
    [self updateHookInfo];
    lastUp = up;
    lastDown = down;
    lastTime = now;
}

/// 「到底拦没拦到」——参数不生效时先看这一行：
/// 拦截次数不涨 = 这个 App 的网络没走我们插桩的函数；次数一直涨但速率是 0 = 真的没流量
- (void)updateHookInfo {
    uint64_t calls = 0;
    uint64_t socketCalls = 0;
    uint64_t dropped = 0;
    IPATQnHookStats(&calls, &socketCalls, &dropped);
    if (IPATQnHookState() < 0) {
        self.hookLabel.text = @"注意：符号插入没生效，弱网对当前 App 不起作用";
        self.hookLabel.textColor = [UIColor orangeColor];
        return;
    }
    self.hookLabel.textColor = [UIColor colorWithWhite:1.0 alpha:0.55];
    self.hookLabel.text = [NSString stringWithFormat:@"拦截 %llu 次（网络 %llu 次，丢包 %llu）",
                           calls, socketCalls, dropped];
}

@end

#pragma mark - 弹窗窗口

/// 不抢焦点（游戏不会因为弹窗被暂停），窗口空白区也不吃触摸
@interface IPATQnWindow : UIWindow
@end

@implementation IPATQnWindow

- (BOOL)canBecomeKeyWindow { return NO; }

- (UIView *)hitTest:(CGPoint)point withEvent:(UIEvent *)event {
    UIView *hit = [super hitTest:point withEvent:event];
    return hit == self ? nil : hit;
}

@end

/// 根视图：空白处一律穿透给游戏 —— 所以「点空白处不会关掉弹窗」，
/// 而且游戏原本的按钮照样点得到
@interface IPATQnRootView : UIView
@end

@implementation IPATQnRootView

- (UIView *)hitTest:(CGPoint)point withEvent:(UIEvent *)event {
    UIView *hit = [super hitTest:point withEvent:event];
    return hit == self ? nil : hit;
}

@end

@interface IPATQnRootController : UIViewController
@end

@implementation IPATQnRootController

- (BOOL)shouldAutorotate { return YES; }

- (UIInterfaceOrientationMask)supportedInterfaceOrientations { return IPATAppOrientationMask(); }

@end

#pragma mark - 与悬浮面板对接

@interface IPATQnBridge : NSObject <UIGestureRecognizerDelegate>

@property (nonatomic, strong) UIWindow *settingsWindow;
@property (nonatomic, strong) IPATQnCard *card;
@property (nonatomic, strong) NSTimer *rateTimer;
@property (nonatomic, assign) CGPoint dragStart;
@property (nonatomic, assign) CGRect cardFrame;

@end

@implementation IPATQnBridge

+ (instancetype)shared {
    static IPATQnBridge *shared;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ shared = [[IPATQnBridge alloc] init]; });
    return shared;
}

- (void)start {
    NSNotificationCenter *center = [NSNotificationCenter defaultCenter];
    [center addObserver:self selector:@selector(handlePanelChange:) name:IPATControlDidChangeNotification object:nil];
    [center addObserver:self selector:@selector(handlePanelDiscover:) name:IPATControlDiscoverNotification object:nil];
    [center addObserver:self selector:@selector(handleAction:) name:IPATControlActionNotification object:nil];
    [[UIDevice currentDevice] beginGeneratingDeviceOrientationNotifications];
    [center addObserver:self selector:@selector(handleOrientationChange)
                   name:UIDeviceOrientationDidChangeNotification object:nil];
    [self registerWithPanel];
    IPATQnConfig cfg = IPATQnSnapshot();
    IPATQnLog(@"弱网测试已就绪（启用=%d 下行=%d 上行=%d KB/s 延迟=%d 抖动=%d 丢包=%d%%）",
              cfg.enabled, cfg.downKbps, cfg.upKbps, cfg.delayMs, cfg.jitterMs, cfg.lossPct);
}

- (void)registerWithPanel {
    IPATQnConfig cfg = IPATQnSnapshot();
    NSDictionary *reg = @{
        IPATRegId: IPATFeatureQNet,
        IPATRegTitle: @"弱网测试（QNet）",
        IPATRegDetail: @"限速 / 延迟 / 抖动 / 丢包，只对当前 App 生效",
        IPATRegMasterKey: IPATKeyQNetEnabled,
        IPATRegEnabled: @(cfg.enabled ? YES : NO),
        IPATRegRows: @[
            @{
                IPATRowKey: IPATQnActionSettings,
                IPATRowTitle: @"网络参数设置",
                IPATRowKind: IPATRowKindAction,
                IPATRowNote: [NSString stringWithFormat:@"当前：下行 %@ / 延迟 %d ms / 丢包 %d%%",
                                                        IPATQnParamText(IPATQnParamDown, cfg.downKbps),
                                                        cfg.delayMs, cfg.lossPct],
            },
        ],
    };
    [[NSNotificationCenter defaultCenter] postNotificationName:IPATControlRegisterNotification
                                                        object:nil
                                                      userInfo:reg];
    [self postStatus];
}

- (void)postStatus {
    IPATQnConfig cfg = IPATQnSnapshot();
    IPATQnPresetItem *preset = IPATQnActivePreset();
    NSString *text = cfg.enabled
        ? [NSString stringWithFormat:@"已开启%@：下行 %@ / 上行 %@ / 延迟 %d ms / 丢包 %d%%",
                                     preset ? [NSString stringWithFormat:@"（预设 %@）", preset.name] : @"",
                                     IPATQnParamText(IPATQnParamDown, cfg.downKbps),
                                     IPATQnParamText(IPATQnParamUp, cfg.upKbps),
                                     cfg.delayMs, cfg.lossPct]
        : @"未开启（点「网络参数设置」调好后打开开关）";
    [[NSNotificationCenter defaultCenter] postNotificationName:IPATControlStatusNotification
                                                        object:nil
                                                      userInfo:@{IPATRegId: IPATFeatureQNet,
                                                                 IPATStaDetail: text}];
}

#pragma mark 面板事件

- (void)handlePanelDiscover:(NSNotification *)note {
    [self registerWithPanel];
}

- (void)handlePanelChange:(NSNotification *)note {
    if (![note.userInfo[IPATChgId] isEqualToString:IPATFeatureQNet]) return;
    // 从面板把总开关关掉 = 预设也不再算启用中
    id enabled = note.userInfo[IPATChgEnabled];
    if ([enabled respondsToSelector:@selector(boolValue)]) {
        BOOL on = [enabled boolValue];
        NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
        [defaults setBool:on forKey:IPATKeyQNetEnabled];
        if (!on) IPATQnSetActivePresetId(@"");
        [defaults synchronize];
    }
    IPATQnReloadConfig();
    [self.card refreshValues];
    [self registerWithPanel];
}

- (void)handleAction:(NSNotification *)note {
    if (![note.userInfo[IPATChgId] isEqualToString:IPATFeatureQNet]) return;
    if (![note.userInfo[IPATActKey] isEqualToString:IPATQnActionSettings]) return;
    [self openSettings];
}

#pragma mark 弹窗

- (UIWindow *)makeWindow {
    if (self.settingsWindow) return self.settingsWindow;
    UIWindow *window = nil;
    if (@available(iOS 13.0, *)) {
        UIWindowScene *scene = nil;
        for (UIScene *candidate in [UIApplication sharedApplication].connectedScenes) {
            if (![candidate isKindOfClass:[UIWindowScene class]]) continue;
            UIWindowScene *found = (UIWindowScene *)candidate;
            scene = found;
            if (candidate.activationState == UISceneActivationStateForegroundActive) break;
        }
        if (scene && [UIWindow instancesRespondToSelector:@selector(initWithWindowScene:)]) {
            IPATQnWindow *made = [[IPATQnWindow alloc] initWithWindowScene:scene];
            made.frame = [UIScreen mainScreen].bounds;
            // 比悬浮窗（Alert+100）再高一层，弹窗一定压在悬浮按钮上面
            made.windowLevel = UIWindowLevelAlert + 150;
            made.backgroundColor = [UIColor clearColor];
            made.opaque = NO;
            IPATQnRootController *root = [[IPATQnRootController alloc] init];
            IPATQnRootView *view = [[IPATQnRootView alloc] initWithFrame:made.bounds];
            view.backgroundColor = [UIColor clearColor];
            view.opaque = NO;
            view.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
            root.view = view;
            made.rootViewController = root;
            window = made;
        }
    }
    if (!window) {
        IPATQnLog(@"拿不到 windowScene，弱网设置窗口弹不出来");
        return nil;
    }
    self.settingsWindow = window;
    return window;
}

- (void)openSettings {
    dispatch_async(dispatch_get_main_queue(), ^{
        UIWindow *window = [self makeWindow];
        if (!window) return;
        [self syncWindowGeometry];
        window.hidden = NO;

        if (!self.card) {
            CGFloat width = MIN(340.0, window.bounds.size.width - 32.0);
            IPATQnCard *card = [[IPATQnCard alloc] initWithFrame:CGRectMake(0, 0, width, 480.0)];
            __weak typeof(self) weakSelf = self;
            card.onClose = ^{ [weakSelf closeSettings]; };
            card.onChanged = ^{ [weakSelf registerWithPanel]; };
            // 预设增删后内容变高，让外面按新高度重新排版
            card.onResize = ^{ [weakSelf layoutCard]; };
            // 拖动手势只挂在标题栏上：内容区让给 scrollView 自己滚，互不打架
            UIPanGestureRecognizer *pan =
                [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(handleDrag:)];
            pan.delegate = self;
            [card.headerView addGestureRecognizer:pan];
            [window.rootViewController.view addSubview:card];
            self.card = card;
        }
        [self.card refreshValues];
        [self layoutCard];

        // 弹窗期间把悬浮按钮收起来，关掉再放出来
        [[NSNotificationCenter defaultCenter] postNotificationName:IPATControlVisibilityNotification
                                                            object:nil
                                                          userInfo:@{IPATVisVisible: @NO}];
        if (!self.rateTimer) {
            self.rateTimer = [NSTimer scheduledTimerWithTimeInterval:0.5
                                                              target:self
                                                            selector:@selector(handleRateTick)
                                                            userInfo:nil
                                                             repeats:YES];
        }
        IPATQnLog(@"弱网设置窗口已打开");
    });
}

- (void)closeSettings {
    dispatch_async(dispatch_get_main_queue(), ^{
        [self.rateTimer invalidate];
        self.rateTimer = nil;
        [self saveCardFrame];
        [self.card removeFromSuperview];
        self.card = nil;
        if (self.settingsWindow) {
            NSArray<UIView *> *subs = [self.settingsWindow.rootViewController.view.subviews copy];
            for (UIView *subview in subs) {
                [subview removeFromSuperview];
            }
            self.settingsWindow.hidden = YES;
        }
        [[NSNotificationCenter defaultCenter] postNotificationName:IPATControlVisibilityNotification
                                                            object:nil
                                                          userInfo:@{IPATVisVisible: @YES}];
        [self registerWithPanel];
        IPATQnLog(@"弱网设置窗口已关闭");
    });
}

- (void)handleRateTick {
    [self.card updateRate];
}

/// 拖动窗口：整个卡片都能拖，但滑块 / 开关 / 按钮自己要先处理触摸，别跟拖动抢
- (BOOL)gestureRecognizer:(UIGestureRecognizer *)gestureRecognizer shouldReceiveTouch:(UITouch *)touch {
    for (UIView *candidate = touch.view; candidate; candidate = candidate.superview) {
        if ([candidate isKindOfClass:[UIControl class]]) return NO;
    }
    return YES;
}

- (void)handleDrag:(UIPanGestureRecognizer *)pan {
    UIView *card = self.card;
    UIView *superview = card.superview;
    if (!card || !superview) return;

    if (pan.state == UIGestureRecognizerStateBegan) {
        self.dragStart = card.center;
    }
    CGPoint delta = [pan translationInView:superview];
    CGPoint center = CGPointMake(self.dragStart.x + delta.x, self.dragStart.y + delta.y);
    CGFloat halfWidth = card.bounds.size.width / 2.0;
    CGFloat halfHeight = card.bounds.size.height / 2.0;
    center.x = MIN(MAX(halfWidth + 4.0, center.x), superview.bounds.size.width - halfWidth - 4.0);
    center.y = MIN(MAX(halfHeight + 4.0, center.y), superview.bounds.size.height - halfHeight - 4.0);
    card.center = center;

    if (pan.state == UIGestureRecognizerStateEnded || pan.state == UIGestureRecognizerStateCancelled) {
        self.cardFrame = card.frame;
        [self saveCardFrame];
    }
}

/// 记住拖到哪了：同一局里再打开还在原处
- (void)saveCardFrame {
    if (CGRectIsEmpty(self.cardFrame)) return;
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    [defaults setObject:NSStringFromCGRect(self.cardFrame) forKey:IPATKeyQNetCardFrame];
    [defaults synchronize];
}

- (void)layoutCard {
    UIWindow *window = self.settingsWindow;
    IPATQnCard *card = self.card;
    if (!window || !card) return;

    CGRect bounds = window.bounds;
    CGRect frame = card.frame;
    frame.size.width = MIN(340.0, bounds.size.width - 32.0);
    // 横屏时屏幕高度有限，卡片跟着缩，里面的内容靠 scrollView 滚
    frame.size.height = MIN([card preferredHeight], bounds.size.height - 24.0);

    if (CGRectIsEmpty(self.cardFrame)) {
        NSString *saved = [[NSUserDefaults standardUserDefaults] objectForKey:IPATKeyQNetCardFrame];
        if (saved.length > 0) self.cardFrame = CGRectFromString(saved);
    }
    if (!CGRectIsEmpty(self.cardFrame)) {
        frame.origin = self.cardFrame.origin;
    } else {
        frame.origin.x = (bounds.size.width - frame.size.width) / 2.0;
        frame.origin.y = (bounds.size.height - frame.size.height) / 2.0;
    }
    frame.origin.x = MIN(MAX(8.0, frame.origin.x), bounds.size.width - frame.size.width - 8.0);
    frame.origin.y = MIN(MAX(8.0, frame.origin.y), bounds.size.height - frame.size.height - 8.0);
    card.frame = frame;
    self.cardFrame = frame;
}

- (void)syncWindowGeometry {
    UIWindow *window = self.settingsWindow;
    if (!window) return;
    IPATAlignWindowToInterface(window, IPATAppKeyWindowExcluding(window));
}

- (void)handleOrientationChange {
    if (!self.settingsWindow || self.settingsWindow.isHidden) return;
    dispatch_async(dispatch_get_main_queue(), ^{
        [self syncWindowGeometry];
        [self layoutCard];
    });
}

@end

__attribute__((constructor)) static void IPATQNetInit(void) {
    // 早点把配置装好：网络可能在 UI 起来之前就开始跑了
    IPATQnReloadConfig();
    // 自检：故意拿一个无效 fd 调一次 send，看有没有被自己的 hook 拦到。
    // 拦到了就说明 dyld 的符号插入生效，弱网才真的起作用；拦不到的话，
    // 弹窗里会直接写清楚，免得参数调了半天没反应还不知道为什么。
    uint64_t before = 0;
    uint64_t after = 0;
    IPATQnHookStats(&before, NULL, NULL);
    send(-1, NULL, 0, 0);   // 必然失败（EBADF），只是借它走一遍 hook
    IPATQnHookStats(&after, NULL, NULL);
    pthread_mutex_lock(&gQnLock);
    gQnHookVerified = (after > before) ? 1 : -1;
    pthread_mutex_unlock(&gQnLock);
    IPATQnLog(@"hook 自检：%@（拦截计数 %llu → %llu）",
              after > before ? @"符号插入生效" : @"符号插入没生效，弱网不会起作用",
              before, after);
    dispatch_async(dispatch_get_main_queue(), ^{
        [[IPATQnBridge shared] start];
    });
}
