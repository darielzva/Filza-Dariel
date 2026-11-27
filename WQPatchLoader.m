// WQPatchLoader.m
// Filza-Dariel — Sistema de parches bundled

#import "WQPatchLoader.h"

static NSString *const kAppliedPatchesFile = @"applied_patches.json";
static NSString *const kPatchesFolder      = @"Patches";

@implementation WQPatch
- (instancetype)init {
    self = [super init];
    if (self) {
        _name             = @"Unknown";
        _version          = @"1.0";
        _author           = @"Unknown";
        _patchDescription = @"";
        _filename         = @"";
        _settings         = @{};
    }
    return self;
}
- (NSString *)description {
    return [NSString stringWithFormat:@"<WQPatch: %@ v%@ by %@>",
            self.name, self.version, self.author];
}
@end

@implementation WQPatchLoader {
    NSMutableSet<NSString *> *_appliedPatchNames;
    NSString                 *_appliedPatchesPath;
    dispatch_queue_t          _queue;
}

+ (instancetype)shared {
    static WQPatchLoader *instance;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ instance = [WQPatchLoader new]; });
    return instance;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _queue = dispatch_queue_create("com.darielmodz.patchloader", DISPATCH_QUEUE_SERIAL);
        NSString *docs = NSSearchPathForDirectoriesInDomains(
            NSDocumentDirectory, NSUserDomainMask, YES).firstObject;
        _appliedPatchesPath = [docs stringByAppendingPathComponent:kAppliedPatchesFile];
        [self loadAppliedPatches];
    }
    return self;
}

// MARK: - Public

- (void)applyBundledPatchesIfNeeded {
    dispatch_async(_queue, ^{
        NSArray<WQPatch *> *patches = [self availableBundledPatches];
        NSUInteger applied = 0;
        for (WQPatch *patch in patches) {
            WQPatchResult result = [self applyPatchNamed:patch.filename];
            if (result == WQPatchResultApplied) {
                applied++;
                NSLog(@"[WQPatchLoader] Applied patch: %@ v%@", patch.name, patch.version);
            } else if (result == WQPatchResultAlreadyApplied) {
                NSLog(@"[WQPatchLoader] Skipped (already applied): %@", patch.filename);
            } else {
                NSLog(@"[WQPatchLoader] Failed to apply %@: result=%ld",
                      patch.filename, (long)result);
            }
        }
        NSLog(@"[WQPatchLoader] Done. Applied %lu new patch(es).", (unsigned long)applied);
    });
}

- (NSArray<WQPatch *> *)availableBundledPatches {
    NSBundle *bundle = NSBundle.mainBundle;
    NSString *patchesDir = [bundle pathForResource:nil ofType:nil
                                       inDirectory:kPatchesFolder];
    if (!patchesDir) {
        // Fallback: busca en el bundle root
        patchesDir = [[bundle bundlePath]
                      stringByAppendingPathComponent:kPatchesFolder];
    }

    NSFileManager *fm = NSFileManager.defaultManager;
    NSArray<NSString *> *files = [fm contentsOfDirectoryAtPath:patchesDir error:nil];
    if (!files) return @[];

    NSMutableArray<WQPatch *> *result = [NSMutableArray array];
    for (NSString *file in files) {
        NSString *ext = file.pathExtension.lowercaseString;
        if ([ext isEqualToString:@"dm"] || [ext isEqualToString:@"3105"]) {
            NSString *fullPath = [patchesDir stringByAppendingPathComponent:file];
            WQPatch *patch = [self parsePatchAtPath:fullPath filename:file];
            if (patch) [result addObject:patch];
        }
    }
    return [result copy];
}

- (NSArray<NSString *> *)appliedPatchNames {
    __block NSArray *names;
    dispatch_sync(_queue, ^{
        names = _appliedPatchNames.allObjects;
    });
    return names;
}

- (WQPatchResult)applyPatchNamed:(NSString *)filename {
    __block WQPatchResult result;
    dispatch_sync(_queue, ^{
        result = [self _applyPatchNamed:filename];
    });
    return result;
}

- (void)resetAppliedPatches {
    dispatch_async(_queue, ^{
        [_appliedPatchNames removeAllObjects];
        [NSFileManager.defaultManager removeItemAtPath:_appliedPatchesPath error:nil];
        NSLog(@"[WQPatchLoader] Reset: all patches cleared.");
    });
}

// MARK: - Private

- (WQPatchResult)_applyPatchNamed:(NSString *)filename {
    // Idempotencia: no re-aplicar
    if ([_appliedPatchNames containsObject:filename]) {
        return WQPatchResultAlreadyApplied;
    }

    // Buscar en bundle
    NSBundle *bundle = NSBundle.mainBundle;
    NSString *patchesDir = [[bundle bundlePath]
                            stringByAppendingPathComponent:kPatchesFolder];
    NSString *fullPath = [patchesDir stringByAppendingPathComponent:filename];

    if (![NSFileManager.defaultManager fileExistsAtPath:fullPath]) {
        return WQPatchResultFileNotFound;
    }

    WQPatch *patch = [self parsePatchAtPath:fullPath filename:filename];
    if (!patch) return WQPatchResultInvalidFormat;

    // Aplicar configuración del parche a NSUserDefaults
    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
    for (NSString *key in patch.settings) {
        NSString *value = patch.settings[key];
        // Convierte booleans
        if ([value isEqualToString:@"true"]) {
            [defaults setBool:YES forKey:[NSString stringWithFormat:@"patch_%@", key]];
        } else if ([value isEqualToString:@"false"]) {
            [defaults setBool:NO forKey:[NSString stringWithFormat:@"patch_%@", key]];
        } else {
            [defaults setObject:value forKey:[NSString stringWithFormat:@"patch_%@", key]];
        }
    }
    [defaults synchronize];

    // Marcar como aplicado y persistir
    [_appliedPatchNames addObject:filename];
    [self saveAppliedPatches];

    return WQPatchResultApplied;
}

- (nullable WQPatch *)parsePatchAtPath:(NSString *)path filename:(NSString *)filename {
    NSError *error;
    NSString *content = [NSString stringWithContentsOfFile:path
                                                  encoding:NSUTF8StringEncoding
                                                     error:&error];
    if (!content || error) return nil;

    NSMutableDictionary<NSString *, NSString *> *settings = [NSMutableDictionary dictionary];
    NSArray<NSString *> *lines = [content componentsSeparatedByCharactersInSet:
                                  NSCharacterSet.newlineCharacterSet];
    for (NSString *rawLine in lines) {
        NSString *line = [rawLine stringByTrimmingCharactersInSet:
                          NSCharacterSet.whitespaceCharacterSet];
        if (line.length == 0 || [line hasPrefix:@"#"]) continue;

        NSRange eq = [line rangeOfString:@"="];
        if (eq.location == NSNotFound) continue;

        NSString *key = [[line substringToIndex:eq.location]
                         stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
        NSString *val = [[line substringFromIndex:eq.location + 1]
                         stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
        if (key.length > 0) settings[key] = val;
    }

    if (settings.count == 0) return nil;

    WQPatch *patch = [WQPatch new];
    patch.filename         = filename;
    patch.name             = settings[@"patch_name"]    ?: filename;
    patch.version          = settings[@"patch_version"] ?: @"1.0";
    patch.author           = settings[@"patch_author"]  ?: @"Unknown";
    patch.patchDescription = settings[@"patch_description"] ?: @"";
    patch.settings         = [settings copy];
    return patch;
}

- (void)loadAppliedPatches {
    _appliedPatchNames = [NSMutableSet set];
    NSData *data = [NSData dataWithContentsOfFile:_appliedPatchesPath];
    if (!data) return;
    NSArray *names = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
    if ([names isKindOfClass:NSArray.class]) {
        for (id obj in names) {
            if ([obj isKindOfClass:NSString.class]) [_appliedPatchNames addObject:obj];
        }
    }
}

- (void)saveAppliedPatches {
    NSArray *names = _appliedPatchNames.allObjects;
    NSData *data = [NSJSONSerialization dataWithJSONObject:names options:0 error:nil];
    if (data) [data writeToFile:_appliedPatchesPath atomically:YES];
}

@end
