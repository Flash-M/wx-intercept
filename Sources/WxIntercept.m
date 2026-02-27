/**
 * WxIntercept.m
 * wx-intercept — WeChat Mac Message Recall Interceptor
 */

#import <Foundation/Foundation.h>
#import <AppKit/AppKit.h>
#import <UserNotifications/UserNotifications.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <dispatch/dispatch.h>
#import <fcntl.h>
#import <unistd.h>
#import <mach-o/dyld.h>

#import "fishhook.h"

#define WXILog(fmt, ...) NSLog(@"[WxIntercept] " fmt, ##__VA_ARGS__)
#define WXIDebug(fmt, ...) do { if (sDebugEnabled) NSLog(@"[WxIntercept:DBG] " fmt, ##__VA_ARGS__); } while(0)

static BOOL sInitialized = NO;
static BOOL sDebugEnabled = YES;    // Enable verbose logging for debugging
static NSString *sLogPath = nil;
static NSMutableDictionary<NSString *, NSString *> *sMsgContentCache = nil;
static NSMutableArray<NSString *> *sMsgContentOrder = nil;
static dispatch_queue_t sCacheQueue = nil;
static const NSUInteger kMaxCacheSize = 5000;

static void showNotification(NSString *sender, NSString *content);
static void scanBufferForRevoke(const void *buf, int len, const char *source);
static void scanBufferForMessage(const void *buf, int len, const char *source);
static NSString *extractXMLTag(NSString *xml, NSString *tag);
static void writeLogToFile(NSString *entry);

// Check if we're being loaded multiple times (due to duplicate LC_LOAD_DYLIB)
static BOOL isAlreadyLoaded(void) {
    static dispatch_once_t onceToken;
    static BOOL loaded = NO;
    dispatch_once(&onceToken, ^{
        loaded = YES;
    });
    // If dispatch_once didn't run (already ran before), we're duplicate
    return !loaded;
}

static void writeLogToFile(NSString *entry) {
    if (!sLogPath) {
        sLogPath = [NSTemporaryDirectory() stringByAppendingPathComponent:@"wxintercept_ipc.log"];
        // Clear old log on fresh start
        [@"" writeToFile:sLogPath atomically:YES encoding:NSUTF8StringEncoding error:nil];
    }
    NSString *line = [NSString stringWithFormat:@"%@ %@\n", [NSDate date], entry ?: @""];
    NSFileHandle *fh = [NSFileHandle fileHandleForWritingAtPath:sLogPath];
    if (fh) {
        [fh seekToEndOfFile];
        [fh writeData:[line dataUsingEncoding:NSUTF8StringEncoding]];
        [fh closeFile];
    } else {
        [line writeToFile:sLogPath atomically:YES encoding:NSUTF8StringEncoding error:nil];
    }
}

static NSString *extractXMLTag(NSString *xml, NSString *tag) {
    if (!xml || !tag) return nil;
    NSString *open = [NSString stringWithFormat:@"<%@>", tag];
    NSString *close = [NSString stringWithFormat:@"</%@>", tag];
    NSRange r1 = [xml rangeOfString:open];
    if (r1.location == NSNotFound) return nil;
    NSUInteger start = r1.location + r1.length;
    if (start >= xml.length) return nil;
    NSRange r2 = [xml rangeOfString:close options:0 range:NSMakeRange(start, xml.length - start)];
    if (r2.location == NSNotFound) return nil;
    return [xml substringWithRange:NSMakeRange(start, r2.location - start)];
}

static void cacheMessageContent(NSString *msgSvrId, NSString *content) {
    if (!msgSvrId || !content) return;
    WXIDebug(@"Caching msg id=%@ len=%lu", msgSvrId, (unsigned long)content.length);
    dispatch_async(sCacheQueue, ^{
        if (!sMsgContentCache[msgSvrId]) {
            [sMsgContentOrder addObject:msgSvrId];
        }
        sMsgContentCache[msgSvrId] = content;
        while (sMsgContentOrder.count > kMaxCacheSize) {
            NSString *oldest = sMsgContentOrder.firstObject;
            [sMsgContentOrder removeObjectAtIndex:0];
            [sMsgContentCache removeObjectForKey:oldest];
        }
    });
}

static NSString *lookupCachedContent(NSString *msgSvrId) {
    if (!msgSvrId) return nil;
    __block NSString *result = nil;
    dispatch_sync(sCacheQueue, ^{
        result = sMsgContentCache[msgSvrId];
    });
    return result;
}

static void scanBufferForMessage(const void *buf, int len, const char *source) {
    if (!buf || len < 20) return;

    NSString *str = [[NSString alloc] initWithBytes:buf length:(NSUInteger)len encoding:NSUTF8StringEncoding];
    if (!str) {
        str = [[NSString alloc] initWithBytes:buf length:(NSUInteger)len encoding:NSISOLatin1StringEncoding];
    }
    if (!str) return;

    // Log first 200 chars for debugging
    NSString *preview = str.length > 200 ? [str substringToIndex:200] : str;
    WXIDebug(@"[%s] scanMsg len=%d preview=%@", source, len, preview);

    NSString *msgId = extractXMLTag(str, @"MsgSvrID");
    if (!msgId) msgId = extractXMLTag(str, @"NewMsgId");
    if (!msgId) msgId = extractXMLTag(str, @"newmsgid");
    if (!msgId) msgId = extractXMLTag(str, @"msgsvrid");

    NSString *msgContent = extractXMLTag(str, @"Content");
    if (!msgContent) msgContent = extractXMLTag(str, @"content");
    if (!msgContent) msgContent = extractXMLTag(str, @"msg");

    if (msgId && msgContent) {
        cacheMessageContent(msgId, msgContent);
    }
}

// Search for revoke patterns - enhanced for WeChat 4.x
static void scanBufferForRevoke(const void *buf, int len, const char *source) {
    if (!buf || len <= 0) return;

    const uint8_t *bytes = (const uint8_t *)buf;
    
    // Convert to string first for pattern matching
    NSData *nsdata = [NSData dataWithBytes:buf length:len];
    NSString *str = [[NSString alloc] initWithData:nsdata encoding:NSUTF8StringEncoding];
    if (!str) str = [[NSString alloc] initWithData:nsdata encoding:NSISOLatin1StringEncoding];
    
    // Check for various revoke-related patterns
    BOOL found = NO;
    NSString *matchedPattern = nil;
    
    // English patterns
    NSArray *patterns = @[@"revokemsg", @"revoke", @"recall", @"withdraw", @"RevokeMsg", @"sysmsg"];
    for (NSString *pattern in patterns) {
        if (str && [str containsString:pattern]) {
            found = YES;
            matchedPattern = pattern;
            break;
        }
    }
    
    // Chinese patterns (撤回)
    if (!found && str) {
        const char *chehuiUTF8 = "\xe6\x92\xa4\xe5\x9b\x9e";  // 撤回 in UTF-8
        if (memmem(bytes, len, chehuiUTF8, 6)) {
            found = YES;
            matchedPattern = @"撤回";
        }
    }
    
    // Also check for binary patterns (protobuf type field for revoke might use specific values)
    // Look for patterns that might indicate a revoke message type
    if (!found && len > 10) {
        // Check for message type indicators (10000-10002 are system message types)
        NSString *numStr = str;
        if (numStr && ([numStr containsString:@"10000"] || [numStr containsString:@"10001"] || 
                       [numStr containsString:@"10002"] || [numStr containsString:@"msgtype\":10"])) {
            writeLogToFile([NSString stringWithFormat:@"[%s] SYSMSG_TYPE detected, len=%d sample=%@", 
                          source, len, [str substringToIndex:MIN(300, str.length)]]);
        }
    }
    
    if (!found) return;
    
    writeLogToFile([NSString stringWithFormat:@"[%s] REVOKE_PATTERN '%@' found, len=%d content=%@", 
                  source, matchedPattern, len, str ? [str substringToIndex:MIN(500, str.length)] : @"[binary]"]);
    
    // Original XML parsing logic - look for "revokemsg"
    static const uint8_t sig[] = "revokemsg";

    int revokeOffset = -1;
    for (int i = 0; i <= len - 9; i++) {
        if (memcmp(bytes + i, sig, 9) == 0) {
            revokeOffset = i;
            break;
        }
    }
    
    // If "revokemsg" not found but we detected other patterns, show generic notification
    if (revokeOffset < 0) {
        if ([matchedPattern isEqualToString:@"撤回"] || [matchedPattern isEqualToString:@"recall"]) {
            showNotification(@"有人", str ? [str substringToIndex:MIN(100, str.length)] : @"撤回了一条消息");
        }
        return;
    }

    int rootStart = revokeOffset;
    for (int i = revokeOffset; i >= 0 && i > revokeOffset - 2000; i--) {
        if (bytes[i] == '<' && i + 7 < len && memcmp(bytes + i, "<sysmsg", 7) == 0) {
            rootStart = i;
            break;
        }
    }

    int xmlEnd = revokeOffset + 9;
    for (int i = xmlEnd; i < len - 9; i++) {
        if (memcmp(bytes + i, "</sysmsg>", 9) == 0) {
            xmlEnd = i + 9;
            break;
        }
    }
    if (xmlEnd > len) xmlEnd = len;

    int xmlLen = xmlEnd - rootStart;
    if (xmlLen <= 0 || xmlLen > 12000) xmlLen = MIN(2500, len - rootStart);
    if (xmlLen <= 0) return;

    NSString *xml = [[NSString alloc] initWithBytes:bytes + rootStart
                                             length:(NSUInteger)xmlLen
                                           encoding:NSUTF8StringEncoding];
    if (!xml) {
        xml = [[NSString alloc] initWithBytes:bytes + rootStart
                                       length:(NSUInteger)xmlLen
                                     encoding:NSISOLatin1StringEncoding];
    }

    WXILog(@"[%s] revoke detected len=%d", source, xmlLen);
    if (xml) {
        writeLogToFile([NSString stringWithFormat:@"[%s] REVOKE XML:\n%@", source, xml]);
    }

    NSString *sender = nil;
    NSString *content = nil;
    NSString *replaceMsg = xml ? extractXMLTag(xml, @"replacemsg") : nil;

    if (replaceMsg) {
        NSRange quoteStart = [replaceMsg rangeOfString:@"\""];
        if (quoteStart.location != NSNotFound) {
            NSRange quoteEnd = [replaceMsg rangeOfString:@"\""
                                                 options:0
                                                   range:NSMakeRange(quoteStart.location + 1,
                                                                      replaceMsg.length - quoteStart.location - 1)];
            if (quoteEnd.location != NSNotFound) {
                sender = [replaceMsg substringWithRange:NSMakeRange(quoteStart.location + 1,
                                                                    quoteEnd.location - quoteStart.location - 1)];
            }
        }
    }

    if (!sender && xml) sender = extractXMLTag(xml, @"session");

    NSString *msgSvrId = nil;
    if (xml) {
        msgSvrId = extractXMLTag(xml, @"newmsgid");
        if (!msgSvrId) msgSvrId = extractXMLTag(xml, @"msgid");
    }

    if (msgSvrId) content = lookupCachedContent(msgSvrId);
    if (!content) content = replaceMsg;

    showNotification(sender, content);
}

// Mojo symbols
typedef const void *(*GetMMMojoReadInfo_fn)(void *readInfo, int *outLen);

static GetMMMojoReadInfo_fn orig_GetMMMojoReadInfoRequest = NULL;
static GetMMMojoReadInfo_fn orig_GetMMMojoReadInfoAttach = NULL;
static GetMMMojoReadInfo_fn orig_GetMMMojoReadInfoSync = NULL;

static const void *hooked_GetMMMojoReadInfoRequest(void *readInfo, int *outLen) {
    // Safety check - don't process NULL readInfo
    if (!readInfo || !orig_GetMMMojoReadInfoRequest) {
        return orig_GetMMMojoReadInfoRequest ? orig_GetMMMojoReadInfoRequest(readInfo, outLen) : NULL;
    }
    
    const void *data = orig_GetMMMojoReadInfoRequest(readInfo, outLen);
    int len = (data && outLen) ? *outLen : 0;
    
    // Log ALL calls with any data for debugging
    static int callCount = 0;
    callCount++;
    if (callCount <= 50) {
        WXILog(@"ReadRequest #%d: data=%p len=%d", callCount, data, len);
    }
    
    if (len > 0) {  // Log ALL data
        static int logCount = 0;
        if (logCount < 200) {
            logCount++;
            NSData *nsdata = [NSData dataWithBytes:data length:MIN(len, 500)];
            NSString *hex = [nsdata description];
            NSString *sample = [[NSString alloc] initWithBytes:data length:MIN(len, 200) encoding:NSUTF8StringEncoding];
            if (!sample) sample = @"[binary]";
            writeLogToFile([NSString stringWithFormat:@"[ReadReq] len=%d hex=%@ str=%@", len, hex, sample]);
        }
    }
    if (data && len > 0) {
        scanBufferForRevoke(data, len, "ReadRequest");
        scanBufferForMessage(data, len, "ReadRequest");
    }
    return data;
}

static const void *hooked_GetMMMojoReadInfoAttach(void *readInfo, int *outLen) {
    // Safety check - don't process NULL readInfo
    if (!readInfo || !orig_GetMMMojoReadInfoAttach) {
        return orig_GetMMMojoReadInfoAttach ? orig_GetMMMojoReadInfoAttach(readInfo, outLen) : NULL;
    }
    
    const void *data = orig_GetMMMojoReadInfoAttach(readInfo, outLen);
    int len = (data && outLen) ? *outLen : 0;
    if (len > 50) {  // Only log meaningful data
        static int logCount = 0;
        if (logCount < 100) {
            logCount++;
            NSData *nsdata = [NSData dataWithBytes:data length:MIN(len, 500)];
            NSString *hex = [nsdata description];
            NSString *sample = [[NSString alloc] initWithBytes:data length:MIN(len, 200) encoding:NSUTF8StringEncoding];
            if (!sample) sample = @"[binary]";
            writeLogToFile([NSString stringWithFormat:@"[ReadAttach] len=%d hex=%@ str=%@", len, hex, sample]);
        }
    }
    if (data && len > 0) {
        scanBufferForRevoke(data, len, "ReadAttach");
        scanBufferForMessage(data, len, "ReadAttach");
    }
    return data;
}

static const void *hooked_GetMMMojoReadInfoSync(void *readInfo, int *outLen) {
    // Safety check - don't process NULL readInfo
    if (!readInfo || !orig_GetMMMojoReadInfoSync) {
        return orig_GetMMMojoReadInfoSync ? orig_GetMMMojoReadInfoSync(readInfo, outLen) : NULL;
    }
    
    const void *data = orig_GetMMMojoReadInfoSync(readInfo, outLen);
    int len = (data && outLen) ? *outLen : 0;
    if (len > 50) {  // Only log meaningful data
        static int logCount = 0;
        if (logCount < 100) {
            logCount++;
            NSData *nsdata = [NSData dataWithBytes:data length:MIN(len, 500)];
            NSString *hex = [nsdata description];
            NSString *sample = [[NSString alloc] initWithBytes:data length:MIN(len, 200) encoding:NSUTF8StringEncoding];
            if (!sample) sample = @"[binary]";
            writeLogToFile([NSString stringWithFormat:@"[ReadSync] len=%d hex=%@ str=%@", len, hex, sample]);
        }
    }
    if (data && len > 0) {
        scanBufferForRevoke(data, len, "ReadSync");
        scanBufferForMessage(data, len, "ReadSync");
    }
    return data;
}

// Hook write info functions - DISABLED due to crashes
// The write functions seem to have different calling conventions that cause SIGSEGV
// We'll only hook read functions which work reliably

static void hookMojoIPC(void) {
    // Only hook Read functions - Write hooks cause crashes
    struct rebinding rebindings[] = {
        {"GetMMMojoReadInfoRequest", (void *)hooked_GetMMMojoReadInfoRequest, (void **)&orig_GetMMMojoReadInfoRequest},
        {"GetMMMojoReadInfoAttach",  (void *)hooked_GetMMMojoReadInfoAttach,  (void **)&orig_GetMMMojoReadInfoAttach},
        {"GetMMMojoReadInfoSync",    (void *)hooked_GetMMMojoReadInfoSync,    (void **)&orig_GetMMMojoReadInfoSync},
    };

    int rc = rebind_symbols(rebindings, sizeof(rebindings) / sizeof(rebindings[0]));
    WXILog(@"Mojo hook result=%d reqR=%p attachR=%p syncR=%p",
           rc,
           orig_GetMMMojoReadInfoRequest,
           orig_GetMMMojoReadInfoAttach,
           orig_GetMMMojoReadInfoSync);
}

// ========== ilink2.framework Hooks (Dart FFI) ==========

// Original function pointers
typedef void (*DartCloudSession_receiveCloudNotify_fn)(void *session, void *notify, int notifyLen);
typedef void (*DartNetworkManager_subscribeNotify_fn)(void *manager, void *callback, void *context);
typedef void (*DartNetworkManager_subscribeSyncMessage_fn)(void *manager, void *callback, void *context);

static DartCloudSession_receiveCloudNotify_fn orig_receiveCloudNotify = NULL;
static DartNetworkManager_subscribeNotify_fn orig_subscribeNotify = NULL;
static DartNetworkManager_subscribeSyncMessage_fn orig_subscribeSyncMessage = NULL;

// Hooked: DartCloudSession_receiveCloudNotify
static void hooked_receiveCloudNotify(void *session, void *notify, int notifyLen) {
    WXILog(@"[ilink2] receiveCloudNotify: session=%p notify=%p len=%d", session, notify, notifyLen);
    
    if (notify && notifyLen > 0) {
        // Log notify data for analysis
        NSData *data = [NSData dataWithBytes:notify length:MIN(notifyLen, 1000)];
        NSString *hexStr = [data description];
        NSString *strContent = [[NSString alloc] initWithBytes:notify length:MIN(notifyLen, 500) encoding:NSUTF8StringEncoding];
        
        writeLogToFile([NSString stringWithFormat:@"[ilink2:CloudNotify] len=%d hex=%@", notifyLen, hexStr]);
        if (strContent) {
            writeLogToFile([NSString stringWithFormat:@"[ilink2:CloudNotify] str=%@", strContent]);
        }
        
        // Check for revoke patterns
        if (strContent) {
            if ([strContent containsString:@"revoke"] || [strContent containsString:@"recall"] ||
                [strContent containsString:@"撤回"] || [strContent containsString:@"sysmsg"]) {
                WXILog(@"[ilink2] ⚠️ Revoke pattern detected in CloudNotify!");
                writeLogToFile([NSString stringWithFormat:@"[ilink2:REVOKE] %@", strContent]);
                showNotification(@"检测到撤回", [strContent substringToIndex:MIN(100, strContent.length)]);
            }
        }
    }
    
    // Call original
    if (orig_receiveCloudNotify) {
        orig_receiveCloudNotify(session, notify, notifyLen);
    }
}

// Hooked: DartNetworkManager_subscribeNotify
static void hooked_subscribeNotify(void *manager, void *callback, void *context) {
    WXILog(@"[ilink2] subscribeNotify: manager=%p callback=%p context=%p", manager, callback, context);
    writeLogToFile([NSString stringWithFormat:@"[ilink2:subscribeNotify] manager=%p", manager]);
    
    if (orig_subscribeNotify) {
        orig_subscribeNotify(manager, callback, context);
    }
}

// Hooked: DartNetworkManager_subscribeSyncMessage
static void hooked_subscribeSyncMessage(void *manager, void *callback, void *context) {
    WXILog(@"[ilink2] subscribeSyncMessage: manager=%p callback=%p context=%p", manager, callback, context);
    writeLogToFile([NSString stringWithFormat:@"[ilink2:subscribeSyncMessage] manager=%p", manager]);
    
    if (orig_subscribeSyncMessage) {
        orig_subscribeSyncMessage(manager, callback, context);
    }
}

static void hookIlink2(void) {
    WXILog(@"Attempting to hook ilink2.framework...");
    
    // Note: Symbol names in fishhook don't need underscore prefix
    struct rebinding ilink_rebindings[] = {
        {"_DartCloudSession_receiveCloudNotify", (void *)hooked_receiveCloudNotify, (void **)&orig_receiveCloudNotify},
        {"_DartNetworkManager_subscribeNotify", (void *)hooked_subscribeNotify, (void **)&orig_subscribeNotify},
        {"_DartNetworkManager_subscribeSyncMessage", (void *)hooked_subscribeSyncMessage, (void **)&orig_subscribeSyncMessage},
    };
    
    int rc = rebind_symbols(ilink_rebindings, sizeof(ilink_rebindings) / sizeof(ilink_rebindings[0]));
    WXILog(@"ilink2 hook (with underscore) result=%d cloudNotify=%p subNotify=%p subSync=%p",
           rc,
           orig_receiveCloudNotify,
           orig_subscribeNotify,
           orig_subscribeSyncMessage);
    
    // Try without underscore prefix as well
    if (!orig_receiveCloudNotify) {
        struct rebinding ilink_rebindings2[] = {
            {"DartCloudSession_receiveCloudNotify", (void *)hooked_receiveCloudNotify, (void **)&orig_receiveCloudNotify},
            {"DartNetworkManager_subscribeNotify", (void *)hooked_subscribeNotify, (void **)&orig_subscribeNotify},
            {"DartNetworkManager_subscribeSyncMessage", (void *)hooked_subscribeSyncMessage, (void **)&orig_subscribeSyncMessage},
        };
        
        rc = rebind_symbols(ilink_rebindings2, sizeof(ilink_rebindings2) / sizeof(ilink_rebindings2[0]));
        WXILog(@"ilink2 hook (no underscore) result=%d cloudNotify=%p subNotify=%p subSync=%p",
               rc,
               orig_receiveCloudNotify,
               orig_subscribeNotify,
               orig_subscribeSyncMessage);
    }
}

// ========== Method Swizzling for ObjC message classes ==========

static IMP sOrigOnAddMsg = NULL;
static IMP sOrigOnRevokeMsg = NULL;
static IMP sOrigOnSyncBatchAddMsg = NULL;

// Swizzled implementation for onAddMsg:MgrType: or similar
static void swizzled_onAddMsg(id self, SEL _cmd, id msgData, unsigned long mgrType) {
    // Call original first
    if (sOrigOnAddMsg) {
        ((void(*)(id, SEL, id, unsigned long))sOrigOnAddMsg)(self, _cmd, msgData, mgrType);
    }
    
    // Try to extract message content
    @try {
        if (!msgData) return;
        
        NSString *msgIdStr = nil;
        NSString *content = nil;
        
        // Try different property names
        if ([msgData respondsToSelector:@selector(m_uiMesLocalID)]) {
            msgIdStr = [NSString stringWithFormat:@"%llu", (unsigned long long)[msgData performSelector:@selector(m_uiMesLocalID)]];
        } else if ([msgData respondsToSelector:@selector(m_ui64MesSvrID)]) {
            msgIdStr = [NSString stringWithFormat:@"%llu", (unsigned long long)[msgData performSelector:@selector(m_ui64MesSvrID)]];
        } else if ([msgData respondsToSelector:@selector(mesLocalID)]) {
            msgIdStr = [NSString stringWithFormat:@"%llu", (unsigned long long)[msgData performSelector:@selector(mesLocalID)]];
        } else if ([msgData respondsToSelector:@selector(mesSvrID)]) {
            msgIdStr = [NSString stringWithFormat:@"%llu", (unsigned long long)[msgData performSelector:@selector(mesSvrID)]];
        }
        
        if ([msgData respondsToSelector:@selector(m_nsContent)]) {
            content = [msgData performSelector:@selector(m_nsContent)];
        } else if ([msgData respondsToSelector:@selector(content)]) {
            content = [msgData performSelector:@selector(content)];
        } else if ([msgData respondsToSelector:@selector(msgContent)]) {
            content = [msgData performSelector:@selector(msgContent)];
        }
        
        if (msgIdStr.length > 0 && content.length > 0) {
            WXIDebug(@"[ObjC] Cached msg id=%@ len=%lu", msgIdStr, (unsigned long)content.length);
            cacheMessageContent(msgIdStr, content);
        }
    } @catch (NSException *e) {
        WXIDebug(@"[ObjC] onAddMsg exception: %@", e);
    }
}

// Swizzled implementation for onRevokeMsg:
static void swizzled_onRevokeMsg(id self, SEL _cmd, id msgData) {
    WXILog(@"[ObjC] onRevokeMsg called! msgData=%@", msgData);
    
    @try {
        NSString *sender = nil;
        NSString *msgIdStr = nil;
        NSString *content = nil;
        
        if (msgData) {
            // Try to get sender
            if ([msgData respondsToSelector:@selector(m_nsFromUsr)]) {
                sender = [msgData performSelector:@selector(m_nsFromUsr)];
            } else if ([msgData respondsToSelector:@selector(fromUsr)]) {
                sender = [msgData performSelector:@selector(fromUsr)];
            } else if ([msgData respondsToSelector:@selector(m_nsToUsr)]) {
                sender = [msgData performSelector:@selector(m_nsToUsr)];
            }
            
            // Try to get message ID
            if ([msgData respondsToSelector:@selector(m_uiMesLocalID)]) {
                msgIdStr = [NSString stringWithFormat:@"%llu", (unsigned long long)[msgData performSelector:@selector(m_uiMesLocalID)]];
            } else if ([msgData respondsToSelector:@selector(m_ui64MesSvrID)]) {
                msgIdStr = [NSString stringWithFormat:@"%llu", (unsigned long long)[msgData performSelector:@selector(m_ui64MesSvrID)]];
            } else if ([msgData respondsToSelector:@selector(mesSvrID)]) {
                msgIdStr = [NSString stringWithFormat:@"%llu", (unsigned long long)[msgData performSelector:@selector(mesSvrID)]];
            }
            
            // Try to get content directly
            if ([msgData respondsToSelector:@selector(m_nsContent)]) {
                content = [msgData performSelector:@selector(m_nsContent)];
            } else if ([msgData respondsToSelector:@selector(content)]) {
                content = [msgData performSelector:@selector(content)];
            }
            
            // Fallback to cache
            if (!content && msgIdStr) {
                content = lookupCachedContent(msgIdStr);
            }
        }
        
        WXILog(@"[ObjC] Revoke: sender=%@ msgId=%@ content=%@", sender, msgIdStr, content);
        showNotification(sender, content);
        
    } @catch (NSException *e) {
        WXILog(@"[ObjC] onRevokeMsg exception: %@", e);
        showNotification(nil, @"[检测到撤回消息]");
    }
    
    // Call original
    if (sOrigOnRevokeMsg) {
        ((void(*)(id, SEL, id))sOrigOnRevokeMsg)(self, _cmd, msgData);
    }
}

// Swizzled for FFProcessRevokeMsg
static void swizzled_FFProcessRevokeMsg(id self, SEL _cmd, id msgData) {
    WXILog(@"[ObjC] FFProcessRevokeMsg called!");
    showNotification(nil, @"[FFProcessRevokeMsg 撤回检测]");
    
    if (sOrigOnRevokeMsg) {
        ((void(*)(id, SEL, id))sOrigOnRevokeMsg)(self, _cmd, msgData);
    }
}

static BOOL swizzleMethod(Class cls, SEL originalSel, IMP newImp, IMP *origImpOut) {
    if (!cls) return NO;
    
    Method method = class_getInstanceMethod(cls, originalSel);
    if (!method) return NO;
    
    *origImpOut = method_setImplementation(method, newImp);
    return YES;
}

static void hookObjCMessageClasses(void) {
    WXILog(@"Attempting ObjC method swizzling...");
    
    // List of possible class names for message handling
    NSArray *classNames = @[
        @"MessageService",
        @"CMessageMgr", 
        @"MMMessageMgr",
        @"MMMsgService",
        @"FFIMMessageMgr",
        @"WCMessageService"
    ];
    
    // Try to find and hook onRevokeMsg:
    SEL revokeSelectors[] = {
        @selector(onRevokeMsg:),
        NSSelectorFromString(@"OnRevokeMsg:"),
        NSSelectorFromString(@"processRevokeMsg:"),
        NSSelectorFromString(@"handleRevokeMsg:"),
        NSSelectorFromString(@"FFProcessRevokeMsg:"),
        NSSelectorFromString(@"onRevokeMsgWrap:"),
    };
    
    BOOL foundRevoke = NO;
    for (NSString *className in classNames) {
        Class cls = NSClassFromString(className);
        if (!cls) continue;
        
        WXILog(@"Found class: %@", className);
        
        // Try each revoke selector
        for (int i = 0; i < sizeof(revokeSelectors)/sizeof(revokeSelectors[0]); i++) {
            SEL sel = revokeSelectors[i];
            if (swizzleMethod(cls, sel, (IMP)swizzled_onRevokeMsg, &sOrigOnRevokeMsg)) {
                WXILog(@"  -> Hooked %@::%@", className, NSStringFromSelector(sel));
                foundRevoke = YES;
                break;
            }
        }
        
        // Hook onAddMsg variants
        SEL addMsgSelectors[] = {
            @selector(onAddMsg:MgrType:),
            NSSelectorFromString(@"OnAddMsg:MgrType:"),
            NSSelectorFromString(@"onAddMsg:msgType:"),
            NSSelectorFromString(@"FFProcessNewMsg:MgrType:"),
        };
        
        for (int i = 0; i < sizeof(addMsgSelectors)/sizeof(addMsgSelectors[0]); i++) {
            if (swizzleMethod(cls, addMsgSelectors[i], (IMP)swizzled_onAddMsg, &sOrigOnAddMsg)) {
                WXILog(@"  -> Hooked %@::%@", className, NSStringFromSelector(addMsgSelectors[i]));
                break;
            }
        }
        
        if (foundRevoke) break;
    }
    
    if (!foundRevoke) {
        WXILog(@"Warning: Could not find any ObjC revoke method to hook");
        
        // Dump all Message-related classes to a file for analysis
        // Use a path that works regardless of sandbox
        NSString *classLogPath = @"/tmp/wxintercept_classes.log";
        // Fallback to home directory if /tmp fails
        if (![[NSFileManager defaultManager] isWritableFileAtPath:@"/tmp"]) {
            classLogPath = [NSHomeDirectory() stringByAppendingPathComponent:@"wxintercept_classes.log"];
        }
        
        NSMutableString *classLog = [NSMutableString stringWithString:@"=== WeChat Classes ===\n"];
        
        unsigned int classCount = 0;
        Class *classes = objc_copyClassList(&classCount);
        [classLog appendFormat:@"Total classes: %u\n\n", classCount];
        
        for (unsigned int i = 0; i < classCount; i++) {
            NSString *name = NSStringFromClass(classes[i]);
            if ([name containsString:@"Message"] || [name containsString:@"Msg"] || 
                [name containsString:@"Revoke"] || [name containsString:@"Chat"] ||
                [name containsString:@"Session"] || [name containsString:@"Service"]) {
                if (![name hasPrefix:@"NS"] && ![name hasPrefix:@"_"] && ![name hasPrefix:@"OS"]) {
                    [classLog appendFormat:@"  %@\n", name];
                    
                    // Also dump methods for promising classes
                    if ([name containsString:@"Msg"] || [name containsString:@"Message"]) {
                        Class cls = classes[i];
                        unsigned int methodCount = 0;
                        Method *methods = class_copyMethodList(cls, &methodCount);
                        for (unsigned int j = 0; j < methodCount && j < 100; j++) {
                            SEL sel = method_getName(methods[j]);
                            NSString *methodName = NSStringFromSelector(sel);
                            if ([methodName containsString:@"evoke"] || [methodName containsString:@"Add"] ||
                                [methodName containsString:@"Recv"] || [methodName containsString:@"recv"]) {
                                [classLog appendFormat:@"      -> %@\n", methodName];
                            }
                        }
                        if (methods) free(methods);
                    }
                }
            }
        }
        free(classes);
        
        NSError *error = nil;
        BOOL written = [classLog writeToFile:classLogPath atomically:YES encoding:NSUTF8StringEncoding error:&error];
        if (written) {
            WXILog(@"Class dump saved to: %@", classLogPath);
        } else {
            WXILog(@"Failed to write class dump: %@", error);
            // Print to log as fallback
            WXILog(@"Class dump:\n%@", classLog);
        }
    }
}

static dispatch_source_t sRevokeDBWatcher = nil;

static NSString *findRevokeMsgDB(void) {
    NSString *container = [@"~/Library/Containers/com.tencent.xinWeChat/Data/Library/Application Support/com.tencent.xinWeChat"
                           stringByExpandingTildeInPath];
    NSFileManager *fm = [NSFileManager defaultManager];
    NSArray<NSString *> *versions = [fm contentsOfDirectoryAtPath:container error:nil];
    
    NSString *latestDB = nil;
    NSDate *latestDate = nil;
    
    for (NSString *ver in versions) {
        NSString *verPath = [container stringByAppendingPathComponent:ver];
        NSArray<NSString *> *hashes = [fm contentsOfDirectoryAtPath:verPath error:nil];
        for (NSString *hash in hashes) {
            NSString *db = [[verPath stringByAppendingPathComponent:hash] stringByAppendingPathComponent:@"RevokeMsg/revokemsg.db"];
            if ([fm fileExistsAtPath:db]) {
                NSDictionary *attrs = [fm attributesOfItemAtPath:db error:nil];
                NSDate *modDate = attrs[NSFileModificationDate];
                if (!latestDate || [modDate compare:latestDate] == NSOrderedDescending) {
                    latestDate = modDate;
                    latestDB = db;
                }
            }
        }
    }
    if (latestDB) {
        WXILog(@"Found revokemsg.db: %@", latestDB);
    }
    return latestDB;
}

static void monitorRevokeDB(void) {
    NSString *dbPath = findRevokeMsgDB();
    if (!dbPath) {
        WXILog(@"No revokemsg.db found, skipping DB monitoring");
        return;
    }

    int fd = open(dbPath.fileSystemRepresentation, O_EVTONLY);
    if (fd < 0) {
        WXILog(@"Failed to open revokemsg.db for monitoring");
        return;
    }
    
    WXILog(@"Monitoring revokemsg.db for changes");

    sRevokeDBWatcher = dispatch_source_create(DISPATCH_SOURCE_TYPE_VNODE,
                                              (uintptr_t)fd,
                                              DISPATCH_VNODE_WRITE | DISPATCH_VNODE_EXTEND | DISPATCH_VNODE_ATTRIB,
                                              dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0));

    dispatch_source_set_event_handler(sRevokeDBWatcher, ^{
        static NSTimeInterval last = 0;
        NSTimeInterval now = [NSDate date].timeIntervalSince1970;
        if (now - last > 2.0) {
            last = now;
            WXILog(@"revokemsg.db changed!");
            showNotification(nil, @"检测到消息撤回");
        }
    });

    dispatch_source_set_cancel_handler(sRevokeDBWatcher, ^{
        close(fd);
    });

    dispatch_resume(sRevokeDBWatcher);
}

static void showNotification(NSString *sender, NSString *content) {
    NSString *title = sender.length ? [NSString stringWithFormat:@"撤回消息 — %@", sender] : @"撤回消息";
    NSString *body = content.length ? content : @"[消息已被撤回]";

    Class centerCls = NSClassFromString(@"UNUserNotificationCenter");
    if (centerCls) {
        id center = ((id (*)(id, SEL))objc_msgSend)((id)centerCls, NSSelectorFromString(@"currentNotificationCenter"));
        if (center) {
            SEL reqSel = NSSelectorFromString(@"requestAuthorizationWithOptions:completionHandler:");
            if ([center respondsToSelector:reqSel]) {
                NSMethodSignature *sig = [center methodSignatureForSelector:reqSel];
                NSInvocation *inv = [NSInvocation invocationWithMethodSignature:sig];
                inv.target = center;
                inv.selector = reqSel;
                NSUInteger opts = (1 << 2) | (1 << 3);
                [inv setArgument:&opts atIndex:2];
                void (^cb)(BOOL, NSError *) = ^(BOOL granted, NSError *error) {};
                [inv setArgument:&cb atIndex:3];
                [inv invoke];
            }

            id notifContent = [NSClassFromString(@"UNMutableNotificationContent") new];
            [notifContent setValue:title forKey:@"title"];
            [notifContent setValue:body forKey:@"body"];

            id reqClass = NSClassFromString(@"UNNotificationRequest");
            SEL makeReqSel = NSSelectorFromString(@"requestWithIdentifier:content:trigger:");
            NSMethodSignature *rsig = [reqClass methodSignatureForSelector:makeReqSel];
            if (rsig) {
                NSInvocation *rinv = [NSInvocation invocationWithMethodSignature:rsig];
                rinv.target = reqClass;
                rinv.selector = makeReqSel;
                NSString *identifier = [NSString stringWithFormat:@"wxintercept.%f", [NSDate date].timeIntervalSince1970];
                id trigger = nil;
                [rinv setArgument:&identifier atIndex:2];
                [rinv setArgument:&notifContent atIndex:3];
                [rinv setArgument:&trigger atIndex:4];
                [rinv invoke];

                __unsafe_unretained id request = nil;
                [rinv getReturnValue:&request];
                if (request) {
                    SEL addSel = NSSelectorFromString(@"addNotificationRequest:withCompletionHandler:");
                    NSMethodSignature *asig = [center methodSignatureForSelector:addSel];
                    if (asig) {
                        NSInvocation *ainv = [NSInvocation invocationWithMethodSignature:asig];
                        ainv.target = center;
                        ainv.selector = addSel;
                        [ainv setArgument:&request atIndex:2];
                        id nilBlock = nil;
                        [ainv setArgument:&nilBlock atIndex:3];
                        [ainv invoke];
                        return;
                    }
                }
            }
        }
    }

    Class legacyNotifCls = NSClassFromString(@"NSUserNotification");
    Class legacyCenterCls = NSClassFromString(@"NSUserNotificationCenter");
    if (legacyNotifCls && legacyCenterCls) {
        @try {
            id notif = [legacyNotifCls new];
            [notif setValue:title forKey:@"title"];
            [notif setValue:body forKey:@"informativeText"];
            id center = [legacyCenterCls performSelector:@selector(defaultUserNotificationCenter)];
            [center performSelector:@selector(deliverNotification:) withObject:notif];
        } @catch (__unused NSException *e) {
        }
    }
}

__attribute__((constructor))
static void WxInterceptInitialize(void) {
    // Prevent duplicate initialization (if dylib is loaded multiple times)
    if (sInitialized) {
        WXILog(@"Already initialized, skipping duplicate constructor call.");
        return;
    }
    sInitialized = YES;
    
    WXILog(@"=== WxIntercept loaded (Mojo + ilink2 + ObjC Swizzle strategy) ===");
    WXILog(@"Debug log path: %@", [NSTemporaryDirectory() stringByAppendingPathComponent:@"wxintercept_ipc.log"]);

    sCacheQueue = dispatch_queue_create("com.wxintercept.cache", DISPATCH_QUEUE_SERIAL);
    sMsgContentCache = [NSMutableDictionary new];
    sMsgContentOrder = [NSMutableArray new];

    // Strategy 1: Hook Mojo IPC (C functions from libmmmojo.dylib)
    hookMojoIPC();
    
    // Strategy 2: Hook ilink2.framework (Dart FFI functions)
    // Delay to ensure ilink2 is loaded
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        hookIlink2();
    });
    
    // Strategy 3: Hook ObjC message classes (Method Swizzling)
    // Delay slightly to ensure all WeChat classes are loaded
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        hookObjCMessageClasses();
    });

    // Strategy 4: Monitor revokemsg.db for changes
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 3 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
        monitorRevokeDB();
    });
}
