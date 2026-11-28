#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Your own posts. Jax Reddit Eclipse never counts them as read, never leaves
/// them out of a feed, and never hides them on your Reddit account. It learns
/// which they are from Reddit (your account and your recent posts, and who
/// posted each post before it's hidden on your account; see HRAccountHider.m)
/// and from the author named by the posts it sees in feeds and post pages.
/// Kept in Reddit's user defaults, for every account the app has used. Any
/// thread.

/// YES if `postID` is one of your posts, as far as Jax Reddit Eclipse knows.
BOOL HRIsOwnPost(NSString *_Nullable postID);

/// YES if a post's author, as Reddit names it (`name`, e.g. "alienjax", and/or
/// `accountID`, e.g. "t2_abc12"), is one of your accounts.
BOOL HRIsOwnAuthor(NSString *_Nullable name, NSString *_Nullable accountID);

/// Whether `node` (a feed item, or a post page's post) is by you, going by the
/// author it names; if it is, the post is remembered as yours. NO when it names
/// no author, or before your account is known.
BOOL HRCheckOwnPost(NSString *postID, NSDictionary *node);

/// Remembers posts as yours, takes them out of the read history, and tells
/// HRAccountHider (they're never hidden; any it hid before are unhidden).
/// Returns those that weren't known yet.
NSArray<NSString *> *HRAddOwnPosts(NSArray<NSString *> *postIDs);

/// An account the app is signed in to (from Reddit's /api/v1/me, or the
/// account an answer says is signed in): its name and "t2_" id.
void HRAddOwnAccount(NSString *name, NSString *_Nullable accountID);

/// YES once any account of yours is known, so your posts can be told apart.
BOOL HRKnowsOwnAccount(void);

NS_ASSUME_NONNULL_END
