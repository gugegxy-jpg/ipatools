//
//  lwipopts.h
//  AnyVpn 非越狱模式的 lwIP 配置：单线程事件循环（NO_SYS=1），
//  整个 TCP/IP 栈跑在 AnyVpnT2S 的 select 循环里，不接 OS 层。
//
#ifndef IPAT_LWIPOPTS_H
#define IPAT_LWIPOPTS_H

#define NO_SYS                  1
// 必须显式关掉：opt.h 默认是 1，会引用 NO_SYS 模式下无人提供的 sys_prot_t
// （sys_arch.h 只在非 NO_SYS 分支才被包含）
#define SYS_LIGHTWEIGHT_PROT    0
#define LWIP_SOCKET             0
#define LWIP_NETCONN            0
#define LWIP_IPV4               1
#define LWIP_IPV6               0
#define LWIP_ARP                0   // 点对点隧道，没有链路层
#define LWIP_ETHERNET           0
#define LWIP_DHCP               0
#define LWIP_AUTOIP             0
#define LWIP_IGMP               0
#define LWIP_DNS                0   // DNS 我们自己组包（见 AnyVpnT2S.c 的解析器）
#define LWIP_RAW                0
#define LWIP_ICMP               1
#define LWIP_STATS              0
#define LWIP_TIMERS             1
#define LWIP_SUPPORT_CUSTOM_PBUF 0

#define MEM_LIBC_MALLOC         1   // 用系统 malloc，省得自己管堆
#define MEMP_MEM_MALLOC         1
#define PBUF_POOL_SIZE          128
#define PBUF_POOL_BUFSIZE       1600

#define TCP_MSS                 1344
#define TCP_WND                 (16 * 1024)
#define TCP_SND_BUF             (16 * 1024)
#define TCP_SND_QUEUELEN        64
#define MEMP_NUM_TCP_PCB        128
#define MEMP_NUM_TCP_PCB_LISTEN 8
#define MEMP_NUM_TCP_SEG        256
#define MEMP_NUM_UDP_PCB        64
#define MEMP_NUM_PBUF           256
#define MEMP_NUM_REASSDATA      16

#define IP_REASSEMBLY           1
#define IP_FRAG                 0
#define IP_REASS_MAX_PBUFS      64
#define LWIP_CHECKSUM_ON_COPY   1

#endif /* IPAT_LWIPOPTS_H */
