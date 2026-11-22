#import "DMSupabaseService.h"

NSString *const DMSupabaseErrorDomain = @"DMSupabaseErrorDomain";

// MARK: - Helpers

static NSDate *_Nullable DMParseISO8601(NSString *string) {
    if (!string || string.length == 0) return nil;

    // Strip fractional seconds: "2024-01-01T00:00:00.123+00:00" → "2024-01-01T00:00:00+00:00"
    NSString *stripped = [string stringByReplacingOccurrencesOfString:@"\\.\\d+"
                                                           withString:@""
                                                              options:NSRegularExpressionSearch
                                                                range:NSMakeRange(0, string.length)];
    NSISO8601DateFormatter *fmt = [[NSISO8601DateFormatter alloc] init];
    fmt.formatOptions = NSISO8601DateFormatWithInternetDateTime | NSISO8601DateFormatWithFractionalSeconds;
    NSDate *d = [fmt dateFromString:string];
    if (d) return d;

    fmt.formatOptions = NSISO8601DateFormatWithInternetDateTime;
    d = [fmt dateFromString:string];
    if (d) return d;

    return [fmt dateFromString:stripped];
}

// MARK: - DMSupabaseKey

@implementation DMSupabaseKey

+ (nullable instancetype)keyFromDictionary:(NSDictionary *)dict {
    if (![dict isKindOfClass:[NSDictionary class]]) return nil;
    DMSupabaseKey *k = [[DMSupabaseKey alloc] init];
    k.keyId     = dict[@"id"]         ?: @"";
    k.keyValue  = dict[@"key_value"]  ?: @"";
    k.isActive  = [dict[@"is_active"] boolValue];
    k.isBanned  = [dict[@"is_banned"] boolValue];
    k.label     = dict[@"label"];
    k.expiresAt = dict[@"expires_at"];
    k.createdAt = dict[@"created_at"];
    return k;
}

- (BOOL)isValid {
    if (!self.isActive || self.isBanned) return NO;
    if (self.expiresAt) {
        NSDate *expDate = DMParseISO8601(self.expiresAt);
        if (expDate && [expDate compare:[NSDate date]] == NSOrderedAscending) return NO;
    }
    return YES;
}

@end

// MARK: - DMSupabaseService

@interface DMSupabaseService () <NSURLSessionWebSocketDelegate>

@property (nonatomic, strong, nullable) DMSupabaseKey *currentKey;
@property (nonatomic, assign) BOOL isKeyRevoked;
@property (nonatomic, assign) BOOL isKeyFrozen;
@property (nonatomic, assign) BOOL isConnected;
@property (nonatomic, assign) BOOL isMaintenanceMode;
@property (nonatomic, copy) NSString *maintenanceMessage;

@property (nonatomic, strong, nullable) NSURLSessionWebSocketTask *keyWSTask;
@property (nonatomic, strong, nullable) NSURLSessionWebSocketTask *maintWSTask;
@property (nonatomic, strong, nullable) NSTimer *heartbeatTimer;
@property (nonatomic, strong) NSURLSession *wsSession;

@end

@implementation DMSupabaseService

+ (NSString *)supabaseURL {
    return @"https://joihzvppwcaybutdgcqw.supabase.co";
}

+ (NSString *)supabaseAnonKey {
    return @"eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9."
           @"eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6ImpvaWh6dnBwd2NheWJ1dGRnY3F3Iiwicm9sZSI6ImFub24iLCJpYXQiOjE3OTM1ODc2MTUsImV4cCI6MjEwOTE2MzYxNX0."
           @"q2ueR7wHbheobTEuag3aTWpGkVJJJ9iwS3L4CMrpV38";
}

+ (instancetype)shared {
    static DMSupabaseService *instance = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        instance = [[DMSupabaseService alloc] init];
    });
    return instance;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _maintenanceMessage = @"El servicio está en mantenimiento. Vuelve pronto.";
        _wsSession = [NSURLSession sessionWithConfiguration:[NSURLSessionConfiguration defaultSessionConfiguration]
                                                   delegate:self
                                              delegateQueue:nil];
    }
    return self;
}

// MARK: - Verify Key

- (void)verifyKey:(NSString *)value completion:(DMKeyCompletion)completion {
    NSString *trimmed = [value stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    NSString *encoded = [trimmed stringByAddingPercentEncodingWithAllowedCharacters:[NSCharacterSet URLQueryAllowedCharacterSet]];
    NSString *urlStr  = [NSString stringWithFormat:@"%@/rest/v1/keys?key_value=eq.%@&select=*&limit=1",
                         [DMSupabaseService supabaseURL], encoded];

    NSURL *url = [NSURL URLWithString:urlStr];
    if (!url) {
        dispatch_async(dispatch_get_main_queue(), ^{
            completion(nil, [NSError errorWithDomain:DMSupabaseErrorDomain
                                               code:DMSupabaseErrorInvalidURL
                                           userInfo:nil]);
        });
        return;
    }

    NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:url];
    req.HTTPMethod = @"GET";
    [req setValue:[DMSupabaseService supabaseAnonKey] forHTTPHeaderField:@"apikey"];
    [req setValue:[NSString stringWithFormat:@"Bearer %@", [DMSupabaseService supabaseAnonKey]]
       forHTTPHeaderField:@"Authorization"];
    [req setValue:@"application/json" forHTTPHeaderField:@"Accept"];

    NSURLSessionDataTask *task = [[NSURLSession sharedSession] dataTaskWithRequest:req
                                  completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        if (error) {
            dispatch_async(dispatch_get_main_queue(), ^{
                completion(nil, [NSError errorWithDomain:DMSupabaseErrorDomain
                                                   code:DMSupabaseErrorNetwork
                                               userInfo:@{NSUnderlyingErrorKey: error}]);
            });
            return;
        }
        if (!data) {
            dispatch_async(dispatch_get_main_queue(), ^{
                completion(nil, [NSError errorWithDomain:DMSupabaseErrorDomain
                                                   code:DMSupabaseErrorNoData
                                               userInfo:nil]);
            });
            return;
        }

        NSError *jsonError = nil;
        id obj = [NSJSONSerialization JSONObjectWithData:data options:0 error:&jsonError];
        if (!obj || jsonError || ![obj isKindOfClass:[NSArray class]]) {
            dispatch_async(dispatch_get_main_queue(), ^{
                completion(nil, [NSError errorWithDomain:DMSupabaseErrorDomain
                                                   code:DMSupabaseErrorDecodingFailed
                                               userInfo:nil]);
            });
            return;
        }

        NSArray *keys = (NSArray *)obj;
        NSDictionary *dict = keys.firstObject;
        if (!dict) {
            dispatch_async(dispatch_get_main_queue(), ^{
                completion(nil, [NSError errorWithDomain:DMSupabaseErrorDomain
                                                   code:DMSupabaseErrorKeyNotFound
                                               userInfo:nil]);
            });
            return;
        }

        DMSupabaseKey *key = [DMSupabaseKey keyFromDictionary:dict];
        if (!key) {
            dispatch_async(dispatch_get_main_queue(), ^{
                completion(nil, [NSError errorWithDomain:DMSupabaseErrorDomain
                                                   code:DMSupabaseErrorDecodingFailed
                                               userInfo:nil]);
            });
            return;
        }

        NSError *keyError = nil;
        if (key.isBanned) {
            keyError = [NSError errorWithDomain:DMSupabaseErrorDomain code:DMSupabaseErrorKeyBanned userInfo:nil];
        } else if (!key.isActive) {
            keyError = [NSError errorWithDomain:DMSupabaseErrorDomain code:DMSupabaseErrorKeyInactive userInfo:nil];
        } else if (key.expiresAt) {
            NSDate *expDate = DMParseISO8601(key.expiresAt);
            if (expDate && [expDate compare:[NSDate date]] == NSOrderedAscending) {
                keyError = [NSError errorWithDomain:DMSupabaseErrorDomain code:DMSupabaseErrorKeyExpired userInfo:nil];
            }
        }

        dispatch_async(dispatch_get_main_queue(), ^{
            if (keyError) {
                completion(nil, keyError);
                return;
            }
            self.currentKey  = key;
            self.isConnected = YES;
            [self connectRealtimeForKey:key.keyValue];
            completion(key, nil);
        });
    }];
    [task resume];
}

// MARK: - Periodic Status Check

- (void)checkKeyStatusWithCompletion:(nullable DMVoidCompletion)completion {
    if (!self.currentKey) return;

    NSString *encoded = [self.currentKey.keyValue
                         stringByAddingPercentEncodingWithAllowedCharacters:[NSCharacterSet URLQueryAllowedCharacterSet]];
    NSString *urlStr = [NSString stringWithFormat:
                        @"%@/rest/v1/keys?key_value=eq.%@&select=is_active,is_banned,expires_at&limit=1",
                        [DMSupabaseService supabaseURL], encoded];

    NSURL *url = [NSURL URLWithString:urlStr];
    if (!url) return;

    NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:url];
    req.HTTPMethod = @"GET";
    [req setValue:[DMSupabaseService supabaseAnonKey] forHTTPHeaderField:@"apikey"];
    [req setValue:[NSString stringWithFormat:@"Bearer %@", [DMSupabaseService supabaseAnonKey]]
       forHTTPHeaderField:@"Authorization"];
    [req setValue:@"application/json" forHTTPHeaderField:@"Accept"];

    [[[NSURLSession sharedSession] dataTaskWithRequest:req
       completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        if (!data || error) {
            if (completion) dispatch_async(dispatch_get_main_queue(), ^{ completion(error); });
            return;
        }
        NSArray *arr = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
        NSDictionary *dict = [arr isKindOfClass:[NSArray class]] ? arr.firstObject : nil;
        if (!dict) {
            if (completion) dispatch_async(dispatch_get_main_queue(), ^{ completion(nil); });
            return;
        }

        BOOL isActive = [dict[@"is_active"] boolValue];
        BOOL isBanned = [dict[@"is_banned"] boolValue];
        NSString *expiresAt = dict[@"expires_at"];

        dispatch_async(dispatch_get_main_queue(), ^{
            if (isBanned) {
                self.isKeyRevoked = YES;
            } else if (!isActive) {
                self.isKeyFrozen = YES;
            } else if (expiresAt) {
                NSDate *expDate = DMParseISO8601(expiresAt);
                if (expDate && [expDate compare:[NSDate date]] == NSOrderedAscending) {
                    self.isKeyRevoked = YES;
                }
            }
            if (completion) completion(nil);
        });
    }] resume];
}

// MARK: - Realtime WebSocket

- (void)connectRealtimeForKey:(NSString *)keyValue {
    NSString *wsBase = [[DMSupabaseService supabaseURL]
                        stringByReplacingOccurrencesOfString:@"https://"
                        withString:@"wss://"];
    NSString *wsURLStr = [NSString stringWithFormat:@"%@/realtime/v1/websocket?apikey=%@&vsn=1.0.0",
                          wsBase, [DMSupabaseService supabaseAnonKey]];
    NSURL *wsURL = [NSURL URLWithString:wsURLStr];
    if (!wsURL) return;

    NSMutableURLRequest *wsReq = [NSMutableURLRequest requestWithURL:wsURL];
    [wsReq setValue:[DMSupabaseService supabaseAnonKey] forHTTPHeaderField:@"apikey"];

    self.keyWSTask = [self.wsSession webSocketTaskWithRequest:wsReq];
    [self.keyWSTask resume];
    NSString *keyFilter = [NSString stringWithFormat:@"key_value=eq.%@", keyValue];
    [self sendPhxJoin:self.keyWSTask topic:@"realtime:keys" table:@"keys" filter:keyFilter];
    __weak typeof(self) weak = self;
    [self listenOnTask:self.keyWSTask handler:^(NSDictionary *payload) {
        [weak handleKeyEvent:payload];
    }];

    self.maintWSTask = [self.wsSession webSocketTaskWithRequest:wsReq];
    [self.maintWSTask resume];
    [self sendPhxJoin:self.maintWSTask topic:@"realtime:app_config" table:@"app_config" filter:@"id=eq.1"];
    [self listenOnTask:self.maintWSTask handler:^(NSDictionary *payload) {
        [weak handleMaintenanceEvent:payload];
    }];

    [self startHeartbeat];
}

- (void)disconnect {
    [self.heartbeatTimer invalidate];
    self.heartbeatTimer = nil;
    [self.keyWSTask cancel];
    self.keyWSTask = nil;
    [self.maintWSTask cancel];
    self.maintWSTask = nil;
}

// MARK: - Private WebSocket Helpers

- (void)sendPhxJoin:(NSURLSessionWebSocketTask *)task
              topic:(NSString *)topic
              table:(NSString *)table
             filter:(NSString *)filter {
    NSDictionary *msg = @{
        @"topic": topic,
        @"event": @"phx_join",
        @"payload": @{
            @"config": @{
                @"broadcast": @{@"self": @NO},
                @"postgres_changes": @[@{
                    @"event": @"*",
                    @"schema": @"public",
                    @"table": table,
                    @"filter": filter
                }]
            }
        },
        @"ref": @"1"
    };
    NSData *data = [NSJSONSerialization dataWithJSONObject:msg options:0 error:nil];
    if (!data) return;
    NSString *str = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
    if (!str) return;
    NSURLSessionWebSocketMessage *wsMsg = [[NSURLSessionWebSocketMessage alloc] initWithString:str];
    [task sendMessage:wsMsg completionHandler:^(NSError *err) {}];
}

- (void)listenOnTask:(NSURLSessionWebSocketTask *)task
             handler:(void (^)(NSDictionary *payload))handler {
    if (!task) return;
    __weak typeof(self) weak = self;
    [task receiveMessageWithCompletionHandler:^(NSURLSessionWebSocketMessage *msg, NSError *error) {
        if (error) return; // socket closed or error — stop recursing
        if (msg.type == NSURLSessionWebSocketMessageTypeString) {
            NSData *data = [msg.string dataUsingEncoding:NSUTF8StringEncoding];
            NSDictionary *json = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
            if ([json isKindOfClass:[NSDictionary class]]) {
                handler(json);
            }
        }
        // Recurse to keep listening
        [weak listenOnTask:task handler:handler];
    }];
}

- (void)handleKeyEvent:(NSDictionary *)payload {
    NSDictionary *inner = payload[@"payload"];
    NSDictionary *data  = inner[@"data"];
    NSDictionary *record = data[@"record"];
    if (![record isKindOfClass:[NSDictionary class]]) return;

    BOOL isActive = [record[@"is_active"] boolValue];
    BOOL isBanned = [record[@"is_banned"] boolValue];

    dispatch_async(dispatch_get_main_queue(), ^{
        if (isBanned)       self.isKeyRevoked = YES;
        else if (!isActive) self.isKeyFrozen  = YES;
    });
}

- (void)handleMaintenanceEvent:(NSDictionary *)payload {
    NSDictionary *inner  = payload[@"payload"];
    NSDictionary *data   = inner[@"data"];
    NSDictionary *record = data[@"record"];
    if (![record isKindOfClass:[NSDictionary class]]) return;

    BOOL maint = [record[@"maintenance_mode"] boolValue];
    NSString *msg = record[@"maintenance_message"];

    dispatch_async(dispatch_get_main_queue(), ^{
        self.isMaintenanceMode = maint;
        if (msg) self.maintenanceMessage = msg;
    });
}

- (void)startHeartbeat {
    dispatch_async(dispatch_get_main_queue(), ^{
        self.heartbeatTimer = [NSTimer scheduledTimerWithTimeInterval:25.0
                                                              repeats:YES
                                                                block:^(NSTimer *timer) {
            NSDictionary *hb = @{@"topic": @"phoenix", @"event": @"heartbeat",
                                 @"payload": @{}, @"ref": @"hb"};
            NSData *data = [NSJSONSerialization dataWithJSONObject:hb options:0 error:nil];
            if (!data) return;
            NSString *str = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
            if (!str) return;
            NSURLSessionWebSocketMessage *wsMsg = [[NSURLSessionWebSocketMessage alloc] initWithString:str];
            [self.keyWSTask  sendMessage:wsMsg completionHandler:^(NSError *e) {}];
            [self.maintWSTask sendMessage:wsMsg completionHandler:^(NSError *e) {}];
        }];
    });
}

@end
