//
//  WQPatchCrypto.h
//  DM FILES
//
//  Portable .dm patch-package format v1.
//  Structurally incompatible with .3105: different magic, different AAD string,
//  different key-wrapping AAD — rejected at byte 0 when renamed.
//
//  File layout
//  ───────────
//  [8  bytes]  magic  "DMFILES\0"
//  [n  bytes]  binary plist envelope:
//    schemaVersion        NSInteger  = 1
//    packageID            NSString   UUID
//    isPasswordProtected  BOOL
//    publicContentKey     NSData     32 bytes  (present only when NOT protected)
//    kdfSalt              NSData     16 bytes  (present only when protected)
//    kdfIterations        NSInteger  200 000   (present only when protected)
//    wrappedContentKey    NSData     60 bytes  nonce(12)+wrapped_key(32)+tag(16)
//    keyFingerprint       NSData     32 bytes  SHA-256(contentKey)
//    encryptedPayload     NSData     nonce(12)+ciphertext+tag(16)
//
//  Key derivation (protected packages)
//    PBKDF2-HMAC-SHA256(password_UTF8, kdfSalt, kdfIterations, 32) → wrappingKey
//    AES-256-GCM(wrappingKey, nonce=wrappedContentKey[0:12],
//                aad="DMFILES/v1/key/{packageID}",
//                plaintext=contentKey[32]) → wrappedContentKey[12:60]
//
//  Payload encryption
//    AES-256-GCM(contentKey, random_nonce(12),
//                aad="DMFILES/v1/payload/{packageID}",
//                plaintext=bplist(name,bundleID,files[]))
//
//  Payload plist: { name, bundleID, files:[{source,target,data}] }
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

static const uint8_t  kWQDMFileMagic[]  = { 'D','M','F','I','L','E','S',0x00 };
static const NSUInteger kWQDMFileMagicLen = 8;

/// Write a password-optionally-protected .dm to `destPath`.
/// `folder` must pass wq_patch_read.  `password` may be nil or empty for no protection.
/// Returns nil on success, a human-readable error on failure.
NSString *_Nullable wq_dm_write(NSString *folder, NSString *destPath,
                                NSString *_Nullable password);

/// Read and decrypt a .dm package.
/// `password` may be nil for unprotected packages.
/// On success fills `*outFolder` (a temp path) and returns nil.
/// On failure returns an error string; `*needsPassword` is YES when
/// the file is protected and the password was missing or wrong.
NSString *_Nullable wq_dm_read(NSData *fileData,
                               NSString *_Nullable password,
                               NSString *_Nullable __autoreleasing *_Nonnull outFolder,
                               BOOL *_Nullable needsPassword);

NS_ASSUME_NONNULL_END
