//
//  VGDownloader.m
//  直链（NSURLSession） + HLS（m3u8 解析、变体选择、分片合并）
//

#import "VGDownloader.h"
#import <UIKit/UIKit.h>

@interface VGTaskBox : NSObject
@property (nonatomic, strong) NSURLSessionDownloadTask *task;
@property (nonatomic, copy) NSString *destination;
@property (nonatomic, copy) VGProgressBlock progress;
@property (nonatomic, copy) VGFinishBlock completion;
@end

@implementation VGTaskBox
@end

@interface VGDownloader () <NSURLSessionDownloadDelegate>
@property (nonatomic, strong) NSURLSession *session;
@property (nonatomic, strong) NSMutableDictionary<NSNumber *, VGTaskBox *> *boxes;
- (void)downloadDirect:(VGMediaItem *)item progress:(VGProgressBlock)progress completion:(VGFinishBlock)completion;
- (void)downloadHLS:(VGMediaItem *)item progress:(VGProgressBlock)progress completion:(VGFinishBlock)completion;
- (void)downloadManifest:(VGMediaItem *)item progress:(VGProgressBlock)progress completion:(VGFinishBlock)completion;
- (NSData *)syncDataAtURL:(NSString *)urlString referer:(NSString *)referer error:(NSError **)outError;
- (NSString *)uniquePathForName:(NSString *)name;
- (NSError *)errorWithText:(NSString *)text;
- (void)finishOnMain:(VGFinishBlock)completion file:(NSURL *)file error:(NSError *)error;
@end

@implementation VGDownloader

+ (instancetype)shared {
    static VGDownloader *d;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ d = [VGDownloader new]; });
    return d;
}

+ (NSString *)downloadDirectory {
    NSString *dir = [NSTemporaryDirectory() stringByAppendingPathComponent:@"XLHVideoGrab"];
    [[NSFileManager defaultManager] createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:NULL];
    return dir;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        NSURLSessionConfiguration *cfg = [NSURLSessionConfiguration defaultSessionConfiguration];
        cfg.timeoutIntervalForRequest = 30;
        cfg.timeoutIntervalForResource = 3600;
        cfg.HTTPMaximumConnectionsPerHost = 4;
        cfg.waitsForConnectivity = YES;
        // 有些站点会检查 UA/Referer，这里伪装成移动 Safari
        cfg.HTTPAdditionalHeaders = @{
            @"User-Agent": @"Mozilla/5.0 (iPhone; CPU iPhone OS 16_4_1 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/16.4 Mobile/15E148 Safari/604.1",
            @"Accept": @"*/*",
        };
        _session = [NSURLSession sessionWithConfiguration:cfg delegate:self delegateQueue:nil];
        _boxes = [NSMutableDictionary dictionary];
    }
    return self;
}

#pragma mark - 入口

- (void)downloadItem:(VGMediaItem *)item progress:(VGProgressBlock)progress completion:(VGFinishBlock)completion {
    if (!item.url.length) {
        if (completion) completion(nil, [NSError errorWithDomain:@"xlhgrab" code:-1 userInfo:@{NSLocalizedDescriptionKey: @"链接为空"}]);
        return;
    }
    switch (item.kind) {
        case VGKindHLS:
            [self downloadHLS:item progress:progress completion:completion];
            break;
        case VGKindDASH:
            // mpd 解析成本高，先保存清单，交给专用工具
            [self downloadManifest:item progress:progress completion:completion];
            break;
        default:
            [self downloadDirect:item progress:progress completion:completion];
            break;
    }
}

- (NSString *)uniquePathForName:(NSString *)name {
    NSString *dir = [VGDownloader downloadDirectory];
    NSString *base = [name stringByDeletingPathExtension];
    NSString *ext = name.pathExtension;
    NSString *path = [dir stringByAppendingPathComponent:name];
    int i = 1;
    while ([[NSFileManager defaultManager] fileExistsAtPath:path]) {
        NSString *candidate = [NSString stringWithFormat:@"%@-%d.%@", base, i++, ext];
        path = [dir stringByAppendingPathComponent:candidate];
    }
    return path;
}

#pragma mark - 直链

- (void)downloadDirect:(VGMediaItem *)item progress:(VGProgressBlock)progress completion:(VGFinishBlock)completion {
    NSURL *url = [NSURL URLWithString:item.url];
    if (!url) {
        if (completion) completion(nil, [NSError errorWithDomain:@"xlhgrab" code:-2 userInfo:@{NSLocalizedDescriptionKey: @"链接格式非法"}]);
        return;
    }
    NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:url];
    if (item.pageURL.length) [req setValue:item.pageURL forHTTPHeaderField:@"Referer"];

    NSURLSessionDownloadTask *task = [self.session downloadTaskWithRequest:req];
    VGTaskBox *box = [VGTaskBox new];
    box.task = task;
    box.destination = [self uniquePathForName:item.suggestedFileName];
    box.progress = progress;
    box.completion = completion;
    @synchronized (self.boxes) {
        self.boxes[@(task.taskIdentifier)] = box;
    }
    if (progress) progress(0, [NSString stringWithFormat:@"连接 %@…", url.host ?: @""]);
    [task resume];
}

#pragma mark - 清单（mpd）

- (void)downloadManifest:(VGMediaItem *)item progress:(VGProgressBlock)progress completion:(VGFinishBlock)completion {
    if (progress) progress(-1, @"读取 DASH 清单…");
    NSURL *url = [NSURL URLWithString:item.url];
    if (!url) {
        if (completion) completion(nil, [NSError errorWithDomain:@"xlhgrab" code:-2 userInfo:@{NSLocalizedDescriptionKey: @"清单地址非法"}]);
        return;
    }
    NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:url];
    if (item.pageURL.length) [req setValue:item.pageURL forHTTPHeaderField:@"Referer"];
    NSURLSessionDataTask *task = [self.session dataTaskWithRequest:req completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        if (error || !data.length) {
            if (completion) completion(nil, error ?: [NSError errorWithDomain:@"xlhgrab" code:-3 userInfo:@{NSLocalizedDescriptionKey: @"清单下载失败"}]);
            return;
        }
        NSString *path = [self uniquePathForName:@"manifest.mpd"];
        [data writeToFile:path atomically:YES];
        dispatch_async(dispatch_get_main_queue(), ^{
            if (completion) completion([NSURL fileURLWithPath:path], nil);
        });
    }];
    [task resume];
}

#pragma mark - HLS

- (NSData *)syncDataAtURL:(NSString *)urlString referer:(NSString *)referer error:(NSError **)outError {
    NSURL *url = [NSURL URLWithString:urlString];
    if (!url) {
        if (outError) *outError = [NSError errorWithDomain:@"xlhgrab" code:-4 userInfo:@{NSLocalizedDescriptionKey: @"分片地址非法"}];
        return nil;
    }
    NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:url];
    req.timeoutInterval = 30;
    if (referer.length) [req setValue:referer forHTTPHeaderField:@"Referer"];

    __block NSData *result = nil;
    __block NSError *resultError = nil;
    dispatch_semaphore_t sem = dispatch_semaphore_create(0);
    NSURLSessionDataTask *task = [self.session dataTaskWithRequest:req completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        result = data;
        resultError = error;
        dispatch_semaphore_signal(sem);
    }];
    [task resume];
    dispatch_semaphore_wait(sem, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(40 * NSEC_PER_SEC)));
    if (outError) *outError = resultError;
    return result;
}

static NSString *VGResolve(NSString *base, NSString *relative) {
    if (!relative.length) return nil;
    if ([relative hasPrefix:@"http://"] || [relative hasPrefix:@"https://"]) return relative;
    NSURL *b = [NSURL URLWithString:base];
    NSURL *r = [NSURL URLWithString:relative relativeToURL:b];
    return r.absoluteString;
}

- (void)downloadHLS:(VGMediaItem *)item progress:(VGProgressBlock)progress completion:(VGFinishBlock)completion {
    if (progress) progress(-1, @"读取 m3u8…");
    NSString *pageURL = item.pageURL;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        NSError *error = nil;
        NSString *playlistURL = item.url;
        NSString *text = [[NSString alloc] initWithData:[self syncDataAtURL:playlistURL referer:pageURL error:&error] encoding:NSUTF8StringEncoding];
        if (!text.length) {
            [self finishOnMain:completion file:nil error:error ?: [self errorWithText:@"m3u8 读取失败"]];
            return;
        }

        // 主播放列表：挑选带宽最高的变体
        if ([text rangeOfString:@"#EXT-X-STREAM-INF"].location != NSNotFound) {
            NSString *bestURL = nil;
            NSInteger bestBandwidth = -1;
            NSArray *lines = [text componentsSeparatedByCharactersInSet:[NSCharacterSet newlineCharacterSet]];
            for (NSUInteger i = 0; i < lines.count; i++) {
                NSString *line = [lines[i] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
                if (![line hasPrefix:@"#EXT-X-STREAM-INF"]) continue;
                NSInteger bandwidth = 0;
                NSRange r = [line rangeOfString:@"BANDWIDTH="];
                if (r.location != NSNotFound) {
                    NSString *tail = [line substringFromIndex:NSMaxRange(r)];
                    NSCharacterSet *digits = [NSCharacterSet decimalDigitCharacterSet];
                    NSRange numRange = [tail rangeOfCharacterFromSet:digits];
                    if (numRange.location != NSNotFound) {
                        NSInteger end = numRange.location;
                        while (end < tail.length && [digits characterIsMember:[tail characterAtIndex:end]]) end++;
                        bandwidth = [[tail substringWithRange:NSMakeRange(numRange.location, end - numRange.location)] integerValue];
                    }
                }
                // 下一行非注释即变体地址
                for (NSUInteger j = i + 1; j < lines.count; j++) {
                    NSString *cand = [lines[j] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
                    if (!cand.length) continue;
                    if ([cand hasPrefix:@"#"]) break;
                    if (bandwidth > bestBandwidth) {
                        bestBandwidth = bandwidth;
                        bestURL = VGResolve(playlistURL, cand);
                    }
                    break;
                }
            }
            if (bestURL) {
                playlistURL = bestURL;
                text = [[NSString alloc] initWithData:[self syncDataAtURL:playlistURL referer:pageURL error:&error] encoding:NSUTF8StringEncoding];
            }
        }

        if (!text.length) {
            [self finishOnMain:completion file:nil error:error ?: [self errorWithText:@"变体播放列表读取失败"]];
            return;
        }

        // 加密流：只保存清单，交给专用下载器
        if ([text rangeOfString:@"#EXT-X-KEY" options:NSCaseInsensitiveSearch].location != NSNotFound &&
            [text rangeOfString:@"METHOD=NONE" options:NSCaseInsensitiveSearch].location == NSNotFound) {
            NSString *path = [self uniquePathForName:@"playlist.m3u8"];
            [text writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:NULL];
            [self finishOnMain:completion file:[NSURL fileURLWithPath:path] error:nil];
            return;
        }

        NSMutableArray<NSString *> *segments = [NSMutableArray array];
        NSArray *lines = [text componentsSeparatedByCharactersInSet:[NSCharacterSet newlineCharacterSet]];
        for (NSString *raw in lines) {
            NSString *line = [raw stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
            if (!line.length || [line hasPrefix:@"#"]) continue;
            NSString *resolved = VGResolve(playlistURL, line);
            if (resolved.length) [segments addObject:resolved];
        }

        if (!segments.count) {
            NSString *path = [self uniquePathForName:@"playlist.m3u8"];
            [text writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:NULL];
            [self finishOnMain:completion file:[NSURL fileURLWithPath:path] error:nil];
            return;
        }

        if (segments.count > 3000) [segments removeObjectsInRange:NSMakeRange(3000, segments.count - 3000)];

        NSString *path = [self uniquePathForName:@"video.ts"];
        [[NSFileManager defaultManager] createFileAtPath:path contents:nil attributes:nil];
        NSFileHandle *handle = [NSFileHandle fileHandleForWritingAtPath:path];
        if (!handle) {
            [self finishOnMain:completion file:nil error:[self errorWithText:@"无法创建输出文件"]];
            return;
        }

        NSUInteger total = segments.count;
        for (NSUInteger i = 0; i < total; i++) {
            NSString *seg = segments[i];
            NSData *data = [self syncDataAtURL:seg referer:pageURL error:&error];
            if (!data.length) {
                // 单分片失败重试一次
                data = [self syncDataAtURL:seg referer:pageURL error:&error];
            }
            if (data.length) {
                @try { [handle writeData:data]; } @catch (NSException *e) { break; }
            }
            double fraction = (double)(i + 1) / (double)total;
            dispatch_async(dispatch_get_main_queue(), ^{
                if (progress) progress(fraction, [NSString stringWithFormat:@"合并分片 %lu/%lu", (unsigned long)(i + 1), (unsigned long)total]);
            });
        }
        @try { [handle closeFile]; } @catch (NSException *e) {}

        unsigned long long size = [[[NSFileManager defaultManager] attributesOfItemAtPath:path error:NULL] fileSize];
        if (size < 1024) {
            [[NSFileManager defaultManager] removeItemAtPath:path error:NULL];
            [self finishOnMain:completion file:nil error:[self errorWithText:@"分片全部下载失败"]];
            return;
        }
        [self finishOnMain:completion file:[NSURL fileURLWithPath:path] error:nil];
    });
}

- (NSError *)errorWithText:(NSString *)text {
    return [NSError errorWithDomain:@"xlhgrab" code:-10 userInfo:@{NSLocalizedDescriptionKey: text}];
}

- (void)finishOnMain:(VGFinishBlock)completion file:(NSURL *)file error:(NSError *)error {
    dispatch_async(dispatch_get_main_queue(), ^{
        if (completion) completion(file, error);
    });
}

#pragma mark - NSURLSessionDownloadDelegate

- (void)URLSession:(NSURLSession *)session downloadTask:(NSURLSessionDownloadTask *)downloadTask
didFinishDownloadingToURL:(NSURL *)location {
    VGTaskBox *box;
    @synchronized (self.boxes) {
        box = self.boxes[@(downloadTask.taskIdentifier)];
        [self.boxes removeObjectForKey:@(downloadTask.taskIdentifier)];
    }
    if (!box) return;

    // 在代理回调返回前必须把临时文件搬走
    NSString *dest = box.destination;
    [[NSFileManager defaultManager] removeItemAtPath:dest error:NULL];
    NSError *moveError = nil;
    [[NSFileManager defaultManager] moveItemAtURL:location toURL:[NSURL fileURLWithPath:dest] error:&moveError];
    if (moveError) {
        [self finishOnMain:box.completion file:nil error:moveError];
        return;
    }
    [self finishOnMain:box.completion file:[NSURL fileURLWithPath:dest] error:nil];
}

- (void)URLSession:(NSURLSession *)session downloadTask:(NSURLSessionDownloadTask *)downloadTask
      didWriteData:(int64_t)bytesWritten
 totalBytesWritten:(int64_t)totalBytesWritten
totalBytesExpectedToWrite:(int64_t)totalBytesExpectedToWrite {
    VGTaskBox *box;
    @synchronized (self.boxes) {
        box = self.boxes[@(downloadTask.taskIdentifier)];
    }
    if (!box.progress) return;
    double fraction = totalBytesExpectedToWrite > 0 ? (double)totalBytesWritten / (double)totalBytesExpectedToWrite : -1;
    NSString *status;
    if (totalBytesExpectedToWrite > 0) {
        status = [NSString stringWithFormat:@"%@ / %@",
                  [NSByteCountFormatter stringFromByteCount:totalBytesWritten countStyle:NSByteCountFormatterCountStyleFile],
                  [NSByteCountFormatter stringFromByteCount:totalBytesExpectedToWrite countStyle:NSByteCountFormatterCountStyleFile]];
    } else {
        status = [NSString stringWithFormat:@"已下载 %@",
                  [NSByteCountFormatter stringFromByteCount:totalBytesWritten countStyle:NSByteCountFormatterCountStyleFile]];
    }
    box.progress(fraction, status);
}

- (void)URLSession:(NSURLSession *)session task:(NSURLSessionTask *)task didCompleteWithError:(NSError *)error {
    if (!error) return;
    VGTaskBox *box;
    @synchronized (self.boxes) {
        box = self.boxes[@(task.taskIdentifier)];
        [self.boxes removeObjectForKey:@(task.taskIdentifier)];
    }
    if (box) [self finishOnMain:box.completion file:nil error:error];
}

@end
