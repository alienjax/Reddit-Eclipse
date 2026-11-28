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
// Reddit next becomes active. Its requests go out like the app's own: through
// the app's own URL session (its cookies and settings), with the headers of the
// app's latest request that say who's asking (device, session, app version).
// A sign-in Reddit's API answers as if no one were logged in (/api/v1/me with
// no account in it) isn't used to hide posts.
//
// When Reddit's API won't take the app's sign-in, posts are hidden the way the
// app itself hides one: its own GraphQL request for ⋯ → Hide post, learned the
// first time you hide a post yourself, and sent again with each read post in
// it, one at a time (see "The app's own way" below).
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
static NSString *const kHROwnRequestKey = @"HideReadAccountRequest";  // marks Jax Reddit Eclipse's own requests
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
static NSMutableArray<NSString *> *gAnonymousSignIns;  // sign-ins Reddit's API answers as logged out (memory only)
static NSMutableOrderedSet<NSString *> *gRecentSignIns;  // the app's latest few, most recent last (memory only)
static NSMutableOrderedSet<NSString *> *gRecentGraphQLSignIns;  // the same, on its GraphQL requests
static NSURLSession *gAppSession;      // the session of the app's latest API request: Jax Reddit Eclipse's go through it
static NSURLSession *gAppGraphQLSession;  // the same, for GraphQL
static NSDictionary<NSString *, NSString *> *gAppHeaders;  // that request's headers that say who's asking (memory only)
static NSArray<NSString *> *gAppHeaderNames;  // for the log
static BOOL gOwnSessionOnly;  // the app's session wouldn't carry Jax Reddit Eclipse's requests: its own from then on
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

// The app's own way of hiding a post (see "The app's own way").
static NSString *const kHRAppHideRequestKey = @"HRAppHideRequest";  // in the user defaults
static NSString *const kHRPostPlaceholder = @"__JaxRedditEclipsePost__";
static const NSTimeInterval kHRAppWayGap = 3;       // between posts hidden that way
static NSDictionary *gAppHideRequest;               // url, body, headers, operation, confirmed
static NSUInteger gAppWayFailures;                  // in a row
static NSUInteger gAppWayLogged;                    // posts hidden that way since the last line in the log about it
static NSMutableOrderedSet<NSString *> *gChecked;   // checked as not yours, waiting to be hidden that way
static BOOL gToldUncheckedAuthors;                  // the log said who posted them couldn't be looked up
static BOOL gToldAppWay;                            // the log named the first post hidden that way

static void HRSendBatch(void);
static BOOL HRCanHideTheAppsWay(void);
static NSMutableURLRequest *HRGetRequest(NSString *url, NSDictionary<NSString *, NSString *> *query,
                                         NSString *authorization);
static NSURLSessionDataTask *HRTaskFor(NSMutableURLRequest *request, BOOL graphQL,
                                       void (^handler)(NSData *data, NSURLResponse *response, NSError *error));

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
  BOOL canSend = (gAuthorization && !gStopped) || HRCanHideTheAppsWay();
  if (waiting && canSend && gNextAllowed - CFAbsoluteTimeGetCurrent() < 20) return;
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

// The app's own hide request, as learned (see "The app's own way"), from the
// user defaults: only one with everything in place.
static void HRLoadAppHideRequest(void) {
  id saved = [NSUserDefaults.standardUserDefaults dictionaryForKey:kHRAppHideRequestKey];
  if (![saved isKindOfClass:NSDictionary.class]) return;
  NSDictionary *request = saved;
  if (![request[@"url"] isKindOfClass:NSString.class] || ![request[@"body"] isKindOfClass:NSString.class] ||
      ![(NSString *)request[@"body"] containsString:kHRPostPlaceholder] ||
      ![request[@"headers"] isKindOfClass:NSDictionary.class])
    return;
  gAppHideRequest = request;
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
    gAnonymousSignIns = [NSMutableArray array];
    gRecentSignIns = [NSMutableOrderedSet orderedSet];
    gRecentGraphQLSignIns = [NSMutableOrderedSet orderedSet];
    gUnhide = [NSMutableOrderedSet orderedSet];
    gToCheck = [NSMutableOrderedSet orderedSet];
    gChecked = [NSMutableOrderedSet orderedSet];
    gRecord = [NSMutableDictionary dictionary];
    // Off the calling thread, and before anything else runs on the queue.
    dispatch_async(gQueue, ^{
      HRLoadRecord();
      HRMirrorRecord();
      HRLoadAppHideRequest();
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
  if (!gAuthorization || gStopped) return NO;
  if (HRNeedsAccount()) return gPending.count > 0 || HRBulkCanSend() || HRCanTidyUp();
  return HRCanTidyUp() && (gUnhide.count > 0 || gToCheck.count > 0 || HRNeedsOwnList());
}

// Sends now if a batch is full (or as soon as the pause allows), there's a
// lookup to do, or Reddit is leaving the screen, otherwise in up to 10 seconds.
static void HRConsiderSending(void) {
  if (gSending) return;
  BOOL appsWay = (!gAuthorization || gStopped) && HRCanHideTheAppsWay();
  if (gStopped && !appsWay) return;
  BOOL housekeeping = HRHousekeepingDue();
  if (!housekeeping && !gPending.count && !HRBulkCanSend()) return;
  if (!gAuthorization && !appsWay) {
    if (!gToldWaiting) {
      gToldWaiting = YES;
      HRLog(@"[account] %lu posts waiting for the Reddit app's sign-in to hide them on your account",
            (unsigned long)(gPending.count + gBulk.count));
    }
    return;
  }
  NSTimeInterval wait = MAX(0, gNextAllowed - CFAbsoluteTimeGetCurrent());
  if (housekeeping || HRBulkCanSend() || gPending.count >= kHRBatchSize || !gAppActive ||
      (appsWay && gChecked.count))
    HRArmSend(wait);
  else if (!gTimerArmed)
    HRArmSend(MAX(wait, kHRGatherDelay));
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
    NSMutableURLRequest *request = HRGetRequest(kHRInfoURL, @{@"id" : postID, @"raw_json" : @"1"}, authorization);
    NSURLSessionDataTask *task = HRTaskFor(
        request, NO, ^(NSData *data, NSURLResponse *response, NSError *error) {
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
          });
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

// Reddit's API answered your account's lookup (/api/v1/me) for this sign-in as
// if no one were logged in: it can't hide posts on your account, so it isn't
// used again (until "Hide All Read Posts Now"), and isn't tried every minute.
// Posts are hidden the app's own way instead, once that's been learned.
static void HRNoteLoggedOutSignIn(NSString *authorization, NSURLResponse *response) {
  if (authorization.length && ![gAnonymousSignIns containsObject:authorization]) {
    [gAnonymousSignIns addObject:authorization];
    if (gAnonymousSignIns.count > 8) [gAnonymousSignIns removeObjectAtIndex:0];
  }
  if ([gAuthorization isEqualToString:authorization]) gAuthorization = nil;
  gToldWaiting = NO;
  gProblem = @"Reddit’s API answers the Reddit app’s sign-in as if no one were logged in.";
  NSString *headers = HRPref(HRPrefDiagnostics) && gAppHeaderNames.count
                          ? [NSString stringWithFormat:@"; sent with the app's headers %@",
                                                       [gAppHeaderNames componentsJoinedByString:@", "]]
                          : @"";
  HRLog(@"[account] Reddit's API answers sign-in %@ as if no one were logged in (HTTP %ld from %@ with no account "
        @"in it%@), so it isn't used to hide posts; %@",
        HRSignInTag(authorization), (long)HRStatusCode(response), response.URL.path ?: @"?", headers,
        HRCanHideTheAppsWay() ? @"they're hidden the Reddit app's own way instead"
        : gAppHideRequest     ? @"they'll be hidden the Reddit app's own way once your account is known"
                              : @"to hide them anyway, hide one post yourself (⋯ → Hide post), and the rest are "
                                @"hidden the same way");
  if (!HRCanHideTheAppsWay())
    HRTellProblem(@"Couldn’t hide your read posts: Reddit’s API answers the Reddit app’s sign-in as if no one were "
                  @"logged in. Hide one post yourself (⋯ → Hide post), and Jax Reddit Eclipse will hide the rest the "
                  @"same way.");
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

// The headers of the app's requests that Jax Reddit Eclipse's own carry too: those
// that say who's asking (device, session, app version, language). Not those
// about the request itself (its body, its GraphQL operation, a signature,
// tracing), cookies (the session adds its own), or the sign-in (set apart).
static BOOL HRIsCopiedHeader(NSString *name) {
  static NSSet<NSString *> *skipped;
  static dispatch_once_t once;
  dispatch_once(&once, ^{
    skipped = [NSSet setWithArray:@[
      @"authorization", @"content-type", @"content-length", @"content-md5", @"accept", @"host", @"connection",
      @"cookie", @"expect", @"te", @"transfer-encoding", @"traceparent", @"tracestate"
    ]];
  });
  NSString *lowered = name.lowercaseString;
  if (!lowered.length || [skipped containsObject:lowered]) return NO;
  for (NSString *fragment in @[
         @"apollo", @"operation", @"encoding", @"compression", @"signature", @"signed", @"hmac", @"request-id",
         @"requestid", @"retry", @"trace", @"span", @"b3"
       ])
    if ([lowered containsString:fragment]) return NO;
  return YES;
}

// The app's headers that say who's asking, then the sign-in.
static void HRDressRequest(NSMutableURLRequest *request, NSString *authorization) {
  for (NSString *name in gAppHeaders) [request setValue:gAppHeaders[name] forHTTPHeaderField:name];
  if (gUserAgent && ![request valueForHTTPHeaderField:@"User-Agent"])
    [request setValue:gUserAgent forHTTPHeaderField:@"User-Agent"];
  [request setValue:authorization forHTTPHeaderField:@"Authorization"];
}

// A task for one of Jax Reddit Eclipse's own requests to Reddit: marked as its own
// (the network hooks let it through untouched), and through the app's own
// session (with `graphQL`, the one for its GraphQL requests), so it goes out
// with the app's cookies and settings; else through its own session.
// A request the connection itself refused or cut off (a certificate the app's
// session won't accept from Jax Reddit Eclipse, say), rather than Reddit's answer.
static BOOL HRIsConnectionRefusal(NSError *error) {
  if (![error.domain isEqualToString:@"NSURLErrorDomain"]) return NO;
  switch (error.code) {
    case NSURLErrorCancelled:
    case NSURLErrorUserCancelledAuthentication:
    case NSURLErrorSecureConnectionFailed:
    case NSURLErrorServerCertificateHasBadDate:
    case NSURLErrorServerCertificateUntrusted:
    case NSURLErrorServerCertificateHasUnknownRoot:
    case NSURLErrorServerCertificateNotYetValid:
    case NSURLErrorClientCertificateRejected:
    case NSURLErrorClientCertificateRequired:
      return YES;
    default:
      return NO;
  }
}

static NSURLSessionDataTask *HRTaskFor(NSMutableURLRequest *request, BOOL graphQL,
                                       void (^handler)(NSData *data, NSURLResponse *response, NSError *error)) {
  [NSURLProtocol setProperty:@YES forKey:kHROwnRequestKey inRequest:request];
  request.cachePolicy = NSURLRequestReloadIgnoringLocalCacheData;
  NSURLSession *session = gOwnSessionOnly ? nil
                          : graphQL       ? (gAppGraphQLSession ?: gAppSession)
                                          : (gAppSession ?: gAppGraphQLSession);
  if (session && session != gSession) {
    // If the app's session won't carry it, Jax Reddit Eclipse's own session from then on.
    void (^watched)(NSData *, NSURLResponse *, NSError *) = ^(NSData *data, NSURLResponse *response, NSError *error) {
      if (HRIsConnectionRefusal(error))
        dispatch_async(gQueue, ^{
          if (gOwnSessionOnly) return;
          gOwnSessionOnly = YES;
          HRLog(@"[account] the Reddit app's session wouldn't carry a request (%@); using Jax Reddit Eclipse's own",
                error.localizedDescription);
        });
      handler(data, response, error);
    };
    @try {
      NSURLSessionDataTask *task = [session dataTaskWithRequest:request completionHandler:watched];
      if (task) return task;
    } @catch (NSException *exception) {
      // The app let that session go: Jax Reddit Eclipse's own until the app's next request.
      HRLog(@"[account] the Reddit app's session couldn't take a request (%@); using Jax Reddit Eclipse's own",
            exception.reason);
      if (gAppSession == session) gAppSession = nil;
      if (gAppGraphQLSession == session) gAppGraphQLSession = nil;
    }
  }
  return [gSession dataTaskWithRequest:request completionHandler:handler];
}

// A GET request to Reddit with the app's sign-in.
static NSMutableURLRequest *HRGetRequest(NSString *url, NSDictionary<NSString *, NSString *> *query,
                                         NSString *authorization) {
  NSURLComponents *components = [NSURLComponents componentsWithString:url];
  NSMutableArray<NSURLQueryItem *> *items = [NSMutableArray array];
  for (NSString *name in query) [items addObject:[NSURLQueryItem queryItemWithName:name value:query[name]]];
  components.queryItems = items;
  NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:components.URL];
  HRDressRequest(request, authorization);
  return request;
}

// POST /api/hide or /api/unhide for `postIDs`, with the app's sign-in.
static NSMutableURLRequest *HRPostsRequest(NSString *url, NSArray<NSString *> *postIDs, NSString *authorization) {
  NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:url]];
  request.HTTPMethod = @"POST";
  HRDressRequest(request, authorization);
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
static void HRSend(NSMutableURLRequest *request, NSTimeInterval gap, BOOL graphQL,
                   void (^done)(NSData *data, NSURLResponse *response, NSError *error)) {
  gSending = YES;
  if (!gAppActive) gBackgroundSends++;
  gNextAllowed = MAX(gNextAllowed, CFAbsoluteTimeGetCurrent() + gap);
  NSURLSessionDataTask *task = HRTaskFor(request, graphQL, ^(NSData *data, NSURLResponse *response, NSError *error) {
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
  });
  [task resume];
}

static void HRSendHide(NSArray<NSString *> *batch, NSString *authorization) {
  HRSend(HRPostsRequest(kHRHideURL, batch, authorization), HRBulkCanSend() ? kHRBulkGap : kHRMinGap, NO,
         ^(NSData *data, NSURLResponse *response, NSError *error) {
           HRHandleAnswer(batch, response, error, data, authorization);
         });
}

// Before a batch is hidden, Reddit is asked who posted each post in it (GET
// /api/info). Yours are left out, and never hidden; the rest go right after.
static void HRCheckThenHide(NSArray<NSString *> *batch) {
  NSString *authorization = gAuthorization;
  NSMutableURLRequest *request =
      HRGetRequest(kHRInfoURL, @{@"id" : [batch componentsJoinedByString:@","], @"raw_json" : @"1"}, authorization);
  HRSend(request, kHRLookUpGap, NO, ^(NSData *data, NSURLResponse *response, NSError *error) {
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
  HRSend(HRGetRequest(kHRMeURL, @{@"raw_json" : @"1"}, authorization), kHRLookUpGap, NO,
         ^(NSData *data, NSURLResponse *response, NSError *error) {
           NSInteger status = HRStatusCode(response);
           id json = !error && status >= 200 && status < 300 && data.length
                         ? [NSJSONSerialization JSONObjectWithData:data options:0 error:NULL]
                         : nil;
           id name = [json isKindOfClass:NSDictionary.class] ? ((NSDictionary *)json)[@"name"] : nil;
           id ident = [json isKindOfClass:NSDictionary.class] ? ((NSDictionary *)json)[@"id"] : nil;
           if (![name isKindOfClass:NSString.class] || ![(NSString *)name length]) {
             if ([json isKindOfClass:NSDictionary.class])
               HRNoteLoggedOutSignIn(authorization, response);
             else
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
         kHRLookUpGap, NO, ^(NSData *data, NSURLResponse *response, NSError *error) {
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
  NSMutableURLRequest *request =
      HRGetRequest(kHRInfoURL, @{@"id" : [chunk componentsJoinedByString:@","], @"raw_json" : @"1"}, authorization);
  HRSend(request, kHRLookUpGap, NO, ^(NSData *data, NSURLResponse *response, NSError *error) {
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
  HRSend(HRPostsRequest(kHRUnhideURL, batch, authorization), kHRBulkGap, NO,
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

#pragma mark - The app's own way

// When Reddit's API won't take the app's sign-in (it turns it down, or answers
// as if no one were logged in), posts are hidden the way the app itself hides
// one: its own GraphQL request for ⋯ → Hide post. Jax Reddit Eclipse learns it
// the first time you hide a post yourself, once Reddit says that worked: what
// the request goes to, its body with the post left out, and its headers about
// the request itself (the operation). That's kept in the user defaults, never
// the sign-in or anything that says who you are. Each read post then goes the
// same way, one at a time, every 3 seconds (2 during "Hide All Read Posts
// Now"), through the app's own session with the headers and sign-in of its
// latest GraphQL request. Before a post goes, Reddit is asked who posted it
// (GET /api/info, 25 at a time), and yours are left out; if Reddit won't say,
// it goes by the posts known to be yours. It only runs once your account is
// known, so your posts can be told apart. Three posts in a row Reddit won't
// hide that way (or one, for a request learned without seeing Reddit's answer)
// and it's forgotten until you hide a post yourself again: the app may have
// changed how it does it.

// Not a request to hide a post: one to unhide (or undo a hide), report, block
// or remove.
static BOOL HRIsOtherAction(NSString *lowered) {
  for (NSString *word in @[
         @"unhid", @"undo", @"restore", @"report", @"block", @"mute", @"spam", @"remove", @"delete", @"ban", @"flag",
         @"award", @"vote", @"save", @"follow", @"subscri", @"comment", @"subreddit", @"community", @"user",
         @"redditor"
       ])
    if ([lowered containsString:word]) return YES;
  return NO;
}

// Whether the variables say to unhide (a state of "NONE", isHidden: false...),
// or carry what goes with a report (a reason, a rule).
static BOOL HRVariablesSayOtherwise(id object, NSString *key, NSUInteger depth) {
  if (depth > 5) return YES;
  NSString *loweredKey = key.lowercaseString ?: @"";
  for (NSString *word in @[ @"reason", @"rule", @"report", @"message", @"comment" ])
    if ([loweredKey containsString:word]) return YES;
  if ([object isKindOfClass:NSDictionary.class]) {
    for (id childKey in (NSDictionary *)object)
      if (HRVariablesSayOtherwise(((NSDictionary *)object)[childKey],
                                  [childKey isKindOfClass:NSString.class] ? childKey : nil, depth + 1))
        return YES;
    return NO;
  }
  if ([object isKindOfClass:NSArray.class]) {
    for (id child in (NSArray *)object)
      if (HRVariablesSayOtherwise(child, key, depth + 1)) return YES;
    return NO;
  }
  BOOL stateKey = [loweredKey containsString:@"hid"] || [loweredKey containsString:@"state"];
  if (stateKey && [object isKindOfClass:NSString.class]) {
    NSString *value = [(NSString *)object lowercaseString];
    return [@[ @"none", @"unhidden", @"unhide", @"visible", @"shown", @"not_hidden", @"nothidden", @"false" ]
        containsObject:value];
  }
  if (stateKey && [object isKindOfClass:NSNumber.class]) return ![(NSNumber *)object boolValue];
  return NO;
}

// The posts ("t3_...", the whole string) anywhere in the variables.
static void HRCollectPostIDs(id object, NSUInteger depth, NSMutableSet<NSString *> *found) {
  if (depth > 6 || found.count > 2) return;
  if ([object isKindOfClass:NSString.class]) {
    NSString *string = object;
    if (string.length > 3 && [string hasPrefix:@"t3_"] &&
        [string rangeOfString:@"^t3_[0-9a-z]+$" options:NSRegularExpressionSearch].location != NSNotFound)
      [found addObject:string];
  } else if ([object isKindOfClass:NSDictionary.class]) {
    for (id value in [(NSDictionary *)object allValues]) HRCollectPostIDs(value, depth + 1, found);
  } else if ([object isKindOfClass:NSArray.class]) {
    for (id value in (NSArray *)object) HRCollectPostIDs(value, depth + 1, found);
  }
}

// `object` with every string that is `postID` swapped for the placeholder;
// `count` says how many.
static id HRWithPlaceholder(id object, NSString *postID, NSUInteger depth, NSUInteger *count) {
  if (depth > 8) return object;
  if ([object isKindOfClass:NSString.class]) {
    if (![(NSString *)object isEqualToString:postID]) return object;
    (*count)++;
    return kHRPostPlaceholder;
  }
  if ([object isKindOfClass:NSDictionary.class]) {
    NSMutableDictionary *copy = [NSMutableDictionary dictionary];
    [(NSDictionary *)object enumerateKeysAndObjectsUsingBlock:^(id key, id value, BOOL *stop) {
      copy[key] = HRWithPlaceholder(value, postID, depth + 1, count);
    }];
    return copy;
  }
  if ([object isKindOfClass:NSArray.class]) {
    NSMutableArray *copy = [NSMutableArray array];
    for (id value in (NSArray *)object) [copy addObject:HRWithPlaceholder(value, postID, depth + 1, count)];
    return copy;
  }
  return object;
}

// If `request` is the app hiding one post (⋯ → Hide post): what Jax Reddit
// Eclipse keeps of it (url, body with the post left out, headers about the
// request, operation), and the post in `postIDOut`. Nil for anything else. Any
// thread.
static NSDictionary *HRLearnableHideRequest(NSURLRequest *request, NSData *body, NSString **postIDOut) {
  if (![request.HTTPMethod.uppercaseString isEqualToString:@"POST"] || body.length == 0 || body.length > 16 * 1024)
    return nil;
  // Most requests name their operation in a header: no need to read their body.
  NSString *named = [request valueForHTTPHeaderField:@"X-APOLLO-OPERATION-NAME"].lowercaseString;
  if (named.length && ![named containsString:@"hide"] && ![named containsString:@"hidden"]) return nil;
  NSString *operation = nil;
  NSDictionary *variables = nil;
  HRParseGraphQLRequest(request, body, &operation, &variables);
  NSString *lowered = operation.lowercaseString;
  if (![lowered containsString:@"hide"] && ![lowered containsString:@"hidden"]) return nil;
  if (HRIsOtherAction(lowered) || !variables.count) return nil;
  NSData *variablesData = [NSJSONSerialization dataWithJSONObject:variables options:0 error:NULL];
  if (!variablesData || variablesData.length > 600 || HRVariablesSayOtherwise(variables, nil, 0)) return nil;
  NSMutableSet<NSString *> *postIDs = [NSMutableSet set];
  HRCollectPostIDs(variables, 0, postIDs);
  if (postIDs.count != 1) return nil;
  NSString *postID = postIDs.anyObject;

  id json = [NSJSONSerialization JSONObjectWithData:body options:0 error:NULL];
  if (![json isKindOfClass:NSDictionary.class] || ![((NSDictionary *)json)[@"variables"] isKindOfClass:NSDictionary.class])
    return nil;
  NSMutableDictionary *template = [(NSDictionary *)json mutableCopy];
  NSUInteger replaced = 0;
  template[@"variables"] = HRWithPlaceholder(template[@"variables"], postID, 0, &replaced);
  if (!replaced) return nil;
  NSData *templateData = [NSJSONSerialization dataWithJSONObject:template
                                                         options:NSJSONWritingWithoutEscapingSlashes
                                                           error:NULL];
  NSString *templateBody = templateData ? [[NSString alloc] initWithData:templateData encoding:NSUTF8StringEncoding] : nil;
  NSString *url = request.URL.absoluteString;
  if (!templateBody.length || !url.length) return nil;

  // Only the headers about the request itself: who's asking comes from the app's
  // latest request each time.
  NSMutableDictionary<NSString *, NSString *> *headers = [NSMutableDictionary dictionary];
  [request.allHTTPHeaderFields enumerateKeysAndObjectsUsingBlock:^(NSString *name, NSString *value, BOOL *stop) {
    NSString *lowerName = name.lowercaseString;
    if ([lowerName containsString:@"apollo"] || [lowerName containsString:@"operation"] ||
        [lowerName isEqualToString:@"content-type"] || [lowerName isEqualToString:@"accept"])
      headers[name] = value;
  }];
  if (postIDOut) *postIDOut = postID;
  return @{@"url" : url, @"body" : templateBody, @"headers" : headers, @"operation" : operation};
}

// Whether Reddit says a GraphQL request worked: HTTP 2xx, JSON with data, no
// errors, and nothing in it that says it didn't ("ok": false). Otherwise
// `problem` says what Reddit said.
static BOOL HRSaysNotDone(id object, NSUInteger depth) {
  if (depth > 4) return NO;
  if ([object isKindOfClass:NSDictionary.class]) {
    NSDictionary *dict = object;
    for (id key in dict) {
      id value = dict[key];
      NSString *lowered = [key isKindOfClass:NSString.class] ? [(NSString *)key lowercaseString] : @"";
      if (([lowered isEqualToString:@"ok"] || [lowered isEqualToString:@"success"] ||
           [lowered isEqualToString:@"issuccess"]) &&
          [value isKindOfClass:NSNumber.class] && ![(NSNumber *)value boolValue])
        return YES;
      if ([lowered isEqualToString:@"errors"] && [value isKindOfClass:NSArray.class] && [(NSArray *)value count])
        return YES;
      if (HRSaysNotDone(value, depth + 1)) return YES;
    }
  } else if ([object isKindOfClass:NSArray.class]) {
    for (id value in (NSArray *)object)
      if (HRSaysNotDone(value, depth + 1)) return YES;
  }
  return NO;
}

static BOOL HRAppWaySucceeded(NSData *data, NSURLResponse *response, NSError *error,
                              NSString *__strong *problem) {
  NSInteger status = HRStatusCode(response);
  if (error) {
    *problem = error.localizedDescription;
    return NO;
  }
  NSString *excerpt = HRAnswerExcerpt(data);
  if (status < 200 || status >= 300) {
    *problem = [NSString stringWithFormat:@"HTTP %ld%@", (long)status, excerpt];
    return NO;
  }
  id json = data.length ? [NSJSONSerialization JSONObjectWithData:data options:0 error:NULL] : nil;
  if (![json isKindOfClass:NSDictionary.class]) {
    *problem = [@"an answer that isn't JSON" stringByAppendingString:excerpt];
    return NO;
  }
  id errors = ((NSDictionary *)json)[@"errors"];
  if ([errors isKindOfClass:NSArray.class] && [(NSArray *)errors count]) {
    id first = [(NSArray *)errors firstObject];
    id message = [first isKindOfClass:NSDictionary.class] ? ((NSDictionary *)first)[@"message"] : nil;
    *problem = [message isKindOfClass:NSString.class] ? message : [@"errors" stringByAppendingString:excerpt];
    return NO;
  }
  id payload = ((NSDictionary *)json)[@"data"];
  BOOL anything = NO;
  if ([payload isKindOfClass:NSDictionary.class])
    for (id value in [(NSDictionary *)payload allValues])
      if (value != NSNull.null) anything = YES;
  if (!anything || HRSaysNotDone(payload, 0)) {
    *problem = [@"an answer that says it didn't" stringByAppendingString:excerpt];
    return NO;
  }
  return YES;
}

// The sign-in to hide posts with the app's own way: the latest one on the app's
// GraphQL requests, but not one Reddit's API answers as if no one were logged in
// while the app has another (it can use more than one).
static NSString *HRGraphQLSignIn(void) {
  for (NSString *signIn in gRecentGraphQLSignIns.reverseObjectEnumerator)
    if (![gAnonymousSignIns containsObject:signIn]) return signIn;
  return gRecentGraphQLSignIns.lastObject;
}

// The sign-in to look posts up with (who posted them, which is public): the
// latest one Reddit hasn't turned down.
static NSString *HRLookUpSignIn(void) {
  for (NSString *signIn in gRecentSignIns.reverseObjectEnumerator)
    if (![gRefusedSignIns containsObject:signIn]) return signIn;
  return gRecentSignIns.lastObject;
}

static BOOL HRCanHideTheAppsWay(void) {
  return gAppHideRequest && gRecentGraphQLSignIns.count && HRKnowsOwnAccount();
}

// The app hid a post, and Reddit said that worked (or, for a request Jax Reddit
// Eclipse couldn't see the answer to, `confirmed` is NO): kept as the way to hide
// posts while Reddit's API won't take the sign-in. A confirmed one isn't
// replaced by an unconfirmed one.
static void HRLearnAppHideRequest(NSDictionary *learned, NSString *postID, BOOL confirmed) {
  if (!confirmed && [gAppHideRequest[@"confirmed"] boolValue]) return;
  BOOL same = [gAppHideRequest[@"body"] isEqual:learned[@"body"]] && [gAppHideRequest[@"url"] isEqual:learned[@"url"]];
  BOOL could = HRCanHideTheAppsWay();
  NSMutableDictionary *saved = [learned mutableCopy];
  saved[@"confirmed"] = @(confirmed);
  gAppHideRequest = saved;
  gAppWayFailures = 0;
  [NSUserDefaults.standardUserDefaults setObject:saved forKey:kHRAppHideRequestKey];
  // That post is on your Hidden list now, if it was a read post (not one of
  // yours): it isn't sent again.
  if (confirmed && postID && !HRIsOwnPost(postID) &&
      ([gPending containsObject:postID] || [gBulk containsObject:postID] ||
       [HideReadStore.sharedStore containsPostID:postID])) {
    gRecord[postID] = @(NSDate.date.timeIntervalSince1970);
    HRSaveRecordSoon();
    NSUInteger fromBulk = HRTakeOut(@[ postID ]);
    gBulkDone += fromBulk;
    gBulkHidden += fromBulk;
    [gChecked removeObject:postID];
  }
  if (!same || !could)
    HRLog(@"[account] learned how the Reddit app hides a post (%@%@): while Reddit's API won't take the app's "
          @"sign-in, read posts are hidden on your account that way%@",
          learned[@"operation"], confirmed ? @"" : @", not confirmed by Reddit yet",
          HRKnowsOwnAccount() ? @"" : @", once your account is known");
  if (gProblem && !gAuthorization) gProblem = nil;
  HRStatusChanged();
  HRConsiderSending();
}

static void HRForgetAppHideRequest(NSString *problem) {
  HRLog(@"[account] hiding posts the Reddit app's own way stopped working (%@); hide one post yourself (⋯ → Hide "
        @"post) to show Jax Reddit Eclipse again",
        problem);
  gAppHideRequest = nil;
  gAppWayFailures = 0;
  [NSUserDefaults.standardUserDefaults removeObjectForKey:kHRAppHideRequestKey];
  gProblem = @"Hiding posts the Reddit app’s own way stopped working.";
  HRTellProblem(@"Couldn’t hide your read posts the Reddit app’s own way. Hide one post yourself (⋯ → Hide post), "
                @"and Jax Reddit Eclipse will hide the rest the same way.");
}

// The app's hide request with `postID` in it, the app's latest headers and
// sign-in, or nil.
static NSMutableURLRequest *HRAppWayRequest(NSString *postID) {
  NSURL *url = [NSURL URLWithString:gAppHideRequest[@"url"]];
  NSString *body = [gAppHideRequest[@"body"] stringByReplacingOccurrencesOfString:kHRPostPlaceholder
                                                                        withString:postID];
  NSString *signIn = HRGraphQLSignIn();
  if (!url || !body.length || !signIn) return nil;
  NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:url];
  request.HTTPMethod = @"POST";
  NSDictionary *headers = gAppHideRequest[@"headers"];
  for (id name in headers)
    if ([name isKindOfClass:NSString.class] && [headers[name] isKindOfClass:NSString.class])
      [request setValue:headers[name] forHTTPHeaderField:name];
  HRDressRequest(request, signIn);
  if (![request valueForHTTPHeaderField:@"Content-Type"])
    [request setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];
  request.HTTPBody = [body dataUsingEncoding:NSUTF8StringEncoding];
  return request;
}

static void HRAppWayFailed(NSString *postID, NSURLResponse *response, NSError *error, NSString *problem,
                           NSDictionary *used) {
  NSInteger status = HRStatusCode(response);
  if (error || status == 0 || status == 401 || status == 408 || status == 429 || status >= 500) {
    // No connection, trouble on Reddit's side, too many requests, or a sign-in
    // that just ran out (the app's next request brings a new one): a pause.
    gBackoff = gBackoff ? MIN(gBackoff * 2, kHRMaxBackoff) : 60;
    gNextAllowed = MAX(gNextAllowed, CFAbsoluteTimeGetCurrent() + gBackoff);
    gProblem = [NSString stringWithFormat:@"Couldn’t reach Reddit to hide posts (%@).",
                                          error ? error.localizedDescription
                                                : [NSString stringWithFormat:@"HTTP %ld", (long)status]];
    HRLog(@"[account] couldn't hide %@ the Reddit app's own way (%@); trying again in %.0f seconds",
          HRDescribePost(postID), problem, gBackoff);
    HRTellProblem([gProblem stringByAppendingFormat:@" Trying again in %.0f seconds.", gBackoff]);
    return;
  }
  if (used != gAppHideRequest) return;  // learned again meanwhile
  gAppWayFailures++;
  if (![used[@"confirmed"] boolValue] || gAppWayFailures >= 3 ||
      [problem.lowercaseString containsString:@"persisted"]) {
    HRForgetAppHideRequest(problem);
    return;
  }
  // Reddit won't hide this one (it was deleted, say): left out rather than sent forever.
  gBulkDone += HRTakeOut(@[ postID ]);
  [gChecked removeObject:postID];
  HRLog(@"[account] Reddit wouldn't hide %@ the Reddit app's own way (%@); left it out", HRDescribePost(postID),
        problem);
}

static void HRHideTheAppsWay(NSString *postID) {
  NSMutableURLRequest *request = HRAppWayRequest(postID);
  if (!request) {
    HRForgetAppHideRequest(@"it couldn't be made into a request");
    return;
  }
  BOOL bulkRunning = gBulkTotal > 0;
  NSDictionary *used = gAppHideRequest;
  HRSend(request, HRBulkCanSend() ? kHRBulkGap : kHRAppWayGap, YES,
         ^(NSData *data, NSURLResponse *response, NSError *error) {
           NSString *problem = nil;
           if (HRAppWaySucceeded(data, response, error, &problem)) {
             gRecord[postID] = @(NSDate.date.timeIntervalSince1970);
             HRSaveRecordSoon();
             NSUInteger fromBulk = HRTakeOut(@[ postID ]);
             gBulkDone += fromBulk;
             gBulkHidden += fromBulk;
             [gChecked removeObject:postID];
             gAppWayFailures = 0;
             gProblem = nil;
             gHiddenThisRun++;
             if (used == gAppHideRequest && ![used[@"confirmed"] boolValue]) {
               NSMutableDictionary *confirmed = [used mutableCopy];
               confirmed[@"confirmed"] = @YES;
               gAppHideRequest = confirmed;
               [NSUserDefaults.standardUserDefaults setObject:confirmed forKey:kHRAppHideRequestKey];
             }
             // The first one, then every 25, and when nothing's left.
             NSUInteger waiting = gPending.count + gBulk.count;
             gAppWayLogged++;
             if (!gToldAppWay || gAppWayLogged >= 25 || !waiting) {
               HRLog(@"[account] hid %@ on your Reddit account the Reddit app's own way (%lu since Reddit "
                     @"opened, %lu waiting)",
                     gAppWayLogged > 1 ? [NSString stringWithFormat:@"%lu more posts", (unsigned long)gAppWayLogged]
                                       : HRDescribePost(postID),
                     (unsigned long)gHiddenThisRun, (unsigned long)waiting);
               gToldAppWay = YES;
               gAppWayLogged = 0;
             }
           } else {
             HRAppWayFailed(postID, response, error, problem, used);
           }
           if (bulkRunning && !gBulk.count) HRFinishBulk();
         });
}

// Who posted the next posts to hide the app's own way (GET /api/info): yours
// are left out. If Reddit won't say, it goes by the posts known to be yours.
static void HRCheckAuthorsTheAppsWay(NSArray<NSString *> *batch) {
  NSString *authorization = HRLookUpSignIn();
  NSMutableURLRequest *request =
      HRGetRequest(kHRInfoURL, @{@"id" : [batch componentsJoinedByString:@","], @"raw_json" : @"1"}, authorization);
  HRSend(request, kHRLookUpGap, NO, ^(NSData *data, NSURLResponse *response, NSError *error) {
    NSInteger status = HRStatusCode(response);
    BOOL bulkRunning = gBulkTotal > 0;
    NSDictionary<NSString *, NSDictionary *> *posts =
        !error && status >= 200 && status < 300 ? HRPostsInListing(data) : nil;
    if (!posts && (error || status == 0 || status == 408 || status == 429 || status >= 500)) {
      gBackoff = gBackoff ? MIN(gBackoff * 2, kHRMaxBackoff) : 60;
      gNextAllowed = MAX(gNextAllowed, CFAbsoluteTimeGetCurrent() + gBackoff);
      HRLog(@"[account] couldn't look up who posted the posts to hide (%@); trying again in %.0f seconds",
            error ? error.localizedDescription : [NSString stringWithFormat:@"HTTP %ld", (long)status], gBackoff);
      return;
    }
    if (!posts && !gToldUncheckedAuthors) {
      gToldUncheckedAuthors = YES;
      HRLog(@"[account] Reddit won't say who posted the posts to hide (HTTP %ld%@); going by the posts known to "
            @"be yours",
            (long)status, HRAnswerExcerpt(data));
    }
    NSMutableArray<NSString *> *yours = [NSMutableArray array];
    for (NSString *postID in batch) {
      NSDictionary *post = posts[postID];
      if (HRIsOwnPost(postID) || (post && HRIsYours(post))) {
        [yours addObject:postID];
        continue;
      }
      if ([gPending containsObject:postID] || [gBulk containsObject:postID]) [gChecked addObject:postID];
    }
    if (yours.count) {
      for (NSString *postID in yours)
        if (!HRIsOwnPost(postID))
          HRLog(@"[own] %@ is your post, so it isn't hidden on your account", HRDescribePost(postID));
      HRDropFromQueues(yours);
      HRAddOwnPosts(yours);
      if (bulkRunning && !gBulk.count) HRFinishBulk();
    }
  });
}

// The next step the app's own way: a post already checked, else the next 25 to check.
static void HRSendTheAppsWay(void) {
  NSMutableArray<NSString *> *gone = [NSMutableArray array];
  NSString *next = nil;
  for (NSString *postID in gChecked) {
    BOOL pending = [gPending containsObject:postID];
    BOOL bulk = [gBulk containsObject:postID];
    if ((!pending && !bulk) || HRIsOwnPost(postID)) {
      [gone addObject:postID];
      continue;
    }
    if (!next && (pending || HRBulkCanSend())) next = postID;
  }
  [gChecked removeObjectsInArray:gone];
  if (next) {
    HRHideTheAppsWay(next);
    return;
  }
  NSMutableOrderedSet<NSString *> *batch = [NSMutableOrderedSet orderedSet];
  for (NSString *postID in gPending) {
    if (batch.count == kHRBatchSize) break;
    if (![gChecked containsObject:postID]) [batch addObject:postID];
  }
  if (HRBulkCanSend())
    for (NSString *postID in gBulk) {
      if (batch.count == kHRBatchSize) break;
      if (![gChecked containsObject:postID]) [batch addObject:postID];
    }
  if (batch.count) HRCheckAuthorsTheAppsWay([[NSArray alloc] initWithArray:batch.array]);
}

// What goes to Reddit next, one request at a time: your account, for a new
// sign-in; while Reddit is open, your posts to unhide, your newest posts to
// list, and the record to check for yours; then posts to hide, those just
// counted as read first, then the read history, each batch checked for yours.
// While Reddit's API won't take the app's sign-in: the app's own way.
static void HRSendBatch(void) {
  if (gSending) return;
  BOOL appsWay = (!gAuthorization || gStopped) && HRCanHideTheAppsWay();
  if (gStopped && !appsWay) return;
  if (gPending.count && !HRAccountHidingOn()) {
    // Turned off since these were counted.
    [gPending removeAllObjects];
    [gChecked removeAllObjects];
    HRSavePending();
    HRStatusChanged();
  }
  if (!HRHousekeepingDue() && !gPending.count && !HRBulkCanSend()) return;
  if (!gAuthorization && !appsWay) {
    HRConsiderSending();  // waits for the app's sign-in
    return;
  }
  CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
  if (now < gNextAllowed) {
    HRArmSend(gNextAllowed - now);
    return;
  }
  if (appsWay) {
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
    HRSendTheAppsWay();
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

  BOOL apiRefused = gStopped || gRefusedSignIns.count > 0 || gAnonymousSignIns.count > 0;
  BOOL appsWay = (!gAuthorization || gStopped) && HRCanHideTheAppsWay();
  if (appsWay && waiting) {
    if (gProblem && gNextAllowed > now + 1)
      [parts addObject:[gProblem stringByAppendingFormat:@" Trying again in %.0f seconds.", gNextAllowed - now]];
    else
      [parts addObject:[NSString stringWithFormat:@"Hiding them the Reddit app’s own way, one at a time: %@ "
                                                  @"waiting.",
                                                  HRCount(waiting)]];
  } else if (waiting && (gStopped || !gAuthorization) && apiRefused) {
    // Reddit's API won't take the app's sign-in, and the app's own way isn't ready.
    NSString *why = gStopped ? @"Reddit refused the app’s sign-in three times."
                             : (gProblem ?: @"Reddit’s API won’t take the Reddit app’s sign-in.");
    NSString *next = gAppHideRequest ? @" Waiting to learn which Reddit account is yours, so your own posts are "
                                       @"never hidden."
                                     : @" To hide them anyway, hide one post yourself (⋯ → Hide post): Jax Reddit "
                                       @"Eclipse then hides the rest the same way.";
    [parts addObject:[why stringByAppendingString:next]];
  } else if (gStopped) {
    [parts addObject:@"Stopped: Reddit refused the app’s sign-in three times. Reopen Reddit to retry."];
  } else if (waiting && !gAuthorization)
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
    if (!gAuthorization && HRCanHideTheAppsWay())
      return @"Nothing waiting. Read posts go to your account the Reddit app’s own way.";
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

BOOL HRAccountHiderIsOwnRequest(NSURLRequest *request) {
  return request && [[NSURLProtocol propertyForKey:kHROwnRequestKey inRequest:request] boolValue];
}

// gql.reddit.com, gql-fed.reddit.com, cf.gql-fed.reddit.com...
static BOOL HRIsGraphQLHost(NSString *host) {
  for (NSString *label in [host.lowercaseString componentsSeparatedByString:@"."])
    if ([label hasPrefix:@"gql"]) return YES;
  return NO;
}

void HRAccountHiderNoteRequest(NSURLSession *session, NSURLRequest *request) {
  // Only from Reddit's API hosts (gql…, oauth…), the ones the hiding requests go
  // to: other Reddit hosts can carry other kinds of sign-in.
  if (!HRShouldProcessRequest(request) || HRAccountHiderIsOwnRequest(request)) return;
  NSString *host = request.URL.host;
  if (!session || (gSession && session == gSession)) return;  // our own
  NSDictionary *extra = session.configuration.HTTPAdditionalHeaders;
  NSString *authorization = [request valueForHTTPHeaderField:@"Authorization"];
  if (!authorization.length && [extra[@"Authorization"] isKindOfClass:NSString.class])
    authorization = extra[@"Authorization"];
  if (authorization.length < 40 ||
      [authorization rangeOfString:@"Bearer " options:NSCaseInsensitiveSearch | NSAnchoredSearch].location ==
          NSNotFound)
    return;
  NSString *agent = [request valueForHTTPHeaderField:@"User-Agent"];
  if (!agent.length && [extra[@"User-Agent"] isKindOfClass:NSString.class]) agent = extra[@"User-Agent"];
  // The headers that say who's asking, the session's and then the request's own.
  NSMutableDictionary<NSString *, NSString *> *headers = [NSMutableDictionary dictionary];
  NSMutableDictionary<NSString *, NSString *> *namesByLowered = [NSMutableDictionary dictionary];
  NSMutableSet<NSString *> *allNames = [NSMutableSet set];
  NSMutableArray<NSDictionary *> *headerSets = [NSMutableArray array];
  if ([extra isKindOfClass:NSDictionary.class]) [headerSets addObject:extra];
  if (request.allHTTPHeaderFields) [headerSets addObject:request.allHTTPHeaderFields];
  for (NSDictionary *fields in headerSets) {
    for (id name in fields) {
      id value = fields[name];
      if (![name isKindOfClass:NSString.class] || ![value isKindOfClass:NSString.class]) continue;
      NSString *lowered = [(NSString *)name lowercaseString];
      [allNames addObject:lowered];
      if (!HRIsCopiedHeader(name)) continue;
      NSString *previous = namesByLowered[lowered];
      if (previous) [headers removeObjectForKey:previous];
      namesByLowered[lowered] = name;
      headers[name] = value;
    }
  }
  NSArray<NSString *> *copiedNames = [namesByLowered.allKeys sortedArrayUsingSelector:@selector(compare:)];
  BOOL graphQL = HRIsGraphQLHost(host);
  NSString *path = request.URL.path ?: @"";
  HRSetUp();
  dispatch_async(gQueue, ^{
    if (agent.length) gUserAgent = agent;
    BOOL couldHideTheAppsWay = HRCanHideTheAppsWay();
    gAppSession = session;
    gAppHeaders = headers;
    gAppHeaderNames = copiedNames;
    [gRecentSignIns removeObject:authorization];
    [gRecentSignIns addObject:authorization];
    if (gRecentSignIns.count > 6) [gRecentSignIns removeObjectAtIndex:0];
    if (graphQL) {
      gAppGraphQLSession = session;
      [gRecentGraphQLSignIns removeObject:authorization];
      [gRecentGraphQLSignIns addObject:authorization];
      if (gRecentGraphQLSignIns.count > 4) [gRecentGraphQLSignIns removeObjectAtIndex:0];
    }
    if (HRPref(HRPrefDiagnostics))
      HRLogOnce(@"signin-headers", @"[account] the app's requests carry these headers: %@",
                [[allNames.allObjects sortedArrayUsingSelector:@selector(compare:)] componentsJoinedByString:@", "]);
    if ([authorization isEqualToString:gAuthorization] || [gRefusedSignIns containsObject:authorization] ||
        [gAnonymousSignIns containsObject:authorization]) {
      // The app's own way may have just become possible (its first GraphQL request).
      if (!couldHideTheAppsWay && HRCanHideTheAppsWay()) {
        HRStatusChanged();
        HRConsiderSending();
      }
      return;
    }
    BOOL first = !gAuthorization;
    gAuthorization = authorization;
    // Each sign-in once, with where it came from: the app may use more than one.
    HRLogOnce([@"signin:" stringByAppendingString:HRSignInTag(authorization)],
              @"[account] using the Reddit app's sign-in %@ (from a request to %@%@)", HRSignInTag(authorization),
              host, path);
    if (first) HRStatusChanged();
    HRConsiderSending();
  });
}

// The app's own hide request (⋯ → Hide post), seen going out: learned from once
// Reddit says it worked (see "The app's own way"). A request without a
// completion handler (streamed) is learned from as it is, and checked by the
// first post sent that way.
HRAccountCompletionHandler HRAccountHiderWatchRequest(NSURLRequest *request, NSData *body,
                                                      HRAccountCompletionHandler handler) {
  if (!body.length || HRAccountHiderIsOwnRequest(request) || !HRIsGraphQLHost(request.URL.host)) return handler;
  NSString *postID = nil;
  NSDictionary *learned = HRLearnableHideRequest(request, body, &postID);
  if (!learned) return handler;
  HRSetUp();
  if (!handler) {
    dispatch_async(gQueue, ^{
      HRLearnAppHideRequest(learned, postID, NO);
    });
    return handler;
  }
  return ^(NSData *data, NSURLResponse *response, NSError *error) {
    NSData *answer = [data copy];
    dispatch_async(gQueue, ^{
      NSString *problem = nil;
      if (HRAppWaySucceeded(answer, response, error, &problem))
        HRLearnAppHideRequest(learned, postID, YES);
      else
        HRLog(@"[account] the Reddit app tried to hide %@ (%@), but Reddit answered %@; not learned from",
              HRDescribePost(postID), learned[@"operation"], problem);
    });
    handler(data, response, error);
  };
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
    if (run != gBulkRun || !gBulkTotal || gAuthorization || HRCanHideTheAppsWay()) return;
    if (gRefusedSignIns.count || gAnonymousSignIns.count)
      HRTellProblem(@"Couldn’t hide your read posts: Reddit’s API won’t take the Reddit app’s sign-in. Hide one "
                    @"post yourself (⋯ → Hide post), and Jax Reddit Eclipse will hide the rest the same way.");
    else
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
    // You asked to try again: every sign-in gets another go.
    [gRefusedSignIns removeAllObjects];
    [gAnonymousSignIns removeAllObjects];
    gToldUncheckedAuthors = NO;
    if (!gAuthorization) gAuthorization = gRecentSignIns.lastObject;
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
      if (!gAuthorization && !HRCanHideTheAppsWay()) HRTellIfStillWaiting(gBulkRun);
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
