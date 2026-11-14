//
//  WQUI.h
//  WQ Files shared UI helpers
//

#import <UIKit/UIKit.h>
#import "WQLocalization.h"

NS_ASSUME_NONNULL_BEGIN

static inline UIBarButtonItemStyle wq_primary_button_style(void)
{
    if (@available(iOS 26.0, *)) return UIBarButtonItemStyleProminent;
    return UIBarButtonItemStylePlain;
}

dispatch_queue_t wq_io(void);
void wq_alert(UIViewController *host, NSString *title, NSString *_Nullable message);
// Settings → Allow Deleting (on by default). When off, every delete, clear and
// clean action is hidden or refused.
BOOL wq_deleting_allowed(void);
void wq_set_deleting_allowed(BOOL allowed);
// Settings → Keep Data Before Restore (on by default). When off, the safety
// backup an app restore makes first is deleted once the restore succeeded.
BOOL wq_keep_before_restore(void);
void wq_set_keep_before_restore(BOOL keep);
// YES (after telling the user) when deleting is turned off.
BOOL wq_refuse_if_deleting_off(UIViewController *host);
UIAlertController *wq_alert_controller(NSString *_Nullable title, NSString *_Nullable message, UIAlertControllerStyle style);
UIAlertAction *wq_alert_action(NSString *title, UIAlertActionStyle style, void (^_Nullable handler)(UIAlertAction *));
NSString *wq_size_text(unsigned long long size);
UIView *wq_device_header(CGFloat width);
// "iPhone 17 Pro Max (iPhone18,2) · iOS 27.0.1 (24A446)"
NSString *wq_device_line(void);
UIImage *_Nullable wq_app_icon(NSString *_Nullable bundleID);

// ---- Appearance (Settings → Appearance) ----
typedef NS_ENUM(NSInteger, WQTheme) { WQThemeSystem = 0, WQThemeLight = 1, WQThemeDark = 2 };
WQTheme wq_theme(void);
void wq_set_theme(WQTheme theme);
// Translucent "glass" cards and a soft gradient behind the lists (on by default).
BOOL wq_glass_enabled(void);
void wq_set_glass_enabled(BOOL on);
// Icons keep their own colors; off = every icon uses the accent color.
BOOL wq_colored_icons(void);
void wq_set_colored_icons(BOOL on);
NSArray<UIColor *> *wq_accent_colors(void);
NSUInteger wq_accent_index(void);
void wq_set_accent_index(NSUInteger index);
UIColor *wq_accent_color(void);
void wq_reset_appearance(void);
// Applies theme and accent color to the window (and every other window).
void wq_apply_appearance(UIWindow *_Nullable window);
// Gradient behind a table when glass is on; plain system background otherwise.
void wq_style_table(UITableView *table);
// Glass background for a cell when glass is on.
void wq_style_cell(UITableViewCell *cell);
// A Settings-style icon: white symbol on a rounded colored square.
UIImage *wq_badge_image(NSString *symbol, UIColor *color);
UIImage *wq_telegram_icon(CGFloat side);

@interface WQAppearanceViewController : UITableViewController
@end
@interface WQAboutViewController : UITableViewController
@end
// Patches: a folder with patch.json + files; Apply copies them into an app's data.
@interface WQPatchesViewController : UITableViewController
// Push directly into the create-patch form with a pre-filled target path and bundle ID.
// Used by WQDirViewController's "Crear parche en esta ruta" context menu action.
- (instancetype)initWithPrefilledPath:(nullable NSString *)targetPath
                             bundleID:(nullable NSString *)bundleID;
@end

// Implemented by WQDirViewController when launched as a patch route picker.
// The selected file's relative path (Documents/…) and the container's bundle ID
// are delivered back to whoever pushed the picker.
@protocol WQPatchRoutePickerDelegate <NSObject>
- (void)patchRoutePickerDidSelectPath:(NSString *)relativePath
                             bundleID:(NSString *)bundleID;
@end

// Returns the data container path for the given bundle ID, or nil if not found.
// Blocking — call off the main thread.
NSString *_Nullable wq_data_container_for_bundle(NSString *bundleID);

NS_ASSUME_NONNULL_END
