#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Hides the posts counted as read on your Reddit account too, as "Hide post"
/// in a post's ⋯ menu does, while "Hide on Reddit Account" is on, and on request
/// every post in the read history at once. See HRAccountHider.m.

/// Call for each request the Reddit app makes: picks up the app's own sign-in
/// (its Authorization header) for hiding posts. Any thread; cheap.
void HRAccountHiderNoteRequest(NSURLSession *session, NSURLRequest *request);

/// A post newly counted as read: queued to be hidden on your account. Any thread.
void HRAccountHiderQueue(NSString *postID);

/// YES if Jax Reddit Eclipse hid `postID` on your account (it's on the record).
/// Any thread; cheap.
BOOL HRAccountHiderHid(NSString *_Nullable postID);

/// Posts found to be yours (see HROwnPosts.h): never hidden on your account,
/// and any Jax Reddit Eclipse hid there before are unhidden. Any thread.
void HRAccountHiderOwnPosts(NSArray<NSString *> *postIDs);

/// Call when the app becomes active: sends what's still waiting (from the last
/// time Reddit was open, too).
void HRAccountHiderStart(void);

/// Call when the app resigns active (main thread): asks iOS for time to finish
/// in the background, and sends what's waiting now rather than later.
void HRAccountHiderAppWillResignActive(void);

/// How many posts in the read history aren't hidden on your account yet (as far
/// as Jax Reddit Eclipse knows). Main thread; for the "Hide All Read Posts Now"
/// confirmation.
NSUInteger HRAccountHiderReadPostsToHide(void);

/// "Hide All Read Posts Now" (a tap on Hide in the tab bar, or the row in
/// settings): hides every post in the read history that isn't hidden on your
/// account yet, 25 at a time, while Reddit is open (and for up to half a minute
/// after it leaves the screen), whether or not "Hide on Reddit Account" is on.
/// When it's done, the newest of them is looked up with Reddit and a note says
/// how it went, or what went wrong. With `showNote`, a note also says right away
/// how many are going, or, when they're all hidden already, what Reddit says
/// about the newest.
void HRAccountHiderHideAllRead(BOOL showNote);

/// Stops a "Hide All Read Posts Now" run; what's already hidden stays hidden.
void HRAccountHiderStopHidingAll(void);

/// For the settings screen. Main thread. Keys:
///   hidden     NSNumber  posts Jax Reddit Eclipse has hidden on your account
///   bulkTotal  NSNumber  posts in the running "Hide All Read Posts Now" (0: none)
///   bulkDone   NSNumber  how many of those are done
///   line       NSString  what's happening, in a sentence or two
NSDictionary<NSString *, id> *HRAccountHiderStatus(void);

/// Posted on the main queue whenever HRAccountHiderStatus() changes.
extern NSNotificationName const HRAccountHiderStatusDidChangeNotification;

NS_ASSUME_NONNULL_END
