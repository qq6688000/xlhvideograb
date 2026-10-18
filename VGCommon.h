//
//  VGCommon.h
//  XLHVideoGrab — 悬浮抓取网页视频链接
//  适配 iOS 15+ / Dopamine 无根越狱 (/var/jb)
//

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>

typedef NS_ENUM(NSInteger, VGKind) {
    VGKindUnknown = 0,
    VGKindHLS,          // m3u8
    VGKindDASH,         // mpd
    VGKindProgressive,  // mp4 / webm / mov ...
    VGKindAudio,        // mp3 / m4a ...
    VGKindSegment,      // .ts 分片
};

@interface VGMediaItem : NSObject

@property (nonatomic, copy) NSString *url;
@property (nonatomic, copy) NSString *kindString;   // 来自 JS: hls/dash/progressive/audio/segment
@property (nonatomic, copy) NSString *source;       // 抓取来源: xhr/fetch/media.src/dom/perf/html
@property (nonatomic, copy) NSString *pageURL;      // 所在页面
@property (nonatomic, assign) NSTimeInterval addedAt;
@property (nonatomic, assign) NSInteger hits;       // 命中次数

@property (nonatomic, readonly) VGKind kind;
@property (nonatomic, readonly) NSString *kindName;
@property (nonatomic, readonly) NSInteger score;
@property (nonatomic, readonly) NSString *displayName;
@property (nonatomic, readonly) NSString *displayDetail;
@property (nonatomic, readonly) NSString *suggestedFileName;

@end

FOUNDATION_EXPORT NSString *VGJBPath(NSString *relative);
FOUNDATION_EXPORT BOOL VGConfigBool(NSString *key, BOOL fallback);
FOUNDATION_EXPORT NSString *VGConfigString(NSString *key);
FOUNDATION_EXPORT void VGConfigReload(void);

/// 按 URL 猜测媒体类型（hls/dash/audio/segment/progressive）
FOUNDATION_EXPORT NSString *VGGuessKindString(NSString *url);

/// 调试日志（写沙盒临时目录，音量上限 512KB）
FOUNDATION_EXPORT NSString *VGLogPath(void);
FOUNDATION_EXPORT void VGLogLine(NSString *line);
/// 把内存缓冲落盘（点「日志」时才调用）
FOUNDATION_EXPORT void VGLogDump(void);
