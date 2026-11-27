#import "HRResponseProcessor.h"
#import <os/lock.h>
#import <stdatomic.h>
#import <string.h>
#import "HideReadStore.h"
#import "HRAccountHider.h"
#import "HROwnPosts.h"
#import "HRScreenTracker.h"
#import "HRScrollTracker.h"
#import "HRShared.h"
#import "HideReadSettingsViewController.h"

// Reddit preloads a small comment tree (8 comments) for posts that stay on
// screen in a feed for a few seconds, then asks for ~200 comments when you
// actually open the post (r/RedditEng, "Instant Comment Loading on Android &
// iOS", May 2024). A comment load bigger than the preload therefore means the
// post was opened.
static const NSUInteger kHRPreloadMaxComments = 8;

// How long after a post screen appears its first comment load can still be
// attributed to it.
static const NSTimeInterval kHRPostScreenWindow = 6.0;

static const NSUInteger kHRMaxWalkDepth = 12;

@interface HideReadFeedStats : NSObject
@property (nonatomic) BOOL diagnostics;
@property (nonatomic) NSUInteger posts;         // visible posts recognised in feed lists
@property (nonatomic) NSUInteger hidden;        // of those, taken out because they were read
@property (nonatomic) NSUInteger crossposts;    // of those, crossposts of posts you've read
@property (nonatomic) NSUInteger alreadyHidden; // posts taken out because Reddit marks them hidden
@property (nonatomic) NSUInteger unrecognized;  // feed items with no single post id
@property (nonatomic, copy) NSString *unrecognizedSample;
@property (nonatomic, strong) NSMutableArray<NSString *> *hiddenTitles;  // diagnostics
@property (nonatomic) BOOL rememberTitles;  // for the log and the scroll tracker
@property (nonatomic) NSUInteger shown;     // hidden posts shown as posts again
@property (nonatomic) BOOL keptHiddenRow;   // a "Post hidden" row had to stay
@property (nonatomic, strong) NSArray<NSString *> *listedPosts;  // the list's posts as handed on, in order
@property (nonatomic, copy) NSString *listedCursor;              // and its endCursor
@end

@implementation HideReadFeedStats
@end

static void HRRememberTitle(NSString *postID, id node);
static NSString *HRTitleSuffix(NSString *postID);
static void HRNoteFeedOrder(NSArray<NSString *> *posts, NSString *after, NSString *endCursor);

#pragma mark - Identifiers

// "t3_1abc23" -> "t3_1abc23", "t3_1abc23_title" -> "t3_1abc23", anything else -> nil.
static NSString *HRPostIDFromValue(id value) {
  if (![value isKindOfClass:NSString.class]) return nil;
  NSString *string = value;
  if (![string hasPrefix:@"t3_"]) return nil;
  NSUInteger end = 3;
  while (end < string.length) {
    unichar c = [string characterAtIndex:end];
    if (!((c >= '0' && c <= '9') || (c >= 'a' && c <= 'z'))) break;
    end++;
  }
  return end > 3 ? [string substringToIndex:end] : nil;
}

// Fullnames of things that aren't posts: t1_ comment, t2_ account, t4_ message,
// t5_ subreddit, t6_ award.
static BOOL HRIsNonPostFullname(id value) {
  if (![value isKindOfClass:NSString.class]) return NO;
  NSString *string = value;
  if (string.length < 4 || [string characterAtIndex:0] != 't' || [string characterAtIndex:2] != '_')
    return NO;
  unichar kind = [string characterAtIndex:1];
  return kind >= '0' && kind <= '9' && kind != '3';
}

static NSString *HRTypename(NSDictionary *node) {
  id type = node[@"__typename"];
  return [type isKindOfClass:NSString.class] ? type : @"";
}

// Breadth-first search for post ids, stopping once `limit` distinct ids turn
// up. With `anyKey` NO, only values under identifier-like keys count.
static NSOrderedSet<NSString *> *HRPostIDsInside(id root, NSUInteger maxDepth, BOOL anyKey,
                                                 NSUInteger limit) {
  static NSSet<NSString *> *identifierKeys;
  static dispatch_once_t once;
  dispatch_once(&once, ^{
    identifierKeys = [NSSet setWithArray:@[ @"groupId", @"postId", @"postID", @"id", @"linkId" ]];
  });

  NSMutableOrderedSet<NSString *> *found = [NSMutableOrderedSet orderedSet];
  NSMutableArray<NSArray *> *queue = [NSMutableArray arrayWithObject:@[ root, @0 ]];
  for (NSUInteger head = 0; head < queue.count && head < 400 && found.count < limit; head++) {
    NSArray *entry = queue[head];
    id object = entry[0];
    NSUInteger depth = [entry[1] unsignedIntegerValue];
    NSArray *children = nil;

    if ([object isKindOfClass:NSDictionary.class]) {
      NSDictionary *dict = object;
      for (id key in dict) {
        if (!anyKey && ![identifierKeys containsObject:key]) continue;
        NSString *postID = HRPostIDFromValue(dict[key]);
        if (postID) [found addObject:postID];
      }
      children = dict.allValues;
    } else if ([object isKindOfClass:NSArray.class]) {
      children = object;
      if (anyKey) {
        for (id value in children) {
          NSString *postID = HRPostIDFromValue(value);
          if (postID) [found addObject:postID];
        }
      }
    }

    if (depth >= maxDepth) continue;
    for (id child in children)
      if ([child isKindOfClass:NSDictionary.class] || [child isKindOfClass:NSArray.class])
        [queue addObject:@[ child, @(depth + 1) ]];
  }
  return found;
}

// The one post id inside `root`, or nil if there is none or several (a
// carousel, a crosspost or similar, which is left alone).
static NSString *HRSinglePostIDInside(id root, NSUInteger maxDepth, BOOL anyKey) {
  NSOrderedSet<NSString *> *ids = HRPostIDsInside(root, maxDepth, anyKey, 2);
  return ids.count == 1 ? ids.firstObject : nil;
}

// Diagnostics only: key paths of the first few post ids inside a node, so the
// log shows where Reddit keeps them if a feed item isn't recognised.
static void HRFindPostIDPaths(id object, NSString *path, NSUInteger depth,
                              NSMutableArray<NSString *> *paths) {
  if (paths.count >= 4 || depth > 6) return;
  if ([object isKindOfClass:NSDictionary.class]) {
    NSDictionary *dict = object;
    for (NSString *key in [dict.allKeys sortedArrayUsingSelector:@selector(compare:)]) {
      id value = dict[key];
      NSString *childPath = path.length > 0 ? [NSString stringWithFormat:@"%@.%@", path, key] : key;
      if (HRPostIDFromValue(value))
        [paths addObject:[NSString stringWithFormat:@"%@=%@", childPath, value]];
      else
        HRFindPostIDPaths(value, childPath, depth + 1, paths);
      if (paths.count >= 4) return;
    }
  } else if ([object isKindOfClass:NSArray.class]) {
    NSArray *array = object;
    for (NSUInteger i = 0; i < array.count && i < 10 && paths.count < 4; i++)
      HRFindPostIDPaths(array[i], [NSString stringWithFormat:@"%@[%lu]", path, (unsigned long)i],
                        depth + 1, paths);
  }
}

static NSString *HRDescribeNode(NSDictionary *node) {
  NSMutableArray<NSString *> *keys = [NSMutableArray array];
  for (id key in node)
    if ([key isKindOfClass:NSString.class]) [keys addObject:key];
  [keys sortUsingSelector:@selector(compare:)];
  NSString *type = HRTypename(node);
  NSMutableString *description =
      [NSMutableString stringWithFormat:@"%@ {%@}", type.length > 0 ? type : @"untyped",
                                        [keys componentsJoinedByString:@", "]];

  id cells = node[@"cells"];
  if ([cells isKindOfClass:NSArray.class]) {
    NSMutableArray<NSString *> *cellTypes = [NSMutableArray array];
    for (id cell in (NSArray *)cells)
      if ([cell isKindOfClass:NSDictionary.class] && cellTypes.count < 8)
        [cellTypes addObject:HRTypename(cell)];
    [description appendFormat:@", cells: %@", [cellTypes componentsJoinedByString:@", "]];
  }

  NSMutableArray<NSString *> *paths = [NSMutableArray array];
  HRFindPostIDPaths(node, @"", 0, paths);
  [description appendFormat:@", post ids at: %@",
                            paths.count > 0 ? [paths componentsJoinedByString:@"; "] : @"none"];
  return description;
}

// The post a feed node stands for, or nil if it isn't a post.
static NSString *HRPostIDForNode(NSDictionary *node) {
  NSString *type = HRTypename(node);
  if ([type containsString:@"Comment"]) return nil;
  for (NSString *key in @[ @"groupId", @"postId", @"id", @"linkId" ]) {
    NSString *postID = HRPostIDFromValue(node[key]);
    if (postID) return postID;
  }
  if (HRIsNonPostFullname(node[@"id"])) return nil;
  // Server-driven feed units ("CellGroup") may carry the post id only inside their cells.
  id cells = node[@"cells"];
  if ([cells isKindOfClass:NSArray.class]) return HRSinglePostIDInside(cells, 4, NO);
  return nil;
}

#pragma mark - Hiding

static BOOL HRIsHideableNode(NSDictionary *node) {
  NSString *type = HRTypename(node);
  return [type isEqualToString:@"CellGroup"] || [type hasSuffix:@"Post"] ||
         [node[@"cells"] isKindOfClass:NSArray.class] || node[@"isHidden"] != nil;
}

static BOOL HRIsAlreadyHidden(NSDictionary *node) {
  id hidden = node[@"isHidden"];
  if ([hidden isKindOfClass:NSNumber.class] && [hidden boolValue]) return YES;
  id cells = node[@"cells"];
  return [cells isKindOfClass:NSArray.class] && [(NSArray *)cells count] == 0;
}

// Marks a feed node hidden in place: posts get isHidden = true, server-driven
// units lose their cells. Only for a list that can't be changed: the Reddit app
// shows a post marked this way as a "Post hidden / Undo" row.
static void HRHideNode(NSMutableDictionary *node) {
  if ([node[@"cells"] isKindOfClass:NSArray.class] ||
      [HRTypename(node) isEqualToString:@"CellGroup"])
    node[@"cells"] = [NSMutableArray array];
  else
    node[@"isHidden"] = @YES;
}

static BOOL HRLooksLikeEdges(NSArray *array) {
  BOOL sawNode = NO;
  for (id element in array) {
    if (![element isKindOfClass:NSDictionary.class]) return NO;
    if ([((NSDictionary *)element)[@"node"] isKindOfClass:NSDictionary.class]) sawNode = YES;
  }
  return sawNode;
}

static BOOL HRHasMorePages(NSDictionary *container) {
  id pageInfo = container[@"pageInfo"];
  if ([pageInfo isKindOfClass:NSDictionary.class]) {
    id hasNextPage = ((NSDictionary *)pageInfo)[@"hasNextPage"];
    if ([hasNextPage isKindOfClass:NSNumber.class]) return [hasNextPage boolValue];
  }
  return YES;  // unknown, so assume there are more
}

// A post marked hidden (isHidden), turned back into a post. A server-driven
// card Reddit sends without its cells can't be: NO.
static BOOL HRShowHiddenNode(NSMutableDictionary *node) {
  id hidden = node[@"isHidden"];
  if (![hidden isKindOfClass:NSNumber.class] || ![hidden boolValue]) return NO;
  id cells = node[@"cells"];
  if ([cells isKindOfClass:NSArray.class] && [(NSArray *)cells count] == 0) return NO;
  node[@"isHidden"] = @NO;
  return YES;
}

#pragma mark - Crossposts

// Whether a key or a type names the post a crosspost shares (crosspostRoot,
// crosspost_parent, a crosspost card), rather than posts sharing this one
// ("crossposts") or something else about crossposting (crosspostCount,
// isCrosspostable, where-to-crosspost suggestions).
static BOOL HRNamesSharedPost(id name) {
  if (![name isKindOfClass:NSString.class]) return NO;
  NSString *lowered = ((NSString *)name).lowercaseString;
  return [lowered containsString:@"crosspost"] && ![lowered containsString:@"crossposts"] &&
         ![lowered containsString:@"suggest"] && ![lowered containsString:@"count"] &&
         ![lowered hasPrefix:@"is"] && ![lowered hasPrefix:@"can"];
}

// The posts a crosspost shares: its original, and for a crosspost of a crosspost
// the one in between. They're the post ids under a key, or inside an object, that
// names the shared post, anywhere in the post's feed item. Never the post itself;
// empty for a post that isn't a crosspost.
static NSOrderedSet<NSString *> *HRSharedPostIDs(NSDictionary *node, NSString *postID) {
  NSMutableOrderedSet<NSString *> *found = [NSMutableOrderedSet orderedSet];
  NSMutableArray<NSArray *> *queue = [NSMutableArray arrayWithObject:@[ node, @0, @NO ]];
  for (NSUInteger head = 0; head < queue.count && head < 600 && found.count < 4; head++) {
    NSArray *entry = queue[head];
    id object = entry[0];
    NSUInteger depth = [entry[1] unsignedIntegerValue];
    BOOL shared = [entry[2] boolValue];  // inside the shared post's part
    if ([object isKindOfClass:NSDictionary.class]) {
      NSDictionary *dict = object;
      if (!shared && HRNamesSharedPost(HRTypename(dict))) shared = YES;
      for (id key in dict) {
        id value = dict[key];
        BOOL inside = shared || HRNamesSharedPost(key);
        NSString *other = inside ? HRPostIDFromValue(value) : nil;
        if (other) [found addObject:other];
        if (depth < 6 && ([value isKindOfClass:NSDictionary.class] || [value isKindOfClass:NSArray.class]))
          [queue addObject:@[ value, @(depth + 1), @(inside) ]];
      }
    } else if ([object isKindOfClass:NSArray.class]) {
      for (id value in (NSArray *)object) {
        NSString *other = shared ? HRPostIDFromValue(value) : nil;
        if (other) [found addObject:other];
        if (depth < 6 && ([value isKindOfClass:NSDictionary.class] || [value isKindOfClass:NSArray.class]))
          [queue addObject:@[ value, @(depth + 1), @(shared) ]];
      }
    }
  }
  if (postID) [found removeObject:postID];
  return found;
}

// "It’s a Crosspost of a Read Post": whether a feed post is a crosspost of a post
// you've read. Then it counts as read itself, so it also goes on your account and
// stays out wherever read posts do.
static BOOL HRSharesReadPost(NSDictionary *node, NSString *postID, HideReadFeedStats *stats) {
  NSOrderedSet<NSString *> *shared = HRSharedPostIDs(node, postID);
  if (shared.count == 0) {
    // A server-driven unit with another post's id in its cells may be a crosspost
    // whose card isn't named as one: shown in the log, so it can be recognised.
    id cells = node[@"cells"];
    if (stats.diagnostics && [cells isKindOfClass:NSArray.class]) {
      NSMutableOrderedSet<NSString *> *ids = [HRPostIDsInside(cells, 5, NO, 3) mutableCopy];
      [ids removeObject:postID];
      if (ids.count)
        HRLogOnce(@"crosspost-unnamed", @"[crosspost] %@ has another post's id (%@) in its cells: %@",
                  HRDescribePost(postID), ids.firstObject, HRDescribeNode(node));
    }
    return NO;
  }
  HideReadStore *store = HideReadStore.sharedStore;
  NSString *read = nil;
  for (NSString *other in shared) {
    if ([store containsPostID:other]) {
      read = other;
      break;
    }
  }
  if (stats.diagnostics)
    HRLogOnce([@"crosspost:" stringByAppendingString:postID], @"[crosspost] %@ shares %@%@",
              HRDescribePost(postID), HRDescribePost(read ?: shared.firstObject),
              read ? @", which you've read: counted as read" : @", not read yet");
  if (!read) return NO;
  [store markPostID:postID];
  stats.crossposts++;
  return YES;
}

// Takes the read posts out of a feed list, and the posts Reddit marks as hidden
// on your account: the app would show each of those as a "Post hidden / Undo"
// row. Your own posts stay; one of yours Jax Reddit Eclipse hid before (it's
// being unhidden) shows as a post. The list's pageInfo stays as it is, so the
// next page loads as usual. A list left with nothing at all in it could stop the
// feed from loading more, so then, when more pages exist, one post stays: the
// last read one, else the last hidden one, shown as a post where it can be.
static void HRHideReadInEdges(NSArray *edges, NSDictionary *container, HideReadFeedStats *stats) {
  HideReadStore *store = HideReadStore.sharedStore;
  BOOL crossposts = HRPref(HRPrefMarkCrossposts);
  NSMutableArray<NSNumber *> *readEdges = [NSMutableArray array];    // indexes, in order
  NSMutableArray<NSNumber *> *hiddenEdges = [NSMutableArray array];
  NSUInteger visiblePosts = 0;

  for (NSUInteger i = 0; i < edges.count; i++) {
    id edge = edges[i];
    if (![edge isKindOfClass:NSDictionary.class]) continue;
    id node = ((NSDictionary *)edge)[@"node"];
    if (![node isKindOfClass:NSMutableDictionary.class] || !HRIsHideableNode(node)) continue;
    NSString *postID = HRPostIDForNode(node);
    BOOL own = postID && HRCheckOwnPost(postID, node);
    if (HRIsAlreadyHidden(node)) {
      if (!(own && HRAccountHiderHid(postID) && HRShowHiddenNode(node))) {
        if (postID) [hiddenEdges addObject:@(i)];
        continue;
      }
      stats.shown++;
    }
    if (!postID) {
      stats.unrecognized++;
      if (stats.diagnostics && !stats.unrecognizedSample)
        stats.unrecognizedSample = HRDescribeNode(node);
      continue;
    }
    visiblePosts++;
    if (stats.rememberTitles) HRRememberTitle(postID, node);
    if (own) continue;
    if ([store containsPostID:postID] || (crossposts && HRSharesReadPost(node, postID, stats)))
      [readEdges addObject:@(i)];
  }

  stats.posts += visiblePosts;
  if (readEdges.count || hiddenEdges.count) {
    if (readEdges.count + hiddenEdges.count == edges.count && HRHasMorePages(container)) {
      if (readEdges.count) {
        [readEdges removeLastObject];
      } else {
        NSNumber *last = hiddenEdges.lastObject;
        [hiddenEdges removeLastObject];
        if (HRShowHiddenNode(edges[last.unsignedIntegerValue][@"node"]))
          stats.shown++;
        else
          stats.keptHiddenRow = YES;
      }
    }

    if (stats.diagnostics && readEdges.count) {
      if (!stats.hiddenTitles) stats.hiddenTitles = [NSMutableArray array];
      for (NSNumber *index in readEdges) {
        NSString *postID = HRPostIDForNode(edges[index.unsignedIntegerValue][@"node"]);
        NSString *title = HRTitleSuffix(postID);
        [stats.hiddenTitles addObject:title.length ? [title substringFromIndex:1] : postID];
      }
    }

    if ([edges isKindOfClass:NSMutableArray.class]) {
      NSMutableArray<NSNumber *> *out = [readEdges mutableCopy];
      [out addObjectsFromArray:hiddenEdges];
      [out sortUsingSelector:@selector(compare:)];
      for (NSNumber *index in out.reverseObjectEnumerator)  // last first, so the others keep their places
        [(NSMutableArray *)edges removeObjectAtIndex:index.unsignedIntegerValue];
      stats.alreadyHidden += hiddenEdges.count;
    } else {
      for (NSNumber *index in readEdges) HRHideNode(edges[index.unsignedIntegerValue][@"node"]);
    }
    stats.hidden += readEdges.count;
  }

  // The posts the list now shows, in order: the scroll tracker counts those above
  // the topmost card on screen as scrolled past. The longest list in a response
  // is its feed.
  NSMutableArray<NSString *> *listed = [NSMutableArray array];
  for (id edge in edges) {
    id node = [edge isKindOfClass:NSDictionary.class] ? ((NSDictionary *)edge)[@"node"] : nil;
    if (![node isKindOfClass:NSDictionary.class] || HRIsAlreadyHidden(node)) continue;
    NSString *postID = HRPostIDForNode(node);
    if (postID) [listed addObject:postID];
  }
  if (listed.count > stats.listedPosts.count) {
    stats.listedPosts = listed;
    id pageInfo = container[@"pageInfo"];
    id cursor = [pageInfo isKindOfClass:NSDictionary.class] ? ((NSDictionary *)pageInfo)[@"endCursor"] : nil;
    stats.listedCursor = [cursor isKindOfClass:NSString.class] ? cursor : nil;
  }
}

// Posts Jax Reddit Eclipse hid on your account, marked hidden (isHidden) in an
// answer: counted, and with `show` turned back into posts.
static NSUInteger HRFindEclipseHidden(id object, NSUInteger depth, BOOL show) {
  if (depth > kHRMaxWalkDepth) return 0;
  NSUInteger found = 0;
  if ([object isKindOfClass:NSDictionary.class]) {
    NSDictionary *dict = object;
    id hidden = dict[@"isHidden"];
    if ([hidden isKindOfClass:NSNumber.class] && [hidden boolValue]) {
      NSString *postID = HRPostIDFromValue(dict[@"id"]) ?: HRPostIDFromValue(dict[@"postId"]);
      if (postID && HRAccountHiderHid(postID)) {
        if (!show)
          found++;
        else if ([dict isKindOfClass:NSMutableDictionary.class] && HRShowHiddenNode((NSMutableDictionary *)dict))
          found++;
      }
    }
    for (id value in dict.allValues)
      if ([value isKindOfClass:NSDictionary.class] || [value isKindOfClass:NSArray.class])
        found += HRFindEclipseHidden(value, depth + 1, show);
  } else if ([object isKindOfClass:NSArray.class]) {
    for (id value in (NSArray *)object)
      if ([value isKindOfClass:NSDictionary.class] || [value isKindOfClass:NSArray.class])
        found += HRFindEclipseHidden(value, depth + 1, show);
  }
  return found;
}

// Keys never descended into: comment trees, and the user's own lists.
static BOOL HRIsSkippedKey(id key) {
  if (![key isKindOfClass:NSString.class]) return NO;
  NSString *lowered = [(NSString *)key lowercaseString];
  for (NSString *fragment in @[ @"comment", @"saved", @"hidden", @"history", @"upvoted", @"downvoted" ])
    if ([lowered containsString:fragment]) return YES;
  return NO;
}

static void HRWalk(id object, NSUInteger depth, HideReadFeedStats *stats) {
  if (depth > kHRMaxWalkDepth) return;
  if ([object isKindOfClass:NSDictionary.class]) {
    NSDictionary *dict = object;
    for (id key in dict.allKeys) {
      if (HRIsSkippedKey(key)) continue;
      id value = dict[key];
      if ([value isKindOfClass:NSArray.class] && HRLooksLikeEdges(value))
        HRHideReadInEdges(value, dict, stats);  // posts don't nest feeds, so stop here
      else if ([value isKindOfClass:NSDictionary.class] || [value isKindOfClass:NSArray.class])
        HRWalk(value, depth + 1, stats);
    }
  } else if ([object isKindOfClass:NSArray.class]) {
    for (id value in (NSArray *)object)
      if ([value isKindOfClass:NSDictionary.class] || [value isKindOfClass:NSArray.class])
        HRWalk(value, depth + 1, stats);
  }
}

static void HRHideReadPosts(NSDictionary *payload, HideReadFeedStats *stats) {
  for (id key in payload.allKeys) {
    if (HRIsSkippedKey(key)) continue;
    id root = payload[key];
    // A post page (the post plus its comments) is never touched.
    if ([root isKindOfClass:NSDictionary.class] && ((NSDictionary *)root)[@"commentForest"] != nil)
      continue;
    if ([root isKindOfClass:NSDictionary.class] || [root isKindOfClass:NSArray.class])
      HRWalk(root, 1, stats);
  }
}

// Which GraphQL operations may have read posts hidden. Unknown names are
// allowed (they are almost always feeds); lists that belong to the user, post
// pages and lookups by id never are.
static BOOL HRShouldHideInOperation(NSString *operation) {
  if (operation.length == 0) return YES;
  static NSArray<NSString *> *never;
  static dispatch_once_t once;
  dispatch_once(&once, ^{
    never = @[
      @"history", @"saved", @"hidden", @"upvoted", @"downvoted", @"byid", @"comment",
      @"postinfo", @"detail", @"moderat", @"modqueue", @"draft", @"scheduled", @"inbox",
      @"notification", @"message", @"chat"
    ];
  });
  NSString *op = operation.lowercaseString;
  for (NSString *fragment in never)
    if ([op containsString:fragment]) return NO;
  if ([op containsString:@"search"]) return HRPref(HRPrefHideInSearch);
  if ([op containsString:@"profile"] || [op containsString:@"redditor"] ||
      [op containsString:@"userpost"] || [op containsString:@"usersubmitted"])
    return HRPref(HRPrefHideOnProfiles);
  return YES;
}

#pragma mark - Read signals

static BOOL HRIsPageSizeKey(id key) {
  if (![key isKindOfClass:NSString.class]) return NO;
  static NSArray<NSString *> *ignored;
  static NSSet<NSString *> *exact;
  static dispatch_once_t once;
  dispatch_once(&once, ^{
    ignored = @[
      @"depth", @"width", @"height", @"award", @"media", @"image", @"thumbnail", @"preview",
      @"truncat", @"level", @"length", @"char", @"repl"
    ];
    exact = [NSSet setWithArray:@[ @"first", @"count", @"limit", @"size", @"pagesize", @"max", @"maxcount" ]];
  });
  NSString *lowered = [(NSString *)key lowercaseString];
  for (NSString *fragment in ignored)
    if ([lowered containsString:fragment]) return NO;
  if ([exact containsObject:lowered]) return YES;
  return [lowered hasSuffix:@"pagesize"] || [lowered hasSuffix:@"count"] ||
         [lowered hasSuffix:@"limit"];
}

static BOOL HRIsPlainInteger(id value) {
  if (![value isKindOfClass:NSNumber.class]) return NO;
  if (CFGetTypeID((__bridge CFTypeRef)value) == CFBooleanGetTypeID()) return NO;
  const char *type = [(NSNumber *)value objCType];
  return strcmp(type, @encode(double)) != 0 && strcmp(type, @encode(float)) != 0;
}

// Largest page-size-like integer in the GraphQL variables (e.g. {"pageSize": 200}),
// or -1 if there is none.
static NSInteger HRPageSizeHint(id object, NSUInteger depth) {
  if (depth > 4) return -1;
  NSInteger best = -1;
  if ([object isKindOfClass:NSDictionary.class]) {
    NSDictionary *dict = object;
    for (id key in dict) {
      id value = dict[key];
      if (HRIsPageSizeKey(key) && HRIsPlainInteger(value)) {
        NSInteger number = [value integerValue];
        if (number > 0 && number <= 10000 && number > best) best = number;
      } else if ([value isKindOfClass:NSDictionary.class] || [value isKindOfClass:NSArray.class]) {
        best = MAX(best, HRPageSizeHint(value, depth + 1));
      }
    }
  } else if ([object isKindOfClass:NSArray.class]) {
    for (id value in (NSArray *)object) best = MAX(best, HRPageSizeHint(value, depth + 1));
  }
  return best;
}

static void HRCollectCommentIDs(id object, NSUInteger depth, NSMutableSet<NSString *> *ids,
                                NSUInteger *budget) {
  if (depth > 8 || *budget == 0) return;
  (*budget)--;
  if ([object isKindOfClass:NSDictionary.class]) {
    NSDictionary *dict = object;
    id identifier = dict[@"id"];
    if ([identifier isKindOfClass:NSString.class] && [identifier hasPrefix:@"t1_"])
      [ids addObject:identifier];
    for (id value in dict.allValues)
      if ([value isKindOfClass:NSDictionary.class] || [value isKindOfClass:NSArray.class])
        HRCollectCommentIDs(value, depth + 1, ids, budget);
  } else if ([object isKindOfClass:NSArray.class]) {
    for (id value in (NSArray *)object)
      if ([value isKindOfClass:NSDictionary.class] || [value isKindOfClass:NSArray.class])
        HRCollectCommentIDs(value, depth + 1, ids, budget);
  }
}

#pragma mark - Titles

// Titles of posts seen in feeds and post pages: the log and the notes about
// hiding name posts by them, and the scroll tracker matches the post cards on
// screen (scrolled past or tapped) against them. Filled while the log, "You Open
// It" or "You Scroll Past It" is on.
static os_unfair_lock gTitleLock = OS_UNFAIR_LOCK_INIT;
static NSMutableDictionary<NSString *, NSString *> *gTitles;    // post id -> title, for the log
static NSMutableDictionary<NSString *, NSString *> *gTitleIDs;  // normalized title -> post id
// Normalized titles seen for more than one post (crossposts, reposts, "Daily
// Thread"): a card with such a title isn't matched at all, rather than risk
// counting the other post.
static NSMutableSet<NSString *> *gSharedTitles;
static NSMutableArray<NSString *> *gTitleOrder;                 // post ids, oldest first

// Lowercased, with runs of whitespace collapsed to one space.
static NSString *HRNormalizedText(NSString *text) {
  NSArray<NSString *> *words =
      [text.lowercaseString componentsSeparatedByCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
  NSMutableArray<NSString *> *kept = [NSMutableArray arrayWithCapacity:words.count];
  for (NSString *word in words)
    if (word.length) [kept addObject:word];
  return [kept componentsJoinedByString:@" "];
}

// A post card's title: its title cell's ("TitleCell" and the like), else the
// post's own (cards that carry the post, and post pages), else the shallowest
// "title" anywhere. Taking the shallowest one first could pick up something
// else's title, such as a recommendation's ("Because you visited r/...").
static NSString *HRFindTitle(id root) {
  NSString *postTitle = nil, *anyTitle = nil;
  NSMutableArray<NSArray *> *queue = [NSMutableArray arrayWithObject:@[ root, @0 ]];
  for (NSUInteger head = 0; head < queue.count && head < 400; head++) {
    id object = queue[head][0];
    NSUInteger depth = [queue[head][1] unsignedIntegerValue];
    NSArray *children = nil;
    if ([object isKindOfClass:NSDictionary.class]) {
      NSDictionary *dict = object;
      id title = dict[@"title"];
      id type = dict[@"__typename"];
      if ([title isKindOfClass:NSString.class] && [(NSString *)title length] > 0) {
        BOOL typed = [type isKindOfClass:NSString.class];
        if (typed && [(NSString *)type containsString:@"Title"]) return title;
        if (typed && !postTitle && [(NSString *)type hasSuffix:@"Post"]) postTitle = title;
        else if (!anyTitle) anyTitle = title;
      }
      children = dict.allValues;
    } else if ([object isKindOfClass:NSArray.class]) {
      children = object;
    }
    if (depth >= 5) continue;
    for (id child in children)
      if ([child isKindOfClass:NSDictionary.class] || [child isKindOfClass:NSArray.class])
        [queue addObject:@[ child, @(depth + 1) ]];
  }
  return postTitle ?: anyTitle;
}

static void HRRememberTitle(NSString *postID, id node) {
  NSString *title = HRFindTitle(node);
  if (!postID || !title) return;
  NSString *normalized = HRNormalizedText(title);
  NSString *shown = title.length > 60 ? [[title substringToIndex:57] stringByAppendingString:@"..."] : title;
  os_unfair_lock_lock(&gTitleLock);
  if (!gTitles) {
    gTitles = [NSMutableDictionary dictionary];
    gTitleIDs = [NSMutableDictionary dictionary];
    gTitleOrder = [NSMutableArray array];
    gSharedTitles = [NSMutableSet set];
  }
  if (!gTitles[postID]) [gTitleOrder addObject:postID];
  gTitles[postID] = shown;
  if (normalized.length) {
    NSString *existing = gTitleIDs[normalized];
    if (existing && ![existing isEqualToString:postID]) [gSharedTitles addObject:normalized];
    gTitleIDs[normalized] = postID;
  }
  // Keep the most recent 2,000 posts: the ones on screen are always among them.
  if (gTitleOrder.count > 2000) {
    NSArray<NSString *> *dropped = [gTitleOrder subarrayWithRange:NSMakeRange(0, 500)];
    [gTitleOrder removeObjectsInRange:NSMakeRange(0, 500)];
    NSSet<NSString *> *droppedSet = [NSSet setWithArray:dropped];
    [gTitles removeObjectsForKeys:dropped];
    NSArray *staleTitles = [gTitleIDs keysOfEntriesPassingTest:^BOOL(id key, id value, BOOL *stop) {
      return [droppedSet containsObject:value];
    }].allObjects;
    [gTitleIDs removeObjectsForKeys:staleTitles];
    [gSharedTitles minusSet:[NSSet setWithArray:staleTitles]];
  }
  os_unfair_lock_unlock(&gTitleLock);
}

// Whether `range` of `text` is a whole run of its comma-separated parts ("r/sub,
// A title, with a comma, 12 upvotes"): at the start or right after ", ", and at
// the end or right before ", ". A title that's only part of another title, or of
// a sentence, doesn't count.
static BOOL HRIsWholeParts(NSString *text, NSRange range) {
  NSUInteger end = NSMaxRange(range);
  BOOL startsPart = range.location == 0 ||
                    (range.location >= 2 && [text rangeOfString:@", " options:NSAnchoredSearch
                                                          range:NSMakeRange(range.location - 2, 2)]
                                                    .location != NSNotFound);
  BOOL endsPart = end == text.length ||
                  (end + 2 <= text.length &&
                   [text rangeOfString:@", " options:NSAnchoredSearch range:NSMakeRange(end, 2)].location != NSNotFound);
  return startsPart && endsPart;
}

NSString *HRPostIDForText(NSString *text, BOOL searchInside) {
  NSString *normalized = HRNormalizedText(text ?: @"");
  if (normalized.length < 3) return nil;
  NSString *postID = nil;
  os_unfair_lock_lock(&gTitleLock);
  // The whole text, or one of its comma-separated parts ("r/sub, Title, 12
  // upvotes"). Titles more than one post has are never matched.
  if (![gSharedTitles containsObject:normalized]) postID = gTitleIDs[normalized];
  if (!postID)
    for (NSString *part in [normalized componentsSeparatedByString:@", "])
      if (![gSharedTitles containsObject:part] && (postID = gTitleIDs[part])) break;
  // Otherwise the longest known title that's a whole run of the text's parts (a
  // title with a comma in it).
  if (!postID && searchInside) {
    NSUInteger best = 0;
    for (NSString *title in gTitleIDs) {
      if (title.length < 8 || title.length <= best || title.length > normalized.length ||
          [gSharedTitles containsObject:title])
        continue;
      NSRange range = [normalized rangeOfString:title];
      if (range.location == NSNotFound || !HRIsWholeParts(normalized, range)) continue;
      best = title.length;
      postID = gTitleIDs[title];
    }
  }
  os_unfair_lock_unlock(&gTitleLock);
  return postID;
}

NSString *HRPostTitle(NSString *postID) {
  if (!postID) return nil;
  os_unfair_lock_lock(&gTitleLock);
  NSString *title = gTitles[postID];
  os_unfair_lock_unlock(&gTitleLock);
  return title;
}

// " “Title”" for the log, or "" when the title isn't known.
static NSString *HRTitleSuffix(NSString *postID) {
  NSString *title = HRPostTitle(postID);
  return title ? [NSString stringWithFormat:@" “%@”", title] : @"";
}

NSString *HRDescribePost(NSString *postID) {
  return [postID stringByAppendingString:HRTitleSuffix(postID)];
}

#pragma mark - Read detection

// Diagnostics: a request's variables with ids and long text blanked out, so the
// log shows how Reddit asks for a post's page or comments (a preload and a real
// open may differ). Logged once per distinct shape.
static NSString *HRDescribeVariables(id object, NSUInteger depth) {
  if ([object isKindOfClass:NSDictionary.class]) {
    if (depth >= 3) return @"{...}";
    NSDictionary *dict = object;
    NSMutableArray<NSString *> *parts = [NSMutableArray array];
    for (id key in [dict.allKeys sortedArrayUsingSelector:@selector(compare:)])
      [parts addObject:[NSString stringWithFormat:@"%@: %@", key,
                                                  HRDescribeVariables(dict[key], depth + 1)]];
    return [NSString stringWithFormat:@"{%@}", [parts componentsJoinedByString:@", "]];
  }
  if ([object isKindOfClass:NSArray.class]) {
    NSArray *array = object;
    if (array.count == 0) return @"[]";
    return [NSString stringWithFormat:@"[%@%@]", HRDescribeVariables(array.firstObject, depth + 1),
                                      array.count > 1 ? @", ..." : @""];
  }
  if ([object isKindOfClass:NSString.class]) {
    NSString *string = object;
    if (HRPostIDFromValue(string) || [string hasPrefix:@"t1_"]) return @"<id>";
    if (string.length > 24) return @"<text>";
    return [NSString stringWithFormat:@"\"%@\"", string];
  }
  if ([object isKindOfClass:NSNumber.class]) {
    if (CFGetTypeID((__bridge CFTypeRef)object) == CFBooleanGetTypeID())
      return [object boolValue] ? @"true" : @"false";
    // Nested numbers are counters (ads seen, posts seen) that change every time.
    return depth >= 2 ? @"#" : [object stringValue];
  }
  return object == NSNull.null ? @"null" : @"?";
}

// Operations that load a post's own page. PostInfoById brings the post itself;
// the Pdp... ones (e.g. PdpCommentsAds) only run for an open post page.
static BOOL HRIsPostPageOperation(NSString *operation) {
  return [operation isEqualToString:@"PostInfoById"] || [operation hasPrefix:@"Pdp"];
}

// How Jax Reddit Eclipse tells that you opened a post:
//  - A post page load (see HRIsPostPageOperation) sent after a post screen
//    appeared, and the first such load for that screen. Pages Reddit loads
//    ahead for other posts don't count.
//  - A comment load with more than 8 comments. Reddit preloads comments for
//    posts sitting in the feed, asking for 200 like a real load, but a preload
//    never returns more than 8. A load that asks for a truncated tree
//    (isTruncatedFetch) is always a preload.
//  - A comment load sent after a post screen appeared, and the first load for
//    that screen.
// Any other comment load is a preload for a post that stayed on screen in the
// feed, which only counts with "It Stays on Screen" on.
static void HRRecordReadSignals(NSString *operation, NSDictionary *variables,
                                NSDictionary *payload, CFAbsoluteTime requestTime) {
  BOOL markOpened = HRPref(HRPrefMarkOpened);
  BOOL markLingered = HRPref(HRPrefMarkLingered);
  if (!markOpened && !markLingered) return;
  BOOL diagnostics = HRPref(HRPrefDiagnostics);
  HideReadStore *store = HideReadStore.sharedStore;

  BOOL postPageOperation = HRIsPostPageOperation(operation);
  BOOL commentsOperation = [operation isEqualToString:@"PostInfoByIdComments"];
  if (diagnostics && variables && (postPageOperation || commentsOperation)) {
    NSString *shape = HRDescribeVariables(variables, 0);
    HRLogOnce([NSString stringWithFormat:@"vars:%@:%@", operation, shape], @"[vars] %@ %@",
              operation, shape);
  }

  if (postPageOperation) {
    // PostInfoById answers with the post; the Pdp... operations only say in
    // their request which post the page is for.
    NSString *postID = nil;
    if ([operation isEqualToString:@"PostInfoById"]) {
      for (id key in payload) {
        id root = payload[key];
        if (![root isKindOfClass:NSDictionary.class]) continue;
        postID = HRPostIDFromValue(((NSDictionary *)root)[@"id"]);
        if (postID) {
          if (diagnostics || markOpened || HRPref(HRPrefMarkScrolledPast)) HRRememberTitle(postID, root);
          HRCheckOwnPost(postID, root);
          break;
        }
      }
    }
    if (!postID && variables) postID = HRSinglePostIDInside(variables, 4, YES);
    if (!postID) return;
    if (HRIsOwnPost(postID)) {
      HRLogOnce([@"own:" stringByAppendingString:postID], @"[own] %@ is your post, so it's never counted as read",
                HRDescribePost(postID));
      return;
    }
    BOOL alreadyRead = [store containsPostID:postID];
    if (HRScreenTrackerClaimPostScreen(kHRPostScreenWindow, requestTime)) {
      if (markOpened && [store markPostID:postID]) {
        HRLog(@"[read] %@%@ opened (post page loaded; %@)", postID, HRTitleSuffix(postID),
              operation);
        HRShowReadHintIfNeeded();
      }
    } else if (!alreadyRead) {
      HRLog(@"[skip] %@%@ post page loaded by %@, but not right after a post screen opened",
            postID, HRTitleSuffix(postID), operation);
    }
    return;
  }

  // The next page of a post's comments ("N more replies"): that post is already open.
  for (NSString *cursorKey in @[ @"after", @"cursor" ]) {
    id cursor = variables[cursorKey];
    if ([cursor isKindOfClass:NSString.class] && [(NSString *)cursor length] > 0) return;
  }

  for (id key in payload) {
    id root = payload[key];
    if (![root isKindOfClass:NSDictionary.class]) continue;
    id forest = ((NSDictionary *)root)[@"commentForest"];
    BOOL hasForest = [forest isKindOfClass:NSDictionary.class];
    // A post with no comments comes back without a commentForest at all.
    if (!hasForest && !commentsOperation) continue;

    NSString *postID = HRPostIDFromValue(((NSDictionary *)root)[@"id"]);
    if (!postID && variables) postID = HRSinglePostIDInside(variables, 4, YES);
    if (!postID) {
      HRLog(@"[read] comments loaded by %@, but the post id is missing",
            operation ?: @"an unnamed operation");
      continue;
    }
    if (HRCheckOwnPost(postID, root)) {
      HRLogOnce([@"own:" stringByAppendingString:postID], @"[own] %@ is your post, so it's never counted as read",
                HRDescribePost(postID));
      continue;
    }
    BOOL alreadyRead = [store containsPostID:postID];

    NSMutableSet<NSString *> *commentIDs = [NSMutableSet set];
    NSUInteger budget = 5000;
    if (hasForest) HRCollectCommentIDs(forest, 0, commentIDs, &budget);
    NSUInteger comments = commentIDs.count;
    NSInteger pageSize = variables ? HRPageSizeHint(variables, 0) : -1;  // for the log only

    NSString *lowerOperation = operation.lowercaseString ?: @"";
    // Reddit marks its own preloads: they ask for a truncated comment tree.
    id truncated = variables[@"isTruncatedFetch"];
    BOOL namedPreload = [lowerOperation containsString:@"prefetch"] ||
                        [lowerOperation containsString:@"preload"] ||
                        ([truncated isKindOfClass:NSNumber.class] && [truncated boolValue]);
    BOOL fullLoad = !namedPreload && comments > kHRPreloadMaxComments;
    BOOL claimedScreen =
        !namedPreload && HRScreenTrackerClaimPostScreen(kHRPostScreenWindow, requestTime);

    NSString *details = [NSString
        stringWithFormat:@"%@, %lu comments, page size %@", operation ?: @"unnamed operation",
                         (unsigned long)comments,
                         pageSize > 0 ? [NSString stringWithFormat:@"%ld", (long)pageSize] : @"?"];
    NSString *title = HRTitleSuffix(postID);
    if (markOpened && (fullLoad || claimedScreen)) {
      if ([store markPostID:postID]) {
        HRLog(@"[read] %@%@ opened (%@; %@)", postID, title,
              fullLoad ? @"more comments than a preload" : @"post screen just opened", details);
        HRShowReadHintIfNeeded();
      }
    } else if (markLingered) {
      if ([store markPostID:postID]) {
        HRLog(@"[read] %@%@ stayed on screen (comment preload; %@)", postID, title, details);
        HRScrollTrackerPostHidden();
      }
    } else if (!alreadyRead) {
      HRLog(@"[skip] %@%@ comment preload, not counted (%@)", postID, title, details);
    }
  }
}

#pragma mark - Requests

static void HRParseRequest(NSURLRequest *request, NSData *body, NSString **operationOut,
                           NSDictionary **variablesOut) {
  NSString *operation = [request valueForHTTPHeaderField:@"X-APOLLO-OPERATION-NAME"];
  NSDictionary *variables = nil;

  if (body.length > 0 && body.length < 1024 * 1024) {
    id json = [NSJSONSerialization JSONObjectWithData:body options:0 error:NULL];
    if ([json isKindOfClass:NSDictionary.class]) {
      id name = ((NSDictionary *)json)[@"operationName"];
      if (operation.length == 0 && [name isKindOfClass:NSString.class]) operation = name;
      id vars = ((NSDictionary *)json)[@"variables"];
      if ([vars isKindOfClass:NSDictionary.class]) variables = vars;
    }
  }

  if (operation.length == 0 || !variables) {
    NSURLComponents *components = [NSURLComponents componentsWithURL:request.URL
                                             resolvingAgainstBaseURL:NO];
    for (NSURLQueryItem *item in components.queryItems) {
      if (operation.length == 0 && [item.name isEqualToString:@"operationName"]) {
        operation = item.value;
      } else if (!variables && [item.name isEqualToString:@"variables"] && item.value.length > 0) {
        id vars = [NSJSONSerialization JSONObjectWithData:[item.value dataUsingEncoding:NSUTF8StringEncoding]
                                                  options:0
                                                    error:NULL];
        if ([vars isKindOfClass:NSDictionary.class]) variables = vars;
      }
    }
  }

  if (operationOut) *operationOut = operation.length > 0 ? operation : nil;
  if (variablesOut) *variablesOut = variables;
}

NSString *HROperationName(NSURLRequest *request, NSData *body) {
  NSString *operation = nil;
  HRParseRequest(request, body, &operation, NULL);
  return operation;
}

// Lookups of posts by id: the details the app refreshes for posts on screen
// ("FeedPostDetailsByIds"), a post's page ("PostInfoById", "Pdp..."). Never
// feeds, but they say whether each post is hidden on your account: posts Jax
// Reddit Eclipse hid there are shown to the app as not hidden in them, as the app
// would turn a post on screen into a "Post hidden / Undo" row as soon as it
// heard. They leave the feed the next time it loads, like any read post.
static BOOL HRIsPostLookupOperation(NSString *operation) {
  NSString *op = operation.lowercaseString;
  if ([op hasPrefix:@"pdp"]) return YES;
  return [op containsString:@"post"] &&
         ([op containsString:@"byid"] || [op containsString:@"detail"] || [op containsString:@"postinfo"]);
}

// Operations that carry a post's page or comments: the read signals.
static BOOL HRIsReadSignalOperation(NSString *operation) {
  return [operation hasPrefix:@"PostInfoById"] || [operation hasPrefix:@"Pdp"];
}

// Telemetry, config and account calls that never contain posts. Their
// responses go to the app (and any other tweak) without Jax Reddit Eclipse touching them.
static BOOL HRIsIgnoredOperation(NSString *operation) {
  static NSSet<NSString *> *ignored;
  static dispatch_once_t once;
  dispatch_once(&once, ^{
    ignored = [NSSet setWithArray:@[
      @"Age", @"AdsOffRedditLocation", @"AdsOffRedditPreferences", @"AwardProductOffers",
      @"BadgeCounts", @"BadgeCountsV2", @"BlockedRedditors", @"BrandToolsStatus",
      @"CookiePreferences", @"DynamicConfigsByNames", @"EnrollInGamification",
      @"ExposeExperimentBatch", @"FeaturedDevvitGame", @"FeedPostDetailsByIds",
      @"FetchIdentityPreferences", @"FetchSubscribedSubreddits", @"GamesPreferences",
      @"GetAccount", @"GetActiveSubreddits", @"GetAllExperimentVariants",
      @"GetEligibleUXExperiences", @"GetMyShowcaseCarousel", @"GetProfilePostFlairTemplates",
      @"GetRedditUsersByIds", @"GetRedditorByNameApollo", @"GetUserAdEligibility",
      @"GoldBalances", @"LastModeratedSubredditName", @"ModQueueNewItemCount",
      @"NotificationInbox", @"PaymentSubscriptions", @"PostDraftsCount", @"RecommendedPrompts",
      @"RegisterMobilePushToken", @"SubredditDevvitInfo", @"SubredditsForIds",
      @"SubredditsForNames", @"TrendingSearchesQuery", @"UserLocation", @"UserPublicTrophies",
    ]];
  });
  return [ignored containsObject:operation];
}

BOOL HRShouldWatchOperation(NSString *operation) {
  if (operation.length == 0) return NO;
  BOOL track = HRPref(HRPrefMarkOpened) || HRPref(HRPrefMarkLingered);
  if (track && HRIsReadSignalOperation(operation)) return YES;
  if (!HRPref(HRPrefEnabled)) return NO;
  return HRIsPostLookupOperation(operation) ||
         (!HRIsIgnoredOperation(operation) && HRShouldHideInOperation(operation));
}

BOOL HRIsRedditHost(NSString *host) {
  host = host.lowercaseString;
  return [host isEqualToString:@"reddit.com"] || [host hasSuffix:@".reddit.com"];
}

// Reddit's API hosts: gql.reddit.com, gql-fed.reddit.com, oauth.reddit.com, and
// cf.gql-fed.reddit.com, the Cloudflare route some accounts get moved onto. Any
// label of the host starting with "gql" or "oauth" counts.
BOOL HRShouldProcessRequest(NSURLRequest *request) {
  NSString *host = request.URL.host.lowercaseString;
  if (!host || ![host hasSuffix:@".reddit.com"]) return NO;
  NSString *subdomains = [host substringToIndex:host.length - @".reddit.com".length];
  for (NSString *label in [subdomains componentsSeparatedByString:@"."])
    if ([label hasPrefix:@"gql"] || [label hasPrefix:@"oauth"]) return YES;
  return NO;
}

static _Atomic(NSUInteger) gFeedPostsSeen;

NSUInteger HRFeedPostsSeenCount(void) {
  return atomic_load(&gFeedPostsSeen);
}

NSData *HRProcessResponse(NSURLRequest *request, NSData *body, NSData *data,
                          CFAbsoluteTime requestTime) {
  BOOL hide = HRPref(HRPrefEnabled);
  BOOL track = HRPref(HRPrefMarkOpened) || HRPref(HRPrefMarkLingered);
  if ((!hide && !track) || data.length == 0) return data;

  @try {
    id json = [NSJSONSerialization JSONObjectWithData:data
                                              options:NSJSONReadingMutableContainers
                                                error:NULL];
    if (![json isKindOfClass:NSDictionary.class]) return data;
    id payload = ((NSDictionary *)json)[@"data"];
    if (![payload isKindOfClass:NSDictionary.class]) return data;

    NSString *operation = nil;
    NSDictionary *variables = nil;
    HRParseRequest(request, body, &operation, &variables);
    NSString *name = operation ?: @"unnamed operation";
    HRLogOnce([@"api:" stringByAppendingString:name], @"[api] %@ (%@)", name, request.URL.host);

    if (track) HRRecordReadSignals(operation, variables, payload, requestTime);
    if (!hide) return data;
    BOOL changed = NO;
    if (HRIsPostLookupOperation(operation)) {
      NSUInteger shown = HRFindEclipseHidden(payload, 0, YES);
      if (shown) {
        HRLog(@"[feed] %@: %lu posts hidden on your account left as posts (no \"Post hidden\" rows)", name,
              (unsigned long)shown);
        changed = YES;
      }
    }
    if (!HRShouldHideInOperation(operation)) {
      if (!changed) return data;
      NSData *modified = [NSJSONSerialization dataWithJSONObject:json
                                                         options:NSJSONWritingWithoutEscapingSlashes
                                                           error:NULL];
      return modified ?: data;
    }

    HideReadFeedStats *stats = [HideReadFeedStats new];
    stats.diagnostics = HRPref(HRPrefDiagnostics);
    stats.rememberTitles = stats.diagnostics || HRPref(HRPrefMarkOpened) || HRPref(HRPrefMarkScrolledPast);
    HRHideReadPosts(payload, stats);
    atomic_fetch_add(&gFeedPostsSeen, stats.posts);
    if (stats.listedPosts.count) {
      id after = variables[@"after"];
      HRNoteFeedOrder(stats.listedPosts, [after isKindOfClass:NSString.class] ? after : nil, stats.listedCursor);
    }
    if (stats.shown)
      HRLog(@"[feed] %@: %lu hidden posts left as posts (yours, or the one a page needs to keep loading)", name,
            (unsigned long)stats.shown);
    if (stats.keptHiddenRow)
      HRLog(@"[feed] %@: nothing else left on this page, so one \"Post hidden\" row stays for the feed to keep "
            @"loading",
            name);
    if (stats.diagnostics && !HRIsPostLookupOperation(operation)) {
      NSUInteger left = HRFindEclipseHidden(payload, 0, NO);
      if (left)
        HRLogOnce([@"marked-hidden:" stringByAppendingString:name],
                  @"[feed] %@ still marks %lu posts hidden by Jax Reddit Eclipse as hidden", name, (unsigned long)left);
    }
    if (stats.posts > 0 || stats.alreadyHidden > 0)
      HRLog(@"[feed] %@: hid %lu of %lu posts%@%@%@%@", name, (unsigned long)stats.hidden,
            (unsigned long)stats.posts,
            stats.crossposts ? [NSString stringWithFormat:@" (%lu crossposts of posts you've read)",
                                                          (unsigned long)stats.crossposts]
                             : @"",
            stats.alreadyHidden ? [NSString stringWithFormat:@", and took out %lu Reddit marks as hidden",
                                                             (unsigned long)stats.alreadyHidden]
                                : @"",
            stats.hiddenTitles.count ? @": " : @"",
            stats.hiddenTitles.count ? [stats.hiddenTitles componentsJoinedByString:@", "] : @"");
    if (stats.unrecognized > 0)
      HRLog(@"[feed] %@: %lu items without a single post id, e.g. %@", name,
            (unsigned long)stats.unrecognized, stats.unrecognizedSample ?: @"?");
    if (stats.posts == 0 && stats.unrecognized == 0 &&
        ([name containsString:@"Feed"] || [name containsString:@"Sdui"]))
      HRLogOnce([@"empty:" stringByAppendingString:name],
                @"[feed] %@: no feed items found (top-level fields: %@)", name,
                [[payload allKeys] componentsJoinedByString:@", "]);
    if (stats.hidden == 0 && stats.alreadyHidden == 0 && stats.shown == 0 && !changed) return data;

    NSData *modified = [NSJSONSerialization dataWithJSONObject:json
                                                       options:NSJSONWritingWithoutEscapingSlashes
                                                         error:NULL];
    return modified ?: data;
  } @catch (NSException *exception) {
    HRLog(@"[error] %@: %@", exception.name, exception.reason);
    return data;
  }
}

#pragma mark - Feed order

// The posts each feed list shows, in order, as Jax Reddit Eclipse handed them to
// the app (a feed's pages joined up by their cursors), so the scroll tracker can
// tell which posts are above the topmost card on screen: every one of them was
// scrolled past, however fast it went by. The last 20 lists, 3,000 posts each.
static os_unfair_lock gOrderLock = OS_UNFAIR_LOCK_INIT;
static NSMutableArray<NSMutableDictionary *> *gOrders;  // newest last

static void HRNoteFeedOrder(NSArray<NSString *> *posts, NSString *after, NSString *endCursor) {
  if (!posts.count) return;
  os_unfair_lock_lock(&gOrderLock);
  if (!gOrders) gOrders = [NSMutableArray array];
  NSMutableDictionary *order = nil;
  if (after.length)
    for (NSMutableDictionary *candidate in gOrders.reverseObjectEnumerator)
      if ([candidate[@"cursor"] isEqual:after]) {
        order = candidate;
        break;
      }
  if (order) {
    [gOrders removeObjectIdenticalTo:order];
  } else {
    order = [NSMutableDictionary dictionary];
    order[@"posts"] = [NSMutableArray array];
    order[@"index"] = [NSMutableDictionary dictionary];
    order[@"taken"] = @0;
  }
  [gOrders addObject:order];
  if (gOrders.count > 20) [gOrders removeObjectAtIndex:0];
  NSMutableArray<NSString *> *list = order[@"posts"];
  NSMutableDictionary<NSString *, NSNumber *> *index = order[@"index"];
  for (NSString *postID in posts) {
    if (index[postID] || list.count >= 3000) continue;
    index[postID] = @(list.count);
    [list addObject:postID];
  }
  if (endCursor.length)
    order[@"cursor"] = endCursor;
  else
    [order removeObjectForKey:@"cursor"];
  os_unfair_lock_unlock(&gOrderLock);
}

NSArray<NSString *> *HRTakePostsListedBefore(NSString *postID, NSArray<NSString *> *below) {
  NSMutableArray<NSString *> *taken = [NSMutableArray array];
  if (!postID) return taken;
  os_unfair_lock_lock(&gOrderLock);
  NSMutableDictionary *best = nil;
  NSUInteger bestScore = 0;
  for (NSMutableDictionary *order in gOrders.reverseObjectEnumerator) {  // newest first
    NSNumber *at = order[@"index"][postID];
    if (!at) continue;
    NSUInteger score = 0;
    for (NSString *other in below) {
      NSNumber *otherAt = order[@"index"][other];
      if (otherAt && otherAt.unsignedIntegerValue > at.unsignedIntegerValue) score++;
    }
    if (score > bestScore) {
      best = order;
      bestScore = score;
    }
  }
  if (best) {
    NSUInteger at = [best[@"index"][postID] unsignedIntegerValue];
    NSUInteger from = [best[@"taken"] unsignedIntegerValue];
    if (at > from) {
      [taken addObjectsFromArray:[best[@"posts"] subarrayWithRange:NSMakeRange(from, at - from)]];
      best[@"taken"] = @(at);
    }
  }
  os_unfair_lock_unlock(&gOrderLock);
  return taken;
}

#pragma mark - Topping up thin pages

// When most of a feed page is posts you've read, what's left can be too short to
// scroll, and Reddit only loads more when you scroll near the end. So a page
// that would be left with fewer than six unread posts gets the next page fetched
// and merged in before the app sees it.

static NSString *const kHRTopUpRequestKey = @"HideReadTopUpRequest";
static const NSUInteger kHRMinimumUnreadPosts = 6;

// The list in a feed response: data.<root>.elements, holding edges and pageInfo.
static NSMutableDictionary *HRFeedElements(NSDictionary *json) {
  id payload = json[@"data"];
  if (![payload isKindOfClass:NSDictionary.class]) return nil;
  for (id root in [(NSDictionary *)payload allValues]) {
    if (![root isKindOfClass:NSDictionary.class]) continue;
    id elements = ((NSDictionary *)root)[@"elements"];
    if ([elements isKindOfClass:NSMutableDictionary.class] &&
        [((NSDictionary *)elements)[@"edges"] isKindOfClass:NSArray.class])
      return elements;
  }
  return nil;
}

BOOL HRIsTopUpRequest(NSURLRequest *request) {
  return [[NSURLProtocol propertyForKey:kHRTopUpRequestKey inRequest:request] boolValue];
}

NSURLRequest *HRFeedTopUpRequest(NSURLRequest *request, NSData *body, NSData *page) {
  if (!HRPref(HRPrefEnabled) || HRIsTopUpRequest(request) || body.length == 0 ||
      body.length > 1024 * 1024 || page.length == 0)
    return nil;
  NSString *operation = HROperationName(request, body);
  if (![operation containsString:@"Feed"] || !HRShouldHideInOperation(operation)) return nil;

  @try {
    NSMutableDictionary *requestJSON = [NSJSONSerialization JSONObjectWithData:body
                                                                       options:NSJSONReadingMutableContainers
                                                                         error:NULL];
    if (![requestJSON isKindOfClass:NSMutableDictionary.class]) return nil;
    NSMutableDictionary *variables = requestJSON[@"variables"];
    if (![variables isKindOfClass:NSMutableDictionary.class]) return nil;

    NSDictionary *json = [NSJSONSerialization JSONObjectWithData:page options:0 error:NULL];
    if (![json isKindOfClass:NSDictionary.class]) return nil;
    id payload = json[@"data"];
    if (![payload isKindOfClass:NSDictionary.class]) return nil;
    NSDictionary *elements = nil;
    for (id root in [(NSDictionary *)payload allValues]) {
      id candidate = [root isKindOfClass:NSDictionary.class] ? ((NSDictionary *)root)[@"elements"] : nil;
      if ([candidate isKindOfClass:NSDictionary.class] &&
          [((NSDictionary *)candidate)[@"edges"] isKindOfClass:NSArray.class]) {
        elements = candidate;
        break;
      }
    }
    NSDictionary *pageInfo = elements[@"pageInfo"];
    if (![pageInfo isKindOfClass:NSDictionary.class] || !HRHasMorePages(elements)) return nil;
    NSString *cursor = pageInfo[@"endCursor"];
    if (![cursor isKindOfClass:NSString.class] || cursor.length == 0) return nil;

    HideReadStore *store = HideReadStore.sharedStore;
    NSUInteger unread = 0;
    for (id edge in elements[@"edges"]) {
      NSDictionary *node = [edge isKindOfClass:NSDictionary.class] ? ((NSDictionary *)edge)[@"node"] : nil;
      if (![node isKindOfClass:NSDictionary.class] || HRIsAlreadyHidden(node)) continue;
      NSString *postID = HRPostIDForNode(node);
      if (postID && (HRIsOwnPost(postID) || ![store containsPostID:postID])) unread++;
    }
    if (unread >= kHRMinimumUnreadPosts) return nil;

    variables[@"after"] = cursor;
    NSData *newBody = [NSJSONSerialization dataWithJSONObject:requestJSON
                                                      options:NSJSONWritingWithoutEscapingSlashes
                                                        error:NULL];
    if (!newBody) return nil;
    NSMutableURLRequest *next = [request mutableCopy];
    next.HTTPBody = newBody;
    [next setValue:[NSString stringWithFormat:@"%lu", (unsigned long)newBody.length]
        forHTTPHeaderField:@"Content-Length"];
    [NSURLProtocol setProperty:@YES forKey:kHRTopUpRequestKey inRequest:next];
    HRLog(@"[feed] %@: only %lu unread posts on this page, loading the next one too", operation,
          (unsigned long)unread);
    return next;
  } @catch (NSException *exception) {
    HRLog(@"[feed] couldn't prepare the next page: %@", exception.reason);
    return nil;
  }
}

NSData *HRMergeFeedPages(NSData *page, NSData *nextPage) {
  if (page.length == 0 || nextPage.length == 0) return nil;
  @try {
    NSMutableDictionary *first = [NSJSONSerialization JSONObjectWithData:page
                                                                 options:NSJSONReadingMutableContainers
                                                                   error:NULL];
    NSMutableDictionary *next = [NSJSONSerialization JSONObjectWithData:nextPage
                                                                options:NSJSONReadingMutableContainers
                                                                  error:NULL];
    if (![first isKindOfClass:NSMutableDictionary.class] || ![next isKindOfClass:NSMutableDictionary.class])
      return nil;
    NSMutableDictionary *firstElements = HRFeedElements(first);
    NSMutableDictionary *nextElements = HRFeedElements(next);
    NSArray *edges = firstElements[@"edges"];
    NSArray *moreEdges = nextElements[@"edges"];
    NSDictionary *pageInfo = nextElements[@"pageInfo"];
    if (!edges || !moreEdges || ![pageInfo isKindOfClass:NSDictionary.class]) return nil;

    // A post can come back on the next page too. The same item twice in one
    // list could upset the app, so repeats are left out.
    NSMutableSet *ids = [NSMutableSet set];
    for (id edge in edges) {
      id nodeID = [edge isKindOfClass:NSDictionary.class] ? ((NSDictionary *)edge)[@"node"] : nil;
      nodeID = [nodeID isKindOfClass:NSDictionary.class] ? ((NSDictionary *)nodeID)[@"id"] : nil;
      if ([nodeID isKindOfClass:NSString.class]) [ids addObject:nodeID];
    }
    NSMutableArray *merged = [edges mutableCopy];
    NSUInteger repeats = 0;
    for (id edge in moreEdges) {
      id node = [edge isKindOfClass:NSDictionary.class] ? ((NSDictionary *)edge)[@"node"] : nil;
      id nodeID = [node isKindOfClass:NSDictionary.class] ? ((NSDictionary *)node)[@"id"] : nil;
      if ([nodeID isKindOfClass:NSString.class]) {
        if ([ids containsObject:nodeID]) {
          repeats++;
          continue;
        }
        [ids addObject:nodeID];
      }
      [merged addObject:edge];
    }
    firstElements[@"edges"] = merged;
    firstElements[@"pageInfo"] = pageInfo;
    HRLog(@"[feed] merged the next page: %lu items added, %lu repeats left out",
          (unsigned long)(moreEdges.count - repeats), (unsigned long)repeats);
    return [NSJSONSerialization dataWithJSONObject:first
                                           options:NSJSONWritingWithoutEscapingSlashes
                                             error:NULL];
  } @catch (NSException *exception) {
    HRLog(@"[feed] couldn't merge the next page: %@", exception.reason);
    return nil;
  }
}
