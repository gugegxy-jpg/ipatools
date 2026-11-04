#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

typedef void (^OCLogBlock)(NSString *line);

/// libopenconnect 会话封装：认证状态机 + CSTP 握手 + 网关 IP 配置。
/// 纯 C 回调，不依赖 UIKit / App 内悬浮窗 / fishhook。
@interface OCSession : NSObject

/// 最近一次失败原因。不用 NSError** —— 带 error 出参的 ObjC 方法会被 Swift
/// 导入成 throws，签名容易和 SwiftUI 侧调用对不上。
@property (nonatomic, readonly, copy) NSString *lastError;

- (instancetype)initWithConfig:(NSDictionary<NSString *, id> *)config
                           log:(OCLogBlock)log;

/// init_ssl → vpninfo_new → obtain_cookie → make_cstp_connection → get_ip_info
/// 成功返回网关下发的配置字典（addr/netmask/gateway/dns/mtu/splitIncludes…），
/// 失败返回 nil 并填写 lastError
- (NSDictionary<NSString *, id> * _Nullable)connectAndGetIPInfo;

/// 把 socketpair 的一端交给 openconnect 当 tun fd（必须在握手之后）
- (BOOL)attachTunFd:(int)fd;

/// 阻塞运行 openconnect_mainloop，直到断开或被 cancel
- (void)runMainloop;

/// 通过 cmd pipe 让 mainloop 退出
- (void)cancel;

/// 释放 vpninfo（必须在 runMainloop 返回之后）
- (void)shutdown;

@end

NS_ASSUME_NONNULL_END
