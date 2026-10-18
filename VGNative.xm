//
//  VGNative.xm
//  原生播放器抓取
//
//  1.9.0 起：记录**永远开启**，与「是否显示悬浮球」彻底解耦。
//  1.4.0 的错误是把两者塞进同一个 native 开关（默认 NO），
//  导致钩子装上了但每次记录都在第一行 return，表现为 items=0。
//
//  只挂钩 AVFoundation 公开入口，全部包 @try，绝不改动未知私有类。
//

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <AVFoundation/AVFoundation.h>
#import <AVKit/AVKit.h>

#import "VGCommon.h"
#import "VGManager.h"

#pragma mark - 判定

/// 网络兜底钩子较重，单独开关（默认关闭），AV 钩子不受影响
static BOOL VGNetHooksEnabled(void) {
    return VGConfigBool(@"net", NO);
}

static BOOL VGLooksLikeMedia(NSString *s) {
    NSString *lower = s.lowercaseString;

    // 交给 AVPlayer 的本地文件一定是媒体，不看扩展名
    // （Telegram 缓存文件名常常是哈希，没有后缀）
    if ([lower hasPrefix:@"file://"]) return YES;
    if (![lower hasPrefix:@"http"]) return NO;

    return [lower containsString:@".mp4"]
        || [lower containsString:@".m3u8"]
        || [lower containsString:@".mpd"]
        || [lower containsString:@".m4a"]
        || [lower containsString:@".mp3"]
        || [lower containsString:@".mov?"]
        || [lower containsString:@".ts?"]
        || [lower containsString:@"mime_type=video"]
        || [lower containsString:@"/video/tos"]
        || [lower containsString:@"/video/"];
}

#pragma mark - 记录

static void VGRecordURL(id value, NSString *source) {
    @try {
        NSString *s = nil;
        if ([value isKindOfClass:[NSURL class]]) {
            s = [(NSURL *)value absoluteString];
        } else if ([value isKindOfClass:[NSString class]]) {
            s = (NSString *)value;
        }
        if (s.length < 12) return;
        if (!VGLooksLikeMedia(s)) return;

        NSString *kind = VGIsLocalFileURL(s) ? @"local" : (VGGuessKindString(s) ?: @"progressive");

        // 只进内存环形缓冲，热路径不碰磁盘
        VGLogLine([NSString stringWithFormat:@"[%@] %@", source ?: @"native", s]);

        [[VGManager shared] countNativeProbe];
        [[VGManager shared] ingestPayload:@{ @"url": s,
                                             @"kind": kind,
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
        } else if (asset) {
            // 组合资产：把各段都试一遍
            for (AVAssetTrack *t in asset.tracks) {
                (void)t;
            }
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
    VGRecordAsset(asset, @"AVPlayerItem");
    return %orig;
}

- (instancetype)initWithAsset:(AVAsset *)asset automaticallyLoadedAssetKeys:(NSArray *)keys {
    VGRecordAsset(asset, @"AVPlayerItem.autoKeys");
    return %orig;
}

+ (instancetype)playerItemWithURL:(NSURL *)URL {
    VGRecordURL(URL, @"AVPlayerItem+");
    return %orig;
}

+ (instancetype)playerItemWithAsset:(AVAsset *)asset {
    VGRecordAsset(asset, @"AVPlayerItem+");
    return %orig;
}

+ (instancetype)playerItemWithAsset:(AVAsset *)asset automaticallyLoadedAssetKeys:(NSArray *)keys {
    VGRecordAsset(asset, @"AVPlayerItem+.autoKeys");
    return %orig;
}

%end

%hook AVPlayer

+ (instancetype)playerWithPlayerItem:(AVPlayerItem *)item {
    VGRecordAsset(item.asset, @"AVPlayer+");
    return %orig;
}

+ (instancetype)playerWithURL:(NSURL *)URL {
    VGRecordURL(URL, @"AVPlayer+");
    return %orig;
}

- (void)replaceCurrentItemWithPlayerItem:(AVPlayerItem *)item {
    VGRecordAsset(item.asset, @"AVPlayer");
    %orig;
}

- (void)setCurrentItem:(AVPlayerItem *)item {
    VGRecordAsset(item.asset, @"AVPlayer");
    %orig;
}

%end

%hook AVQueuePlayer

- (instancetype)initWithItems:(NSArray *)items {
    for (AVPlayerItem *it in items) {
        @try { VGRecordAsset(it.asset, @"AVQueuePlayer"); } @catch (__unused NSException *e) {}
    }
    return %orig;
}

- (void)insertItem:(AVPlayerItem *)item afterItem:(AVPlayerItem *)afterItem {
    VGRecordAsset(item.asset, @"AVQueuePlayer");
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

#pragma mark - 网络兜底（默认关闭，xlgrab net on 打开）

%group VGNetHooks

%hook __NSCFURLSession

- (id)dataTaskWithURL:(NSURL *)url {
    if (VGNetHooksEnabled()) VGRecordURL(url, @"NSURLSession");
    return %orig;
}

- (id)dataTaskWithRequest:(NSURLRequest *)request {
    if (VGNetHooksEnabled()) VGRecordURL(request.URL, @"NSURLSession");
    return %orig;
}

%end

%end

%ctor {
    @autoreleasepool {
        %init(VGAVHooks);
        %init(VGNetHooks);
        VGLogLine(@"\u5bfc\u5165 %@: AV \u94a9\u5b50\u5df2\u5b89\u88c5, net=%@", XLH_VERSION, (VGConfigBool(@"net", NO) ? @"on" : @"off"));
    }
}
