#import "HideReadStore.h"
#import "HRAccountHider.h"
#import "HROwnPosts.h"
#import <os/lock.h>

static const NSTimeInterval kHRMaxAge = 90 * 24 * 60 * 60;
static const NSUInteger kHRMaxEntries = 20000;
static const NSUInteger kHRTrimSlack = 500;
static const int64_t kHRSaveDelay = 2 * NSEC_PER_SEC;

@implementation HideReadStore {
  os_unfair_lock _lock;
  NSMutableDictionary<NSString *, NSNumber *> *_entries;  // post id -> time last read
  dispatch_queue_t _ioQueue;
  BOOL _dirty;
  BOOL _saveScheduled;
  NSUInteger _sessionCount;
}

+ (HideReadStore *)sharedStore {
  static HideReadStore *store;
  static dispatch_once_t once;
  dispatch_once(&once, ^{
    store = [self new];
  });
  return store;
}

+ (NSURL *)fileURL {
  NSURL *support = [NSFileManager.defaultManager URLsForDirectory:NSApplicationSupportDirectory
                                                        inDomains:NSUserDomainMask]
                       .firstObject;
  return [[support URLByAppendingPathComponent:@"HideRead" isDirectory:YES]
      URLByAppendingPathComponent:@"ReadPosts.plist"
                      isDirectory:NO];
}

- (instancetype)init {
  if ((self = [super init])) {
    _lock = OS_UNFAIR_LOCK_INIT;
    _ioQueue = dispatch_queue_create("com.jax.reddit-eclipse.store", DISPATCH_QUEUE_SERIAL);
    _entries = [self loadEntries];
  }
  return self;
}

- (NSMutableDictionary<NSString *, NSNumber *> *)loadEntries {
  NSMutableDictionary<NSString *, NSNumber *> *entries = [NSMutableDictionary dictionary];
  NSData *data = [NSData dataWithContentsOfURL:self.class.fileURL];
  if (!data) return entries;

  id plist = [NSPropertyListSerialization propertyListWithData:data
                                                       options:NSPropertyListImmutable
                                                        format:NULL
                                                         error:NULL];
  if (![plist isKindOfClass:NSDictionary.class]) return entries;

  NSTimeInterval cutoff = NSDate.date.timeIntervalSince1970 - kHRMaxAge;
  [(NSDictionary *)plist enumerateKeysAndObjectsUsingBlock:^(id key, id value, BOOL *stop) {
    if ([key isKindOfClass:NSString.class] && [value isKindOfClass:NSNumber.class] &&
        [value doubleValue] >= cutoff)
      entries[key] = value;
  }];
  [self.class trimEntries:entries toCount:kHRMaxEntries];
  return entries;
}

// Drops the oldest entries until at most `limit` remain.
+ (void)trimEntries:(NSMutableDictionary<NSString *, NSNumber *> *)entries
            toCount:(NSUInteger)limit {
  if (entries.count <= limit) return;
  NSArray<NSString *> *oldestFirst = [entries keysSortedByValueUsingSelector:@selector(compare:)];
  [entries removeObjectsForKeys:[oldestFirst
                                    subarrayWithRange:NSMakeRange(0, entries.count - limit)]];
}

- (BOOL)containsPostID:(NSString *)postID {
  if (postID.length == 0) return NO;
  os_unfair_lock_lock(&_lock);
  BOOL found = _entries[postID] != nil;
  os_unfair_lock_unlock(&_lock);
  return found;
}

- (BOOL)markPostID:(NSString *)postID {
  if (postID.length == 0 || HRIsOwnPost(postID)) return NO;  // your own posts never count as read
  NSNumber *now = @(NSDate.date.timeIntervalSince1970);
  os_unfair_lock_lock(&_lock);
  BOOL isNew = _entries[postID] == nil;
  if (isNew) _sessionCount++;
  _entries[postID] = now;
  if (_entries.count > kHRMaxEntries + kHRTrimSlack)
    [self.class trimEntries:_entries toCount:kHRMaxEntries];
  os_unfair_lock_unlock(&_lock);
  [self scheduleSave];
  if (isNew) HRAccountHiderQueue(postID);  // and on your Reddit account, if that's on
  return isNew;
}

- (NSArray<NSString *> *)removePostIDs:(NSArray<NSString *> *)postIDs {
  NSMutableArray<NSString *> *removed = [NSMutableArray array];
  os_unfair_lock_lock(&_lock);
  for (NSString *postID in postIDs) {
    if (!_entries[postID]) continue;
    [_entries removeObjectForKey:postID];
    [removed addObject:postID];
  }
  os_unfair_lock_unlock(&_lock);
  if (removed.count) [self scheduleSave];
  return removed;
}

- (NSUInteger)count {
  os_unfair_lock_lock(&_lock);
  NSUInteger count = _entries.count;
  os_unfair_lock_unlock(&_lock);
  return count;
}

- (NSUInteger)sessionCount {
  os_unfair_lock_lock(&_lock);
  NSUInteger count = _sessionCount;
  os_unfair_lock_unlock(&_lock);
  return count;
}

- (NSArray<NSString *> *)allPostIDsNewestFirst {
  os_unfair_lock_lock(&_lock);
  NSDictionary<NSString *, NSNumber *> *snapshot = [_entries copy];
  os_unfair_lock_unlock(&_lock);
  return [snapshot keysSortedByValueUsingSelector:@selector(compare:)].reverseObjectEnumerator.allObjects;
}

- (void)removeAllPostIDs {
  os_unfair_lock_lock(&_lock);
  [_entries removeAllObjects];
  os_unfair_lock_unlock(&_lock);
  [self scheduleSave];
}

- (void)scheduleSave {
  os_unfair_lock_lock(&_lock);
  _dirty = YES;
  BOOL alreadyScheduled = _saveScheduled;
  _saveScheduled = YES;
  os_unfair_lock_unlock(&_lock);
  if (alreadyScheduled) return;

  dispatch_after(dispatch_time(DISPATCH_TIME_NOW, kHRSaveDelay), _ioQueue, ^{
    [self saveNow];
  });
}

// Runs on _ioQueue.
- (void)saveNow {
  os_unfair_lock_lock(&_lock);
  _saveScheduled = NO;
  if (!_dirty) {
    os_unfair_lock_unlock(&_lock);
    return;
  }
  _dirty = NO;
  NSDictionary<NSString *, NSNumber *> *snapshot = [_entries copy];
  os_unfair_lock_unlock(&_lock);

  NSURL *url = self.class.fileURL;
  [NSFileManager.defaultManager createDirectoryAtURL:url.URLByDeletingLastPathComponent
                         withIntermediateDirectories:YES
                                          attributes:nil
                                               error:NULL];
  NSData *data = [NSPropertyListSerialization dataWithPropertyList:snapshot
                                                            format:NSPropertyListBinaryFormat_v1_0
                                                           options:0
                                                             error:NULL];
  if (!data || ![data writeToURL:url options:NSDataWritingAtomic error:NULL]) {
    // Try again with the next change.
    os_unfair_lock_lock(&_lock);
    _dirty = YES;
    os_unfair_lock_unlock(&_lock);
  }
}

- (void)flush {
  dispatch_sync(_ioQueue, ^{
    [self saveNow];
  });
}

@end
