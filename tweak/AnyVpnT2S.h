//
//  AnyVpnT2S.h
//  非越狱模式引擎：openconnect tun 数据 <-> lwIP 用户态 TCP/IP 栈 <-> 本地中继
//  + fishhook 劫持（connect / sendto / getaddrinfo）。
//
//  数据通路（全程用户态，不碰内核路由，无需 root）：
//    宿主 App socket --(fishhook 改连 127.0.0.1 中继)--> 中继 socket
//      <-> lwIP TCP/UDP pcb <-> netif(输出写 socketpair) <-> openconnect
//
#ifndef IPAT_ANYVPN_T2S_H
#define IPAT_ANYVPN_T2S_H

#import <Foundation/Foundation.h>
#import <netinet/in.h>

__BEGIN_DECLS

// 在 dylib 加载时调用：安装 fishhook 劫持（engine 未就绪时全部直通原函数）
void T2SInstallHooks(void);

// VPN 自身的 socket（openconnect 回调 protect）不劫持
void T2SProtectFD(int fd);

// 引擎控制。openconnectTunFd 是 openconnect 正在读写的 tun fd——
// 这里用 socketpair 掉包：我们把它的对端接进 lwIP，收发裸 IP 包。
BOOL T2SEngineStart(int openconnectTunFd,
                    NSString *localIP, NSString *netmask, NSString *gateway,
                    int mtu, NSArray<NSString *> *dnsIPs,
                    NSString **errOut);
void T2SEngineStop(void);
BOOL T2SEngineReady(void);

// DNS（走隧道内的 VPN DNS）。阻塞，内部 5s 超时，失败返回 NO。
BOOL T2SResolve(NSString *host, uint32_t *outAddrV4);

__END_DECLS

#endif /* IPAT_ANYVPN_T2S_H */
