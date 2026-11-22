#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

// MARK: - Error domain

extern NSString *const DMSupabaseErrorDomain;

typedef NS_ENUM(NSInteger, DMSupabaseErrorCode) {
    DMSupabaseErrorInvalidURL       = 1000,
    DMSupabaseErrorNoData           = 1001,
    DMSupabaseErrorDecodingFailed   = 1002,
    DMSupabaseErrorKeyNotFound      = 1003,
    DMSupabaseErrorKeyBanned        = 1004,
    DMSupabaseErrorKeyExpired       = 1005,
    DMSupabaseErrorKeyInactive      = 1006,
    DMSupabaseErrorDeviceLimit      = 1007,
    DMSupabaseErrorDeviceBanned     = 1008,
    DMSupabaseErrorNetwork          = 1009,
};

// MARK: - DMSupabaseKey model

@interface DMSupabaseKey : NSObject

@property (nonatomic, copy) NSString *keyId;
@property (nonatomic, copy) NSString *keyValue;
@property (nonatomic, assign) BOOL isActive;
@property (nonatomic, assign) BOOL isBanned;
@property (nonatomic, copy, nullable) NSString *label;
@property (nonatomic, copy, nullable) NSString *expiresAt;
@property (nonatomic, copy, nullable) NSString *createdAt;

/// YES if the key is active, not banned, and not expired
@property (nonatomic, readonly) BOOL isValid;

+ (nullable instancetype)keyFromDictionary:(NSDictionary *)dict;

@end

// MARK: - DMSupabaseService

typedef void (^DMKeyCompletion)(DMSupabaseKey *_Nullable key, NSError *_Nullable error);
typedef void (^DMVoidCompletion)(NSError *_Nullable error);

@interface DMSupabaseService : NSObject

+ (NSString *)supabaseURL;
+ (NSString *)supabaseAnonKey;

@property (nonatomic, strong, readonly, nullable) DMSupabaseKey *currentKey;
@property (nonatomic, assign, readonly) BOOL isKeyRevoked;
@property (nonatomic, assign, readonly) BOOL isKeyFrozen;
@property (nonatomic, assign, readonly) BOOL isConnected;
@property (nonatomic, assign, readonly) BOOL isMaintenanceMode;
@property (nonatomic, copy, readonly) NSString *maintenanceMessage;

+ (instancetype)shared;

/// Verifica una key contra Supabase. Callback en main queue.
- (void)verifyKey:(NSString *)value completion:(DMKeyCompletion)completion;

/// Chequeo periódico de estado de la key activa. Callback en main queue.
- (void)checkKeyStatusWithCompletion:(nullable DMVoidCompletion)completion;

/// Conecta WebSocket Realtime para la key y para app_config (maintenance).
- (void)connectRealtimeForKey:(NSString *)keyValue;

/// Desconecta todos los WebSockets.
- (void)disconnect;

@end

NS_ASSUME_NONNULL_END
