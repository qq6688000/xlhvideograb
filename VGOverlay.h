//
//  VGOverlay.h
//  悬浮抓取层：直接挂在 App 自身 window 上，不做独立 UIWindow
//

#import <UIKit/UIKit.h>
#import <WebKit/WebKit.h>

@class VGMediaItem;

@interface VGOverlayController : NSObject

/// 取（或创建）某个 window 对应的悬浮层，同一 window 只会有一份
+ (instancetype)controllerForWindow:(UIWindow *)window;

@property (nonatomic, weak, readonly) UIWindow *window;
@property (nonatomic, weak, readonly) WKWebView *webView;

- (void)bindWebView:(WKWebView *)webView;
- (void)showIfNeeded;
- (void)detach;

@end
