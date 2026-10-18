//
//  VGCommon.m
//

#import "VGCommon.h"
#import <objc/runtime.h>

#pragma mark - 越狱根路径

NSString *VGJBPath(NSString *relative) {
    static NSString *root = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        root = [[NSFileManager defaultManager] fileExistsAtPath:@"/var/jb"] ? @"/var/jb" : @"";
    });
    if (!relative.length) return root.length ? root : @"/";
    return [root stringByAppendingPathComponent:relative];
}

#pragma mark - 配置（纯文本，方便 shell 直接改）

static NSString *VGConfigDir(void) {
    return @"/var/mobile/Library/Preferences/xlhgrab";
}

static NSMutableDictionary *sCache = nil;
static NSTimeInterval sCacheTime = 0;

void VGConfigReload(void) {
    sCache = [NSMutableDictionary dictionary];
    sCacheTime = [NSDate date].timeIntervalSince1970;
}

static NSString *VGConfigRaw(NSString *key) {
    NSTimeInterval now = [NSDate date].timeIntervalSince1970;
    if (!sCache || now - sCacheTime > 2.0) VGConfigReload();
    NSString *cached = sCache[key];
    if (cached) return cached;
    NSString *path = [VGConfigDir() stringByAppendingPathComponent:key];
    NSString *value = [NSString stringWithContentsOfFile:path encoding:NSUTF8StringEncoding error:NULL];
    value = [value stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (!value) value = @"";
    sCache[key] = value;
    return value;
}

BOOL VGConfigBool(NSString *key, BOOL fallback) {
    NSString *raw = VGConfigRaw(key);
    if (!raw.length) return fallback;
    NSString *low = raw.lowercaseString;
    if ([low isEqualToString:@"0"] || [low isEqualToString:@"no"] || [low isEqualToString:@"false"] || [low isEqualToString:@"off"])
        return NO;
    if ([low isEqualToString:@"1"] || [low isEqualToString:@"yes"] || [low isEqualToString:@"true"] || [low isEqualToString:@"on"])
        return YES;
    return fallback;
}

NSString *VGConfigString(NSString *key) {
    return VGConfigRaw(key) ?: @"";
}

#pragma mark - VGMediaItem

@implementation VGMediaItem

- (VGKind)kind {
    NSString *k = self.kindString.lowercaseString;
    if ([k isEqualToString:@"hls"]) return VGKindHLS;
    if ([k isEqualToString:@"dash"]) return VGKindDASH;
    if ([k isEqualToString:@"progressive"]) return VGKindProgressive;
    if ([k isEqualToString:@"audio"]) return VGKindAudio;
    if ([k isEqualToString:@"segment"]) return VGKindSegment;
    return VGKindUnknown;
}

- (NSString *)kindName {
    switch (self.kind) {
        case VGKindHLS:         return @"HLS";
        case VGKindDASH:        return @"DASH";
        case VGKindProgressive: return @"视频";
        case VGKindAudio:       return @"音频";
        case VGKindSegment:     return @"分片";
        default:                return @"链接";
    }
}

- (NSInteger)score {
    switch (self.kind) {
        case VGKindHLS:         return 95;
        case VGKindDASH:        return 92;
        case VGKindProgressive: return 85;
        case VGKindAudio:       return 40;
        case VGKindSegment:     return 10;
        default:                return 5;
    }
}

- (NSString *)displayName {
    NSURL *u = [NSURL URLWithString:self.url];
    NSString *host = u.host ?: @"";
    NSString *last = u.lastPathComponent;
    if (!last.length) last = u.path.length ? u.path : self.url;
    // 去掉查询串里的噪声，只保留有辨识度的一段
    if (last.length > 54) last = [[last substringToIndex:51] stringByAppendingString:@"…"];
    if (host.length) return [NSString stringWithFormat:@"%@ · %@", host, last];
    return last;
}

- (NSString *)displayDetail {
    NSURL *p = [NSURL URLWithString:self.pageURL];
    NSString *pageHost = p.host ?: @"";
    NSString *src = self.source.length ? self.source : @"?";
    NSString *detail = [NSString stringWithFormat:@"%@ · %@ · %@", self.kindName, src, pageHost];
    if (self.hits > 1) detail = [detail stringByAppendingFormat:@" · ×%ld", (long)self.hits];
    return detail;
}

- (NSString *)suggestedFileName {
    NSURL *u = [NSURL URLWithString:self.url];
    NSString *name = u.lastPathComponent;
    if (!name.length) name = @"media";
    // 清洗非法字符
    NSCharacterSet *bad = [NSCharacterSet characterSetWithCharactersInString:@"/\\:*?\"<>|\n\r\t "];
    name = [[name componentsSeparatedByCharactersInSet:bad] componentsJoinedByString:@"_"];
    if (name.length > 80) {
        NSString *ext = name.pathExtension;
        name = [[name substringToIndex:70] stringByAppendingString:ext.length ? [@"." stringByAppendingString:ext] : @""];
    }
    NSString *ext = name.pathExtension.lowercaseString;
    NSArray *known = @[@"mp4", @"m4v", @"mov", @"webm", @"mkv", @"flv", @"ts", @"mp3", @"m4a", @"aac", @"ogg", @"wav", @"m3u8", @"mpd"];
    if (![known containsObject:ext]) {
        switch (self.kind) {
            case VGKindHLS:         name = [name stringByAppendingString:@".m3u8"]; break;
            case VGKindDASH:        name = [name stringByAppendingString:@".mpd"]; break;
            case VGKindAudio:       name = [name stringByAppendingString:@".m4a"]; break;
            default:                name = [name stringByAppendingString:@".mp4"]; break;
        }
    }
    return name;
}

- (NSString *)description {
    return [NSString stringWithFormat:@"<VGMediaItem %@ %@>", self.kindString, self.url];
}

@end

NSString *VGGuessKindString(NSString *url) {
    if (![url isKindOfClass:[NSString class]]) return @"progressive";
    NSString *s = url.lowercaseString;
    if ([s containsString:@"m3u8"]) return @"hls";
    if ([s containsString:@".mpd"] || [s containsString:@"manifest.mpd"]) return @"dash";
    if ([s containsString:@".m4a"] || [s containsString:@".mp3"] || [s containsString:@".aac"]) return @"audio";
    if ([s containsString:@".ts?"] || [s hasSuffix:@".ts"]) return @"segment";
    return @"progressive";
}

#pragma mark - 调试日志

static NSString *gVGLogPath = nil;

NSString *VGLogPath(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSString *dir = @"/var/mobile/Documents/XLHVideoGrab";
        BOOL ok = [[NSFileManager defaultManager] createDirectoryAtPath:dir
                                           withIntermediateDirectories:YES
                                                            attributes:nil error:NULL];
        if (ok && [[NSFileManager defaultManager] isWritableFileAtPath:dir]) {
            gVGLogPath = [dir stringByAppendingPathComponent:@"probe.log"];
        } else {
            // 沙盒 App 走这里，最后用面板的「日志」按钮分享出来
            gVGLogPath = [NSTemporaryDirectory() stringByAppendingPathComponent:@"xlhgrab_probe.log"];
        }
    });
    return gVGLogPath;
}

static NSMutableArray<NSString *> *gVGRing = nil;
static NSLock *gVGRingLock = nil;

void VGLogLine(NSString *line) {
    if (!line.length) return;
    if (!VGConfigBool(@"debug", YES)) return;

    static NSDateFormatter *fmt = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        gVGRing = [NSMutableArray array];
        gVGRingLock = [NSLock new];
        fmt = [NSDateFormatter new];
        fmt.dateFormat = @"HH:mm:ss";
    });

    // 只进内存，绝不碰磁盘：热路径里做 I/O 会拖死 App
    NSString *entry = [NSString stringWithFormat:@"%@ %@", [fmt stringFromDate:[NSDate date]], line];
    [gVGRingLock lock];
    [gVGRing addObject:entry];
    if (gVGRing.count > 1500) {
        [gVGRing removeObjectsInRange:NSMakeRange(0, gVGRing.count - 1500)];
    }
    [gVGRingLock unlock];
}

void VGLogDump(void) {
    [gVGRingLock lock];
    NSString *text = [gVGRing componentsJoinedByString:@"\n"];
    NSUInteger count = gVGRing.count;
    [gVGRingLock unlock];

    NSString *header = [NSString stringWithFormat:@"XLH VideoGrab %@\n设备 %@ / iOS %@\n记录 %lu 行\n---\n",
                        VGVersionString(),
                        [[UIDevice currentDevice] model],
                        [[UIDevice currentDevice] systemVersion],
                        (unsigned long)count];
    NSString *full = [header stringByAppendingString:text ?: @""];

    NSError *err = nil;
    [full writeToFile:VGLogPath() atomically:YES encoding:NSUTF8StringEncoding error:&err];
}
