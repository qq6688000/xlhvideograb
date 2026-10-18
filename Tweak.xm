//
//  Tweak.xm
//  XLHVideoGrab — 网页视频链接悬浮抓取
//  兼容 iOS 15+ rootless (Dopamine / ElleKit)
//

#import <UIKit/UIKit.h>
#import <WebKit/WebKit.h>
#import "VGManager.h"
#import "VGCommon.h"

%hook WKWebView

// 所有 WKWebView 创建入口：先改 configuration 再创建
- (instancetype)initWithFrame:(CGRect)frame configuration:(WKWebViewConfiguration *)configuration {
    [VGManager injectIntoConfiguration:configuration];
    WKWebView *webView = %orig;
    [[VGManager shared] trackWebView:webView];
    [VGManager bindProxyForWebView:webView configuration:configuration];
    return webView;
}

// Storyboard / NSCoding 创建
- (instancetype)initWithCoder:(NSCoder *)coder {
    WKWebView *webView = %orig;
    [[VGManager shared] trackWebView:webView];
    return webView;
}

// 添加到窗口后挂载悬浮球
- (void)didMoveToWindow {
    %orig;
    WKWebView *self_ = self;
    if (self_.window) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [[VGManager shared] attachUIForWebView:self_];
        });
    }
}

%end

%ctor {
    @autoreleasepool {
        [[VGManager shared] start];
    }
}
