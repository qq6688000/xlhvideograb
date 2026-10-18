//
//  VGDownloader.h
//  支持直链下载 + HLS(m3u8) 解析合并
//

#import <Foundation/Foundation.h>
#import "VGCommon.h"

typedef void (^VGProgressBlock)(double fraction, NSString *status);
typedef void (^VGFinishBlock)(NSURL *file, NSError *error);

@interface VGDownloader : NSObject

+ (instancetype)shared;

/// 下载一个抓取到的媒体条目；完成后回调本地文件 URL
- (void)downloadItem:(VGMediaItem *)item
            progress:(VGProgressBlock)progress
          completion:(VGFinishBlock)completion;

/// 下载目录（App 沙盒内，便于分享/另存）
+ (NSString *)downloadDirectory;

@end
