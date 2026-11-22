#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

/// Jax Reddit Eclipse's in-app settings screen.
@interface HideReadSettingsViewController : UITableViewController
@end

/// Opens the settings screen in Jax Reddit Eclipse's own window above the app, without
/// making it the key window. Does nothing if it's already open; shows a banner
/// if it can't open.
void HRPresentSettings(void);

/// Adds the two-finger double tap that opens the settings, if `window` is
/// Reddit's main window. It only works while the Hide button isn't in the tab
/// bar; while it is, holding Hide opens the settings. Other windows (other tweaks' included) are left alone.
/// Safe to call more than once per window.
void HRInstallSettingsGesture(UIWindow *window);

/// Same, for the main window of every connected scene.
void HRInstallSettingsGestures(void);

/// A short message at the top of the screen, gone after `duration` seconds.
/// Main thread.
void HRShowBanner(NSString *text, NSTimeInterval duration);

/// A faint note at the top of the screen that fades in, stays a moment and fades
/// out (about a second and a half). A newer one replaces it.
void HRShowToast(NSString *text);

/// Shows a one-time banner after the first launch saying how to open settings.
void HRShowFirstLaunchHintIfNeeded(void);

/// Shows a one-time banner the first time a post is counted as read, saying
/// it disappears the next time the feed loads. Call on any thread.
void HRShowReadHintIfNeeded(void);

NS_ASSUME_NONNULL_END
