#import <UIKit/UIKit.h>
#import "DMSupabaseService.h"

NS_ASSUME_NONNULL_BEGIN

typedef void (^DMLoginCompletion)(DMSupabaseKey *key);

/// Full-screen UIKit login view controller.
/// Presents the amber DM Files logo, a styled key text field, and a Verify button.
/// On success, persists the key to the Keychain and calls the completion block.
@interface DMLoginViewController : UIViewController

- (instancetype)initWithCompletion:(DMLoginCompletion)completion NS_DESIGNATED_INITIALIZER;
- (instancetype)initWithNibName:(nullable NSString *)n bundle:(nullable NSBundle *)b NS_UNAVAILABLE;
- (instancetype)initWithCoder:(NSCoder *)c NS_UNAVAILABLE;

/// Reads the stored key from Keychain. Returns nil if none is saved.
+ (nullable NSString *)savedKeyValue;

/// Removes the stored key from Keychain.
+ (void)clearSavedKey;

@end

NS_ASSUME_NONNULL_END
