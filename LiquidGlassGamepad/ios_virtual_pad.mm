#include <TargetConditionals.h>
#if TARGET_OS_IOS
#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>
#include <SDL3/SDL.h>
#include <atomic>
#include <cstring>
#include <cmath>

static std::atomic<uint16_t> g_buttons{0};
static std::atomic<uint8_t> g_lt{0}, g_rt{0};
static std::atomic<int16_t> g_lx{0}, g_ly{0}, g_rx{0}, g_ry{0};
static std::atomic<uint32_t> g_packet{1};
static std::atomic<bool> g_active{true};

static float g_sensitivity = 1.0f;
static float g_buttonScale = 1.0f;
static NSInteger g_layoutMode = 0; // 0 = Twin-Stick, 1 = Touch-Drag
static BOOL g_editMode = NO;

@class LiquidGlassButton;
static void (^g_onSelectControl)(UIView *ctrl) = nil;

@interface LiquidGlassButton : UIView
@property (nonatomic, copy) NSString *ctrlId;
@property (nonatomic, assign) uint16_t buttonMask;
@property (nonatomic, assign) BOOL isLT, isRT;
@property (nonatomic, copy) void (^onTap)(void);
@property (nonatomic, strong) UIVisualEffectView *blurView;
@property (nonatomic, strong) UILabel *titleLabel;
@property (nonatomic, strong) UITouch *activeTouch;
@property (nonatomic, assign) CGPoint dragStartCenter;
@property (nonatomic, assign) CGPoint dragStartTouch;
- (instancetype)initWithFrame:(CGRect)frame ctrlId:(NSString *)cid title:(NSString *)title accent:(UIColor *)accent cornerRadius:(CGFloat)radius;
@end

@implementation LiquidGlassButton
- (instancetype)initWithFrame:(CGRect)frame ctrlId:(NSString *)cid title:(NSString *)title accent:(UIColor *)accent cornerRadius:(CGFloat)radius {
    if ((self = [super initWithFrame:frame])) {
        _ctrlId = cid;
        self.backgroundColor = [UIColor clearColor];
        self.userInteractionEnabled = YES;
        self.multipleTouchEnabled = YES;
        _blurView = [[UIVisualEffectView alloc] initWithEffect:[UIBlurEffect effectWithStyle:UIBlurEffectStyleSystemUltraThinMaterialDark]];
        _blurView.frame = self.bounds;
        _blurView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        _blurView.layer.cornerRadius = radius;
        _blurView.clipsToBounds = YES;
        _blurView.userInteractionEnabled = NO;
        _blurView.layer.borderWidth = 1.25;
        _blurView.layer.borderColor = [UIColor colorWithWhite:1.0 alpha:0.35].CGColor;
        [self addSubview:_blurView];

        UIView *tint = [[UIView alloc] initWithFrame:self.bounds];
        tint.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        tint.backgroundColor = [UIColor colorWithWhite:1.0 alpha:0.07];
        tint.userInteractionEnabled = NO;
        [_blurView.contentView addSubview:tint];

        _titleLabel = [[UILabel alloc] initWithFrame:self.bounds];
        _titleLabel.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        _titleLabel.text = title;
        _titleLabel.textAlignment = NSTextAlignmentCenter;
        _titleLabel.font = [UIFont systemFontOfSize:(radius > 18 ? 17 : 13) weight:UIFontWeightBold];
        _titleLabel.textColor = accent ? accent : [UIColor colorWithWhite:1.0 alpha:0.94];
        [self addSubview:_titleLabel];
    }
    return self;
}
- (void)setPressed:(BOOL)pressed {
    [UIView animateWithDuration:0.08 animations:^{
        self.transform = pressed ? CGAffineTransformMakeScale(0.91, 0.91) : CGAffineTransformIdentity;
        self.blurView.layer.borderColor = [UIColor colorWithWhite:1.0 alpha:(pressed ? 0.8 : 0.35)].CGColor;
        self.alpha = pressed ? 1.0 : 0.88;
    }];
    if (pressed) {
        [[[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleLight] impactOccurred];
        if (_onTap) _onTap();
    }
    if (_isLT) g_lt.store(pressed ? 255 : 0);
    else if (_isRT) g_rt.store(pressed ? 255 : 0);
    else if (_buttonMask) {
        uint16_t cur = g_buttons.load();
        g_buttons.store(pressed ? (cur | _buttonMask) : (cur & ~_buttonMask));
    }
    g_packet.fetch_add(1);
}
- (void)touchesBegan:(NSSet<UITouch *> *)t withEvent:(UIEvent *)e {
    if (g_editMode && _ctrlId) {
        UITouch *touch = [t anyObject];
        self.dragStartCenter = self.center;
        self.dragStartTouch = [touch locationInView:self.superview];
        if (g_onSelectControl) g_onSelectControl(self);
        return;
    }
    if (!self.activeTouch) { self.activeTouch = [t anyObject]; [self setPressed:YES]; }
}
- (void)touchesMoved:(NSSet<UITouch *> *)t withEvent:(UIEvent *)e {
    if (g_editMode && _ctrlId) {
        UITouch *touch = [t anyObject];
        CGPoint pt = [touch locationInView:self.superview];
        self.center = CGPointMake(self.dragStartCenter.x + (pt.x - self.dragStartTouch.x), self.dragStartCenter.y + (pt.y - self.dragStartTouch.y));
        return;
    }
}
- (void)touchesEnded:(NSSet<UITouch *> *)t withEvent:(UIEvent *)e {
    if (g_editMode && _ctrlId) return;
    if (self.activeTouch && [t containsObject:self.activeTouch]) { self.activeTouch = nil; [self setPressed:NO]; }
}
- (void)touchesCancelled:(NSSet<UITouch *> *)t withEvent:(UIEvent *)e {
    if (g_editMode && _ctrlId) return;
    if (self.activeTouch && [t containsObject:self.activeTouch]) { self.activeTouch = nil; [self setPressed:NO]; }
}
@end
@interface LiquidGlassThumbstick : UIView
@property (nonatomic, copy) NSString *ctrlId;
@property (nonatomic, assign) BOOL isRightStick;
@property (nonatomic, assign) BOOL isFloating;
@property (nonatomic, strong) UIVisualEffectView *baseView, *knobView;
@property (nonatomic, strong) UITouch *activeTouch;
@property (nonatomic, assign) CGPoint defaultCenter;
@property (nonatomic, strong) NSTimer *sprintTimer;
@property (nonatomic, assign) BOOL sprintLocked;
@property (nonatomic, assign) CGPoint dragStartCenter, dragStartTouch;
@end

@implementation LiquidGlassThumbstick
- (instancetype)initWithFrame:(CGRect)frame ctrlId:(NSString *)cid isRight:(BOOL)isRight floating:(BOOL)floating {
    if ((self = [super initWithFrame:frame])) {
        _ctrlId = cid; _isRightStick = isRight; _isFloating = floating;
        _defaultCenter = self.center;
        self.backgroundColor = [UIColor clearColor];
        self.multipleTouchEnabled = YES;
        if (floating) self.alpha = 0.0;
        CGFloat size = frame.size.width;
        _baseView = [[UIVisualEffectView alloc] initWithEffect:[UIBlurEffect effectWithStyle:UIBlurEffectStyleSystemUltraThinMaterialDark]];
        _baseView.frame = self.bounds;
        _baseView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        _baseView.layer.cornerRadius = size * 0.5;
        _baseView.clipsToBounds = YES;
        _baseView.layer.borderWidth = 1.25;
        _baseView.layer.borderColor = [UIColor colorWithWhite:1.0 alpha:0.25].CGColor;
        _baseView.userInteractionEnabled = NO;
        [self addSubview:_baseView];

        CGFloat ks = size * 0.44;
        _knobView = [[UIVisualEffectView alloc] initWithEffect:[UIBlurEffect effectWithStyle:UIBlurEffectStyleSystemThinMaterialLight]];
        _knobView.frame = CGRectMake((size - ks) * 0.5, (size - ks) * 0.5, ks, ks);
        _knobView.layer.cornerRadius = ks * 0.5;
        _knobView.clipsToBounds = YES;
        _knobView.layer.borderWidth = 1.5;
        _knobView.layer.borderColor = [UIColor colorWithWhite:1.0 alpha:0.70].CGColor;
        _knobView.userInteractionEnabled = NO;
        [self addSubview:_knobView];
    }
    return self;
}
- (void)layoutSubviews {
    [super layoutSubviews];
    CGFloat size = self.bounds.size.width;
    _baseView.layer.cornerRadius = size * 0.5;
    CGFloat ks = size * 0.44;
    if (!self.activeTouch) _knobView.frame = CGRectMake((size - ks) * 0.5, (size - ks) * 0.5, ks, ks);
    _knobView.layer.cornerRadius = ks * 0.5;
}
- (void)setSprintActive:(BOOL)active {
    if (_sprintLocked == active) return;
    _sprintLocked = active;
    uint16_t cur = g_buttons.load();
    g_buttons.store(active ? (cur | 0x0040) : (cur & ~0x0040));
    g_packet.fetch_add(1);
    _knobView.layer.borderColor = active ? [UIColor colorWithRed:0.3 green:0.9 blue:0.4 alpha:0.95].CGColor : [UIColor colorWithWhite:1.0 alpha:0.70].CGColor;
    if (active) [[[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleMedium] impactOccurred];
}
- (void)updateStickWithPoint:(CGPoint)pt {
    CGFloat r = self.bounds.size.width * 0.5, maxD = r * 0.72;
    CGFloat dx = pt.x - r, dy = pt.y - r, dist = hypot(dx, dy);
    if (dist > maxD) { dx = (dx / dist) * maxD; dy = (dy / dist) * maxD; }
    _knobView.center = CGPointMake(r + dx, r + dy);
    float nx = (float)(dx / maxD), ny = (float)(-dy / maxD);
    if (fabsf(nx) < 0.08f) nx = 0.0f;
    if (fabsf(ny) < 0.08f) ny = 0.0f;
    if (_isRightStick) {
        nx = fmaxf(-1.0f, fminf(1.0f, nx * g_sensitivity));
        ny = fmaxf(-1.0f, fminf(1.0f, ny * g_sensitivity));
        g_rx.store((int16_t)(nx * 32767.0f)); g_ry.store((int16_t)(ny * 32767.0f));
    } else {
        g_lx.store((int16_t)(nx * 32767.0f)); g_ly.store((int16_t)(ny * 32767.0f));
        // Auto-sprint: kada se drzi do ivice (>88%) duze od 1.0s
        if (dist >= maxD * 0.88f) {
            if (!self.sprintTimer && !self.sprintLocked) {
                __weak typeof(self) weakSelf = self;
                self.sprintTimer = [NSTimer scheduledTimerWithTimeInterval:1.0 repeats:NO block:^(NSTimer * _Nonnull timer) {
                    [weakSelf setSprintActive:YES];
                }];
            }
        } else {
            [self.sprintTimer invalidate]; self.sprintTimer = nil;
            if (self.sprintLocked) [self setSprintActive:NO];
        }
    }
    g_packet.fetch_add(1);
}
- (void)resetStick {
    [self.sprintTimer invalidate]; self.sprintTimer = nil;
    if (self.sprintLocked) [self setSprintActive:NO];
    CGFloat r = self.bounds.size.width * 0.5;
    [UIView animateWithDuration:0.12 animations:^{
        self.knobView.center = CGPointMake(r, r);
        if (self.isFloating && !g_editMode) { self.alpha = 0.0; self.center = self.defaultCenter; }
    }];
    if (_isRightStick) { g_rx.store(0); g_ry.store(0); } else { g_lx.store(0); g_ly.store(0); }
    g_packet.fetch_add(1);
}
- (void)touchesBegan:(NSSet<UITouch *> *)t withEvent:(UIEvent *)e {
    if (g_editMode) {
        UITouch *touch = [t anyObject];
        self.dragStartCenter = self.center;
        self.dragStartTouch = [touch locationInView:self.superview];
        if (g_onSelectControl) g_onSelectControl(self);
        return;
    }
    if (!self.activeTouch) { self.activeTouch = [t anyObject]; [self updateStickWithPoint:[self.activeTouch locationInView:self]]; }
}
- (void)touchesMoved:(NSSet<UITouch *> *)t withEvent:(UIEvent *)e {
    if (g_editMode) {
        UITouch *touch = [t anyObject];
        CGPoint pt = [touch locationInView:self.superview];
        self.center = CGPointMake(self.dragStartCenter.x + (pt.x - self.dragStartTouch.x), self.dragStartCenter.y + (pt.y - self.dragStartTouch.y));
        self.defaultCenter = self.center;
        return;
    }
    if (self.activeTouch && [t containsObject:self.activeTouch]) [self updateStickWithPoint:[self.activeTouch locationInView:self]];
}
- (void)touchesEnded:(NSSet<UITouch *> *)t withEvent:(UIEvent *)e { if (!g_editMode && self.activeTouch && [t containsObject:self.activeTouch]) { self.activeTouch = nil; [self resetStick]; } }
- (void)touchesCancelled:(NSSet<UITouch *> *)t withEvent:(UIEvent *)e { if (!g_editMode && self.activeTouch && [t containsObject:self.activeTouch]) { self.activeTouch = nil; [self resetStick]; } }
@end

@interface FloatingStickZone : UIView
@property (nonatomic, weak) LiquidGlassThumbstick *stick;
@end
@implementation FloatingStickZone
- (void)touchesBegan:(NSSet<UITouch *> *)t withEvent:(UIEvent *)e {
    if (g_editMode || !self.stick || self.stick.activeTouch) return;
    UITouch *touch = [t anyObject];
    CGPoint pt = [touch locationInView:self.superview];
    self.stick.center = pt;
    self.stick.alpha = 1.0;
    [self.stick touchesBegan:t withEvent:e];
}
- (void)touchesMoved:(NSSet<UITouch *> *)t withEvent:(UIEvent *)e { if (!g_editMode) [self.stick touchesMoved:t withEvent:e]; }
- (void)touchesEnded:(NSSet<UITouch *> *)t withEvent:(UIEvent *)e { if (!g_editMode) [self.stick touchesEnded:t withEvent:e]; }
- (void)touchesCancelled:(NSSet<UITouch *> *)t withEvent:(UIEvent *)e { if (!g_editMode) [self.stick touchesCancelled:t withEvent:e]; }
@end

@interface TouchDragCameraZone : UIView
@property (nonatomic, strong) UITouch *dragTouch;
@property (nonatomic, assign) CGPoint lastPt;
@property (nonatomic, strong) NSTimer *decayTimer;
@end
@implementation TouchDragCameraZone
- (void)touchesBegan:(NSSet<UITouch *> *)t withEvent:(UIEvent *)e { if (!g_editMode && !self.dragTouch) { self.dragTouch = [t anyObject]; self.lastPt = [self.dragTouch locationInView:self]; } }
- (void)touchesMoved:(NSSet<UITouch *> *)t withEvent:(UIEvent *)e {
    if (!g_editMode && self.dragTouch && [t containsObject:self.dragTouch]) {
        CGPoint pt = [self.dragTouch locationInView:self];
        CGFloat dx = pt.x - self.lastPt.x, dy = pt.y - self.lastPt.y;
        self.lastPt = pt;
        float vx = fmaxf(-1.0f, fminf(1.0f, (float)(dx / 18.0) * g_sensitivity));
        float vy = fmaxf(-1.0f, fminf(1.0f, (float)(-dy / 18.0) * g_sensitivity));
        g_rx.store((int16_t)(vx * 32767.0f)); g_ry.store((int16_t)(vy * 32767.0f));
        g_packet.fetch_add(1);
        [self.decayTimer invalidate];
        self.decayTimer = [NSTimer scheduledTimerWithTimeInterval:0.04 repeats:NO block:^(NSTimer * _Nonnull timer) { g_rx.store(0); g_ry.store(0); g_packet.fetch_add(1); }];
    }
}
- (void)touchesEnded:(NSSet<UITouch *> *)t withEvent:(UIEvent *)e { if (self.dragTouch && [t containsObject:self.dragTouch]) { self.dragTouch = nil; [self.decayTimer invalidate]; g_rx.store(0); g_ry.store(0); g_packet.fetch_add(1); } }
- (void)touchesCancelled:(NSSet<UITouch *> *)t withEvent:(UIEvent *)e { if (self.dragTouch && [t containsObject:self.dragTouch]) { self.dragTouch = nil; [self.decayTimer invalidate]; g_rx.store(0); g_ry.store(0); g_packet.fetch_add(1); } }
@end
@interface PassthroughContainer : UIView
@end
@implementation PassthroughContainer
- (UIView *)hitTest:(CGPoint)point withEvent:(UIEvent *)event {
    UIView *hit = [super hitTest:point withEvent:event];
    return (hit == self) ? nil : hit;
}
@end

@interface VirtualPadController : NSObject
@property (nonatomic, weak) UIView *rootView;
@property (nonatomic, strong) UIView *overlay;
@property (nonatomic, strong) UIView *controlsContainer;
@property (nonatomic, strong) UIVisualEffectView *settingsPanel;
@property (nonatomic, strong) UIVisualEffectView *editBanner;
@property (nonatomic, weak) UIView *selectedControl;
@property (nonatomic, strong) UISlider *itemScaleSlider;
@property (nonatomic, strong) LiquidGlassButton *hideBtn;
@property (nonatomic, assign) BOOL controlsHidden;
- (void)rebuildControls;
@end

@implementation VirtualPadController
- (void)loadPrefs {
    NSUserDefaults *ud = [NSUserDefaults standardUserDefaults];
    if ([ud objectForKey:@"vpad_mode"]) g_layoutMode = [ud integerForKey:@"vpad_mode"];
    if ([ud objectForKey:@"vpad_sens"]) g_sensitivity = [ud floatForKey:@"vpad_sens"];
}

- (void)saveCustomLayout {
    NSUserDefaults *ud = [NSUserDefaults standardUserDefaults];
    for (UIView *v in self.controlsContainer.subviews) {
        NSString *cid = nil;
        if ([v isKindOfClass:[LiquidGlassButton class]]) cid = ((LiquidGlassButton *)v).ctrlId;
        else if ([v isKindOfClass:[LiquidGlassThumbstick class]]) cid = ((LiquidGlassThumbstick *)v).ctrlId;
        if (cid) {
            [ud setObject:NSStringFromCGRect(v.frame) forKey:[@"vpad_frame_" stringByAppendingString:cid]];
        }
    }
}

- (CGRect)frameForId:(NSString *)cid defaultFrame:(CGRect)def {
    NSString *s = [[NSUserDefaults standardUserDefaults] stringForKey:[@"vpad_frame_" stringByAppendingString:cid]];
    return s ? CGRectFromString(s) : def;
}

- (void)resetCustomLayout {
    NSUserDefaults *ud = [NSUserDefaults standardUserDefaults];
    for (NSString *k in [[ud dictionaryRepresentation] allKeys]) {
        if ([k hasPrefix:@"vpad_frame_"]) [ud removeObjectForKey:k];
    }
    [self rebuildControls];
}

- (void)enterEditMode {
    g_editMode = YES;
    self.settingsPanel.hidden = YES;
    self.editBanner.hidden = NO;
    [self.overlay bringSubviewToFront:self.editBanner];
    for (UIView *v in self.controlsContainer.subviews) {
        if ([v isKindOfClass:[LiquidGlassButton class]] || [v isKindOfClass:[LiquidGlassThumbstick class]]) {
            v.layer.borderWidth = 1.5;
            v.layer.borderColor = [UIColor systemYellowColor].CGColor;
            v.alpha = 1.0;
        }
    }
}

- (void)exitEditMode {
    g_editMode = NO;
    self.editBanner.hidden = YES;
    self.selectedControl = nil;
    for (UIView *v in self.controlsContainer.subviews) { v.layer.borderWidth = 0; if ([v isKindOfClass:[LiquidGlassThumbstick class]] && ((LiquidGlassThumbstick *)v).isFloating) v.alpha = 0.0; }
    [self saveCustomLayout];
}

- (void)itemScaleChanged:(UISlider *)sl {
    if (!self.selectedControl) return;
    CGPoint c = self.selectedControl.center;
    CGFloat base = 54.0;
    if ([self.selectedControl isKindOfClass:[LiquidGlassThumbstick class]]) base = 135.0;
    else if (self.selectedControl.bounds.size.width > self.selectedControl.bounds.size.height + 10) {
        CGFloat w = 66.0 * sl.value, h = 36.0 * sl.value;
        self.selectedControl.bounds = CGRectMake(0, 0, w, h);
        self.selectedControl.center = c;
        return;
    }
    CGFloat sz = base * sl.value;
    self.selectedControl.bounds = CGRectMake(0, 0, sz, sz);
    self.selectedControl.center = c;
    if ([self.selectedControl isKindOfClass:[LiquidGlassButton class]]) {
        ((LiquidGlassButton *)self.selectedControl).blurView.layer.cornerRadius = sz * 0.5;
    }
}

- (void)modeChanged:(UISegmentedControl *)seg {
    g_layoutMode = seg.selectedSegmentIndex;
    [[NSUserDefaults standardUserDefaults] setInteger:g_layoutMode forKey:@"vpad_mode"];
    [self rebuildControls];
}

- (void)sensChanged:(UISlider *)sl {
    g_sensitivity = sl.value;
    [[NSUserDefaults standardUserDefaults] setFloat:g_sensitivity forKey:@"vpad_sens"];
}

- (void)toggleSettings {
    if (g_editMode) [self exitEditMode];
    self.settingsPanel.hidden = !self.settingsPanel.hidden;
    if (!self.settingsPanel.hidden) [self.overlay bringSubviewToFront:self.settingsPanel];
}

- (void)toggleHide {
    if (g_editMode) [self exitEditMode];
    self.controlsHidden = !self.controlsHidden;
    self.controlsContainer.hidden = self.controlsHidden;
    self.settingsPanel.hidden = YES;
    self.hideBtn.titleLabel.text = self.controlsHidden ? @"Show" : @"Hide";
    self.hideBtn.alpha = self.controlsHidden ? 0.45 : 0.88;
}
- (void)setupInRoot:(UIView *)root {
    self.rootView = root;
    [self loadPrefs];
    CGFloat w = MAX(root.bounds.size.width, root.bounds.size.height);
    CGFloat h = MIN(root.bounds.size.width, root.bounds.size.height);

    self.overlay = [[PassthroughContainer alloc] initWithFrame:CGRectMake(0, 0, w, h)];
    self.overlay.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    self.overlay.multipleTouchEnabled = YES;

    self.controlsContainer = [[PassthroughContainer alloc] initWithFrame:self.overlay.bounds];
    self.controlsContainer.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    self.controlsContainer.multipleTouchEnabled = YES;
    [self.overlay addSubview:self.controlsContainer];

    __weak typeof(self) weakSelf = self;
    g_onSelectControl = ^(UIView *ctrl) {
        weakSelf.selectedControl = ctrl;
        weakSelf.itemScaleSlider.value = 1.0f;
    };

    LiquidGlassButton *touchBtn = [[LiquidGlassButton alloc] initWithFrame:CGRectMake(w/2 - 74, 14, 66, 30) ctrlId:nil title:@"Touch" accent:nil cornerRadius:12];
    touchBtn.onTap = ^{ [weakSelf toggleSettings]; };
    [self.overlay addSubview:touchBtn];

    self.hideBtn = [[LiquidGlassButton alloc] initWithFrame:CGRectMake(w/2 + 8, 14, 66, 30) ctrlId:nil title:@"Hide" accent:nil cornerRadius:12];
    self.hideBtn.onTap = ^{ [weakSelf toggleHide]; };
    [self.overlay addSubview:self.hideBtn];

    CGFloat ew = 340, eh = 92;
    self.editBanner = [[UIVisualEffectView alloc] initWithEffect:[UIBlurEffect effectWithStyle:UIBlurEffectStyleSystemMaterialDark]];
    self.editBanner.frame = CGRectMake((w - ew)/2, 52, ew, eh);
    self.editBanner.layer.cornerRadius = 18; self.editBanner.clipsToBounds = YES;
    self.editBanner.layer.borderWidth = 1.2; self.editBanner.layer.borderColor = [UIColor systemYellowColor].CGColor;
    self.editBanner.hidden = YES;

    UILabel *el = [[UILabel alloc] initWithFrame:CGRectMake(14, 8, ew - 28, 18)];
    el.text = @"Drag any button • Tap & slide to resize"; el.textColor = [UIColor whiteColor]; el.font = [UIFont boldSystemFontOfSize:12];
    [self.editBanner.contentView addSubview:el];

    self.itemScaleSlider = [[UISlider alloc] initWithFrame:CGRectMake(14, 30, ew - 160, 26)];
    self.itemScaleSlider.minimumValue = 0.65f; self.itemScaleSlider.maximumValue = 1.60f; self.itemScaleSlider.value = 1.0f;
    [self.itemScaleSlider addTarget:self action:@selector(itemScaleChanged:) forControlEvents:UIControlEventValueChanged];
    [self.editBanner.contentView addSubview:self.itemScaleSlider];

    UIButton *resetBtn = [UIButton buttonWithType:UIButtonTypeSystem];
    resetBtn.frame = CGRectMake(ew - 138, 28, 60, 30);
    [resetBtn setTitle:@"Reset" forState:UIControlStateNormal];
    [resetBtn setTitleColor:[UIColor systemRedColor] forState:UIControlStateNormal];
    [resetBtn addTarget:self action:@selector(resetCustomLayout) forControlEvents:UIControlEventTouchUpInside];
    [self.editBanner.contentView addSubview:resetBtn];

    UIButton *doneBtn = [UIButton buttonWithType:UIButtonTypeSystem];
    doneBtn.frame = CGRectMake(ew - 72, 28, 60, 30);
    [doneBtn setTitle:@"OK" forState:UIControlStateNormal];
    doneBtn.titleLabel.font = [UIFont boldSystemFontOfSize:15];
    [doneBtn setTitleColor:[UIColor systemGreenColor] forState:UIControlStateNormal];
    [doneBtn addTarget:self action:@selector(exitEditMode) forControlEvents:UIControlEventTouchUpInside];
    [self.editBanner.contentView addSubview:doneBtn];
    [self.overlay addSubview:self.editBanner];

    CGFloat pw = 310, ph = 205;
    self.settingsPanel = [[UIVisualEffectView alloc] initWithEffect:[UIBlurEffect effectWithStyle:UIBlurEffectStyleSystemMaterialDark]];
    self.settingsPanel.frame = CGRectMake((w - pw)/2, 54, pw, ph);
    self.settingsPanel.layer.cornerRadius = 20; self.settingsPanel.clipsToBounds = YES;
    self.settingsPanel.layer.borderWidth = 1.2; self.settingsPanel.layer.borderColor = [UIColor colorWithWhite:1.0 alpha:0.35].CGColor;
    self.settingsPanel.hidden = YES;

    UIView *cv = self.settingsPanel.contentView;
    UILabel *l1 = [[UILabel alloc] initWithFrame:CGRectMake(16, 12, pw - 32, 18)];
    l1.text = @"Control Layout"; l1.textColor = [UIColor whiteColor]; l1.font = [UIFont boldSystemFontOfSize:13];
    [cv addSubview:l1];

    UISegmentedControl *seg = [[UISegmentedControl alloc] initWithItems:@[@"Twin-Stick", @"Touch-Drag"]];
    seg.frame = CGRectMake(16, 34, pw - 32, 30); seg.selectedSegmentIndex = g_layoutMode;
    [seg addTarget:self action:@selector(modeChanged:) forControlEvents:UIControlEventValueChanged];
    [cv addSubview:seg];

    UILabel *l3 = [[UILabel alloc] initWithFrame:CGRectMake(16, 76, pw - 32, 18)];
    l3.text = @"Camera Sensitivity"; l3.textColor = [UIColor whiteColor]; l3.font = [UIFont boldSystemFontOfSize:13];
    [cv addSubview:l3];

    UISlider *sens = [[UISlider alloc] initWithFrame:CGRectMake(16, 98, pw - 32, 28)];
    sens.minimumValue = 0.30f; sens.maximumValue = 2.50f; sens.value = g_sensitivity;
    [sens addTarget:self action:@selector(sensChanged:) forControlEvents:UIControlEventValueChanged];
    [cv addSubview:sens];

    UIButton *editBtn = [UIButton buttonWithType:UIButtonTypeSystem];
    editBtn.frame = CGRectMake(16, 144, pw - 32, 38);
    editBtn.backgroundColor = [UIColor colorWithWhite:1.0 alpha:0.15];
    editBtn.layer.cornerRadius = 12;
    [editBtn setTitle:@"Customize Layout (Drag & Resize)" forState:UIControlStateNormal];
    [editBtn setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
    editBtn.titleLabel.font = [UIFont boldSystemFontOfSize:14];
    [editBtn addTarget:self action:@selector(enterEditMode) forControlEvents:UIControlEventTouchUpInside];
    [cv addSubview:editBtn];

    [self.overlay addSubview:self.settingsPanel];
    [self rebuildControls];
    [root addSubview:self.overlay];
    [root bringSubviewToFront:self.overlay];
}
- (void)rebuildControls {
    for (UIView *sub in [self.controlsContainer.subviews copy]) [sub removeFromSuperview];
    CGFloat w = self.controlsContainer.bounds.size.width;
    CGFloat h = self.controlsContainer.bounds.size.height;

    if (g_layoutMode == 1) {
        TouchDragCameraZone *dragZone = [[TouchDragCameraZone alloc] initWithFrame:CGRectMake(w * 0.45, 50, w * 0.55, h - 50)];
        [self.controlsContainer addSubview:dragZone];
    }

    CGFloat m = 26.0, ss = (h > 600) ? 146.0 : 120.0, bs = (h > 600) ? 54.0 : 46.0;

    CGRect lsFrame = [self frameForId:@"ls" defaultFrame:CGRectMake(m + 14, h - ss - m, ss, ss)];
    LiquidGlassThumbstick *leftStick = [[LiquidGlassThumbstick alloc] initWithFrame:lsFrame ctrlId:@"ls" isRight:NO floating:YES];
    FloatingStickZone *floatZone = [[FloatingStickZone alloc] initWithFrame:CGRectMake(0, 95, w * 0.42, h - 95)];
    floatZone.stick = leftStick;
    [self.controlsContainer addSubview:floatZone];
    [self.controlsContainer addSubview:leftStick];

    if (g_layoutMode == 0) {
        CGFloat rs = ss * 0.88;
        CGRect rsFrame = [self frameForId:@"rs" defaultFrame:CGRectMake(w - rs - m - 88, h - rs - m + 8, rs, rs)];
        [self.controlsContainer addSubview:[[LiquidGlassThumbstick alloc] initWithFrame:rsFrame ctrlId:@"rs" isRight:YES floating:NO]];
    }

    CGFloat ds = 36.0, dx = m + ss + 64.0, dy = h - m - ds * 1.55;
    LiquidGlassButton *dUp = [[LiquidGlassButton alloc] initWithFrame:[self frameForId:@"dup" defaultFrame:CGRectMake(dx, dy - ds, ds, ds)] ctrlId:@"dup" title:@"▲" accent:nil cornerRadius:10]; dUp.buttonMask = 0x0001; [self.controlsContainer addSubview:dUp];
    LiquidGlassButton *dDn = [[LiquidGlassButton alloc] initWithFrame:[self frameForId:@"ddn" defaultFrame:CGRectMake(dx, dy + ds, ds, ds)] ctrlId:@"ddn" title:@"▼" accent:nil cornerRadius:10]; dDn.buttonMask = 0x0002; [self.controlsContainer addSubview:dDn];
    LiquidGlassButton *dLt = [[LiquidGlassButton alloc] initWithFrame:[self frameForId:@"dlt" defaultFrame:CGRectMake(dx - ds, dy, ds, ds)] ctrlId:@"dlt" title:@"◀" accent:nil cornerRadius:10]; dLt.buttonMask = 0x0004; [self.controlsContainer addSubview:dLt];
    LiquidGlassButton *dRt = [[LiquidGlassButton alloc] initWithFrame:[self frameForId:@"drt" defaultFrame:CGRectMake(dx + ds, dy, ds, ds)] ctrlId:@"drt" title:@"▶" accent:nil cornerRadius:10]; dRt.buttonMask = 0x0008; [self.controlsContainer addSubview:dRt];

    CGFloat cx = w - m - bs * 1.45, cy = (g_layoutMode == 0) ? (h - m - ss * 0.92 - bs * 0.75) : (h - m - bs * 1.65), sp = bs * 0.92;
    LiquidGlassButton *bY = [[LiquidGlassButton alloc] initWithFrame:[self frameForId:@"by" defaultFrame:CGRectMake(cx - bs/2, cy - sp - bs/2, bs, bs)] ctrlId:@"by" title:@"Y" accent:[UIColor colorWithRed:1.0 green:0.84 blue:0.2 alpha:1.0] cornerRadius:bs/2]; bY.buttonMask = 0x8000; [self.controlsContainer addSubview:bY];
    LiquidGlassButton *bA = [[LiquidGlassButton alloc] initWithFrame:[self frameForId:@"ba" defaultFrame:CGRectMake(cx - bs/2, cy + sp - bs/2, bs, bs)] ctrlId:@"ba" title:@"A" accent:[UIColor colorWithRed:0.3 green:0.9 blue:0.4 alpha:1.0] cornerRadius:bs/2]; bA.buttonMask = 0x1000; [self.controlsContainer addSubview:bA];
    LiquidGlassButton *bX = [[LiquidGlassButton alloc] initWithFrame:[self frameForId:@"bx" defaultFrame:CGRectMake(cx - sp - bs/2, cy - bs/2, bs, bs)] ctrlId:@"bx" title:@"X" accent:[UIColor colorWithRed:0.35 green:0.7 blue:1.0 alpha:1.0] cornerRadius:bs/2]; bX.buttonMask = 0x4000; [self.controlsContainer addSubview:bX];
    LiquidGlassButton *bB = [[LiquidGlassButton alloc] initWithFrame:[self frameForId:@"bb" defaultFrame:CGRectMake(cx + sp - bs/2, cy - bs/2, bs, bs)] ctrlId:@"bb" title:@"B" accent:[UIColor colorWithRed:1.0 green:0.35 blue:0.35 alpha:1.0] cornerRadius:bs/2]; bB.buttonMask = 0x2000; [self.controlsContainer addSubview:bB];

    CGFloat pw = 66.0, ph = 36.0;
    LiquidGlassButton *bLT = [[LiquidGlassButton alloc] initWithFrame:[self frameForId:@"blt" defaultFrame:CGRectMake(m + 14, m, pw, ph)] ctrlId:@"blt" title:@"LT" accent:nil cornerRadius:13]; bLT.isLT = YES; [self.controlsContainer addSubview:bLT];
    LiquidGlassButton *bLB = [[LiquidGlassButton alloc] initWithFrame:[self frameForId:@"blb" defaultFrame:CGRectMake(m + 14, m + ph + 8, pw, ph)] ctrlId:@"blb" title:@"LB" accent:nil cornerRadius:13]; bLB.buttonMask = 0x0100; [self.controlsContainer addSubview:bLB];
    LiquidGlassButton *bRT = [[LiquidGlassButton alloc] initWithFrame:[self frameForId:@"brt" defaultFrame:CGRectMake(w - m - pw, m, pw, ph)] ctrlId:@"brt" title:@"RT" accent:nil cornerRadius:13]; bRT.isRT = YES; [self.controlsContainer addSubview:bRT];
    LiquidGlassButton *bRB = [[LiquidGlassButton alloc] initWithFrame:[self frameForId:@"brb" defaultFrame:CGRectMake(w - m - pw, m + ph + 8, pw, ph)] ctrlId:@"brb" title:@"RB" accent:nil cornerRadius:13]; bRB.buttonMask = 0x0200; [self.controlsContainer addSubview:bRB];

    LiquidGlassButton *bV = [[LiquidGlassButton alloc] initWithFrame:[self frameForId:@"bv" defaultFrame:CGRectMake(w/2 - 134, 14, 48, 30)] ctrlId:@"bv" title:@"⧉" accent:nil cornerRadius:11]; bV.buttonMask = 0x0020; [self.controlsContainer addSubview:bV];
    LiquidGlassButton *bM = [[LiquidGlassButton alloc] initWithFrame:[self frameForId:@"bm" defaultFrame:CGRectMake(w/2 + 86, 14, 48, 30)] ctrlId:@"bm" title:@"☰" accent:nil cornerRadius:11]; bM.buttonMask = 0x0010; [self.controlsContainer addSubview:bM];
}
@end

static VirtualPadController *g_padCtrl = nil;
extern "C" int ios_vpad_active(void) { return g_active.load() ? 1 : 0; }
extern "C" void ios_vpad_fill_state(uint8_t state[16]) {
    uint32_t pkt = g_packet.load(); uint16_t btns = g_buttons.load();
    uint8_t lt = g_lt.load(), rt = g_rt.load();
    int16_t lx = g_lx.load(), ly = g_ly.load(), rx = g_rx.load(), ry = g_ry.load();
    std::memcpy(state, &pkt, 4); std::memcpy(state + 4, &btns, 2);
    state[6] = lt; state[7] = rt;
    std::memcpy(state + 8, &lx, 2); std::memcpy(state + 10, &ly, 2);
    std::memcpy(state + 12, &rx, 2); std::memcpy(state + 14, &ry, 2);
}
extern "C" void ios_vpad_attach_to_window(SDL_Window *win) {
    if (!win) return;
    UIWindow *uiWin = (__bridge UIWindow *)SDL_GetPointerProperty(SDL_GetWindowProperties(win), SDL_PROP_WINDOW_UIKIT_WINDOW_POINTER, NULL);
    if (!uiWin || !uiWin.rootViewController) return;
    dispatch_async(dispatch_get_main_queue(), ^{
        UIView *root = uiWin.rootViewController.view;
        if (!g_padCtrl) { g_padCtrl = [[VirtualPadController alloc] init]; [g_padCtrl setupInRoot:root]; }
        else if (g_padCtrl.overlay.superview != root) { [root addSubview:g_padCtrl.overlay]; }
        [root bringSubviewToFront:g_padCtrl.overlay];
    });
}
#endif
