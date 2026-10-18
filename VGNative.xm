//
//  VGNative.xm
//  原生播放器抓取：抖音 / 快手 / 番茄小说 等不走 <video>，直接 hook AVFoundation
//

#import <AVFoundation/AVFoundation.h>
#import "VGCommon.h"
#import "VGManager.h"

/// 记录一条原生播放地址（去重 + 开关控制）
static void VGNoteNativeURL(NSURL *URL, NSString *source) {
    if (![URL isKindOfClass:[NSURL class]]) return;
    if (URL.isFileURL) return;

    NSString *text = URL.absoluteString;
    if (text.length < 12 || ![text hasPrefix:@"http"]) return;
    if (!VGConfigBool(@"native", YES)) return;

    static NSMutableSet *seen;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        seen = [NSMutableSet set];
    });

    @synchronized (seen) {
        if ([seen containsObject:text]) return;
        [seen addObject:text];
        if (seen.count > 1000) [seen removeAllObjects];
    }

    [[VGManager shared] ingestPayload:@{ @"url": text,
                                         @"kind": VGGuessKindString(text),
                                         @"source": source ?: @"native" }
                          fromWebView:nil];
}

%hook AVPlayerItem

- (instancetype)initWithURL:(NSURL *)URL {
    VGNoteNativeURL(URL, @"avplayer");
    return %orig;
}

- (instancetype)initWithURL:(NSURL *)URL automaticallyLoadedAssetKeys:(NSArray<NSString *> *)keys {
    VGNoteNativeURL(URL, @"avplayer");
    return %orig;
}

%end

%hook AVURLAsset

- (instancetype)initWithURL:(NSURL *)URL options:(NSDictionary<NSString *, id> *)options {
    VGNoteNativeURL(URL, @"avasset");
    return %orig;
}

%end
