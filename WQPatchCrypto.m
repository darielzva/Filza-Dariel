//
//  WQPatchCrypto.m
//  DM FILES
//
//  AES-256-GCM implemented via AES-ECB (CCCrypt kCCOptionECBMode) + GHASH in
//  plain C — no kCCModeGCM, no CCCryptorGCMFinalize, no private APIs.
//  Identical approach to the .3105 reader already in WQUI.m.
//

#import "WQPatchCrypto.h"
#import <CommonCrypto/CommonCrypto.h>
#import <Security/Security.h>

// ---------------------------------------------------------------------------
#pragma mark - Random / SHA-256
// ---------------------------------------------------------------------------

static NSData *_Nullable dm_random(NSUInteger len)
{
    NSMutableData *buf = [NSMutableData dataWithLength:len];
    return SecRandomCopyBytes(kSecRandomDefault, len, buf.mutableBytes) == 0 ? buf : nil;
}

static NSData *dm_sha256(NSData *data)
{
    NSMutableData *d = [NSMutableData dataWithLength:CC_SHA256_DIGEST_LENGTH];
    CC_SHA256(data.bytes, (CC_LONG)data.length, d.mutableBytes);
    return d;
}

// ---------------------------------------------------------------------------
#pragma mark - GHASH (4-bit table, plain C)
// ---------------------------------------------------------------------------

typedef struct { uint64_t hl[16], hh[16]; } dm_ghash_t;

static const uint64_t dm_last4[16] = {
    0x0000, 0x1c20, 0x3840, 0x2460, 0x7080, 0x6ca0, 0x48c0, 0x54e0,
    0xe100, 0xfd20, 0xd940, 0xc560, 0x9180, 0x8da0, 0xa9c0, 0xb5e0
};

static void dm_ghash_init(dm_ghash_t *g, const uint8_t h[16])
{
    uint64_t vh = 0, vl = 0;
    for (int i = 0; i < 8; i++) { vh = (vh << 8) | h[i]; vl = (vl << 8) | h[8+i]; }
    g->hl[0] = 0; g->hh[0] = 0;
    g->hl[8] = vl; g->hh[8] = vh;
    for (int i = 4; i > 0; i >>= 1) {
        uint32_t t = (uint32_t)(vl & 1) * 0xe1000000U;
        vl = (vh << 63) | (vl >> 1);
        vh = (vh >> 1) ^ ((uint64_t)t << 32);
        g->hl[i] = vl; g->hh[i] = vh;
    }
    for (int i = 2; i < 16; i <<= 1) {
        uint64_t *hil = g->hl + i, *hih = g->hh + i;
        vh = *hih; vl = *hil;
        for (int j = 1; j < i; j++) { hih[j] = vh ^ g->hh[j]; hil[j] = vl ^ g->hl[j]; }
    }
}

static void dm_ghash_mult(const dm_ghash_t *g, uint8_t x[16])
{
    uint8_t lo = x[15] & 0xf;
    uint64_t zh = g->hh[lo], zl = g->hl[lo];
    for (int i = 15; i >= 0; i--) {
        lo = x[i] & 0xf;
        uint8_t hi = (x[i] >> 4) & 0xf, rem;
        if (i != 15) {
            rem = (uint8_t)(zl & 0xf);
            zl = (zh << 60) | (zl >> 4); zh >>= 4;
            zh ^= dm_last4[rem] << 48; zh ^= g->hh[lo]; zl ^= g->hl[lo];
        }
        rem = (uint8_t)(zl & 0xf);
        zl = (zh << 60) | (zl >> 4); zh >>= 4;
        zh ^= dm_last4[rem] << 48; zh ^= g->hh[hi]; zl ^= g->hl[hi];
    }
    for (int i = 0; i < 8; i++) {
        x[i]   = (uint8_t)(zh >> (56 - 8*i));
        x[8+i] = (uint8_t)(zl >> (56 - 8*i));
    }
}

static void dm_ghash_update(const dm_ghash_t *g, uint8_t y[16],
                             const uint8_t *data, size_t len)
{
    while (len) {
        size_t n = len < 16 ? len : 16;
        for (size_t i = 0; i < n; i++) y[i] ^= data[i];
        dm_ghash_mult(g, y);
        data += n; len -= n;
    }
}

// ---------------------------------------------------------------------------
#pragma mark - AES-ECB block (CCCrypt, no kCCModeGCM)
// ---------------------------------------------------------------------------

static BOOL dm_aes_ecb(NSData *key, const uint8_t *in, size_t len, uint8_t *out)
{
    size_t moved = 0;
    CCCryptorStatus st = CCCrypt(kCCEncrypt, kCCAlgorithmAES, kCCOptionECBMode,
                                 key.bytes, key.length, NULL,
                                 in, len, out, len, &moved);
    return st == kCCSuccess && moved == len;
}

// ---------------------------------------------------------------------------
#pragma mark - AES-256-GCM tag computation
// ---------------------------------------------------------------------------
// Computes the GCM authentication tag over (aad, ciphertext) using `key`.
// nonce must be 12 bytes; writes 16 bytes into `tag_out`.
// Returns NO on AES failure.

static BOOL dm_gcm_tag(NSData *key, const uint8_t *nonce,
                        const uint8_t *aad,        size_t aadLen,
                        const uint8_t *ciphertext, size_t ctLen,
                        uint8_t tag_out[16])
{
    // H = AES(key, 0^128)
    uint8_t zero[16] = {0}, h[16];
    if (!dm_aes_ecb(key, zero, 16, h)) return NO;
    dm_ghash_t ghash; dm_ghash_init(&ghash, h);

    // GHASH(aad || ciphertext || lengths)
    uint8_t y[16] = {0};
    dm_ghash_update(&ghash, y, aad,        aadLen);
    dm_ghash_update(&ghash, y, ciphertext, ctLen);
    uint8_t lengths[16];
    uint64_t ab = (uint64_t)aadLen * 8, cb = (uint64_t)ctLen * 8;
    for (int i = 0; i < 8; i++) {
        lengths[i]   = (uint8_t)(ab >> (56 - 8*i));
        lengths[8+i] = (uint8_t)(cb >> (56 - 8*i));
    }
    dm_ghash_update(&ghash, y, lengths, 16);

    // EJ0 = AES(key, nonce || 0x00000001)
    uint8_t j0[16] = {0}, ej0[16];
    memcpy(j0, nonce, 12); j0[15] = 1;
    if (!dm_aes_ecb(key, j0, 16, ej0)) return NO;

    // tag = GHASH_result XOR EJ0
    for (int i = 0; i < 16; i++) tag_out[i] = y[i] ^ ej0[i];
    return YES;
}

// ---------------------------------------------------------------------------
#pragma mark - AES-256-CTR keystream (counter starting at 2)
// ---------------------------------------------------------------------------

static BOOL dm_gcm_ctr(NSData *key, const uint8_t *nonce,
                        const uint8_t *in, uint8_t *out, size_t len)
{
    const size_t CHUNK = 65536;   // blocks per batch (1 MB keystream)
    uint8_t *counters = malloc(CHUNK * 16);
    uint8_t *stream   = malloc(CHUNK * 16);
    if (!counters || !stream) { free(counters); free(stream); return NO; }
    uint32_t ctr = 2;
    size_t done = 0;
    BOOL ok = YES;
    while (done < len) {
        size_t rem    = len - done;
        size_t blocks = (rem + 15) / 16;
        if (blocks > CHUNK) blocks = CHUNK;
        for (size_t b = 0; b < blocks; b++) {
            memcpy(counters + b*16, nonce, 12);
            uint32_t c = ctr++;
            counters[b*16+12] = (uint8_t)(c >> 24);
            counters[b*16+13] = (uint8_t)(c >> 16);
            counters[b*16+14] = (uint8_t)(c >>  8);
            counters[b*16+15] = (uint8_t) c;
        }
        if (!dm_aes_ecb(key, counters, blocks*16, stream)) { ok = NO; break; }
        size_t n = blocks*16 < rem ? blocks*16 : rem;
        for (size_t i = 0; i < n; i++) out[done+i] = in[done+i] ^ stream[i];
        done += n;
    }
    free(counters); free(stream);
    return ok;
}

// ---------------------------------------------------------------------------
#pragma mark - dm_gcm_seal / dm_gcm_open
// ---------------------------------------------------------------------------
// Wire format: nonce(12) | ciphertext | tag(16)

static NSData *_Nullable dm_gcm_seal(NSData *plaintext, NSData *key,
                                      NSData *nonce, NSData *_Nullable aad)
{
    if (key.length != 32 || nonce.length != 12) return nil;
    NSMutableData *ct = [NSMutableData dataWithLength:plaintext.length];
    if (plaintext.length) {
        if (!dm_gcm_ctr(key, nonce.bytes, plaintext.bytes, ct.mutableBytes, plaintext.length))
            return nil;
    }
    uint8_t tag[16];
    const uint8_t *aadBytes = aad.length ? (const uint8_t *)aad.bytes : (const uint8_t *)"";
    if (!dm_gcm_tag(key, nonce.bytes, aadBytes, aad.length,
                    ct.bytes, ct.length, tag)) return nil;

    NSMutableData *wire = [NSMutableData dataWithCapacity:12 + ct.length + 16];
    [wire appendData:nonce];
    [wire appendData:ct];
    [wire appendBytes:tag length:16];
    return wire;
}

// Returns plaintext on success, nil on tag mismatch or bad params.
static NSData *_Nullable dm_gcm_open(NSData *wire, NSData *key, NSData *_Nullable aad)
{
    if (key.length != 32 || wire.length < 28) return nil;
    const uint8_t *b  = (const uint8_t *)wire.bytes;
    const uint8_t *nonce = b;
    NSUInteger ctLen     = wire.length - 28;
    const uint8_t *ct    = b + 12;
    const uint8_t *wireTag = b + 12 + ctLen;

    // Verify tag first (constant-time)
    uint8_t expectedTag[16];
    const uint8_t *aadBytes = aad.length ? (const uint8_t *)aad.bytes : (const uint8_t *)"";
    if (!dm_gcm_tag(key, nonce, aadBytes, aad.length, ct, ctLen, expectedTag)) return nil;
    uint8_t diff = 0;
    for (int i = 0; i < 16; i++) diff |= expectedTag[i] ^ wireTag[i];
    if (diff) return nil;

    // Decrypt
    NSMutableData *plain = [NSMutableData dataWithLength:ctLen];
    if (ctLen && !dm_gcm_ctr(key, nonce, ct, plain.mutableBytes, ctLen)) return nil;
    return plain;
}

// ---------------------------------------------------------------------------
#pragma mark - Payload helpers
// ---------------------------------------------------------------------------

static NSData *_Nullable dm_build_payload(NSString *name, NSString *bundleID,
                                           NSArray *pjFiles, NSString *folder,
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
                     dataWithPropertyList:@{@"name": name, @"bundleID": bundleID, @"files": payloadFiles}
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
    // ---- 1. patch.json -----------------------------------------------------
    NSData *pjData = [NSData dataWithContentsOfFile:[folder stringByAppendingPathComponent:@"patch.json"]];
    if (!pjData) return @"patch.json no se pudo leer.";
    id pj = [NSJSONSerialization JSONObjectWithData:pjData options:0 error:nil];
    NSString *patchName = ([pj[@"name"] isKindOfClass:NSString.class] && [pj[@"name"] length])
                          ? pj[@"name"] : folder.lastPathComponent;
    NSString *bundleID  = [pj[@"bundleID"] isKindOfClass:NSString.class] ? pj[@"bundleID"] : nil;
    NSArray  *filesList = [pj[@"files"]    isKindOfClass:NSArray.class]  ? pj[@"files"]    : nil;
    if (!bundleID.length || !filesList.count)
        return @"patch.json inválido (falta bundleID o files).";

    // ---- 2. Payload --------------------------------------------------------
    NSString *payloadErr = nil;
    NSData *payloadPlist = dm_build_payload(patchName, bundleID, filesList, folder, &payloadErr);
    if (!payloadPlist) return payloadErr ?: @"Error construyendo payload.";

    // ---- 3. Package ID + content key ---------------------------------------
    NSString *packageID = [[NSUUID UUID] UUIDString];
    NSData *contentKey  = dm_random(32);
    if (!contentKey) return @"SecRandom falló (content key).";

    // ---- 4. Encrypt payload ------------------------------------------------
    NSData *payloadNonce = dm_random(12);
    if (!payloadNonce) return @"SecRandom falló (payload nonce).";
    NSData *payloadAAD = [[NSString stringWithFormat:@"DMFILES/v1/payload/%@", packageID]
                          dataUsingEncoding:NSUTF8StringEncoding];
    NSData *encPayload = dm_gcm_seal(payloadPlist, contentKey, payloadNonce, payloadAAD);
    if (!encPayload) return @"AES-256-GCM falló al cifrar payload.";

    // ---- 5. Envelope -------------------------------------------------------
    BOOL usePassword = password.length > 0;
    NSMutableDictionary *env = [NSMutableDictionary dictionaryWithDictionary:@{
        @"schemaVersion":       @(1),
        @"packageID":           packageID,
        @"isPasswordProtected": @(usePassword),
        @"keyFingerprint":      dm_sha256(contentKey),
        @"encryptedPayload":    encPayload,
    }];

    if (!usePassword) {
        env[@"publicContentKey"] = contentKey;
    } else {
        // PBKDF2(pw, salt, 200000) → wrappingKey; GCM-seal(contentKey) → wrappedContentKey
        NSData *kdfSalt = dm_random(16);
        if (!kdfSalt) return @"SecRandom falló (kdfSalt).";
        NSData *pwBytes = [password dataUsingEncoding:NSUTF8StringEncoding];
        uint8_t wrappingRaw[32];
        if (CCKeyDerivationPBKDF(kCCPBKDF2, pwBytes.bytes, pwBytes.length,
                                 kdfSalt.bytes, kdfSalt.length,
                                 kCCPRFHmacAlgSHA256, 200000,
                                 wrappingRaw, 32) != kCCSuccess)
            return @"PBKDF2 falló.";
        NSData *wrappingKey = [NSData dataWithBytes:wrappingRaw length:32];
        NSData *keyNonce    = dm_random(12);
        if (!keyNonce) return @"SecRandom falló (key nonce).";
        NSData *keyAAD = [[NSString stringWithFormat:@"DMFILES/v1/key/%@", packageID]
                          dataUsingEncoding:NSUTF8StringEncoding];
        NSData *wrappedKey = dm_gcm_seal(contentKey, wrappingKey, keyNonce, keyAAD);
        if (!wrappedKey) return @"AES-256-GCM falló al cifrar la content key.";
        env[@"kdfSalt"]          = kdfSalt;
        env[@"kdfIterations"]    = @(200000);
        env[@"wrappedContentKey"] = wrappedKey;
    }

    // ---- 6. Serialize + write ----------------------------------------------
    NSError *plistErr = nil;
    NSData *envPlist = [NSPropertyListSerialization
                        dataWithPropertyList:env
                        format:NSPropertyListBinaryFormat_v1_0
                        options:0 error:&plistErr];
    if (!envPlist)
        return [NSString stringWithFormat:@"No se pudo serializar el envelope: %@",
                plistErr.localizedDescription ?: @"error desconocido"];

    NSMutableData *wire = [NSMutableData dataWithCapacity:kWQDMFileMagicLen + envPlist.length];
    [wire appendBytes:kWQDMFileMagic length:kWQDMFileMagicLen];
    [wire appendData:envPlist];
    [[NSFileManager defaultManager] removeItemAtPath:destPath error:nil];
    if (![wire writeToFile:destPath atomically:YES])
        return [NSString stringWithFormat:@"No se pudo escribir el .dm en %@.", destPath];
    return nil;
}

NSString *_Nullable wq_dm_read(NSData *fileData,
                               NSString *_Nullable password,
                               NSString *_Nullable __autoreleasing *outFolder,
                               BOOL *_Nullable needsPassword)
{
    if (needsPassword) *needsPassword = NO;

    // ---- 1. Magic ----------------------------------------------------------
    if (fileData.length < kWQDMFileMagicLen + 8)
        return @"El archivo .dm es demasiado pequeño.";
    if (memcmp(fileData.bytes, kWQDMFileMagic, kWQDMFileMagicLen) != 0) {
        static const uint8_t k3105[] = {'3','1','0','5','P','A','T','C','H',0};
        if (fileData.length >= 10 && memcmp(fileData.bytes, k3105, 10) == 0)
            return @"Este archivo es un paquete .3105 de otra app. DM FILES solo abre sus propios .dm.";
        static const uint8_t kZip[] = {0x50,0x4b,0x03,0x04};
        if (fileData.length >= 4 && memcmp(fileData.bytes, kZip, 4) == 0)
            return @"Este .dm fue creado con una versión antigua. Vuelve a exportarlo desde DM FILES.";
        return @"El archivo no es un paquete .dm válido.";
    }

    // ---- 2. Envelope -------------------------------------------------------
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

    // ---- 3. Content key ----------------------------------------------------
    NSData *contentKey = nil;
    if (!isProtected) {
        contentKey = [env[@"publicContentKey"] isKindOfClass:NSData.class]
                     ? env[@"publicContentKey"] : nil;
        if (contentKey.length != 32) return @"El .dm no trae una clave de contenido válida.";
    } else {
        if (!password.length) {
            if (needsPassword) *needsPassword = YES;
            return @"Este parche está protegido con contraseña.";
        }
        NSData *kdfSalt    = env[@"kdfSalt"];
        NSData *wrappedKey = env[@"wrappedContentKey"];
        NSInteger iters    = [env[@"kdfIterations"] integerValue];
        if (kdfSalt.length < 8 || wrappedKey.length != 60 || iters < 1000 || iters > 10000000)
            return @"El .dm está dañado (parámetros de contraseña inválidos).";
        NSData *pwBytes = [password dataUsingEncoding:NSUTF8StringEncoding];
        uint8_t wrappingRaw[32];
        if (CCKeyDerivationPBKDF(kCCPBKDF2, pwBytes.bytes, pwBytes.length,
                                 kdfSalt.bytes, kdfSalt.length,
                                 kCCPRFHmacAlgSHA256, (unsigned)iters,
                                 wrappingRaw, 32) != kCCSuccess)
            return @"PBKDF2 falló al derivar la clave.";
        NSData *wrappingKey = [NSData dataWithBytes:wrappingRaw length:32];
        NSData *keyAAD = [[NSString stringWithFormat:@"DMFILES/v1/key/%@", packageID]
                          dataUsingEncoding:NSUTF8StringEncoding];
        contentKey = dm_gcm_open(wrappedKey, wrappingKey, keyAAD);
        if (!contentKey || contentKey.length != 32) {
            if (needsPassword) *needsPassword = YES;
            return @"Contraseña incorrecta.";
        }
    }

    // ---- 4. Fingerprint ----------------------------------------------------
    if ([keyFP isKindOfClass:NSData.class] && keyFP.length == 32) {
        if (![dm_sha256(contentKey) isEqualToData:keyFP]) {
            if (needsPassword) *needsPassword = isProtected;
            return isProtected ? @"Contraseña incorrecta."
                               : @"El .dm está dañado (fingerprint no coincide).";
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
    if (!payload) return @"El payload del .dm no es un plist válido.";

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

    NSMutableArray *pjFiles = [NSMutableArray new];
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

    if (!pjFiles.count) {
        [fm removeItemAtPath:tmpRoot error:nil];
        return @"Sin archivos de parche utilizables.";
    }

    NSData *pjData = [NSJSONSerialization
                      dataWithJSONObject:@{@"name": name ?: folderName,
                                           @"bundleID": bundleID,
                                           @"files": pjFiles}
                      options:NSJSONWritingPrettyPrinted error:nil];
    if (!pjData || ![pjData writeToFile:[dest stringByAppendingPathComponent:@"patch.json"]
                             atomically:YES]) {
        [fm removeItemAtPath:tmpRoot error:nil];
        return @"No se pudo escribir patch.json.";
    }

    *outFolder = dest;
    return nil;
}
