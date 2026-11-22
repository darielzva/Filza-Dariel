#import "DMLoginViewController.h"
#import <Security/Security.h>

// MARK: - Keychain constants

static NSString *const kKeychainService = @"com.dmfiles.angel";
static NSString *const kKeychainAccount = @"license_key";

// MARK: - Theme (matches DMSplashViewController)

static UIColor *DMLAccentColor(void)     { return [UIColor colorWithRed:0.961f green:0.620f blue:0.043f alpha:1.0f]; }
static UIColor *DMLBackgroundColor(void) { return [UIColor colorWithRed:0.039f green:0.039f blue:0.059f alpha:1.0f]; }
static UIColor *DMLSurfaceColor(void)    { return [UIColor colorWithRed:0.08f  green:0.08f  blue:0.11f  alpha:1.0f]; }

// MARK: - Keychain helpers (Security.framework)

static BOOL DMKeychainSave(NSString *service, NSString *account, NSString *value) {
    NSData *data = [value dataUsingEncoding:NSUTF8StringEncoding];
    NSDictionary *query = @{
        (__bridge id)kSecClass:            (__bridge id)kSecClassGenericPassword,
        (__bridge id)kSecAttrService:      service,
        (__bridge id)kSecAttrAccount:      account,
        (__bridge id)kSecValueData:        data,
        (__bridge id)kSecAttrAccessible:   (__bridge id)kSecAttrAccessibleAfterFirstUnlock,
    };
    // Delete any existing entry first
    SecItemDelete((__bridge CFDictionaryRef)query);
    OSStatus status = SecItemAdd((__bridge CFDictionaryRef)query, NULL);
    return status == errSecSuccess;
}

static NSString * _Nullable DMKeychainRead(NSString *service, NSString *account) {
    NSDictionary *query = @{
        (__bridge id)kSecClass:            (__bridge id)kSecClassGenericPassword,
        (__bridge id)kSecAttrService:      service,
        (__bridge id)kSecAttrAccount:      account,
        (__bridge id)kSecReturnData:       @YES,
        (__bridge id)kSecMatchLimit:       (__bridge id)kSecMatchLimitOne,
    };
    CFTypeRef result = NULL;
    OSStatus status = SecItemCopyMatching((__bridge CFDictionaryRef)query, &result);
    if (status != errSecSuccess || !result) return nil;
    NSData *data = (__bridge_transfer NSData *)result;
    return [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
}

static void DMKeychainDelete(NSString *service, NSString *account) {
    NSDictionary *query = @{
        (__bridge id)kSecClass:       (__bridge id)kSecClassGenericPassword,
        (__bridge id)kSecAttrService: service,
        (__bridge id)kSecAttrAccount: account,
    };
    SecItemDelete((__bridge CFDictionaryRef)query);
}

// MARK: - DMLoginViewController

@interface DMLoginViewController () <UITextFieldDelegate>

@property (nonatomic, copy) DMLoginCompletion completion;

// UI
@property (nonatomic, strong) UIScrollView  *scroll;
@property (nonatomic, strong) UIView        *card;
@property (nonatomic, strong) UIImageView   *logoView;
@property (nonatomic, strong) UILabel       *titleLabel;
@property (nonatomic, strong) UILabel       *subtitleLabel;
@property (nonatomic, strong) UITextField   *keyField;
@property (nonatomic, strong) UIButton      *verifyButton;
@property (nonatomic, strong) UIActivityIndicatorView *spinner;
@property (nonatomic, strong) UILabel       *errorLabel;

// State
@property (nonatomic, assign) BOOL isLoading;

@end

@implementation DMLoginViewController

// MARK: - Init

- (instancetype)initWithCompletion:(DMLoginCompletion)completion {
    self = [super initWithNibName:nil bundle:nil];
    if (self) {
        _completion = [completion copy];
    }
    return self;
}

// MARK: - Public class methods

+ (nullable NSString *)savedKeyValue {
    return DMKeychainRead(kKeychainService, kKeychainAccount);
}

+ (void)clearSavedKey {
    DMKeychainDelete(kKeychainService, kKeychainAccount);
}

// MARK: - Lifecycle

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = DMLBackgroundColor();
    [self buildScrollAndCard];
    [self buildLogoSection];
    [self buildFields];
    [self layoutAll];
    [self registerKeyboardObservers];

    // Auto-fill saved key
    NSString *saved = [DMLoginViewController savedKeyValue];
    if (saved) {
        self.keyField.text = saved;
    }
}

- (void)viewWillDisappear:(BOOL)animated {
    [super viewWillDisappear:animated];
    [self unregisterKeyboardObservers];
}

// MARK: - Build UI

- (void)buildScrollAndCard {
    _scroll = [[UIScrollView alloc] init];
    _scroll.translatesAutoresizingMaskIntoConstraints = NO;
    _scroll.alwaysBounceVertical = YES;
    [self.view addSubview:_scroll];

    _card = [[UIView alloc] init];
    _card.translatesAutoresizingMaskIntoConstraints = NO;
    _card.backgroundColor   = DMLSurfaceColor();
    _card.layer.cornerRadius = 20.0f;
    _card.layer.borderColor  = [DMLAccentColor() colorWithAlphaComponent:0.2f].CGColor;
    _card.layer.borderWidth  = 1.0f;
    // Subtle amber shadow
    _card.layer.shadowColor   = DMLAccentColor().CGColor;
    _card.layer.shadowRadius  = 20.0f;
    _card.layer.shadowOpacity = 0.15f;
    _card.layer.shadowOffset  = CGSizeZero;
    [_scroll addSubview:_card];
}

- (void)buildLogoSection {
    _logoView = [[UIImageView alloc] initWithImage:[UIImage imageNamed:@"AngelLogo"]];
    _logoView.translatesAutoresizingMaskIntoConstraints = NO;
    _logoView.contentMode = UIViewContentModeScaleAspectFit;
    _logoView.layer.shadowColor   = [UIColor blackColor].CGColor;
    _logoView.layer.shadowRadius  = 10.0f;
    _logoView.layer.shadowOpacity = 0.3f;
    _logoView.layer.shadowOffset  = CGSizeZero;
    [_card addSubview:_logoView];

    _titleLabel = [[UILabel alloc] init];
    _titleLabel.translatesAutoresizingMaskIntoConstraints = NO;
    _titleLabel.text          = @"DM Files";
    _titleLabel.font          = [UIFont systemFontOfSize:24.0f weight:UIFontWeightHeavy];
    _titleLabel.textColor     = [UIColor whiteColor];
    _titleLabel.textAlignment = NSTextAlignmentCenter;
    [_card addSubview:_titleLabel];

    _subtitleLabel = [[UILabel alloc] init];
    _subtitleLabel.translatesAutoresizingMaskIntoConstraints = NO;
    _subtitleLabel.text          = @"INGRESA TU LICENCIA";
    _subtitleLabel.font          = [UIFont systemFontOfSize:11.0f weight:UIFontWeightBold];
    _subtitleLabel.textColor     = [DMLAccentColor() colorWithAlphaComponent:0.8f];
    _subtitleLabel.textAlignment = NSTextAlignmentCenter;
    _subtitleLabel.attributedText = [[NSAttributedString alloc]
        initWithString:@"INGRESA TU LICENCIA"
            attributes:@{
                NSFontAttributeName:            _subtitleLabel.font,
                NSForegroundColorAttributeName: [DMLAccentColor() colorWithAlphaComponent:0.8f],
                NSKernAttributeName:            @2.5,
            }];
    [_card addSubview:_subtitleLabel];
}

- (void)buildFields {
    // Key input field
    _keyField = [[UITextField alloc] init];
    _keyField.translatesAutoresizingMaskIntoConstraints = NO;
    _keyField.placeholder       = @"XXXX-XXXX-XXXX-XXXX";
    _keyField.autocapitalizationType = UITextAutocapitalizationTypeAllCharacters;
    _keyField.autocorrectionType     = UITextAutocorrectionTypeNo;
    _keyField.returnKeyType          = UIReturnKeyDone;
    _keyField.clearButtonMode        = UITextFieldViewModeWhileEditing;
    _keyField.font          = [UIFont monospacedSystemFontOfSize:15.0f weight:UIFontWeightMedium];
    _keyField.textColor     = [UIColor whiteColor];
    _keyField.textAlignment = NSTextAlignmentCenter;
    _keyField.backgroundColor    = [UIColor colorWithWhite:1.0f alpha:0.06f];
    _keyField.layer.cornerRadius = 12.0f;
    _keyField.layer.borderColor  = [DMLAccentColor() colorWithAlphaComponent:0.3f].CGColor;
    _keyField.layer.borderWidth  = 1.0f;
    // Padding via left/right views
    UIView *leftPad  = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 16, 1)];
    UIView *rightPad = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 16, 1)];
    _keyField.leftView  = leftPad;
    _keyField.rightView = rightPad;
    _keyField.leftViewMode  = UITextFieldViewModeAlways;
    _keyField.rightViewMode = UITextFieldViewModeAlways;
    // Placeholder color
    _keyField.attributedPlaceholder = [[NSAttributedString alloc]
        initWithString:@"XXXX-XXXX-XXXX-XXXX"
            attributes:@{NSForegroundColorAttributeName: [UIColor colorWithWhite:1.0f alpha:0.25f]}];
    _keyField.delegate = self;
    [_card addSubview:_keyField];

    // Error label (hidden initially)
    _errorLabel = [[UILabel alloc] init];
    _errorLabel.translatesAutoresizingMaskIntoConstraints = NO;
    _errorLabel.text          = @"";
    _errorLabel.font          = [UIFont systemFontOfSize:12.0f weight:UIFontWeightMedium];
    _errorLabel.textColor     = [UIColor colorWithRed:0.98f green:0.27f blue:0.27f alpha:1.0f];
    _errorLabel.textAlignment = NSTextAlignmentCenter;
    _errorLabel.numberOfLines = 2;
    _errorLabel.hidden        = YES;
    [_card addSubview:_errorLabel];

    // Verify button
    _verifyButton = [UIButton buttonWithType:UIButtonTypeSystem];
    _verifyButton.translatesAutoresizingMaskIntoConstraints = NO;
    _verifyButton.backgroundColor   = DMLAccentColor();
    _verifyButton.layer.cornerRadius = 12.0f;
    _verifyButton.layer.shadowColor  = DMLAccentColor().CGColor;
    _verifyButton.layer.shadowRadius = 8.0f;
    _verifyButton.layer.shadowOpacity = 0.4f;
    _verifyButton.layer.shadowOffset  = CGSizeZero;
    [_verifyButton setAttributedTitle:[[NSAttributedString alloc]
        initWithString:@"VERIFICAR"
            attributes:@{
                NSFontAttributeName:            [UIFont systemFontOfSize:14.0f weight:UIFontWeightBold],
                NSForegroundColorAttributeName: [UIColor blackColor],
                NSKernAttributeName:            @2.0,
            }]
              forState:UIControlStateNormal];
    [_verifyButton addTarget:self action:@selector(verifyTapped) forControlEvents:UIControlEventTouchUpInside];
    [_card addSubview:_verifyButton];

    // Spinner (hidden inside button)
    _spinner = [[UIActivityIndicatorView alloc] initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleMedium];
    _spinner.translatesAutoresizingMaskIntoConstraints = NO;
    _spinner.color = [UIColor blackColor];
    _spinner.hidesWhenStopped = YES;
    [_verifyButton addSubview:_spinner];
}

- (void)layoutAll {
    // Scroll fills the view
    [NSLayoutConstraint activateConstraints:@[
        [_scroll.topAnchor     constraintEqualToAnchor:self.view.topAnchor],
        [_scroll.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [_scroll.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [_scroll.bottomAnchor  constraintEqualToAnchor:self.view.bottomAnchor],
    ]];

    // Card centred horizontally with side padding, vertically centred in the scroll
    [NSLayoutConstraint activateConstraints:@[
        [_card.centerXAnchor constraintEqualToAnchor:_scroll.centerXAnchor],
        [_card.centerYAnchor constraintEqualToAnchor:_scroll.centerYAnchor],
        [_card.widthAnchor   constraintLessThanOrEqualToConstant:360.0f],
        [_card.leadingAnchor constraintGreaterThanOrEqualToAnchor:_scroll.leadingAnchor constant:24.0f],
        [_card.trailingAnchor constraintLessThanOrEqualToAnchor:_scroll.trailingAnchor constant:-24.0f],
        // Scroll content size
        [_card.topAnchor    constraintGreaterThanOrEqualToAnchor:_scroll.topAnchor constant:60.0f],
        [_card.bottomAnchor constraintLessThanOrEqualToAnchor:_scroll.bottomAnchor constant:-60.0f],
    ]];

    // Card internals
    [NSLayoutConstraint activateConstraints:@[
        [_logoView.topAnchor     constraintEqualToAnchor:_card.topAnchor constant:36.0f],
        [_logoView.centerXAnchor constraintEqualToAnchor:_card.centerXAnchor],
        [_logoView.widthAnchor   constraintEqualToConstant:72.0f],
        [_logoView.heightAnchor  constraintEqualToConstant:72.0f],

        [_titleLabel.topAnchor     constraintEqualToAnchor:_logoView.bottomAnchor constant:16.0f],
        [_titleLabel.leadingAnchor constraintEqualToAnchor:_card.leadingAnchor constant:24.0f],
        [_titleLabel.trailingAnchor constraintEqualToAnchor:_card.trailingAnchor constant:-24.0f],

        [_subtitleLabel.topAnchor     constraintEqualToAnchor:_titleLabel.bottomAnchor constant:6.0f],
        [_subtitleLabel.leadingAnchor constraintEqualToAnchor:_card.leadingAnchor constant:24.0f],
        [_subtitleLabel.trailingAnchor constraintEqualToAnchor:_card.trailingAnchor constant:-24.0f],

        [_keyField.topAnchor     constraintEqualToAnchor:_subtitleLabel.bottomAnchor constant:28.0f],
        [_keyField.leadingAnchor constraintEqualToAnchor:_card.leadingAnchor constant:20.0f],
        [_keyField.trailingAnchor constraintEqualToAnchor:_card.trailingAnchor constant:-20.0f],
        [_keyField.heightAnchor  constraintEqualToConstant:48.0f],

        [_errorLabel.topAnchor     constraintEqualToAnchor:_keyField.bottomAnchor constant:8.0f],
        [_errorLabel.leadingAnchor constraintEqualToAnchor:_card.leadingAnchor constant:20.0f],
        [_errorLabel.trailingAnchor constraintEqualToAnchor:_card.trailingAnchor constant:-20.0f],

        [_verifyButton.topAnchor     constraintEqualToAnchor:_errorLabel.bottomAnchor constant:16.0f],
        [_verifyButton.leadingAnchor constraintEqualToAnchor:_card.leadingAnchor constant:20.0f],
        [_verifyButton.trailingAnchor constraintEqualToAnchor:_card.trailingAnchor constant:-20.0f],
        [_verifyButton.heightAnchor  constraintEqualToConstant:48.0f],
        [_verifyButton.bottomAnchor  constraintEqualToAnchor:_card.bottomAnchor constant:-32.0f],

        [_spinner.centerXAnchor constraintEqualToAnchor:_verifyButton.centerXAnchor],
        [_spinner.centerYAnchor constraintEqualToAnchor:_verifyButton.centerYAnchor],
    ]];
}

// MARK: - Verification

- (void)verifyTapped {
    NSString *value = [self.keyField.text
                       stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (value.length == 0) {
        [self showError:@"Ingresa una licencia válida."];
        return;
    }
    [self setLoading:YES];
    [self hideError];
    [self.keyField resignFirstResponder];

    [[DMSupabaseService shared] verifyKey:value completion:^(DMSupabaseKey *key, NSError *error) {
        [self setLoading:NO];
        if (error) {
            [self showError:[self messageForError:error]];
            return;
        }
        // Persist to Keychain
        DMKeychainSave(kKeychainService, kKeychainAccount, value);
        if (self.completion) self.completion(key);
    }];
}

- (NSString *)messageForError:(NSError *)error {
    if (![error.domain isEqualToString:DMSupabaseErrorDomain]) {
        return @"Error de red. Verifica tu conexión.";
    }
    switch (error.code) {
        case DMSupabaseErrorKeyNotFound:  return @"Licencia no encontrada.";
        case DMSupabaseErrorKeyBanned:    return @"Licencia baneada. Contacta soporte.";
        case DMSupabaseErrorKeyExpired:   return @"Licencia expirada.";
        case DMSupabaseErrorKeyInactive:  return @"Licencia inactiva.";
        default:                          return @"Error inesperado. Intenta de nuevo.";
    }
}

- (void)setLoading:(BOOL)loading {
    _isLoading = loading;
    self.verifyButton.enabled = !loading;
    if (loading) {
        [self.spinner startAnimating];
        [self.verifyButton setAttributedTitle:[[NSAttributedString alloc]
            initWithString:@""
                attributes:@{}]
                                     forState:UIControlStateNormal];
    } else {
        [self.spinner stopAnimating];
        [self.verifyButton setAttributedTitle:[[NSAttributedString alloc]
            initWithString:@"VERIFICAR"
                attributes:@{
                    NSFontAttributeName:            [UIFont systemFontOfSize:14.0f weight:UIFontWeightBold],
                    NSForegroundColorAttributeName: [UIColor blackColor],
                    NSKernAttributeName:            @2.0,
                }]
                                     forState:UIControlStateNormal];
    }
}

- (void)showError:(NSString *)message {
    self.errorLabel.text   = message;
    self.errorLabel.hidden = NO;
    // Shake animation on the field
    CAKeyframeAnimation *shake = [CAKeyframeAnimation animationWithKeyPath:@"transform.translation.x"];
    shake.timingFunction = [CAMediaTimingFunction functionWithName:kCAMediaTimingFunctionLinear];
    shake.duration  = 0.4;
    shake.values    = @[@-8, @8, @-6, @6, @-4, @4, @0];
    [self.keyField.layer addAnimation:shake forKey:@"shake"];
    // Red border flash
    self.keyField.layer.borderColor = [UIColor colorWithRed:0.98f green:0.27f blue:0.27f alpha:1.0f].CGColor;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.5 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        self.keyField.layer.borderColor = [DMLAccentColor() colorWithAlphaComponent:0.3f].CGColor;
    });
}

- (void)hideError {
    self.errorLabel.hidden = YES;
    self.errorLabel.text   = @"";
}

// MARK: - UITextFieldDelegate

- (BOOL)textFieldShouldReturn:(UITextField *)textField {
    [self verifyTapped];
    return YES;
}

// MARK: - Keyboard

- (void)registerKeyboardObservers {
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(keyboardWillShow:)
                                                 name:UIKeyboardWillShowNotification
                                               object:nil];
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(keyboardWillHide:)
                                                 name:UIKeyboardWillHideNotification
                                               object:nil];
}

- (void)unregisterKeyboardObservers {
    [[NSNotificationCenter defaultCenter] removeObserver:self name:UIKeyboardWillShowNotification object:nil];
    [[NSNotificationCenter defaultCenter] removeObserver:self name:UIKeyboardWillHideNotification object:nil];
}

- (void)keyboardWillShow:(NSNotification *)note {
    NSDictionary *info = note.userInfo;
    CGRect kbFrame = [[info objectForKey:UIKeyboardFrameEndUserInfoKey] CGRectValue];
    double duration = [[info objectForKey:UIKeyboardAnimationDurationUserInfoKey] doubleValue];
    UIEdgeInsets insets = UIEdgeInsetsMake(0, 0, kbFrame.size.height, 0);
    [UIView animateWithDuration:duration animations:^{
        self.scroll.contentInset          = insets;
        self.scroll.scrollIndicatorInsets = insets;
    }];
}

- (void)keyboardWillHide:(NSNotification *)note {
    double duration = [[note.userInfo objectForKey:UIKeyboardAnimationDurationUserInfoKey] doubleValue];
    [UIView animateWithDuration:duration animations:^{
        self.scroll.contentInset          = UIEdgeInsetsZero;
        self.scroll.scrollIndicatorInsets = UIEdgeInsetsZero;
    }];
}

@end
