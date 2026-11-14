//
//  WQUI.m
//  WQ Files shared UI helpers
//  GPL-3.0-or-later.
//

#import "WQUI.h"
#import "WQAccess.h"
#import "WQLaunchServices.h"
#import <fcntl.h>
#import <sys/sysctl.h>
#import <sys/utsname.h>

// "iPhone 17 Pro Max (iPhone18,2)\niOS 27.0.1 (24A446)"
NSString *wq_device_line(void)
{
    struct utsname u;
    NSString *machine = (uname(&u) == 0) ? @(u.machine) : @"unknown";
    char build[64] = {0};
    size_t len = sizeof(build);
    NSString *buildStr = (sysctlbyname("kern.osversion", build, &len, NULL, 0) == 0) ? @(build) : nil;
    NSDictionary *names = @{
        @"iPhone17,1": @"iPhone 16 Pro", @"iPhone17,2": @"iPhone 16 Pro Max",
        @"iPhone17,3": @"iPhone 16", @"iPhone17,4": @"iPhone 16 Plus", @"iPhone17,5": @"iPhone 16e",
        @"iPhone18,1": @"iPhone 17 Pro", @"iPhone18,2": @"iPhone 17 Pro Max",
        @"iPhone18,3": @"iPhone 17", @"iPhone18,4": @"iPhone Air",
    };
    NSString *marketing = names[machine];
    NSString *model = marketing ? [NSString stringWithFormat:@"%@ (%@)", marketing, machine] : machine;
    NSString *ver = UIDevice.currentDevice.systemVersion;
    return buildStr ? [NSString stringWithFormat:@"%@ · iOS %@ (%@)", model, ver, buildStr]
                    : [NSString stringWithFormat:@"%@ · iOS %@", model, ver];
}

// Small breathing space above a list. The device and iOS line used to sit
// here; it now lives in the log and in About.
UIView *wq_device_header(CGFloat width)
{
    return [[UIView alloc] initWithFrame:CGRectMake(0, 0, width, 8)];
}

// Private: app icon by bundle id (in UIKit; guarded with respondsToSelector).
@interface UIImage (WQPrivate)
+ (UIImage *)_applicationIconImageForBundleIdentifier:(NSString *)bid format:(int)fmt scale:(CGFloat)scale;
@end

// Small grey fingerprint of an icon, to recognise iOS's blank placeholder.
static NSData *wq_icon_fingerprint(UIImage *img)
{
    const size_t s = 12;
    uint8_t px[12 * 12 * 4] = {0};
    CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
    CGContextRef ctx = CGBitmapContextCreate(px, s, s, 8, s * 4, cs, (CGBitmapInfo)kCGImageAlphaPremultipliedLast);
    CGColorSpaceRelease(cs);
    if (!ctx) return nil;
    if (img.CGImage) CGContextDrawImage(ctx, CGRectMake(0, 0, s, s), img.CGImage);
    CGContextRelease(ctx);
    return [NSData dataWithBytes:px length:sizeof(px)];
}

static UIImage *wq_raw_icon(NSString *bundleID)
{
    if (![UIImage respondsToSelector:@selector(_applicationIconImageForBundleIdentifier:format:scale:)]) return nil;
    CGFloat scale = 2.0; // Safe fallback for background preparation without UI context.
    if (NSThread.isMainThread) {
        for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
            if ([scene isKindOfClass:UIWindowScene.class] && scene.activationState == UISceneActivationStateForegroundActive) {
                scale = ((UIWindowScene *)scene).screen.scale;
                break;
            }
        }
    }
    return [UIImage _applicationIconImageForBundleIdentifier:bundleID format:2 scale:scale];
}

// The real icon for bundleID, or nil when iOS only has its placeholder.
static UIImage *wq_real_icon(NSString *bundleID)
{
    static NSData *placeholder;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ placeholder = wq_icon_fingerprint(wq_raw_icon(@"cz.kolbi.wqfiles.no-such-app")); });
    UIImage *raw = wq_raw_icon(bundleID);
    if (!raw || !raw.CGImage) return nil;
    NSData *fp = wq_icon_fingerprint(raw);
    if (!placeholder || fp.length != placeholder.length) return raw;
    // Near-identical to the placeholder (allow small rendering differences).
    const uint8_t *a = fp.bytes, *b = placeholder.bytes;
    unsigned long diff = 0;
    for (NSUInteger i = 0; i < fp.length; i++) diff += (unsigned long)abs((int)a[i] - (int)b[i]);
    return diff / fp.length < 8 ? nil : raw;
}

// The icon from the app's own bundle, for when iOS only hands out its
// placeholder (iOS 26 refuses this app's icon requests). Reads the primary
// icon names from Info.plist and loads the matching PNG files.
// The first few outcomes go to the Log, to see why icons are missing.
static void wq_icon_note(NSString *bundleID, NSString *what)
{
    static NSUInteger notes;
    @synchronized (NSNull.null) {
        if (notes >= 8) return;
        notes++;
    }
    wq_log(@"icon: %@: %@", bundleID, what);
}

static UIImage *wq_bundle_icon(NSString *bundleID)
{
    NSString *path = wq_bundle_path_for_id(bundleID);
    if (!path.length) { wq_icon_note(bundleID, @"no bundle path in the app database"); return nil; }
    NSString *plistPath = [path stringByAppendingPathComponent:@"Info.plist"];
    NSDictionary *info = [NSDictionary dictionaryWithContentsOfFile:plistPath];
    if (!info && wq_grant(path)) info = [NSDictionary dictionaryWithContentsOfFile:plistPath];
    if (![info isKindOfClass:NSDictionary.class]) {
        int fd = open(plistPath.fileSystemRepresentation, O_RDONLY);
        int err = fd < 0 ? errno : 0;
        if (fd >= 0) close(fd);
        wq_icon_note(bundleID, [NSString stringWithFormat:@"can't read %@ (%s)", plistPath, err ? strerror(err) : "not a plist"]);
        return nil;
    }
    NSMutableArray<NSString *> *names = [NSMutableArray new];
    for (NSString *key in @[@"CFBundleIcons", @"CFBundleIcons~ipad"]) {
        NSDictionary *primary = [info[key] isKindOfClass:NSDictionary.class] ? info[key][@"CFBundlePrimaryIcon"] : nil;
        if (![primary isKindOfClass:NSDictionary.class]) continue;
        if ([primary[@"CFBundleIconName"] isKindOfClass:NSString.class]) [names addObject:primary[@"CFBundleIconName"]];
        NSArray *files = [primary[@"CFBundleIconFiles"] isKindOfClass:NSArray.class] ? primary[@"CFBundleIconFiles"] : @[];
        for (id file in files.reverseObjectEnumerator) if ([file isKindOfClass:NSString.class]) [names addObject:file];
    }
    if ([info[@"CFBundleIconFile"] isKindOfClass:NSString.class]) [names addObject:info[@"CFBundleIconFile"]];
    [names addObjectsFromArray:@[@"AppIcon60x60", @"AppIcon"]];
    // Only the PNG files apps ship next to their asset catalog. Loading from
    // the catalog (UIImage imageNamed:inBundle:) aborts inside UIKit when an
    // entry exists but can't be rendered (crash on 27.0.1, build 21).
    for (NSString *name in names) {
        NSString *base = name.stringByDeletingPathExtension;
        for (NSString *suffix in @[@"@3x.png", @"@2x.png", @"@2x~ipad.png", @"~ipad.png", @".png"]) {
            UIImage *image = [UIImage imageWithContentsOfFile:[path stringByAppendingPathComponent:[base stringByAppendingString:suffix]]];
            if (image.CGImage) {
                wq_icon_note(bundleID, [NSString stringWithFormat:@"loaded %@%@ from the app", base, suffix]);
                return image;
            }
        }
    }
    wq_icon_note(bundleID, [NSString stringWithFormat:@"no icon PNG in %@ (tried %@)", path.lastPathComponent,
                            [names componentsJoinedByString:@", "]]);
    return nil;
}

static UIImage *wq_round_icon(UIImage *raw)
{
    CGFloat s = 40;
    UIGraphicsImageRenderer *r = [[UIGraphicsImageRenderer alloc] initWithSize:CGSizeMake(s, s)];
    return [r imageWithActions:^(UIGraphicsImageRendererContext *__unused ctx) {
        [[UIBezierPath bezierPathWithRoundedRect:CGRectMake(0, 0, s, s) cornerRadius:s * 0.225] addClip];
        [raw drawInRect:CGRectMake(0, 0, s, s)];
    }];
}

// Symbol tile for system services and extensions that have no icon at all,
// picked from keywords in the bundle id.
static UIImage *wq_service_tile(NSString *bundleID)
{
    static NSArray<NSArray *> *rules;
    static NSCache *tiles;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        tiles = [NSCache new];
        UIColor *blue = UIColor.systemBlueColor, *green = UIColor.systemGreenColor, *red = UIColor.systemRedColor,
                *orange = UIColor.systemOrangeColor, *purple = UIColor.systemPurpleColor, *indigo = UIColor.systemIndigoColor,
                *teal = UIColor.systemTealColor, *pink = UIColor.systemPinkColor, *gray = UIColor.systemGrayColor;
        // keywords (lower case, any match), symbol, colour
        rules = @[
            @[@[@"emoji"], @"face.smiling.inverse", orange],
            @[@[@"keyboard", @"inputui", @"textinput", @"dictation"], @"keyboard.fill", gray],
            @[@[@"airdrop", @"sharing", @"sharesheet"], @"antenna.radiowaves.left.and.right", blue],
            @[@[@"widget", @"chrono"], @"square.grid.2x2.fill", blue],
            @[@[@"screenshot", @"screencapture", @"screenrecord"], @"camera.viewfinder", indigo],
            @[@[@"poster", @"wallpaper"], @"photo.on.rectangle.angled", purple],
            @[@[@"siri", @"assistant"], @"waveform", indigo],
            @[@[@"camera"], @"camera.fill", gray],
            @[@[@"photo"], @"photo.fill", orange],
            @[@[@"music", @"audio", @"shazam", @"musicrecognition"], @"music.note", pink],
            @[@[@"headphone", @"airpods", @"bluetooth"], @"headphones", gray],
            @[@[@"hearing"], @"ear.fill", blue],
            @[@[@"weather"], @"cloud.sun.fill", teal],
            @[@[@"location", @"maps", @"navigation"], @"location.fill", blue],
            @[@[@"health", @"fitness", @"workout"], @"heart.fill", red],
            @[@[@"pay", @"wallet", @"passbook", @"cash", @"finance"], @"creditcard.fill", green],
            @[@[@"mail"], @"envelope.fill", blue],
            @[@[@"message", @"sms", @"imessage"], @"message.fill", green],
            @[@[@"facetime", @"video"], @"video.fill", green],
            @[@[@"phone", @"call", @"telephony"], @"phone.fill", green],
            @[@[@"notification", @"usernotification", @"bulletin"], @"bell.fill", red],
            @[@[@"shortcut", @"workflow", @"intent"], @"square.on.square", indigo],
            @[@[@"safari", @"web"], @"safari.fill", blue],
            @[@[@"news", @"stocks"], @"newspaper.fill", red],
            @[@[@"calendar", @"event"], @"calendar", red],
            @[@[@"note", @"paper"], @"note.text", orange],
            @[@[@"reminder"], @"checklist", blue],
            @[@[@"game"], @"gamecontroller.fill", purple],
            @[@[@"auth", @"account", @"appsso", @"password", @"keychain", @"tcc", @"privacy"], @"lock.fill", gray],
            @[@[@"print"], @"printer.fill", gray],
            @[@[@"clarity", @"accessib"], @"accessibility", blue],
            @[@[@"home"], @"house.fill", orange],
            @[@[@"findmy", @"fmd", @"fmip"], @"location.circle.fill", green],
            @[@[@"carplay", @"carradio", @"cartrip", @"car."], @"car.fill", gray],
            @[@[@"tvremote", @"tvsetup", @"com.apple.tv"], @"tv.fill", gray],
            @[@[@"book"], @"book.fill", orange],
            @[@[@"podcast"], @"mic.fill", purple],
            @[@[@"spotlight", @"search"], @"magnifyingglass", gray],
            @[@[@"diagnostic", @"logging", @"crash", @"analytics"], @"stethoscope", gray],
            @[@[@"font"], @"textformat", gray],
            @[@[@"translate"], @"character.bubble.fill", blue],
            @[@[@"file", @"document", @"cloud"], @"folder.fill", blue],
            @[@[@"setup", @"buddy", @"onboarding"], @"gearshape.2.fill", gray],
        ];
    });
    NSString *key = bundleID.lowercaseString;
    NSString *symbol = @"gearshape.fill";
    UIColor *color = UIColor.systemGrayColor;
    for (NSArray *rule in rules) {
        BOOL hit = NO;
        for (NSString *word in rule[0]) if ([key containsString:word]) { hit = YES; break; }
        if (hit) { symbol = rule[1]; color = rule[2]; break; }
    }
    NSString *cacheKey = [symbol stringByAppendingString:color.description];
    UIImage *tile = [tiles objectForKey:cacheKey];
    if (tile) return tile;
    CGFloat s = 40;
    UIGraphicsImageRenderer *r = [[UIGraphicsImageRenderer alloc] initWithSize:CGSizeMake(s, s)];
    UIColor *fill = [color resolvedColorWithTraitCollection:[UITraitCollection traitCollectionWithUserInterfaceStyle:UIUserInterfaceStyleLight]];
    tile = [r imageWithActions:^(UIGraphicsImageRendererContext *__unused ctx) {
        [fill setFill];
        [[UIBezierPath bezierPathWithRoundedRect:CGRectMake(0, 0, s, s) cornerRadius:s * 0.225] fill];
        UIImageSymbolConfiguration *cfg = [UIImageSymbolConfiguration configurationWithPointSize:19 weight:UIImageSymbolWeightSemibold];
        UIImage *g = [[UIImage systemImageNamed:symbol withConfiguration:cfg] ?: [UIImage systemImageNamed:@"gearshape.fill" withConfiguration:cfg]
                      imageWithTintColor:UIColor.whiteColor renderingMode:UIImageRenderingModeAlwaysOriginal];
        [g drawInRect:CGRectMake((s - g.size.width) / 2, (s - g.size.height) / 2, g.size.width, g.size.height)];
    }];
    [tiles setObject:tile forKey:cacheKey];
    return tile;
}

// Rounded app icon for a bundle id, cached. Falls back to the closest parent
// app's icon (extensions: com.foo.app.widget -> com.foo.app), then to a
// neutral service tile. Nil only without a bundle id.
UIImage *wq_app_icon(NSString *bundleID)
{
    if (!bundleID.length) return nil;
    static NSCache *cache;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ cache = [NSCache new]; });
    UIImage *cached = [cache objectForKey:bundleID];
    if (cached) return cached;
    // The bundle fallback reads files and may ask for access: never on the
    // main thread. Lists warm the cache from their background passes; a
    // main-thread miss gets the tile without caching it.
    BOOL background = !NSThread.isMainThread;
    UIImage *system = wq_real_icon(bundleID);
    if (system && background) wq_icon_note(bundleID, @"iOS returned an icon");
    UIImage *raw = system ?: (background ? wq_bundle_icon(bundleID) : nil);
    NSArray *parts = [bundleID componentsSeparatedByString:@"."];
    for (NSInteger n = (NSInteger)parts.count - 1; !raw && n >= 3; n--)
    {
        NSString *parent = [[parts subarrayWithRange:NSMakeRange(0, (NSUInteger)n)] componentsJoinedByString:@"."];
        raw = wq_real_icon(parent) ?: (background ? wq_bundle_icon(parent) : nil);
    }
    UIImage *icon = raw ? wq_round_icon(raw) : wq_service_tile(bundleID);
    if (raw || background) [cache setObject:icon forKey:bundleID];
    return icon;
}

dispatch_queue_t wq_io(void)
{
    static dispatch_queue_t queue;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ queue = dispatch_queue_create("wqfiles.io", DISPATCH_QUEUE_SERIAL); });
    return queue;
}

static NSString *const kWQDeletingDisabledPref = @"WQDeletingDisabled";

BOOL wq_deleting_allowed(void)
{
    return ![NSUserDefaults.standardUserDefaults boolForKey:kWQDeletingDisabledPref];
}

void wq_set_deleting_allowed(BOOL allowed)
{
    [NSUserDefaults.standardUserDefaults setBool:!allowed forKey:kWQDeletingDisabledPref];
}

static NSString *const kWQDiscardBeforeRestorePref = @"WQDiscardBeforeRestore";

BOOL wq_keep_before_restore(void)
{
    return ![NSUserDefaults.standardUserDefaults boolForKey:kWQDiscardBeforeRestorePref];
}

void wq_set_keep_before_restore(BOOL keep)
{
    [NSUserDefaults.standardUserDefaults setBool:!keep forKey:kWQDiscardBeforeRestorePref];
}

BOOL wq_refuse_if_deleting_off(UIViewController *host)
{
    if (wq_deleting_allowed()) return NO;
    UIAlertController *alert = wq_alert_controller(@"Deleting is turned off",
        @"Turn on Allow Deleting on the start screen of WQ Files to delete, clear or clean.", UIAlertControllerStyleAlert);
    [alert addAction:wq_alert_action(@"OK", UIAlertActionStyleDefault, nil)];
    [host presentViewController:alert animated:YES completion:nil];
    return YES;
}

UIAlertController *wq_alert_controller(NSString *title, NSString *message, UIAlertControllerStyle style)
{
    return [UIAlertController alertControllerWithTitle:WQLocalizedNullable(title)
                                               message:WQLocalizedNullable(message)
                                        preferredStyle:style];
}

UIAlertAction *wq_alert_action(NSString *title, UIAlertActionStyle style, void (^handler)(UIAlertAction *))
{
    return [UIAlertAction actionWithTitle:WQLocalized(title) style:style handler:handler];
}

void wq_alert(UIViewController *host, NSString *title, NSString *message)
{
    if (!host || !host.isViewLoaded || !host.view.window) return;
    UIWindowScene *scene = host.view.window.windowScene;
    if (scene && scene.activationState != UISceneActivationStateForegroundActive) return;
    UINavigationController *nav = host.navigationController;
    if (nav && nav.topViewController != host) return;
    if (host.presentedViewController && !host.presentedViewController.isBeingDismissed) return;
    UIAlertController *alert = wq_alert_controller(title, message, UIAlertControllerStyleAlert);
    [alert addAction:wq_alert_action(@"OK", UIAlertActionStyleDefault, nil)];
    [host presentViewController:alert animated:YES completion:nil];
}

NSString *wq_size_text(unsigned long long size)
{
    if (size == 0) return @"0 KB";
    return [NSByteCountFormatter stringFromByteCount:(long long)size countStyle:NSByteCountFormatterCountStyleFile];
}


#pragma mark - Appearance

static NSString *const kWQThemePref = @"WQTheme";
static NSString *const kWQGlassPref = @"WQGlass";
static NSString *const kWQColoredIconsPref = @"WQColoredIcons";
static NSString *const kWQAccentPref = @"WQAccent";

WQTheme wq_theme(void)
{
    NSInteger v = [NSUserDefaults.standardUserDefaults integerForKey:kWQThemePref];
    return (v >= 0 && v <= 2) ? (WQTheme)v : WQThemeSystem;
}
void wq_set_theme(WQTheme theme) { [NSUserDefaults.standardUserDefaults setInteger:theme forKey:kWQThemePref]; }

BOOL wq_glass_enabled(void)
{
    id v = [NSUserDefaults.standardUserDefaults objectForKey:kWQGlassPref];
    return v ? [v boolValue] : YES;
}
void wq_set_glass_enabled(BOOL on) { [NSUserDefaults.standardUserDefaults setBool:on forKey:kWQGlassPref]; }

BOOL wq_colored_icons(void)
{
    id v = [NSUserDefaults.standardUserDefaults objectForKey:kWQColoredIconsPref];
    return v ? [v boolValue] : YES;
}
void wq_set_colored_icons(BOOL on) { [NSUserDefaults.standardUserDefaults setBool:on forKey:kWQColoredIconsPref]; }

NSArray<UIColor *> *wq_accent_colors(void)
{
    static NSArray<UIColor *> *colors;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        colors = @[
            [UIColor colorWithRed:0.04 green:0.52 blue:1.00 alpha:1],   // blue
            [UIColor colorWithRed:0.49 green:0.36 blue:1.00 alpha:1],   // violet
            [UIColor colorWithRed:1.00 green:0.22 blue:0.37 alpha:1],   // pink
            [UIColor colorWithRed:1.00 green:0.62 blue:0.04 alpha:1],   // orange
            [UIColor colorWithRed:0.19 green:0.82 blue:0.35 alpha:1],   // green
            [UIColor colorWithRed:0.25 green:0.78 blue:0.88 alpha:1],   // teal
            [UIColor colorWithRed:1.00 green:0.27 blue:0.23 alpha:1],   // red
            [UIColor colorWithRed:0.56 green:0.56 blue:0.58 alpha:1],   // graphite
        ];
    });
    return colors;
}

NSUInteger wq_accent_index(void)
{
    NSInteger v = [NSUserDefaults.standardUserDefaults integerForKey:kWQAccentPref];
    return (v >= 0 && (NSUInteger)v < wq_accent_colors().count) ? (NSUInteger)v : 0;
}
void wq_set_accent_index(NSUInteger index) { [NSUserDefaults.standardUserDefaults setInteger:(NSInteger)index forKey:kWQAccentPref]; }
UIColor *wq_accent_color(void) { return wq_accent_colors()[wq_accent_index()]; }

void wq_reset_appearance(void)
{
    for (NSString *key in @[kWQThemePref, kWQGlassPref, kWQColoredIconsPref, kWQAccentPref])
        [NSUserDefaults.standardUserDefaults removeObjectForKey:key];
}

void wq_apply_appearance(UIWindow *window)
{
    NSMutableArray<UIWindow *> *windows = [NSMutableArray new];
    if (window) [windows addObject:window];
    for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
        if (![scene isKindOfClass:UIWindowScene.class]) continue;
        for (UIWindow *w in ((UIWindowScene *)scene).windows)
            if (![windows containsObject:w]) [windows addObject:w];
    }
    WQTheme theme = wq_theme();
    UIUserInterfaceStyle style = theme == WQThemeLight ? UIUserInterfaceStyleLight
                               : theme == WQThemeDark ? UIUserInterfaceStyleDark
                               : UIUserInterfaceStyleUnspecified;
    UIColor *accent = wq_accent_color();
    for (UIWindow *w in windows) {
        w.overrideUserInterfaceStyle = style;
        w.tintColor = accent;
    }
}

// The soft gradient behind the lists. It only uses the accent color with
// transparency, so the system background (light or dark) shows through.
@interface WQGradientView : UIView
@end
@implementation WQGradientView
+ (Class)layerClass { return CAGradientLayer.class; }
- (instancetype)initWithFrame:(CGRect)frame
{
    self = [super initWithFrame:frame];
    if (self) {
        self.backgroundColor = UIColor.systemGroupedBackgroundColor;
        UIColor *accent = wq_accent_color();
        CAGradientLayer *gradient = (CAGradientLayer *)self.layer;
        gradient.colors = @[(id)[accent colorWithAlphaComponent:0.42].CGColor,
                            (id)[accent colorWithAlphaComponent:0.0].CGColor,
                            (id)[accent colorWithAlphaComponent:0.24].CGColor];
        gradient.locations = @[@0.0, @0.55, @1.0];
        gradient.startPoint = CGPointMake(0.15, 0.0);
        gradient.endPoint = CGPointMake(0.85, 1.0);
    }
    return self;
}
@end

void wq_style_table(UITableView *table)
{
    table.backgroundView = wq_glass_enabled() ? [WQGradientView new] : nil;
}

void wq_style_cell(UITableViewCell *cell)
{
    if (!wq_glass_enabled()) {
        cell.configurationUpdateHandler = nil;
        cell.backgroundConfiguration = nil;
        return;
    }
    cell.configurationUpdateHandler = ^(UITableViewCell *c, UICellConfigurationState *state) {
        UIBackgroundConfiguration *bg = [[UIBackgroundConfiguration listCellConfiguration] updatedConfigurationForState:state];
        bg.visualEffect = [UIBlurEffect effectWithStyle:UIBlurEffectStyleSystemThinMaterial];
        bg.backgroundColor = (state.highlighted || state.selected) ? [UIColor.labelColor colorWithAlphaComponent:0.10]
                                                                         : UIColor.clearColor;
        bg.strokeColor = [UIColor.whiteColor colorWithAlphaComponent:0.28];
        bg.strokeWidth = 0.5;
        c.backgroundConfiguration = bg;
    };
}

UIImage *wq_badge_image(NSString *symbol, UIColor *color)
{
    static NSMutableDictionary<NSString *, UIImage *> *cache;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ cache = [NSMutableDictionary new]; });
    CGFloat r = 0, g = 0, b = 0, a = 0;
    [color getRed:&r green:&g blue:&b alpha:&a];
    NSString *key = [NSString stringWithFormat:@"%@|%.2f,%.2f,%.2f|%ld", symbol, r, g, b,
                     (long)UITraitCollection.currentTraitCollection.userInterfaceStyle];
    UIImage *hit = cache[key];
    if (hit) return hit;
    const CGFloat side = 30;
    UIGraphicsImageRenderer *renderer = [[UIGraphicsImageRenderer alloc] initWithSize:CGSizeMake(side, side)];
    UIImage *image = [renderer imageWithActions:^(UIGraphicsImageRendererContext *__unused ctx) {
        [color setFill];
        [[UIBezierPath bezierPathWithRoundedRect:CGRectMake(0, 0, side, side) cornerRadius:8] fill];
        UIImageSymbolConfiguration *cfg = [UIImageSymbolConfiguration configurationWithPointSize:15 weight:UIImageSymbolWeightSemibold];
        UIImage *glyph = [[UIImage systemImageNamed:symbol withConfiguration:cfg]
                          imageWithTintColor:UIColor.whiteColor renderingMode:UIImageRenderingModeAlwaysOriginal];
        CGSize size = glyph.size;
        [glyph drawInRect:CGRectMake((side - size.width) / 2, (side - size.height) / 2, size.width, size.height)];
    }];
    cache[key] = image;
    return image;
}

// Telegram's blue circle with a paper plane. Drawn by hand, so it is an
// approximation of the official logo.
UIImage *wq_telegram_icon(CGFloat side)
{
    UIGraphicsImageRenderer *renderer = [[UIGraphicsImageRenderer alloc] initWithSize:CGSizeMake(side, side)];
    return [renderer imageWithActions:^(UIGraphicsImageRendererContext *__unused ctx) {
        UIColor *blue = [UIColor colorWithRed:0.133 green:0.620 blue:0.851 alpha:1];
        [blue setFill];
        [[UIBezierPath bezierPathWithOvalInRect:CGRectMake(0, 0, side, side)] fill];
        #define P(x, y) CGPointMake((x) * side, (y) * side)
        UIBezierPath *plane = [UIBezierPath bezierPath];
        [plane moveToPoint:P(0.78, 0.27)];
        [plane addLineToPoint:P(0.21, 0.49)];
        [plane addLineToPoint:P(0.35, 0.57)];
        [plane addLineToPoint:P(0.41, 0.75)];
        [plane addLineToPoint:P(0.50, 0.64)];
        [plane addLineToPoint:P(0.64, 0.73)];
        [plane closePath];
        [UIColor.whiteColor setFill];
        [plane fill];
        UIBezierPath *fold = [UIBezierPath bezierPath];
        [fold moveToPoint:P(0.35, 0.57)];
        [fold addLineToPoint:P(0.70, 0.38)];
        fold.lineWidth = MAX(1, side * 0.035);
        [blue setStroke];
        [fold stroke];
        #undef P
    }];
}

#pragma mark - Appearance screen

@implementation WQAppearanceViewController

- (instancetype)init { return [super initWithStyle:UITableViewStyleInsetGrouped]; }

- (void)viewDidLoad
{
    [super viewDidLoad];
    self.title = WQLocalized(@"Appearance");
    self.navigationItem.largeTitleDisplayMode = UINavigationItemLargeTitleDisplayModeNever;
}

- (void)viewWillAppear:(BOOL)animated
{
    [super viewWillAppear:animated];
    wq_style_table(self.tableView);
    [self.tableView reloadData];
}

- (void)changed
{
    wq_apply_appearance(self.view.window);
    wq_style_table(self.tableView);
    __weak typeof(self) weakSelf = self;
    dispatch_async(dispatch_get_main_queue(), ^{ [weakSelf.tableView reloadData]; });
}

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView { return 4; }

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section
{
    static const NSInteger counts[4] = {3, 2, 1, 1};
    return counts[section];
}

- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section
{
    if (section == 0) return WQLocalized(@"Theme");
    if (section == 2) return WQLocalized(@"Accent Color");
    return nil;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath
{
    UITableViewCell *cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:nil];
    wq_style_cell(cell);
    UIListContentConfiguration *c = cell.defaultContentConfiguration;
    __weak typeof(self) weakSelf = self;
    if (indexPath.section == 0) {
        NSArray<NSString *> *names = @[@"System", @"Light", @"Dark"];
        NSArray<NSString *> *symbols = @[@"circle.lefthalf.filled", @"sun.max.fill", @"moon.fill"];
        c.text = WQLocalized(names[(NSUInteger)indexPath.row]);
        c.image = [UIImage systemImageNamed:symbols[(NSUInteger)indexPath.row]];
        cell.contentConfiguration = c;
        cell.accessoryType = (NSInteger)wq_theme() == indexPath.row ? UITableViewCellAccessoryCheckmark : UITableViewCellAccessoryNone;
        return cell;
    }
    if (indexPath.section == 1) {
        BOOL glass = indexPath.row == 0;
        c.text = WQLocalized(glass ? @"Glass Effect" : @"Colored Icons");
        c.image = [UIImage systemImageNamed:glass ? @"square.on.square.intersection.dashed" : @"paintpalette.fill"];
        cell.contentConfiguration = c;
        cell.selectionStyle = UITableViewCellSelectionStyleNone;
        UISwitch *toggle = [UISwitch new];
        toggle.on = glass ? wq_glass_enabled() : wq_colored_icons();
        [toggle addAction:[UIAction actionWithHandler:^(UIAction *action) {
            BOOL on = ((UISwitch *)action.sender).on;
            if (glass) wq_set_glass_enabled(on); else wq_set_colored_icons(on);
            [weakSelf changed];
        }] forControlEvents:UIControlEventValueChanged];
        cell.accessoryView = toggle;
        return cell;
    }
    if (indexPath.section == 2) {
        cell.selectionStyle = UITableViewCellSelectionStyleNone;
        NSArray<UIColor *> *colors = wq_accent_colors();
        NSMutableArray<UIButton *> *buttons = [NSMutableArray new];
        for (NSUInteger i = 0; i < colors.count; i++) {
            UIButton *button = [UIButton buttonWithType:UIButtonTypeCustom];
            button.backgroundColor = colors[i];
            button.layer.cornerRadius = 16;
            button.tintColor = UIColor.whiteColor;
            [button.widthAnchor constraintEqualToConstant:32].active = YES;
            [button.heightAnchor constraintEqualToConstant:32].active = YES;
            if (i == wq_accent_index()) {
                button.layer.borderWidth = 3;
                button.layer.borderColor = UIColor.whiteColor.CGColor;
                [button setImage:[UIImage systemImageNamed:@"checkmark"
                                          withConfiguration:[UIImageSymbolConfiguration configurationWithPointSize:13 weight:UIImageSymbolWeightBold]]
                        forState:UIControlStateNormal];
            }
            [button addAction:[UIAction actionWithHandler:^(UIAction *__unused a) {
                wq_set_accent_index(i);
                [weakSelf changed];
            }] forControlEvents:UIControlEventTouchUpInside];
            [buttons addObject:button];
        }
        UIStackView *stack = [[UIStackView alloc] initWithArrangedSubviews:buttons];
        stack.axis = UILayoutConstraintAxisHorizontal;
        stack.distribution = UIStackViewDistributionEqualSpacing;
        stack.translatesAutoresizingMaskIntoConstraints = NO;
        [cell.contentView addSubview:stack];
        UILayoutGuide *margins = cell.contentView.layoutMarginsGuide;
        [NSLayoutConstraint activateConstraints:@[
            [stack.leadingAnchor constraintEqualToAnchor:margins.leadingAnchor],
            [stack.trailingAnchor constraintEqualToAnchor:margins.trailingAnchor],
            [stack.topAnchor constraintEqualToAnchor:cell.contentView.topAnchor constant:14],
            [stack.bottomAnchor constraintEqualToAnchor:cell.contentView.bottomAnchor constant:-14],
        ]];
        return cell;
    }
    c.text = WQLocalized(@"Reset Appearance");
    c.textProperties.color = UIColor.systemRedColor;
    cell.contentConfiguration = c;
    return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath
{
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    if (indexPath.section == 0) { wq_set_theme((WQTheme)indexPath.row); [self changed]; }
    else if (indexPath.section == 3) { wq_reset_appearance(); [self changed]; }
}

@end

#pragma mark - About screen

@implementation WQAboutViewController {
    NSArray<NSDictionary *> *_sections;   // title, rows (title, detail, url, text)
}

- (instancetype)init { return [super initWithStyle:UITableViewStyleInsetGrouped]; }

- (void)viewDidLoad
{
    [super viewDidLoad];
    self.title = WQLocalized(@"About");
    self.navigationItem.largeTitleDisplayMode = UINavigationItemLargeTitleDisplayModeNever;
    NSDictionary *info = NSBundle.mainBundle.infoDictionary;
    NSString *version = [NSString stringWithFormat:@"%@ (%@)", info[@"CFBundleShortVersionString"] ?: @"?", info[@"CFBundleVersion"] ?: @"?"];
    _sections = @[
        @{@"title": @"", @"rows": @[
            @{@"title": WQLocalized(@"Version"), @"detail": version},
            @{@"title": @"Telegram", @"detail": @"t.me/didierxit7", @"url": @"https://t.me/didierxit7", @"telegram": @YES},
        ]},
        @{@"title": WQLocalized(@"Help"), @"rows": @[
            @{@"text": WQLocalized(@"Overwritten and deleted files are copied to Backups first (also visible in the Files app). Long-press a backup to restore it.")},
            @{@"text": WQLocalized(@"Allow Deleting: when off, nothing can be deleted: no Delete or swipe to delete in folders and backups, no Clear Data in Apps and no cleaning in the Cache Cleaner. Saving, moving and restoring still work.\n\nShow Item Counts: shows how many items each folder holds. Every subfolder has to be listed for this, which slows down folders with many subfolders, especially in other apps' data.")},
            @{@"text": WQLocalized(@"Keep Data Before Restore: restoring an app or file backup first backs up what's there now, so a failed restore can be undone. When off, that backup is deleted once the restore succeeded.")},
            @{@"text": WQLocalized(@"On iOS 26, System Data and System Groups can't be reached (worse_query covers them on iOS 27 only), and Internal Daemons need a scan of every file id: the first one can take most of an hour on a well-used device, later ones only check new files.")},
        ]},
        @{@"title": WQLocalized(@"Credits"), @"rows": @[
            @{@"title": @"WQ Files", @"detail": @"kolbicz", @"url": @"https://github.com/kolbicz/WQFiles"},
            @{@"title": @"worse_query", @"detail": @"@forcequitOS", @"url": @"https://github.com/forcequitOS/worse_query"},
            @{@"title": @"GPL-3.0-or-later", @"detail": @"gnu.org", @"url": @"https://www.gnu.org/licenses/gpl-3.0.html"},
        ]},
    ];
}

- (void)viewWillAppear:(BOOL)animated
{
    [super viewWillAppear:animated];
    wq_style_table(self.tableView);
    [self.tableView reloadData];
}

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView { return (NSInteger)_sections.count; }

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section
{
    return (NSInteger)[_sections[(NSUInteger)section][@"rows"] count];
}

- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section
{
    NSString *title = _sections[(NSUInteger)section][@"title"];
    return title.length ? title : nil;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath
{
    NSDictionary *row = _sections[(NSUInteger)indexPath.section][@"rows"][(NSUInteger)indexPath.row];
    UITableViewCell *cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:nil];
    wq_style_cell(cell);
    if (row[@"text"]) {
        UIListContentConfiguration *c = cell.defaultContentConfiguration;
        c.text = row[@"text"];
        c.textProperties.font = [UIFont preferredFontForTextStyle:UIFontTextStyleFootnote];
        c.textProperties.color = UIColor.secondaryLabelColor;
        cell.contentConfiguration = c;
        cell.selectionStyle = UITableViewCellSelectionStyleNone;
        return cell;
    }
    UIListContentConfiguration *c = [UIListContentConfiguration valueCellConfiguration];
    c.text = row[@"title"];
    c.secondaryText = row[@"detail"];
    if (row[@"telegram"]) {
        c.image = wq_telegram_icon(24);
        c.imageProperties.reservedLayoutSize = CGSizeMake(24, 24);
    }
    cell.contentConfiguration = c;
    if (row[@"url"]) cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
    else cell.selectionStyle = UITableViewCellSelectionStyleNone;
    return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath
{
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    NSString *url = _sections[(NSUInteger)indexPath.section][@"rows"][(NSUInteger)indexPath.row][@"url"];
    if (url) [UIApplication.sharedApplication openURL:[NSURL URLWithString:url] options:@{} completionHandler:nil];
}

@end
