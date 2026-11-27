#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

// Settings live in Reddit's own (sandboxed) user defaults, so no preference
// bundle or sandbox workaround is needed on rootless or rootful jailbreaks.
extern NSString *const HRPrefEnabled;         // hide read posts in feeds
extern NSString *const HRPrefMarkOpened;      // a post you open counts as read
extern NSString *const HRPrefMarkLingered;    // a post that stays on screen counts as read
extern NSString *const HRPrefMarkScrolledPast; // a post you scroll past counts as read
extern NSString *const HRPrefMarkCrossposts;  // a crosspost of a post you read counts as read
extern NSString *const HRPrefHideButton;      // show the Hide button in the tab bar
extern NSString *const HRPrefHideOnAccount;   // also hide read posts on your Reddit account
extern NSString *const HRPrefHiddenNote;      // the faint "N posts hidden" note
extern NSString *const HRPrefHideInSearch;    // also hide read posts in search results
extern NSString *const HRPrefHideOnProfiles;  // also hide read posts on user profiles
extern NSString *const HRPrefDiagnostics;     // keep a diagnostic log
extern NSString *const HRPrefHintShown;       // first-launch hint already shown
extern NSString *const HRPrefReadHintShown;   // "counted as read" hint already shown

extern NSString *const HRTweakVersion;

void HRRegisterDefaults(void);
BOOL HRPref(NSString *key);

// Diagnostic log: a ring buffer shown in the settings screen, mirrored to the
// system log. Does nothing unless the Diagnostic Log setting is on.
void HRLog(NSString *format, ...) NS_FORMAT_FUNCTION(1, 2);
/// Like HRLog, but only the first time `key` is seen in this app session.
void HRLogOnce(NSString *key, NSString *format, ...) NS_FORMAT_FUNCTION(2, 3);
NSArray<NSString *> *HRLogSnapshot(void);
void HRLogClear(void);

NS_ASSUME_NONNULL_END
