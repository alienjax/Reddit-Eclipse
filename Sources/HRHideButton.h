#import <UIKit/UIKit.h>

// Jax Reddit Eclipse's Hide button in Reddit's tab bar: a tap hides every read post
// on your Reddit account, and touching and holding it opens the settings.

NS_ASSUME_NONNULL_BEGIN

/// Puts the Hide item in Reddit's tab bar if it isn't there yet, or takes it out
/// while the setting is off. Only for a tab bar that's on screen, so nothing is
/// made to load early. Main thread.
void HRHideButtonUpdate(void);

/// HRHideButtonUpdate on the next pass of the main queue, so it never runs
/// inside one of Reddit's own screen callbacks. Main thread.
void HRHideButtonUpdateLater(void);

/// Call when the app becomes active: tries now and a few times over the next
/// seconds, in case the tab bar takes a moment to be on screen.
void HRHideButtonUpdateSoon(void);

/// Call at launch, before anything else touches the Hide button: if Reddit
/// froze or crashed last time while the Hide tab went in, turns the button off
/// (and says so once Reddit is up).
void HRHideButtonCheckLastRun(void);

/// YES while the Hide button is in Reddit's tab bar (so holding it opens the
/// settings). Main thread.
BOOL HRHideButtonIsInTabBar(void);

/// Call when the app resigns active: it's still responding, so the safety net
/// can stand down.
void HRHideButtonAppWillResignActive(void);

NS_ASSUME_NONNULL_END
