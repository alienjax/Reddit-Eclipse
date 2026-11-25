#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

/// Called (on the main thread) from the -[UIViewController viewWillAppear:] hook.
void HRScreenTrackerViewWillAppear(UIViewController *controller);

/// YES if the controller looks like Reddit's post / comments screen, judged by
/// its class name (e.g. "...PostDetailViewController").
BOOL HRIsPostScreenController(UIViewController *controller);

/// YES if the controller shows a post's own content: its page (see
/// HRIsPostScreenController), or its video, images or link full screen, judged
/// by its class name (e.g. "AVPlayerViewController", "SFSafariViewController",
/// "...MediaViewerViewController"). Screens for subreddits, profiles, menus,
/// sheets and the like never count.
BOOL HRIsPostContentScreen(UIViewController *controller);

/// Returns YES at most once per post-screen appearance, for a request sent
/// after that appearance (or just before it) and answered within `window`
/// seconds of it. Lets the first post load after a post screen opens be
/// attributed to that screen, while a load Reddit started earlier for another
/// post (a preload still in flight) can't take its place. `requestTime` is
/// when the request was sent (CFAbsoluteTimeGetCurrent), or 0 if unknown.
/// Thread-safe.
BOOL HRScreenTrackerClaimPostScreen(NSTimeInterval window, CFAbsoluteTime requestTime);

NS_ASSUME_NONNULL_END
