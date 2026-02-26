/**
 * WxIntercept.m
 * wx-intercept — WeChat Mac Message Recall Interceptor
 *
 * This file is compiled into a dynamic library (dylib) that is injected into
 * the WeChat for macOS process.  When loaded it:
 *
 *  1. Swizzles MessageService / CMessageMgr  so that every incoming message
 *     is cached before WeChat processes it.
 *  2. Swizzles the revoke-message handler so that, when WeChat tries to hide a
 *     recalled message, we
 *       a. Look the original content up in the cache.
 *       b. Let WeChat's own revoke logic run (so the UI stays consistent).
 *       c. Re-inject the recalled content as a new system-style local message
 *          in the same conversation.
 *       d. Post a macOS User Notification as a fallback so the content is
 *          never silently lost.
 *
 * Compatibility: universal binary (x86_64 + arm64), WeChat ≥ 3.0 for macOS.
 *
 * Build:  see Makefile at the repository root.
 * Install: see Scripts/install.sh.
 */

#import <Foundation/Foundation.h>
#import <AppKit/AppKit.h>
#import <UserNotifications/UserNotifications.h>
#import <objc/runtime.h>
#import <objc/message.h>

#import "MessageCache.h"

// ---------------------------------------------------------------------------
// Logging
// ---------------------------------------------------------------------------
#define WXILog(fmt, ...) \
    NSLog(@"[WxIntercept] " fmt, ##__VA_ARGS__)

// ---------------------------------------------------------------------------
// Forward declarations
// ---------------------------------------------------------------------------
static void hookMessageService(void);
static void hookClass(Class cls);
static BOOL trySwizzle(Class cls, SEL orig, SEL replacement);
static void showNotification(NSString *sender, NSString *content);
static void tryAddRecalledMessageToChat(id messageService,
                                        id originalMessage,
                                        NSString *content,
                                        id revokeInfo);

// ---------------------------------------------------------------------------
// Category carrying our hook implementations
//
// We attach these methods to NSObject so they survive across multiple WeChat
// class hierarchies.  The swizzle step replaces the IMP on the *specific*
// WeChat class, not on NSObject.
// ---------------------------------------------------------------------------
@interface NSObject (WxInterceptHooks)

/// Replacement for MessageService / CMessageMgr  -onAddMsg:MgrType:
- (void)wxi_onAddMsg:(id)message MgrType:(int)type;

/// Replacement for MessageService / CMessageMgr  -onRevokeMsg:
- (void)wxi_onRevokeMsg:(id)revokeInfo;

/// Replacement for the single-argument variant (some WeChat versions)
- (void)wxi_onRevokeMsg_v2:(id)revokeInfo;

@end

@implementation NSObject (WxInterceptHooks)

// ---------------------------------------------------------------------------
// Message-add hook — cache every inbound message
// ---------------------------------------------------------------------------
- (void)wxi_onAddMsg:(id)message MgrType:(int)type {
    [[MessageCache sharedCache] cacheMessage:message];

    // Call original (swizzled names are exchanged, so "wxi_" now points at
    // the original IMP)
    [self wxi_onAddMsg:message MgrType:type];
}

// ---------------------------------------------------------------------------
// Revoke hook (two-argument) — the main interception path
// ---------------------------------------------------------------------------
- (void)wxi_onRevokeMsg:(id)revokeInfo {
    WXILog(@"onRevokeMsg: triggered — revokeInfo=%@", revokeInfo);

    // 1. Identify the message being revoked
    NSString *msgId = [MessageCache msgIdFromRevokeInfo:revokeInfo];
    WXILog(@"Revoked msgId resolved to: %@", msgId ?: @"<unknown>");

    // 2. Look up cached original
    id originalMessage = msgId ? [[MessageCache sharedCache] messageWithId:msgId] : nil;
    NSString *content  = [MessageCache contentStringFromMessage:originalMessage];
    NSString *sender   = [MessageCache senderFromMessage:originalMessage];

    // 3. Let WeChat perform the revoke (updates its own DB / UI)
    [self wxi_onRevokeMsg:revokeInfo];

    // 4. Re-surface the message
    if (originalMessage) {
        WXILog(@"Intercepted recalled message from %@: %@", sender ?: @"?", content);
        tryAddRecalledMessageToChat(self, originalMessage, content, revokeInfo);
    } else {
        WXILog(@"Original message not in cache (msgId=%@), showing notification only", msgId);
    }

    showNotification(sender, content);

    // 5. Keep cache tidy
    if (msgId) [[MessageCache sharedCache] removeMessageWithId:msgId];
}

// ---------------------------------------------------------------------------
// Revoke hook (one-argument variant found in some WeChat builds)
// ---------------------------------------------------------------------------
- (void)wxi_onRevokeMsg_v2:(id)revokeInfo {
    WXILog(@"onRevokeMsg (v2) triggered");

    NSString *msgId       = [MessageCache msgIdFromRevokeInfo:revokeInfo];
    id originalMessage    = msgId ? [[MessageCache sharedCache] messageWithId:msgId] : nil;
    NSString *content     = [MessageCache contentStringFromMessage:originalMessage];
    NSString *sender      = [MessageCache senderFromMessage:originalMessage];

    [self wxi_onRevokeMsg_v2:revokeInfo];

    if (originalMessage) {
        WXILog(@"Intercepted recalled message from %@: %@", sender ?: @"?", content);
        tryAddRecalledMessageToChat(self, originalMessage, content, revokeInfo);
    }

    showNotification(sender, content);

    if (msgId) [[MessageCache sharedCache] removeMessageWithId:msgId];
}

@end

// ---------------------------------------------------------------------------
// In-chat re-injection
// ---------------------------------------------------------------------------

/// Build a display string for the recalled message.
static NSString *recallDisplayText(NSString *sender, NSString *content) {
    NSString *name = sender.length ? sender : @"对方";
    return [NSString stringWithFormat:@"[撤回] %@: %@", name, content];
}

/// Candidate selectors for adding a local (not synced) message to the chat.
static NSArray<NSString *> *kAddLocalMsgSelectors(void) {
    return @[
        @"addLocalMsg:forSession:",
        @"insertLocalMsg:toSession:",
        @"appendLocalMsg:toSession:",
        @"sendLocalMsg:toSession:",
    ];
}

/// Candidate keys for extracting the session / talker ID from a revoke-info
/// or from the original message.
static NSArray<NSString *> *kSessionKeys(void) {
    return @[@"m_nsSession", @"session", @"talkerId", @"toUserName",
             @"m_nsTalkerId", @"chatRoomName", @"m_nsChatRoomName"];
}

static id safeKVC(id obj, NSString *key) {
    @try { return [obj valueForKey:key]; }
    @catch (...) { return nil; }
}

static void tryAddRecalledMessageToChat(id messageService,
                                        id originalMessage,
                                        NSString *content,
                                        id revokeInfo) {
    if (!originalMessage || !messageService) return;

    // -- Resolve session identifier --
    NSString *sessionId = nil;
    for (NSString *key in kSessionKeys()) {
        id v = safeKVC(revokeInfo, key) ?: safeKVC(originalMessage, key);
        if (v) { sessionId = [NSString stringWithFormat:@"%@", v]; break; }
    }

    // -- Build a minimal WeChat message object to inject --
    // We clone the original message and update its content/type so that
    // WeChat's own rendering pipeline handles display correctly.
    id newMsg = nil;
    @try {
        // Most WeChat message classes implement NSCopying; if not, we fall back
        // to creating a plain NSMutableDictionary (triggers generic rendering).
        if ([originalMessage respondsToSelector:@selector(mutableCopy)]) {
            newMsg = [originalMessage mutableCopy];
        } else if ([originalMessage respondsToSelector:@selector(copy)]) {
            newMsg = [originalMessage copy];
        }
    } @catch (...) {}

    NSString *displayText = recallDisplayText(
        [MessageCache senderFromMessage:originalMessage], content);

    if (newMsg) {
        // Overwrite content and reset the message ID so WeChat treats it as new
        @try { [newMsg setValue:displayText forKey:@"m_nsContent"]; }  @catch (...) {}
        @try { [newMsg setValue:displayText forKey:@"content"]; }      @catch (...) {}
        @try { [newMsg setValue:@(0)        forKey:@"m_nMsgId"]; }     @catch (...) {}
        @try { [newMsg setValue:@(0)        forKey:@"msgId"]; }        @catch (...) {}
        // Mark as a local system-style notification (type 10000)
        @try { [newMsg setValue:@(10000)    forKey:@"m_nMsgType"]; }   @catch (...) {}
        @try { [newMsg setValue:@(10000)    forKey:@"msgType"]; }      @catch (...) {}
    }

    if (!newMsg || !sessionId) {
        WXILog(@"Cannot inject in-chat message: newMsg=%@ sessionId=%@",
               newMsg, sessionId);
        return;
    }

    // -- Try each candidate selector --
    for (NSString *selName in kAddLocalMsgSelectors()) {
        SEL sel = NSSelectorFromString(selName);
        if ([messageService respondsToSelector:sel]) {
            @try {
                // Use NSInvocation to avoid ARC/type warnings on unknown selectors
                NSMethodSignature *sig =
                    [messageService methodSignatureForSelector:sel];
                if (!sig) continue;
                NSInvocation *inv =
                    [NSInvocation invocationWithMethodSignature:sig];
                inv.target   = messageService;
                inv.selector = sel;
                [inv setArgument:&newMsg      atIndex:2];
                [inv setArgument:&sessionId   atIndex:3];
                [inv invoke];
                WXILog(@"In-chat injection succeeded via %@", selName);
                return;
            } @catch (NSException *e) {
                WXILog(@"In-chat injection via %@ failed: %@", selName, e);
            }
        }
    }
    WXILog(@"In-chat injection: no matching selector found on %@",
           NSStringFromClass([messageService class]));
}

// ---------------------------------------------------------------------------
// macOS notification fallback
// ---------------------------------------------------------------------------
static void showNotification(NSString *sender, NSString *content) {
    NSString *title = sender.length
        ? [NSString stringWithFormat:@"撤回消息 — %@", sender]
        : @"撤回消息";
    NSString *body = content.length ? content : @"[消息]";

    // Prefer the modern UNUserNotificationCenter (macOS 10.14+)
    Class UNCenter = NSClassFromString(@"UNUserNotificationCenter");
    if (UNCenter) {
        id center = [UNCenter performSelector:@selector(currentNotificationCenter)];
        if (!center) {
            // macOS 10.14+ uses +currentNotificationCenter
            center = objc_msgSend((id)UNCenter,
                                  NSSelectorFromString(@"currentNotificationCenter"));
        }

        // Request authorization (fire-and-forget; WeChat already has it)
        SEL reqAuth = NSSelectorFromString(
            @"requestAuthorizationWithOptions:completionHandler:");
        if ([center respondsToSelector:reqAuth]) {
            NSMethodSignature *sig = [center methodSignatureForSelector:reqAuth];
            NSInvocation *inv = [NSInvocation invocationWithMethodSignature:sig];
            inv.target   = center;
            inv.selector = reqAuth;
            NSUInteger opts = (1 << 2) | (1 << 3); // UNAuthorizationOptionAlert | UNAuthorizationOptionSound
            [inv setArgument:&opts atIndex:2];
            void (^dummy)(BOOL, NSError *) = ^(BOOL g, NSError *e){};
            [inv setArgument:&dummy atIndex:3];
            [inv invoke];
        }

        // Build UNMutableNotificationContent
        Class contentClass =
            NSClassFromString(@"UNMutableNotificationContent");
        id notifContent = [contentClass new];
        [notifContent setValue:title forKey:@"title"];
        [notifContent setValue:body  forKey:@"body"];

        // Build UNNotificationRequest
        Class reqClass = NSClassFromString(@"UNNotificationRequest");
        NSString *identifier =
            [NSString stringWithFormat:@"wxintercept.%f",
             [NSDate date].timeIntervalSince1970];
        SEL reqWith = NSSelectorFromString(
            @"requestWithIdentifier:content:trigger:");
        NSMethodSignature *rSig =
            [reqClass methodSignatureForSelector:reqWith];
        if (rSig) {
            NSInvocation *rInv =
                [NSInvocation invocationWithMethodSignature:rSig];
            rInv.target   = (id)reqClass;
            rInv.selector = reqWith;
            [rInv setArgument:&identifier   atIndex:2];
            [rInv setArgument:&notifContent atIndex:3];
            id trigger = nil;
            [rInv setArgument:&trigger      atIndex:4];
            [rInv invoke];
            __unsafe_unretained id request;
            [rInv getReturnValue:&request];

            if (request) {
                SEL addReq =
                    NSSelectorFromString(@"addNotificationRequest:withCompletionHandler:");
                NSMethodSignature *aSig =
                    [center methodSignatureForSelector:addReq];
                if (aSig) {
                    NSInvocation *aInv =
                        [NSInvocation invocationWithMethodSignature:aSig];
                    aInv.target   = center;
                    aInv.selector = addReq;
                    [aInv setArgument:&request atIndex:2];
                    id nilBlock = nil;
                    [aInv setArgument:&nilBlock atIndex:3];
                    [aInv invoke];
                    WXILog(@"UNUserNotificationCenter notification sent");
                    return;
                }
            }
        }
    }

    // Legacy fallback: NSUserNotification (macOS 10.8 – 10.14)
    Class NSUNClass = NSClassFromString(@"NSUserNotification");
    Class NSUNCenterClass = NSClassFromString(@"NSUserNotificationCenter");
    if (NSUNClass && NSUNCenterClass) {
        @try {
            id notif = [NSUNClass new];
            [notif setValue:title forKey:@"title"];
            [notif setValue:body  forKey:@"informativeText"];
            id center = [NSUNCenterClass
                         performSelector:@selector(defaultUserNotificationCenter)];
            [center performSelector:@selector(deliverNotification:)
                         withObject:notif];
            WXILog(@"NSUserNotification sent (legacy)");
        } @catch (NSException *e) {
            WXILog(@"Legacy notification failed: %@", e);
        }
    }
}

// ---------------------------------------------------------------------------
// Swizzle helpers
// ---------------------------------------------------------------------------

/// Exchange implementations of `orig` and `replacement` on `cls`.
/// Returns YES if both methods were found and swapped.
static BOOL trySwizzle(Class cls, SEL orig, SEL replacement) {
    Method origMethod = class_getInstanceMethod(cls, orig);
    Method replMethod = class_getInstanceMethod(cls, replacement);
    if (!origMethod || !replMethod) return NO;
    method_exchangeImplementations(origMethod, replMethod);
    WXILog(@"Swizzled [%@ %@]", NSStringFromClass(cls), NSStringFromSelector(orig));
    return YES;
}

// ---------------------------------------------------------------------------
// Hook installation
// ---------------------------------------------------------------------------

/// Candidate class names to hook (tried in order; first match wins per method).
static NSArray<NSString *> *kCandidateClasses(void) {
    return @[
        @"MessageService",
        @"CMessageMgr",
        @"WCMessageManager",
        @"MessageManager",
    ];
}

/// Install hooks on a single WeChat service class.
static void hookClass(Class cls) {
    if (!cls) return;

    // -- Cache all inbound messages --
    trySwizzle(cls,
               @selector(onAddMsg:MgrType:),
               @selector(wxi_onAddMsg:MgrType:));

    // -- Intercept revoke (two-arg) --
    BOOL hookedRevoke =
        trySwizzle(cls,
                   @selector(onRevokeMsg:),
                   @selector(wxi_onRevokeMsg:));

    // -- Intercept revoke (one-arg alternate) --
    if (!hookedRevoke) {
        // Some builds use a different selector name
        for (NSString *selName in @[@"revokeMsg:", @"didReceiveRevokeMsg:",
                                    @"handleRevokeMsg:", @"processRevokeMsg:"]) {
            if (trySwizzle(cls,
                           NSSelectorFromString(selName),
                           @selector(wxi_onRevokeMsg_v2:))) {
                break;
            }
        }
    }
}

static void hookMessageService(void) {
    BOOL hooked = NO;
    for (NSString *className in kCandidateClasses()) {
        Class cls = NSClassFromString(className);
        if (cls) {
            WXILog(@"Installing hooks on class: %@", className);
            hookClass(cls);
            hooked = YES;
            // Don't break — WeChat may split functionality across multiple classes
        }
    }
    if (!hooked) {
        WXILog(@"WARNING: None of the expected WeChat classes were found. "
               @"The plugin may not be compatible with this version of WeChat.");
    }
}

// ---------------------------------------------------------------------------
// dylib constructor — runs automatically when WeChat loads this library
// ---------------------------------------------------------------------------
__attribute__((constructor))
static void WxInterceptInitialize(void) {
    WXILog(@"Loaded. Initializing message recall interceptor…");
    WXILog(@"Build: %s %s", __DATE__, __TIME__);

    // WeChat's Objective-C classes are registered at launch.  We defer the
    // hook installation by a short interval so that all classes are available.
    dispatch_after(
        dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)),
        dispatch_get_main_queue(),
        ^{
            hookMessageService();
            WXILog(@"Hook installation complete.");
        });
}
