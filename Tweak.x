// Jax Reddit Eclipse: hide posts you've already read in the official Reddit app.
//
// The feed is filtered at the network layer: Reddit's GraphQL responses pass
// through Jax Reddit Eclipse before the app parses them. Posts already marked as read get
// the same "hidden" treatment the app uses for posts you dismiss. A post is
// marked as read when its page or comments load right after a post screen
// opens; see Sources/HRResponseProcessor.m.
//
// Jax Reddit Eclipse keeps out of other tweaks' way: it hooks only NSURLSession's
// data and upload tasks and -[UIViewController viewWillAppear:], always calls
// the original, leaves responses it doesn't need untouched, and doesn't
// react to shakes or take over the app's key window. Its network hooks go in
// last, after every tweak's constructor has run, so a tweak that filters
// Reddit's responses (blocking posts, say) always works on what Reddit sent,
// and Jax Reddit Eclipse only removes read posts from what that tweak hands on.

#import <UIKit/UIKit.h>
#import "HideReadStore.h"
#import "HRResponseProcessor.h"
#import "HRScreenTracker.h"
#import "HRScrollTracker.h"
#import "HRHideButton.h"
#import "HRAccountHider.h"
#import "HideReadSettingsViewController.h"
#import "HRShared.h"

typedef void (^HRCompletionHandler)(NSData *data, NSURLResponse *response, NSError *error);

// Hands a response to the app on the session's delegate queue, where the app
// expects it.
static void HRDeliver(NSURLSession *session, HRCompletionHandler handler, NSData *data,
                      NSURLResponse *response) {
  NSOperationQueue *queue = session.delegateQueue;
  if (queue && NSOperationQueue.currentQueue != queue)
    [queue addOperationWithBlock:^{
      handler(data, response, nil);
    }];
  else
    handler(data, response, nil);
}

// Hides read posts in a response and hands it on. A feed page that would be
// left with too few unread posts gets the next page merged in first: up to three
// more pages, within four seconds of the first one arriving. The extra requests
// go through every tweak's hook like the app's own (Jax Reddit Eclipse's lets them
// through untouched), so a tweak that filters posts filters them too.
static void HRFinishResponse(NSURLSession *session, NSURLRequest *request, NSData *body, NSData *data,
                             NSURLResponse *response, CFAbsoluteTime requestTime,
                             CFAbsoluteTime deadline, NSUInteger topUps, HRCompletionHandler handler) {
  NSURLRequest *next = session && topUps < 3 && CFAbsoluteTimeGetCurrent() < deadline
                           ? HRFeedTopUpRequest(request, body, data)
                           : nil;
  if (!next) {
    HRDeliver(session, handler, HRProcessResponse(request, body, data, requestTime), response);
    return;
  }

  // Whichever comes first, the next page or the deadline, finishes the job.
  NSObject *lock = [NSObject new];
  __block BOOL claimed = NO;
  BOOL (^claim)(void) = ^BOOL {
    @synchronized(lock) {
      if (claimed) return NO;
      claimed = YES;
      return YES;
    }
  };
  NSURLSessionDataTask *task = [session
      dataTaskWithRequest:next
        completionHandler:^(NSData *nextData, NSURLResponse *nextResponse, NSError *nextError) {
          if (!claim()) return;
          NSInteger status = [nextResponse isKindOfClass:NSHTTPURLResponse.class]
                                 ? ((NSHTTPURLResponse *)nextResponse).statusCode
                                 : 200;
          NSData *merged = !nextError && nextData.length > 0 && status >= 200 && status < 300
                               ? HRMergeFeedPages(data, nextData)
                               : nil;
          HRFinishResponse(session, request, body, merged ?: data, response, requestTime, deadline,
                           merged ? topUps + 1 : 3, handler);
        }];
  [task resume];
  dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
                               (int64_t)((deadline - CFAbsoluteTimeGetCurrent()) * NSEC_PER_SEC)),
                 dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
                   if (!claim()) return;
                   [task cancel];
                   HRLog(@"[feed] the next page took too long; showing this one as it is");
                   HRDeliver(session, handler, HRProcessResponse(request, body, data, requestTime),
                             response);
                 });
}

// Wraps a completion handler so the response passes through Jax Reddit Eclipse first.
static HRCompletionHandler HRWrapCompletionHandler(NSURLSession *session, NSURLRequest *request,
                                                   NSData *body,
                                                   HRCompletionHandler completionHandler) {
  NSURLRequest *requestCopy = [request copy];
  NSData *bodyCopy = [body copy];
  CFAbsoluteTime requestTime = CFAbsoluteTimeGetCurrent();
  return ^(NSData *data, NSURLResponse *response, NSError *error) {
    NSInteger status = [response isKindOfClass:NSHTTPURLResponse.class]
                           ? ((NSHTTPURLResponse *)response).statusCode
                           : 200;
    if (error || data.length == 0 || status < 200 || status >= 300) {
      completionHandler(data, response, error);
      return;
    }
    HRFinishResponse(session, requestCopy, bodyCopy, data, response, requestTime,
                     CFAbsoluteTimeGetCurrent() + 4.0, 0, completionHandler);
  };
}

// Diagnostics: a Reddit address Jax Reddit Eclipse isn't reading, so a move to a new API
// host shows up in the log. Logged once per address.
static void HRNoteUnwatchedRequest(NSURLRequest *request, BOOL hasCompletionHandler) {
  NSString *host = request.URL.host;
  if (!HRPref(HRPrefDiagnostics) || !HRIsRedditHost(host)) return;
  BOOL apiHost = HRShouldProcessRequest(request);
  HRLogOnce([NSString stringWithFormat:@"unwatched:%@:%d", host, apiHost],
            @"[api] not reading %@%@", host,
            apiHost ? @" (request has no completion handler)" : @"");
}

// The handler to pass on: wrapped for responses Jax Reddit Eclipse needs, the app's own
// for everything else.
static HRCompletionHandler HRHandlerFor(NSURLSession *session, NSURLRequest *request, NSData *body,
                                        HRCompletionHandler completionHandler) {
  HRAccountHiderNoteRequest(session, request);  // the app's sign-in, for hiding posts on your account
  // Jax Reddit Eclipse's own requests for a next page: the handler waiting for them reads them.
  if (completionHandler && HRIsTopUpRequest(request)) return completionHandler;
  if (!completionHandler || !HRShouldProcessRequest(request)) {
    HRNoteUnwatchedRequest(request, completionHandler != nil);
    return completionHandler;
  }
  NSString *operation = HROperationName(request, body);
  if (!HRShouldWatchOperation(operation)) {
    if (HRPref(HRPrefDiagnostics))
      HRLogOnce([@"passed:" stringByAppendingString:operation ?: @"?"],
                @"[api] %@ (%@, passed through)", operation ?: @"unnamed operation",
                request.URL.host);
    return completionHandler;
  }
  return HRWrapCompletionHandler(session, request, body, completionHandler);
}

// Set while a completion-handler task is being created, so the diagnostics hook
// below doesn't count it as a streamed request.
static __thread BOOL gCreatingHandlerTask;

// YES once the outer hooks (HRNetwork) are in; the early ones then step aside.
static volatile BOOL gOuterHooksInstalled;

// Installed in the constructor, so a request Reddit makes before the main
// queue's first pass is still read. Once the outer hooks are in, these pass
// everything straight on, so no response is read twice.
%group HREarlyNetwork
%hook NSURLSession

- (NSURLSessionDataTask *)dataTaskWithRequest:(NSURLRequest *)request
                            completionHandler:(HRCompletionHandler)completionHandler {
  if (gOuterHooksInstalled) return %orig;
  HRCompletionHandler handler = HRHandlerFor(self, request, request.HTTPBody, completionHandler);
  BOOL outer = gCreatingHandlerTask;
  gCreatingHandlerTask = YES;
  NSURLSessionDataTask *task = %orig(request, handler);
  gCreatingHandlerTask = outer;
  return task;
}

- (NSURLSessionUploadTask *)uploadTaskWithRequest:(NSURLRequest *)request
                                         fromData:(NSData *)bodyData
                                completionHandler:(HRCompletionHandler)completionHandler {
  if (gOuterHooksInstalled) return %orig;
  HRCompletionHandler handler = HRHandlerFor(self, request, bodyData, completionHandler);
  BOOL outer = gCreatingHandlerTask;
  gCreatingHandlerTask = YES;
  NSURLSessionUploadTask *task = %orig(request, bodyData, handler);
  gCreatingHandlerTask = outer;
  return task;
}

%end
%end

%group HRNetwork
%hook NSURLSession

- (NSURLSessionDataTask *)dataTaskWithRequest:(NSURLRequest *)request
                            completionHandler:(HRCompletionHandler)completionHandler {
  HRCompletionHandler handler = HRHandlerFor(self, request, request.HTTPBody, completionHandler);
  BOOL outer = gCreatingHandlerTask;
  gCreatingHandlerTask = YES;
  NSURLSessionDataTask *task = %orig(request, handler);
  gCreatingHandlerTask = outer;
  return task;
}

- (NSURLSessionUploadTask *)uploadTaskWithRequest:(NSURLRequest *)request
                                         fromData:(NSData *)bodyData
                                completionHandler:(HRCompletionHandler)completionHandler {
  HRCompletionHandler handler = HRHandlerFor(self, request, bodyData, completionHandler);
  BOOL outer = gCreatingHandlerTask;
  gCreatingHandlerTask = YES;
  NSURLSessionUploadTask *task = %orig(request, bodyData, handler);
  gCreatingHandlerTask = outer;
  return task;
}

%end
%end

// Requests made without a completion handler (streamed responses, such as a
// feed loaded with @defer) can't be read or filtered. They still carry the app's
// sign-in, picked up for hiding posts on your account, and with the diagnostic
// log on they're noted.
%hook NSURLSession

- (NSURLSessionDataTask *)dataTaskWithRequest:(NSURLRequest *)request {
  if (!gCreatingHandlerTask) {
    HRAccountHiderNoteRequest(self, request);
    if (HRPref(HRPrefDiagnostics) && HRShouldProcessRequest(request)) {
      NSString *operation = HROperationName(request, request.HTTPBody) ?: @"unnamed operation";
      HRLogOnce([@"streamed:" stringByAppendingString:operation],
                @"[api] %@ (%@) is streamed: Jax Reddit Eclipse can't read or filter it", operation,
                request.URL.host);
    }
  }
  return %orig;
}

%end

// Installed from the main queue's first pass, which comes after every tweak's
// constructor (each tweak installs its hooks there). Hooks installed later wrap
// earlier ones, so Jax Reddit Eclipse's handler sees each response after the other tweaks'
// handlers. Anything Reddit asks for before then goes through the early hooks.
static void HRInstallNetworkHooks(void) {
  static BOOL installed;
  if (installed) return;
  installed = YES;
  %init(HRNetwork);
  gOuterHooksInstalled = YES;
  HRLog(@"[info] network hooks in place, after other tweaks' hooks");
}

// Tells Jax Reddit Eclipse when a post screen opens (see HRScreenTracker).
%hook UIViewController

- (void)viewWillAppear:(BOOL)animated {
  %orig;
  HRScreenTrackerViewWillAppear(self);
}

%end

%ctor {
  @autoreleasepool {
    HRRegisterDefaults();
    HRHideButtonCheckLastRun();  // before anything touches the Hide button

    // Load the read history off the main thread.
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
      [HideReadStore sharedStore];
    });

    NSNotificationCenter *center = NSNotificationCenter.defaultCenter;
    for (NSNotificationName name in
         @[ UIApplicationDidEnterBackgroundNotification, UIApplicationWillTerminateNotification ]) {
      [center addObserverForName:name
                          object:nil
                           queue:nil
                      usingBlock:^(NSNotification *note) {
                        [HideReadStore.sharedStore flush];
                      }];
    }

    // The two-finger double tap (for when the Hide button is off) goes on
    // Reddit's main window, found through notifications rather than a UIWindow
    // hook.
    [center addObserverForName:UIWindowDidBecomeKeyNotification
                        object:nil
                         queue:NSOperationQueue.mainQueue
                    usingBlock:^(NSNotification *note) {
                      if ([note.object isKindOfClass:UIWindow.class])
                        HRInstallSettingsGesture(note.object);
                    }];
    [center addObserverForName:UIApplicationDidBecomeActiveNotification
                        object:nil
                         queue:NSOperationQueue.mainQueue
                    usingBlock:^(NSNotification *note) {
                      HRInstallSettingsGestures();
                      HRShowFirstLaunchHintIfNeeded();
                      HRScrollTrackerStart();
                      HRHideButtonUpdateSoon();
                      HRAccountHiderStart();
                    }];
    [center addObserverForName:UIApplicationWillResignActiveNotification
                        object:nil
                         queue:NSOperationQueue.mainQueue
                    usingBlock:^(NSNotification *note) {
                      HRScrollTrackerStop();
                      HRHideButtonAppWillResignActive();
                      HRAccountHiderAppWillResignActive();
                    }];

    %init;
    %init(HREarlyNetwork);
    dispatch_async(dispatch_get_main_queue(), ^{
      HRInstallNetworkHooks();
    });
  }
}
