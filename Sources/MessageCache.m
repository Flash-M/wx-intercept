/**
 * MessageCache.m
 * wx-intercept — WeChat Mac Message Recall Interceptor
 *
 * Implementation of the thread-safe rolling message cache.
 */

#import "MessageCache.h"

// ---------------------------------------------------------------------------
// WeChat message type constants (m_nMsgType / msgType)
// ---------------------------------------------------------------------------
typedef NS_ENUM(NSInteger, WXMsgType) {
    WXMsgTypeText          = 1,
    WXMsgTypeImage         = 3,
    WXMsgTypeVoice         = 34,
    WXMsgTypeVideo         = 43,
    WXMsgTypeEmoticon      = 47,
    WXMsgTypeLocation      = 48,
    WXMsgTypeApp           = 49,   // file / link / mini-program
    WXMsgTypeMicroVideo    = 62,
    WXMsgTypeVoip          = 50,
    WXMsgTypeSystem        = 10000,
    WXMsgTypeRevoke        = 10002,
};

// Keys tried in order when looking up a property via KVC
static NSArray<NSString *> *kMsgIdKeys(void) {
    return @[@"m_nMsgId", @"msgId", @"messageId", @"localId",
             @"m_nMsgLocalID", @"m_nLocalID"];
}

static NSArray<NSString *> *kSvrIdKeys(void) {
    return @[@"m_nMsgSvrId", @"msgSvrId", @"serverMessageId", @"m_n64MsgId"];
}

static NSArray<NSString *> *kRevokeIdKeys(void) {
    return @[@"m_nRevokedMsgId", @"revokedMsgId", @"msgId",
             @"m_nMsgLocalID", @"newMsgLocalID", @"m_nNewMsgLocalID",
             @"m_nSvrId", @"svrId"];
}

static NSArray<NSString *> *kContentKeys(void) {
    return @[@"m_nsContent", @"content", @"messageContent", @"strContent"];
}

static NSArray<NSString *> *kMsgTypeKeys(void) {
    return @[@"m_nMsgType", @"msgType", @"messageType", @"type"];
}

static NSArray<NSString *> *kSenderKeys(void) {
    return @[@"m_nsFromUsr", @"fromUser", @"fromUserName", @"senderUserName",
             @"m_nsSenderUsr"];
}

// ---------------------------------------------------------------------------

@implementation MessageCache {
    // Maps msgId (NSString) → WeChat message object (id)
    NSMutableDictionary<NSString *, id> *_cache;
    // Insertion-order queue so we can evict oldest entries
    NSMutableArray<NSString *>          *_order;
    dispatch_queue_t                     _queue;
}

+ (instancetype)sharedCache {
    static MessageCache *instance;
    static dispatch_once_t token;
    dispatch_once(&token, ^{ instance = [[MessageCache alloc] init]; });
    return instance;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _cache = [NSMutableDictionary dictionaryWithCapacity:256];
        _order = [NSMutableArray arrayWithCapacity:256];
        _queue = dispatch_queue_create("com.wxintercept.cache",
                                       DISPATCH_QUEUE_SERIAL);
    }
    return self;
}

// ---------------------------------------------------------------------------
#pragma mark - Public interface
// ---------------------------------------------------------------------------

- (void)cacheMessage:(id)message {
    if (!message) return;
    NSString *msgId = [MessageCache msgIdFromMessage:message];
    if (!msgId) return;

    dispatch_async(_queue, ^{
        // Overwrite if already present (update)
        if (!self->_cache[msgId]) {
            [self->_order addObject:msgId];
        }
        self->_cache[msgId] = message;

        // Evict oldest entries when limit is reached
        while (self->_order.count > kWXIMaxCacheTotal) {
            NSString *oldest = self->_order.firstObject;
            [self->_order removeObjectAtIndex:0];
            [self->_cache removeObjectForKey:oldest];
        }
    });
}

- (nullable id)messageWithId:(NSString *)msgId {
    if (!msgId) return nil;
    __block id result;
    dispatch_sync(_queue, ^{
        result = self->_cache[msgId];
    });
    return result;
}

- (void)removeMessageWithId:(NSString *)msgId {
    if (!msgId) return;
    dispatch_async(_queue, ^{
        [self->_cache removeObjectForKey:msgId];
        [self->_order removeObject:msgId];
    });
}

// ---------------------------------------------------------------------------
#pragma mark - KVC helpers (class methods so WxIntercept.m can use them)
// ---------------------------------------------------------------------------

/// Safely read a KVC key from an object; returns nil on exception.
static id safeValueForKey(id obj, NSString *key) {
    @try { return [obj valueForKey:key]; }
    @catch (...) { return nil; }
}

/// Try a list of candidate keys; return the first non-nil value as NSString.
static NSString *firstStringValue(id obj, NSArray<NSString *> *keys) {
    for (NSString *key in keys) {
        id v = safeValueForKey(obj, key);
        if (v) return [NSString stringWithFormat:@"%@", v];
    }
    return nil;
}

+ (nullable NSString *)msgIdFromMessage:(id)message {
    if (!message) return nil;
    // Prefer local ID; fall back to server ID
    NSString *local = firstStringValue(message, kMsgIdKeys());
    if (local && ![local isEqualToString:@"0"]) return local;
    return firstStringValue(message, kSvrIdKeys());
}

+ (nullable NSString *)msgIdFromRevokeInfo:(id)revokeInfo {
    if (!revokeInfo) return nil;
    return firstStringValue(revokeInfo, kRevokeIdKeys());
}

+ (nullable NSString *)senderFromMessage:(id)message {
    return firstStringValue(message, kSenderKeys());
}

+ (NSString *)contentStringFromMessage:(id)message {
    if (!message) return @"[消息]";

    // Determine message type
    NSInteger msgType = WXMsgTypeText;
    NSString *typeStr = firstStringValue(message, kMsgTypeKeys());
    if (typeStr) msgType = typeStr.integerValue;

    switch (msgType) {
        case WXMsgTypeText: {
            NSString *text = firstStringValue(message, kContentKeys());
            return text.length ? text : @"[文本消息]";
        }
        case WXMsgTypeImage:      return @"[图片]";
        case WXMsgTypeVoice:      return @"[语音]";
        case WXMsgTypeVideo:      return @"[视频]";
        case WXMsgTypeEmoticon:   return @"[表情]";
        case WXMsgTypeLocation:   return @"[位置]";
        case WXMsgTypeMicroVideo: return @"[小视频]";
        case WXMsgTypeVoip:       return @"[通话]";
        case WXMsgTypeApp: {
            // App messages embed an XML payload; try to extract a title
            NSString *xml = firstStringValue(message, kContentKeys());
            if (xml) {
                NSRange r = [xml rangeOfString:@"<title>"];
                NSRange e = [xml rangeOfString:@"</title>"];
                if (r.location != NSNotFound && e.location != NSNotFound
                    && e.location > r.location) {
                    NSUInteger s = r.location + r.length;
                    return [xml substringWithRange:NSMakeRange(s, e.location - s)];
                }
            }
            return @"[文件/链接]";
        }
        default: {
            NSString *text = firstStringValue(message, kContentKeys());
            return text.length ? text : @"[消息]";
        }
    }
}

@end
