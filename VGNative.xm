//
//  VGNative.xm
//  原生播放器抓取：AVFoundation + 运行时嗅探（抖音/番茄小说这类自带播放内核的 App）
//

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <AVFoundation/AVFoundation.h>
#import <objc/runtime.h>

#import "VGCommon.h"
#import "VGManager.h"

#pragma mark - 记录

static void VGRecordURL(id value, NSString *source) {
    NSString *s = nil;
    if ([value isKindOfClass:[NSURL class]]) {
        s = [(NSURL *)value absoluteString];
    } else if ([value isKindOfClass:[NSString class]]) {
        s = (NSString *)value;
    }
    if (s.length < 24) return;

    NSString *lower = s.lowercaseString;
    if (![lower hasPrefix:@"http"]) return;

    BOOL media = [lower containsString:@".mp4"]
              || [lower containsString:@".m3u8"]
              || [lower containsString:@".mpd"]
              || [lower containsString:@".m4a"]
              || [lower containsString:@".mp3"]
              || [lower containsString:@".ts?"]
              || [lower containsString:@"mime_type=video"]
              || [lower containsString:@"/video/tos"]
              || [lower containsString:@"/video/"]
              || [lower containsString:@"video_id="];
    if (!media) return;

    NSString *kind = VGGuessKindString(s);
    VGLogLine([NSString stringWithFormat:@"[%@] %@", source ?: @"native", s]);

    [[VGManager shared] countNativeProbe];
    dispatch_async(dispatch_get_main_queue(), ^{
        [[VGManager shared] ingestPayload:@{ @"url": s,
                                             @"kind": kind ?: @"progressive",
                                             @"source": source ?: @"native" }
                              fromWebView:nil];
    });
}

#pragma mark - 运行时嗅探

static NSMutableSet *gVGKeys = nil;
static BOOL gVGScanned = NO;

static BOOL VGNameIsNoise(NSString *name) {
    static NSArray *prefixes = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        prefixes = @[ @"AV", @"NS", @"UI", @"WK", @"CA", @"MTL", @"SK", @"VT", @"PH",
                      @"Q", @"_", @"Web", @"Core", @"IOSurface", @"CM", @"RP" ];
    });
    for (NSString *p in prefixes) {
        if ([name hasPrefix:p]) return YES;
    }
    return NO;
}

static BOOL VGNameLooksLikePlayer(NSString *name) {
    static NSArray *keys = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        keys = @[ @"video", @"player", @"engine", @"media", @"stream", @"aweme", @"ttnet" ];
    });
    NSString *lower = name.lowercaseString;
    for (NSString *k in keys) {
        if ([lower containsString:k]) return YES;
    }
    return NO;
}

static void VGInstallSniffer(Class cls) {
    NSString *cname = NSStringFromClass(cls);
    unsigned int count = 0;
    Method *methods = class_copyMethodList(cls, &count);
    if (!methods) return;

    for (unsigned int i = 0; i < count; i++) {
        Method m = methods[i];
        SEL sel = method_getName(m);
        NSString *sname = NSStringFromSelector(sel);
        NSString *lower = sname.lowercaseString;

        // 只看名字里带 url / uri 的方法
        if (!([lower containsString:@"url"] || [lower containsString:@"uri"])) continue;

        // 只动「返回 void、恰好一个对象参数」的方法，避免破坏返回值约定
        const char *types = method_getTypeEncoding(m);
        if (!types || types[0] != 'v') continue;
        if (method_getNumberOfArguments(m) != 3) continue;
        char argType[8] = {0};
        method_getArgumentType(m, 2, argType, sizeof(argType));
        if (argType[0] != '@') continue;

        NSString *key = [NSString stringWithFormat:@"%@|%@", cname, sname];
        if ([gVGKeys containsObject:key]) continue;
        [gVGKeys addObject:key];

        IMP origImp = method_getImplementation(m);
        if (!origImp) continue;

        NSString *source = [NSString stringWithFormat:@"%@.%@", cname, sname];
        IMP newImp = imp_implementationWithBlock(^(id obj, SEL cmd, id arg) {
            VGRecordURL(arg, source);
            ((void (*)(id, SEL, id))origImp)(obj, cmd, arg);
        });
        if (!newImp) continue;
        method_setImplementation(m, newImp);
    }
    free(methods);
}

static void VGScanPlayers(void) {
    if (gVGScanned) return;
    gVGScanned = YES;

    int total = objc_getClassList(NULL, 0);
    if (total <= 0) return;

    Class *classes = (Class *)malloc(sizeof(Class) * (size_t)total);
    if (!classes) return;
    total = objc_getClassList(classes, total);

    int candidates = 0;
    for (int i = 0; i < total; i++) {
        Class c = classes[i];
        NSString *name = NSStringFromClass(c);
        if (!name.length) continue;
        if (VGNameIsNoise(name)) continue;
        if (!VGNameLooksLikePlayer(name)) continue;

        candidates++;
        VGInstallSniffer(c);
    }
    free(classes);

    VGLogLine([NSString stringWithFormat:@"扫描完成：共 %d 个类，候选 %d 个，挂钩 %lu 个方法",
               total, candidates, (unsigned long)gVGKeys.count]);
}

#pragma mark - AVFoundation 钩子

%group VGAVHooks

%hook AVURLAsset

- (instancetype)initWithURL:(NSURL *)URL options:(NSDictionary *)options {
    VGRecordURL(URL, @"AVURLAsset");
    return %orig;
}

%end

%hook AVPlayerItem

- (instancetype)initWithURL:(NSURL *)URL {
    VGRecordURL(URL, @"AVPlayerItem");
    return %orig;
}

- (instancetype)initWithAsset:(AVAsset *)asset {
    if ([asset isKindOfClass:[AVURLAsset class]]) {
        VGRecordURL([(AVURLAsset *)asset URL], @"AVPlayerItem.asset");
    }
    return %orig;
}

%end

%hook AVPlayer

- (void)replaceCurrentItemWithPlayerItem:(AVPlayerItem *)item {
    AVAsset *asset = item.asset;
    if ([asset isKindOfClass:[AVURLAsset class]]) {
        VGRecordURL([(AVURLAsset *)asset URL], @"AVPlayer");
    }
    %orig;
}

%end

%end

#pragma mark - 网络兜底

%group VGNetHooks

%hook __NSCFURLSession

- (id)dataTaskWithURL:(NSURL *)url {
    VGRecordURL(url, @"NSURLSession");
    return %orig;
}

- (id)dataTaskWithRequest:(NSURLRequest *)request {
    VGRecordURL(request.URL, @"NSURLSession");
    return %orig;
}

%end

%end

#pragma mark - 生命周期

static void VGInstallObservers(void) {
    [[NSNotificationCenter defaultCenter] addObserverForName:UIApplicationDidBecomeActiveNotification
                                                      object:nil
                                                       queue:[NSOperationQueue mainQueue]
                                                  usingBlock:^(NSNotification *note) {
        (void)note;
        // 类在启动后才陆续加载，延迟扫一次即可
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.5 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            VGScanPlayers();
        });
    }];
}

%ctor {
    @autoreleasepool {
        %init(VGAVHooks);
        %init(VGNetHooks);

        gVGKeys = [NSMutableSet set];

        dispatch_async(dispatch_get_main_queue(), ^{
            VGInstallObservers();
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.5 * NSEC_PER_SEC)),
                           dispatch_get_main_queue(), ^{
                VGScanPlayers();
            });
        });
    }
}
