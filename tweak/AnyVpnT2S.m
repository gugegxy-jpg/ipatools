//
//  AnyVpnT2S.m
//  AnyVpn 非越狱模式引擎。
//
//  数据通路（全程用户态，不碰内核路由，无需 root）：
//    宿主 App socket --(fishhook 改连 127.0.0.1 中继)--> 本地中继 socket
//      <-> lwIP TCP/UDP pcb（NO_SYS 单线程 select 循环）
//      <-> netif 输出写 socketpair <-> openconnect
//
//  劫持范围：宿主 App 直接调 BSD socket API 的流量（游戏自研网络层基本都算）。
//  CFNetwork/NSURLSession 在系统库内部建连，劫持不到 —— 无越狱的硬边界。
//  DNS：iOS 的 getaddrinfo 走 mDNSResponder（独立进程、XPC），劫持不到 socket，
//  所以劫持 getaddrinfo 本身，用隧道内的 VPN DNS 自己解析，失败回落系统解析。
//
#import "AnyVpnT2S.h"
#import "IPATControlShared.h"
#import "fishhook.h"

#import "lwip/init.h"
#import "lwip/netif.h"
#import "lwip/tcp.h"
#import "lwip/udp.h"
#import "lwip/pbuf.h"
#import "lwip/ip4_addr.h"
#import "lwip/ip4.h"
#import "lwip/timeouts.h"
#import "lwip/sys.h"

#import <sys/socket.h>
#import <netinet/in.h>
#import <arpa/inet.h>
#import <netdb.h>   // getaddrinfo / struct addrinfo（劫持 DNS 用）
#import <fcntl.h>
#import <unistd.h>
#import <dlfcn.h>
#import <pthread.h>

#pragma mark - 小工具

#define T2SLog(...) do { IPATAppendLogLine([NSString stringWithFormat:@"[anyvpn/t2s] " __VA_ARGS__]); } while (0)

static u32_t g_bootMs;
u32_t sys_now(void) {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (u32_t)((uint64_t)ts.tv_sec * 1000 + ts.tv_nsec / 1000000 - g_bootMs);
}

static void set_nonblock(int fd) {
    int fl = fcntl(fd, F_GETFL, 0);
    fcntl(fd, F_SETFL, fl | O_NONBLOCK);
}

#pragma mark - 记账表（hook 线程写，引擎线程读，互斥锁保护）

typedef struct {
    uint16_t sport;      // 宿主侧 socket 的本地端口（bind 127.0.0.1:0 后拿到）
    uint32_t ip;         // 真实目的地（网络序）
    uint16_t port;
} T2STarget;

#define T2S_TARGET_MAX 256
static T2STarget g_tcpTargets[T2S_TARGET_MAX];   // TCP：按宿主源端口
static T2STarget g_udpTargets[T2S_TARGET_MAX];   // UDP：按宿主源端口
static pthread_mutex_t g_targetMutex = PTHREAD_MUTEX_INITIALIZER;

static void target_add(T2STarget *table, uint16_t sport, uint32_t ip, uint16_t port) {
    pthread_mutex_lock(&g_targetMutex);
    int slot = -1;
    for (int i = 0; i < T2S_TARGET_MAX; i++) {
        if (table[i].sport == sport) { slot = i; break; }     // 覆盖旧记录
        if (slot < 0 && table[i].sport == 0) slot = i;
    }
    if (slot >= 0) {
        table[slot].sport = sport;
        table[slot].ip = ip;
        table[slot].port = port;
    }
    pthread_mutex_unlock(&g_targetMutex);
}

static BOOL target_get(T2STarget *table, uint16_t sport, uint32_t *ip, uint16_t *port) {
    pthread_mutex_lock(&g_targetMutex);
    BOOL ok = NO;
    for (int i = 0; i < T2S_TARGET_MAX; i++) {
        if (table[i].sport == sport) {
            *ip = table[i].ip;
            *port = table[i].port;
            ok = YES;
            break;
        }
    }
    pthread_mutex_unlock(&g_targetMutex);
    return ok;
}

static void target_del(T2STarget *table, uint16_t sport) {
    pthread_mutex_lock(&g_targetMutex);
    for (int i = 0; i < T2S_TARGET_MAX; i++) {
        if (table[i].sport == sport) { table[i].sport = 0; break; }
    }
    pthread_mutex_unlock(&g_targetMutex);
}

#pragma mark - 引擎状态

static int g_ocFd = -1;        // socketpair 对端（lwIP 侧收发裸 IP 包）
static int g_listener = -1;    // TCP 中继监听
static int g_udpRelay = -1;    // UDP 中继
static uint16_t g_tcpPort, g_udpPort;
static struct netif g_nif;
static volatile BOOL g_run = NO;
static volatile BOOL g_ready = NO;
static pthread_t g_thread;

typedef struct TCPSession {
    int fd;                          // 已 accept 的宿主侧 socket（非阻塞）
    struct tcp_pcb *pcb;             // err 回调后置 NULL
    uint8_t *buf;                    // 目的地 -> 宿主
    size_t len, cap;
    size_t pendingRecv;              // 已收未确认给对端的字节数
    BOOL eof;                        // 宿主侧关了，缓冲发完就收尾
    struct TCPSession *next;
} TCPSession;

typedef struct UDPSession {
    struct sockaddr_in client;       // 宿主侧地址（127.0.0.1:sport）
    struct udp_pcb *pcb;
    struct UDPSession *next;
} UDPSession;

static TCPSession *g_tcpSess;
static UDPSession *g_udpSess;

// 受保护 fd（openconnect 自己的 socket，绝不劫持）
#define PROTECTED_MAX 128
static int g_protected[PROTECTED_MAX];
static int g_protectedN;

void T2SProtectFD(int fd) {
    if (g_protectedN < PROTECTED_MAX) g_protected[g_protectedN++] = fd;
}

static BOOL isProtectedFD(int fd) {
    for (int i = 0; i < g_protectedN; i++) {
        if (g_protected[i] == fd) return YES;
    }
    return NO;
}

static BOOL engineWantsInet(const struct sockaddr_in *d) {
    if (!g_ready) return NO;
    uint32_t ip = ntohl(d->sin_addr.s_addr);
    return (ip >> 24) != 127;        // 回环不走隧道
}

#pragma mark - lwIP netif

static err_t t2s_output(struct netif *nif, struct pbuf *p, const ip4_addr_t *ipaddr) {
    (void)ipaddr;
    if (g_ocFd < 0) return ERR_IF;
    size_t total = 0;
    for (struct pbuf *q = p; q; q = q->next) {
        total += q->len;
    }
    // MTU 守门：超过 netif MTU 的包绝不能进 openconnect——tun 读缓冲按 MTU 分配，
    // DGRAM read 会把大包截断成畸形 IP 包喂给网关，ocserv 校验失败直接杀会话
    //（表现：一连上、游戏一跑流量就 2~3 秒被服务端断一次）。IP_FRAG 开启后
    // lwIP 理论不会再出大包，这里兜底；真出现就丢，靠上层重传/重发
    if (nif && nif->mtu && total > nif->mtu) {
        static int dropLogs = 0;
        if (dropLogs < 5) {
            dropLogs++;
            T2SLog(@"丢弃超 MTU 出站包：%zu 字节（MTU %d）", total, nif->mtu);
        }
        return ERR_BUF;
    }
    static uint8_t linear[TCP_MSS + 40];
    total = 0;
    for (struct pbuf *q = p; q; q = q->next) {
        if (total + q->len > sizeof linear) return ERR_BUF;
        memcpy(linear + total, q->payload, q->len);
        total += q->len;
    }
    // g_ocFd 是 AF_UNIX SOCK_DGRAM：一次 write 必须是完整一个 IP 包（openconnect
    // 按包边界 read）。不存在部分写——缓冲满（EAGAIN/ENOBUFS）就整包丢弃，
    // 靠 lwIP TCP 重传兜底；UDP 丢了就丢了
    ssize_t n = write(g_ocFd, linear, total);
    if (n == (ssize_t)total) return ERR_OK;
    if (n < 0 && (errno == EAGAIN || errno == EWOULDBLOCK || errno == ENOBUFS ||
                  errno == EINTR)) {
        return ERR_OK;
    }
    return ERR_IF;
}

static err_t t2s_netif_init(struct netif *nif) {
    nif->name[0] = 't';
    nif->name[1] = 'n';
    nif->output = t2s_output;
    // lwIP 2.x 删掉了 NETIF_FLAG_POINTTOPOINT（1.x 的 flag）；本接口无链路层
    nif->flags = NETIF_FLAG_LINK_UP;
    return ERR_OK;
}

static void t2s_feed_lwip(void) {
    static uint8_t pkt[65535];
    // g_ocFd 是 AF_UNIX SOCK_DGRAM：每次 read 恰好取出一个完整 IP 包（不会粘包/
    // 残包），drain 到 EAGAIN 为止
    for (;;) {
        ssize_t n = read(g_ocFd, pkt, sizeof pkt);
        if (n < 0) {
            if (errno == EINTR) continue;
            return;   // EAGAIN：无更多数据；对端关闭同样退出
        }
        if (n == 0) return;
        struct pbuf *p = pbuf_alloc(PBUF_RAW, (u16_t)n, PBUF_RAM);
        if (!p) continue;
        pbuf_take(p, pkt, (u16_t)n);
        if (g_nif.input) g_nif.input(p, &g_nif);
    }
}

#pragma mark - TCP 会话

static void t2s_tcp_destroy(TCPSession *s) {
    if (s->pcb) {
        tcp_arg(s->pcb, NULL);
        tcp_recv(s->pcb, NULL);
        tcp_err(s->pcb, NULL);
        tcp_sent(s->pcb, NULL);
        tcp_poll(s->pcb, NULL, 0);
        tcp_abort(s->pcb);           // 简化：直接断，不做半关优雅收尾
        s->pcb = NULL;
    }
    if (s->fd >= 0) close(s->fd);
    free(s->buf);
    TCPSession **pp = &g_tcpSess;
    while (*pp && *pp != s) pp = &(*pp)->next;
    if (*pp) *pp = s->next;
    free(s);
}

static void t2s_tcp_flush(TCPSession *s) {
    while (s->len > 0) {
        ssize_t n = send(s->fd, s->buf, s->len, 0);
        if (n > 0) {
            size_t ack = (size_t)n > s->pendingRecv ? s->pendingRecv : (size_t)n;
            if (s->pcb && ack) tcp_recved(s->pcb, (u16_t)ack);
            s->pendingRecv -= ack;
            memmove(s->buf, s->buf + n, s->len - (size_t)n);
            s->len -= (size_t)n;
            continue;
        }
        if (n < 0 && (errno == EAGAIN || errno == EWOULDBLOCK)) break;
        s->eof = YES;   // 写失败当对端关了
        break;
    }
    if (s->len == 0 && s->eof && s->pcb) {
        tcp_arg(s->pcb, NULL);
        tcp_close(s->pcb);
        s->pcb = NULL;
        if (s->fd >= 0) { close(s->fd); s->fd = -1; }
        TCPSession **pp = &g_tcpSess;
        while (*pp && *pp != s) pp = &(*pp)->next;
        if (*pp) *pp = s->next;
        free(s->buf);
        free(s);
    }
}

static err_t t2s_tcp_recv(void *arg, struct tcp_pcb *pcb, struct pbuf *p, err_t err) {
    TCPSession *s = (TCPSession *)arg;
    if (!s || !p) {          // 对端关了：把剩下的发给宿主后收尾
        if (s) s->eof = YES;
        return ERR_OK;
    }
    size_t need = s->len + p->tot_len;
    if (need > s->cap) {
        size_t ncap = s->cap ? s->cap * 2 : 16 * 1024;
        while (ncap < need) ncap *= 2;
        uint8_t *nb = realloc(s->buf, ncap);
        if (!nb) { pbuf_free(p); return ERR_MEM; }
        s->buf = nb;
        s->cap = ncap;
    }
    pbuf_copy_partial(p, s->buf + s->len, p->tot_len, 0);
    s->len += p->tot_len;
    s->pendingRecv += p->tot_len;
    pbuf_free(p);
    // 缓冲不深就立刻确认；缓冲深就压一压对端（背压）
    if (s->pendingRecv < 64 * 1024 && s->pcb) {
        tcp_recved(pcb, (u16_t)p->tot_len);
        s->pendingRecv = 0;
    }
    t2s_tcp_flush(s);
    return ERR_OK;
}

static void t2s_tcp_err(void *arg, err_t err) {
    TCPSession *s = (TCPSession *)arg;
    if (!s) return;
    s->pcb = NULL;           // lwIP 已经 free 了 pcb
    s->eof = YES;
    t2s_tcp_flush(s);
}

static err_t t2s_tcp_connected(void *arg, struct tcp_pcb *pcb, err_t err) {
    (void)arg; (void)pcb; (void)err;
    return ERR_OK;
}

static void t2s_tcp_accept(int newfd) {
    struct sockaddr_in peer;
    socklen_t pl = sizeof peer;
    if (getpeername(newfd, (struct sockaddr *)&peer, &pl) != 0) { close(newfd); return; }
    uint16_t sport = ntohs(peer.sin_port);
    uint32_t dip; uint16_t dport;
    if (!target_get(g_tcpTargets, sport, &dip, &dport)) { close(newfd); return; }

    TCPSession *s = calloc(1, sizeof *s);
    s->fd = newfd;
    set_nonblock(newfd);

    struct tcp_pcb *pcb = tcp_new_ip_type(IPADDR_TYPE_V4);
    if (!pcb) { t2s_tcp_destroy(s); return; }
    tcp_arg(pcb, s);
    tcp_recv(pcb, t2s_tcp_recv);
    tcp_err(pcb, t2s_tcp_err);

    ip_addr_t addr;
    ip_addr_set_ip4_u32(&addr, dip);
    if (tcp_connect(pcb, &addr, dport, t2s_tcp_connected) != ERR_OK) {
        tcp_arg(pcb, NULL);
        tcp_abort(pcb);
        t2s_tcp_destroy(s);
        return;
    }
    s->pcb = pcb;
    s->next = g_tcpSess;
    g_tcpSess = s;
    target_del(g_tcpTargets, sport);
}

static void t2s_tcp_pump(TCPSession *s, fd_set *rs, fd_set *ws) {
    if (s->fd < 0) return;
    if (FD_ISSET(s->fd, ws)) t2s_tcp_flush(s);
    if (s->fd >= 0 && FD_ISSET(s->fd, rs) && s->pcb) {
        size_t avail = tcp_sndbuf(s->pcb);
        if (avail > 0) {
            uint8_t tmp[4096];
            size_t want = avail < sizeof tmp ? avail : sizeof tmp;
            ssize_t n = recv(s->fd, tmp, want, 0);
            if (n > 0) {
                tcp_write(s->pcb, tmp, (u16_t)n, TCP_WRITE_FLAG_COPY);
                tcp_output(s->pcb);
            } else if (n == 0) {
                s->eof = YES;
                t2s_tcp_flush(s);
            } else if (errno != EAGAIN && errno != EWOULDBLOCK) {
                t2s_tcp_destroy(s);
            }
        }
    }
}

#pragma mark - UDP 会话

static void t2s_udp_destroy(UDPSession *u) {
    if (u->pcb) {
        udp_recv(u->pcb, NULL, NULL);
        udp_remove(u->pcb);
    }
    UDPSession **pp = &g_udpSess;
    while (*pp && *pp != u) pp = &(*pp)->next;
    if (*pp) *pp = u->next;
    free(u);
}

static void t2s_udp_recv_cb(void *arg, struct udp_pcb *pcb, struct pbuf *p,
                            const ip_addr_t *addr, u16_t port) {
    (void)arg; (void)pcb; (void)addr; (void)port;
    UDPSession *u = (UDPSession *)arg;
    if (!u || !p) return;
    uint8_t pkt[2048];
    size_t n = p->tot_len > sizeof pkt ? sizeof pkt : p->tot_len;
    pbuf_copy_partial(p, pkt, (u16_t)n, 0);
    pbuf_free(p);
    sendto(g_udpRelay, pkt, n, 0, (struct sockaddr *)&u->client, sizeof u->client);
}

static void t2s_udp_accept(struct sockaddr_in *from) {
    uint32_t dip; uint16_t dport;
    if (!target_get(g_udpTargets, ntohs(from->sin_port), &dip, &dport)) return;

    for (UDPSession *u = g_udpSess; u; u = u->next) {
        if (u->client.sin_port == from->sin_port) return;   // 已有会话
    }
    UDPSession *u = calloc(1, sizeof *u);
    u->client = *from;
    struct udp_pcb *pcb = udp_new_ip_type(IPADDR_TYPE_V4);
    if (!pcb) { free(u); return; }
    udp_recv(pcb, t2s_udp_recv_cb, u);
    ip_addr_t addr;
    ip_addr_set_ip4_u32(&addr, dip);
    if (udp_connect(pcb, &addr, dport) != ERR_OK) {
        udp_remove(pcb);
        free(u);
        return;
    }
    u->pcb = pcb;
    u->next = g_udpSess;
    g_udpSess = u;
}

#pragma mark - DNS（隧道内解析）

typedef struct {
    char name[256];
    uint32_t addr;      // 主机序
    int state;          // 0=待发 1=已发 2=完成
    int found;
} DNSReq;

static DNSReq g_dnsReq;
static pthread_mutex_t g_dnsMutex = PTHREAD_MUTEX_INITIALIZER;
static pthread_cond_t g_dnsCond = PTHREAD_COND_INITIALIZER;
static struct udp_pcb *g_dnsPcb;
static ip4_addr_t g_dnsServer;
static uint16_t g_dnsTxid;
static BOOL g_dnsPending;

static void t2s_dns_recv_cb(void *arg, struct udp_pcb *pcb, struct pbuf *p,
                            const ip_addr_t *addr, u16_t port) {
    (void)arg; (void)pcb; (void)addr; (void)port;
    if (!p) return;
    uint8_t pkt[1500];
    u16_t n = p->tot_len > sizeof pkt ? sizeof pkt : p->tot_len;
    pbuf_copy_partial(p, pkt, n, 0);
    pbuf_free(p);
    if (n < 12) return;
    uint16_t txid = (uint16_t)((pkt[0] << 8) | pkt[1]);
    pthread_mutex_lock(&g_dnsMutex);
    if (g_dnsReq.state == 1 && txid == g_dnsTxid && (pkt[2] & 0x80)) {   // QR=响应
        uint16_t qd = (uint16_t)((pkt[4] << 8) | pkt[5]);
        uint16_t an = (uint16_t)((pkt[6] << 8) | pkt[7]);
        size_t off = 12;
        for (int i = 0; i < qd && off < n; i++) {          // 跳过 Question
            while (off < n) { uint8_t l = pkt[off++]; if (!l) break; off += l; }
            off += 4;
        }
        for (int i = 0; i < an && off + 10 <= n; i++) {    // 逐条 Answer
            while (off < n) {
                uint8_t l = pkt[off];
                if (l & 0xC0) { off += 2; break; }         // 压缩指针
                if (!l) { off += 1; break; }
                off += 1 + l;
            }
            if (off + 10 > n) break;
            uint16_t type = (uint16_t)((pkt[off] << 8) | pkt[off + 1]);
            uint16_t rdlen = (uint16_t)((pkt[off + 8] << 8) | pkt[off + 9]);
            off += 10;
            if (type == 1 && rdlen == 4 && off + 4 <= n) { // A 记录
                g_dnsReq.addr = ((uint32_t)pkt[off] << 24) | ((uint32_t)pkt[off+1] << 16) |
                                ((uint32_t)pkt[off+2] << 8) | pkt[off+3];
                g_dnsReq.found = 1;
                break;
            }
            off += rdlen;
        }
        g_dnsReq.state = 2;
        pthread_cond_broadcast(&g_dnsCond);
    }
    pthread_mutex_unlock(&g_dnsMutex);
}

static void t2s_dns_poll(void) {
    pthread_mutex_lock(&g_dnsMutex);
    BOOL pending = g_dnsPending && g_dnsReq.state == 0;
    pthread_mutex_unlock(&g_dnsMutex);
    if (!pending) return;

    uint8_t q[300];
    size_t n = 0;
    pthread_mutex_lock(&g_dnsMutex);
    g_dnsTxid = (uint16_t)(random() & 0xFFFF);
    uint16_t txid = g_dnsTxid;
    pthread_mutex_unlock(&g_dnsMutex);
    q[n++] = (uint8_t)(txid >> 8); q[n++] = (uint8_t)(txid & 0xFF);
    q[n++] = 0x01; q[n++] = 0x00;          // RD=1
    q[n++] = 0; q[n++] = 1;                // QDCOUNT=1
    q[n++] = 0; q[n++] = 0; q[n++] = 0; q[n++] = 0; q[n++] = 0; q[n++] = 0;
    for (const char *c = g_dnsReq.name; *c && n < sizeof q - 6; c++) {
        if (*c == '.') { q[n++] = 0; continue; }
        const char *dot = strchr(c, '.');
        size_t l = dot ? (size_t)(dot - c) : strlen(c);
        if (l > 63) l = 63;
        q[n++] = (uint8_t)l;
        memcpy(q + n, c, l);
        n += l;
        if (!dot) break;
        c += l - 1;   // for 循环里再 ++
    }
    q[n++] = 0;
    q[n++] = 0; q[n++] = 1;                // Type A
    q[n++] = 0; q[n++] = 1;                // Class IN

    if (!g_dnsPcb) {
        g_dnsPcb = udp_new_ip_type(IPADDR_TYPE_V4);
        if (!g_dnsPcb) return;
        udp_recv(g_dnsPcb, t2s_dns_recv_cb, NULL);
    }
    struct pbuf *p = pbuf_alloc(PBUF_TRANSPORT, (u16_t)n, PBUF_RAM);
    if (!p) return;
    pbuf_take(p, q, (u16_t)n);
    ip_addr_t s;
    ip_addr_copy_from_ip4(s, g_dnsServer);
    err_t r = udp_sendto(g_dnsPcb, p, &s, 53);
    pbuf_free(p);
    pthread_mutex_lock(&g_dnsMutex);
    if (r == ERR_OK) g_dnsReq.state = 1;
    else g_dnsReq.state = 2;               // 发不出去直接判失败
    pthread_cond_broadcast(&g_dnsCond);
    pthread_mutex_unlock(&g_dnsMutex);
}

BOOL T2SResolve(NSString *host, uint32_t *outAddrV4) {
    if (!g_ready || !host.length || !outAddrV4) return NO;
    char name[256] = {0};
    [host getCString:name maxLength:sizeof name - 1 encoding:NSUTF8StringEncoding];

    pthread_mutex_lock(&g_dnsMutex);
    if (g_dnsReq.state != 2 && g_dnsReq.state != 0) {
        pthread_mutex_unlock(&g_dnsMutex);
        return NO;                          // 上一个查询还在飞，别叠加
    }
    memset(&g_dnsReq, 0, sizeof g_dnsReq);
    strlcpy(g_dnsReq.name, name, sizeof g_dnsReq.name);
    g_dnsPending = YES;
    struct timespec ts;
    clock_gettime(CLOCK_REALTIME, &ts);
    ts.tv_sec += 5;
    int rc = 0;
    while (g_dnsReq.state != 2 && rc != ETIMEDOUT) {
        rc = pthread_cond_timedwait(&g_dnsCond, &g_dnsMutex, &ts);
    }
    g_dnsPending = NO;
    BOOL found = g_dnsReq.found;
    uint32_t addr = g_dnsReq.addr;
    g_dnsReq.state = 0;
    pthread_mutex_unlock(&g_dnsMutex);
    if (found) *outAddrV4 = htonl(addr);
    return found ? YES : NO;
}

#pragma mark - 主循环

static void *t2s_main(void *arg) {
    (void)arg;
    @autoreleasepool {
        while (g_run) {
            fd_set rs, ws;
            FD_ZERO(&rs);
            FD_ZERO(&ws);
            int maxfd = -1;
            if (g_ocFd >= 0) { FD_SET(g_ocFd, &rs); maxfd = g_ocFd; }
            if (g_listener >= 0) { FD_SET(g_listener, &rs); if (g_listener > maxfd) maxfd = g_listener; }
            if (g_udpRelay >= 0) { FD_SET(g_udpRelay, &rs); if (g_udpRelay > maxfd) maxfd = g_udpRelay; }
            for (TCPSession *s = g_tcpSess; s; s = s->next) {
                if (s->fd < 0) continue;
                FD_SET(s->fd, &rs);
                if (s->len > 0) FD_SET(s->fd, &ws);
                if (s->fd > maxfd) maxfd = s->fd;
            }

            int sleepMs = sys_timeouts_sleeptime();
            if (sleepMs < 0 || sleepMs > 100) sleepMs = 100;
            struct timeval tv = { .tv_sec = 0, .tv_usec = sleepMs * 1000 };
            int n = select(maxfd + 1, &rs, &ws, NULL, &tv);
            if (n < 0 && errno != EINTR) break;

            sys_check_timeouts();
            t2s_dns_poll();
            if (!g_run) break;

            if (g_ocFd >= 0 && FD_ISSET(g_ocFd, &rs)) t2s_feed_lwip();
            if (g_listener >= 0 && FD_ISSET(g_listener, &rs)) {
                int newfd = accept(g_listener, NULL, NULL);
                if (newfd >= 0) t2s_tcp_accept(newfd);
            }
            if (g_udpRelay >= 0 && FD_ISSET(g_udpRelay, &rs)) {
                uint8_t pkt[2048];
                struct sockaddr_in from;
                socklen_t fl = sizeof from;
                ssize_t n2 = recvfrom(g_udpRelay, pkt, sizeof pkt, 0,
                                      (struct sockaddr *)&from, &fl);
                if (n2 > 0) {
                    t2s_udp_accept(&from);   // 顺便登记新会话
                    for (UDPSession *u = g_udpSess; u; u = u->next) {
                        if (u->client.sin_port == from.sin_port) {
                            struct pbuf *p = pbuf_alloc(PBUF_TRANSPORT, (u16_t)n2, PBUF_RAM);
                            if (p) {
                                pbuf_take(p, pkt, (u16_t)n2);
                                udp_send(u->pcb, p);
                                pbuf_free(p);
                            }
                            break;
                        }
                    }
                }
            }
            TCPSession *s = g_tcpSess;
            while (s) {
                TCPSession *next = s->next;
                t2s_tcp_pump(s, &rs, &ws);
                s = next;
            }
        }
    }
    return NULL;
}

#pragma mark - 引擎启停

BOOL T2SEngineStart(int engineFd, NSString *localIP, NSString *netmask, NSString *gateway,
                    int mtu, NSArray<NSString *> *dnsIPs, NSString **errOut) {
    if (g_ready) return YES;
    if (engineFd < 0) {
        if (errOut) *errOut = @"引擎 fd 无效";
        return NO;
    }

    lwip_init();
    g_bootMs = sys_now();

    g_ocFd = engineFd;
    set_nonblock(g_ocFd);

    // 中继：TCP 监听 + UDP 收发口，都绑 127.0.0.1 随机口
    g_listener = socket(AF_INET, SOCK_STREAM, 0);
    g_udpRelay = socket(AF_INET, SOCK_DGRAM, 0);
    struct sockaddr_in la;
    memset(&la, 0, sizeof la);
    la.sin_len = sizeof la;
    la.sin_family = AF_INET;
    la.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
    if (bind(g_listener, (struct sockaddr *)&la, sizeof la) != 0 ||
        listen(g_listener, 32) != 0) {
        if (errOut) *errOut = @"TCP 中继监听失败";
        return NO;
    }
    if (bind(g_udpRelay, (struct sockaddr *)&la, sizeof la) != 0) {
        if (errOut) *errOut = @"UDP 中继绑定失败";
        return NO;
    }
    socklen_t ll = sizeof la;
    getsockname(g_listener, (struct sockaddr *)&la, &ll);
    g_tcpPort = ntohs(la.sin_port);
    ll = sizeof la;
    getsockname(g_udpRelay, (struct sockaddr *)&la, &ll);
    g_udpPort = ntohs(la.sin_port);
    set_nonblock(g_listener);
    set_nonblock(g_udpRelay);

    ip4_addr_t ip, mask, gw;
    ip4addr_aton(localIP.UTF8String ?: "10.0.0.2", &ip);
    ip4addr_aton(netmask.UTF8String ?: "255.255.255.0", &mask);
    ip4addr_aton(gateway.UTF8String ?: localIP.UTF8String ?: "10.0.0.2", &gw);
    if (mtu <= 0) mtu = 1400;
    g_nif.mtu = (u16_t)mtu;
    netif_add(&g_nif, &ip, &mask, &gw, NULL, t2s_netif_init, ip4_input);
    netif_set_default(&g_nif);
    netif_set_up(&g_nif);

    ip4addr_aton(dnsIPs.firstObject.UTF8String ?: "8.8.8.8", &g_dnsServer);

    g_run = YES;
    if (pthread_create(&g_thread, NULL, t2s_main, NULL) != 0) {
        g_run = NO;
        if (errOut) *errOut = @"引擎线程创建失败";
        return NO;
    }
    g_ready = YES;
    T2SLog(@"引擎就绪：TCP 中继 :%u，UDP 中继 :%u，MTU %d", g_tcpPort, g_udpPort, mtu);
    return YES;
}

void T2SEngineStop(void) {
    g_ready = NO;
    g_run = NO;
    pthread_join(g_thread, NULL);
    while (g_tcpSess) t2s_tcp_destroy(g_tcpSess);
    while (g_udpSess) t2s_udp_destroy(g_udpSess);
    if (g_dnsPcb) { udp_remove(g_dnsPcb); g_dnsPcb = NULL; }
    if (g_listener >= 0) { close(g_listener); g_listener = -1; }
    if (g_udpRelay >= 0) { close(g_udpRelay); g_udpRelay = -1; }
    if (g_ocFd >= 0) { close(g_ocFd); g_ocFd = -1; }
    netif_remove(&g_nif);
}

BOOL T2SEngineReady(void) {
    return g_ready;
}

#pragma mark - fishhook 劫持

static int (*real_connect)(int, const struct sockaddr *, socklen_t);
static ssize_t (*real_sendto)(int, const void *, size_t, int, const struct sockaddr *, socklen_t);
static int (*real_getaddrinfo)(const char *, const char *,
                               const struct addrinfo *, struct addrinfo **);
static BOOL g_hooksInstalled;

// 把 fd 接到中继：bind 127.0.0.1:0 定源端口 -> 记账 -> connect 中继
static BOOL t2s_wire_fd(int fd, BOOL isTCP, const struct sockaddr_in *dest) {
    struct sockaddr_in la;
    memset(&la, 0, sizeof la);
    la.sin_len = sizeof la;
    la.sin_family = AF_INET;
    if (bind(fd, (struct sockaddr *)&la, sizeof la) != 0) return NO;
    socklen_t ll = sizeof la;
    if (getsockname(fd, (struct sockaddr *)&la, &ll) != 0) return NO;
    uint16_t sport = ntohs(la.sin_port);
    struct sockaddr_in relay = la;
    relay.sin_port = htons(isTCP ? g_tcpPort : g_udpPort);
    // 显式走原函数：connect 已被劫持，虽然回环目的地会自然直通，
    // 但这里不能依赖那个兜底逻辑
    int rc = real_connect(fd, (struct sockaddr *)&relay, sizeof relay);
    if (rc != 0 && errno != EINPROGRESS) return NO;
    if (isTCP) target_add(g_tcpTargets, sport, dest->sin_addr.s_addr, dest->sin_port);
    else target_add(g_udpTargets, sport, dest->sin_addr.s_addr, dest->sin_port);
    return YES;
}

static int hooked_connect(int fd, const struct sockaddr *sa, socklen_t len) {
    if (g_hooksInstalled && sa && sa->sa_family == AF_INET && g_ready && !isProtectedFD(fd) &&
        len >= (socklen_t)sizeof(struct sockaddr_in)) {
        const struct sockaddr_in *d = (const struct sockaddr_in *)sa;
        if (engineWantsInet(d)) {
            int type = 0;
            socklen_t tl = sizeof type;
            if (getsockopt(fd, SOL_SOCKET, SO_TYPE, &type, &tl) == 0 &&
                (type == SOCK_STREAM || type == SOCK_DGRAM) &&
                t2s_wire_fd(fd, type == SOCK_STREAM, d)) {
                return 0;   // 连的是本机中继，内核立即完成
            }
        }
    }
    return real_connect(fd, sa, len);
}

static ssize_t hooked_sendto(int fd, const void *buf, size_t n, int flags,
                             const struct sockaddr *sa, socklen_t slen) {
    if (g_hooksInstalled && sa && sa->sa_family == AF_INET && g_ready && !isProtectedFD(fd) &&
        slen >= (socklen_t)sizeof(struct sockaddr_in)) {
        const struct sockaddr_in *d = (const struct sockaddr_in *)sa;
        if (engineWantsInet(d)) {
            int type = 0;
            socklen_t tl = sizeof type;
            if (getsockopt(fd, SOL_SOCKET, SO_TYPE, &type, &tl) == 0 && type == SOCK_DGRAM) {
                // 已接进中继的 fd 直接发；新 fd 先接线
                struct sockaddr_in peer;
                socklen_t pl = sizeof peer;
                BOOL wired = getpeername(fd, (struct sockaddr *)&peer, &pl) == 0 &&
                             ntohs(peer.sin_port) == g_udpPort;
                if (!wired) wired = t2s_wire_fd(fd, NO, d);
                if (wired) return send(fd, buf, n, flags);
            }
        }
    }
    return real_sendto(fd, buf, n, flags, sa, slen);
}

static int hooked_getaddrinfo(const char *node, const char *service,
                              const struct addrinfo *hints, struct addrinfo **res) {
    if (g_hooksInstalled && g_ready && node && *node && res) {
        struct in_addr numeric;
        if (inet_pton(AF_INET, node, &numeric) != 1) {     // 数字 IP 直接放行
            uint32_t a = 0;
            if (T2SResolve([NSString stringWithUTF8String:node], &a)) {
                int port = service ? atoi(service) : 0;
                struct addrinfo *ai = calloc(1, sizeof *ai);
                struct sockaddr_in *sa = calloc(1, sizeof *sa);
                if (ai && sa) {
                    sa->sin_len = sizeof *sa;
                    sa->sin_family = AF_INET;
                    sa->sin_port = htons((uint16_t)port);
                    sa->sin_addr.s_addr = a;
                    ai->ai_family = AF_INET;
                    ai->ai_socktype = (hints && hints->ai_socktype) ? hints->ai_socktype : SOCK_STREAM;
                    ai->ai_protocol = (hints && hints->ai_protocol) ? hints->ai_protocol : 0;
                    ai->ai_addrlen = sizeof *sa;
                    ai->ai_addr = (struct sockaddr *)sa;
                    *res = ai;
                    return 0;
                }
                free(ai);
                free(sa);
            }
            // 隧道解析失败：回落系统解析（可能拿不到隧道内的地域结果，但聊胜于无）
        }
    }
    return real_getaddrinfo(node, service, hints, res);
}

void T2SInstallHooks(void) {
    if (g_hooksInstalled) return;
    struct rebinding rb[] = {
        { "connect",     (void *)hooked_connect,     (void **)&real_connect },
        { "sendto",      (void *)hooked_sendto,      (void **)&real_sendto },
        { "getaddrinfo", (void *)hooked_getaddrinfo, (void **)&real_getaddrinfo },
    };
    rebind_symbols(rb, 3);
    g_hooksInstalled = YES;
    T2SLog(@"socket 劫持已安装（connect/sendto/getaddrinfo）");
}
