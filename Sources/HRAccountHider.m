#import "HRAccountHider.h"
#import <UIKit/UIKit.h>
#import <os/lock.h>
#import "HROwnPosts.h"
#import "HRResponseProcessor.h"
#import "HRShared.h"
#import "HideReadSettingsViewController.h"
#import "HideReadStore.h"

// Hides the posts counted as read on your Reddit account as well, the way "Hide
// post" in a post's ⋯ menu does: they go on your Hidden list, and Reddit leaves
// them out of your feeds on every device. This is Reddit's own POST /api/hide,
// which takes a comma-separated list of posts.
//
// A few at a time: posts counted as read wait in a queue (kept across launches,
// at most 1,000) and go to Reddit in batches of up to 25, once 25 are waiting or
// 10 seconds after the first one, and never more than one batch every 10
// seconds. "Hide All Read Posts Now" (a tap on Hide in the tab bar, or the row
// in settings) sends the whole read history the same way, a batch every 2
// seconds, while Reddit is open. When Reddit leaves the screen with posts still
// waiting, iOS is asked for the usual half a minute to finish sending them. If
// Reddit asks for less (too many requests, trouble on its side, no connection),
// the pause doubles each time, up to half an hour; its rate-limit headers are
// respected.
//
// Posts Reddit took are recorded (Application Support/HideRead/AccountHidden.plist,
// 90 days, at most 20,000), so none is sent twice. /api/hide answers OK whether
// or not it hid anything, so posts are looked up (GET /api/info) to check
// they're really on your Hidden list: one after the first batch each time Reddit
// opens, and the newest one at the end of each "Hide All Read Posts Now". One
// Reddit doesn't list as hidden is taken off the record, so it's sent again.
//
// Never your own posts. Before a batch goes, Reddit is asked who posted each
// post in it (GET /api/info), and yours are left out. Your account is looked up
// (GET /api/v1/me) for each sign-in the app uses, and its newest 100 posts are
// listed (GET /user/<you>/submitted) when Reddit opens and every ten minutes, so
// they're never counted as read or left out of a feed either (HROwnPosts.h).
// Any of your posts hidden here before are unhidden (POST /api/unhide): the
// posts on the record are checked for yours once per account.
//
// "Hide All Read Posts Now" says how it went in a note at the top of the screen:
// how many posts were hidden and whether Reddit confirms it, or what went wrong.
// A note that comes while Reddit is off screen waits until it's back.
//
// It uses the Reddit app's own sign-in: the Authorization header of the app's
// own requests to reddit.com, picked up as they go out. It's kept in memory
// only, never written down or logged, and only ever sent back to Reddit. If
// Reddit turns it down three times in a row, hiding on your account stops until
// Reddit next becomes active.
//
// Jax Reddit Eclipse still leaves read posts out of the feeds itself as well:
// that covers posts still waiting to be sent, and any Reddit wouldn't take. A
// post already in the list you're scrolling keeps "Hide post" in its ⋯ menu:
// the app only learns it's hidden when that feed loads again.

NSNotificationName const HRAccountHiderStatusDidChangeNotification = @"HRAccountHiderStatusDidChange";

static NSString *const kHRHideURL = @"https://oauth.reddit.com/api/hide";
static NSString *const kHRInfoURL = @"https://oauth.reddit.com/api/info";
static NSString *const kHRUnhideURL = @"https://oauth.reddit.com/api/unhide";
static NSString *const kHRMeURL = @"https://oauth.reddit.com/api/v1/me";
static NSString *const kHRCheckedAccountsKey = @"HRAccountHiddenCheckedFor";  // record checked for their posts
static NSString *const kHRPendingKey = @"HRAccountHidePending";
static const NSUInteger kHRBatchSize = 25;
static const NSUInteger kHRMaxPending = 1000;
static const NSTimeInterval kHRGatherDelay = 10;  // for a batch to fill, at most
static const NSTimeInterval kHRMinGap = 10;       // between requests
static const NSTimeInterval kHRBulkGap = 2;       // between requests during "Hide All Read Posts Now"
static const NSTimeInterval kHRLookUpGap = 1;     // after a lookup (/api/info, /api/v1/me, your posts)
static const NSTimeInterval kHROwnListInterval = 10 * 60;  // your newest posts are listed again after this
static const NSUInteger kHRInfoBatch = 100;       // posts per lookup of the record
static const NSTimeInterval kHRMaxBackoff = 30 * 60;
static const NSTimeInterval kHRRecordMaxAge = 90 * 24 * 60 * 60;
static const NSUInteger kHRRecordMax = 20000;

static dispatch_queue_t gQueue;    // everything below is only touched on it
static dispatch_queue_t gIOQueue;  // writes the record file
static NSURLSession *gSession;
static NSString *gAuthorization;  // "Bearer ...", from the app's own requests
static NSString *gUserAgent;
static BOOL gAppActive;
static NSMutableOrderedSet<NSString *> *gPending;  // counted as read, waiting; kept in the defaults
static NSMutableOrderedSet<NSString *> *gBulk;     // "Hide All Read Posts Now", waiting; memory only
static NSUInteger gBulkTotal;                      // posts in the running "Hide All" (0: none running)
static NSUInteger gBulkDone;                       // of those: hidden, or left out because Reddit refused them
static NSUInteger gBulkHidden;                     // of those: hidden
static NSUInteger gLastBulkHidden;                 // hidden by the last "Hide All" that ended
static NSMutableDictionary<NSString *, NSNumber *> *gRecord;  // post id -> when Reddit took it
static BOOL gRecordDirty;
static BOOL gRecordSaveScheduled;
static BOOL gSending;
static BOOL gTimerArmed;
static NSUInteger gTimerGeneration;
static CFAbsoluteTime gNextAllowed;
static NSTimeInterval gBackoff;
static NSUInteger gRefusals;  // sign-ins Reddit turned down in a row
static BOOL gStopped;         // turned down three times: until Reddit next becomes active
static NSUInteger gHiddenThisRun;
static BOOL gToldWaiting;
static NSString *gProblem;  // what went wrong last, until something works again
static NSInteger gCheck;    // 0: not checked yet this run; 1: Reddit lists it as hidden; -1: it doesn't
static BOOL gChecking;      // the first check this run is under way
static NSUInteger gLookUps; // lookups (GET /api/info) under way
static BOOL gStatusChangeQueued;
static NSUInteger gBulkRun;       // counts "Hide All" runs, so a timer can tell its run is over
static NSString *gBulkNewest;     // the newest read post in the running "Hide All", looked up when it's done
static BOOL gBulkToldProblem;     // a note about a problem went up for the running "Hide All"
static NSString *gNoteForReturn;  // how "Hide All" went, if Reddit was off screen then
static BOOL gBackgroundTime;      // iOS gave Reddit time to finish sending after it left the screen
static NSUInteger gBackgroundSends;  // requests sent in that time, for the log
static UIBackgroundTaskIdentifier gQueueBackgroundTask;  // the time that's for (set up as UIBackgroundTaskInvalid)

static NSMutableDictionary<NSString *, NSString *> *gAccountForSignIn;  // sign-in -> your account (memory only)
static NSMutableArray<NSString *> *gRefusedSignIns;  // sign-ins Reddit turned down, not used again (memory only)
static NSString *gListedAccount;          // the account whose newest posts were listed last
static CFAbsoluteTime gOwnListedAt;       // when
static NSMutableOrderedSet<NSString *> *gUnhide;   // your posts hidden here before: unhidden
static NSMutableOrderedSet<NSString *> *gToCheck;  // posts on the record, to check once for yours
static NSString *gCheckingFor;            // the account they're checked for
static NSUInteger gUnhidden;              // your posts unhidden, for the note

// The record's posts, copied after each change, for HRAccountHiderHid on any thread.
static os_unfair_lock gHidLock = OS_UNFAIR_LOCK_INIT;
static NSSet<NSString *> *gHid;

// Main thread only: the background time iOS gave, if any (set up as UIBackgroundTaskInvalid).
static UIBackgroundTaskIdentifier gBackgroundTask;

static void HRSendBatch(void);

static BOOL HRAccountHidingOn(void) {
  return HRPref(HRPrefEnabled) && HRPref(HRPrefHideOnAccount);
}

static NSString *HRCount(NSUInteger count) {
  return [NSNumberFormatter localizedStringFromNumber:@(count) numberStyle:NSNumberFormatterDecimalStyle];
}

// "1 read post", "12 read posts".
static NSString *HRReadPosts(NSUInteger count) {
  return count == 1 ? @"1 read post" : [NSString stringWithFormat:@"%@ read posts", HRCount(count)];
}

// “A post’s title”, at most 50 characters, or `fallback` when it isn't known.
static NSString *HRQuotedTitle(NSString *title, NSString *fallback) {
  title = [title stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
  if (!title.length) return fallback;
  if (title.length > 50) title = [[title substringToIndex:49] stringByAppendingString:@"…"];
  return [NSString stringWithFormat:@"“%@”", title];
}

static NSInteger HRStatusCode(NSURLResponse *response) {
  return [response isKindOfClass:NSHTTPURLResponse.class] ? ((NSHTTPURLResponse *)response).statusCode : 0;
}

// The settings screen redraws its status lines: at most five times a second.
static void HRStatusChanged(void) {
  if (gStatusChangeQueued) return;
  gStatusChangeQueued = YES;
  dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.2 * NSEC_PER_SEC)), gQueue, ^{
    gStatusChangeQueued = NO;
    dispatch_async(dispatch_get_main_queue(), ^{
      [NSNotificationCenter.defaultCenter postNotificationName:HRAccountHiderStatusDidChangeNotification
                                                        object:nil];
    });
  });
}

#pragma mark - Notes and background time

// A note at the top of the screen about how "Hide All" went: right away while
// Reddit is on screen, otherwise once it's back.
static void HRTell(NSString *text) {
  HRLog(@"[account] note: %@", text);
  if (!gAppActive) {
    gNoteForReturn = text;
    return;
  }
  dispatch_async(dispatch_get_main_queue(), ^{
    HRShowBanner(text, 5);
  });
}

// A problem holding up the running "Hide All": said once per run.
static void HRTellProblem(NSString *text) {
  if (!gBulkTotal || gBulkToldProblem || !text.length) return;
  gBulkToldProblem = YES;
  HRTell(text);
}

// Main thread.
static void HREndBackgroundTask(UIBackgroundTaskIdentifier task) {
  if (task == UIBackgroundTaskInvalid || task != gBackgroundTask) return;
  gBackgroundTask = UIBackgroundTaskInvalid;
  [UIApplication.sharedApplication endBackgroundTask:task];
}

// Hands back the time iOS gave once nothing is left to send, or nothing can be
// sent for a while.
static void HREndBackgroundTimeIfDone(void) {
  if (!gBackgroundTime || gSending || gLookUps) return;
  BOOL waiting = gPending.count > 0 || gBulk.count > 0;
  if (waiting && !gStopped && gAuthorization && gNextAllowed - CFAbsoluteTimeGetCurrent() < 20) return;
  UIBackgroundTaskIdentifier task = gQueueBackgroundTask;
  gBackgroundTime = NO;
  gQueueBackgroundTask = UIBackgroundTaskInvalid;
  if (gBackgroundSends || waiting)
    HRLog(@"[account] done in the background: %lu requests sent%@", (unsigned long)gBackgroundSends,
          waiting ? [NSString stringWithFormat:@", %lu posts wait for Reddit to open again",
                                               (unsigned long)(gPending.count + gBulk.count)]
                  : @"");
  gBackgroundSends = 0;
  dispatch_async(dispatch_get_main_queue(), ^{
    HREndBackgroundTask(task);
  });
}

#pragma mark - Record of posts hidden on the account

static NSURL *HRRecordURL(void) {
  NSURL *support =
      [NSFileManager.defaultManager URLsForDirectory:NSApplicationSupportDirectory inDomains:NSUserDomainMask]
          .firstObject;
  // Next to the read history.
  return [[support URLByAppendingPathComponent:@"HideRead" isDirectory:YES]
      URLByAppendingPathComponent:@"AccountHidden.plist"
                      isDirectory:NO];
}

static void HRLoadRecord(void) {
  NSData *data = [NSData dataWithContentsOfURL:HRRecordURL()];
  id plist = data ? [NSPropertyListSerialization propertyListWithData:data
                                                              options:NSPropertyListImmutable
                                                               format:NULL
                                                                error:NULL]
                  : nil;
  if (![plist isKindOfClass:NSDictionary.class]) return;
  NSTimeInterval cutoff = NSDate.date.timeIntervalSince1970 - kHRRecordMaxAge;
  [(NSDictionary *)plist enumerateKeysAndObjectsUsingBlock:^(id key, id value, BOOL *stop) {
    if ([key isKindOfClass:NSString.class] && [value isKindOfClass:NSNumber.class] &&
        [value doubleValue] >= cutoff)
      gRecord[key] = value;
  }];
}

static void HRSaveRecordNow(void) {
  if (!gRecordDirty) return;
  gRecordDirty = NO;
  if (gRecord.count > kHRRecordMax + 500) {
    NSArray<NSString *> *oldestFirst = [gRecord keysSortedByValueUsingSelector:@selector(compare:)];
    [gRecord removeObjectsForKeys:[oldestFirst subarrayWithRange:NSMakeRange(0, gRecord.count - kHRRecordMax)]];
  }
  NSData *data = [NSPropertyListSerialization dataWithPropertyList:gRecord
                                                            format:NSPropertyListBinaryFormat_v1_0
                                                           options:0
                                                             error:NULL];
  if (!data) return;
  dispatch_async(gIOQueue, ^{
    NSURL *url = HRRecordURL();
    [NSFileManager.defaultManager createDirectoryAtURL:url.URLByDeletingLastPathComponent
                           withIntermediateDirectories:YES
                                            attributes:nil
                                                 error:NULL];
    if (![data writeToURL:url options:NSDataWritingAtomic error:NULL])
      dispatch_async(gQueue, ^{
        gRecordDirty = YES;  // with the next change
      });
  });
}

static void HRMirrorRecord(void) {
  NSSet<NSString *> *posts = [NSSet setWithArray:gRecord.allKeys];
  os_unfair_lock_lock(&gHidLock);
  gHid = posts;
  os_unfair_lock_unlock(&gHidLock);
}

static void HRSaveRecordSoon(void) {
  HRMirrorRecord();
  gRecordDirty = YES;
  if (gRecordSaveScheduled) return;
  gRecordSaveScheduled = YES;
  dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2 * NSEC_PER_SEC)), gQueue, ^{
    gRecordSaveScheduled = NO;
    HRSaveRecordNow();
  });
}

#pragma mark - Sending

static void HRSetUp(void) {
  static dispatch_once_t once;
  dispatch_once(&once, ^{
    gBackgroundTask = gQueueBackgroundTask = UIBackgroundTaskInvalid;
    gQueue = dispatch_queue_create("com.jax.reddit-eclipse.account", DISPATCH_QUEUE_SERIAL);
    gIOQueue = dispatch_queue_create("com.jax.reddit-eclipse.account-io", DISPATCH_QUEUE_SERIAL);
    NSURLSessionConfiguration *configuration = NSURLSessionConfiguration.ephemeralSessionConfiguration;
    configuration.timeoutIntervalForRequest = 30;
    gSession = [NSURLSession sessionWithConfiguration:configuration];
    gPending = [NSMutableOrderedSet orderedSet];
    gBulk = [NSMutableOrderedSet orderedSet];
    gAccountForSignIn = [NSMutableDictionary dictionary];
    gRefusedSignIns = [NSMutableArray array];
    gUnhide = [NSMutableOrderedSet orderedSet];
    gToCheck = [NSMutableOrderedSet orderedSet];
    gRecord = [NSMutableDictionary dictionary];
    // Off the calling thread, and before anything else runs on the queue.
    dispatch_async(gQueue, ^{
      HRLoadRecord();
      HRMirrorRecord();
      for (id postID in [NSUserDefaults.standardUserDefaults arrayForKey:kHRPendingKey])
        if ([postID isKindOfClass:NSString.class] && [(NSString *)postID hasPrefix:@"t3_"] && !gRecord[postID])
          [gPending addObject:postID];
    });
  });
}

static void HRSavePending(void) {
  [NSUserDefaults.standardUserDefaults setObject:gPending.count ? [NSArray arrayWithArray:gPending.array] : nil
                                          forKey:kHRPendingKey];
}

static void HRArmSend(NSTimeInterval delay) {
  NSUInteger generation = ++gTimerGeneration;
  gTimerArmed = YES;
  dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(MAX(delay, 0) * NSEC_PER_SEC)), gQueue, ^{
    if (generation != gTimerGeneration) return;
    gTimerArmed = NO;
    HRSendBatch();
  });
}

// "Hide All Read Posts Now" only goes on while Reddit is active, or has time
// from iOS to finish in the background: a request the system cuts off as Reddit
// is suspended would only count as a failure.
static BOOL HRBulkCanSend(void) {
  return gBulk.count > 0 && (gAppActive || gBackgroundTime);
}

// Your account needs looking up for this sign-in (the app can switch accounts).
static BOOL HRNeedsAccount(void) {
  return gAuthorization && !gAccountForSignIn[gAuthorization];
}

// Tidying up goes on only while Reddit is open, with Jax Reddit Eclipse on.
static BOOL HRCanTidyUp(void) {
  return gAppActive && HRPref(HRPrefEnabled);
}

static BOOL HRNeedsOwnList(void) {
  NSString *account = gAuthorization ? gAccountForSignIn[gAuthorization] : nil;
  return HRCanTidyUp() && account &&
         (![account isEqualToString:gListedAccount] || CFAbsoluteTimeGetCurrent() - gOwnListedAt >= kHROwnListInterval);
}

// Requests that go before any posts are hidden: your account for this sign-in
// (needed to tell your posts apart); and while Reddit is open, your posts to
// unhide, your newest posts to list, the record to check for yours.
static BOOL HRHousekeepingDue(void) {
  if (!gAuthorization) return NO;
  if (HRNeedsAccount()) return gPending.count > 0 || HRBulkCanSend() || HRCanTidyUp();
  return HRCanTidyUp() && (gUnhide.count > 0 || gToCheck.count > 0 || HRNeedsOwnList());
}

// Sends now if a batch is full (or as soon as the pause allows), there's a
// lookup to do, or Reddit is leaving the screen, otherwise in up to 10 seconds.
static void HRConsiderSending(void) {
  if (gSending || gStopped) return;
  BOOL housekeeping = HRHousekeepingDue();
  if (!housekeeping && !gPending.count && !HRBulkCanSend()) return;
  if (!gAuthorization) {
    if (!gToldWaiting) {
      gToldWaiting = YES;
      HRLog(@"[account] %lu posts waiting for the Reddit app's sign-in to hide them on your account",
            (unsigned long)(gPending.count + gBulk.count));
    }
    return;
  }
  NSTimeInterval wait = MAX(0, gNextAllowed - CFAbsoluteTimeGetCurrent());
  if (housekeeping || HRBulkCanSend() || gPending.count >= kHRBatchSize || !gAppActive) HRArmSend(wait);
  else if (!gTimerArmed) HRArmSend(MAX(wait, kHRGatherDelay));
}

static NSString *HRFormEncode(NSString *value) {
  NSMutableCharacterSet *allowed = [NSCharacterSet.alphanumericCharacterSet mutableCopy];
  [allowed addCharactersInString:@"-._~"];
  return [value stringByAddingPercentEncodingWithAllowedCharacters:allowed] ?: @"";
}

// The start of Reddit's answer, for the log (its error messages, never the sign-in).
static NSString *HRAnswerExcerpt(NSData *data) {
  NSString *text = data.length ? [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] : nil;
  if (!text.length) return @"";
  text = [[text componentsSeparatedByCharactersInSet:NSCharacterSet.newlineCharacterSet]
      componentsJoinedByString:@" "];
  return [@": " stringByAppendingString:text.length > 200 ? [text substringToIndex:200] : text];
}

// A short tag telling the app's sign-ins apart in the log (never the sign-in itself).
static NSString *HRSignInTag(NSString *authorization) {
  return [NSString stringWithFormat:@"#%04lx", (unsigned long)(authorization.hash & 0xffff)];
}

// Reddit's rate-limit headers: requests left in this window, and seconds until
// it starts over. With fewer than five left, wait for the next window.
static void HRRespectRateLimit(NSURLResponse *response) {
  if (![response isKindOfClass:NSHTTPURLResponse.class]) return;
  NSHTTPURLResponse *http = (NSHTTPURLResponse *)response;
  NSString *remaining = [http valueForHTTPHeaderField:@"x-ratelimit-remaining"];
  NSString *reset = [http valueForHTTPHeaderField:@"x-ratelimit-reset"];
  if (!remaining.length || !reset.length || remaining.doubleValue >= 5) return;
  NSTimeInterval wait = MIN(MAX(reset.doubleValue, 1), 600) + 1;
  CFAbsoluteTime until = CFAbsoluteTimeGetCurrent() + wait;
  if (until <= gNextAllowed) return;
  gNextAllowed = until;
  HRLog(@"[account] Reddit's request limit is nearly used up; waiting %.0f seconds", wait);
}

// The post in Reddit's /api/info answer, or nil.
static NSDictionary *HRPostInfo(NSData *data, NSString *postID) {
  id json = data.length ? [NSJSONSerialization JSONObjectWithData:data options:0 error:NULL] : nil;
  id listing = [json isKindOfClass:NSDictionary.class] ? ((NSDictionary *)json)[@"data"] : nil;
  id children = [listing isKindOfClass:NSDictionary.class] ? ((NSDictionary *)listing)[@"children"] : nil;
  if (![children isKindOfClass:NSArray.class]) return nil;
  for (id child in (NSArray *)children) {
    id post = [child isKindOfClass:NSDictionary.class] ? ((NSDictionary *)child)[@"data"] : nil;
    if ([post isKindOfClass:NSDictionary.class] && [((NSDictionary *)post)[@"name"] isEqual:postID]) return post;
  }
  return nil;
}

// Looks a post up with Reddit (GET /api/info) `delay` seconds from now, and
// hands `done` whether Reddit lists it as hidden on your account (@YES, @NO, or
// nil if there was no answer that says) and its title, on the queue. One Reddit
// doesn't list as hidden comes off the record, so it's sent again.
static void HRLookUpHidden(NSString *postID, NSString *authorization, NSTimeInterval delay,
                           void (^done)(NSNumber *hidden, NSString *title)) {
  gLookUps++;
  dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay * NSEC_PER_SEC)), gQueue, ^{
    NSURLComponents *components = [NSURLComponents componentsWithString:kHRInfoURL];
    components.queryItems = @[
      [NSURLQueryItem queryItemWithName:@"id" value:postID], [NSURLQueryItem queryItemWithName:@"raw_json" value:@"1"]
    ];
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:components.URL];
    [request setValue:authorization forHTTPHeaderField:@"Authorization"];
    if (gUserAgent) [request setValue:gUserAgent forHTTPHeaderField:@"User-Agent"];
    NSURLSessionDataTask *task = [gSession
        dataTaskWithRequest:request
          completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
            NSInteger status = HRStatusCode(response);
            NSDictionary *post = !error && status >= 200 && status < 300 ? HRPostInfo(data, postID) : nil;
            id flag = post[@"hidden"];
            NSNumber *hidden = [flag isKindOfClass:NSNumber.class] ? flag : nil;
            id title = post[@"title"];
            dispatch_async(gQueue, ^{
              gLookUps--;
              if (hidden) {
                gCheck = hidden.boolValue ? 1 : -1;
                if (hidden.boolValue) {
                  HRLog(@"[account] checked with Reddit: %@ is on your Hidden list", HRDescribePost(postID));
                } else {
                  HRLog(@"[account] Reddit answered OK, but doesn't list %@ as hidden; it will be sent again",
                        HRDescribePost(postID));
                  if (gRecord[postID]) {
                    [gRecord removeObjectForKey:postID];
                    HRSaveRecordSoon();
                  }
                }
              } else {
                HRLog(@"[account] couldn't check with Reddit whether %@ is hidden (%@)", postID,
                      error ? error.localizedDescription
                            : [NSString stringWithFormat:@"HTTP %ld%@", (long)status, HRAnswerExcerpt(data)]);
              }
              done(hidden, [title isKindOfClass:NSString.class] ? title : HRPostTitle(postID));
              HRStatusChanged();
              HREndBackgroundTimeIfDone();
            });
          }];
    [task resume];
  });
}

// The end of a "Hide All": the newest post in it is looked up with Reddit, and
// a note says how it went.
static void HRFinishBulk(void) {
  NSUInteger hidden = gBulkHidden;
  NSUInteger leftOut = gBulkDone - gBulkHidden;
  NSString *newest = gBulkNewest;
  HRLog(@"[account] Hide All Read Posts Now is done: %lu hidden on your account, %lu left out",
        (unsigned long)hidden, (unsigned long)leftOut);
  gLastBulkHidden = hidden;
  gBulkTotal = gBulkDone = gBulkHidden = 0;
  gBulkNewest = nil;
  gBulkToldProblem = NO;

  if (!hidden) {
    if (!leftOut && !gProblem)
      HRTell(@"Nothing hidden: the read posts left were your own.");
    else
      HRTell(gProblem ?: @"Reddit wouldn’t hide your read posts.");
    return;
  }
  NSString *done = [NSString stringWithFormat:@"%@ hidden on your Reddit account.", HRReadPosts(hidden)];
  if (leftOut)
    done = [done stringByAppendingFormat:@" Reddit wouldn’t take %@ of them.", HRCount(leftOut)];
  NSString *authorization = gAuthorization;
  if (!newest || !gRecord[newest] || !authorization) {
    HRTell(done);
    return;
  }
  HRLookUpHidden(newest, authorization, 2, ^(NSNumber *flag, NSString *title) {
    NSString *named = HRQuotedTitle(title, @"the newest one");
    if (flag.boolValue)
      HRTell([done stringByAppendingFormat:@" Reddit confirms %@ is on your Hidden list.", named]);
    else if (flag)
      HRTell([NSString stringWithFormat:@"Reddit accepted %@, but doesn’t list %@ as hidden on your account.",
                                        HRReadPosts(hidden), named]);
    else
      HRTell(done);
  });
}

// Takes posts out of both queues; returns how many were from "Hide All".
static NSUInteger HRTakeOut(NSArray<NSString *> *batch) {
  NSUInteger fromBulk = 0;
  for (NSString *postID in batch)
    if ([gBulk containsObject:postID]) fromBulk++;
  [gPending removeObjectsInArray:batch];
  [gBulk removeObjectsInArray:batch];
  HRSavePending();
  return fromBulk;
}

// Your posts, out of both queues: they're never hidden. A running "Hide All"
// leaves them out of its count.
static void HRDropFromQueues(NSArray<NSString *> *postIDs) {
  NSUInteger fromBulk = 0;
  for (NSString *postID in postIDs)
    if ([gBulk containsObject:postID]) fromBulk++;
  [gPending removeObjectsInArray:postIDs];
  [gBulk removeObjectsInArray:postIDs];
  HRSavePending();
  if (!gBulkTotal) return;
  gBulkTotal -= MIN(fromBulk, gBulkTotal - gBulkDone);
  if (gBulkNewest && [postIDs containsObject:gBulkNewest]) gBulkNewest = gBulk.firstObject;
}

// A request that didn't go through. The sign-in turned down: it's dropped (the
// app's next request brings a new one), and after three times in a row nothing
// more goes until Reddit next becomes active. Reddit refusing the request
// itself: the posts in `batch` are left out rather than sent forever (with no
// batch, a lookup, it's asked again in a minute). Too many requests, trouble on
// Reddit's side, or no connection: a pause, twice as long each time.
static void HRHandleFailure(NSArray<NSString *> *batch, NSURLResponse *response, NSError *error, NSData *data,
                            NSString *authorization) {
  NSInteger status = HRStatusCode(response);
  NSString *reason = error ? error.localizedDescription
                           : [NSString stringWithFormat:@"HTTP %ld from %@ with sign-in %@%@", (long)status,
                                                        response.URL.path ?: @"?", HRSignInTag(authorization),
                                                        HRAnswerExcerpt(data)];
  if (status == 401 || status == 403) {
    // That sign-in won't do: it may have run out, or not be your account's (the app
    // can send others). It isn't used again; the app's next request brings another.
    if (authorization.length && ![gRefusedSignIns containsObject:authorization]) {
      [gRefusedSignIns addObject:authorization];
      if (gRefusedSignIns.count > 8) [gRefusedSignIns removeObjectAtIndex:0];
    }
    if ([gAuthorization isEqualToString:authorization]) gAuthorization = nil;
    gToldWaiting = NO;
    gProblem = [NSString stringWithFormat:@"Reddit turned down the app’s sign-in (HTTP %ld).", (long)status];
    if (++gRefusals >= 3) {
      gStopped = YES;
      HRLog(@"[account] Reddit turned down hiding posts on your account three times (%@). Stopped until Reddit "
            @"is next opened; %lu posts waiting",
            reason, (unsigned long)(gPending.count + gBulk.count));
      HRTellProblem([NSString stringWithFormat:@"Couldn’t hide your read posts: Reddit turned down the Reddit "
                                               @"app’s sign-in (HTTP %ld). Tap Hide to try again.",
                                               (long)status]);
    } else {
      HRLog(@"[account] Reddit turned down hiding posts on your account (%@); trying again with the app's next "
            @"sign-in",
            reason);
    }
  } else if (status >= 400 && status < 500 && status != 408 && status != 429) {
    if (!batch.count) {
      gNextAllowed = MAX(gNextAllowed, CFAbsoluteTimeGetCurrent() + 60);
      HRLog(@"[account] Reddit wouldn't answer (%@); asking again in a minute", reason);
      return;
    }
    // Reddit won't take this batch as it is: drop it rather than send it forever.
    gBulkDone += HRTakeOut(batch);
    gProblem = [NSString stringWithFormat:@"Reddit wouldn’t hide %lu posts (HTTP %ld), so they were left out.",
                                          (unsigned long)batch.count, (long)status];
    HRLog(@"[account] Reddit wouldn't hide these %lu posts (%@); left them out", (unsigned long)batch.count, reason);
    if (gBulk.count) HRTellProblem(gProblem);
  } else {
    // Too many requests, trouble on Reddit's side, or no connection: wait longer each time.
    gBackoff = gBackoff ? MIN(gBackoff * 2, kHRMaxBackoff) : 60;
    gNextAllowed = MAX(gNextAllowed, CFAbsoluteTimeGetCurrent() + gBackoff);
    gProblem = [NSString stringWithFormat:@"Couldn’t reach Reddit to hide posts (%@).",
                                          error ? error.localizedDescription
                                                : [NSString stringWithFormat:@"HTTP %ld", (long)status]];
    HRLog(@"[account] couldn't hide posts on your account (%@); trying again in %.0f seconds", reason, gBackoff);
    HRTellProblem([gProblem stringByAppendingFormat:@" Trying again in %.0f seconds.", gBackoff]);
  }
}

static void HRHandleAnswer(NSArray<NSString *> *batch, NSURLResponse *response, NSError *error, NSData *data,
                           NSString *authorization) {
  NSInteger status = HRStatusCode(response);
  BOOL bulkRunning = gBulkTotal > 0;

  if (!error && status >= 200 && status < 300) {
    NSNumber *now = @(NSDate.date.timeIntervalSince1970);
    for (NSString *postID in batch) gRecord[postID] = now;
    HRSaveRecordSoon();
    NSUInteger fromBulk = HRTakeOut(batch);
    gBulkDone += fromBulk;
    gBulkHidden += fromBulk;
    gBackoff = 0;
    gRefusals = 0;
    gProblem = nil;
    gHiddenThisRun += batch.count;
    HRLog(@"[account] hid %lu posts on your Reddit account (%lu since Reddit opened, %lu waiting)",
          (unsigned long)batch.count, (unsigned long)gHiddenThisRun, (unsigned long)(gPending.count + gBulk.count));
    // The end of a "Hide All" has its own check.
    if (!bulkRunning && !gCheck && !gChecking) {
      gChecking = YES;
      HRLookUpHidden(batch.firstObject, authorization, 3, ^(NSNumber *hidden, NSString *title) {
        gChecking = NO;
      });
    }
  } else {
    HRHandleFailure(batch, response, error, data, authorization);
  }
  if (bulkRunning && !gBulk.count) HRFinishBulk();
}

// A GET request to Reddit with the app's sign-in.
static NSMutableURLRequest *HRGetRequest(NSString *url, NSDictionary<NSString *, NSString *> *query,
                                         NSString *authorization) {
  NSURLComponents *components = [NSURLComponents componentsWithString:url];
  NSMutableArray<NSURLQueryItem *> *items = [NSMutableArray array];
  for (NSString *name in query) [items addObject:[NSURLQueryItem queryItemWithName:name value:query[name]]];
  components.queryItems = items;
  NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:components.URL];
  [request setValue:authorization forHTTPHeaderField:@"Authorization"];
  if (gUserAgent) [request setValue:gUserAgent forHTTPHeaderField:@"User-Agent"];
  return request;
}

// POST /api/hide or /api/unhide for `postIDs`, with the app's sign-in.
static NSMutableURLRequest *HRPostsRequest(NSString *url, NSArray<NSString *> *postIDs, NSString *authorization) {
  NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:url]];
  request.HTTPMethod = @"POST";
  [request setValue:authorization forHTTPHeaderField:@"Authorization"];
  if (gUserAgent) [request setValue:gUserAgent forHTTPHeaderField:@"User-Agent"];
  [request setValue:@"application/x-www-form-urlencoded" forHTTPHeaderField:@"Content-Type"];
  NSString *body = [@"id=" stringByAppendingString:HRFormEncode([postIDs componentsJoinedByString:@","])];
  request.HTTPBody = [body dataUsingEncoding:NSUTF8StringEncoding];
  return request;
}

// The posts in one of Reddit's listings (/api/info, /user/<name>/submitted), by
// id, or nil if the answer isn't one.
static NSDictionary<NSString *, NSDictionary *> *HRPostsInListing(NSData *data) {
  id json = data.length ? [NSJSONSerialization JSONObjectWithData:data options:0 error:NULL] : nil;
  id listing = [json isKindOfClass:NSDictionary.class] ? ((NSDictionary *)json)[@"data"] : nil;
  id children = [listing isKindOfClass:NSDictionary.class] ? ((NSDictionary *)listing)[@"children"] : nil;
  if (![children isKindOfClass:NSArray.class]) return nil;
  NSMutableDictionary<NSString *, NSDictionary *> *posts = [NSMutableDictionary dictionary];
  for (id child in (NSArray *)children) {
    id post = [child isKindOfClass:NSDictionary.class] ? ((NSDictionary *)child)[@"data"] : nil;
    id name = [post isKindOfClass:NSDictionary.class] ? ((NSDictionary *)post)[@"name"] : nil;
    if ([name isKindOfClass:NSString.class] && [(NSString *)name hasPrefix:@"t3_"]) posts[name] = post;
  }
  return posts;
}

// Whether Reddit names one of your accounts as the post's author.
static BOOL HRIsYours(NSDictionary *post) {
  return HRIsOwnAuthor(post[@"author"], post[@"author_fullname"]);
}

static BOOL HRIsLookUpRefused(NSInteger status) {
  return status >= 400 && status < 500 && status != 401 && status != 403 && status != 408 && status != 429;
}

// Sends a request, and nothing else until it's answered; `done` gets the answer
// on the queue. The next request waits `gap` seconds from now at least. An
// answer means the sign-in works and Reddit can be reached: any pause for
// trouble starts over.
static void HRSend(NSURLRequest *request, NSTimeInterval gap,
                   void (^done)(NSData *data, NSURLResponse *response, NSError *error)) {
  gSending = YES;
  if (!gAppActive) gBackgroundSends++;
  gNextAllowed = MAX(gNextAllowed, CFAbsoluteTimeGetCurrent() + gap);
  NSURLSessionDataTask *task =
      [gSession dataTaskWithRequest:request
                  completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
                    dispatch_async(gQueue, ^{
                      gSending = NO;
                      NSInteger status = HRStatusCode(response);
                      if (!error && status >= 200 && status < 300) gBackoff = gRefusals = 0;
                      HRRespectRateLimit(response);
                      done(data, response, error);
                      HRStatusChanged();
                      HRConsiderSending();
                      HREndBackgroundTimeIfDone();
                    });
                  }];
  [task resume];
}

static void HRSendHide(NSArray<NSString *> *batch, NSString *authorization) {
  HRSend(HRPostsRequest(kHRHideURL, batch, authorization), HRBulkCanSend() ? kHRBulkGap : kHRMinGap,
         ^(NSData *data, NSURLResponse *response, NSError *error) {
           HRHandleAnswer(batch, response, error, data, authorization);
         });
}

// Before a batch is hidden, Reddit is asked who posted each post in it (GET
// /api/info). Yours are left out, and never hidden; the rest go right after.
static void HRCheckThenHide(NSArray<NSString *> *batch) {
  NSString *authorization = gAuthorization;
  NSURLRequest *request =
      HRGetRequest(kHRInfoURL, @{@"id" : [batch componentsJoinedByString:@","], @"raw_json" : @"1"}, authorization);
  HRSend(request, kHRLookUpGap, ^(NSData *data, NSURLResponse *response, NSError *error) {
    NSInteger status = HRStatusCode(response);
    BOOL bulkRunning = gBulkTotal > 0;
    NSDictionary<NSString *, NSDictionary *> *posts =
        !error && status >= 200 && status < 300 ? HRPostsInListing(data) : nil;
    if (!posts) {
      HRHandleFailure(batch, response, error, data, authorization);
      if (bulkRunning && !gBulk.count) HRFinishBulk();
      return;
    }
    NSMutableArray<NSString *> *yours = [NSMutableArray array];
    NSMutableArray<NSString *> *others = [NSMutableArray array];
    for (NSString *postID in batch) {
      NSDictionary *post = posts[postID];
      if (post && HRIsYours(post))
        [yours addObject:postID];
      else
        [others addObject:postID];
    }
    if (yours.count) {
      for (NSString *postID in yours)
        HRLog(@"[own] %@ is your post, so it isn't hidden on your account", HRDescribePost(postID));
      HRDropFromQueues(yours);
      HRAddOwnPosts(yours);
    }
    // Only posts still waiting ("Hide All" may have been stopped meanwhile), and
    // only if Reddit's request limit allows; otherwise they wait their turn.
    NSMutableArray<NSString *> *waiting = [NSMutableArray array];
    for (NSString *postID in others)
      if ([gPending containsObject:postID] || [gBulk containsObject:postID]) [waiting addObject:postID];
    if (waiting.count && gNextAllowed <= CFAbsoluteTimeGetCurrent() + kHRLookUpGap)
      HRSendHide(waiting, authorization);
    else if (bulkRunning && !gBulk.count)
      HRFinishBulk();
  });
}

// The record has been checked for this account's posts.
static void HRRecordChecked(void) {
  if (!gCheckingFor) return;
  NSMutableArray *checked =
      [[NSUserDefaults.standardUserDefaults arrayForKey:kHRCheckedAccountsKey] mutableCopy] ?: [NSMutableArray array];
  if (![checked containsObject:gCheckingFor]) [checked addObject:gCheckingFor];
  [NSUserDefaults.standardUserDefaults setObject:checked forKey:kHRCheckedAccountsKey];
  HRLog(@"[own] checked the posts hidden here before for u/%@'s own", gCheckingFor);
  gCheckingFor = nil;
}

// The posts hidden on your account before your own were left alone: those
// known to be yours are unhidden, and the rest are checked once per account.
static void HRQueueRecordCheck(NSString *name) {
  for (NSString *postID in gRecord)
    if (HRIsOwnPost(postID)) [gUnhide addObject:postID];
  NSString *account = name.lowercaseString;
  if ([gCheckingFor isEqualToString:account] ||
      [[NSUserDefaults.standardUserDefaults arrayForKey:kHRCheckedAccountsKey] containsObject:account])
    return;
  gCheckingFor = account;
  [gToCheck removeAllObjects];
  [gToCheck addObjectsFromArray:gRecord.allKeys];
  if (!gToCheck.count) HRRecordChecked();
}

// Your account (GET /api/v1/me), asked for each sign-in the app uses: which
// posts are yours goes by it.
static void HRLookUpAccount(void) {
  NSString *authorization = gAuthorization;
  HRSend(HRGetRequest(kHRMeURL, @{@"raw_json" : @"1"}, authorization), kHRLookUpGap,
         ^(NSData *data, NSURLResponse *response, NSError *error) {
           NSInteger status = HRStatusCode(response);
           id json = !error && status >= 200 && status < 300 && data.length
                         ? [NSJSONSerialization JSONObjectWithData:data options:0 error:NULL]
                         : nil;
           id name = [json isKindOfClass:NSDictionary.class] ? ((NSDictionary *)json)[@"name"] : nil;
           id ident = [json isKindOfClass:NSDictionary.class] ? ((NSDictionary *)json)[@"id"] : nil;
           if (![name isKindOfClass:NSString.class] || ![(NSString *)name length]) {
             HRHandleFailure(nil, response, error, data, authorization);
             return;
           }
           if (gAccountForSignIn.count >= 8) [gAccountForSignIn removeAllObjects];
           gAccountForSignIn[authorization] = name;
           HRAddOwnAccount(name, [ident isKindOfClass:NSString.class] ? [@"t2_" stringByAppendingString:ident] : nil);
           HRQueueRecordCheck(name);
         });
}

// Your newest 100 posts (GET /user/<you>/submitted), listed when Reddit opens
// and every ten minutes while it's open: they're never counted as read or left
// out of a feed.
static void HRListOwnPosts(void) {
  NSString *name = gAccountForSignIn[gAuthorization];
  NSString *path = [name stringByAddingPercentEncodingWithAllowedCharacters:NSCharacterSet.URLPathAllowedCharacterSet];
  NSString *url = [NSString stringWithFormat:@"https://oauth.reddit.com/user/%@/submitted", path ?: name];
  NSString *authorization = gAuthorization;
  gListedAccount = name;
  gOwnListedAt = CFAbsoluteTimeGetCurrent();  // after a failure too: asked again in ten minutes
  HRSend(HRGetRequest(url, @{@"limit" : @"100", @"sort" : @"new", @"show" : @"all", @"raw_json" : @"1"},
                      authorization),
         kHRLookUpGap, ^(NSData *data, NSURLResponse *response, NSError *error) {
           NSInteger status = HRStatusCode(response);
           NSDictionary<NSString *, NSDictionary *> *posts =
               !error && status >= 200 && status < 300 ? HRPostsInListing(data) : nil;
           if (!posts) {
             HRHandleFailure(nil, response, error, data, authorization);
             return;
           }
           NSMutableArray<NSString *> *yours = [NSMutableArray array];
           for (NSString *postID in posts)
             if (HRIsYours(posts[postID])) [yours addObject:postID];
           NSUInteger added = HRAddOwnPosts(yours).count;
           HRLog(@"[own] u/%@ has %lu recent posts (%lu new here); they're never counted as read or hidden", name,
                 (unsigned long)yours.count, (unsigned long)added);
         });
}

// One record check: 100 posts looked up (GET /api/info); yours are unhidden.
static void HRCheckRecordStep(void) {
  NSArray<NSString *> *chunk = [gToCheck.array subarrayWithRange:NSMakeRange(0, MIN(gToCheck.count, kHRInfoBatch))];
  NSString *authorization = gAuthorization;
  NSURLRequest *request =
      HRGetRequest(kHRInfoURL, @{@"id" : [chunk componentsJoinedByString:@","], @"raw_json" : @"1"}, authorization);
  HRSend(request, kHRLookUpGap, ^(NSData *data, NSURLResponse *response, NSError *error) {
    NSInteger status = HRStatusCode(response);
    NSDictionary<NSString *, NSDictionary *> *posts =
        !error && status >= 200 && status < 300 ? HRPostsInListing(data) : nil;
    if (!posts) {
      HRHandleFailure(nil, response, error, data, authorization);
      if (HRIsLookUpRefused(status)) [gToCheck removeObjectsInArray:chunk];  // Reddit won't look these up
      if (!gToCheck.count) HRRecordChecked();
      return;
    }
    [gToCheck removeObjectsInArray:chunk];
    NSMutableArray<NSString *> *yours = [NSMutableArray array];
    for (NSString *postID in chunk)
      if (posts[postID] && HRIsYours(posts[postID])) [yours addObject:postID];
    if (yours.count) {
      HRAddOwnPosts(yours);
      for (NSString *postID in yours)
        if (gRecord[postID]) [gUnhide addObject:postID];
    }
    if (!gToCheck.count) HRRecordChecked();
  });
}

// Your posts hidden here before: unhidden (POST /api/unhide), 25 at a time, and
// off the record.
static void HRSendUnhide(void) {
  NSArray<NSString *> *batch = [gUnhide.array subarrayWithRange:NSMakeRange(0, MIN(gUnhide.count, kHRBatchSize))];
  NSString *authorization = gAuthorization;
  HRSend(HRPostsRequest(kHRUnhideURL, batch, authorization), kHRBulkGap,
         ^(NSData *data, NSURLResponse *response, NSError *error) {
           NSInteger status = HRStatusCode(response);
           if (error || status < 200 || status >= 300) {
             HRHandleFailure(nil, response, error, data, authorization);
             if (HRIsLookUpRefused(status)) [gUnhide removeObjectsInArray:batch];  // Reddit won't take them
             return;
           }
           [gUnhide removeObjectsInArray:batch];
           [gRecord removeObjectsForKeys:batch];
           HRSaveRecordSoon();
           gUnhidden += batch.count;
           for (NSString *postID in batch)
             HRLog(@"[own] %@ is your post: unhidden on your account", HRDescribePost(postID));
           if (gUnhide.count) return;
           HRTell(gUnhidden == 1
                      ? @"Unhid 1 of your own posts on your Reddit account."
                      : [NSString stringWithFormat:@"Unhid %@ of your own posts on your Reddit account.",
                                                   HRCount(gUnhidden)]);
           gUnhidden = 0;
         });
}

// What goes to Reddit next, one request at a time: your account, for a new
// sign-in; while Reddit is open, your posts to unhide, your newest posts to
// list, and the record to check for yours; then posts to hide, those just
// counted as read first, then the read history, each batch checked for yours.
static void HRSendBatch(void) {
  if (gSending || gStopped) return;
  if (gPending.count && !HRAccountHidingOn()) {
    // Turned off since these were counted.
    [gPending removeAllObjects];
    HRSavePending();
    HRStatusChanged();
  }
  if (!HRHousekeepingDue() && !gPending.count && !HRBulkCanSend()) return;
  if (!gAuthorization) {
    HRConsiderSending();  // waits for the app's sign-in
    return;
  }
  CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
  if (now < gNextAllowed) {
    HRArmSend(gNextAllowed - now);
    return;
  }

  if (HRNeedsAccount()) {
    HRLookUpAccount();
    return;
  }
  if (HRCanTidyUp() && gUnhide.count) {
    HRSendUnhide();
    return;
  }
  if (HRNeedsOwnList()) {
    HRListOwnPosts();
    return;
  }
  if (HRCanTidyUp() && gToCheck.count) {
    HRCheckRecordStep();
    return;
  }

  // Posts already known to be yours never go.
  NSMutableArray<NSString *> *yours = [NSMutableArray array];
  for (NSString *postID in gPending)
    if (HRIsOwnPost(postID)) [yours addObject:postID];
  for (NSString *postID in gBulk)
    if (HRIsOwnPost(postID)) [yours addObject:postID];
  if (yours.count) {
    BOOL bulkRunning = gBulkTotal > 0;
    HRDropFromQueues(yours);
    if (bulkRunning && !gBulk.count) HRFinishBulk();
  }
  if (!gPending.count && !HRBulkCanSend()) return;

  // Posts just counted as read first, then the read history.
  NSMutableOrderedSet<NSString *> *picked = [NSMutableOrderedSet orderedSet];
  for (NSString *postID in gPending) {
    if (picked.count == kHRBatchSize) break;
    [picked addObject:postID];
  }
  if (HRBulkCanSend())
    for (NSString *postID in gBulk) {
      if (picked.count == kHRBatchSize) break;
      [picked addObject:postID];
    }
  HRCheckThenHide([[NSArray alloc] initWithArray:picked.array]);  // .array is a live view
}

#pragma mark - Status

static NSString *HRStatusLine(void) {
  CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
  NSUInteger waiting = gPending.count + gBulk.count;
  NSMutableArray<NSString *> *parts = [NSMutableArray array];

  if (gBulkTotal)
    [parts addObject:[NSString stringWithFormat:@"Hiding your read posts: %@ of %@ done.", HRCount(gBulkDone),
                                                HRCount(gBulkTotal)]];
  else if (gLastBulkHidden)
    [parts addObject:[NSString stringWithFormat:@"Hid %@ read posts.", HRCount(gLastBulkHidden)]];

  if (gStopped)
    [parts addObject:@"Stopped: Reddit refused the app’s sign-in three times. Reopen Reddit to retry."];
  else if (waiting && !gAuthorization)
    [parts addObject:gProblem ? [gProblem stringByAppendingString:@" Waiting for the app’s next sign-in, picked up "
                                                                  @"when a feed loads."]
                              : @"Waiting for the app’s sign-in, picked up when a feed loads."];
  else if (gProblem && waiting && gNextAllowed > now + 1)
    [parts addObject:[gProblem stringByAppendingFormat:@" Trying again in %.0f seconds.", gNextAllowed - now]];
  else if (gProblem)
    [parts addObject:gProblem];
  else if (gPending.count && !gBulkTotal)
    [parts addObject:[NSString stringWithFormat:@"%@ waiting to be sent.", HRCount(gPending.count)]];

  if (gCheck > 0)
    [parts addObject:@"Reddit confirms they’re hidden."];
  else if (gCheck < 0)
    [parts addObject:@"Reddit answered, but doesn’t list them as hidden."];

  BOOL on = HRAccountHidingOn();
  if (!parts.count) {
    if (!on) return @"Off: read posts are only left out of this app’s feeds.";
    if (gHiddenThisRun) return [NSString stringWithFormat:@"%@ hidden since Reddit opened.", HRCount(gHiddenThisRun)];
    if (!gAuthorization) return @"Nothing waiting. The app’s sign-in is picked up when a feed loads.";
    return @"Nothing waiting.";
  }
  if (!on && !gBulkTotal) [parts insertObject:@"Off." atIndex:0];
  return [parts componentsJoinedByString:@" "];
}

NSDictionary<NSString *, id> *HRAccountHiderStatus(void) {
  HRSetUp();
  __block NSDictionary<NSString *, id> *status;
  dispatch_sync(gQueue, ^{
    status = @{
      @"hidden" : @(gRecord.count),
      @"bulkTotal" : @(gBulkTotal),
      @"bulkDone" : @(gBulkDone),
      @"line" : HRStatusLine(),
    };
  });
  return status;
}

#pragma mark - Entry points

void HRAccountHiderNoteRequest(NSURLSession *session, NSURLRequest *request) {
  // Only from Reddit's API hosts (gql…, oauth…), the ones the hiding requests go
  // to: other Reddit hosts can carry other kinds of sign-in.
  if (!HRShouldProcessRequest(request)) return;
  NSString *host = request.URL.host;
  if (gSession && session == gSession) return;  // our own
  NSString *authorization = [request valueForHTTPHeaderField:@"Authorization"];
  NSDictionary *extra = nil;
  if (!authorization.length) {
    extra = session.configuration.HTTPAdditionalHeaders;
    if ([extra[@"Authorization"] isKindOfClass:NSString.class]) authorization = extra[@"Authorization"];
  }
  if (authorization.length < 40 ||
      [authorization rangeOfString:@"Bearer " options:NSCaseInsensitiveSearch | NSAnchoredSearch].location ==
          NSNotFound)
    return;
  NSString *agent = [request valueForHTTPHeaderField:@"User-Agent"];
  if (!agent.length) {
    if (!extra) extra = session.configuration.HTTPAdditionalHeaders;
    if ([extra[@"User-Agent"] isKindOfClass:NSString.class]) agent = extra[@"User-Agent"];
  }
  NSString *path = request.URL.path ?: @"";
  NSMutableSet<NSString *> *headerNames = [NSMutableSet set];
  if (HRPref(HRPrefDiagnostics)) {
    for (NSString *name in request.allHTTPHeaderFields) [headerNames addObject:name.lowercaseString];
    for (id name in session.configuration.HTTPAdditionalHeaders)
      if ([name isKindOfClass:NSString.class]) [headerNames addObject:((NSString *)name).lowercaseString];
  }
  HRSetUp();
  dispatch_async(gQueue, ^{
    if (agent.length) gUserAgent = agent;
    if ([authorization isEqualToString:gAuthorization] || [gRefusedSignIns containsObject:authorization]) return;
    BOOL first = !gAuthorization;
    gAuthorization = authorization;
    // Each sign-in once, with where it came from: the app may use more than one.
    HRLogOnce([@"signin:" stringByAppendingString:HRSignInTag(authorization)],
              @"[account] using the Reddit app's sign-in %@ (from a request to %@%@)", HRSignInTag(authorization),
              host, path);
    if (headerNames.count)
      HRLogOnce(@"signin-headers", @"[account] the app's requests carry these headers: %@",
                [[headerNames.allObjects sortedArrayUsingSelector:@selector(compare:)] componentsJoinedByString:@", "]);
    if (first) HRStatusChanged();
    HRConsiderSending();
  });
}

void HRAccountHiderQueue(NSString *postID) {
  if (![postID hasPrefix:@"t3_"] || !HRAccountHidingOn() || HRIsOwnPost(postID)) return;
  HRSetUp();
  dispatch_async(gQueue, ^{
    if (gRecord[postID] || [gPending containsObject:postID]) return;
    [gPending addObject:postID];
    if (gPending.count > kHRMaxPending) [gPending removeObjectsInRange:NSMakeRange(0, gPending.count - kHRMaxPending)];
    HRSavePending();
    HRConsiderSending();
    HRStatusChanged();
  });
}

BOOL HRAccountHiderHid(NSString *postID) {
  if (![postID isKindOfClass:NSString.class]) return NO;
  HRSetUp();
  os_unfair_lock_lock(&gHidLock);
  BOOL hid = [gHid containsObject:postID];
  os_unfair_lock_unlock(&gHidLock);
  return hid;
}

void HRAccountHiderOwnPosts(NSArray<NSString *> *postIDs) {
  if (!postIDs.count) return;
  HRSetUp();
  NSArray<NSString *> *yours = [postIDs copy];
  dispatch_async(gQueue, ^{
    BOOL bulkRunning = gBulkTotal > 0;
    HRDropFromQueues(yours);
    for (NSString *postID in yours)
      if (gRecord[postID]) [gUnhide addObject:postID];
    if (bulkRunning && !gBulk.count && !gSending) HRFinishBulk();  // otherwise the answer under way finishes it
    HRStatusChanged();
    HRConsiderSending();
  });
}

void HRAccountHiderStart(void) {
  HRSetUp();
  HREndBackgroundTask(gBackgroundTask);  // Reddit is back: no need for it
  dispatch_async(gQueue, ^{
    gAppActive = YES;
    gBackgroundTime = NO;
    gQueueBackgroundTask = UIBackgroundTaskInvalid;
    gStopped = NO;
    gRefusals = 0;
    // How "Hide All" went, if it ended while Reddit was off screen.
    NSString *note = gNoteForReturn;
    gNoteForReturn = nil;
    if (note)
      dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.8 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        HRShowBanner(note, 5);
      });
    // A fresh start each time Reddit opens: a pause from the last time (or from
    // requests cut off in the background) doesn't carry over, unless it's
    // Reddit's own rate limit.
    if (gBackoff) {
      gBackoff = 0;
      gNextAllowed = MIN(gNextAllowed, CFAbsoluteTimeGetCurrent() + kHRMinGap);
    }
    HRConsiderSending();
    HRStatusChanged();
  });
}

void HRAccountHiderAppWillResignActive(void) {
  HRSetUp();
  // Time to finish sending what's waiting (say Hide was tapped just before you
  // switched to another app). iOS gives about half a minute; it's handed back as
  // soon as nothing is left.
  if (gBackgroundTask == UIBackgroundTaskInvalid) {
    __block UIBackgroundTaskIdentifier task = UIBackgroundTaskInvalid;
    task = [UIApplication.sharedApplication
        beginBackgroundTaskWithName:@"Jax Reddit Eclipse: hiding read posts"
                  expirationHandler:^{
                    HREndBackgroundTask(task);
                    dispatch_async(gQueue, ^{
                      if (gQueueBackgroundTask != task) return;
                      gBackgroundTime = NO;
                      gQueueBackgroundTask = UIBackgroundTaskInvalid;
                      HRLog(@"[account] out of time in the background after %lu requests; %lu posts wait for "
                            @"Reddit to open again",
                            (unsigned long)gBackgroundSends, (unsigned long)(gPending.count + gBulk.count));
                      gBackgroundSends = 0;
                    });
                  }];
    gBackgroundTask = task;
  }
  UIBackgroundTaskIdentifier task = gBackgroundTask;
  dispatch_async(gQueue, ^{
    gAppActive = NO;
    gBackgroundTime = task != UIBackgroundTaskInvalid;
    gQueueBackgroundTask = task;
    HRSaveRecordNow();
    if (gBackgroundTime && (gPending.count || gBulk.count) && gAuthorization && !gStopped)
      HRLog(@"[account] Reddit left the screen with %lu posts waiting; sending them in the background",
            (unsigned long)(gPending.count + gBulk.count));
    HRConsiderSending();  // what's waiting goes now
    HREndBackgroundTimeIfDone();
  });
}

NSUInteger HRAccountHiderReadPostsToHide(void) {
  NSArray<NSString *> *postIDs = HideReadStore.sharedStore.allPostIDsNewestFirst;
  HRSetUp();
  __block NSUInteger count = 0;
  dispatch_sync(gQueue, ^{
    for (NSString *postID in postIDs)
      if ([postID hasPrefix:@"t3_"] && !gRecord[postID] && !HRIsOwnPost(postID)) count++;
  });
  return count;
}

// Every read post is hidden on your account already, as far as Jax Reddit
// Eclipse knows: Reddit is asked about the newest. If it doesn't list it as
// hidden (unhidden on the website, say), the record can't be trusted, so it's
// cleared and the whole read history goes to Reddit again.
static void HRConfirmAllHidden(NSArray<NSString *> *postIDs, NSString *newest, NSUInteger readPosts,
                               BOOL showNote) {
  NSString *all = readPosts == 1 ? @"The 1 post you’ve read is"
                                 : [NSString stringWithFormat:@"All %@ posts you’ve read are", HRCount(readPosts)];
  NSString *authorization = gAuthorization;
  if (!authorization) {
    if (showNote) HRTell([all stringByAppendingString:@" hidden on your Reddit account already."]);
    return;
  }
  HRLookUpHidden(newest, authorization, 0, ^(NSNumber *hidden, NSString *title) {
    NSString *named = HRQuotedTitle(title, @"the newest one");
    if (hidden && !hidden.boolValue) {
      HRLog(@"[account] the record of hidden posts is out of date; sending the read history again");
      [gRecord removeAllObjects];
      HRSaveRecordSoon();
      if (!gBulkTotal) gBulkDone = gBulkHidden = 0;
      for (NSString *postID in postIDs)
        if ([postID hasPrefix:@"t3_"] && !HRIsOwnPost(postID)) [gBulk addObject:postID];
      gBulkTotal = gBulk.count ? gBulkDone + gBulk.count : 0;
      if (!gBulkNewest) gBulkNewest = gBulk.firstObject;
      HRConsiderSending();
      HRStatusChanged();
      if (showNote)
        HRTell([NSString stringWithFormat:@"Reddit doesn’t list %@ as hidden, so all %@ are going to Reddit again.",
                                          named, HRReadPosts(readPosts)]);
      return;
    }
    if (!showNote) return;
    if (hidden)
      HRTell([all stringByAppendingFormat:@" hidden on your Reddit account. Reddit confirms %@ is on your Hidden list.",
                                          named]);
    else
      HRTell([all stringByAppendingString:@" hidden on your Reddit account already."]);
  });
}

// "Hide" was tapped before the Reddit app's sign-in was picked up: if it still
// isn't a few seconds later, a note says what's holding things up.
static void HRTellIfStillWaiting(NSUInteger run) {
  dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(8 * NSEC_PER_SEC)), gQueue, ^{
    if (run != gBulkRun || !gBulkTotal || gAuthorization) return;
    HRTellProblem(@"Waiting for the Reddit app’s sign-in to hide your read posts. Pull your feed down to "
                  @"refresh it, and they’ll go.");
  });
}

void HRAccountHiderHideAllRead(BOOL showNote) {
  NSArray<NSString *> *postIDs = HideReadStore.sharedStore.allPostIDsNewestFirst;
  HRSetUp();
  dispatch_async(gQueue, ^{
    gStopped = NO;
    gRefusals = 0;
    [gRefusedSignIns removeAllObjects];  // you asked to try again: every sign-in gets another go
    gBulkToldProblem = NO;
    if (!gBulkTotal) {
      gBulkDone = gBulkHidden = 0;
      gBulkNewest = nil;
      gBulkRun++;
    }
    gLastBulkHidden = 0;
    NSUInteger readPosts = 0;
    NSString *newestRead = nil;
    for (NSString *postID in postIDs) {
      if (![postID hasPrefix:@"t3_"] || HRIsOwnPost(postID)) continue;  // yours are never hidden
      readPosts++;
      if (!newestRead) newestRead = postID;
      if (!gRecord[postID]) [gBulk addObject:postID];
    }
    gBulkTotal = gBulk.count ? gBulkDone + gBulk.count : 0;
    if (!gBulkNewest) gBulkNewest = gBulk.firstObject;
    HRLog(@"[account] Hide All Read Posts Now: %lu of %lu read posts to hide on your Reddit account%@",
          (unsigned long)gBulk.count, (unsigned long)readPosts,
          gBulkNewest ? [@", newest " stringByAppendingString:HRDescribePost(gBulkNewest)] : @"");
    HRConsiderSending();
    HRStatusChanged();

    if (gBulk.count) {
      if (!gAuthorization) HRTellIfStillWaiting(gBulkRun);
      if (showNote) {
        NSString *note = [NSString stringWithFormat:@"Hiding %@ on your Reddit account…", HRReadPosts(gBulk.count)];
        dispatch_async(dispatch_get_main_queue(), ^{
          HRShowToast(note);
        });
      }
      return;
    }
    if (!readPosts) {
      if (showNote)
        dispatch_async(dispatch_get_main_queue(), ^{
          HRShowToast(@"No read posts to hide yet");
        });
      return;
    }
    HRConfirmAllHidden(postIDs, newestRead, readPosts, showNote);
  });
}

void HRAccountHiderStopHidingAll(void) {
  HRSetUp();
  dispatch_async(gQueue, ^{
    if (!gBulkTotal) return;
    HRLog(@"[account] Hide All Read Posts Now stopped: %lu of %lu done", (unsigned long)gBulkDone,
          (unsigned long)gBulkTotal);
    [gBulk removeAllObjects];
    gLastBulkHidden = gBulkHidden;
    gBulkTotal = gBulkDone = gBulkHidden = 0;
    gBulkNewest = nil;
    gBulkToldProblem = NO;
    HRStatusChanged();
    HREndBackgroundTimeIfDone();
  });
}
