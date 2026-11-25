#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

/// Starts watching the feed on screen: while "You Scroll Past It" is on, counts
/// the posts you scroll past as read, and says how many with a faint note once
/// the list comes to rest. Hooks nothing: a timer reads the list a few times a
/// second, and a gesture recognizer that never takes part in a gesture notes
/// which post card a tap lands on. Main thread; safe to call more than once.
void HRScrollTrackerStart(void);

/// Stops the timer (the app is going inactive).
void HRScrollTrackerStop(void);

/// A screen appeared: look for the feed list again on the next tick.
void HRScrollTrackerScreenChanged(void);

/// A screen-level controller is about to appear. If it shows a post's content
/// (see HRIsPostContentScreen) and a post card in the feed was tapped just
/// before, that post counts as opened while "You Open It" is on: this is how a
/// video, images or link watched full screen count. Main thread.
void HRScrollTrackerScreenAppeared(UIViewController *controller);

/// Counts a post newly hidden while you browse a feed (one that stayed on
/// screen), for the "N posts hidden" note, as scrolled-past posts are. Any thread.
void HRScrollTrackerPostHidden(void);

/// Posts newly counted as read since Reddit opened because you scrolled past
/// them. Main thread.
NSUInteger HRScrollTrackerScrolledPastCount(void);

NS_ASSUME_NONNULL_END
