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
#import <QuartzCore/QuartzCore.h>

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

@interface VGOverlayController () <UITableViewDataSource, UITableViewDelegate, UIGestureRecognizerDelegate>

@property (nonatomic, weak) UIWindow *window;
@property (nonatomic, weak) WKWebView *webView;

@property (nonatomic, strong) VGPassthroughView *root;
@property (nonatomic, strong) UIWindow *fabWindow;
@property (nonatomic, strong) UIButton *fab;

@property (nonatomic, strong) UIView *dim;
@property (nonatomic, strong) UIView *panel;
@property (nonatomic, strong) UITableView *table;
@property (nonatomic, strong) UILabel *summary;
@property (nonatomic, strong) UILabel *emptyLabel;
@property (nonatomic, strong) UIButton *closeButton;
@property (nonatomic, strong) UIButton *scanButton;
@property (nonatomic, strong) UIButton *logButton;

@property (nonatomic, strong) NSArray<VGMediaItem *> *items;
@property (nonatomic, assign) BOOL panelVisible;
@property (nonatomic, assign) BOOL dragging;
@property (nonatomic, assign) CGFloat dragDistance;
@property (nonatomic, assign) NSTimeInterval lastDragEndTime;

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
    if (self.fabWindow) return;
    UIWindow *w = self.window;
    if (!w) return;

    const CGFloat size = 54;

    // 球窗口：只有 54x54，层级压过 App 全部视图，但不覆盖其它任何区域
    UIWindow *fw = nil;
    if (@available(iOS 13.0, *)) {
        UIWindowScene *scene = w.windowScene;
        if (!scene) return;
        fw = [[UIWindow alloc] initWithWindowScene:scene];
    } else {
        fw = [[UIWindow alloc] initWithFrame:CGRectMake(0, 0, size, size)];
    }
    fw.frame = CGRectMake(0, 0, size, size);
    fw.windowLevel = UIWindowLevelAlert + 200;
    fw.backgroundColor = [UIColor clearColor];
    fw.rootViewController = [UIViewController new];
    fw.rootViewController.view.backgroundColor = [UIColor clearColor];
    fw.hidden = NO;

    UIButton *fab = [UIButton buttonWithType:UIButtonTypeCustom];
    fab.frame = CGRectMake(0, 0, size, size);
    fab.backgroundColor = [UIColor colorWithWhite:0.10 alpha:0.62];
    fab.layer.cornerRadius = size / 2;
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
    fab.exclusiveTouch = YES;

    UITapGestureRecognizer *tap =
        [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(handleFABTap:)];
    tap.delegate = self;
    [fab addGestureRecognizer:tap];

    UIPanGestureRecognizer *pan = [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(handlePan:)];
    pan.delegate = self;
    pan.cancelsTouchesInView = NO;
    [fab addGestureRecognizer:pan];

    UILongPressGestureRecognizer *press = [[UILongPressGestureRecognizer alloc] initWithTarget:self action:@selector(handleLongPress:)];
    press.minimumPressDuration = 0.6;
    press.delegate = self;
    press.cancelsTouchesInView = NO;
    [fab addGestureRecognizer:press];

    [fw.rootViewController.view addSubview:fab];
    self.fab = fab;
    self.fabWindow = fw;

    // 面板层：全屏透明，挂在 App 主窗口，默认隐藏
    VGPassthroughView *pr = [[VGPassthroughView alloc] initWithFrame:w.bounds];
    pr.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    pr.backgroundColor = [UIColor clearColor];
    pr.opaque = NO;
    pr.hidden = YES;
    [w addSubview:pr];
    self.root = pr;

    [self layoutFAB];

    NSNotificationCenter *nc = [NSNotificationCenter defaultCenter];
    [nc addObserver:self selector:@selector(onMediaChangedNote:) name:VGMediaDidChangeNotification object:nil];
    [nc addObserver:self selector:@selector(onAppActiveNote:) name:UIApplicationDidBecomeActiveNotification object:nil];
    [nc addObserver:self selector:@selector(onOrientationChanged:) name:UIDeviceOrientationDidChangeNotification object:nil];

    VGLogLine([NSString stringWithFormat:@"[attach] fabWindow=%.0f,%.0f level=%.0f scene=%@",
               fw.frame.origin.x, fw.frame.origin.y, fw.windowLevel,
               w.windowScene ? @"yes" : @"nil"]);
}

- (void)detach {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
    self.fabWindow.hidden = YES;
    self.fabWindow = nil;
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
    if (!self.fabWindow) [self attach];
    if (!self.fabWindow) return;

    self.fabWindow.hidden = NO;

    BOOL hiddenByUser = [[NSUserDefaults standardUserDefaults] boolForKey:@"xlgrab.fabhidden"];
    NSString *cfg = VGConfigString(@"fab");
    if ([cfg isEqualToString:@"1"] || [cfg isEqualToString:@"on"] || [cfg isEqualToString:@"true"]) {
        hiddenByUser = NO;
    } else if ([cfg isEqualToString:@"0"] || [cfg isEqualToString:@"off"] || [cfg isEqualToString:@"false"]) {
        hiddenByUser = YES;
    }
    self.fab.hidden = hiddenByUser;
    // 球隐藏时窗口也要收起，不能留一块看不见的触摸区
    self.fabWindow.hidden = hiddenByUser;
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
    fab.exclusiveTouch = YES;

    // 不用 UIControl 的 touchUpInside：pan 手势一旦识别就会取消它，
    // 在自带复杂手势的 App 里点击会静默失效。改用显式 tap。
    UITapGestureRecognizer *tap =
        [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(handleFABTap:)];
    tap.delegate = self;
    [fab addGestureRecognizer:tap];

    UIPanGestureRecognizer *pan = [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(handlePan:)];
    pan.delegate = self;
    pan.cancelsTouchesInView = NO;
    [fab addGestureRecognizer:pan];

    UILongPressGestureRecognizer *press = [[UILongPressGestureRecognizer alloc] initWithTarget:self action:@selector(handleLongPress:)];
    press.minimumPressDuration = 0.6;
    press.delegate = self;
    press.cancelsTouchesInView = NO;
    [fab addGestureRecognizer:press];

    [self.root addSubview:fab];
    self.fab = fab;
}

- (void)layoutFAB {
    if (!self.fabWindow || !self.window) return;
    CGSize b = self.window.bounds.size;
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
    self.fabWindow.frame = CGRectMake(c.x - size / 2, c.y - size / 2, size, size);
}

- (void)handlePan:(UIPanGestureRecognizer *)g {
    if (!self.fabWindow || !self.window) return;

    CGPoint t = [g translationInView:self.window];
    [g setTranslation:CGPointZero inView:self.window];

    if (g.state == UIGestureRecognizerStateBegan) {
        self.dragDistance = 0;
        self.dragging = NO;
    }
    self.dragDistance += (CGFloat)(fabs(t.x) + fabs(t.y));

    if (self.dragDistance < 8.0) {
        if (g.state == UIGestureRecognizerStateEnded ||
            g.state == UIGestureRecognizerStateCancelled ||
            g.state == UIGestureRecognizerStateFailed) {
            self.dragDistance = 0;
        }
        return;
    }
    self.dragging = YES;

    CGSize b = self.window.bounds.size;
    const CGFloat half = 27;
    CGPoint c = CGPointMake(self.fabWindow.center.x + t.x, self.fabWindow.center.y + t.y);
    c.x = MAX(half + 4, MIN(b.width - half - 4, c.x));
    c.y = MAX(half + 34, MIN(b.height - half - 24, c.y));
    self.fabWindow.frame = CGRectMake(c.x - half, c.y - half, 54, 54);

    if (g.state == UIGestureRecognizerStateEnded ||
        g.state == UIGestureRecognizerStateCancelled ||
        g.state == UIGestureRecognizerStateFailed) {
        self.lastDragEndTime = CACurrentMediaTime();
        [self snapFAB];
        [self saveFABPosition];
        self.dragging = NO;
        self.dragDistance = 0;
    }
}

- (void)snapFAB {
    if (!self.fabWindow || !self.window) return;
    CGSize b = self.window.bounds.size;
    const CGFloat half = 27;
    CGFloat x = self.fabWindow.center.x < b.width / 2 ? half + 10 : b.width - half - 10;
    CGRect f = self.fabWindow.frame;
    [UIView animateWithDuration:0.2 animations:^{
        self.fabWindow.frame = CGRectMake(x - half, f.origin.y, 54, 54);
    }];
}

- (void)saveFABPosition {
    if (!self.fabWindow || !self.window) return;
    CGSize b = self.window.bounds.size;
    if (b.width < 2 || b.height < 2) return;
    NSUserDefaults *d = [NSUserDefaults standardUserDefaults];
    [d setFloat:self.fabWindow.center.x / b.width forKey:@"xlgrab.fabx"];
    [d setFloat:self.fabWindow.center.y / b.height forKey:@"xlgrab.faby"];
}

- (void)handleFABTap:(UITapGestureRecognizer *)g {
    if (g.state != UIGestureRecognizerStateRecognized) return;
    if (CACurrentMediaTime() - self.lastDragEndTime < 0.35) return;   // 刚拖完不算点击

    VGLogLine([NSString stringWithFormat:@"[UI] fab tap, panelVisible=%d",
               (int)self.panelVisible]);
    if (self.panelVisible) [self hidePanel];
    else [self showPanel];
}

#pragma mark - UIGestureRecognizerDelegate

- (BOOL)gestureRecognizer:(UIGestureRecognizer *)gestureRecognizer
shouldRecognizeSimultaneouslyWithGestureRecognizer:(UIGestureRecognizer *)other {
    return YES;
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
        // 窗口必须一起隐藏，否则 54x54 那块区域仍会拦截触摸
        weakSelf.fabWindow.hidden = YES;
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

    UIButton *logBtn = [UIButton buttonWithType:UIButtonTypeCustom];
    [logBtn setTitle:@"日志" forState:UIControlStateNormal];
    [logBtn setTitleColor:[UIColor colorWithWhite:1 alpha:0.55] forState:UIControlStateNormal];
    logBtn.titleLabel.font = [UIFont systemFontOfSize:12 weight:UIFontWeightMedium];
    logBtn.layer.borderColor = [UIColor colorWithWhite:1 alpha:0.18].CGColor;
    logBtn.layer.borderWidth = 1;
    logBtn.layer.cornerRadius = 15;
    [logBtn addTarget:self action:@selector(shareLogFile) forControlEvents:UIControlEventTouchUpInside];
    [panel addSubview:logBtn];
    self.logButton = logBtn;

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
    self.logButton.frame = CGRectMake(w - 44 - 6 - 44, (headerH - 30) / 2, 44, 30);
    self.scanButton.frame = CGRectMake(w - 44 - 6 - 44 - 6 - 76, (headerH - 30) / 2, 76, 30);
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

    self.root.hidden = NO;
    [self.window bringSubviewToFront:self.root];
    self.fabWindow.hidden = YES;          // 面板期间藏球，避免遮挡列表

    self.dim.hidden = NO;
    self.panel.hidden = NO;
    self.panel.alpha = 0;
    self.panel.transform = CGAffineTransformMakeScale(0.95, 0.95);
    [UIView animateWithDuration:0.18 animations:^{
        self.panel.alpha = 1;
        self.panel.transform = CGAffineTransformIdentity;
    }];
    self.panelVisible = YES;
    VGLogLine([NSString stringWithFormat:@"[UI] showPanel items=%lu dim=%@ panel=%@",
               (unsigned long)self.items.count,
               self.dim ? @"ok" : @"nil",
               self.panel ? @"ok" : @"nil"]);
}

- (void)hidePanel {
    if (!self.panel) { self.panelVisible = NO; return; }
    self.panelVisible = NO;
    [UIView animateWithDuration:0.15 animations:^{
        self.panel.alpha = 0;
    } completion:^(BOOL done) {
        self.panel.hidden = YES;
        self.dim.hidden = YES;
        self.root.hidden = YES;
        self.fabWindow.hidden = NO;
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
    BOOL isLocal = VGIsLocalFileURL(item.url);
    [ac addAction:[UIAlertAction actionWithTitle:(isLocal ? @"导出文件" : @"下载")
                                          style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) {
        [weakSelf downloadItem:item];
    }]];
    [ac addAction:[UIAlertAction actionWithTitle:@"复制链接" style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) {
        [UIPasteboard generalPasteboard].string = item.url ?: @"";
        [weakSelf toast:@"链接已复制"];
    }]];
    if (!isLocal) [ac addAction:[UIAlertAction actionWithTitle:@"用浏览器打开" style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) {
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

- (void)shareLogFile {
    VGLogDump();
    NSString *path = VGLogPath();
    if (![[NSFileManager defaultManager] fileExistsAtPath:path]) {
        [self toast:@"还没有日志，先播放几秒"];
        return;
    }
    UIViewController *host = [self topViewController];
    if (!host) return;

    UIActivityViewController *avc = [[UIActivityViewController alloc] initWithActivityItems:@[[NSURL fileURLWithPath:path]]
                                                                     applicationActivities:nil];
    if (avc.popoverPresentationController) {
        avc.popoverPresentationController.sourceView = self.panel;
        avc.popoverPresentationController.sourceRect = self.logButton.frame;
    }
    [host presentViewController:avc animated:YES completion:nil];
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
