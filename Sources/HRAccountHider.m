#import "HRAccountHider.h"
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
// seconds. "Hide All Read Posts Now" sends the whole read history the same way,
// a batch every 2 seconds, while Reddit is open and active. If Reddit asks for
// less (too many requests, trouble on its side, no connection), the pause
// doubles each time, up to half an hour; its rate-limit headers are respected.
//
// Posts Reddit took are recorded (Application Support/HideRead/AccountHidden.plist,
// 90 days, at most 20,000), so none is sent twice. /api/hide answers OK whether
// or not it hid anything, so after the first batch each time Reddit opens, one of
// its posts is looked up (GET /api/info) to check it's really on your Hidden list.
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
static NSString *const kHRPendingKey = @"HRAccountHidePending";
static const NSUInteger kHRBatchSize = 25;
static const NSUInteger kHRMaxPending = 1000;
static const NSTimeInterval kHRGatherDelay = 10;  // for a batch to fill, at most
static const NSTimeInterval kHRMinGap = 10;       // between requests
static const NSTimeInterval kHRBulkGap = 2;       // between requests during "Hide All Read Posts Now"
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
static BOOL gChecking;
static BOOL gStatusChangeQueued;

static void HRSendBatch(void);

static BOOL HRAccountHidingOn(void) {
  return HRPref(HRPrefEnabled) && HRPref(HRPrefHideOnAccount);
}

static NSString *HRCount(NSUInteger count) {
  return [NSNumberFormatter localizedStringFromNumber:@(count) numberStyle:NSNumberFormatterDecimalStyle];
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

static void HRSaveRecordSoon(void) {
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
    gQueue = dispatch_queue_create("com.jax.reddit-eclipse.account", DISPATCH_QUEUE_SERIAL);
    gIOQueue = dispatch_queue_create("com.jax.reddit-eclipse.account-io", DISPATCH_QUEUE_SERIAL);
    NSURLSessionConfiguration *configuration = NSURLSessionConfiguration.ephemeralSessionConfiguration;
    configuration.timeoutIntervalForRequest = 30;
    gSession = [NSURLSession sessionWithConfiguration:configuration];
    gPending = [NSMutableOrderedSet orderedSet];
    gBulk = [NSMutableOrderedSet orderedSet];
    gRecord = [NSMutableDictionary dictionary];
    // Off the calling thread, and before anything else runs on the queue.
    dispatch_async(gQueue, ^{
      HRLoadRecord();
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

// "Hide All Read Posts Now" only goes on while Reddit is active: a request the
// system cuts off as Reddit goes to the background would only count as a failure.
static BOOL HRBulkCanSend(void) {
  return gBulk.count > 0 && gAppActive;
}

// Sends now if a batch is full (or as soon as the pause allows), otherwise in
// up to 10 seconds.
static void HRConsiderSending(void) {
  if (gSending || gStopped || (!gPending.count && !HRBulkCanSend())) return;
  if (!gAuthorization) {
    if (!gToldWaiting) {
      gToldWaiting = YES;
      HRLog(@"[account] %lu posts waiting for the Reddit app's sign-in to hide them on your account",
            (unsigned long)(gPending.count + gBulk.count));
    }
    return;
  }
  NSTimeInterval wait = MAX(0, gNextAllowed - CFAbsoluteTimeGetCurrent());
  if (HRBulkCanSend() || gPending.count >= kHRBatchSize) HRArmSend(wait);
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
  return [@": " stringByAppendingString:text.length > 120 ? [text substringToIndex:120] : text];
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

// Whether Reddit's /api/info answer lists the post as hidden: @YES, @NO, or nil
// if the answer doesn't say.
static NSNumber *HRHiddenFlag(NSData *data, NSString *postID) {
  id json = data.length ? [NSJSONSerialization JSONObjectWithData:data options:0 error:NULL] : nil;
  id listing = [json isKindOfClass:NSDictionary.class] ? ((NSDictionary *)json)[@"data"] : nil;
  id children = [listing isKindOfClass:NSDictionary.class] ? ((NSDictionary *)listing)[@"children"] : nil;
  if (![children isKindOfClass:NSArray.class]) return nil;
  for (id child in (NSArray *)children) {
    id post = [child isKindOfClass:NSDictionary.class] ? ((NSDictionary *)child)[@"data"] : nil;
    if (![post isKindOfClass:NSDictionary.class] || ![((NSDictionary *)post)[@"name"] isEqual:postID]) continue;
    id hidden = ((NSDictionary *)post)[@"hidden"];
    return [hidden isKindOfClass:NSNumber.class] ? hidden : nil;
  }
  return nil;
}

// Looks one post up a few seconds after Reddit took it, to see it's on your
// Hidden list.
static void HRCheckHiddenSoon(NSString *postID, NSString *authorization) {
  if (!postID) return;
  gChecking = YES;
  dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(3 * NSEC_PER_SEC)), gQueue, ^{
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
            NSNumber *hidden = !error && status >= 200 && status < 300 ? HRHiddenFlag(data, postID) : nil;
            dispatch_async(gQueue, ^{
              gChecking = NO;
              if (hidden) {
                gCheck = hidden.boolValue ? 1 : -1;
                if (gCheck > 0)
                  HRLog(@"[account] checked with Reddit: %@ is on your Hidden list", HRDescribePost(postID));
                else
                  HRLog(@"[account] Reddit answered OK, but doesn't list %@ as hidden: %@", HRDescribePost(postID),
                        HRAnswerExcerpt(data));
              } else {
                HRLog(@"[account] couldn't check with Reddit whether %@ is hidden (%@)", postID,
                      error ? error.localizedDescription
                            : [NSString stringWithFormat:@"HTTP %ld%@", (long)status, HRAnswerExcerpt(data)]);
              }
              HRStatusChanged();
            });
          }];
    [task resume];
  });
}

static void HRFinishBulk(void) {
  HRLog(@"[account] Hide All Read Posts Now is done: %lu hidden on your account, %lu left out",
        (unsigned long)gBulkHidden, (unsigned long)(gBulkDone - gBulkHidden));
  NSUInteger hidden = gBulkHidden;
  gLastBulkHidden = hidden;
  gBulkTotal = gBulkDone = gBulkHidden = 0;
  if (hidden)
    dispatch_async(dispatch_get_main_queue(), ^{
      HRShowToast([NSString stringWithFormat:@"%@ read posts hidden on your Reddit account", HRCount(hidden)]);
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

static void HRHandleAnswer(NSArray<NSString *> *batch, NSURLResponse *response, NSError *error, NSData *data,
                           NSString *authorization) {
  NSInteger status = HRStatusCode(response);
  BOOL bulkRunning = gBulkTotal > 0;
  HRRespectRateLimit(response);

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
    if (!gCheck && !gChecking) HRCheckHiddenSoon(batch.firstObject, authorization);
  } else {
    NSString *reason = error ? error.localizedDescription
                             : [NSString stringWithFormat:@"HTTP %ld%@", (long)status, HRAnswerExcerpt(data)];
    if (status == 401 || status == 403) {
      // The sign-in may have run out: the app's next request brings a new one.
      if ([gAuthorization isEqualToString:authorization]) gAuthorization = nil;
      gToldWaiting = NO;
      gProblem = [NSString stringWithFormat:@"Reddit turned down the app’s sign-in (HTTP %ld).", (long)status];
      if (++gRefusals >= 3) {
        gStopped = YES;
        HRLog(@"[account] Reddit turned down hiding posts on your account three times (%@). Stopped until Reddit "
              @"is next opened; %lu posts waiting",
              reason, (unsigned long)(gPending.count + gBulk.count));
      } else {
        HRLog(@"[account] Reddit turned down hiding posts on your account (%@); trying again with the app's next "
              @"sign-in",
              reason);
      }
    } else if (status >= 400 && status < 500 && status != 408 && status != 429) {
      // Reddit won't take this batch as it is: drop it rather than send it forever.
      gBulkDone += HRTakeOut(batch);
      gProblem = [NSString stringWithFormat:@"Reddit wouldn’t hide %lu posts (HTTP %ld), so they were left out.",
                                            (unsigned long)batch.count, (long)status];
      HRLog(@"[account] Reddit wouldn't hide these %lu posts (%@); left them out", (unsigned long)batch.count, reason);
    } else {
      // Too many requests, trouble on Reddit's side, or no connection: wait longer each time.
      gBackoff = gBackoff ? MIN(gBackoff * 2, kHRMaxBackoff) : 60;
      gNextAllowed = MAX(gNextAllowed, CFAbsoluteTimeGetCurrent() + gBackoff);
      gProblem = [NSString stringWithFormat:@"Couldn’t reach Reddit to hide posts (%@).",
                                            error ? error.localizedDescription
                                                  : [NSString stringWithFormat:@"HTTP %ld", (long)status]];
      HRLog(@"[account] couldn't hide posts on your account (%@); trying again in %.0f seconds", reason, gBackoff);
    }
  }
  if (bulkRunning && !gBulk.count) HRFinishBulk();
  HRStatusChanged();
}

static void HRSendBatch(void) {
  if (gSending || gStopped) return;
  if (gPending.count && !HRAccountHidingOn()) {
    // Turned off since these were counted.
    [gPending removeAllObjects];
    HRSavePending();
    HRStatusChanged();
  }
  if (!gPending.count && !HRBulkCanSend()) return;
  if (!gAuthorization) {
    HRConsiderSending();  // waits for the app's sign-in
    return;
  }
  CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
  if (now < gNextAllowed) {
    HRArmSend(gNextAllowed - now);
    return;
  }

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
  NSArray<NSString *> *batch = [[NSArray alloc] initWithArray:picked.array];  // .array is a live view

  NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:kHRHideURL]];
  request.HTTPMethod = @"POST";
  [request setValue:gAuthorization forHTTPHeaderField:@"Authorization"];
  if (gUserAgent) [request setValue:gUserAgent forHTTPHeaderField:@"User-Agent"];
  [request setValue:@"application/x-www-form-urlencoded" forHTTPHeaderField:@"Content-Type"];
  NSString *body = [@"id=" stringByAppendingString:HRFormEncode([batch componentsJoinedByString:@","])];
  request.HTTPBody = [body dataUsingEncoding:NSUTF8StringEncoding];

  gSending = YES;
  gNextAllowed = now + (HRBulkCanSend() ? kHRBulkGap : kHRMinGap);
  NSString *authorization = gAuthorization;
  NSURLSessionDataTask *task =
      [gSession dataTaskWithRequest:request
                  completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
                    dispatch_async(gQueue, ^{
                      gSending = NO;
                      HRHandleAnswer(batch, response, error, data, authorization);
                      HRConsiderSending();
                    });
                  }];
  [task resume];
  HRStatusChanged();
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
    [parts addObject:[NSString stringWithFormat:@"Hid %@ read posts as you asked.", HRCount(gLastBulkHidden)]];

  if (gStopped)
    [parts addObject:@"Reddit turned the app’s sign-in down three times, so this stopped until Reddit is next opened."];
  else if (waiting && !gAuthorization)
    [parts addObject:@"Waiting for the Reddit app’s sign-in, which is picked up when a feed loads."];
  else if (gProblem && waiting && gNextAllowed > now + 1)
    [parts addObject:[gProblem stringByAppendingFormat:@" Trying again in %.0f seconds.", gNextAllowed - now]];
  else if (gProblem)
    [parts addObject:gProblem];
  else if (gPending.count && !gBulkTotal)
    [parts addObject:[NSString stringWithFormat:@"%@ waiting to be sent.", HRCount(gPending.count)]];

  if (gCheck > 0)
    [parts addObject:@"Reddit confirms they’re on your Hidden list."];
  else if (gCheck < 0)
    [parts addObject:@"Reddit answered, but doesn’t list them on your Hidden list."];

  BOOL on = HRAccountHidingOn();
  if (!parts.count) {
    if (!on) return @"Off: read posts are only left out of feeds in this app.";
    if (gHiddenThisRun) return [NSString stringWithFormat:@"%@ hidden since Reddit opened.", HRCount(gHiddenThisRun)];
    if (!gAuthorization)
      return @"Nothing waiting. The Reddit app’s sign-in hasn’t been picked up yet; that happens when a feed loads.";
    return @"Nothing waiting. Read posts go to Reddit about 20 seconds after they’re counted.";
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
  NSString *host = request.URL.host;
  if (!HRIsRedditHost(host)) return;
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
  HRSetUp();
  dispatch_async(gQueue, ^{
    if (agent.length) gUserAgent = agent;
    if ([authorization isEqualToString:gAuthorization]) return;
    BOOL first = !gAuthorization;
    gAuthorization = authorization;
    if (first) {
      HRLog(@"[account] picked up the Reddit app's sign-in (from a request to %@)", host);
      HRStatusChanged();
    }
    HRConsiderSending();
  });
}

void HRAccountHiderQueue(NSString *postID) {
  if (![postID hasPrefix:@"t3_"] || !HRAccountHidingOn()) return;
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

void HRAccountHiderStart(void) {
  HRSetUp();
  dispatch_async(gQueue, ^{
    gAppActive = YES;
    gStopped = NO;
    gRefusals = 0;
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
  dispatch_async(gQueue, ^{
    gAppActive = NO;
    HRSaveRecordNow();
    if (!gPending.count || gSending || gStopped || !gAuthorization) return;
    HRArmSend(MAX(0, gNextAllowed - CFAbsoluteTimeGetCurrent()));
  });
}

NSUInteger HRAccountHiderReadPostsToHide(void) {
  NSArray<NSString *> *postIDs = HideReadStore.sharedStore.allPostIDsNewestFirst;
  HRSetUp();
  __block NSUInteger count = 0;
  dispatch_sync(gQueue, ^{
    for (NSString *postID in postIDs)
      if ([postID hasPrefix:@"t3_"] && !gRecord[postID]) count++;
  });
  return count;
}

void HRAccountHiderHideAllRead(BOOL showNote) {
  NSArray<NSString *> *postIDs = HideReadStore.sharedStore.allPostIDsNewestFirst;
  HRSetUp();
  dispatch_async(gQueue, ^{
    gStopped = NO;
    gRefusals = 0;
    if (!gBulkTotal) gBulkDone = gBulkHidden = 0;
    gLastBulkHidden = 0;
    for (NSString *postID in postIDs)
      if ([postID hasPrefix:@"t3_"] && !gRecord[postID]) [gBulk addObject:postID];
    gBulkTotal = gBulk.count ? gBulkDone + gBulk.count : 0;
    HRLog(@"[account] Hide All Read Posts Now: %lu read posts to hide on your Reddit account",
          (unsigned long)gBulk.count);
    HRConsiderSending();
    HRStatusChanged();
    if (!showNote) return;
    NSString *note = gBulk.count ? [NSString stringWithFormat:@"Hiding %@ read posts…", HRCount(gBulk.count)]
                     : postIDs.count ? @"Your read posts are all hidden already"
                                     : @"No read posts to hide yet";
    dispatch_async(dispatch_get_main_queue(), ^{
      HRShowToast(note);
    });
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
    HRStatusChanged();
  });
}
