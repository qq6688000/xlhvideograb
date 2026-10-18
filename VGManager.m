//
//  VGManager.m
//

#import "VGManager.h"
#import "VGOverlay.h"
#import "VGScript.h"
#import <objc/runtime.h>
#import <UIKit/UIKit.h>

NSString *const VGMediaDidChangeNotification = @"VGMediaDidChangeNotification";

static char kVGProxyKey;

#pragma mark - 消息代理

@interface VGMessageProxy : NSObject <WKScriptMessageHandler>
@property (nonatomic, weak) WKWebView *webView;
@end

@implementation VGMessageProxy
- (void)userContentController:(WKUserContentController *)userContentController
      didReceiveScriptMessage:(WKScriptMessage *)message {
    if (![message.name isEqualToString:@"xlhgrab"]) return;
    if (![message.body isKindOfClass:[NSDictionary class]]) return;
    [[VGManager shared] ingestPayload:(NSDictionary *)message.body fromWebView:self.webView];
}
@end

#pragma mark - VGManager

@interface VGManager ()
@property (nonatomic, strong) NSMutableDictionary<NSString *, VGMediaItem *> *media;
@property (nonatomic, strong) NSHashTable<WKWebView *> *webViews;
@property (nonatomic, assign) BOOL started;
- (void)start;
- (void)trackWebView:(WKWebView *)webView;
- (WKWebView *)activeWebView;
- (void)ingestPayload:(NSDictionary *)payload fromWebView:(WKWebView *)webView;
- (NSArray<VGMediaItem *> *)sortedItems;
- (void)clearItems;
- (void)attachUIForWebView:(WKWebView *)webView;
@end

@implementation VGManager

+ (instancetype)shared {
    static VGManager *m;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        m = [VGManager new];
        m.media = [NSMutableDictionary dictionary];
        m.webViews = [NSHashTable weakObjectsHashTable];
    });
    return m;
}

- (void)start {
    if (self.started) return;
    self.started = YES;
    // 预创建配置目录，方便 shell 端直接写配置
    [[NSFileManager defaultManager] createDirectoryAtPath:@"/var/mobile/Library/Preferences/xlhgrab"
                              withIntermediateDirectories:YES attributes:nil error:NULL];
    [[NSFileManager defaultManager] createDirectoryAtPath:@"/var/mobile/Documents/XLHVideoGrab"
                              withIntermediateDirectories:YES attributes:nil error:NULL];
}

#pragma mark - 注入

static NSHashTable *sInjectedControllers(void) {
    static NSHashTable *table;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        table = [NSHashTable weakObjectsHashTable];
    });
    return table;
}

+ (void)injectIntoConfiguration:(WKWebViewConfiguration *)configuration {
    if (!configuration) return;
    if (!VGConfigBool(@"enabled", YES)) return;

    @try {
        WKUserContentController *ucc = configuration.userContentController;
        if (!ucc) {
            ucc = [WKUserContentController new];
            configuration.userContentController = ucc;
        }
        // 同一个 userContentController 只能注册一次同名 handler，否则会抛异常
        @synchronized (sInjectedControllers()) {
            if ([sInjectedControllers() containsObject:ucc]) return;
            [sInjectedControllers() addObject:ucc];
        }

        VGMessageProxy *proxy = [VGMessageProxy new];
        objc_setAssociatedObject(configuration, &kVGProxyKey, proxy, OBJC_ASSOCIATION_RETAIN_NONATOMIC);

        [ucc addScriptMessageHandler:proxy name:@"xlhgrab"];

        NSString *source = VGScriptSource();
        if (source.length) {
            WKUserScript *script = [[WKUserScript alloc] initWithSource:source
                                                           injectionTime:WKUserScriptInjectionTimeAtDocumentStart
                                                        forMainFrameOnly:NO];
            [ucc addUserScript:script];
        }
    } @catch (NSException *e) {
        NSLog(@"[XLHVideoGrab] inject failed: %@", e);
    }
}

+ (void)bindProxyForWebView:(WKWebView *)webView configuration:(WKWebViewConfiguration *)configuration {
    if (!webView || !configuration) return;
    VGMessageProxy *proxy = objc_getAssociatedObject(configuration, &kVGProxyKey);
    if ([proxy isKindOfClass:[VGMessageProxy class]]) proxy.webView = webView;
}

- (void)trackWebView:(WKWebView *)webView {
    if (!webView) return;
    @synchronized (self.webViews) {
        [self.webViews addObject:webView];
    }
}

#pragma mark - 数据

- (void)ingestPayload:(NSDictionary *)payload fromWebView:(WKWebView *)webView {
    NSString *url = payload[@"url"];
    if (![url isKindOfClass:[NSString class]] || url.length < 8) return;
    if (![url hasPrefix:@"http"]) return;

    BOOL changed = NO;
    @synchronized (self.media) {
        VGMediaItem *item = self.media[url];
        if (item) {
            item.hits += 1;
        } else {
            item = [VGMediaItem new];
            item.url = url;
            item.kindString = [payload[@"kind"] isKindOfClass:[NSString class]] ? payload[@"kind"] : @"";
            item.source = [payload[@"source"] isKindOfClass:[NSString class]] ? payload[@"source"] : @"";
            NSString *page = [payload[@"page"] isKindOfClass:[NSString class]] ? payload[@"page"] : nil;
            if (!page.length) page = webView.URL.absoluteString ?: @"";
            item.pageURL = page;
            item.addedAt = [NSDate date].timeIntervalSince1970;
            item.hits = 1;
            self.media[url] = item;

            // 上限保护
            if (self.media.count > 600) {
                NSArray *keys = [self.media keysSortedByValueUsingComparator:^NSComparisonResult(VGMediaItem *a, VGMediaItem *b) {
                    return a.addedAt < b.addedAt ? NSOrderedAscending : NSOrderedDescending;
                }];
                for (NSUInteger i = 0; i < 200 && i < keys.count; i++) {
                    [self.media removeObjectForKey:keys[i]];
                }
            }
            changed = YES;
        }
    }

    if (changed) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [[NSNotificationCenter defaultCenter] postNotificationName:VGMediaDidChangeNotification object:nil];
        });
    }
}

- (NSArray<VGMediaItem *> *)sortedItems {
    NSArray *all;
    @synchronized (self.media) {
        all = self.media.allValues;
    }
    return [all sortedArrayUsingComparator:^NSComparisonResult(VGMediaItem *a, VGMediaItem *b) {
        if (a.score != b.score) return a.score > b.score ? NSOrderedAscending : NSOrderedDescending;
        if (a.addedAt != b.addedAt) return a.addedAt > b.addedAt ? NSOrderedAscending : NSOrderedDescending;
        return NSOrderedSame;
    }];
}

- (void)clearItems {
    @synchronized (self.media) {
        [self.media removeAllObjects];
    }
    dispatch_async(dispatch_get_main_queue(), ^{
        [[NSNotificationCenter defaultCenter] postNotificationName:VGMediaDidChangeNotification object:nil];
    });
}

#pragma mark - 前台 WebView

- (WKWebView *)activeWebView {
    NSArray *list;
    @synchronized (self.webViews) {
        list = self.webViews.allObjects;
    }
    WKWebView *best = nil;
    CGFloat bestArea = 0;
    for (WKWebView *wv in list) {
        if (!wv.window || wv.hidden || wv.alpha < 0.05) continue;
        CGRect r = [wv convertRect:wv.bounds toView:wv.window];
        if (CGRectIsEmpty(r)) continue;
        CGFloat area = r.size.width * r.size.height;
        if (area > bestArea) { bestArea = area; best = wv; }
    }
    return best;
}

#pragma mark - 悬浮 UI

- (void)attachUIForWebView:(WKWebView *)webView {
    if (!VGConfigBool(@"enabled", YES)) return;

    // 直接把悬浮层挂在 App 自己的 window 上，不再新建独立窗口
    UIWindow *win = webView.window;
    if (!win) return;

    VGOverlayController *overlay = [VGOverlayController controllerForWindow:win];
    if (!overlay) return;
    [overlay bindWebView:webView];
    [overlay showIfNeeded];
}

@end
