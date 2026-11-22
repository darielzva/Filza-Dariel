#import "DMSplashViewController.h"
#import "DMPatchesStore.h"

// MARK: - Theme constants (matches AngelTheme palette)

static UIColor *DMAccentColor(void) {
    // Amber #F59E0B
    return [UIColor colorWithRed:0.961f green:0.620f blue:0.043f alpha:1.0f];
}

static UIColor *DMAccentDarkColor(void) {
    // Darker amber #D97706
    return [UIColor colorWithRed:0.851f green:0.467f blue:0.024f alpha:1.0f];
}

static UIColor *DMBackgroundColor(void) {
    // Near-black #0A0A0F
    return [UIColor colorWithRed:0.039f green:0.039f blue:0.059f alpha:1.0f];
}

static NSString *const kAppName = @"DM Files";

// MARK: - Orbit particle layer

@interface DMOrbitLayer : CALayer
- (void)startSpinning;
@end

@implementation DMOrbitLayer {
    NSInteger _particleCount;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _particleCount = 24;
        [self buildParticles];
    }
    return self;
}

- (void)buildParticles {
    CGFloat radius = 80.0f;
    for (NSInteger i = 0; i < _particleCount; i++) {
        BOOL isHigh = (i % 6 == 0);
        CALayer *dot = [CALayer layer];
        CGFloat size = isHigh ? 4.0f : 2.5f;
        dot.bounds          = CGRectMake(0, 0, size, size);
        dot.cornerRadius    = size / 2.0f;
        dot.backgroundColor = isHigh
            ? DMAccentDarkColor().CGColor
            : [DMAccentColor() colorWithAlphaComponent:0.4f].CGColor;
        if (isHigh) {
            dot.shadowColor   = DMAccentColor().CGColor;
            dot.shadowRadius  = 4.0f;
            dot.shadowOpacity = 0.8f;
            dot.shadowOffset  = CGSizeZero;
        }
        double angleRad = (double)i / (double)_particleCount * M_PI * 2.0;
        dot.position = CGPointMake(
            self.bounds.size.width  / 2.0f + radius * (CGFloat)sin(angleRad),
            self.bounds.size.height / 2.0f - radius * (CGFloat)cos(angleRad)
        );
        [self addSublayer:dot];
    }
}

- (void)startSpinning {
    // Spin the whole layer 360° in 8s, forever
    CABasicAnimation *spin = [CABasicAnimation animationWithKeyPath:@"transform.rotation.z"];
    spin.fromValue  = @0.0;
    spin.toValue    = @(M_PI * 2.0);
    spin.duration   = 8.0;
    spin.repeatCount = HUGE_VALF;
    spin.timingFunction = [CAMediaTimingFunction functionWithName:kCAMediaTimingFunctionLinear];
    [self addAnimation:spin forKey:@"orbit_spin"];
}

- (void)layoutSublayers {
    [super layoutSublayers];
    // Re-centre particles when bounds change
    [self.sublayers enumerateObjectsUsingBlock:^(CALayer *dot, NSUInteger idx, BOOL *stop) {
        CGFloat radius = 80.0f;
        double angleRad = (double)idx / (double)self->_particleCount * M_PI * 2.0;
        dot.position = CGPointMake(
            self.bounds.size.width  / 2.0f + radius * (CGFloat)sin(angleRad),
            self.bounds.size.height / 2.0f - radius * (CGFloat)cos(angleRad)
        );
    }];
}

@end

// MARK: - DMSplashViewController

@interface DMSplashViewController ()

// Logo area
@property (nonatomic, strong) UIView        *logoContainer;
@property (nonatomic, strong) CALayer       *glowLayer;
@property (nonatomic, strong) DMOrbitLayer  *orbitLayer;
@property (nonatomic, strong) CALayer       *outerRingLayer;
@property (nonatomic, strong) CAGradientLayer *innerRingGradient;
@property (nonatomic, strong) UIImageView   *logoImageView; // AngelLogo placeholder

// Labels
@property (nonatomic, strong) UILabel       *appNameLabel;
@property (nonatomic, strong) UILabel       *stepLabel;
@property (nonatomic, strong) UILabel       *percentLabel;

// Progress bar
@property (nonatomic, strong) UIView        *progressTrack;
@property (nonatomic, strong) UIView        *progressFill;
@property (nonatomic, strong) NSLayoutConstraint *progressFillWidth;

// State
@property (nonatomic, copy) DMSplashCompletion completion;
@property (nonatomic, assign) double currentProgress;

// Pulsing glow timer
@property (nonatomic, strong) CABasicAnimation *glowPulse;

@end

@implementation DMSplashViewController

static const CGFloat kProgressBarWidth = 220.0f;
static const CGFloat kProgressBarHeight = 4.0f;
static const CGFloat kLogoContainerSize = 220.0f;

// MARK: - Init

- (instancetype)initWithCompletion:(DMSplashCompletion)completion {
    self = [super initWithNibName:nil bundle:nil];
    if (self) {
        _completion = [completion copy];
        _currentProgress = 0.0;
    }
    return self;
}

// MARK: - Lifecycle

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = DMBackgroundColor();
    [self buildLogoSection];
    [self buildLabels];
    [self buildProgressBar];
    [self buildSignature];
    [self layoutAll];
    self.view.alpha = 0.0f;
}

- (void)viewDidAppear:(BOOL)animated {
    [super viewDidAppear:animated];
    [UIView animateWithDuration:0.4 animations:^{ self.view.alpha = 1.0f; }];
    [self.orbitLayer startSpinning];
    [self startGlowPulse];
    [self startDownloadSequence];
}

// MARK: - Layout helpers

- (void)buildLogoSection {
    // Container for all orbital elements
    _logoContainer = [[UIView alloc] init];
    _logoContainer.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:_logoContainer];

    // Radial glow behind everything
    _glowLayer = [CALayer layer];
    _glowLayer.frame = CGRectMake(0, 0, kLogoContainerSize, kLogoContainerSize);
    _glowLayer.backgroundColor = [DMAccentColor() colorWithAlphaComponent:0.15f].CGColor;
    _glowLayer.cornerRadius = kLogoContainerSize / 2.0f;
    [_logoContainer.layer insertSublayer:_glowLayer atIndex:0];

    // Orbiting particles
    _orbitLayer = [[DMOrbitLayer alloc] init];
    _orbitLayer.frame = CGRectMake(0, 0, kLogoContainerSize, kLogoContainerSize);
    _orbitLayer.backgroundColor = [UIColor clearColor].CGColor;
    [_logoContainer.layer addSublayer:_orbitLayer];

    // Outer ring (subtle stroke, slow half-speed rotation)
    _outerRingLayer = [CALayer layer];
    _outerRingLayer.frame = CGRectMake(
        (kLogoContainerSize - 160.0f) / 2.0f,
        (kLogoContainerSize - 160.0f) / 2.0f,
        160.0f, 160.0f);
    _outerRingLayer.cornerRadius = 80.0f;
    _outerRingLayer.borderWidth = 0.5f;
    _outerRingLayer.borderColor = [UIColor colorWithWhite:1.0f alpha:0.12f].CGColor;
    _outerRingLayer.backgroundColor = [UIColor clearColor].CGColor;
    [_logoContainer.layer addSublayer:_outerRingLayer];

    // Add a half-speed spin to the outer ring
    CABasicAnimation *halfSpin = [CABasicAnimation animationWithKeyPath:@"transform.rotation.z"];
    halfSpin.fromValue  = @0.0;
    halfSpin.toValue    = @(M_PI * 2.0);
    halfSpin.duration   = 16.0;
    halfSpin.repeatCount = HUGE_VALF;
    halfSpin.timingFunction = [CAMediaTimingFunction functionWithName:kCAMediaTimingFunctionLinear];
    [_outerRingLayer addAnimation:halfSpin forKey:@"outer_ring_spin"];

    // Inner ring gradient border via a CAShapeLayer
    CAShapeLayer *innerMask = [CAShapeLayer layer];
    innerMask.path = [UIBezierPath bezierPathWithOvalInRect:CGRectMake(0, 0, 112.0f, 112.0f)].CGPath;
    innerMask.fillColor   = [UIColor clearColor].CGColor;
    innerMask.strokeColor = [UIColor whiteColor].CGColor;
    innerMask.lineWidth   = 2.5f;

    CAGradientLayer *innerGrad = [CAGradientLayer layer];
    innerGrad.frame = CGRectMake(
        (kLogoContainerSize - 112.0f) / 2.0f,
        (kLogoContainerSize - 112.0f) / 2.0f,
        112.0f, 112.0f);
    innerGrad.colors    = @[(__bridge id)DMAccentColor().CGColor, (__bridge id)DMAccentDarkColor().CGColor];
    innerGrad.startPoint = CGPointMake(0.5f, 0.0f);
    innerGrad.endPoint   = CGPointMake(0.5f, 1.0f);
    innerGrad.cornerRadius = 56.0f;
    innerGrad.mask = innerMask;
    innerGrad.shadowColor   = DMAccentColor().CGColor;
    innerGrad.shadowRadius  = 14.0f;
    innerGrad.shadowOpacity = 0.6f;
    innerGrad.shadowOffset  = CGSizeZero;
    [_logoContainer.layer addSublayer:innerGrad];
    _innerRingGradient = innerGrad;

    // Logo image — replace UIImageView image with your actual AngelLogo asset.
    // Expected: "AngelLogo" in Assets.xcassets or as a file reference.
    _logoImageView = [[UIImageView alloc] initWithImage:[UIImage imageNamed:@"AngelLogo"]];
    _logoImageView.contentMode = UIViewContentModeScaleAspectFit;
    _logoImageView.translatesAutoresizingMaskIntoConstraints = NO;
    _logoImageView.layer.shadowColor   = [UIColor blackColor].CGColor;
    _logoImageView.layer.shadowRadius  = 10.0f;
    _logoImageView.layer.shadowOpacity = 0.4f;
    _logoImageView.layer.shadowOffset  = CGSizeZero;
    [_logoContainer addSubview:_logoImageView];

    // Centre logo inside the 112pt ring
    [NSLayoutConstraint activateConstraints:@[
        [_logoImageView.centerXAnchor constraintEqualToAnchor:_logoContainer.centerXAnchor],
        [_logoImageView.centerYAnchor constraintEqualToAnchor:_logoContainer.centerYAnchor],
        [_logoImageView.widthAnchor  constraintEqualToConstant:90.0f],
        [_logoImageView.heightAnchor constraintEqualToConstant:90.0f],
    ]];
}

- (void)buildLabels {
    _appNameLabel = [[UILabel alloc] init];
    _appNameLabel.translatesAutoresizingMaskIntoConstraints = NO;
    _appNameLabel.text          = kAppName;
    _appNameLabel.font          = [UIFont systemFontOfSize:26.0f weight:UIFontWeightHeavy];
    _appNameLabel.textColor     = [UIColor whiteColor];
    _appNameLabel.textAlignment = NSTextAlignmentCenter;
    _appNameLabel.adjustsFontSizeToFitWidth = YES;
    _appNameLabel.minimumScaleFactor = 0.5f;
    // Amber shadow
    NSShadow *shadow = [[NSShadow alloc] init];
    shadow.shadowColor  = [DMAccentColor() colorWithAlphaComponent:0.45f];
    shadow.shadowBlurRadius = 10.0f;
    _appNameLabel.attributedText = [[NSAttributedString alloc]
        initWithString:kAppName
            attributes:@{
                NSFontAttributeName:            _appNameLabel.font,
                NSForegroundColorAttributeName: [UIColor whiteColor],
                NSKernAttributeName:            @2.0,
                NSShadowAttributeName:          shadow,
            }];
    [self.view addSubview:_appNameLabel];

    _stepLabel = [[UILabel alloc] init];
    _stepLabel.translatesAutoresizingMaskIntoConstraints = NO;
    _stepLabel.text          = @"INICIANDO SISTEMA...";
    _stepLabel.font          = [UIFont systemFontOfSize:11.0f weight:UIFontWeightBold];
    _stepLabel.textColor     = DMAccentColor();
    _stepLabel.textAlignment = NSTextAlignmentCenter;
    _stepLabel.numberOfLines = 2;
    // Letter spacing via attributed text — rebuild when text changes
    [self setStepText:@"INICIANDO SISTEMA..."];
    [self.view addSubview:_stepLabel];

    _percentLabel = [[UILabel alloc] init];
    _percentLabel.translatesAutoresizingMaskIntoConstraints = NO;
    _percentLabel.text      = @"0%";
    _percentLabel.font      = [UIFont monospacedDigitSystemFontOfSize:10.0f weight:UIFontWeightBold];
    _percentLabel.textColor = [UIColor colorWithWhite:1.0f alpha:0.5f];
    _percentLabel.textAlignment = NSTextAlignmentCenter;
    [self.view addSubview:_percentLabel];
}

- (void)buildProgressBar {
    _progressTrack = [[UIView alloc] init];
    _progressTrack.translatesAutoresizingMaskIntoConstraints = NO;
    _progressTrack.backgroundColor = [UIColor colorWithWhite:1.0f alpha:0.1f];
    _progressTrack.layer.cornerRadius = kProgressBarHeight / 2.0f;
    _progressTrack.clipsToBounds = YES;
    [self.view addSubview:_progressTrack];

    _progressFill = [[UIView alloc] init];
    _progressFill.translatesAutoresizingMaskIntoConstraints = NO;
    _progressFill.backgroundColor = DMAccentColor();
    _progressFill.layer.cornerRadius = kProgressBarHeight / 2.0f;
    // Amber glow
    _progressFill.layer.shadowColor   = DMAccentColor().CGColor;
    _progressFill.layer.shadowRadius  = 6.0f;
    _progressFill.layer.shadowOpacity = 0.5f;
    _progressFill.layer.shadowOffset  = CGSizeZero;
    [_progressTrack addSubview:_progressFill];

    // Fill anchors
    _progressFillWidth = [_progressFill.widthAnchor constraintEqualToConstant:0.0f];
    [NSLayoutConstraint activateConstraints:@[
        [_progressFill.leadingAnchor constraintEqualToAnchor:_progressTrack.leadingAnchor],
        [_progressFill.topAnchor     constraintEqualToAnchor:_progressTrack.topAnchor],
        [_progressFill.bottomAnchor  constraintEqualToAnchor:_progressTrack.bottomAnchor],
        _progressFillWidth,
    ]];
}

- (void)buildSignature {
    // AngelSignature — small amber label at the bottom
    UILabel *sig = [[UILabel alloc] init];
    sig.translatesAutoresizingMaskIntoConstraints = NO;
    sig.text      = @"ANGEL SYSTEM";
    sig.font      = [UIFont systemFontOfSize:9.0f weight:UIFontWeightBold];
    sig.textColor = [DMAccentColor() colorWithAlphaComponent:0.5f];
    sig.textAlignment = NSTextAlignmentCenter;
    [self.view addSubview:sig];

    [NSLayoutConstraint activateConstraints:@[
        [sig.centerXAnchor constraintEqualToAnchor:self.view.centerXAnchor],
        [sig.bottomAnchor  constraintEqualToAnchor:self.view.safeAreaLayoutGuide.bottomAnchor constant:-20.0f],
    ]];
}

- (void)layoutAll {
    [NSLayoutConstraint activateConstraints:@[
        // Logo container — fixed 220×220, upper third of screen
        [_logoContainer.centerXAnchor constraintEqualToAnchor:self.view.centerXAnchor],
        [_logoContainer.topAnchor     constraintEqualToAnchor:self.view.safeAreaLayoutGuide.topAnchor constant:60.0f],
        [_logoContainer.widthAnchor   constraintEqualToConstant:kLogoContainerSize],
        [_logoContainer.heightAnchor  constraintEqualToConstant:kLogoContainerSize],

        // App name
        [_appNameLabel.topAnchor     constraintEqualToAnchor:_logoContainer.bottomAnchor constant:28.0f],
        [_appNameLabel.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor constant:28.0f],
        [_appNameLabel.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor constant:-28.0f],

        // Step label
        [_stepLabel.topAnchor     constraintEqualToAnchor:_appNameLabel.bottomAnchor constant:16.0f],
        [_stepLabel.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor constant:40.0f],
        [_stepLabel.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor constant:-40.0f],
        [_stepLabel.heightAnchor  constraintEqualToConstant:20.0f],

        // Progress track
        [_progressTrack.topAnchor     constraintEqualToAnchor:_stepLabel.bottomAnchor constant:14.0f],
        [_progressTrack.centerXAnchor constraintEqualToAnchor:self.view.centerXAnchor],
        [_progressTrack.widthAnchor   constraintEqualToConstant:kProgressBarWidth],
        [_progressTrack.heightAnchor  constraintEqualToConstant:kProgressBarHeight],

        // Percent label
        [_percentLabel.topAnchor     constraintEqualToAnchor:_progressTrack.bottomAnchor constant:8.0f],
        [_percentLabel.centerXAnchor constraintEqualToAnchor:self.view.centerXAnchor],
    ]];
}

// MARK: - Glow pulse animation

- (void)startGlowPulse {
    CABasicAnimation *pulse = [CABasicAnimation animationWithKeyPath:@"backgroundColor"];
    pulse.fromValue    = (__bridge id)[DMAccentColor() colorWithAlphaComponent:0.15f].CGColor;
    pulse.toValue      = (__bridge id)[DMAccentColor() colorWithAlphaComponent:0.35f].CGColor;
    pulse.duration     = 1.5;
    pulse.autoreverses = YES;
    pulse.repeatCount  = HUGE_VALF;
    pulse.timingFunction = [CAMediaTimingFunction functionWithName:kCAMediaTimingFunctionEaseInEaseOut];
    [_glowLayer addAnimation:pulse forKey:@"glow_pulse"];
}

// MARK: - Public update API

- (void)updateProgress:(double)progress step:(NSString *)step {
    dispatch_async(dispatch_get_main_queue(), ^{
        double clamped = MIN(MAX(progress, 0.0), 1.0);
        [UIView animateWithDuration:0.4 animations:^{
            self.progressFillWidth.constant = kProgressBarWidth * (CGFloat)clamped;
            [self.progressTrack layoutIfNeeded];
        }];
        self.percentLabel.text = [NSString stringWithFormat:@"%d%%", (int)(clamped * 100.0)];
        [self setStepText:step];
    });
}

- (void)setStepText:(NSString *)text {
    _stepLabel.attributedText = [[NSAttributedString alloc]
        initWithString:text
            attributes:@{
                NSFontAttributeName:            [UIFont systemFontOfSize:11.0f weight:UIFontWeightBold],
                NSForegroundColorAttributeName: DMAccentColor(),
                NSKernAttributeName:            @3.0,
            }];
}

// MARK: - Download sequence

- (void)startDownloadSequence {
    [self updateProgress:0.0 step:@"CONECTANDO A SUPABASE..."];

    DMPatchesStore *store = [[DMPatchesStore alloc] init];

    [store fetchPatchesWithCompletion:^(NSArray<DMRemotePatch *> *patches, NSError *error) {
        if (error || patches.count == 0) {
            // Nothing to download — finish immediately
            [self updateProgress:1.0 step:@"LISTO"];
            [self finishAfterDelay];
            return;
        }

        [self updateProgress:0.05 step:@"DESCARGANDO PARCHES..."];

        [store downloadAllOnEach:^(NSInteger index, NSInteger total, NSString *name) {
            NSString *step = [NSString stringWithFormat:@"[%ld/%ld] %@", (long)index, (long)total, name.uppercaseString];
            double p = 0.05 + (double)(index - 1) / (double)total * 0.90;
            [self updateProgress:p step:step];
        } onOverall:^(double overall) {
            double p = 0.05 + overall * 0.90;
            [self updateProgress:p step:@"INSTALANDO..."];
        } completion:^(NSError *err) {
            [self updateProgress:1.0 step:@"SISTEMA LISTO"];
            [self finishAfterDelay];
        }];
    }];
}

- (void)finishAfterDelay {
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        [UIView animateWithDuration:0.35 animations:^{
            self.view.alpha = 0.0f;
        } completion:^(BOOL done) {
            if (self.completion) self.completion();
        }];
    });
}

@end
