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
