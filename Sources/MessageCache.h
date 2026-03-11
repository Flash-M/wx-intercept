/**
 * MessageCache.h
 * wx-intercept — WeChat Mac Message Recall Interceptor
 *
 * Thread-safe LRU cache keyed on message ID.
 * Stores the last kWXIMaxCachePerSession messages per session so we can
 * restore content when WeChat fires an onRevokeMsg: callback.
 */

#pragma once
#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Maximum number of messages cached across all sessions combined.
static const NSUInteger kWXIMaxCacheTotal = 2000;

@interface MessageCache : NSObject

/// Shared singleton.
+ (instancetype)sharedCache;

/// Store a WeChat message object. The cache derives the key automatically.
- (void)cacheMessage:(id)message;

/// Look up a cached message by its numeric/string message ID.
/// Returns nil if not found or already evicted.
- (nullable id)messageWithId:(NSString *)msgId;

/// Remove a single entry (call after a revoke has been handled to free memory).
- (void)removeMessageWithId:(NSString *)msgId;

/// Extract a best-effort display string from a cached message object.
+ (NSString *)contentStringFromMessage:(id)message;

/// Extract the message ID string from a message object (tries several known keys).
+ (nullable NSString *)msgIdFromMessage:(id)message;

/// Extract the message ID string from a revoke-info object (tries several known keys).
+ (nullable NSString *)msgIdFromRevokeInfo:(id)revokeInfo;

/// Extract a display name / username for who sent the original message.
+ (nullable NSString *)senderFromMessage:(id)message;

@end

NS_ASSUME_NONNULL_END
