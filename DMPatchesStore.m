#import "DMPatchesStore.h"
#import "DMSupabaseService.h"
#import <CommonCrypto/CommonDigest.h>

// MARK: - DMRemotePatch

@implementation DMRemotePatch

+ (nullable instancetype)patchFromDictionary:(NSDictionary *)dict {
    if (![dict isKindOfClass:[NSDictionary class]]) return nil;
    DMRemotePatch *p = [[DMRemotePatch alloc] init];
    p.patchId       = dict[@"id"]           ?: @"";
    p.patchKey      = dict[@"patch_key"]    ?: @"";
    p.displayName   = dict[@"display_name"] ?: @"";
    p.patchFilename = dict[@"patch_filename"] ?: @"";
    p.category      = dict[@"category"]     ?: @"";
    p.mode          = dict[@"mode"]         ?: @"";
    p.icon          = dict[@"icon"]         ?: @"";
    p.downloadUrl   = dict[@"download_url"];
    p.fileHash      = dict[@"file_hash"];
    p.fileSize      = dict[@"file_size"] ? [dict[@"file_size"] longLongValue] : 0;
    p.version       = dict[@"version"]   ? [dict[@"version"]   integerValue]  : 0;
    p.isActive      = [dict[@"is_active"]  boolValue];
    p.isBlocked     = [dict[@"is_blocked"] boolValue];
    p.blockMessage  = dict[@"block_message"];
    p.sortOrder     = dict[@"sort_order"] ? [dict[@"sort_order"] integerValue] : 0;
    return p;
}

@end

// MARK: - DMPatchesStore

@interface DMPatchesStore ()
@property (nonatomic, strong) NSArray<DMRemotePatch *> *remotePatches;
@property (nonatomic, assign) BOOL isLoading;
@property (nonatomic, copy, nullable) NSString *loadError;
@end

@implementation DMPatchesStore

// MARK: - Hidden directory

+ (NSURL *)hiddenPatchesDirectory {
    NSArray<NSURL *> *dirs = [[NSFileManager defaultManager]
                              URLsForDirectory:NSApplicationSupportDirectory
                              inDomains:NSUserDomainMask];
    NSURL *support = dirs.firstObject;
    // Dot-prefix makes it invisible to Files.app and Apple's file browser.
    NSURL *dir = [support URLByAppendingPathComponent:@".dmpatches" isDirectory:YES];
    NSError *err = nil;
    [[NSFileManager defaultManager] createDirectoryAtURL:dir
                             withIntermediateDirectories:YES
                                              attributes:nil
                                                   error:&err];
    return dir;
}

// MARK: - Init

- (instancetype)init {
    self = [super init];
    if (self) {
        _remotePatches = @[];
    }
    return self;
}

// MARK: - Fetch

- (void)fetchPatchesWithCompletion:(DMPatchesListCompletion)completion {
    NSString *urlStr = [NSString stringWithFormat:
                        @"%@/rest/v1/patches?is_active=eq.true&order=sort_order.asc",
                        [DMSupabaseService supabaseURL]];
    NSURL *url = [NSURL URLWithString:urlStr];
    if (!url) {
        dispatch_async(dispatch_get_main_queue(), ^{
            completion(nil, [NSError errorWithDomain:@"DMPatchesStore" code:-1 userInfo:nil]);
        });
        return;
    }

    NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:url];
    req.HTTPMethod = @"GET";
    [req setValue:[DMSupabaseService supabaseAnonKey] forHTTPHeaderField:@"apikey"];
    [req setValue:[NSString stringWithFormat:@"Bearer %@", [DMSupabaseService supabaseAnonKey]]
       forHTTPHeaderField:@"Authorization"];
    [req setValue:@"application/json" forHTTPHeaderField:@"Accept"];

    dispatch_async(dispatch_get_main_queue(), ^{ self.isLoading = YES; self.loadError = nil; });

    [[[NSURLSession sharedSession] dataTaskWithRequest:req
       completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        if (error) {
            dispatch_async(dispatch_get_main_queue(), ^{
                self.isLoading = NO;
                self.loadError = error.localizedDescription;
                completion(nil, error);
            });
            return;
        }
        NSHTTPURLResponse *http = (NSHTTPURLResponse *)response;
        if (http.statusCode < 200 || http.statusCode >= 300) {
            NSError *e = [NSError errorWithDomain:@"DMPatchesStore" code:-2 userInfo:nil];
            dispatch_async(dispatch_get_main_queue(), ^{
                self.isLoading = NO;
                self.loadError = [NSString stringWithFormat:@"HTTP %ld", (long)http.statusCode];
                completion(nil, e);
            });
            return;
        }
        NSArray *raw = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
        if (![raw isKindOfClass:[NSArray class]]) {
            NSError *e = [NSError errorWithDomain:@"DMPatchesStore" code:-3 userInfo:nil];
            dispatch_async(dispatch_get_main_queue(), ^{
                self.isLoading = NO;
                self.loadError = @"Decoding failed";
                completion(nil, e);
            });
            return;
        }
        NSMutableArray<DMRemotePatch *> *patches = [NSMutableArray arrayWithCapacity:raw.count];
        for (NSDictionary *dict in raw) {
            DMRemotePatch *p = [DMRemotePatch patchFromDictionary:dict];
            if (p) [patches addObject:p];
        }
        dispatch_async(dispatch_get_main_queue(), ^{
            self.remotePatches = [patches copy];
            self.isLoading = NO;
            completion(self.remotePatches, nil);
        });
    }] resume];
}

// MARK: - Download single patch

- (void)downloadPatch:(DMRemotePatch *)patch
             progress:(nullable DMPatchProgressBlock)progress
           completion:(DMPatchDownloadCompletion)completion {
    if (!patch.downloadUrl || patch.downloadUrl.length == 0) {
        dispatch_async(dispatch_get_main_queue(), ^{
            completion([NSError errorWithDomain:@"DMPatchesStore" code:-3 userInfo:nil]);
        });
        return;
    }
    NSURL *remoteURL = [NSURL URLWithString:patch.downloadUrl];
    if (!remoteURL) {
        dispatch_async(dispatch_get_main_queue(), ^{
            completion([NSError errorWithDomain:@"DMPatchesStore" code:-3 userInfo:nil]);
        });
        return;
    }

    NSURL *localURL = [self localURLForPatch:patch];

    // Skip if file exists and hash matches
    if ([[NSFileManager defaultManager] fileExistsAtPath:localURL.path]) {
        if (patch.fileHash && patch.fileHash.length > 0) {
            NSData *existing = [NSData dataWithContentsOfURL:localURL];
            if (existing && [[self sha256Hex:existing] isEqualToString:patch.fileHash]) {
                dispatch_async(dispatch_get_main_queue(), ^{
                    if (progress) progress(1.0);
                    completion(nil);
                });
                return;
            }
        }
        // Hash mismatch — remove stale file
        [[NSFileManager defaultManager] removeItemAtURL:localURL error:nil];
    }

    NSURLSessionDownloadTask *task = [[NSURLSession sharedSession]
        downloadTaskWithURL:remoteURL
          completionHandler:^(NSURL *tempURL, NSURLResponse *response, NSError *error) {
        if (error) {
            dispatch_async(dispatch_get_main_queue(), ^{ completion(error); });
            return;
        }
        NSHTTPURLResponse *http = (NSHTTPURLResponse *)response;
        if (http.statusCode < 200 || http.statusCode >= 300) {
            dispatch_async(dispatch_get_main_queue(), ^{
                completion([NSError errorWithDomain:@"DMPatchesStore" code:-4 userInfo:nil]);
            });
            return;
        }
        // Remove any leftover local file, then move temp into place
        NSFileManager *fm = [NSFileManager defaultManager];
        [fm removeItemAtURL:localURL error:nil];
        NSError *moveError = nil;
        BOOL ok = [fm moveItemAtURL:tempURL toURL:localURL error:&moveError];
        dispatch_async(dispatch_get_main_queue(), ^{
            if (ok) {
                if (progress) progress(1.0);
                completion(nil);
            } else {
                completion(moveError);
            }
        });
    }];
    [task resume];
}

// MARK: - Download all

- (void)downloadAllOnEach:(nullable DMPatchEachBlock)onEach
                onOverall:(nullable DMPatchOverallBlock)onOverall
               completion:(nullable DMVoidCompletion)completion {
    // Filter: active, not blocked
    NSArray<DMRemotePatch *> *todo = [self.remotePatches filteredArrayUsingPredicate:
        [NSPredicate predicateWithBlock:^BOOL(DMRemotePatch *p, id _) {
            return p.isActive && !p.isBlocked;
        }]];

    NSInteger total = todo.count;
    if (total == 0) {
        if (completion) dispatch_async(dispatch_get_main_queue(), ^{ completion(nil); });
        return;
    }

    // Sequential dispatch via recursive index stepping
    __block NSInteger currentIndex = 0;
    dispatch_queue_t serial = dispatch_queue_create("com.dmfiles.patch_download", DISPATCH_QUEUE_SERIAL);

    __block void (^downloadNext)(void);
    __block __weak void (^weakDownloadNext)(void);
    downloadNext = ^{
        if (currentIndex >= total) {
            if (completion) dispatch_async(dispatch_get_main_queue(), ^{ completion(nil); });
            return;
        }
        DMRemotePatch *patch = todo[currentIndex];
        NSInteger idx = currentIndex + 1; // 1-based for UI
        currentIndex++;

        if (onEach) {
            dispatch_async(dispatch_get_main_queue(), ^{ onEach(idx, total, patch.displayName); });
        }

        [self downloadPatch:patch progress:nil completion:^(NSError *__unused error) {
            // Continue on failure (same behaviour as Swift version)
            double overall = (double)idx / (double)total;
            if (onOverall) {
                dispatch_async(dispatch_get_main_queue(), ^{ onOverall(overall); });
            }
            void (^next)(void) = weakDownloadNext;
            if (next) dispatch_async(serial, next);
        }];
    };
    weakDownloadNext = downloadNext;

    dispatch_async(serial, downloadNext);
}

// MARK: - Helpers

- (NSURL *)localURLForPatch:(DMRemotePatch *)patch {
    NSString *filename = [NSString stringWithFormat:@"%@.dm", patch.patchFilename];
    return [[DMPatchesStore hiddenPatchesDirectory] URLByAppendingPathComponent:filename];
}

- (BOOL)patchExistsLocally:(DMRemotePatch *)patch {
    return [[NSFileManager defaultManager] fileExistsAtPath:[self localURLForPatch:patch].path];
}

/// Returns lowercase hex SHA-256 of data using CommonCrypto.
- (NSString *)sha256Hex:(NSData *)data {
    uint8_t hash[CC_SHA256_DIGEST_LENGTH];
    CC_SHA256(data.bytes, (CC_LONG)data.length, hash);
    NSMutableString *hex = [NSMutableString stringWithCapacity:CC_SHA256_DIGEST_LENGTH * 2];
    for (int i = 0; i < CC_SHA256_DIGEST_LENGTH; i++) {
        [hex appendFormat:@"%02x", hash[i]];
    }
    return [hex copy];
}

@end
