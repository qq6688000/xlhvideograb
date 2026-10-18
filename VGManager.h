//
//  VGManager.h
//

#import <Foundation/Foundation.h>
#import <WebKit/WebKit.h>
#import "VGCommon.h"

FOUNDATION_EXPORT NSString *const VGMediaDidChangeNotification;

@interface VGManager : NSObject

+ (instancetype)shared;

/// 在 WKWebView 创建前把 JS 抓取脚本 + messageHandler 注入配置
+ (void)injectIntoConfiguration:(WKWebViewConfiguration *)configuration;

/// WKWebView 创建后登记（弱引用）
- (void)trackWebView:(WKWebView *)webView;

/// 把 configuration 上挂的 message 代理绑定到具体 webView
+ (void)bindProxyForWebView:(WKWebView *)webView configuration:(WKWebViewConfiguration *)configuration;

/// 取当前最可能在前台的那个 WKWebView
- (WKWebView *)activeWebView;

/// JS / 原生消息入口
- (void)ingestPayload:(NSDictionary *)payload fromWebView:(WKWebView *)webView;

- (NSArray<VGMediaItem *> *)sortedItems;
- (void)clearItems;

/// 有 WKWebView 出现在窗口上时挂载悬浮 UI
- (void)attachUIForWebView:(WKWebView *)webView;

- (void)start;

/// 原生层探测次数（用于判断播放器有没有被挂上）
@property (nonatomic, assign, readonly) NSInteger nativeProbes;
- (void)countNativeProbe;

@end
