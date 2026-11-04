#import "TunnelPump.h"

#import <arpa/inet.h>
#import <errno.h>
#import <fcntl.h>
#import <poll.h>
#import <sys/socket.h>
#import <unistd.h>

@implementation TunnelPump {
    NEPacketTunnelFlow *_flow;
    int _fd;
    BOOL _stopping;
    NSLock *_lock;
    dispatch_queue_t _inQueue;
    dispatch_queue_t _outQueue;
    TunnelPumpLogBlock _log;
    unsigned long long _inPackets;
    unsigned long long _outPackets;
}

- (instancetype)initWithFlow:(NEPacketTunnelFlow *)flow fd:(int)fd log:(TunnelPumpLogBlock)log {
    if ((self = [super init])) {
        _flow = flow;
        _fd = fd;
        // 保证非 nil：向 nil block 调用会崩溃，日志块在后台线程里被多处使用
        _log = log ? [log copy] : ^(NSString *line) { (void)line; };
        _lock = [[NSLock alloc] init];
        _inQueue = dispatch_queue_create("com.anyvpn.pump.in", DISPATCH_QUEUE_SERIAL);
        _outQueue = dispatch_queue_create("com.anyvpn.pump.out", DISPATCH_QUEUE_SERIAL);
    }
    return self;
}

- (BOOL)isStopped {
    [_lock lock];
    BOOL s = _stopping;
    [_lock unlock];
    return s;
}

- (int)currentFd {
    [_lock lock];
    int fd = _fd;
    [_lock unlock];
    return fd;
}

- (void)start {
    // 入向用 poll + O_NONBLOCK：stop 时不用靠 close 唤醒阻塞的 read
    // （BSD 上 close 不保证唤醒同 fd 上已阻塞的 read）
    int fd = [self currentFd];
    int flags = fcntl(fd, F_GETFL, 0);
    if (flags >= 0) fcntl(fd, F_SETFL, flags | O_NONBLOCK);

    __weak typeof(self) weakSelf = self;
    dispatch_async(_inQueue, ^{ [weakSelf pumpInbound]; });
    dispatch_async(_outQueue, ^{ [weakSelf pumpOutbound]; });
}

#pragma mark - packetFlow → openconnect（加 AF 前缀）

- (void)pumpOutbound {
    if ([self isStopped]) return;
    __weak typeof(self) weakSelf = self;
    [_flow readPacketsWithCompletionHandler:^(NSArray<NSData *> *packets,
                                              NSArray<NSNumber *> *protocols) {
        __strong typeof(weakSelf) self = weakSelf;
        if (!self || [self isStopped]) return;
        for (NSData *pkt in packets) [self writeToTun:pkt];
        [self pumpOutbound];
    }];
}

- (void)writeToTun:(NSData *)pkt {
    NSUInteger len = pkt.length;
    if (len < 20 || len > 65000) return;
    const uint8_t *bytes = (const uint8_t *)pkt.bytes;
    uint8_t version = bytes[0] >> 4;
    uint32_t af = htonl((uint32_t)((version == 6) ? AF_INET6 : AF_INET));

    static uint8_t buf[4 + 65535];
    memcpy(buf, &af, 4);
    memcpy(buf + 4, bytes, len);
    int fd = [self currentFd];
    if (fd < 0) return;
    ssize_t w = write(fd, buf, 4 + len);
    if (w < 0 && errno != EAGAIN && errno != ENOBUFS) {
        _log([NSString stringWithFormat:@"[pump] ❌ 写 tun fd 失败：errno %d", errno]);
    } else {
        _outPackets++;
    }
}

#pragma mark - openconnect → packetFlow（剥 AF 前缀）

- (void)pumpInbound {
    static uint8_t buf[65535];
    while (![self isStopped]) {
        int fd = [self currentFd];
        if (fd < 0) break;
        struct pollfd pfd;
        pfd.fd = fd;
        pfd.events = POLLIN;
        pfd.revents = 0;
        int r = poll(&pfd, 1, 200);
        if (r <= 0) continue;
        if (pfd.revents & (POLLHUP | POLLERR | POLLNVAL)) break;

        for (;;) {
            ssize_t n = read(fd, buf, sizeof buf);
            if (n <= 0) break;                       // EAGAIN：本轮读空
            if (n <= 4 + 20) continue;               // 前缀 + 最短 IP 头
            uint32_t afVal;
            memcpy(&afVal, buf, 4);
            uint32_t family = ntohl(afVal);
            if (family != (uint32_t)AF_INET && family != (uint32_t)AF_INET6) continue;

            NSUInteger plen = (NSUInteger)n - 4;
            NSData *pkt = [NSData dataWithBytes:buf + 4 length:plen];
            NSNumber *proto = @((buf[4] >> 4) == 6 ? AF_INET6 : AF_INET);
            if ([self isStopped]) break;
            [_flow writePackets:@[pkt] withProtocols:@[proto]];
            _inPackets++;
            if (_inPackets <= 3 || _inPackets % 500 == 0) {
                _log([NSString stringWithFormat:@"[pump] 入向 %llu 包 / 出站 %llu 包（本包 %lu 字节）",
                      _inPackets, _outPackets, (unsigned long)plen]);
            }
        }
    }
    _log([NSString stringWithFormat:@"[pump] 入向泵退出：共 %llu 进 / %llu 出",
          _inPackets, _outPackets]);
}

- (void)stop {
    [_lock lock];
    if (_stopping) { [_lock unlock]; return; }
    _stopping = YES;
    int fd = _fd;
    _fd = -1;
    [_lock unlock];
    if (fd >= 0) close(fd);
    _log(@"[pump] 已停止");
}

@end
