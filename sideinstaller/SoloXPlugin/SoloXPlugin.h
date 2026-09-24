#import <Foundation/Foundation.h>

// 宿主 App（SideInjector）与插件之间约定的 Darwin 通知名（无需 entitlement，系统级广播）。
FOUNDATION_EXPORT NSString *const kSoloXToggleNotification;

// 插件版本，便于宿主识别。
FOUNDATION_EXPORT NSString *const kSoloXPluginVersion;
