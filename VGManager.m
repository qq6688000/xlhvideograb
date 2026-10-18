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
- (void)scanSandboxMediaIfNeeded;
+ (NSArray<NSDictionary *> *)scanMediaFilesInSandbox;
- (NSArray<VGMediaItem *> *)sortedItems;
- (void)clearItems;
- (void)attachUIForWebView:(WKWebView *)webView;
- (void)onAppActive;
- (UIWindow *)keyWindow;
@property (nonatomic, assign, readwrite) NSInteger nativeProbes;
@property (nonatomic, assign) NSTimeInterval lastSandboxScan;
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

    // 抖音 / 番茄小说这类 App 没有可用的 WKWebView，也要挂上悬浮球
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(onAppActive)
                                                 name:UIApplicationDidBecomeActiveNotification
                                               object:nil];
}

- (void)onAppActive {
    NSArray *delays = @[@0.6, @2.0, @5.0];
    for (NSNumber *d in delays) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(d.doubleValue * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            [self attachUIForWebView:[self activeWebView]];
        });
    }
}

- (void)countNativeProbe {
    dispatch_async(dispatch_get_main_queue(), ^{
        self.nativeProbes = self.nativeProbes + 1;
    });
}

- (UIWindow *)keyWindow {
    UIWindow *fallback = nil;
    for (UIScene *scene in [UIApplication sharedApplication].connectedScenes) {
        if (![scene isKindOfClass:[UIWindowScene class]]) continue;
        for (UIWindow *w in ((UIWindowScene *)scene).windows) {
            if (w.hidden) continue;
            if (w.isKeyWindow) return w;
            if (!fallback && w.windowLevel == UIWindowLevelNormal) fallback = w;
        }
    }
    return fallback;
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
    // http(s) 走网络下载；file:// 是 App 沙盒内的本地视频（如 Telegram 缓存），走导出
    BOOL isLocal = [url hasPrefix:@"file://"];
    if (![url hasPrefix:@"http"] && !isLocal) return;

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

#pragma mark - 沙盒媒体扫描（原生 App 不走 AVPlayer 时的兜底）

- (void)scanSandboxMediaIfNeeded {
    NSTimeInterval now = [NSDate date].timeIntervalSince1970;
    if (now - self.lastSandboxScan < 5.0) return;
    self.lastSandboxScan = now;

    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        NSArray<NSDictionary *> *found = [[self class] scanMediaFilesInSandbox];
        VGLogLine([NSString stringWithFormat:@"[sandbox] 扫描完成，命中 %lu 条", (unsigned long)found.count]);
        for (NSUInteger i = 0; i < found.count && i < 5; i++) {
            VGLogLine([NSString stringWithFormat:@"[sandbox] %@ %@", found[i][@"kind"], found[i][@"url"]]);
        }
        if (!found.count) return;
        dispatch_async(dispatch_get_main_queue(), ^{
            for (NSDictionary *f in found) {
                [self ingestPayload:@{@"url": f[@"url"], @"kind": f[@"kind"], @"source": @"sandbox"}
                        fromWebView:nil];
            }
        });
    });
}

static NSString *VGDetectKindByMagic(NSString *path) {
    @try {
        NSFileHandle *fh = [NSFileHandle fileHandleForReadingAtPath:path];
        if (!fh) return nil;
        NSData *head = [fh readDataOfLength:16];
        [fh closeFile];
        if (head.length < 4) return nil;
        const uint8_t *b = (const uint8_t *)head.bytes;
        if (head.length >= 8 && memcmp(b + 4, "ftyp", 4) == 0) return @"progressive";
        if (memcmp(b, "ID3", 3) == 0) return @"audio";
        if (b[0] == 0xFF && (b[1] & 0xE0) == 0xE0) return @"audio";
        if (memcmp(b, "fLaC", 4) == 0) return @"audio";
        if (memcmp(b, "OggS", 4) == 0) return @"audio";
        if (head.length >= 12 && memcmp(b, "RIFF", 4) == 0 && memcmp(b + 8, "WAVE", 4) == 0) return @"audio";
        return nil;
    } @catch (__unused NSException *e) {
        return nil;
    }
}

+ (NSArray<NSDictionary *> *)scanMediaFilesInSandbox {
    static NSSet *videoExts = nil;
    static NSSet *audioExts = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        videoExts = [NSSet setWithArray:@[@"mp4", @"mov", @"m4v", @"mkv", @"webm", @"flv", @"3gp"]];
        audioExts = [NSSet setWithArray:@[@"mp3", @"m4a", @"aac", @"flac", @"ogg", @"wav"]];
    });

    NSMutableArray<NSString *> *roots = [NSMutableArray array];
    NSString *home = NSHomeDirectory();
    NSString *tmp = NSTemporaryDirectory();
    if (tmp.length) [roots addObject:tmp];
    if (home.length) {
        [roots addObject:[home stringByAppendingPathComponent:@"Library/Caches"]];
        [roots addObject:[home stringByAppendingPathComponent:@"Library/Application Support"]];
        [roots addObject:[home stringByAppendingPathComponent:@"Documents"]];
        [roots addObject:[home stringByAppendingPathComponent:@"tmp"]];
    }
    // App Group 共享容器（Telegram 媒体常存在这里）
    NSFileManager *fm = [NSFileManager defaultManager];
    NSString *appGroupRoot = @"/var/mobile/Containers/Shared/AppGroup";
    if ([fm fileExistsAtPath:appGroupRoot]) {
        [roots addObject:appGroupRoot];
    }

    VGLogLine([NSString stringWithFormat:@"[sandbox] home=%@ roots=%lu", home ?: @"?", (unsigned long)roots.count]);

    NSTimeInterval cutoff = [NSDate date].timeIntervalSince1970 - 86400.0;
    NSMutableArray<NSDictionary *> *hits = [NSMutableArray array];
    // 诊断：记录每个 root 下最近修改的文件（任意类型），最多 3 条
    NSMutableArray<NSDictionary *> *recentAny = [NSMutableArray array];

    for (NSString *root in roots) {
        if (![fm fileExistsAtPath:root]) continue;
        NSDirectoryEnumerator *en = [fm enumeratorAtPath:root];
        for (NSString *rel in en) {
            NSString *full = [root stringByAppendingPathComponent:rel];
            NSDictionary *attrs = [fm attributesOfItemAtPath:full error:nil];
            if (!attrs) continue;
            if ([attrs[NSFileType] isEqual:NSFileTypeDirectory]) continue;
            unsigned long long size = [attrs[NSFileSize] unsignedLongLongValue];
            if (size < 100 * 1024) continue;
            NSDate *mtime = attrs[NSFileModificationDate];
            if (mtime.timeIntervalSince1970 < cutoff) continue;

            // 诊断用：记录近期文件（不区分扩展名）
            if (recentAny.count < 8) {
                [recentAny addObject:@{@"path": full, @"size": @(size), @"mtime": mtime}];
            }

            NSString *ext = rel.pathExtension.lowercaseString;
            NSString *kind = nil;
            if ([videoExts containsObject:ext]) kind = @"progressive";
            else if ([audioExts containsObject:ext]) kind = @"audio";
            else {
                // 无扩展名或未知扩展名：读文件头魔数
                kind = VGDetectKindByMagic(full);
            }
            if (!kind) continue;

            NSString *fileURL = [NSURL fileURLWithPath:full].absoluteString;
            if (!fileURL.length) continue;
            [hits addObject:@{@"url": fileURL,
                              @"kind": kind,
                              @"size": @(size),
                              @"mtime": mtime}];
            if (hits.count >= 400) break;
        }
        if (hits.count >= 400) break;
    }

    // 诊断输出
    [recentAny sortUsingComparator:^NSComparisonResult(NSDictionary *a, NSDictionary *b) {
        return [(NSDate *)b[@"mtime"] compare:(NSDate *)a[@"mtime"]];
    }];
    for (NSUInteger i = 0; i < recentAny.count && i < 5; i++) {
        NSDictionary *r = recentAny[i];
        VGLogLine([NSString stringWithFormat:@"[sandbox-recent] %@ (%llu B)",
                   r[@"path"], [r[@"size"] unsignedLongLongValue]]);
    }

    [hits sortUsingComparator:^NSComparisonResult(NSDictionary *a, NSDictionary *b) {
        return [(NSDate *)b[@"mtime"] compare:(NSDate *)a[@"mtime"]];
    }];
    if (hits.count > 60) return [hits subarrayWithRange:NSMakeRange(0, 60)];
    return hits;
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
    UIWindow *win = webView.window ?: [self keyWindow];
    if (!win || win.hidden) return;
    if (win.windowLevel != UIWindowLevelNormal) return;

    // 没有 WebView 的 App：默认不挂（避免挡触控）；
    // 例外是 Telegram 系——它走标准 AVPlayer，风险低，默认允许出球
    if (!webView && !VGConfigBool(@"native", NO) && !VGIsTelegramBundle()) return;

    VGLogLine([NSString stringWithFormat:@"[attach] win=%@ level=%.0f webview=%@",
               NSStringFromClass([win class]), win.windowLevel, webView ? @"y" : @"n"]);

    VGOverlayController *overlay = [VGOverlayController controllerForWindow:win];
    if (!overlay) return;
    if (webView) [overlay bindWebView:webView];
    [overlay showIfNeeded];
}

@end
