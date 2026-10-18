//
//  VGNative.xm
//  原生播放器抓取：抖音 / 快手 / 番茄小说 等不走 <video>，直接 hook AVFoundation
//
//  抖音这类 App 有自己的播放引擎（TTVideoEngine），它不一定用
//  -[AVPlayerItem initWithURL:]，而是先建 AVURLAsset 再包装成 item，
//  甚至走 NSURLSession 预下载。所以这里把能拿到 URL 的入口全部挂上。
//

#import <AVFoundation/AVFoundation.h>
#import <AVKit/AVKit.h>
#import "VGCommon.h"
#import "VGManager.h"

#pragma mark - 采集

static void VGCaptureURL(NSURL *URL, NSString *source);

/// 可能是媒体地址？（用于 NSURLSession / NSURLConnection 这类高频入口，避免刷屏）
static BOOL VGMediaLike(NSURL *URL) {
    if (![URL isKindOfClass:[NSURL class]]) return NO;
    NSString *s = URL.absoluteString.lowercaseString;
    if (s.length < 16 || ![s hasPrefix:@"http"]) return NO;

    static NSArray<NSString *> *keys;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        keys = @[ @".m3u8", @".mp4", @".mpd", @".m4a", @".mp3", @".flv",
                  @"/video/", @"/play/", @"videoplay", @".ts?", @"/stream/",
                  @"mime_type=video", @"format=mp4" ];
    });
    for (NSString *k in keys) {
        if ([s containsString:k]) return YES;
    }
    return NO;
}

/// 从 AVAsset 里掏 URL（组合资源掏不到，返回 nil）
static void VGCaptureAsset(AVAsset *asset, NSString *source) {
    if ([asset isKindOfClass:[AVURLAsset class]]) {
        VGCaptureURL(((AVURLAsset *)asset).URL, source);
    }
}

static void VGCaptureURL(NSURL *URL, NSString *source) {
    if (![URL isKindOfClass:[NSURL class]]) return;
    if (URL.isFileURL) return;

    [[VGManager shared] countNativeProbe];

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
        if (seen.count > 1200) [seen removeAllObjects];
    }

    [[VGManager shared] ingestPayload:@{ @"url": text,
                                         @"kind": VGGuessKindString(text),
                                         @"source": source ?: @"native" }
                          fromWebView:nil];
}

#pragma mark - AVAsset

%hook AVURLAsset

+ (instancetype)URLAssetWithURL:(NSURL *)URL options:(NSDictionary<NSString *, id> *)options {
    VGCaptureURL(URL, @"asset+");
    return %orig;
}

- (instancetype)initWithURL:(NSURL *)URL options:(NSDictionary<NSString *, id> *)options {
    VGCaptureURL(URL, @"asset");
    return %orig;
}

%end

#pragma mark - AVPlayerItem

%hook AVPlayerItem

- (instancetype)initWithURL:(NSURL *)URL {
    VGCaptureURL(URL, @"item");
    return %orig;
}

- (instancetype)initWithURL:(NSURL *)URL automaticallyLoadedAssetKeys:(NSArray<NSString *> *)keys {
    VGCaptureURL(URL, @"item");
    return %orig;
}

- (instancetype)initWithAsset:(AVAsset *)asset {
    VGCaptureAsset(asset, @"item-asset");
    return %orig;
}

- (instancetype)initWithAsset:(AVAsset *)asset automaticallyLoadedAssetKeys:(NSArray<NSString *> *)keys {
    VGCaptureAsset(asset, @"item-asset");
    return %orig;
}

+ (instancetype)playerItemWithURL:(NSURL *)URL {
    VGCaptureURL(URL, @"item+");
    return %orig;
}

+ (instancetype)playerItemWithAsset:(AVAsset *)asset {
    VGCaptureAsset(asset, @"item-asset+");
    return %orig;
}

+ (instancetype)playerItemWithAsset:(AVAsset *)asset automaticallyLoadedAssetKeys:(NSArray<NSString *> *)keys {
    VGCaptureAsset(asset, @"item-asset+");
    return %orig;
}

%end

#pragma mark - AVPlayer

%hook AVPlayer

- (void)replaceCurrentItemWithPlayerItem:(AVPlayerItem *)item {
    VGCaptureAsset(item.asset, @"player");
    %orig;
}

- (void)setCurrentItem:(AVPlayerItem *)item {
    VGCaptureAsset(item.asset, @"player");
    %orig;
}

%end

#pragma mark - AVPlayerViewController

%hook AVPlayerViewController

- (void)setPlayer:(AVPlayer *)player {
    VGCaptureAsset(player.currentItem.asset, @"avpvc");
    %orig;
}

%end

#pragma mark - 网络层兜底

@interface __NSCFURLSession : NSURLSession
@end

@interface __NSCFURLConnection : NSURLConnection
@end

%hook __NSCFURLSession

- (NSURLSessionDataTask *)dataTaskWithURL:(NSURL *)url {
    if (VGMediaLike(url)) VGCaptureURL(url, @"session");
    return %orig;
}

- (NSURLSessionDataTask *)dataTaskWithRequest:(NSURLRequest *)request {
    if (VGMediaLike(request.URL)) VGCaptureURL(request.URL, @"session");
    return %orig;
}

- (NSURLSessionDownloadTask *)downloadTaskWithURL:(NSURL *)url {
    if (VGMediaLike(url)) VGCaptureURL(url, @"session");
    return %orig;
}

- (NSURLSessionDownloadTask *)downloadTaskWithRequest:(NSURLRequest *)request {
    if (VGMediaLike(request.URL)) VGCaptureURL(request.URL, @"session");
    return %orig;
}

%end

%hook __NSCFURLConnection

- (instancetype)initWithRequest:(NSURLRequest *)request delegate:(id)delegate startImmediately:(BOOL)startImmediately {
    if (VGMediaLike(request.URL)) VGCaptureURL(request.URL, @"connection");
    return %orig;
}

%end
