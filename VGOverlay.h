//
//  VGOverlay.h
//  悬浮按钮窗口 + 视频列表面板
//

#import <UIKit/UIKit.h>
#import <WebKit/WebKit.h>

@class VGMediaItem;
@class VGOverlayViewController;

@interface VGHostWindow : NSObject

@property (nonatomic, weak, readonly) UIWindowScene *scene;
@property (nonatomic, strong, readonly) UIWindow *window;
@property (nonatomic, strong, readonly) VGOverlayViewController *controller;

- (instancetype)initWithScene:(UIWindowScene *)scene;
- (void)bindWebView:(WKWebView *)webView;
- (void)showIfNeeded;
- (void)hide;

@end
