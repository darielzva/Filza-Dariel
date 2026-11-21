//
//  WQPatchCrypto.m
//  DM FILES
//
//  .dm package format v1 — with optional password protection.
//  Magic:   "DMFILES\0"  (8 bytes)
//  AAD:     "DMFILES/v1/payload/{packageID}"
//  Key AAD: "DMFILES/v1/key/{packageID}"
//
//  These strings are intentionally different from the .3105 equivalents
//  ("3105PATCH/v1/payload/…" and "3105PATCH/v1/key/…"), so a file of either
//  format is structurally rejected when renamed to the other extension.
//

#import "WQPatchCrypto.h"
#import <CommonCrypto/CommonCrypto.h>
#import <Security/Security.h>

// ---------------------------------------------------------------------------
#pragma mark - Internal helpers
// ---------------------------------------------------------------------------

/// Generate `len` cryptographically random bytes.
static NSData *_Nullable dm_random(NSUInteger len) {
    NSMutableData *buf = [NSMutableData dataWithLength:len];
    return SecRandomCopyBytes(kSecRandomDefault, len, buf.mutableBytes) == 0 ? buf : nil;
}

/// SHA-256 digest of `data`.
static NSData *dm_sha256(NSData *data) {
    NSMutableData *d = [NSMutableData dataWithLength:CC_SHA256_DIGEST_LENGTH];
    CC_SHA256(data.bytes, (CC_LONG)data.length, d.mutableBytes);
    return d;
}

// ---------------------------------------------------------------------------
#pragma mark - AES-256-GCM via CommonCrypto kCCModeGCM
// ---------------------------------------------------------------------------
// Wire format: nonce(12) | ciphertext | tag(16)

static NSData *_Nullable dm_gcm_seal(NSData *plaintext,
                                      NSData *key,       // 32 bytes
                                      NSData *nonce,     // 12 bytes
                                      NSData *_Nullable aad)
{
    if (key.length != 32 || nonce.length != 12) return nil;
    CCCryptorRef ref = NULL;
    if (CCCryptorCreateWithMode(kCCEncrypt, kCCModeGCM, kCCAlgorithmAES, ccNoPadding,
                                nonce.bytes, key.bytes, 32,
                                NULL, 0, 0, 0, &ref) != kCCSuccess || !ref) return nil;
    if (aad.length) CCCryptorGCMAddAAD(ref, aad.bytes, aad.length);
    NSMutableData *ct = [NSMutableData dataWithLength:plaintext.length];
    size_t moved = 0;
    if (CCCryptorUpdate(ref, plaintext.bytes, plaintext.length,
                        ct.mutableBytes, ct.length, &moved) != kCCSuccess) {
        CCCryptorRelease(ref); return nil;
    }
    CCCryptorFinal(ref, NULL, 0, NULL);
    uint8_t tag[16]; size_t tlen = 16;
    CCCryptorGCMFinalize(ref, tag, &tlen);
    CCCryptorRelease(ref);
    NSMutableData *wire = [NSMutableData dataWithCapacity:12 + ct.length + 16];
    [wire appendData:nonce];
    [wire appendData:ct];
    [wire appendBytes:tag length:16];
    return wire;
}

// Returns plaintext on success, nil on tag mismatch or bad params.
static NSData *_Nullable dm_gcm_open(NSData *wire,
                                      NSData *key,       // 32 bytes
                                      NSData *_Nullable aad)
{
    if (key.length != 32 || wire.length < 28) return nil;
    const uint8_t *b   = wire.bytes;
    NSUInteger ctLen   = wire.length - 28;
    NSData *nonce      = [NSData dataWithBytesNoCopy:(void *)b length:12 freeWhenDone:NO];
    NSData *ciphertext = [NSData dataWithBytesNoCopy:(void *)(b + 12) length:ctLen freeWhenDone:NO];
    const uint8_t *wireTag = b + 12 + ctLen;

    CCCryptorRef ref = NULL;
    if (CCCryptorCreateWithMode(kCCDecrypt, kCCModeGCM, kCCAlgorithmAES, ccNoPadding,
                                nonce.bytes, key.bytes, 32,
                                NULL, 0, 0, 0, &ref) != kCCSuccess || !ref) return nil;
    if (aad.length) CCCryptorGCMAddAAD(ref, aad.bytes, aad.length);
    NSMutableData *plain = [NSMutableData dataWithLength:ctLen];
    size_t moved = 0;
    CCCryptorUpdate(ref, ciphertext.bytes, ctLen, plain.mutableBytes, ctLen, &moved);
    CCCryptorFinal(ref, NULL, 0, NULL);
    uint8_t computedTag[16]; size_t tlen = 16;
    CCCryptorGCMFinalize(ref, computedTag, &tlen);
    CCCryptorRelease(ref);
    uint8_t diff = 0;
    for (int i = 0; i < 16; i++) diff |= computedTag[i] ^ wireTag[i];
    return diff == 0 ? plain : nil;
}

// ---------------------------------------------------------------------------
#pragma mark - Payload (de)serialization
// ---------------------------------------------------------------------------

static NSData *_Nullable dm_build_payload(NSString *patchName, NSString *bundleID,
                                           NSArray<NSDictionary *> *pjFiles, NSString *folder,
                                           NSString *__autoreleasing *err)
{
    NSMutableArray *payloadFiles = [NSMutableArray new];
    for (NSDictionary *entry in pjFiles) {
        NSString *source = entry[@"source"], *target = entry[@"target"];
        if (![source isKindOfClass:NSString.class] || ![target isKindOfClass:NSString.class]) continue;
        NSData *data = [NSData dataWithContentsOfFile:[folder stringByAppendingPathComponent:source]];
        if (!data) { if (err) *err = [NSString stringWithFormat:@"No se pudo leer '%@'.", source]; return nil; }
        [payloadFiles addObject:@{@"source": source, @"target": target, @"data": data}];
    }
    if (!payloadFiles.count) { if (err) *err = @"Sin archivos fuente válidos."; return nil; }
    NSError *plistErr = nil;
    NSData *plist = [NSPropertyListSerialization
                     dataWithPropertyList:@{@"name": patchName, @"bundleID": bundleID, @"files": payloadFiles}
                     format:NSPropertyListBinaryFormat_v1_0 options:0 error:&plistErr];
    if (!plist && err) *err = plistErr.localizedDescription ?: @"Error serializando payload.";
    return plist;
}

// ---------------------------------------------------------------------------
#pragma mark - Public API
// ---------------------------------------------------------------------------

NSString *_Nullable wq_dm_write(NSString *folder, NSString *destPath,
                                NSString *_Nullable password)
{
    // ---- 1. Read patch.json ------------------------------------------------
    NSData *pjData = [NSData dataWithContentsOfFile:[folder stringByAppendingPathComponent:@"patch.json"]];
    if (!pjData) return @"patch.json no se pudo leer.";
    id pj = [NSJSONSerialization JSONObjectWithData:pjData options:0 error:nil];
    NSString *patchName = ([pj[@"name"] isKindOfClass:NSString.class] && [pj[@"name"] length])
                          ? pj[@"name"] : folder.lastPathComponent;
    NSString *bundleID  = [pj[@"bundleID"] isKindOfClass:NSString.class] ? pj[@"bundleID"] : nil;
    NSArray  *filesList = [pj[@"files"]    isKindOfClass:NSArray.class]  ? pj[@"files"]    : nil;
    if (!bundleID.length || !filesList.count)
        return @"patch.json inválido (falta bundleID o files).";

    // ---- 2. Build payload --------------------------------------------------
    NSString *payloadErr = nil;
    NSData *payloadPlist = dm_build_payload(patchName, bundleID, filesList, folder, &payloadErr);
    if (!payloadPlist) return payloadErr ?: @"Error construyendo payload.";

    // ---- 3. Generate package ID and content key ----------------------------
    NSString *packageID = [[NSUUID UUID] UUIDString];
    NSData *contentKey  = dm_random(32);
    if (!contentKey) return @"SecRandom falló (content key).";
    NSData *keyFP = dm_sha256(contentKey);

    // ---- 4. Encrypt payload ------------------------------------------------
    NSData *payloadNonce = dm_random(12);
    if (!payloadNonce) return @"SecRandom falló (payload nonce).";
    NSData *payloadAAD = [[NSString stringWithFormat:@"DMFILES/v1/payload/%@", packageID]
                          dataUsingEncoding:NSUTF8StringEncoding];
    NSData *encPayload = dm_gcm_seal(payloadPlist, contentKey, payloadNonce, payloadAAD);
    if (!encPayload) return @"AES-256-GCM falló al cifrar payload.";

    // ---- 5. Build envelope -------------------------------------------------
    BOOL usePassword = password.length > 0;
    NSMutableDictionary *envelope = [NSMutableDictionary dictionaryWithDictionary:@{
        @"schemaVersion":       @(1),
        @"packageID":           packageID,
        @"isPasswordProtected": @(usePassword),
        @"keyFingerprint":      keyFP,
        @"encryptedPayload":    encPayload,
    }];

    if (!usePassword) {
        // No password: content key is public (readable by anyone with the file).
        envelope[@"publicContentKey"] = contentKey;
    } else {
        // PBKDF2-HMAC-SHA256(password, salt, 200000, 32) → wrappingKey
        // Then AES-256-GCM(wrappingKey, aad="DMFILES/v1/key/{packageID}") wraps contentKey.
        NSData *kdfSalt = dm_random(16);
        if (!kdfSalt) return @"SecRandom falló (kdfSalt).";
        const NSInteger kIterations = 200000;

        NSData *pwBytes = [password dataUsingEncoding:NSUTF8StringEncoding];
        uint8_t wrappingKeyRaw[32];
        if (CCKeyDerivationPBKDF(kCCPBKDF2,
                                 pwBytes.bytes, pwBytes.length,
                                 kdfSalt.bytes, kdfSalt.length,
                                 kCCPRFHmacAlgSHA256, (unsigned)kIterations,
                                 wrappingKeyRaw, 32) != kCCSuccess)
            return @"PBKDF2 falló.";
        NSData *wrappingKey = [NSData dataWithBytes:wrappingKeyRaw length:32];
        NSData *keyNonce    = dm_random(12);
        if (!keyNonce) return @"SecRandom falló (key nonce).";
        NSData *keyAAD = [[NSString stringWithFormat:@"DMFILES/v1/key/%@", packageID]
                          dataUsingEncoding:NSUTF8StringEncoding];
        NSData *wrappedKey = dm_gcm_seal(contentKey, wrappingKey, keyNonce, keyAAD);
        if (!wrappedKey) return @"AES-256-GCM falló al cifrar la content key.";
        // wrappedKey wire = keyNonce(12) + wrapped(32) + tag(16) = 60 bytes
        envelope[@"kdfSalt"]           = kdfSalt;
        envelope[@"kdfIterations"]      = @(kIterations);
        envelope[@"wrappedContentKey"]  = wrappedKey;
    }

    // ---- 6. Serialize and write --------------------------------------------
    NSError *plistErr = nil;
    NSData *envelopePlist = [NSPropertyListSerialization
                             dataWithPropertyList:envelope
                             format:NSPropertyListBinaryFormat_v1_0
                             options:0 error:&plistErr];
    if (!envelopePlist)
        return [NSString stringWithFormat:@"No se pudo serializar el envelope: %@",
                plistErr.localizedDescription ?: @"error desconocido"];

    NSMutableData *wire = [NSMutableData dataWithCapacity:kWQDMFileMagicLen + envelopePlist.length];
    [wire appendBytes:kWQDMFileMagic length:kWQDMFileMagicLen];
    [wire appendData:envelopePlist];

    [[NSFileManager defaultManager] removeItemAtPath:destPath error:nil];
    if (![wire writeToFile:destPath atomically:YES])
        return [NSString stringWithFormat:@"No se pudo escribir el .dm en %@.", destPath];
    return nil;   // success
}

NSString *_Nullable wq_dm_read(NSData *fileData,
                               NSString *_Nullable password,
                               NSString *_Nullable __autoreleasing *outFolder,
                               BOOL *_Nullable needsPassword)
{
    if (needsPassword) *needsPassword = NO;

    // ---- 1. Magic check ----------------------------------------------------
    if (fileData.length < kWQDMFileMagicLen + 8)
        return @"El archivo .dm es demasiado pequeño.";
    if (memcmp(fileData.bytes, kWQDMFileMagic, kWQDMFileMagicLen) != 0) {
        static const uint8_t k3105[] = { '3','1','0','5','P','A','T','C','H',0 };
        if (fileData.length >= 10 && memcmp(fileData.bytes, k3105, 10) == 0)
            return @"Este archivo es un paquete .3105 de otra app. DM FILES solo abre sus propios .dm.";
        static const uint8_t kZip[] = { 0x50, 0x4b, 0x03, 0x04 };
        if (fileData.length >= 4 && memcmp(fileData.bytes, kZip, 4) == 0)
            return @"Este .dm fue creado con una versión antigua. Vuelve a exportarlo desde DM FILES.";
        return @"El archivo no es un paquete .dm válido.";
    }

    // ---- 2. Parse envelope -------------------------------------------------
    NSData *envData = [fileData subdataWithRange:
                       NSMakeRange(kWQDMFileMagicLen, fileData.length - kWQDMFileMagicLen)];
    NSError *err = nil;
    id envObj = [NSPropertyListSerialization propertyListWithData:envData
                                                         options:NSPropertyListImmutable
                                                          format:nil error:&err];
    NSDictionary *env = [envObj isKindOfClass:NSDictionary.class] ? envObj : nil;
    if (!env)
        return [NSString stringWithFormat:@"Envelope inválido: %@",
                err.localizedDescription ?: @"formato desconocido"];

    NSString *packageID   = env[@"packageID"];
    BOOL isProtected      = [env[@"isPasswordProtected"] boolValue];
    NSData *keyFP         = env[@"keyFingerprint"];
    NSData *encPayload    = env[@"encryptedPayload"];

    if (![packageID isKindOfClass:NSString.class] || !packageID.length)
        return @"El .dm no tiene packageID válido.";
    if (![encPayload isKindOfClass:NSData.class] || encPayload.length < 28)
        return @"El payload cifrado del .dm está malformado.";

    // ---- 3. Recover content key --------------------------------------------
    NSData *contentKey = nil;

    if (!isProtected) {
        contentKey = [env[@"publicContentKey"] isKindOfClass:NSData.class]
                     ? env[@"publicContentKey"] : nil;
        if (contentKey.length != 32)
            return @"El .dm no trae una clave de contenido válida.";
    } else {
        // Password required
        if (!password.length) {
            if (needsPassword) *needsPassword = YES;
            return @"Este parche está protegido con contraseña.";
        }
        NSData *kdfSalt   = env[@"kdfSalt"];
        NSData *wrappedKey = env[@"wrappedContentKey"];
        NSInteger iters   = [env[@"kdfIterations"] integerValue];
        if (kdfSalt.length < 8 || wrappedKey.length != 60 || iters < 1000 || iters > 10000000)
            return @"El .dm está dañado (parámetros de contraseña inválidos).";

        NSData *pwBytes = [password dataUsingEncoding:NSUTF8StringEncoding];
        uint8_t wrappingRaw[32];
        if (CCKeyDerivationPBKDF(kCCPBKDF2,
                                 pwBytes.bytes, pwBytes.length,
                                 kdfSalt.bytes, kdfSalt.length,
                                 kCCPRFHmacAlgSHA256, (unsigned)iters,
                                 wrappingRaw, 32) != kCCSuccess)
            return @"PBKDF2 falló al derivar la clave.";
        NSData *wrappingKey = [NSData dataWithBytes:wrappingRaw length:32];
        NSData *keyAAD = [[NSString stringWithFormat:@"DMFILES/v1/key/%@", packageID]
                          dataUsingEncoding:NSUTF8StringEncoding];
        // wrappedKey wire = nonce(12) + wrapped_key(32) + tag(16)
        contentKey = dm_gcm_open(wrappedKey, wrappingKey, keyAAD);
        if (!contentKey || contentKey.length != 32) {
            if (needsPassword) *needsPassword = YES;
            return @"Contraseña incorrecta.";
        }
    }

    // ---- 4. Verify key fingerprint -----------------------------------------
    if ([keyFP isKindOfClass:NSData.class] && keyFP.length == 32) {
        if (![dm_sha256(contentKey) isEqualToData:keyFP]) {
            if (needsPassword) *needsPassword = isProtected;
            return isProtected ? @"Contraseña incorrecta."
                               : @"El .dm está dañado (el fingerprint no coincide).";
        }
    }

    // ---- 5. Decrypt payload ------------------------------------------------
    NSData *payloadAAD = [[NSString stringWithFormat:@"DMFILES/v1/payload/%@", packageID]
                          dataUsingEncoding:NSUTF8StringEncoding];
    NSData *payloadPlist = dm_gcm_open(encPayload, contentKey, payloadAAD);
    if (!payloadPlist)
        return @"El .dm falló la verificación GCM. Archivo dañado o no es de DM FILES.";

    // ---- 6. Parse payload --------------------------------------------------
    id payObj = [NSPropertyListSerialization propertyListWithData:payloadPlist
                                                         options:NSPropertyListImmutable
                                                          format:nil error:&err];
    NSDictionary *payload = [payObj isKindOfClass:NSDictionary.class] ? payObj : nil;
    if (!payload)
        return @"El payload del .dm no es un plist válido.";

    NSString *name     = payload[@"name"];
    NSString *bundleID = payload[@"bundleID"];
    NSArray  *files    = payload[@"files"];
    if (![bundleID isKindOfClass:NSString.class] || !bundleID.length)
        return @"El .dm no tiene bundleID válido en el payload.";
    if (![files isKindOfClass:NSArray.class] || !files.count)
        return @"El .dm no contiene archivos de parche.";

    // ---- 7. Reconstruct patch folder ---------------------------------------
    NSString *folderName = ([name isKindOfClass:NSString.class] && name.length)
        ? [name stringByReplacingOccurrencesOfString:@"/" withString:@"-"]
        : [packageID substringToIndex:8];
    NSString *tmpRoot = [NSTemporaryDirectory() stringByAppendingPathComponent:[[NSUUID UUID] UUIDString]];
    NSString *dest    = [tmpRoot stringByAppendingPathComponent:folderName];
    NSFileManager *fm = NSFileManager.defaultManager;
    if (![fm createDirectoryAtPath:dest withIntermediateDirectories:YES attributes:nil error:&err])
        return [NSString stringWithFormat:@"No se pudo crear la carpeta temporal: %@",
                err.localizedDescription];

    NSMutableArray<NSDictionary *> *pjFiles = [NSMutableArray new];
    NSMutableSet<NSString *> *usedNames = [NSMutableSet new];

    for (id entry in files) {
        if (![entry isKindOfClass:NSDictionary.class]) continue;
        NSString *source = entry[@"source"], *target = entry[@"target"];
        NSData   *data   = entry[@"data"];
        if (![source isKindOfClass:NSString.class] || !source.length) continue;
        if (![target isKindOfClass:NSString.class] || !target.length) continue;
        if (![data   isKindOfClass:NSData.class]   || !data.length)   continue;

        NSString *safe = source.lastPathComponent;
        if (!safe.length || [safe isEqualToString:@"."] || [safe isEqualToString:@".."]) continue;
        NSString *candidate = safe;
        for (NSUInteger k = 2; [usedNames containsObject:candidate]; k++) {
            NSString *base = safe.stringByDeletingPathExtension, *ext = safe.pathExtension;
            candidate = ext.length
                ? [NSString stringWithFormat:@"%@_%lu.%@", base, (unsigned long)k, ext]
                : [NSString stringWithFormat:@"%@_%lu", base, (unsigned long)k];
        }
        [usedNames addObject:candidate];
        if (![data writeToFile:[dest stringByAppendingPathComponent:candidate] atomically:YES]) {
            [fm removeItemAtPath:tmpRoot error:nil];
            return [NSString stringWithFormat:@"No se pudo escribir '%@' al importar.", candidate];
        }
        [pjFiles addObject:@{@"source": candidate, @"target": target}];
    }

    if (!pjFiles.count) { [fm removeItemAtPath:tmpRoot error:nil]; return @"Sin archivos de parche utilizables."; }

    NSDictionary *pj = @{@"name": name ?: folderName, @"bundleID": bundleID, @"files": pjFiles};
    NSData *pjData = [NSJSONSerialization dataWithJSONObject:pj
                                                     options:NSJSONWritingPrettyPrinted
                                                       error:nil];
    if (!pjData || ![pjData writeToFile:[dest stringByAppendingPathComponent:@"patch.json"] atomically:YES]) {
        [fm removeItemAtPath:tmpRoot error:nil];
        return @"No se pudo escribir patch.json.";
    }

    *outFolder = dest;
    return nil;   // success
}
