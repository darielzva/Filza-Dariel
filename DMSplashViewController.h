#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

/// Completion block called when the splash sequence finishes (all patches downloaded).
typedef void (^DMSplashCompletion)(void);

/// Full-screen animated splash view controller.
/// Displays the DM Files logo, an amber progress bar, and a step label
/// while DMPatchesStore downloads patches from Supabase.
///
/// Usage:
///   DMSplashViewController *splash = [[DMSplashViewController alloc] initWithCompletion:^{
///       // transition to main UI
///   }];
///   [self presentViewController:splash animated:NO completion:nil];
///
@interface DMSplashViewController : UIViewController

- (instancetype)initWithCompletion:(DMSplashCompletion)completion NS_DESIGNATED_INITIALIZER;
- (instancetype)initWithNibName:(nullable NSString *)n bundle:(nullable NSBundle *)b NS_UNAVAILABLE;
- (instancetype)initWithCoder:(NSCoder *)c NS_UNAVAILABLE;

/// Update progress bar (0.0–1.0) and step label from any thread.
- (void)updateProgress:(double)progress step:(NSString *)step;

@end

NS_ASSUME_NONNULL_END
