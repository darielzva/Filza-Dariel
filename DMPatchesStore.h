#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

// MARK: - DMRemotePatch model

@interface DMRemotePatch : NSObject

@property (nonatomic, copy) NSString *patchId;
@property (nonatomic, copy) NSString *patchKey;
@property (nonatomic, copy) NSString *displayName;
@property (nonatomic, copy) NSString *patchFilename;
@property (nonatomic, copy) NSString *category;
@property (nonatomic, copy) NSString *mode;
@property (nonatomic, copy) NSString *icon;
@property (nonatomic, copy, nullable) NSString *downloadUrl;
@property (nonatomic, copy, nullable) NSString *fileHash;
@property (nonatomic, assign) int64_t fileSize;
@property (nonatomic, assign) NSInteger version;
@property (nonatomic, assign) BOOL isActive;
@property (nonatomic, assign) BOOL isBlocked;
@property (nonatomic, copy, nullable) NSString *blockMessage;
@property (nonatomic, assign) NSInteger sortOrder;

+ (nullable instancetype)patchFromDictionary:(NSDictionary *)dict;

@end

// MARK: - DMPatchesStore

typedef void (^DMPatchesListCompletion)(NSArray<DMRemotePatch *> *_Nullable patches, NSError *_Nullable error);
typedef void (^DMPatchDownloadCompletion)(NSError *_Nullable error);
typedef void (^DMPatchProgressBlock)(double progress);
typedef void (^DMPatchEachBlock)(NSInteger index, NSInteger total, NSString *name);
typedef void (^DMPatchOverallBlock)(double overallProgress);

@interface DMPatchesStore : NSObject

@property (nonatomic, strong, readonly) NSArray<DMRemotePatch *> *remotePatches;
@property (nonatomic, assign, readonly) BOOL isLoading;
@property (nonatomic, copy, readonly, nullable) NSString *loadError;

/// `Library/Application Support/.dmpatches` — carpeta oculta (punto = invisible en Files.app)
+ (NSURL *)hiddenPatchesDirectory;

/// Fetches active patch list from Supabase `patches` table. Callback on main queue.
- (void)fetchPatchesWithCompletion:(DMPatchesListCompletion)completion;

/// Downloads a single patch `.dm` to the hidden directory. Verifies SHA-256 if fileHash is set.
/// Skips download if the local file already matches the hash. Callback on main queue.
- (void)downloadPatch:(DMRemotePatch *)patch
             progress:(nullable DMPatchProgressBlock)progress
           completion:(DMPatchDownloadCompletion)completion;

/// Downloads all active, non-blocked patches sequentially.
/// onEach fires before each download with (index, total, displayName).
/// onOverall fires after each with cumulative progress [0.0, 1.0].
/// Continues on individual failures. Callback on main queue.
- (void)downloadAllOnEach:(nullable DMPatchEachBlock)onEach
                onOverall:(nullable DMPatchOverallBlock)onOverall
               completion:(nullable DMVoidCompletion)completion;

/// Returns the local URL a patch would be saved to.
- (NSURL *)localURLForPatch:(DMRemotePatch *)patch;

/// YES if the patch file already exists on disk.
- (BOOL)patchExistsLocally:(DMRemotePatch *)patch;

@end

NS_ASSUME_NONNULL_END
