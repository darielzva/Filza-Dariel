//
//  WQUI.m
//  WQ Files shared UI helpers
//  GPL-3.0-or-later.
//

#import "WQUI.h"
#import "WQAccess.h"
#import "WQArchive.h"
#import "WQApps.h"
#import "WQDir.h"
#import "WQLaunchServices.h"
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>
#import <fcntl.h>
#import <sys/stat.h>
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


#pragma mark - Patches

// A patch is a folder in DM FILES' Documents/Patches (visible in the Files app):
//   patch.json  {"name": "...", "bundleID": "com.example.app",
//                "files": [{"source": "file.bin", "target": "Documents/path/file.bin"}]}
//   file.bin    the files named as "source"
// Apply copies each file into the app's data folder at "target"; what was
// there is saved first (in the patch folder and in Backups) so Restore
// Original puts it back.

static NSString *wq_patches_root(void)
{
    NSString *docs = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject;
    NSString *dir = [docs stringByAppendingPathComponent:@"Patches"];
    [NSFileManager.defaultManager createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:nil];
    return dir;
}

static BOOL wq_patch_rel_ok(id value)
{
    if (![value isKindOfClass:NSString.class]) return NO;
    NSString *rel = value;
    if (!rel.length || [rel hasPrefix:@"/"]) return NO;
    for (NSString *part in [rel componentsSeparatedByString:@"/"])
        if (!part.length || [part isEqualToString:@"."] || [part isEqualToString:@".."]) return NO;
    return YES;
}

static NSDictionary *wq_patch_read(NSString *folder, NSString **errorText)
{
    NSString *problem = nil;
    NSData *data = [NSData dataWithContentsOfFile:[folder stringByAppendingPathComponent:@"patch.json"]];
    id json = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
    NSDictionary *dict = [json isKindOfClass:NSDictionary.class] ? json : nil;
    NSString *bid = [dict[@"bundleID"] isKindOfClass:NSString.class] ? dict[@"bundleID"] : nil;
    NSArray *files = [dict[@"files"] isKindOfClass:NSArray.class] ? dict[@"files"] : nil;
    NSCharacterSet *allowed = [NSCharacterSet characterSetWithCharactersInString:
        @"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789.-_"];
    NSMutableArray<NSDictionary *> *clean = [NSMutableArray new];
    if (!data) problem = @"patch.json is missing.";
    else if (!dict) problem = @"patch.json isn't valid JSON.";
    else if (!bid.length || ![bid containsString:@"."] || [bid rangeOfCharacterFromSet:allowed.invertedSet].location != NSNotFound)
        problem = @"patch.json needs a valid \"bundleID\".";
    else if (!files.count) problem = @"patch.json needs a \"files\" list.";
    else {
        for (id entry in files) {
            NSString *source = [entry isKindOfClass:NSDictionary.class] ? entry[@"source"] : nil;
            NSString *target = [entry isKindOfClass:NSDictionary.class] ? entry[@"target"] : nil;
            if (!wq_patch_rel_ok(source) || !wq_patch_rel_ok(target)) { problem = @"Every file needs a relative \"source\" and \"target\" (no \"..\")."; break; }
            if (!([target hasPrefix:@"Documents/"] || [target hasPrefix:@"Library/"] || [target hasPrefix:@"tmp/"])) {
                problem = [NSString stringWithFormat:@"The target %@ must start with Documents/, Library/ or tmp/.", target]; break;
            }
            BOOL isDir = NO;
            if (![NSFileManager.defaultManager fileExistsAtPath:[folder stringByAppendingPathComponent:source] isDirectory:&isDir] || isDir) {
                problem = [NSString stringWithFormat:@"The file %@ is missing from the patch folder.", source]; break;
            }
            [clean addObject:@{@"source": source, @"target": target}];
        }
    }
    if (problem) { if (errorText) *errorText = problem; return nil; }
    NSString *name = [dict[@"name"] isKindOfClass:NSString.class] && [dict[@"name"] length] ? dict[@"name"] : folder.lastPathComponent;
    return @{@"folder": folder, @"name": name, @"bundleID": bid, @"files": clean};
}

static NSMutableDictionary *wq_patch_state(NSString *folder)
{
    NSData *data = [NSData dataWithContentsOfFile:[folder stringByAppendingPathComponent:@"state.json"]];
    id json = data ? [NSJSONSerialization JSONObjectWithData:data options:NSJSONReadingMutableContainers error:nil] : nil;
    NSMutableDictionary *state = [json isKindOfClass:NSMutableDictionary.class] ? json : [NSMutableDictionary new];
    if (![state[@"entries"] isKindOfClass:NSMutableDictionary.class]) state[@"entries"] = [NSMutableDictionary new];
    return state;
}

static void wq_patch_save_state(NSString *folder, NSDictionary *state)
{
    NSData *data = [NSJSONSerialization dataWithJSONObject:state options:NSJSONWritingPrettyPrinted error:nil];
    [data writeToFile:[folder stringByAppendingPathComponent:@"state.json"] atomically:YES];
}

// The app's data folder, found like the Apps screen does. Blocking: call off the main thread.
NSString *wq_data_container_for_bundle(NSString *bundleID)
{
    NSArray<NSString *> *containers = wq_enumerate(@"/private/var/mobile/Containers/Data/Application", 0, nil, nil);
    for (NSString *c in containers) {
        NSString *label = wq_container_label(c);
        if (!label.length) label = wq_bundle_id_for_container(c);
        if ([label isEqualToString:bundleID]) return c;
    }
    return nil;
}

// Creates the missing folders above dst, inside the container.
static BOOL wq_patch_make_parents(NSString *container, NSString *dst, NSString **errorText)
{
    NSMutableArray<NSString *> *missing = [NSMutableArray new];
    NSString *parent = dst.stringByDeletingLastPathComponent;
    struct stat st;
    while (parent.length > container.length && !wq_stat(parent, &st)) {
        [missing insertObject:parent atIndex:0];
        parent = parent.stringByDeletingLastPathComponent;
    }
    for (NSString *dir in missing) {
        NSString *error = nil;
        if (!wq_create_dir(dir, &error)) { if (errorText) *errorText = error ?: @"Couldn't create a folder."; return NO; }
    }
    return YES;
}

static NSString *wq_patch_apply(NSDictionary *patch)
{
    NSString *bid = patch[@"bundleID"], *folder = patch[@"folder"];
    NSString *container = wq_data_container_for_bundle(bid);
    if (!container) return [NSString stringWithFormat:@"%@ isn't installed, or its data folder can't be found.", bid];
    wq_grant(container);
    NSFileManager *fm = NSFileManager.defaultManager;
    NSMutableDictionary *state = wq_patch_state(folder);
    NSMutableDictionary *entries = state[@"entries"];
    NSString *originals = [folder stringByAppendingPathComponent:@".originals"];
    NSArray<NSDictionary *> *files = patch[@"files"];
    for (NSUInteger i = 0; i < files.count; i++) {
        NSString *target = files[i][@"target"];
        NSString *source = [folder stringByAppendingPathComponent:files[i][@"source"]];
        NSString *dst = [container stringByAppendingPathComponent:target];
        struct stat st;
        BOOL present = wq_stat(dst, &st);
        if (present && !S_ISREG(st.st_mode)) return [NSString stringWithFormat:@"%@ isn't a regular file.", target];
        NSString *error = nil;
        if (!entries[target]) {   // first time: keep what is there now
            if (present) {
                [fm createDirectoryAtPath:originals withIntermediateDirectories:YES attributes:nil error:nil];
                NSString *saved = [originals stringByAppendingPathComponent:[NSString stringWithFormat:@"%lu", (unsigned long)i]];
                [fm removeItemAtPath:saved error:nil];
                if (!wq_copy_to_local(dst, saved, &error))
                    return error ?: [NSString stringWithFormat:@"Couldn't save the original of %@.", target];
            }
            entries[target] = @{@"existed": @(present), @"index": @(i)};
            wq_patch_save_state(folder, state);
        }
        if (present) {
            if (!wq_write_from_file_with_backup(dst, source, NULL, &error))
                return error ?: [NSString stringWithFormat:@"Couldn't write %@.", target];
        } else {
            if (!wq_patch_make_parents(container, dst, &error)) return error;
            if (!wq_create_file_from(dst, source, &error))
                return error ?: [NSString stringWithFormat:@"Couldn't create %@.", target];
        }
    }
    state[@"applied"] = @YES;
    wq_patch_save_state(folder, state);
    return nil;
}

static NSString *wq_patch_restore(NSDictionary *patch)
{
    NSString *bid = patch[@"bundleID"], *folder = patch[@"folder"];
    NSString *container = wq_data_container_for_bundle(bid);
    if (!container) return [NSString stringWithFormat:@"%@ isn't installed, or its data folder can't be found.", bid];
    wq_grant(container);
    NSFileManager *fm = NSFileManager.defaultManager;
    NSDictionary *entries = wq_patch_state(folder)[@"entries"];
    NSString *originals = [folder stringByAppendingPathComponent:@".originals"];
    for (NSString *target in entries) {
        NSDictionary *entry = entries[target];
        NSString *dst = [container stringByAppendingPathComponent:target];
        struct stat st;
        BOOL present = wq_stat(dst, &st);
        NSString *error = nil;
        if ([entry[@"existed"] boolValue]) {
            NSString *saved = [originals stringByAppendingPathComponent:[NSString stringWithFormat:@"%@", entry[@"index"]]];
            if (![fm fileExistsAtPath:saved]) return [NSString stringWithFormat:@"The saved original of %@ is missing.", target];
            if (present) {
                if (!wq_write_from_file(dst, saved, &error)) return error ?: [NSString stringWithFormat:@"Couldn't restore %@.", target];
            } else {
                if (!wq_patch_make_parents(container, dst, &error)) return error;
                if (!wq_create_file_from(dst, saved, &error)) return error ?: [NSString stringWithFormat:@"Couldn't restore %@.", target];
            }
        } else if (present) {
            if (!wq_delete(dst, &error)) return error ?: [NSString stringWithFormat:@"Couldn't remove %@.", target];
        }
    }
    [fm removeItemAtPath:[folder stringByAppendingPathComponent:@"state.json"] error:nil];
    [fm removeItemAtPath:originals error:nil];
    return nil;
}

// ---- Single-screen patch form ------------------------------------------
// WQPatchFormViewController: one UITableViewController with all fields in one
// place. Used for both create and edit. Presented modally from WQPatchesViewController.

@protocol WQPatchFormDelegate <NSObject>
- (void)patchFormDidFinish;
@end

typedef NS_ENUM(NSUInteger, WQPatchFormRow) {
    WQPatchFormRowName = 0,
    WQPatchFormRowBundleID,
    WQPatchFormRowTargetPath,
    WQPatchFormRowFile,
    WQPatchFormRowCount,
};

@interface WQPatchFormViewController : UITableViewController
                                      <UIDocumentPickerDelegate,
                                       WQPatchRoutePickerDelegate>
@property (nonatomic, weak) id<WQPatchFormDelegate> delegate;
// Pre-fill for create-from-route:
@property (nonatomic, copy, nullable) NSString *prefilledTargetPath;
@property (nonatomic, copy, nullable) NSString *prefilledBundleID;
// Pre-fill for edit:
@property (nonatomic, copy, nullable) NSString *editingFolder;
@property (nonatomic, copy, nullable) NSString *existingSourceName;
@end

@implementation WQPatchFormViewController {
    UITextField *_nameField;
    UITextField *_bundleIDField;
    UITextField *_targetPathField;
    UILabel     *_fileLabel;    // shows the picked filename
    NSURL       *_pickedFileURL;
}

- (instancetype)init
{
    return [super initWithStyle:UITableViewStyleInsetGrouped];
}

- (void)viewDidLoad
{
    [super viewDidLoad];
    BOOL editing = (_editingFolder != nil);
    self.title = editing ? @"Editar parche" : @"Crear parche";
    wq_style_table(self.tableView);

    self.navigationItem.leftBarButtonItem =
        [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemCancel
                                                      target:self
                                                      action:@selector(cancel)];
    self.navigationItem.rightBarButtonItem =
        [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemSave
                                                      target:self
                                                      action:@selector(save)];
}

- (void)cancel
{
    [self dismissViewControllerAnimated:YES completion:nil];
}

// ---- Table structure ---------------------------------------------------

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tv { return 1; }
- (NSInteger)tableView:(UITableView *)tv numberOfRowsInSection:(NSInteger)s
{
    return (NSInteger)WQPatchFormRowCount;
}

- (NSString *)tableView:(UITableView *)tv titleForHeaderInSection:(NSInteger)s
{
    return nil;
}

- (NSString *)tableView:(UITableView *)tv titleForFooterInSection:(NSInteger)s
{
    return @"La ruta destino debe empezar con Documents/, Library/ o tmp/. "
            "El archivo se copiará con el nombre del último componente de esa ruta.";
}

- (UITableViewCell *)tableView:(UITableView *)tv
         cellForRowAtIndexPath:(NSIndexPath *)indexPath
{
    UITableViewCell *cell =
        [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:nil];
    wq_style_cell(cell);
    UIListContentConfiguration *c = cell.defaultContentConfiguration;

    switch ((WQPatchFormRow)indexPath.row) {

        case WQPatchFormRowName: {
            c.text = @"Nombre";
            cell.contentConfiguration = c;
            UITextField *tf = [self makeTextField:@"Mi parche FreeFire"
                                             text:_nameField.text ?: (_editingFolder ? _editingFolder.lastPathComponent : nil)];
            tf.returnKeyType = UIReturnKeyNext;
            [tf addTarget:self action:@selector(nameFieldChanged:) forControlEvents:UIControlEventEditingChanged];
            [tf addTarget:self action:@selector(focusBundleID) forControlEvents:UIControlEventEditingDidEndOnExit];
            _nameField = tf;
            cell.accessoryView = tf;
            cell.selectionStyle = UITableViewCellSelectionStyleNone;
            break;
        }

        case WQPatchFormRowBundleID: {
            c.text = @"Bundle ID";
            cell.contentConfiguration = c;
            UITextField *tf = [self makeTextField:@"com.dts.freefireth"
                                             text:_bundleIDField.text ?: _prefilledBundleID];
            tf.keyboardType              = UIKeyboardTypeURL;
            tf.autocapitalizationType    = UITextAutocapitalizationTypeNone;
            tf.autocorrectionType        = UITextAutocorrectionTypeNo;
            tf.returnKeyType             = UIReturnKeyNext;
            [tf addTarget:self action:@selector(focusTargetPath) forControlEvents:UIControlEventEditingDidEndOnExit];
            _bundleIDField = tf;
            cell.accessoryView = tf;
            cell.selectionStyle = UITableViewCellSelectionStyleNone;
            break;
        }

        case WQPatchFormRowTargetPath: {
            c.text = @"Ruta destino";
            cell.contentConfiguration = c;
            UITextField *tf = [self makeTextField:@"Documents/…/archivo.bundle"
                                             text:_targetPathField.text ?: _prefilledTargetPath];
            tf.keyboardType              = UIKeyboardTypeURL;
            tf.autocapitalizationType    = UITextAutocapitalizationTypeNone;
            tf.autocorrectionType        = UITextAutocorrectionTypeNo;
            tf.returnKeyType             = UIReturnKeyDone;
            _targetPathField = tf;

            // "Buscar ruta" button inside the cell's content area
            UIButton *browseBtn = [UIButton buttonWithType:UIButtonTypeSystem];
            [browseBtn setTitle:@"Buscar ruta" forState:UIControlStateNormal];
            browseBtn.titleLabel.font = [UIFont systemFontOfSize:14];
            [browseBtn addTarget:self action:@selector(browseRoute)
                forControlEvents:UIControlEventTouchUpInside];
            [browseBtn sizeToFit];
            cell.accessoryView = browseBtn;

            // Target path text field goes below the label — use a custom subview layout
            cell.contentConfiguration = nil;
            UILabel *lbl = [[UILabel alloc] init];
            lbl.text = @"Ruta destino";
            lbl.font = [UIFont systemFontOfSize:17];
            lbl.translatesAutoresizingMaskIntoConstraints = NO;
            tf.translatesAutoresizingMaskIntoConstraints = NO;
            tf.font = [UIFont systemFontOfSize:14];
            tf.textColor = UIColor.secondaryLabelColor;
            [cell.contentView addSubview:lbl];
            [cell.contentView addSubview:tf];
            [NSLayoutConstraint activateConstraints:@[
                [lbl.leadingAnchor constraintEqualToAnchor:cell.contentView.layoutMarginsGuide.leadingAnchor],
                [lbl.centerYAnchor constraintEqualToAnchor:cell.contentView.centerYAnchor],
                [tf.leadingAnchor constraintEqualToAnchor:lbl.trailingAnchor constant:8],
                [tf.trailingAnchor constraintEqualToAnchor:cell.contentView.layoutMarginsGuide.trailingAnchor],
                [tf.centerYAnchor constraintEqualToAnchor:cell.contentView.centerYAnchor],
            ]];
            cell.selectionStyle = UITableViewCellSelectionStyleNone;
            break;
        }

        case WQPatchFormRowFile: {
            NSString *fileName = _pickedFileURL.lastPathComponent
                ?: _existingSourceName
                ?: @"Ninguno";
            c.text             = @"Archivo";
            c.secondaryText    = fileName;
            c.image            = [UIImage systemImageNamed:@"doc.fill"];
            cell.contentConfiguration = c;
            cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
            break;
        }

        case WQPatchFormRowCount: break;
    }
    return cell;
}

- (void)tableView:(UITableView *)tv didSelectRowAtIndexPath:(NSIndexPath *)indexPath
{
    [tv deselectRowAtIndexPath:indexPath animated:YES];
    if ((WQPatchFormRow)indexPath.row == WQPatchFormRowFile) {
        [self pickFile];
    }
}

// ---- Helpers -----------------------------------------------------------

- (UITextField *)makeTextField:(NSString *)placeholder text:(NSString *_Nullable)text
{
    UITextField *tf = [[UITextField alloc] initWithFrame:CGRectMake(0, 0, 200, 34)];
    tf.placeholder       = placeholder;
    tf.text              = text;
    tf.clearButtonMode   = UITextFieldViewModeWhileEditing;
    tf.textAlignment     = NSTextAlignmentRight;
    tf.font              = [UIFont systemFontOfSize:17];
    return tf;
}

- (void)nameFieldChanged:(UITextField *)tf   { /* live validation hook if needed */ }
- (void)focusBundleID  { [_bundleIDField becomeFirstResponder]; }
- (void)focusTargetPath { [_targetPathField becomeFirstResponder]; }

// ---- "Buscar ruta" -----------------------------------------------------

- (void)browseRoute
{
    // Push the Apps list; when the user taps a file in a data folder,
    // patchRoutePickerDidSelectPath:bundleID: is called back on us.
    WQAppsViewController *apps = [WQAppsViewController new];
    apps.patchRoutePickerDelegate = self;
    apps.navigationItem.prompt = @"Selecciona el archivo destino del parche";
    [self.navigationController pushViewController:apps animated:YES];
}

- (void)patchRoutePickerDidSelectPath:(NSString *)relativePath
                             bundleID:(NSString *)bundleID
{
    // Called from WQDirViewController when the user picks a file.
    _targetPathField.text = relativePath;
    _bundleIDField.text   = bundleID;
    // Pop back to this form.
    [self.navigationController popToViewController:self animated:YES];
    [self.tableView reloadData];
}

// ---- File picker -------------------------------------------------------

- (void)pickFile
{
    UIDocumentPickerViewController *picker =
        [[UIDocumentPickerViewController alloc] initForOpeningContentTypes:@[UTTypeData]
                                                                    asCopy:YES];
    picker.delegate = self;
    [self presentViewController:picker animated:YES completion:nil];
}

- (void)documentPicker:(UIDocumentPickerViewController *)__unused c
didPickDocumentsAtURLs:(NSArray<NSURL *> *)urls
{
    _pickedFileURL = urls.firstObject;
    [self.tableView reloadRowsAtIndexPaths:
        @[[NSIndexPath indexPathForRow:(NSInteger)WQPatchFormRowFile inSection:0]]
                          withRowAnimation:UITableViewRowAnimationAutomatic];
}

// ---- Save --------------------------------------------------------------

- (void)save
{
    NSString *name = [_nameField.text stringByTrimmingCharactersInSet:
                      NSCharacterSet.whitespaceAndNewlineCharacterSet];
    NSString *bid  = [_bundleIDField.text stringByTrimmingCharactersInSet:
                      NSCharacterSet.whitespaceAndNewlineCharacterSet];
    NSString *path = [_targetPathField.text stringByTrimmingCharactersInSet:
                      NSCharacterSet.whitespaceAndNewlineCharacterSet];

    if (!name.length) {
        wq_alert(self, @"Crear parche", @"El nombre no puede estar vacío.");
        return;
    }
    NSCharacterSet *allowed = [NSCharacterSet characterSetWithCharactersInString:
        @"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789.-_"];
    if (!bid.length || ![bid containsString:@"."]
        || [bid rangeOfCharacterFromSet:allowed.invertedSet].location != NSNotFound) {
        wq_alert(self, @"Crear parche", @"Bundle ID inválido. Ej: com.dts.freefireth");
        return;
    }
    if (!path.length
        || (!([path hasPrefix:@"Documents/"] || [path hasPrefix:@"Library/"] || [path hasPrefix:@"tmp/"]))) {
        wq_alert(self, @"Crear parche",
                 @"La ruta debe empezar con Documents/, Library/ o tmp/.");
        return;
    }

    BOOL editing = (_editingFolder != nil);
    if (!editing && !_pickedFileURL) {
        wq_alert(self, @"Crear parche", @"Selecciona un archivo para el parche.");
        return;
    }

    __block NSString *sourceName = path.lastPathComponent;
    if (!sourceName.length) sourceName = @"file";

    NSFileManager *fm = NSFileManager.defaultManager;
    NSString *folder;
    if (editing) {
        folder = _editingFolder;
    } else {
        NSString *dir  = wq_patches_root();
        NSString *safe = [name stringByReplacingOccurrencesOfString:@"/" withString:@"-"];
        NSString *candidate = [dir stringByAppendingPathComponent:safe];
        NSString *finalName = safe;
        for (NSUInteger n = 2; [fm fileExistsAtPath:candidate]; n++) {
            finalName   = [NSString stringWithFormat:@"%@ %lu", safe, (unsigned long)n];
            candidate   = [dir stringByAppendingPathComponent:finalName];
        }
        folder = candidate;
    }

    NSURL *pickedURL = _pickedFileURL;
    NSString *existingSource = _existingSourceName;

    // Disable save button while writing.
    self.navigationItem.rightBarButtonItem.enabled = NO;
    __weak typeof(self) weakSelf = self;

    dispatch_async(wq_io(), ^{
        NSString *errorMsg = nil;
        [fm createDirectoryAtPath:folder withIntermediateDirectories:YES attributes:nil error:nil];

        if (pickedURL) {
            NSString *destFile = [folder stringByAppendingPathComponent:sourceName];
            if (editing && existingSource && ![existingSource isEqualToString:sourceName])
                [fm removeItemAtPath:[folder stringByAppendingPathComponent:existingSource] error:nil];
            [fm removeItemAtPath:destFile error:nil];
            BOOL scoped = [pickedURL startAccessingSecurityScopedResource];
            NSError *copyErr = nil;
            [fm copyItemAtPath:pickedURL.path toPath:destFile error:&copyErr];
            if (scoped) [pickedURL stopAccessingSecurityScopedResource];
            if (copyErr) errorMsg = copyErr.localizedDescription;
        } else {
            // Editing with no new file picked: keep existing source filename.
            sourceName = existingSource ?: sourceName;
        }

        if (!errorMsg) {
            NSDictionary *patchJSON = @{
                @"name":     name,
                @"bundleID": bid,
                @"files":    @[@{@"source": sourceName, @"target": path}]
            };
            NSData *data = [NSJSONSerialization dataWithJSONObject:patchJSON
                                                           options:NSJSONWritingPrettyPrinted
                                                                 | NSJSONWritingWithoutEscapingSlashes
                                                             error:nil];
            if (![data writeToFile:[folder stringByAppendingPathComponent:@"patch.json"]
                        atomically:YES])
                errorMsg = @"No se pudo guardar patch.json.";
        }

        dispatch_async(dispatch_get_main_queue(), ^{
            __strong typeof(self) strongSelf = weakSelf;
            if (!strongSelf) return;
            strongSelf.navigationItem.rightBarButtonItem.enabled = YES;
            if (errorMsg) {
                wq_alert(strongSelf, @"Error al guardar", errorMsg);
            } else {
                [strongSelf.delegate patchFormDidFinish];
                [strongSelf dismissViewControllerAnimated:YES completion:nil];
            }
        });
    });
}

@end

// ------------------------------------------------------------------------

// Two distinct document picker modes for WQPatchesViewController itself:
typedef NS_ENUM(NSInteger, WQPickerMode) {
    WQPickerModeImportDM,   // "Importar parche (.dm)" — picks a .dm file
};

@interface WQPatchesViewController () <UIDocumentPickerDelegate, WQPatchFormDelegate>
@end

@implementation WQPatchesViewController {
    NSArray<NSDictionary *> *_patches;   // folder, name, bundleID, files, applied  |  folder, name, error
    WQPickerMode              _pickerMode;
    // Pre-filled from "Crear parche en esta ruta" in WQDirViewController:
    NSString *_prefilledTargetPath;
    NSString *_prefilledBundleID;
}

- (instancetype)init
{
    return [super initWithStyle:UITableViewStyleInsetGrouped];
}

- (instancetype)initWithPrefilledPath:(nullable NSString *)targetPath
                             bundleID:(nullable NSString *)bundleID
{
    if ((self = [super initWithStyle:UITableViewStyleInsetGrouped])) {
        _prefilledTargetPath = [targetPath copy];
        _prefilledBundleID   = [bundleID copy];
    }
    return self;
}

// ---- viewDidLoad -------------------------------------------------------

- (void)viewDidLoad
{
    [super viewDidLoad];
    self.title = WQLocalized(@"Patches");
    self.navigationItem.largeTitleDisplayMode = UINavigationItemLargeTitleDisplayModeNever;
    __weak typeof(self) weakSelf = self;

    UIAction *importAction =
        [UIAction actionWithTitle:@"Importar parche (.dm)"
                            image:[UIImage systemImageNamed:@"arrow.down.doc.fill"]
                       identifier:nil
                          handler:^(UIAction *__unused a) { [weakSelf importDM]; }];

    UIAction *createAction =
        [UIAction actionWithTitle:@"Crear parche"
                            image:[UIImage systemImageNamed:@"plus.app.fill"]
                       identifier:nil
                          handler:^(UIAction *__unused a) { [weakSelf openCreateForm:nil]; }];

    self.navigationItem.rightBarButtonItem =
        [[UIBarButtonItem alloc] initWithImage:[UIImage systemImageNamed:@"plus"]
                                          menu:[UIMenu menuWithChildren:@[importAction, createAction]]];
}

// ---- viewWillAppear / reload -------------------------------------------

- (void)viewWillAppear:(BOOL)animated
{
    [super viewWillAppear:animated];
    wq_style_table(self.tableView);
    [self reload];
}

- (void)viewDidAppear:(BOOL)animated
{
    [super viewDidAppear:animated];
    // When pushed with a pre-filled path (from "Crear parche en esta ruta"),
    // open the form immediately — only once.
    if (_prefilledTargetPath) {
        NSString *path = _prefilledTargetPath;
        NSString *bid  = _prefilledBundleID;
        _prefilledTargetPath = nil;
        _prefilledBundleID   = nil;
        [self openCreateFormWithPath:path bundleID:bid editingPatch:nil];
    }
}

- (void)reload
{
    NSFileManager *fm = NSFileManager.defaultManager;
    NSString *dir = wq_patches_root();
    NSArray<NSString *> *names =
        [[fm contentsOfDirectoryAtPath:dir error:nil]
         sortedArrayUsingSelector:@selector(localizedStandardCompare:)];
    NSMutableArray<NSDictionary *> *items = [NSMutableArray new];
    for (NSString *name in names) {
        if ([name hasPrefix:@"."]) continue;
        NSString *folder = [dir stringByAppendingPathComponent:name];
        BOOL isDir = NO;
        if (![fm fileExistsAtPath:folder isDirectory:&isDir] || !isDir) continue;
        NSString *error = nil;
        NSDictionary *patch = wq_patch_read(folder, &error);
        if (patch) {
            NSMutableDictionary *item = [patch mutableCopy];
            item[@"applied"] = @([wq_patch_state(folder)[@"applied"] boolValue]);
            [items addObject:item];
        } else {
            [items addObject:@{@"folder": folder, @"name": name,
                               @"error": error ?: @"Invalid patch."}];
        }
    }
    _patches = items;
    [self.tableView reloadData];
}

// ---- Import .dm --------------------------------------------------------

- (void)importDM
{
    _pickerMode = WQPickerModeImportDM;
    UTType *dmType = [UTType typeWithFilenameExtension:@"dm"];
    NSArray<UTType *> *types = dmType ? @[dmType] : @[UTTypeData];
    UIDocumentPickerViewController *picker =
        [[UIDocumentPickerViewController alloc] initForOpeningContentTypes:types asCopy:YES];
    picker.delegate = self;
    [self presentViewController:picker animated:YES completion:nil];
}

- (void)handleImportDMAtURL:(NSURL *)url
{
    // .dm is a ZIP. Extract into a temp folder, validate, then move into Patches/.
    NSString *tmpDir = [NSTemporaryDirectory()
                        stringByAppendingPathComponent:[[NSUUID UUID] UUIDString]];
    NSFileManager *fm = NSFileManager.defaultManager;
    [fm createDirectoryAtPath:tmpDir withIntermediateDirectories:YES attributes:nil error:nil];

    NSString *zipPath = url.path;
    NSString *extractError = nil;
    NSUInteger filesExtracted = 0, skipped = 0;
    BOOL ok = wq_zip_extract(zipPath, tmpDir, wq_archive_posix_io(),
                             512ULL * 1024 * 1024,   // 512 MB limit
                             nil, nil,
                             &filesExtracted, &skipped, &extractError);
    if (!ok) {
        [fm removeItemAtPath:tmpDir error:nil];
        wq_alert(self, @"Importar parche", extractError ?: @"El archivo .dm no se pudo descomprimir.");
        return;
    }

    // The archive may put everything under a single top-level folder, or directly.
    // Find the folder that contains patch.json.
    NSString *patchFolder = [self findPatchFolderIn:tmpDir];
    if (!patchFolder) {
        [fm removeItemAtPath:tmpDir error:nil];
        wq_alert(self, @"Parche inválido", @"El archivo .dm no contiene patch.json.");
        return;
    }

    NSString *validationError = nil;
    if (!wq_patch_read(patchFolder, &validationError)) {
        [fm removeItemAtPath:tmpDir error:nil];
        wq_alert(self, @"Parche inválido", validationError ?: @"patch.json no es válido.");
        return;
    }

    // Move the validated folder into Patches/.
    NSString *dir = wq_patches_root();
    NSString *destName = patchFolder.lastPathComponent;
    NSString *dest = [dir stringByAppendingPathComponent:destName];
    for (NSUInteger n = 2; [fm fileExistsAtPath:dest]; n++) {
        destName = [NSString stringWithFormat:@"%@ %lu", patchFolder.lastPathComponent, (unsigned long)n];
        dest = [dir stringByAppendingPathComponent:destName];
    }
    NSError *moveError = nil;
    if (![fm moveItemAtPath:patchFolder toPath:dest error:&moveError]) {
        [fm removeItemAtPath:tmpDir error:nil];
        wq_alert(self, @"Error al importar", moveError.localizedDescription);
        return;
    }
    [fm removeItemAtPath:tmpDir error:nil];
    [self reload];
}

// Returns the path that directly contains patch.json, searching one level deep.
- (nullable NSString *)findPatchFolderIn:(NSString *)root
{
    NSFileManager *fm = NSFileManager.defaultManager;
    if ([fm fileExistsAtPath:[root stringByAppendingPathComponent:@"patch.json"]]) return root;
    for (NSString *name in [fm contentsOfDirectoryAtPath:root error:nil]) {
        if ([name hasPrefix:@"."]) continue;
        NSString *sub = [root stringByAppendingPathComponent:name];
        BOOL isDir = NO;
        if ([fm fileExistsAtPath:sub isDirectory:&isDir] && isDir) {
            if ([fm fileExistsAtPath:[sub stringByAppendingPathComponent:@"patch.json"]]) return sub;
        }
    }
    return nil;
}

// ---- Create / Edit form ------------------------------------------------

- (void)openCreateForm:(NSDictionary *_Nullable)patch
{
    [self openCreateFormWithPath:nil bundleID:nil editingPatch:patch];
}

- (void)openCreateFormWithPath:(NSString *_Nullable)targetPath
                      bundleID:(NSString *_Nullable)bundleID
                  editingPatch:(NSDictionary *_Nullable)patch
{
    WQPatchFormViewController *form = [WQPatchFormViewController new];
    form.delegate = self;
    if (patch) {
        form.editingFolder      = patch[@"folder"];
        form.existingSourceName = [patch[@"files"] firstObject][@"source"];
        form.prefilledTargetPath = [patch[@"files"] firstObject][@"target"];
        form.prefilledBundleID   = patch[@"bundleID"];
        // Name pre-fill via the editingFolder's last path component
        // is handled inside WQPatchFormViewController.cellForRowAtIndexPath.
    } else {
        form.prefilledTargetPath = targetPath;
        form.prefilledBundleID   = bundleID;
    }
    UINavigationController *nav =
        [[UINavigationController alloc] initWithRootViewController:form];
    nav.modalPresentationStyle = UIModalPresentationFormSheet;
    [self presentViewController:nav animated:YES completion:nil];
}

// WQPatchFormDelegate
- (void)patchFormDidFinish
{
    [self reload];
}

// ---- UIDocumentPickerDelegate ------------------------------------------

- (void)documentPicker:(UIDocumentPickerViewController *)__unused controller
didPickDocumentsAtURLs:(NSArray<NSURL *> *)urls
{
    NSURL *url = urls.firstObject;
    if (!url) return;
    // WQPatchesViewController only uses the picker for .dm import.
    if (_pickerMode == WQPickerModeImportDM) {
        [self handleImportDMAtURL:url];
    }
}

// ---- Apply / Restore with UISwitch ------------------------------------

// Called by the switch in each cell when its value changes.
- (void)switchChanged:(UISwitch *)sw
{
    NSUInteger row = (NSUInteger)sw.tag;
    if (row >= _patches.count) return;
    NSDictionary *patch = _patches[row];
    if (patch[@"error"]) { sw.on = !sw.on; return; }

    BOOL applying = sw.on;
    sw.enabled = NO;   // block further taps while running

    NSString *progressTitle = applying ? @"Activando parche…" : @"Desactivando parche…";
    UIAlertController *busy = wq_alert_controller(progressTitle, nil, UIAlertControllerStyleAlert);
    [self presentViewController:busy animated:YES completion:nil];

    __weak typeof(self) weakSelf = self;
    dispatch_async(wq_io(), ^{
        NSString *error = applying ? wq_patch_apply(patch) : wq_patch_restore(patch);
        dispatch_async(dispatch_get_main_queue(), ^{
            [busy dismissViewControllerAnimated:YES completion:^{
                sw.enabled = YES;
                if (error) {
                    sw.on = !applying;   // revert the switch
                    wq_alert(weakSelf, applying ? @"Error al activar" : @"Error al desactivar", error);
                } else {
                    // Update the in-memory applied flag so the switch stays consistent.
                    __strong typeof(self) strongSelf = weakSelf;
                    if (!strongSelf) return;
                    NSMutableDictionary *updated = [patch mutableCopy];
                    updated[@"applied"] = @(applying);
                    NSMutableArray *mutable = [strongSelf->_patches mutableCopy];
                    mutable[row] = updated;
                    strongSelf->_patches = mutable;
                    // Full reload keeps bundles in sync; the switch already reflects the state.
                    [strongSelf reload];
                }
            }];
        });
    });
}

// ---- Long-press: Export / Edit -----------------------------------------

- (void)handleLongPress:(UILongPressGestureRecognizer *)gr
{
    if (gr.state != UIGestureRecognizerStateBegan) return;
    CGPoint pt = [gr locationInView:self.tableView];
    NSIndexPath *ip = [self.tableView indexPathForRowAtPoint:pt];
    if (!ip) return;
    NSDictionary *patch = _patches[(NSUInteger)ip.row];

    UIAlertController *sheet =
        wq_alert_controller(patch[@"name"], nil, UIAlertControllerStyleActionSheet);
    __weak typeof(self) weakSelf = self;

    [sheet addAction:wq_alert_action(@"Exportar parche (.dm)", UIAlertActionStyleDefault,
                                     ^(UIAlertAction *__unused a) {
        [weakSelf exportPatch:patch fromCell:[self.tableView cellForRowAtIndexPath:ip]];
    })];

    if (!patch[@"error"]) {
        [sheet addAction:wq_alert_action(@"Editar parche", UIAlertActionStyleDefault,
                                         ^(UIAlertAction *__unused a) {
            [weakSelf openCreateForm:patch];
        })];
    }

    BOOL applied = [patch[@"applied"] boolValue];
    if (!applied && wq_deleting_allowed()) {
        [sheet addAction:wq_alert_action(WQLocalized(@"Delete Patch"), UIAlertActionStyleDestructive,
                                         ^(UIAlertAction *__unused a) {
            [NSFileManager.defaultManager removeItemAtPath:patch[@"folder"] error:nil];
            [weakSelf reload];
        })];
    }

    [sheet addAction:wq_alert_action(WQLocalized(@"Cancel"), UIAlertActionStyleCancel, nil)];
    sheet.popoverPresentationController.sourceView = [self.tableView cellForRowAtIndexPath:ip];
    [self presentViewController:sheet animated:YES completion:nil];
}

- (void)exportPatch:(NSDictionary *)patch fromCell:(UIView *_Nullable)sourceView
{
    NSString *folder = patch[@"folder"];
    NSString *patchName = patch[@"name"] ?: folder.lastPathComponent;

    // Sanitize the filename.
    NSString *safeName = [patchName stringByReplacingOccurrencesOfString:@"/" withString:@"-"];
    NSString *zipPath = [NSTemporaryDirectory()
                         stringByAppendingPathComponent:[safeName stringByAppendingPathExtension:@"dm"]];
    [[NSFileManager defaultManager] removeItemAtPath:zipPath error:nil];

    UIAlertController *busy =
        wq_alert_controller(@"Exportando…", nil, UIAlertControllerStyleAlert);
    [self presentViewController:busy animated:YES completion:nil];

    __weak typeof(self) weakSelf = self;
    dispatch_async(wq_io(), ^{
        NSString *errorText = nil;
        BOOL ok = wq_zip_write(@[folder], zipPath, wq_archive_posix_io(),
                               nil, nil, nil, &errorText);
        dispatch_async(dispatch_get_main_queue(), ^{
            [busy dismissViewControllerAnimated:YES completion:^{
                if (!ok || ![[NSFileManager defaultManager] fileExistsAtPath:zipPath]) {
                    wq_alert(weakSelf, @"Error al exportar", errorText ?: @"No se pudo crear el .dm.");
                    return;
                }
                NSURL *dmURL = [NSURL fileURLWithPath:zipPath];
                UIActivityViewController *share =
                    [[UIActivityViewController alloc] initWithActivityItems:@[dmURL]
                                                     applicationActivities:nil];
                share.popoverPresentationController.sourceView = sourceView ?: weakSelf.view;
                [weakSelf presentViewController:share animated:YES completion:nil];
            }];
        });
    });
}

// ---- UITableViewDataSource / Delegate ----------------------------------

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView { return 1; }

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section
{
    return (NSInteger)_patches.count;
}

- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section
{
    return _patches.count ? nil :
        @"Sin parches. Toca + \u2192 \"Importar parche (.dm)\" para a\u00f1adir uno, o \"Crear parche\" para construirlo paso a paso.";
}

- (UITableViewCell *)tableView:(UITableView *)tableView
         cellForRowAtIndexPath:(NSIndexPath *)indexPath
{
    NSDictionary *patch = _patches[(NSUInteger)indexPath.row];
    UITableViewCell *cell =
        [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:nil];
    wq_style_cell(cell);

    UIListContentConfiguration *c = [UIListContentConfiguration subtitleCellConfiguration];
    c.text  = patch[@"name"];
    c.image = [UIImage systemImageNamed:patch[@"error"]
                                            ? @"exclamationmark.triangle.fill"
                                            : @"bandage.fill"];
    if (patch[@"error"]) {
        c.secondaryText = patch[@"error"];
        c.secondaryTextProperties.color = UIColor.systemRedColor;
        cell.contentConfiguration = c;
    } else {
        c.secondaryText = [NSString stringWithFormat:@"%lu archivos · %@",
                           (unsigned long)[patch[@"files"] count], patch[@"bundleID"]];
        cell.contentConfiguration = c;

        // UISwitch as accessoryView; tag carries the row index for the callback.
        UISwitch *sw = [[UISwitch alloc] init];
        sw.tag = indexPath.row;
        sw.on  = [patch[@"applied"] boolValue];
        [sw addTarget:self action:@selector(switchChanged:) forControlEvents:UIControlEventValueChanged];
        cell.accessoryView = sw;
    }

    // Long-press recognizer — one per cell, identified by row via tag.
    UILongPressGestureRecognizer *lp =
        [[UILongPressGestureRecognizer alloc] initWithTarget:self
                                                      action:@selector(handleLongPress:)];
    lp.minimumPressDuration = 0.5;
    [cell addGestureRecognizer:lp];

    return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath
{
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    // Tap on a valid patch toggles the switch programmatically.
    NSDictionary *patch = _patches[(NSUInteger)indexPath.row];
    if (patch[@"error"]) return;
    UITableViewCell *cell = [tableView cellForRowAtIndexPath:indexPath];
    UISwitch *sw = (UISwitch *)cell.accessoryView;
    if (![sw isKindOfClass:UISwitch.class]) return;
    sw.on = !sw.on;
    [self switchChanged:sw];
}

@end
