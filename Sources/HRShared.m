#import "HRShared.h"
#import <os/lock.h>
#import <os/log.h>

NSString *const HRPrefEnabled = @"HREnabled";
NSString *const HRPrefMarkOpened = @"HRMarkOpened";
NSString *const HRPrefMarkLingered = @"HRMarkLingered";
NSString *const HRPrefMarkScrolledPast = @"HRMarkScrolledPast";
NSString *const HRPrefMarkCrossposts = @"HRMarkCrossposts";
NSString *const HRPrefHideOlderThanDays = @"HRHideOlderThanDays";
NSString *const HRPrefHideButton = @"HRHideButton";
NSString *const HRPrefHideOnAccount = @"HRHideOnAccount";
NSString *const HRPrefHiddenNote = @"HRHiddenNote";
NSString *const HRPrefHideInSearch = @"HRHideInSearch";
NSString *const HRPrefHideOnProfiles = @"HRHideOnProfiles";
NSString *const HRPrefDiagnostics = @"HRDiagnostics";
// The first-launch hint has been shown.
NSString *const HRPrefHintShown = @"HRHintShown2";
NSString *const HRPrefReadHintShown = @"HRReadHintShown";

NSString *const HRTweakVersion = @"0.0.31b";

static const NSUInteger kHRMaxLogLines = 400;

static os_unfair_lock gLogLock = OS_UNFAIR_LOCK_INIT;
static NSMutableArray<NSString *> *gLogLines;
static NSDateFormatter *gLogFormatter;

void HRRegisterDefaults(void) {
  [NSUserDefaults.standardUserDefaults registerDefaults:@{
    HRPrefEnabled : @YES,
    HRPrefMarkOpened : @YES,
    HRPrefMarkLingered : @NO,
    HRPrefMarkScrolledPast : @YES,
    HRPrefMarkCrossposts : @YES,
    HRPrefHideOlderThanDays : @0,
    HRPrefHideButton : @YES,
    HRPrefHiddenNote : @YES,
    HRPrefHideOnAccount : @YES,
    HRPrefHideInSearch : @NO,
    HRPrefHideOnProfiles : @NO,
    HRPrefDiagnostics : @NO,
    HRPrefHintShown : @NO,
    HRPrefReadHintShown : @NO,
  }];
}

BOOL HRPref(NSString *key) {
  return [NSUserDefaults.standardUserDefaults boolForKey:key];
}

void HRLog(NSString *format, ...) {
  if (!HRPref(HRPrefDiagnostics)) return;

  va_list args;
  va_start(args, format);
  NSString *message = [[NSString alloc] initWithFormat:format arguments:args];
  va_end(args);

  os_log(OS_LOG_DEFAULT, "[Jax Reddit Eclipse] %{public}@", message);

  os_unfair_lock_lock(&gLogLock);
  if (!gLogLines) {
    gLogLines = [NSMutableArray array];
    gLogFormatter = [NSDateFormatter new];
    gLogFormatter.locale = [NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"];
    gLogFormatter.dateFormat = @"HH:mm:ss.SSS";
  }
  [gLogLines addObject:[NSString stringWithFormat:@"%@  %@",
                                                  [gLogFormatter stringFromDate:[NSDate date]],
                                                  message]];
  if (gLogLines.count > kHRMaxLogLines)
    [gLogLines removeObjectsInRange:NSMakeRange(0, gLogLines.count - kHRMaxLogLines)];
  os_unfair_lock_unlock(&gLogLock);
}

void HRLogOnce(NSString *key, NSString *format, ...) {
  if (!HRPref(HRPrefDiagnostics)) return;

  static NSMutableSet<NSString *> *seenKeys;
  os_unfair_lock_lock(&gLogLock);
  if (!seenKeys) seenKeys = [NSMutableSet set];
  BOOL isNew = ![seenKeys containsObject:key];
  if (isNew) [seenKeys addObject:key];
  os_unfair_lock_unlock(&gLogLock);
  if (!isNew) return;

  va_list args;
  va_start(args, format);
  NSString *message = [[NSString alloc] initWithFormat:format arguments:args];
  va_end(args);
  HRLog(@"%@", message);
}

NSArray<NSString *> *HRLogSnapshot(void) {
  os_unfair_lock_lock(&gLogLock);
  NSArray<NSString *> *lines = gLogLines ? [gLogLines copy] : @[];
  os_unfair_lock_unlock(&gLogLock);
  return lines;
}

void HRLogClear(void) {
  os_unfair_lock_lock(&gLogLock);
  [gLogLines removeAllObjects];
  os_unfair_lock_unlock(&gLogLock);
}
