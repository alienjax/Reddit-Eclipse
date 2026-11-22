#import "HRScreenTracker.h"
#import "HRScrollTracker.h"
#import "HRHideButton.h"
#import <objc/runtime.h>
#import <os/lock.h>
#import "HRShared.h"

static os_unfair_lock gLock = OS_UNFAIR_LOCK_INIT;
static CFAbsoluteTime gLastPostScreenAppearance = 0;
static BOOL gAppearanceClaimed = YES;

BOOL HRIsPostScreenController(UIViewController *controller) {
  static NSArray<NSString *> *matches;
  static NSArray<NSString *> *exclusions;
  static dispatch_once_t once;
  dispatch_once(&once, ^{
    // Lower-cased fragments. Swift class names keep their type name inside the
    // mangled string ("_TtC...PostDetailViewController"), so substring checks work.
    matches = @[
      @"postdetail", @"pdp", @"commentsviewcontroller", @"commentsscreen", @"commentspage",
      @"postcomments", @"commentthread"
    ];
    exclusions = @[ @"compose", @"reply", @"editor", @"report", @"sheet", @"menu" ];
  });

  NSString *name = NSStringFromClass(object_getClass(controller)).lowercaseString;
  for (NSString *exclusion in exclusions)
    if ([name containsString:exclusion]) return NO;
  for (NSString *match in matches)
    if ([name containsString:match]) return YES;
  return NO;
}

// Screen-level controllers only, so the diagnostic log isn't flooded with
// every child controller.
static BOOL HRIsScreenLevel(UIViewController *controller) {
  UIViewController *parent = controller.parentViewController;
  return parent == nil || [parent isKindOfClass:UINavigationController.class] ||
         [parent isKindOfClass:UITabBarController.class] ||
         [parent isKindOfClass:UIPageViewController.class];
}

void HRScreenTrackerViewWillAppear(UIViewController *controller) {
  BOOL isPostScreen = HRIsPostScreenController(controller);
  if (isPostScreen || HRIsScreenLevel(controller)) {
    HRScrollTrackerScreenChanged();
    HRHideButtonUpdateLater();  // never from inside Reddit's own callback
  } else if ([controller isKindOfClass:UITabBarController.class]) {
    HRHideButtonUpdateLater();  // Reddit's tab bar is coming on screen
  }
  if (isPostScreen) {
    os_unfair_lock_lock(&gLock);
    gLastPostScreenAppearance = CFAbsoluteTimeGetCurrent();
    gAppearanceClaimed = NO;
    os_unfair_lock_unlock(&gLock);
  }

  if (HRPref(HRPrefDiagnostics)) {
    NSString *name = NSStringFromClass(object_getClass(controller));
    // Skips the tweak's own screens (their class names start with HideRead).
    if (![name hasPrefix:@"HideRead"] && ![name isEqualToString:@"UIViewController"] && (isPostScreen || HRIsScreenLevel(controller)))
      HRLog(@"[screen] %@%@", name, isPostScreen ? @"  <- post screen" : @"");
  }
}

// A post's page can start loading as you tap, a moment before its screen
// appears.
static const CFAbsoluteTime kHREarlyRequestTolerance = 0.5;

BOOL HRScreenTrackerClaimPostScreen(NSTimeInterval window, CFAbsoluteTime requestTime) {
  os_unfair_lock_lock(&gLock);
  BOOL claimed = !gAppearanceClaimed && gLastPostScreenAppearance > 0 &&
                 CFAbsoluteTimeGetCurrent() - gLastPostScreenAppearance <= window &&
                 (requestTime <= 0 ||
                  requestTime >= gLastPostScreenAppearance - kHREarlyRequestTolerance);
  if (claimed) gAppearanceClaimed = YES;
  os_unfair_lock_unlock(&gLock);
  return claimed;
}
