#import "HROwnPosts.h"
#import <os/lock.h>
#import "HRAccountHider.h"
#import "HRResponseProcessor.h"
#import "HRShared.h"
#import "HideReadStore.h"

static NSString *const kHROwnPostsKey = @"HROwnPosts";        // post ids, oldest first
static NSString *const kHROwnAccountsKey = @"HROwnAccounts";  // account name (lowercased) -> "t2_" id, or ""
static const NSUInteger kHROwnPostsMax = 5000;

static os_unfair_lock gLock = OS_UNFAIR_LOCK_INIT;
static NSMutableOrderedSet<NSString *> *gPosts;              // under gLock
static NSMutableDictionary<NSString *, NSString *> *gAccounts;
static NSMutableSet<NSString *> *gAccountIDs;

// Under gLock: from the user defaults, the first time.
static void HRLoad(void) {
  if (gPosts) return;
  gPosts = [NSMutableOrderedSet orderedSet];
  gAccounts = [NSMutableDictionary dictionary];
  gAccountIDs = [NSMutableSet set];
  NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
  for (id postID in [defaults arrayForKey:kHROwnPostsKey])
    if ([postID isKindOfClass:NSString.class] && [(NSString *)postID hasPrefix:@"t3_"]) [gPosts addObject:postID];
  NSDictionary *accounts = [defaults dictionaryForKey:kHROwnAccountsKey];
  for (id name in accounts) {
    id accountID = accounts[name];
    if (![name isKindOfClass:NSString.class] || ![accountID isKindOfClass:NSString.class]) continue;
    gAccounts[name] = accountID;
    if ([(NSString *)accountID hasPrefix:@"t2_"]) [gAccountIDs addObject:accountID];
  }
}

BOOL HRIsOwnPost(NSString *postID) {
  if (![postID isKindOfClass:NSString.class] || ![postID hasPrefix:@"t3_"]) return NO;
  os_unfair_lock_lock(&gLock);
  HRLoad();
  BOOL own = [gPosts containsObject:postID];
  os_unfair_lock_unlock(&gLock);
  return own;
}

BOOL HRIsOwnAuthor(NSString *name, NSString *accountID) {
  if (![name isKindOfClass:NSString.class]) name = nil;
  if (![accountID isKindOfClass:NSString.class]) accountID = nil;
  if ([name hasPrefix:@"u/"]) name = [name substringFromIndex:2];
  NSString *lowered = name.lowercaseString;
  if (!lowered.length && !accountID.length) return NO;
  os_unfair_lock_lock(&gLock);
  HRLoad();
  BOOL own = (lowered.length && gAccounts[lowered]) || (accountID.length && [gAccountIDs containsObject:accountID]);
  os_unfair_lock_unlock(&gLock);
  return own;
}

// Whether a post node names one of your accounts as its author: "authorInfo"
// on Reddit's posts, author fields on the cells of server-driven cards and on
// posts from the older API. Comments, and a crossposted original (someone
// else's post can carry yours), are never looked into.
static BOOL HRNamesYouAsAuthor(id object, NSUInteger depth) {
  if (depth > 4) return NO;
  if ([object isKindOfClass:NSArray.class]) {
    for (id value in (NSArray *)object)
      if (HRNamesYouAsAuthor(value, depth + 1)) return YES;
    return NO;
  }
  if (![object isKindOfClass:NSDictionary.class]) return NO;
  NSDictionary *dict = object;
  for (id key in dict) {
    if (![key isKindOfClass:NSString.class]) continue;
    NSString *lowered = [(NSString *)key lowercaseString];
    if ([lowered containsString:@"comment"] || [lowered containsString:@"crosspost"]) continue;
    id value = dict[key];
    if ([lowered isEqualToString:@"authorinfo"] || [lowered isEqualToString:@"author"]) {
      if ([value isKindOfClass:NSDictionary.class]) {
        NSDictionary *author = value;
        if (HRIsOwnAuthor(author[@"name"], author[@"id"])) return YES;
      } else if (HRIsOwnAuthor(value, nil)) {
        return YES;
      }
      continue;
    }
    if ([value isKindOfClass:NSString.class]) {
      if ([lowered isEqualToString:@"authorname"] && HRIsOwnAuthor(value, nil)) return YES;
      if (([lowered isEqualToString:@"authorid"] || [lowered isEqualToString:@"author_fullname"] ||
           [lowered isEqualToString:@"authorfullname"]) &&
          HRIsOwnAuthor(nil, value))
        return YES;
      continue;
    }
    if (HRNamesYouAsAuthor(value, depth + 1)) return YES;
  }
  return NO;
}

BOOL HRCheckOwnPost(NSString *postID, NSDictionary *node) {
  if (![postID hasPrefix:@"t3_"] || ![node isKindOfClass:NSDictionary.class]) return NO;
  os_unfair_lock_lock(&gLock);
  HRLoad();
  BOOL known = [gPosts containsObject:postID];
  BOOL accounts = gAccounts.count > 0;
  os_unfair_lock_unlock(&gLock);
  if (known) return YES;
  if (!accounts || !HRNamesYouAsAuthor(node, 0)) return NO;
  HRAddOwnPosts(@[ postID ]);
  return YES;
}

NSArray<NSString *> *HRAddOwnPosts(NSArray<NSString *> *postIDs) {
  NSMutableArray<NSString *> *added = [NSMutableArray array];
  NSArray<NSString *> *saved = nil;
  os_unfair_lock_lock(&gLock);
  HRLoad();
  for (NSString *postID in postIDs) {
    if (![postID isKindOfClass:NSString.class] || ![postID hasPrefix:@"t3_"] || [gPosts containsObject:postID])
      continue;
    [gPosts addObject:postID];
    [added addObject:postID];
  }
  if (added.count) {
    if (gPosts.count > kHROwnPostsMax) [gPosts removeObjectsInRange:NSMakeRange(0, gPosts.count - kHROwnPostsMax)];
    saved = [[NSArray alloc] initWithArray:gPosts.array];
  }
  os_unfair_lock_unlock(&gLock);
  if (!added.count) return added;

  [NSUserDefaults.standardUserDefaults setObject:saved forKey:kHROwnPostsKey];
  for (NSString *postID in [HideReadStore.sharedStore removePostIDs:added])
    HRLog(@"[own] %@ is your post: out of the read history, and never hidden", HRDescribePost(postID));
  HRAccountHiderOwnPosts(added);
  return added;
}

BOOL HRKnowsOwnAccount(void) {
  os_unfair_lock_lock(&gLock);
  HRLoad();
  BOOL known = gAccounts.count > 0;
  os_unfair_lock_unlock(&gLock);
  return known;
}

void HRAddOwnAccount(NSString *name, NSString *accountID) {
  NSString *lowered = name.lowercaseString;
  if (!lowered.length) return;
  NSString *value = [accountID hasPrefix:@"t2_"] ? accountID : @"";
  NSDictionary *saved = nil;
  os_unfair_lock_lock(&gLock);
  HRLoad();
  NSString *known = gAccounts[lowered];
  if (!known || (value.length && ![known isEqualToString:value])) {
    gAccounts[lowered] = value;
    if (value.length) [gAccountIDs addObject:value];
    saved = [gAccounts copy];
  }
  os_unfair_lock_unlock(&gLock);
  if (!saved) return;
  [NSUserDefaults.standardUserDefaults setObject:saved forKey:kHROwnAccountsKey];
  HRLog(@"[own] signed in as u/%@: your own posts are never counted as read or hidden", name);
}
