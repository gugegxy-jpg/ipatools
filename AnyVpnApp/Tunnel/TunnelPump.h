#import <Foundation/Foundation.h>
#import <NetworkExtension/NetworkExtension.h>

NS_ASSUME_NONNULL_BEGIN

typedef void (^TunnelPumpLogBlock)(NSString *line);

/// NEPacketTunnelFlow <-> socketpair 的纯 IP 包桥。
///
/// openconnect 在 Apple 平台按 utun 格式读写 tun fd：每个 IP 包前面带
/// 4 字节 htonl(AF_INET / AF_INET6) 地址族头。packetFlow 收发的是纯 IP 包，
/// 所以两个方向都要做前缀转换。这里不引入 lwIP / tun2socks —— 系统协议栈
/// 就是协议栈，跟安卓 VpnService 把 fd 直接交给 openconnect 是一回事。
@interface TunnelPump : NSObject

- (instancetype)initWithFlow:(NEPacketTunnelFlow *)flow
                          fd:(int)fd
                         log:(TunnelPumpLogBlock)log;
- (void)start;
- (void)stop;

@end

NS_ASSUME_NONNULL_END
