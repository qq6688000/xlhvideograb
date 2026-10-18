//
//  VGNative.xm
//  原生播放器抓取（保守版）
//
//  1.4.0 起不再扫描/篡改未知类 —— 上一版在抖音这类大型 App 里
//  swizzle 上百个陌生方法，是闪退的直接原因。
//  现在只挂钩 AVFoundation 的公开入口，全部包 @try，默认关闭。
//

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <AVFoundation/AVFoundation.h>
#import <AVKit/AVKit.h>

#import "VGCommon.h"
#import "VGManager.h"

#pragma mark - 记录

static BOOL VGNativeEnabled(void) {
    return VGConfigBool(@"native", NO);   // 默认关闭，需 xlgrab native on
}

static void VGRecordURL(id value, NSString *source) {
    @try {
        if (!VGNativeEnabled()) return;

        NSString *s = nil;
        if ([value isKindOfClass:[NSURL class]]) {
            s = [(NSURL *)value absoluteString];
        } else if ([value isKindOfClass:[NSString class]]) {
            s = (NSString *)value;
        }
        if (s.length < 24) return;

        NSString *lower = s.lowercaseString;
        BOOL isLocal = [lower hasPrefix:@"file://"];
        if (![lower hasPrefix:@"http"] && !isLocal) return;

        BOOL media = [lower containsString:@".mp4"]
                  || [lower containsString:@".m3u8"]
                  || [lower containsString:@".mpd"]
                  || [lower containsString:@".m4a"]
                  || [lower containsString:@".mp3"]
                  || [lower containsString:@".ts?"]
                  || [lower containsString:@"mime_type=video"]
                  || [lower containsString:@"/video/tos"]
                  || [lower containsString:@"/video/"];
        if (!media) return;

        NSString *kind = VGGuessKindString(s);
        // 只进内存环形缓冲，热路径不碰磁盘
        VGLogLine([NSString stringWithFormat:@"[%@] %@", source ?: @"native", s]);

        [[VGManager shared] countNativeProbe];
        [[VGManager shared] ingestPayload:@{ @"url": s,
                                             @"kind": kind ?: @"progressive",
                                             @"source": source ?: @"native" }
                              fromWebView:nil];
    } @catch (__unused NSException *e) {
        // 抓取失败绝不能影响 App 本身
    }
}

static void VGRecordAsset(AVAsset *asset, NSString *source) {
    @try {
        if ([asset isKindOfClass:[AVURLAsset class]]) {
            VGRecordURL([(AVURLAsset *)asset URL], source);
        }
    } @catch (__unused NSException *e) {
    }
}

#pragma mark - AVFoundation 钩子

%group VGAVHooks

%hook AVURLAsset

+ (instancetype)URLAssetWithURL:(NSURL *)URL options:(NSDictionary *)options {
    VGRecordURL(URL, @"AVURLAsset+");
    return %orig;
}

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
    VGRecordAsset(asset, @"AVPlayerItem.asset");
    return %orig;
}

+ (instancetype)playerItemWithURL:(NSURL *)URL {
    VGRecordURL(URL, @"AVPlayerItem+");
    return %orig;
}

+ (instancetype)playerItemWithAsset:(AVAsset *)asset {
    VGRecordAsset(asset, @"AVPlayerItem.asset+");
    return %orig;
}

%end

%hook AVPlayer

- (void)replaceCurrentItemWithPlayerItem:(AVPlayerItem *)item {
    VGRecordAsset(item.asset, @"AVPlayer");
    %orig;
}

- (void)setCurrentItem:(AVPlayerItem *)item {
    VGRecordAsset(item.asset, @"AVPlayer.setCurrentItem");
    %orig;
}

%end

%hook AVPlayerViewController

- (void)setPlayer:(AVPlayer *)player {
    VGRecordAsset(player.currentItem.asset, @"AVPlayerVC");
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

%ctor {
    @autoreleasepool {
        %init(VGAVHooks);
        %init(VGNetHooks);
    }
}
