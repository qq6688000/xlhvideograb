//
//  VGOverlay.m
//  悬浮抓取层
//
//  设计要点：不再创建独立 UIWindow，而是把一层“穿透视图”直接加进 App
//  自己的 window。空白区域 hitTest 返回 nil，UIKit 会继续把事件交给
//  下层兄弟视图，因此从机制上不可能出现“整屏点不动”。
//

#import "VGOverlay.h"
#import "VGCommon.h"
#import "VGManager.h"
#import "VGDownloader.h"
#import <objc/runtime.h>

#pragma mark - 触摸穿透容器

@interface VGPassthroughView : UIView
@end

@implementation VGPassthroughView

- (UIView *)hitTest:(CGPoint)point withEvent:(UIEvent *)event {
    UIView *v = [super hitTest:point withEvent:event];
    return (v == self) ? nil : v;
}

@end

#pragma mark - 下载进度 HUD

@interface VGHUD : UIView
+ (instancetype)showInView:(UIView *)view text:(NSString *)text;
- (void)updateFraction:(double)fraction text:(NSString *)text;
- (void)hide;
@end

@interface VGHUD ()
@property (nonatomic, strong) UILabel *label;
@property (nonatomic, strong) UIProgressView *bar;
@end

@implementation VGHUD

+ (instancetype)showInView:(UIView *)view text:(NSString *)text {
    if (!view) return nil;
    VGHUD *hud = [[VGHUD alloc] initWithFrame:CGRectMake(0, 0, 220, 84)];
    hud.center = CGPointMake(CGRectGetMidX(view.bounds), CGRectGetMidY(view.bounds));
    hud.autoresizingMask = UIViewAutoresizingFlexibleLeftMargin | UIViewAutoresizingFlexibleRightMargin |
                           UIViewAutoresizingFlexibleTopMargin | UIViewAutoresizingFlexibleBottomMargin;
    hud.backgroundColor = [UIColor colorWithWhite:0.08 alpha:0.88];
    hud.layer.cornerRadius = 12;
    hud.userInteractionEnabled = NO;

    UILabel *label = [[UILabel alloc] initWithFrame:CGRectMake(14, 16, 192, 26)];
    label.textColor = [UIColor whiteColor];
    label.font = [UIFont systemFontOfSize:13 weight:UIFontWeightMedium];
    label.text = text;
    label.textAlignment = NSTextAlignmentCenter;
    label.lineBreakMode = NSLineBreakByTruncatingMiddle;
    [hud addSubview:label];
    hud.label = label;

    UIProgressView *bar = [[UIProgressView alloc] initWithFrame:CGRectMake(14, 56, 192, 4)];
    bar.progressTintColor = [UIColor colorWithRed:0.30 green:0.85 blue:0.55 alpha:1.0];
    bar.trackTintColor = [UIColor colorWithWhite:1 alpha:0.18];
    [hud addSubview:bar];
    hud.bar = bar;

    [view addSubview:hud];
    return hud;
}

- (void)updateFraction:(double)fraction text:(NSString *)text {
    if (text.length) self.label.text = text;
    if (fraction >= 0) [self.bar setProgress:(float)MIN(1.0, MAX(0.0, fraction)) animated:YES];
}

- (void)hide {
    [UIView animateWithDuration:0.2 animations:^{ self.alpha = 0; } completion:^(BOOL done) {
        [self removeFromSuperview];
    }];
}

@end

#pragma mark - 悬浮层

static const void *kVGOverlayAssocKey = &kVGOverlayAssocKey;

@interface VGOverlayController () <UITableViewDataSource, UITableViewDelegate>

@property (nonatomic, weak) UIWindow *window;
@property (nonatomic, weak) WKWebView *webView;

@property (nonatomic, strong) VGPassthroughView *root;
@property (nonatomic, strong) UIButton *fab;

@property (nonatomic, strong) UIView *dim;
@property (nonatomic, strong) UIView *panel;
@property (nonatomic, strong) UITableView *table;
@property (nonatomic, strong) UILabel *summary;
@property (nonatomic, strong) UILabel *emptyLabel;
@property (nonatomic, strong) UIButton *closeButton;
@property (nonatomic, strong) UIButton *scanButton;

@property (nonatomic, strong) NSArray<VGMediaItem *> *items;
@property (nonatomic, assign) BOOL panelVisible;
@property (nonatomic, assign) BOOL dragging;

@end

@implementation VGOverlayController

+ (instancetype)controllerForWindow:(UIWindow *)window {
    if (!window) return nil;
    VGOverlayController *c = objc_getAssociatedObject(window, kVGOverlayAssocKey);
    if (!c) {
        c = [VGOverlayController new];
        c->_window = window;
        objc_setAssociatedObject(window, kVGOverlayAssocKey, c, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        [c attach];
    }
    return c;
}

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

- (void)attach {
    if (self.root) return;
    UIWindow *w = self.window;
    if (!w) return;

    VGPassthroughView *root = [[VGPassthroughView alloc] initWithFrame:w.bounds];
    root.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    root.backgroundColor = [UIColor clearColor];
    root.opaque = NO;
    [w addSubview:root];
    self.root = root;

    [self setupFAB];
    [self layoutFAB];

    NSNotificationCenter *nc = [NSNotificationCenter defaultCenter];
    [nc addObserver:self selector:@selector(onMediaChangedNote:) name:VGMediaDidChangeNotification object:nil];
    [nc addObserver:self selector:@selector(onAppActiveNote:) name:UIApplicationDidBecomeActiveNotification object:nil];
    [nc addObserver:self selector:@selector(onOrientationChanged:) name:UIDeviceOrientationDidChangeNotification object:nil];
    [nc addObserver:self selector:@selector(onOrientationChanged:) name:UIDeviceOrientationDidChangeNotification object:nil];
}

- (void)detach {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
    [self.root removeFromSuperview];
    self.root = nil;
    self.fab = nil;
    self.panel = nil;
    self.dim = nil;
    self.table = nil;
    self.panelVisible = NO;
}

#pragma mark - 对外

- (void)bindWebView:(WKWebView *)webView {
    _webView = webView;
}

- (void)showIfNeeded {
    if (!VGConfigBool(@"enabled", YES)) {
        [self detach];
        return;
    }
    if (!self.root) [self attach];
    if (!self.root) return;

    self.root.hidden = NO;
    [self.window bringSubviewToFront:self.root];

    BOOL hiddenByUser = [[NSUserDefaults standardUserDefaults] boolForKey:@"xlgrab.fabhidden"];
    NSString *cfg = VGConfigString(@"fab");
    if ([cfg isEqualToString:@"1"] || [cfg isEqualToString:@"on"] || [cfg isEqualToString:@"true"]) {
        hiddenByUser = NO;
    } else if ([cfg isEqualToString:@"0"] || [cfg isEqualToString:@"off"] || [cfg isEqualToString:@"false"]) {
        hiddenByUser = YES;
    }
    self.fab.hidden = hiddenByUser;
}

- (void)onOrientationChanged:(NSNotification *)note {
    (void)note;
    [self layoutFAB];
}

- (void)onAppActiveNote:(NSNotification *)note {
    (void)note;
    if (!self.root) return;
    [self.window bringSubviewToFront:self.root];
    [self layoutFAB];
}

#pragma mark - 悬浮球

- (void)setupFAB {
    UIButton *fab = [UIButton buttonWithType:UIButtonTypeCustom];
    fab.frame = CGRectMake(0, 0, 54, 54);
    fab.backgroundColor = [UIColor colorWithWhite:0.10 alpha:0.62];
    fab.layer.cornerRadius = 27;
    fab.layer.borderWidth = 1.0 / [UIScreen mainScreen].scale;
    fab.layer.borderColor = [UIColor colorWithWhite:1 alpha:0.40].CGColor;
    fab.layer.shadowColor = [UIColor blackColor].CGColor;
    fab.layer.shadowOpacity = 0.28;
    fab.layer.shadowRadius = 6;
    fab.layer.shadowOffset = CGSizeMake(0, 2);
    fab.accessibilityLabel = @"抓取视频";
    [fab setTitle:@"抓" forState:UIControlStateNormal];
    [fab setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
    fab.titleLabel.font = [UIFont boldSystemFontOfSize:19];
    [fab addTarget:self action:@selector(fabTapped) forControlEvents:UIControlEventTouchUpInside];

    UIPanGestureRecognizer *pan = [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(handlePan:)];
    [fab addGestureRecognizer:pan];

    UILongPressGestureRecognizer *press = [[UILongPressGestureRecognizer alloc] initWithTarget:self action:@selector(handleLongPress:)];
    press.minimumPressDuration = 0.6;
    [fab addGestureRecognizer:press];

    [self.root addSubview:fab];
    self.fab = fab;
}

- (void)layoutFAB {
    if (!self.fab || !self.root) return;
    CGSize b = self.root.bounds.size;
    if (b.width < 2 || b.height < 2) return;

    const CGFloat size = 54;
    NSUserDefaults *d = [NSUserDefaults standardUserDefaults];
    CGPoint c;
    if ([d objectForKey:@"xlgrab.fabx"] && [d objectForKey:@"xlgrab.faby"]) {
        c = CGPointMake([d floatForKey:@"xlgrab.fabx"] * b.width,
                        [d floatForKey:@"xlgrab.faby"] * b.height);
    } else {
        c = CGPointMake(b.width - size / 2 - 12, b.height - size / 2 - 96);
    }
    c.x = MAX(size / 2 + 4, MIN(b.width - size / 2 - 4, c.x));
    c.y = MAX(size / 2 + 34, MIN(b.height - size / 2 - 24, c.y));
    self.fab.center = c;
}

- (void)handlePan:(UIPanGestureRecognizer *)g {
    if (!self.fab) return;
    CGPoint t = [g translationInView:self.root];
    [g setTranslation:CGPointZero inView:self.root];
    if (fabs(t.x) > 0.5 || fabs(t.y) > 0.5) self.dragging = YES;

    CGSize b = self.root.bounds.size;
    const CGFloat half = 27;
    CGPoint c = CGPointMake(self.fab.center.x + t.x, self.fab.center.y + t.y);
    c.x = MAX(half + 4, MIN(b.width - half - 4, c.x));
    c.y = MAX(half + 34, MIN(b.height - half - 24, c.y));
    self.fab.center = c;

    if (g.state == UIGestureRecognizerStateEnded || g.state == UIGestureRecognizerStateCancelled) {
        [self snapFAB];
        [self saveFABPosition];
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.15 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            self.dragging = NO;
        });
    }
}

- (void)snapFAB {
    if (!self.fab || !self.root) return;
    CGSize b = self.root.bounds.size;
    const CGFloat half = 27;
    CGFloat x = self.fab.center.x < b.width / 2 ? half + 10 : b.width - half - 10;
    [UIView animateWithDuration:0.2 animations:^{
        self.fab.center = CGPointMake(x, self.fab.center.y);
    }];
}

- (void)saveFABPosition {
    if (!self.fab || !self.root) return;
    CGSize b = self.root.bounds.size;
    if (b.width < 2 || b.height < 2) return;
    NSUserDefaults *d = [NSUserDefaults standardUserDefaults];
    [d setFloat:self.fab.center.x / b.width forKey:@"xlgrab.fabx"];
    [d setFloat:self.fab.center.y / b.height forKey:@"xlgrab.faby"];
}

- (void)fabTapped {
    if (self.dragging) return;
    if (self.panelVisible) [self hidePanel];
    else [self showPanel];
}

- (void)handleLongPress:(UILongPressGestureRecognizer *)g {
    if (g.state != UIGestureRecognizerStateBegan || !self.fab) return;
    UIViewController *host = [self topViewController];
    if (!host) return;
    UIAlertController *ac = [UIAlertController alertControllerWithTitle:@"悬浮球"
                                                               message:@"隐藏后可在终端执行  xlgrab fab on  恢复"
                                                        preferredStyle:UIAlertControllerStyleAlert];
    [ac addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    __weak typeof(self) weakSelf = self;
    [ac addAction:[UIAlertAction actionWithTitle:@"隐藏" style:UIAlertActionStyleDestructive handler:^(UIAlertAction *a) {
        [[NSUserDefaults standardUserDefaults] setBool:YES forKey:@"xlgrab.fabhidden"];
        weakSelf.fab.hidden = YES;
    }]];
    [host presentViewController:ac animated:YES completion:nil];
}

#pragma mark - 面板

- (void)buildPanelIfNeeded {
    if (self.panel || !self.root) return;

    UIView *dim = [[UIView alloc] initWithFrame:self.root.bounds];
    dim.backgroundColor = [UIColor colorWithWhite:0 alpha:0.35];
    dim.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    [dim addGestureRecognizer:[[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(hidePanel)]];
    dim.hidden = YES;
    [self.root addSubview:dim];
    self.dim = dim;

    UIView *panel = [[UIView alloc] initWithFrame:CGRectZero];
    panel.backgroundColor = [UIColor colorWithWhite:0.10 alpha:0.97];
    panel.layer.cornerRadius = 14;
    panel.layer.masksToBounds = YES;
    panel.hidden = YES;
    [self.root addSubview:panel];
    self.panel = panel;

    UILabel *title = [[UILabel alloc] initWithFrame:CGRectMake(14, 0, 180, 44)];
    title.text = @"抓到的视频";
    title.textColor = [UIColor whiteColor];
    title.font = [UIFont systemFontOfSize:15 weight:UIFontWeightSemibold];
    [panel addSubview:title];

    UIButton *close = [UIButton buttonWithType:UIButtonTypeCustom];
    [close setTitle:@"✕" forState:UIControlStateNormal];
    [close setTitleColor:[UIColor colorWithWhite:1 alpha:0.65] forState:UIControlStateNormal];
    close.titleLabel.font = [UIFont systemFontOfSize:16 weight:UIFontWeightMedium];
    [close addTarget:self action:@selector(hidePanel) forControlEvents:UIControlEventTouchUpInside];
    [panel addSubview:close];
    self.closeButton = close;

    UIButton *scan = [UIButton buttonWithType:UIButtonTypeCustom];
    [scan setTitle:@"重新扫描" forState:UIControlStateNormal];
    [scan setTitleColor:[UIColor colorWithRed:0.35 green:0.85 blue:0.60 alpha:1.0] forState:UIControlStateNormal];
    scan.titleLabel.font = [UIFont systemFontOfSize:12 weight:UIFontWeightMedium];
    scan.layer.borderColor = [UIColor colorWithWhite:1 alpha:0.22].CGColor;
    scan.layer.borderWidth = 1;
    scan.layer.cornerRadius = 15;
    [scan addTarget:self action:@selector(rescan) forControlEvents:UIControlEventTouchUpInside];
    [panel addSubview:scan];
    self.scanButton = scan;

    UILabel *summary = [[UILabel alloc] initWithFrame:CGRectZero];
    summary.textColor = [UIColor colorWithWhite:1 alpha:0.50];
    summary.font = [UIFont systemFontOfSize:11];
    summary.lineBreakMode = NSLineBreakByTruncatingMiddle;
    [panel addSubview:summary];
    self.summary = summary;

    UITableView *table = [[UITableView alloc] initWithFrame:CGRectZero style:UITableViewStylePlain];
    table.backgroundColor = [UIColor clearColor];
    table.separatorColor = [UIColor colorWithWhite:1 alpha:0.08];
    table.rowHeight = 62;
    table.dataSource = self;
    table.delegate = self;
    table.indicatorStyle = UIScrollViewIndicatorStyleWhite;
    table.keyboardDismissMode = UIScrollViewKeyboardDismissModeOnDrag;
    [panel addSubview:table];
    self.table = table;

    UILabel *empty = [[UILabel alloc] initWithFrame:CGRectZero];
    empty.text = @"暂时没抓到视频\n播放几秒后点「重新扫描」";
    empty.numberOfLines = 0;
    empty.textAlignment = NSTextAlignmentCenter;
    empty.textColor = [UIColor colorWithWhite:1 alpha:0.40];
    empty.font = [UIFont systemFontOfSize:12];
    empty.hidden = YES;
    [panel addSubview:empty];
    self.emptyLabel = empty;
}

- (void)layoutPanel {
    if (!self.panel || !self.root) return;
    CGSize b = self.root.bounds.size;
    CGFloat w = MIN(360, b.width - 24);
    CGFloat h = MIN(460, b.height - 140);
    if (w < 200 || h < 200) return;
    CGFloat x = (b.width - w) / 2;
    CGFloat y = (b.height - h) / 2;
    self.panel.frame = CGRectMake(x, y, w, h);

    const CGFloat headerH = 44;
    const CGFloat pad = 12;
    self.closeButton.frame = CGRectMake(w - 44, 0, 44, 44);
    self.scanButton.frame = CGRectMake(w - 76 - 50, (headerH - 30) / 2, 76, 30);
    self.summary.frame = CGRectMake(pad, headerH - 2, w - pad * 2, 16);
    CGFloat tableY = headerH + 16;
    self.table.frame = CGRectMake(0, tableY, w, h - tableY - 8);
    self.emptyLabel.frame = CGRectMake(pad, tableY + 44, w - pad * 2, 60);
}

- (void)showPanel {
    if (!self.root) return;
    [self buildPanelIfNeeded];
    [self layoutPanel];
    [self refreshItems];

    self.dim.hidden = NO;
    self.panel.hidden = NO;
    self.panel.alpha = 0;
    self.panel.transform = CGAffineTransformMakeScale(0.95, 0.95);
    [UIView animateWithDuration:0.18 animations:^{
        self.panel.alpha = 1;
        self.panel.transform = CGAffineTransformIdentity;
    }];
    self.panelVisible = YES;
    [self.window bringSubviewToFront:self.root];
}

- (void)hidePanel {
    if (!self.panel) { self.panelVisible = NO; return; }
    self.panelVisible = NO;
    [UIView animateWithDuration:0.15 animations:^{
        self.panel.alpha = 0;
    } completion:^(BOOL done) {
        self.panel.hidden = YES;
        self.dim.hidden = YES;
    }];
}

- (void)refreshItems {
    self.items = [[VGManager shared] sortedItems];

    NSInteger total = (NSInteger)self.items.count;
    NSInteger usable = 0;
    for (VGMediaItem *it in self.items) {
        if (it.kind != VGKindSegment) usable++;
    }
    NSString *page = self.webView.URL.absoluteString ?: @"";
    NSString *host = page.length ? ([NSURL URLWithString:page].host ?: page) : @"当前页";
    NSInteger probes = [VGManager shared].nativeProbes;
    if (probes > 0) {
        self.summary.text = [NSString stringWithFormat:@"%ld 条 · 播放器探测 %ld · %@", (long)total, (long)probes, host];
    } else {
        self.summary.text = [NSString stringWithFormat:@"%ld 条 · %@", (long)total, host];
    }
    (void)usable;

    if (total > 0) {
        self.emptyLabel.hidden = YES;
    } else {
        self.emptyLabel.hidden = NO;
        if (probes > 0) {
            self.emptyLabel.text = @"播放器已触发，但没取到地址\n（可能是 DRM / 复合资源）\n试试先播放 3 秒再回来";
        } else {
            self.emptyLabel.text = @"播放器尚未触发\n播放几秒后点「重新扫描」";
        }
    }
    [self.table reloadData];
}

- (void)onMediaChangedNote:(NSNotification *)note {
    (void)note;
    if (self.panelVisible) [self refreshItems];
}

- (void)rescan {
    if (!self.webView) {
        [self toast:@"本页是原生播放器，播放几秒后再看"];
        [self refreshItems];
        return;
    }
    [self.webView evaluateJavaScript:@"(window.__XLH_VG_SCAN__ && window.__XLH_VG_SCAN__()), 0" completionHandler:nil];
    [self toast:@"已重新扫描"];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.45 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        [self refreshItems];
    });
}

#pragma mark - 表格

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    return (NSInteger)self.items.count;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    static NSString *cid = @"VGMediaCell";
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:cid];
    if (!cell) {
        cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:cid];
        cell.backgroundColor = [UIColor clearColor];
        cell.contentView.backgroundColor = [UIColor clearColor];
        cell.textLabel.textColor = [UIColor whiteColor];
        cell.textLabel.font = [UIFont systemFontOfSize:14 weight:UIFontWeightMedium];
        cell.textLabel.lineBreakMode = NSLineBreakByTruncatingMiddle;
        cell.detailTextLabel.textColor = [UIColor colorWithWhite:1 alpha:0.48];
        cell.detailTextLabel.font = [UIFont systemFontOfSize:11];
        cell.detailTextLabel.lineBreakMode = NSLineBreakByTruncatingMiddle;
        cell.selectionStyle = UITableViewCellSelectionStyleNone;
    }
    if (indexPath.row < (NSInteger)self.items.count) {
        VGMediaItem *item = self.items[indexPath.row];
        cell.textLabel.text = [NSString stringWithFormat:@"%@ · %@", item.kindName, item.displayName];
        cell.detailTextLabel.text = item.displayDetail;
    }
    return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:NO];
    if (indexPath.row >= (NSInteger)self.items.count) return;
    VGMediaItem *item = self.items[indexPath.row];
    [self presentActionsForItem:item cell:[tableView cellForRowAtIndexPath:indexPath]];
}

#pragma mark - 条目操作

- (void)presentActionsForItem:(VGMediaItem *)item cell:(UITableViewCell *)cell {
    UIViewController *host = [self topViewController];
    if (!host) {
        [self toast:@"找不到可用的界面"];
        return;
    }

    UIAlertController *ac = [UIAlertController alertControllerWithTitle:[NSString stringWithFormat:@"%@ · %@", item.kindName, item.displayName]
                                                               message:item.url
                                                        preferredStyle:UIAlertControllerStyleActionSheet];
    if (ac.popoverPresentationController) {
        ac.popoverPresentationController.sourceView = cell ?: self.panel;
        ac.popoverPresentationController.sourceRect = cell ? cell.bounds
            : CGRectMake(CGRectGetMidX(self.panel.bounds), CGRectGetMidY(self.panel.bounds), 1, 1);
    }

    __weak typeof(self) weakSelf = self;
    [ac addAction:[UIAlertAction actionWithTitle:@"下载" style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) {
        [weakSelf downloadItem:item];
    }]];
    [ac addAction:[UIAlertAction actionWithTitle:@"复制链接" style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) {
        [UIPasteboard generalPasteboard].string = item.url ?: @"";
        [weakSelf toast:@"链接已复制"];
    }]];
    [ac addAction:[UIAlertAction actionWithTitle:@"用浏览器打开" style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) {
        NSURL *u = [NSURL URLWithString:item.url];
        if (u) [[UIApplication sharedApplication] openURL:u options:@{} completionHandler:nil];
    }]];
    [ac addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    [host presentViewController:ac animated:YES completion:nil];
}

- (void)downloadItem:(VGMediaItem *)item {
    [self hidePanel];

    __weak typeof(self) weakSelf = self;
    VGHUD *hud = [VGHUD showInView:self.root text:@"准备下载…"];
    [[VGDownloader shared] downloadItem:item progress:^(double fraction, NSString *status) {
        [hud updateFraction:fraction text:status];
    } completion:^(NSURL *file, NSError *error) {
        [hud hide];
        if (error || !file) {
            [weakSelf toast:[NSString stringWithFormat:@"下载失败：%@", error.localizedDescription ?: @"未知错误"]];
            return;
        }
        [weakSelf shareFile:file];
    }];
}

- (void)shareFile:(NSURL *)file {
    UIViewController *host = [self topViewController];
    if (!host || !file) { [self toast:@"已保存到临时目录"]; return; }

    UIActivityViewController *avc = [[UIActivityViewController alloc] initWithActivityItems:@[file] applicationActivities:nil];
    if (avc.popoverPresentationController) {
        avc.popoverPresentationController.sourceView = self.root;
        avc.popoverPresentationController.sourceRect = CGRectMake(CGRectGetMidX(self.root.bounds), CGRectGetMidY(self.root.bounds), 1, 1);
    }
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.25 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        [host presentViewController:avc animated:YES completion:nil];
    });
}

#pragma mark - 辅助

- (UIViewController *)topViewController {
    UIViewController *vc = self.window.rootViewController;
    while (vc.presentedViewController) vc = vc.presentedViewController;
    return vc;
}

- (void)toast:(NSString *)text {
    if (!self.root || !text.length) return;

    UILabel *label = [[UILabel alloc] initWithFrame:CGRectZero];
    label.text = text;
    label.textColor = [UIColor whiteColor];
    label.font = [UIFont systemFontOfSize:12];
    label.textAlignment = NSTextAlignmentCenter;
    label.numberOfLines = 2;
    label.backgroundColor = [UIColor colorWithWhite:0.08 alpha:0.90];
    label.layer.cornerRadius = 10;
    label.layer.masksToBounds = YES;
    label.userInteractionEnabled = NO;
    label.alpha = 0;

    CGSize b = self.root.bounds.size;
    label.frame = CGRectMake(24, b.height - 140, b.width - 48, 40);
    label.autoresizingMask = UIViewAutoresizingFlexibleTopMargin | UIViewAutoresizingFlexibleWidth;
    [self.root addSubview:label];

    [UIView animateWithDuration:0.18 animations:^{ label.alpha = 1; } completion:^(BOOL done) {
        [UIView animateWithDuration:0.25 delay:1.6 options:0 animations:^{ label.alpha = 0; } completion:^(BOOL finished) {
            [label removeFromSuperview];
        }];
    }];
}

@end
