//
//  arch/cc.h —— lwIP 平台适配（最小实现，见 tweak/lwipopts.h）
//
#ifndef IPAT_ARCH_CC_H
#define IPAT_ARCH_CC_H

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#define LWIP_PLATFORM_DIAG(x)   do { printf x; } while (0)
#define LWIP_PLATFORM_ASSERT(x) do { fprintf(stderr, "lwIP assert: %s\n", (const char *)(x)); abort(); } while (0)

#define LWIP_RAND() ((u32_t)random())

#endif /* IPAT_ARCH_CC_H */
