//
//  Browser.h
//  ipatool demo：简易内网浏览器（裸 socket HTTP 客户端）
//
//  为什么不用 WKWebView / NSURLSession：
//  它们在 CFNetwork / WebContent 进程里建连，AnyVpn.dylib 的 fishhook 劫持不到，
//  内网站点必然打不开——那是「非越狱模式」的硬边界，不是 bug。
//  这里用裸 BSD socket 自己发请求，和游戏自研网络层同一条通道，
//  connect/sendto/getaddrinfo 会被劫持进 CSTP 隧道。
//  内网页面能在这里打开 = 隧道真的在跑流量。
//

#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

@interface IPATBrowserVC : UIViewController
@end

NS_ASSUME_NONNULL_END

