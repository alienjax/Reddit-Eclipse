#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// The set of posts (by fullname, e.g. "t3_1abc23") counted as read.
/// Kept in memory and saved to Reddit's own container under
/// Library/Application Support/HideRead/ReadPosts.plist. Entries expire after
/// 90 days and the store keeps at most 20,000 posts. Thread-safe.
@interface HideReadStore : NSObject

@property (class, nonatomic, readonly) HideReadStore *sharedStore;

/// Number of posts currently marked as read.
@property (nonatomic, readonly) NSUInteger count;

/// Number of posts newly marked as read since Reddit opened.
@property (nonatomic, readonly) NSUInteger sessionCount;

/// Every post in the read history, the most recently read first.
@property (nonatomic, readonly) NSArray<NSString *> *allPostIDsNewestFirst;

- (BOOL)containsPostID:(NSString *)postID;

/// When `postID` was last counted as read (seconds since 1970), or 0 if it isn't.
- (NSTimeInterval)readTimeForPostID:(NSString *)postID;

/// Marks a post as read (or refreshes its timestamp). Returns YES if it was not
/// already marked. Your own posts (HRIsOwnPost) are never marked.
- (BOOL)markPostID:(NSString *)postID;

/// Takes posts out of the read history; returns those that were in it.
- (NSArray<NSString *> *)removePostIDs:(NSArray<NSString *> *)postIDs;

- (void)removeAllPostIDs;

/// Writes pending changes to disk right away.
- (void)flush;

@end

NS_ASSUME_NONNULL_END
