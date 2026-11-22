#import "DMIntegration.h"

// MARK: - Maintenance overlay

/// Muestra un overlay de mantenimiento si DMSupabaseService lo activa.
/// Se actualiza vía KVO — se remueve automáticamente cuando termina el mantenimiento.
@interface DMMaintenanceOverlay : NSObject
+ (void)watchWindow:(UIWindow *)window;
@end

@implementation DMMaintenanceOverlay {
    UIWindow *_window;
    UIViewController *_overlayVC;
}

+ (instancetype)shared {
    static DMMaintenanceOverlay *inst;
    static dispatch_once_t t;
    dispatch_once(&t, ^{ inst = [[DMMaintenanceOverlay alloc] init]; });
    return inst;
}

+ (void)watchWindow:(UIWindow *)window {
    DMMaintenanceOverlay *m = [self shared];
    m->_window = window;
    [[DMSupabaseService shared] addObserver:m
                                 forKeyPath:@"isMaintenanceMode"
                                    options:NSKeyValueObservingOptionNew | NSKeyValueObservingOptionInitial
                                    context:NULL];
    [[DMSupabaseService shared] addObserver:m
                                 forKeyPath:@"isKeyRevoked"
                                    options:NSKeyValueObservingOptionNew | NSKeyValueObservingOptionInitial
                                    context:NULL];
    [[DMSupabaseService shared] addObserver:m
                                 forKeyPath:@"isKeyFrozen"
                                    options:NSKeyValueObservingOptionNew | NSKeyValueObservingOptionInitial
                                    context:NULL];
}

- (void)observeValueForKeyPath:(NSString *)keyPath ofObject:(id)object
                        change:(NSDictionary *)change context:(void *)context {
    dispatch_async(dispatch_get_main_queue(), ^{
        [self evaluateState];
    });
}

- (void)evaluateState {
    DMSupabaseService *svc = [DMSupabaseService shared];
    if (svc.isMaintenanceMode || svc.isKeyRevoked || svc.isKeyFrozen) {
        [self showOverlay];
    } else {
        [self hideOverlay];
    }
}

- (void)showOverlay {
    if (_overlayVC) return;

    DMSupabaseService *svc = [DMSupabaseService shared];
    NSString *message;
    NSString *title;

    if (svc.isKeyRevoked) {
        title   = @"LICENCIA REVOCADA";
        message = @"Tu licencia fue desactivada. Contacta soporte.";
    } else if (svc.isKeyFrozen) {
        title   = @"LICENCIA SUSPENDIDA";
        message = @"Tu licencia está suspendida temporalmente. Contacta soporte.";
    } else {
        title   = @"MANTENIMIENTO";
        message = svc.maintenanceMessage;
    }

    UIViewController *vc = [[UIViewController alloc] init];
    vc.view.backgroundColor = [UIColor colorWithRed:0.039f green:0.039f blue:0.059f alpha:0.97f];
    vc.modalPresentationStyle = UIModalPresentationOverFullScreen;

    UILabel *icon = [[UILabel alloc] init];
    icon.translatesAutoresizingMaskIntoConstraints = NO;
    icon.text = svc.isMaintenanceMode ? @"🔧" : @"🔒";
    icon.font = [UIFont systemFontOfSize:52.0f];
    icon.textAlignment = NSTextAlignmentCenter;
    [vc.view addSubview:icon];

    UILabel *titleLbl = [[UILabel alloc] init];
    titleLbl.translatesAutoresizingMaskIntoConstraints = NO;
    titleLbl.text = title;
    titleLbl.font = [UIFont systemFontOfSize:16.0f weight:UIFontWeightBold];
    titleLbl.textColor = [UIColor colorWithRed:0.961f green:0.620f blue:0.043f alpha:1.0f];
    titleLbl.textAlignment = NSTextAlignmentCenter;
    NSMutableAttributedString *attr = [[NSMutableAttributedString alloc]
        initWithString:title attributes:@{NSKernAttributeName: @3.0, NSFontAttributeName: titleLbl.font,
                                          NSForegroundColorAttributeName: titleLbl.textColor}];
    titleLbl.attributedText = attr;
    [vc.view addSubview:titleLbl];

    UILabel *msgLbl = [[UILabel alloc] init];
    msgLbl.translatesAutoresizingMaskIntoConstraints = NO;
    msgLbl.text = message;
    msgLbl.font = [UIFont systemFontOfSize:14.0f];
    msgLbl.textColor = [UIColor colorWithWhite:1.0f alpha:0.7f];
    msgLbl.textAlignment = NSTextAlignmentCenter;
    msgLbl.numberOfLines = 0;
    [vc.view addSubview:msgLbl];

    [NSLayoutConstraint activateConstraints:@[
        [icon.centerXAnchor constraintEqualToAnchor:vc.view.centerXAnchor],
        [icon.centerYAnchor constraintEqualToAnchor:vc.view.centerYAnchor constant:-50.0f],
        [titleLbl.topAnchor constraintEqualToAnchor:icon.bottomAnchor constant:16.0f],
        [titleLbl.centerXAnchor constraintEqualToAnchor:vc.view.centerXAnchor],
        [msgLbl.topAnchor constraintEqualToAnchor:titleLbl.bottomAnchor constant:12.0f],
        [msgLbl.leadingAnchor constraintEqualToAnchor:vc.view.leadingAnchor constant:40.0f],
        [msgLbl.trailingAnchor constraintEqualToAnchor:vc.view.trailingAnchor constant:-40.0f],
    ]];

    _overlayVC = vc;
    [_window.rootViewController presentViewController:vc animated:YES completion:nil];
}

- (void)hideOverlay {
    if (!_overlayVC) return;
    UIViewController *vc = _overlayVC;
    _overlayVC = nil;
    [vc dismissViewControllerAnimated:YES completion:nil];
}

@end

// MARK: - dm_start

void dm_start(UIWindow *window, void (^makeMainUI)(UIWindow *window)) {

    NSString *savedKey = [DMLoginViewController savedKeyValue];

    void (^showMainUI)(void) = ^{
        makeMainUI(window);
        [DMMaintenanceOverlay watchWindow:window];
        // Chequeo periódico de estado de key cada 5 minutos
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_BACKGROUND, 0), ^{
            while (YES) {
                [NSThread sleepForTimeInterval:300.0];
                [[DMSupabaseService shared] checkKeyStatusWithCompletion:nil];
            }
        });
    };

    void (^showSplash)(void) = ^{
        __block DMSplashViewController *splash = [[DMSplashViewController alloc] initWithCompletion:^{
            [UIView animateWithDuration:0.3 animations:^{
                window.rootViewController.view.alpha = 0.0f;
            } completion:^(BOOL __unused done) {
                showMainUI();
            }];
            splash = nil;
        }];
        window.rootViewController = splash;
        window.alpha = 0.0f;
        [window makeKeyAndVisible];
        [UIView animateWithDuration:0.25 animations:^{ window.alpha = 1.0f; }];
    };

    if (savedKey && savedKey.length > 0) {
        // Key guardada → verificar en background, mostrar splash de inmediato
        showSplash();
        [[DMSupabaseService shared] verifyKey:savedKey completion:^(DMSupabaseKey *__unused key, NSError *error) {
            if (error) {
                // Key inválida → borrar y pedir login desde el splash activo
                [DMLoginViewController clearSavedKey];
                DMLoginViewController *login = [[DMLoginViewController alloc] initWithCompletion:^(DMSupabaseKey *__unused validKey) {
                    [window.rootViewController dismissViewControllerAnimated:YES completion:nil];
                }];
                login.modalPresentationStyle = UIModalPresentationOverFullScreen;
                [window.rootViewController presentViewController:login animated:YES completion:nil];
            }
            // Key válida → el splash ya está corriendo, no hacer nada
        }];
    } else {
        // Sin key → Login primero, después Splash
        DMLoginViewController *login = [[DMLoginViewController alloc]
            initWithCompletion:^(DMSupabaseKey *__unused key) {
                showSplash();
            }];
        window.rootViewController = login;
        window.alpha = 0.0f;
        [window makeKeyAndVisible];
        [UIView animateWithDuration:0.25 animations:^{ window.alpha = 1.0f; }];
    }
}
