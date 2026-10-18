//
//  VGOverlay.m
//  悬浮按钮 + 视频链接面板
//

#import "VGOverlay.h"
#import "VGManager.h"
#import "VGDownloader.h"
#import "VGCommon.h"

#pragma mark - 穿透视图
// 只有按钮/面板等真实子视图接收触摸，其余区域事件穿透给下层 App

@interface VGPassthroughView : UIView @end

@implementation VGPassthroughView
- (UIView *)hitTest:(CGPoint)point withEvent:(UIEvent *)event {
    UIView *v = [super hitTest:point withEvent:event];
    return (v == self) ? nil : v;
}
@end

#pragma mark - HUD

@interface VGHUD : UIView
@property (nonatomic, strong) UILabel *label;
@property (nonatomic, strong) UIProgressView *bar;
@property (nonatomic, strong) UIView *box;
+ (instancetype)showInView:(UIView *)view text:(NSString *)text;
- (void)updateText:(NSString *)text progress:(double)progress;
- (void)hide;
@end

@implementation VGHUD

+ (instancetype)showInView:(UIView *)view text:(NSString *)text {
    if (!view) return nil;
    VGHUD *hud = [[VGHUD alloc] initWithFrame:view.bounds];
    hud.userInteractionEnabled = NO;
    hud.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;

    UIView *box = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 232, 84)];
    box.backgroundColor = [UIColor colorWithWhite:0.08 alpha:0.92];
    box.layer.cornerRadius = 14;
    box.center = CGPointMake(CGRectGetMidX(view.bounds), CGRectGetMidY(view.bounds));
    box.autoresizingMask = UIViewAutoresizingFlexibleLeftMargin | UIViewAutoresizingFlexibleRightMargin |
                           UIViewAutoresizingFlexibleTopMargin | UIViewAutoresizingFlexibleBottomMargin;
    [hud addSubview:box];
    hud.box = box;

    UILabel *label = [[UILabel alloc] initWithFrame:CGRectMake(14, 14, 204, 22)];
    label.textColor = [UIColor whiteColor];
    label.font = [UIFont systemFontOfSize:13 weight:UIFontWeightMedium];
    label.textAlignment = NSTextAlignmentCenter;
    label.text = text;
    label.lineBreakMode = NSLineBreakByTruncatingMiddle;
    [box addSubview:label];
    hud.label = label;

    UIProgressView *bar = [[UIProgressView alloc] initWithProgressViewStyle:UIProgressViewStyleDefault];
    bar.frame = CGRectMake(16, 50, 200, 4);
    bar.progressTintColor = [UIColor systemBlueColor];
    bar.trackTintColor = [UIColor colorWithWhite:1 alpha:0.22];
    [box addSubview:bar];
    hud.bar = bar;

    [view addSubview:hud];
    hud.alpha = 0;
    [UIView animateWithDuration:0.15 animations:^{ hud.alpha = 1; }];
    return hud;
}

- (void)updateText:(NSString *)text progress:(double)progress {
    dispatch_async(dispatch_get_main_queue(), ^{
        if (text.length) self.label.text = text;
        if (progress < 0) {
            self.bar.hidden = YES;
        } else {
            self.bar.hidden = NO;
            [self.bar setProgress:(float)MAX(0, MIN(1, progress)) animated:YES];
        }
    });
}

- (void)hide {
    dispatch_async(dispatch_get_main_queue(), ^{
        [UIView animateWithDuration:0.2 animations:^{ self.alpha = 0; } completion:^(BOOL f) {
            [self removeFromSuperview];
        }];
    });
}
@end

#pragma mark - 面板控制器

@interface VGOverlayViewController : UIViewController <UITableViewDataSource, UITableViewDelegate>
@property (nonatomic, weak) WKWebView *webView;
@property (nonatomic, strong) UIButton *fab;
@property (nonatomic, strong) UIView *dim;
@property (nonatomic, strong) UIView *panel;
@property (nonatomic, strong) UITableView *table;
@property (nonatomic, strong) UILabel *summary;
@property (nonatomic, strong) NSArray<VGMediaItem *> *items;
@property (nonatomic, assign) BOOL panelVisible;
@property (nonatomic, strong) UIButton *panelCloseButton;
@property (nonatomic, strong) UIButton *scanButton;
@property (nonatomic, strong) UILabel *hintLabel;

- (void)setupFAB;
- (void)layoutFABIfNeeded;
- (void)layoutPanel;
- (NSString *)fabPositionKey;
- (void)handlePan:(UIPanGestureRecognizer *)g;
- (void)snapFAB;
- (void)handleLongPress:(UILongPressGestureRecognizer *)g;
- (void)fabTapped;
- (void)buildPanelIfNeeded;
- (void)showPanel;
- (void)hidePanel;
- (void)scanPage;
- (void)onMediaChanged;
- (void)refreshItems;
- (UIColor *)colorForKind:(VGKind)kind;
- (void)downloadItem:(VGMediaItem *)item;
- (void)shareFile:(NSURL *)file;
- (void)toast:(NSString *)text;
- (void)presentAlert:(UIAlertController *)alert fromView:(UIView *)view;
@end

@implementation VGOverlayViewController

- (void)loadView {
    VGPassthroughView *root = [[VGPassthroughView alloc] initWithFrame:[UIScreen mainScreen].bounds];
    root.backgroundColor = [UIColor clearColor];
    self.view = root;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    [self setupFAB];
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(onMediaChanged)
                                                 name:VGMediaDidChangeNotification
                                               object:nil];
}

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

#pragma mark 悬浮按钮

- (void)setupFAB {
    UIButton *fab = [UIButton buttonWithType:UIButtonTypeCustom];
    fab.frame = CGRectMake(0, 0, 54, 54);
    fab.backgroundColor = [UIColor colorWithRed:0.13 green:0.62 blue:0.98 alpha:0.92];
    fab.layer.cornerRadius = 27;
    fab.layer.shadowColor = [UIColor blackColor].CGColor;
    fab.layer.shadowOpacity = 0.35;
    fab.layer.shadowRadius = 7;
    fab.layer.shadowOffset = CGSizeMake(0, 2);
    fab.titleLabel.font = [UIFont boldSystemFontOfSize:21];
    [fab setTitle:@"抓" forState:UIControlStateNormal];
    [fab setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
    [fab addTarget:self action:@selector(fabTapped) forControlEvents:UIControlEventTouchUpInside];

    UIPanGestureRecognizer *pan = [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(handlePan:)];
    [fab addGestureRecognizer:pan];

    UILongPressGestureRecognizer *longPress = [[UILongPressGestureRecognizer alloc] initWithTarget:self action:@selector(handleLongPress:)];
    longPress.minimumPressDuration = 0.8;
    [fab addGestureRecognizer:longPress];

    [self.view addSubview:fab];
    self.fab = fab;
}

- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    [self layoutFABIfNeeded];
    [self layoutPanel];
}

- (void)layoutFABIfNeeded {
    if (self.fab.tag == 20241018) return;   // 已定位
    self.fab.tag = 20241018;
    CGSize size = self.view.bounds.size;
    UIEdgeInsets safe = self.view.safeAreaInsets;
    NSString *key = [self fabPositionKey];
    NSString *saved = [[NSUserDefaults standardUserDefaults] stringForKey:key];
    CGPoint center = CGPointMake(size.width - 34 - safe.right, size.height * 0.62);
    if (saved.length) {
        NSArray *parts = [saved componentsSeparatedByString:@","];
        if (parts.count == 2) {
            center = CGPointMake([parts[0] doubleValue], [parts[1] doubleValue]);
        }
    }
    center.x = MAX(34, MIN(size.width - 34, center.x));
    center.y = MAX(60 + safe.top, MIN(size.height - 60 - safe.bottom, center.y));
    self.fab.center = center;
}

- (NSString *)fabPositionKey {
    NSString *bid = [NSBundle mainBundle].bundleIdentifier ?: @"app";
    return [@"xlgrab.fabpos." stringByAppendingString:bid];
}

- (void)handlePan:(UIPanGestureRecognizer *)g {
    CGPoint t = [g translationInView:self.view];
    [g setTranslation:CGPointZero inView:self.view];
    CGPoint c = CGPointMake(self.fab.center.x + t.x, self.fab.center.y + t.y);
    self.fab.center = c;
    if (g.state == UIGestureRecognizerStateEnded || g.state == UIGestureRecognizerStateCancelled) {
        [self snapFAB];
        [[NSUserDefaults standardUserDefaults] setObject:[NSString stringWithFormat:@"%.0f,%.0f", self.fab.center.x, self.fab.center.y]
                                                  forKey:[self fabPositionKey]];
    }
}

- (void)snapFAB {
    CGSize size = self.view.bounds.size;
    UIEdgeInsets safe = self.view.safeAreaInsets;
    CGFloat margin = 20;
    CGFloat x = self.fab.center.x < size.width / 2 ? (34 + safe.left + margin - 20) : (size.width - 34 - safe.right - margin + 20);
    CGFloat y = MAX(60 + safe.top, MIN(size.height - 60 - safe.bottom, self.fab.center.y));
    [UIView animateWithDuration:0.25 delay:0 usingSpringWithDamping:0.8 initialSpringVelocity:0.5
                        options:UIViewAnimationOptionAllowUserInteraction animations:^{
        self.fab.center = CGPointMake(x, y);
    } completion:^(BOOL finished) {
        [[NSUserDefaults standardUserDefaults] setObject:[NSString stringWithFormat:@"%.0f,%.0f", self.fab.center.x, self.fab.center.y]
                                                  forKey:[self fabPositionKey]];
    }];
}

- (void)handleLongPress:(UILongPressGestureRecognizer *)g {
    if (g.state != UIGestureRecognizerStateBegan) return;
    UIImpactFeedbackGenerator *gen = [[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleMedium];
    [gen impactOccurred];

    UIAlertController *sheet = [UIAlertController alertControllerWithTitle:@"XLH 抓取" message:@"长按菜单" preferredStyle:UIAlertControllerStyleActionSheet];
    [sheet addAction:[UIAlertAction actionWithTitle:@"清空已抓取列表" style:UIAlertActionStyleDestructive handler:^(UIAlertAction *a) {
        [[VGManager shared] clearItems];
        [self refreshItems];
    }]];
    [sheet addAction:[UIAlertAction actionWithTitle:@"收起悬浮球（本次）" style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) {
        self.fab.hidden = YES;
        [[NSUserDefaults standardUserDefaults] setBool:YES forKey:@"xlgrab.fabhidden"];
    }]];
    [sheet addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    [self presentAlert:sheet fromView:self.fab];
}

#pragma mark 面板

- (void)fabTapped {
    if (self.panelVisible) {
        [self hidePanel];
    } else {
        [self showPanel];
    }
}

- (void)buildPanelIfNeeded {
    if (self.panel) return;

    UIView *dim = [[UIView alloc] initWithFrame:self.view.bounds];
    dim.backgroundColor = [UIColor colorWithWhite:0 alpha:0.35];
    dim.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    dim.hidden = YES;
    [dim addGestureRecognizer:[[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(hidePanel)]];
    [self.view addSubview:dim];
    self.dim = dim;

    UIView *panel = [[UIView alloc] initWithFrame:CGRectZero];
    panel.backgroundColor = [UIColor colorWithDynamicProvider:^UIColor *(UITraitCollection *tc) {
        return tc.userInterfaceStyle == UIUserInterfaceStyleDark
            ? [UIColor colorWithRed:0.11 green:0.11 blue:0.12 alpha:0.99]
            : [UIColor colorWithWhite:1 alpha:0.99];
    }];
    panel.layer.cornerRadius = 18;
    panel.layer.masksToBounds = YES;
    panel.layer.shadowColor = [UIColor blackColor].CGColor;
    panel.layer.shadowOpacity = 0.3;
    panel.layer.shadowRadius = 16;
    panel.layer.shadowOffset = CGSizeMake(0, 6);
    panel.hidden = YES;
    [self.view addSubview:panel];
    self.panel = panel;

    // 标题
    UILabel *title = [[UILabel alloc] initWithFrame:CGRectMake(16, 14, 200, 22)];
    title.text = @"网页视频抓取";
    title.font = [UIFont boldSystemFontOfSize:17];
    [panel addSubview:title];

    UILabel *summary = [[UILabel alloc] initWithFrame:CGRectMake(16, 36, 240, 16)];
    summary.font = [UIFont systemFontOfSize:11];
    summary.textColor = [UIColor secondaryLabelColor];
    summary.text = @"点右上「扫描」重新抓取";
    [panel addSubview:summary];
    self.summary = summary;

    UIButton *close = [UIButton buttonWithType:UIButtonTypeSystem];
    close.frame = CGRectMake(0, 0, 44, 44);
    [close setTitle:@"✕" forState:UIControlStateNormal];
    close.titleLabel.font = [UIFont systemFontOfSize:19];
    [close addTarget:self action:@selector(hidePanel) forControlEvents:UIControlEventTouchUpInside];
    [panel addSubview:close];
    self.panelCloseButton = close;

    UIButton *scan = [UIButton buttonWithType:UIButtonTypeSystem];
    scan.frame = CGRectMake(0, 0, 60, 30);
    [scan setTitle:@"扫描" forState:UIControlStateNormal];
    scan.titleLabel.font = [UIFont systemFontOfSize:14 weight:UIFontWeightMedium];
    scan.backgroundColor = [[UIColor systemBlueColor] colorWithAlphaComponent:0.14];
    scan.layer.cornerRadius = 8;
    [scan addTarget:self action:@selector(scanPage) forControlEvents:UIControlEventTouchUpInside];
    [panel addSubview:scan];
    self.scanButton = scan;

    UITableView *table = [[UITableView alloc] initWithFrame:CGRectZero style:UITableViewStylePlain];
    table.backgroundColor = [UIColor clearColor];
    table.separatorStyle = UITableViewCellSeparatorStyleNone;
    table.dataSource = self;
    table.delegate = self;
    table.rowHeight = 64;
    [panel addSubview:table];
    self.table = table;

    UILabel *hint = [[UILabel alloc] initWithFrame:CGRectZero];
    hint.font = [UIFont systemFontOfSize:10];
    hint.textColor = [UIColor tertiaryLabelColor];
    hint.numberOfLines = 2;
    hint.text = @"blob:/ 加密 DRM 流无法直接下载；m3u8 会解析并合并为 .ts 文件后弹出分享";
    [panel addSubview:hint];
    self.hintLabel = hint;
}

- (void)showPanel {
    [self buildPanelIfNeeded];
    self.panelVisible = YES;
    [self refreshItems];
    [self layoutPanel];
    [self scanPage];

    self.dim.hidden = NO;
    self.panel.hidden = NO;
    self.dim.alpha = 0;
    self.panel.alpha = 0;
    self.panel.transform = CGAffineTransformMakeScale(0.96, 0.96);
    [UIView animateWithDuration:0.2 animations:^{
        self.dim.alpha = 1;
        self.panel.alpha = 1;
        self.panel.transform = CGAffineTransformIdentity;
    }];
    self.fab.hidden = YES;
}

- (void)hidePanel {
    if (!self.panelVisible) return;
    self.panelVisible = NO;
    [UIView animateWithDuration:0.18 animations:^{
        self.dim.alpha = 0;
        self.panel.alpha = 0;
        self.panel.transform = CGAffineTransformMakeScale(0.96, 0.96);
    } completion:^(BOOL finished) {
        self.dim.hidden = YES;
        self.panel.hidden = YES;
        self.panel.transform = CGAffineTransformIdentity;
        self.fab.hidden = NO;
    }];
}

- (void)layoutPanel {
    if (!self.panel) return;
    CGSize size = self.view.bounds.size;
    UIEdgeInsets safe = self.view.safeAreaInsets;
    CGFloat w = MIN(size.width - 24 - safe.left - safe.right, 560);
    CGFloat h = MIN(size.height - safe.top - safe.bottom - 40, 520);
    CGFloat x = (size.width - w) / 2;
    CGFloat y = MAX(safe.top + 20, (size.height - h) / 2 - 20);
    self.panel.frame = CGRectMake(x, y, w, h);
    self.dim.frame = self.view.bounds;

    self.panelCloseButton.frame = CGRectMake(w - 44, 6, 44, 44);
    self.scanButton.frame = CGRectMake(w - 44 - 68, 12, 60, 30);
    self.table.frame = CGRectMake(0, 56, w, h - 56 - 34);
    self.hintLabel.frame = CGRectMake(14, h - 32, w - 28, 24);
}

#pragma mark 抓取

- (void)scanPage {
    WKWebView *wv = self.webView;
    if (!wv || !wv.window) wv = [[VGManager shared] activeWebView];
    self.webView = wv;
    if (!wv) {
        self.summary.text = @"当前页面没有找到网页视图";
        return;
    }
    self.summary.text = @"扫描中…";
    __weak typeof(self) weakSelf = self;
    [wv evaluateJavaScript:@"(window.__xlhCollect ? window.__xlhCollect() : '{}')"
         completionHandler:^(id result, NSError *error) {
        __strong typeof(weakSelf) self = weakSelf;
        if (!self) return;
        if ([result isKindOfClass:[NSString class]] && [result length] > 2) {
            NSData *data = [(NSString *)result dataUsingEncoding:NSUTF8StringEncoding];
            id obj = [NSJSONSerialization JSONObjectWithData:data options:0 error:NULL];
            if ([obj isKindOfClass:[NSDictionary class]]) {
                NSArray *list = obj[@"items"];
                if ([list isKindOfClass:[NSArray class]]) {
                    for (NSDictionary *dict in list) {
                        if ([dict isKindOfClass:[NSDictionary class]]) {
                            [[VGManager shared] ingestPayload:dict fromWebView:wv];
                        }
                    }
                }
            }
        }
        [self refreshItems];
    }];
}

- (void)onMediaChanged {
    if (self.panelVisible) [self refreshItems];
}

- (void)refreshItems {
    self.items = [[VGManager shared] sortedItems];
    NSString *pageString = self.webView.URL.absoluteString ?: @"";
    // 分片单独计数，列表里默认只显示非分片
    NSUInteger total = self.items.count;
    NSUInteger real = 0;
    for (VGMediaItem *it in self.items) if (it.kind != VGKindSegment) real++;
    NSString *host = pageString.length ? ([NSURL URLWithString:pageString].host ?: pageString) : @"当前页";
    self.summary.text = [NSString stringWithFormat:@"共 %lu 条（可选 %lu），来源：%@",
                         (unsigned long)total, (unsigned long)real, host];
    [self.table reloadData];
}

#pragma mark UITableView

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    return self.items.count;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    static NSString *cid = @"vgcell";
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:cid];
    if (!cell) {
        cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:cid];
        cell.backgroundColor = [UIColor clearColor];
        cell.textLabel.font = [UIFont systemFontOfSize:14 weight:UIFontWeightMedium];
        cell.detailTextLabel.font = [UIFont systemFontOfSize:11];
        cell.detailTextLabel.textColor = [UIColor secondaryLabelColor];
        cell.selectedBackgroundView = [[UIView alloc] init];
        cell.selectedBackgroundView.backgroundColor = [[UIColor systemBlueColor] colorWithAlphaComponent:0.1];
    }
    VGMediaItem *item = self.items[indexPath.row];
    cell.textLabel.text = item.displayName;
    cell.detailTextLabel.text = item.displayDetail;
    cell.imageView.image = nil;

    UILabel *badge = [[UILabel alloc] initWithFrame:CGRectMake(0, 0, 44, 20)];
    badge.text = item.kindName;
    badge.font = [UIFont systemFontOfSize:10 weight:UIFontWeightSemibold];
    badge.textAlignment = NSTextAlignmentCenter;
    badge.textColor = [UIColor whiteColor];
    badge.backgroundColor = [self colorForKind:item.kind];
    badge.layer.cornerRadius = 5;
    badge.layer.masksToBounds = YES;
    cell.accessoryView = badge;
    return cell;
}

- (UIColor *)colorForKind:(VGKind)kind {
    switch (kind) {
        case VGKindHLS:         return [UIColor systemPinkColor];
        case VGKindDASH:        return [UIColor systemPurpleColor];
        case VGKindProgressive: return [UIColor systemBlueColor];
        case VGKindAudio:       return [UIColor systemTealColor];
        case VGKindSegment:     return [UIColor systemGrayColor];
        default:                return [UIColor systemGray2Color];
    }
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    VGMediaItem *item = self.items[indexPath.row];
    UITableViewCell *cell = [tableView cellForRowAtIndexPath:indexPath];

    UIAlertController *sheet = [UIAlertController alertControllerWithTitle:item.displayName
                                                                  message:item.url
                                                           preferredStyle:UIAlertControllerStyleActionSheet];
    [sheet addAction:[UIAlertAction actionWithTitle:@"下载" style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) {
        [self downloadItem:item];
    }]];
    [sheet addAction:[UIAlertAction actionWithTitle:@"复制链接" style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) {
        [UIPasteboard generalPasteboard].string = item.url;
        [self toast:@"已复制链接"];
    }]];
    [sheet addAction:[UIAlertAction actionWithTitle:@"用 Safari 打开" style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) {
        NSURL *u = [NSURL URLWithString:item.url];
        if (u) {
            [[UIApplication sharedApplication] openURL:u options:@{} completionHandler:nil];
        }
    }]];
    [sheet addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    [self presentAlert:sheet fromView:cell];
}

#pragma mark 下载

- (void)downloadItem:(VGMediaItem *)item {
    VGHUD *hud = [VGHUD showInView:self.view text:@"准备下载…"];
    __weak typeof(self) weakSelf = self;
    [[VGDownloader shared] downloadItem:item
                              progress:^(double fraction, NSString *status) {
        [hud updateText:status progress:fraction];
    } completion:^(NSURL *file, NSError *error) {
        __strong typeof(weakSelf) self = weakSelf;
        [hud hide];
        if (!self) return;
        if (error || !file) {
            [self toast:[NSString stringWithFormat:@"下载失败：%@", error.localizedDescription ?: @"未知错误"]];
            return;
        }
        [self shareFile:file];
    }];
}

- (void)shareFile:(NSURL *)file {
    UIActivityViewController *vc = [[UIActivityViewController alloc] initWithActivityItems:@[file] applicationActivities:nil];
    if (vc.popoverPresentationController) {
        vc.popoverPresentationController.sourceView = self.panel;
        vc.popoverPresentationController.sourceRect = CGRectMake(self.panel.bounds.size.width / 2, self.panel.bounds.size.height / 2, 1, 1);
    }
    [self presentViewController:vc animated:YES completion:nil];
}

- (void)toast:(NSString *)text {
    UILabel *label = [[UILabel alloc] init];
    label.text = [NSString stringWithFormat:@"  %@  ", text];
    label.font = [UIFont systemFontOfSize:12];
    label.textColor = [UIColor whiteColor];
    label.numberOfLines = 3;
    label.textAlignment = NSTextAlignmentCenter;
    label.backgroundColor = [UIColor colorWithWhite:0.1 alpha:0.92];
    label.layer.cornerRadius = 10;
    label.layer.masksToBounds = YES;
    [label sizeToFit];
    CGRect f = label.frame;
    f.size.width = MIN(f.size.width + 12, self.view.bounds.size.width - 60);
    f.size.height += 16;
    label.frame = f;
    label.center = CGPointMake(CGRectGetMidX(self.view.bounds), CGRectGetMidY(self.view.bounds));
    label.alpha = 0;
    [self.view addSubview:label];
    [UIView animateWithDuration:0.2 animations:^{ label.alpha = 1; } completion:^(BOOL finished) {
        [UIView animateWithDuration:0.3 delay:2.2 options:0 animations:^{ label.alpha = 0; } completion:^(BOOL finished2) {
            [label removeFromSuperview];
        }];
    }];
}

#pragma mark 弹窗辅助

- (void)presentAlert:(UIAlertController *)alert fromView:(UIView *)view {
    if (alert.popoverPresentationController) {
        alert.popoverPresentationController.sourceView = view ?: self.view;
        alert.popoverPresentationController.sourceRect = view ? view.bounds : CGRectMake(CGRectGetMidX(self.view.bounds), CGRectGetMidY(self.view.bounds), 1, 1);
    }
    [self presentViewController:alert animated:YES completion:nil];
}

@end

#pragma mark - 窗口宿主

@interface VGHostWindow ()
@property (nonatomic, weak) UIWindowScene *scene;
@property (nonatomic, strong) UIWindow *window;
@property (nonatomic, strong) VGOverlayViewController *controller;
@end

@implementation VGHostWindow

- (instancetype)initWithScene:(UIWindowScene *)scene {
    if (!scene) return nil;
    self = [super init];
    if (!self) return nil;
    _scene = scene;

    VGOverlayViewController *vc = [VGOverlayViewController new];
    UIWindow *window = [[UIWindow alloc] initWithWindowScene:scene];
    window.windowLevel = UIWindowLevelAlert + 120;
    window.backgroundColor = [UIColor clearColor];
    window.rootViewController = vc;
    window.hidden = NO;
    _window = window;
    _controller = vc;
    return self;
}

- (void)bindWebView:(WKWebView *)webView {
    self.controller.webView = webView;
}

- (void)showIfNeeded {
    if (!self.window) return;
    BOOL hiddenByUser = [[NSUserDefaults standardUserDefaults] boolForKey:@"xlgrab.fabhidden"];
    self.window.hidden = NO;
    self.controller.fab.hidden = hiddenByUser;
}

- (void)hide {
    self.window.hidden = YES;
}

@end
