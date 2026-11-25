#import "HideReadSettingsViewController.h"
#import "HRAccountHider.h"
#import "HRArtwork.h"
#import "HRHideButton.h"
#import <objc/runtime.h>
#import "HRResponseProcessor.h"
#import "HRScrollTracker.h"
#import "HRShared.h"
#import "HideReadStore.h"

typedef NS_ENUM(NSInteger, HRRowKind) {
  HRRowKindSwitch,
  HRRowKindReadCount,
  HRRowKindClearHistory,
  HRRowKindViewLog,
  HRRowKindAccountStatus,  // hidden on your account so far, and what's happening
  HRRowKindHideAllRead,    // Hide All Read Posts Now (or Stop, while it runs)
  HRRowKindSession,        // this session: posts seen in feeds, counted as read
  HRRowKindLink,           // opens its "url" outside Reddit
};

static NSString *HRFormatted(NSUInteger count) {
  return [NSNumberFormatter localizedStringFromNumber:@(count) numberStyle:NSNumberFormatterDecimalStyle];
}

#pragma mark - Window helpers

// The window that has the keyboard focus (used only to find the active scene).
static UIWindow *HRKeyWindow(void) {
  UIWindow *fallback = nil;
  for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
    if (![scene isKindOfClass:UIWindowScene.class]) continue;
    for (UIWindow *window in ((UIWindowScene *)scene).windows) {
      if (window.isKeyWindow) return window;
      if (!fallback && !window.hidden &&
          scene.activationState == UISceneActivationStateForegroundActive)
        fallback = window;
    }
  }
  return fallback;
}

// Reddit's own main window: the one its scene delegate owns. Windows that other
// tweaks put up are never touched.
static UIWindow *HRMainWindow(UIWindowScene *scene) {
  id delegate = scene.delegate;
  if (![delegate respondsToSelector:@selector(window)]) return nil;
  id window = [delegate window];
  return [window isKindOfClass:UIWindow.class] ? window : nil;
}

static UIWindowScene *HRActiveScene(void) {
  UIWindowScene *scene = HRKeyWindow().windowScene;
  if (scene) return scene;
  for (UIScene *candidate in UIApplication.sharedApplication.connectedScenes)
    if ([candidate isKindOfClass:UIWindowScene.class] &&
        candidate.activationState == UISceneActivationStateForegroundActive)
      return (UIWindowScene *)candidate;
  return nil;
}

#pragma mark - Switch

@interface HideReadSwitch : UISwitch
@property (nonatomic, copy) NSString *prefKey;
@end

@implementation HideReadSwitch
@end

#pragma mark - Log screen

@interface HideReadLogViewController : UIViewController
@end

@implementation HideReadLogViewController {
  UITextView *_textView;
}

- (void)viewDidLoad {
  [super viewDidLoad];
  self.title = @"Diagnostic Log";
  self.view.backgroundColor = UIColor.systemBackgroundColor;

  _textView = [[UITextView alloc] initWithFrame:self.view.bounds];
  _textView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
  _textView.editable = NO;
  _textView.alwaysBounceVertical = YES;
  _textView.font = [UIFont monospacedSystemFontOfSize:11 weight:UIFontWeightRegular];
  _textView.textContainerInset = UIEdgeInsetsMake(12, 8, 12, 8);
  [self.view addSubview:_textView];

  self.navigationItem.rightBarButtonItems = @[
    [[UIBarButtonItem alloc] initWithTitle:@"Copy"
                                     style:UIBarButtonItemStylePlain
                                    target:self
                                    action:@selector(copyLog)],
    [[UIBarButtonItem alloc] initWithTitle:@"Clear"
                                     style:UIBarButtonItemStylePlain
                                    target:self
                                    action:@selector(clearLog)],
  ];
}

- (void)viewWillAppear:(BOOL)animated {
  [super viewWillAppear:animated];
  [self reloadLog];
}

- (void)viewDidAppear:(BOOL)animated {
  [super viewDidAppear:animated];
  if (_textView.text.length > 0)
    [_textView scrollRangeToVisible:NSMakeRange(_textView.text.length - 1, 1)];
}

- (void)reloadLog {
  NSArray<NSString *> *lines = HRLogSnapshot();
  if (lines.count > 0)
    _textView.text = [lines componentsJoinedByString:@"\n"];
  else if (HRPref(HRPrefDiagnostics))
    _textView.text = @"Nothing logged yet. Browse Reddit for a bit, then come back.";
  else
    _textView.text = @"Turn on Diagnostic Log, browse Reddit for a bit, then come back.";
}

- (void)copyLog {
  UIPasteboard.generalPasteboard.string = [HRLogSnapshot() componentsJoinedByString:@"\n"];
}

- (void)clearLog {
  HRLogClear();
  [self reloadLog];
}

@end

#pragma mark - Settings screen

static NSArray<NSDictionary *> *HRSettingsSections(void) {
  return @[
    @{
      @"rows" : @[
        @{@"title" : @"Hide Read Posts", @"pref" : HRPrefEnabled, @"kind" : @(HRRowKindSwitch)},
        @{@"title" : @"Hide Button in Tab Bar", @"pref" : HRPrefHideButton, @"kind" : @(HRRowKindSwitch)},
        @{@"title" : @"“Posts Hidden” Note", @"pref" : HRPrefHiddenNote, @"kind" : @(HRRowKindSwitch)},
      ],
      @"footer" : @"Read posts are left out whenever a feed loads. Tap Hide to hide all your read "
                  @"posts on your Reddit account; touch and hold it for these settings. With the "
                  @"button off, double-tap with two fingers instead. The note shows how many posts "
                  @"you scrolled past were hidden.",
    },
    @{
      @"header" : @"Reddit Account",
      @"rows" : @[
        @{@"title" : @"Hide on Reddit Account", @"pref" : HRPrefHideOnAccount, @"kind" : @(HRRowKindSwitch)},
        @{@"title" : @"Hidden on Your Account", @"kind" : @(HRRowKindAccountStatus)},
        @{@"title" : @"Hide All Read Posts Now", @"kind" : @(HRRowKindHideAllRead)},
      ],
      @"footer" : @"Read posts also go on your account’s Hidden list, as with “Hide post” in the ⋯ "
                  @"menu, so they stay out of your feeds on every device. They’re sent about 20 "
                  @"seconds after they’re counted; until a feed reloads, its ⋯ menus still say "
                  @"“Hide post”. “Hide All Read Posts Now” sends every read post not hidden yet, even "
                  @"with the switch off. Clearing the read history doesn’t unhide anything.",
    },
    @{
      @"header" : @"Count a Post as Read When",
      @"rows" : @[
        @{@"title" : @"You Open It", @"pref" : HRPrefMarkOpened, @"kind" : @(HRRowKindSwitch)},
        @{
          @"title" : @"You Scroll Past It",
          @"pref" : HRPrefMarkScrolledPast,
          @"kind" : @(HRRowKindSwitch)
        },
        @{
          @"title" : @"It Stays on Screen",
          @"pref" : HRPrefMarkLingered,
          @"kind" : @(HRRowKindSwitch)
        },
      ],
      @"footer" : @"“You Open It” includes opening a post’s video, images or link full screen. A "
                  @"post you scroll past stays in the list until the feed reloads. “It Stays on "
                  @"Screen” counts a post visible for a few seconds, using Reddit’s own comment "
                  @"preloading.",
    },
    @{
      @"header" : @"Also Hide Read Posts In",
      @"rows" : @[
        @{@"title" : @"Search Results", @"pref" : HRPrefHideInSearch, @"kind" : @(HRRowKindSwitch)},
        @{@"title" : @"User Profiles", @"pref" : HRPrefHideOnProfiles, @"kind" : @(HRRowKindSwitch)},
      ],
    },
    @{
      @"header" : @"Read History",
      @"rows" : @[
        @{@"title" : @"Posts Marked as Read", @"kind" : @(HRRowKindReadCount)},
        @{@"title" : @"Since Reddit Opened", @"kind" : @(HRRowKindSession)},
        @{@"title" : @"Clear Read History…", @"kind" : @(HRRowKindClearHistory)},
      ],
      @"footer" : @"Read posts are forgotten after 90 days.",
    },
    @{
      @"header" : @"Troubleshooting",
      @"rows" : @[
        @{@"title" : @"Diagnostic Log", @"pref" : HRPrefDiagnostics, @"kind" : @(HRRowKindSwitch)},
        @{@"title" : @"View Log", @"kind" : @(HRRowKindViewLog)},
      ],
      @"footer" : [@"Jax Reddit Eclipse " stringByAppendingString:HRTweakVersion],
    },
    @{
      @"rows" : @[
        @{@"title" : @"🍺 Buy me a beer", @"url" : @"https://opentipjar.com/jax_eclipse", @"kind" : @(HRRowKindLink)},
        @{@"title" : @"Source Code", @"url" : @"https://github.com/alienjax/Reddit-Eclipse", @"kind" : @(HRRowKindLink)},
      ],
    },
  ];
}

// Solid, then see-through over the last `fade` points, eased so neither end of
// the fade shows a line. As a mask, it fades a view out towards its bottom.
static UIImage *HRFadeMask(CGFloat height, CGFloat fade) {
  UIGraphicsImageRenderer *renderer =
      [[UIGraphicsImageRenderer alloc] initWithSize:CGSizeMake(1, height)];
  return [renderer imageWithActions:^(UIGraphicsImageRendererContext *context) {
    for (int y = 0; y < height; y++) {
      CGFloat t = MIN(MAX((y + 0.5 - (height - fade)) / fade, 0.0), 1.0);
      [[UIColor colorWithWhite:0 alpha:1 - t * t * (3 - 2 * t)] setFill];
      [context fillRect:CGRectMake(0, y, 1, 1)];
    }
  }];
}

// The night sky at the top of the settings. Its mask makes it see-through
// towards the bottom, so the page shows through, light or dark.
@interface HideReadSkyView : UIImageView
@end

@implementation HideReadSkyView
- (void)layoutSubviews {
  [super layoutSubviews];
  self.maskView.frame = self.bounds;  // keeps the fade as wide as the sky
}
@end

@implementation HideReadSettingsViewController {
  NSArray<NSDictionary *> *_sections;
}

- (instancetype)init {
  return [self initWithStyle:UITableViewStyleInsetGrouped];
}

- (instancetype)initWithStyle:(UITableViewStyle)style {
  if ((self = [super initWithStyle:style])) {
    self.title = @"Jax Reddit Eclipse";
    _sections = HRSettingsSections();
  }
  return self;
}

- (void)viewDidLoad {
  [super viewDidLoad];
  self.navigationItem.rightBarButtonItem =
      [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemDone
                                                    target:self
                                                    action:@selector(done)];
  self.tableView.tableHeaderView = [self artworkHeader];
  [NSNotificationCenter.defaultCenter addObserver:self
                                         selector:@selector(accountStatusChanged)
                                             name:HRAccountHiderStatusDidChangeNotification
                                           object:nil];
}

// The night sky across the top with the tweak's icon in it. Its lower half
// fades into the page, so the settings carry on from it; it scrolls away with
// them.
- (UIView *)artworkHeader {
  CGRect frame = CGRectMake(0, 0, self.tableView.bounds.size.width, 200);
  UIView *header = [[UIView alloc] initWithFrame:frame];
  header.accessibilityElementsHidden = YES;

  HideReadSkyView *scene = [[HideReadSkyView alloc] initWithImage:HRArtworkScene()];
  scene.contentMode = UIViewContentModeScaleAspectFill;
  scene.maskView = [[UIImageView alloc] initWithImage:HRFadeMask(frame.size.height, 100)];
  scene.accessibilityIgnoresInvertColors = YES;
  scene.translatesAutoresizingMaskIntoConstraints = NO;

  UIImageView *icon = [[UIImageView alloc] initWithImage:HRArtworkIcon()];
  icon.layer.shadowColor = UIColor.blackColor.CGColor;
  icon.layer.shadowOpacity = 0.5;
  icon.layer.shadowRadius = 10;
  icon.layer.shadowOffset = CGSizeMake(0, 4);
  icon.accessibilityIgnoresInvertColors = YES;
  icon.translatesAutoresizingMaskIntoConstraints = NO;

  [header addSubview:scene];
  [header addSubview:icon];
  [NSLayoutConstraint activateConstraints:@[
    [scene.leadingAnchor constraintEqualToAnchor:header.leadingAnchor],
    [scene.trailingAnchor constraintEqualToAnchor:header.trailingAnchor],
    [scene.topAnchor constraintEqualToAnchor:header.topAnchor],
    [scene.bottomAnchor constraintEqualToAnchor:header.bottomAnchor],
    [icon.centerXAnchor constraintEqualToAnchor:header.centerXAnchor],
    [icon.centerYAnchor constraintEqualToAnchor:header.topAnchor constant:92],
    [icon.widthAnchor constraintEqualToConstant:88],
    [icon.heightAnchor constraintEqualToConstant:88],
  ]];
  return header;
}

// The rows that show what hiding on your account is up to, redrawn in place.
- (void)accountStatusChanged {
  if (!self.viewIfLoaded.window) return;
  NSMutableArray<NSIndexPath *> *paths = [NSMutableArray array];
  for (NSUInteger section = 0; section < _sections.count; section++) {
    NSArray *rows = _sections[section][@"rows"];
    for (NSUInteger row = 0; row < rows.count; row++) {
      HRRowKind kind = (HRRowKind)[rows[row][@"kind"] integerValue];
      if (kind == HRRowKindAccountStatus || kind == HRRowKindHideAllRead)
        [paths addObject:[NSIndexPath indexPathForRow:row inSection:section]];
    }
  }
  [UIView performWithoutAnimation:^{
    [self.tableView reloadRowsAtIndexPaths:paths withRowAnimation:UITableViewRowAnimationNone];
  }];
}

- (void)viewWillAppear:(BOOL)animated {
  [super viewWillAppear:animated];
  [self.tableView reloadData];  // refresh the read count
}

- (void)done {
  [self dismissViewControllerAnimated:YES completion:nil];
}

- (NSDictionary *)rowAtIndexPath:(NSIndexPath *)indexPath {
  return _sections[indexPath.section][@"rows"][indexPath.row];
}

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView {
  return _sections.count;
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
  return [_sections[section][@"rows"] count];
}

- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section {
  return _sections[section][@"header"];
}

// The first section has no title; the bottom of the night sky already fades
// into the page, so it only needs a small gap. Other sections keep the usual
// height.
- (CGFloat)tableView:(UITableView *)tableView heightForHeaderInSection:(NSInteger)section {
  return section == 0 && !_sections[0][@"header"] ? 8 : tableView.sectionHeaderHeight;
}

- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section {
  return _sections[section][@"footer"];
}

- (UITableViewCell *)tableView:(UITableView *)tableView
         cellForRowAtIndexPath:(NSIndexPath *)indexPath {
  NSDictionary *row = [self rowAtIndexPath:indexPath];
  HRRowKind kind = (HRRowKind)[row[@"kind"] integerValue];
  UITableViewCell *cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault
                                                 reuseIdentifier:nil];
  UIListContentConfiguration *content = kind == HRRowKindReadCount
                                            ? [UIListContentConfiguration valueCellConfiguration]
                                            : [UIListContentConfiguration cellConfiguration];
  content.text = row[@"title"];

  switch (kind) {
    case HRRowKindSwitch: {
      HideReadSwitch *toggle = [HideReadSwitch new];
      toggle.prefKey = row[@"pref"];
      toggle.on = HRPref(toggle.prefKey);
      [toggle addTarget:self
                    action:@selector(switchChanged:)
          forControlEvents:UIControlEventValueChanged];
      cell.accessoryView = toggle;
      cell.selectionStyle = UITableViewCellSelectionStyleNone;
      break;
    }
    case HRRowKindReadCount:
      content.secondaryText =
          [NSNumberFormatter localizedStringFromNumber:@(HideReadStore.sharedStore.count)
                                           numberStyle:NSNumberFormatterDecimalStyle];
      cell.selectionStyle = UITableViewCellSelectionStyleNone;
      break;
    case HRRowKindClearHistory:
      content.textProperties.color = UIColor.systemRedColor;
      break;
    case HRRowKindViewLog:
      cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
      break;
    case HRRowKindAccountStatus: {
      NSDictionary<NSString *, id> *status = HRAccountHiderStatus();
      content = [UIListContentConfiguration subtitleCellConfiguration];
      content.text = row[@"title"];
      content.secondaryText = status[@"line"];
      content.secondaryTextProperties.color = UIColor.secondaryLabelColor;
      content.textToSecondaryTextVerticalPadding = 3;
      UILabel *count = [UILabel new];
      count.text = HRFormatted([status[@"hidden"] unsignedIntegerValue]);
      count.font = [UIFont preferredFontForTextStyle:UIFontTextStyleBody];
      count.textColor = UIColor.secondaryLabelColor;
      [count sizeToFit];
      cell.accessoryView = count;
      cell.selectionStyle = UITableViewCellSelectionStyleNone;
      break;
    }
    case HRRowKindHideAllRead:
      if ([HRAccountHiderStatus()[@"bulkTotal"] unsignedIntegerValue]) {
        content.text = @"Stop Hiding Read Posts";
        content.textProperties.color = UIColor.systemRedColor;
      } else {
        content.textProperties.color = self.view.tintColor ?: UIColor.systemBlueColor;
      }
      break;
    case HRRowKindSession: {
      content = [UIListContentConfiguration subtitleCellConfiguration];
      content.text = row[@"title"];
      NSUInteger counted = HideReadStore.sharedStore.sessionCount;
      content.secondaryText = [NSString
          stringWithFormat:@"%@ seen in feeds · %@ counted as read (%@ scrolled past)",
                           HRFormatted(HRFeedPostsSeenCount()), HRFormatted(counted),
                           HRFormatted(MIN(HRScrollTrackerScrolledPastCount(), counted))];
      content.secondaryTextProperties.color = UIColor.secondaryLabelColor;
      content.textToSecondaryTextVerticalPadding = 3;
      cell.selectionStyle = UITableViewCellSelectionStyleNone;
      break;
    }
    case HRRowKindLink:
      content.textProperties.color = self.view.tintColor ?: UIColor.systemBlueColor;
      cell.accessibilityTraits |= UIAccessibilityTraitLink;
      cell.accessibilityHint = @"Opens the page outside Reddit.";
      break;
  }
  cell.contentConfiguration = content;
  return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
  [tableView deselectRowAtIndexPath:indexPath animated:YES];
  switch ((HRRowKind)[[self rowAtIndexPath:indexPath][@"kind"] integerValue]) {
    case HRRowKindClearHistory:
      [self confirmClearHistory];
      break;
    case HRRowKindViewLog:
      [self.navigationController pushViewController:[HideReadLogViewController new] animated:YES];
      break;
    case HRRowKindHideAllRead:
      if ([HRAccountHiderStatus()[@"bulkTotal"] unsignedIntegerValue])
        [self confirmStopHidingAll];
      else
        [self confirmHideAllRead];
      break;
    case HRRowKindLink: {
      NSURL *url = [NSURL URLWithString:[self rowAtIndexPath:indexPath][@"url"]];
      if (url) [UIApplication.sharedApplication openURL:url options:[NSDictionary dictionary] completionHandler:nil];
      break;
    }
    case HRRowKindSwitch:
    case HRRowKindReadCount:
    case HRRowKindAccountStatus:
    case HRRowKindSession:
      break;
  }
}

- (void)confirmHideAllRead {
  NSUInteger count = HRAccountHiderReadPostsToHide();
  UIAlertController *alert;
  if (!count) {
    alert = [UIAlertController
        alertControllerWithTitle:@"Nothing to Hide"
                         message:HideReadStore.sharedStore.count
                                     ? @"Every post in your read history is already hidden on your Reddit account."
                                     : @"Your read history is empty."
                  preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleCancel handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];
    return;
  }
  // 25 posts a request, a request every 2 seconds.
  NSUInteger minutes = (NSUInteger)ceil((count + 24) / 25 * 2 / 60.0);
  NSString *time = minutes <= 1 ? @"under a minute" : [NSString stringWithFormat:@"about %lu minutes", (unsigned long)minutes];
  alert = [UIAlertController
      alertControllerWithTitle:@"Hide All Read Posts?"
                       message:[NSString stringWithFormat:@"%@ read posts go on your account’s Hidden list, out of "
                                                          @"your feeds on every device. It takes %@; you can keep "
                                                          @"browsing.",
                                                          HRFormatted(count), time]
                preferredStyle:UIAlertControllerStyleAlert];
  [alert addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
  [alert addAction:[UIAlertAction actionWithTitle:[NSString stringWithFormat:@"Hide %@ Posts", HRFormatted(count)]
                                            style:UIAlertActionStyleDefault
                                          handler:^(UIAlertAction *action) {
                                            HRAccountHiderHideAllRead(NO);
                                          }]];
  [self presentViewController:alert animated:YES completion:nil];
}

- (void)confirmStopHidingAll {
  UIAlertController *alert =
      [UIAlertController alertControllerWithTitle:@"Stop Hiding Read Posts?"
                                          message:@"Posts already hidden on your account stay hidden."
                                   preferredStyle:UIAlertControllerStyleAlert];
  [alert addAction:[UIAlertAction actionWithTitle:@"Keep Going" style:UIAlertActionStyleCancel handler:nil]];
  [alert addAction:[UIAlertAction actionWithTitle:@"Stop"
                                            style:UIAlertActionStyleDestructive
                                          handler:^(UIAlertAction *action) {
                                            HRAccountHiderStopHidingAll();
                                          }]];
  [self presentViewController:alert animated:YES completion:nil];
}

- (void)switchChanged:(HideReadSwitch *)sender {
  [NSUserDefaults.standardUserDefaults setBool:sender.isOn forKey:sender.prefKey];
  if ([sender.prefKey isEqualToString:HRPrefHideButton]) HRHideButtonUpdateLater();
  if ([sender.prefKey isEqualToString:HRPrefHideOnAccount] || [sender.prefKey isEqualToString:HRPrefEnabled])
    [self accountStatusChanged];
  if ([sender.prefKey isEqualToString:HRPrefDiagnostics] && sender.isOn)
    HRLog(@"[info] Diagnostic log started: Jax Reddit Eclipse %@, Reddit %@, iOS %@", HRTweakVersion,
          NSBundle.mainBundle.infoDictionary[@"CFBundleShortVersionString"] ?: @"?",
          UIDevice.currentDevice.systemVersion);
}

- (void)confirmClearHistory {
  UIAlertController *alert = [UIAlertController
      alertControllerWithTitle:@"Clear Read History?"
                       message:@"Every post you’ve read will show up in your feeds again."
                preferredStyle:UIAlertControllerStyleAlert];
  [alert addAction:[UIAlertAction actionWithTitle:@"Cancel"
                                            style:UIAlertActionStyleCancel
                                          handler:nil]];
  __weak typeof(self) weakSelf = self;
  [alert addAction:[UIAlertAction actionWithTitle:@"Clear"
                                            style:UIAlertActionStyleDestructive
                                          handler:^(UIAlertAction *action) {
                                            [HideReadStore.sharedStore removeAllPostIDs];
                                            HRLog(@"[info] Read history cleared");
                                            [weakSelf.tableView reloadData];
                                          }]];
  [self presentViewController:alert animated:YES completion:nil];
}

@end

#pragma mark - Entry points

// Settings open in Jax Reddit Eclipse's own window, so opening them doesn't depend on how
// Reddit arranges its screens. The window never becomes the key window, so the
// app's key window (where Reddit and other tweaks present their own screens)
// stays as it was, and touches outside Jax Reddit Eclipse's sheet go straight through.
@interface HideReadWindow : UIWindow
@end

@implementation HideReadWindow
- (UIView *)hitTest:(CGPoint)point withEvent:(UIEvent *)event {
  UIView *hit = [super hitTest:point withEvent:event];
  return (hit == self || hit == self.rootViewController.view) ? nil : hit;
}
@end

static HideReadWindow *gSettingsWindow;

// What's at the top of the screen now: a newer banner replaces both, and a faint
// note waits out a banner.
static __weak UIView *gBanner;
static __weak UIView *gToast;

void HRShowBanner(NSString *text, NSTimeInterval duration) {
  UIWindowScene *scene = HRActiveScene();
  UIWindow *window = gSettingsWindow ?: (HRMainWindow(scene) ?: HRKeyWindow());
  if (!window) return;
  [gBanner removeFromSuperview];
  [gToast removeFromSuperview];

  UILabel *label = [UILabel new];
  label.text = text;
  label.font = [UIFont systemFontOfSize:14 weight:UIFontWeightSemibold];
  label.textColor = UIColor.whiteColor;
  label.textAlignment = NSTextAlignmentCenter;
  label.numberOfLines = 0;
  label.translatesAutoresizingMaskIntoConstraints = NO;

  UIView *banner = [UIView new];
  banner.backgroundColor = [UIColor colorWithWhite:0.1 alpha:0.92];
  banner.layer.cornerRadius = 18;
  banner.translatesAutoresizingMaskIntoConstraints = NO;
  banner.userInteractionEnabled = NO;
  banner.alpha = 0;
  [banner addSubview:label];
  [window addSubview:banner];
  gBanner = banner;

  [NSLayoutConstraint activateConstraints:@[
    [label.leadingAnchor constraintEqualToAnchor:banner.leadingAnchor constant:16],
    [label.trailingAnchor constraintEqualToAnchor:banner.trailingAnchor constant:-16],
    [label.topAnchor constraintEqualToAnchor:banner.topAnchor constant:10],
    [label.bottomAnchor constraintEqualToAnchor:banner.bottomAnchor constant:-10],
    [banner.centerXAnchor constraintEqualToAnchor:window.centerXAnchor],
    [banner.topAnchor constraintEqualToAnchor:window.safeAreaLayoutGuide.topAnchor constant:8],
    [banner.widthAnchor constraintLessThanOrEqualToAnchor:window.widthAnchor constant:-32],
  ]];

  [UIView animateWithDuration:0.3
      animations:^{
        banner.alpha = 1;
      }
      completion:^(BOOL finished) {
        [UIView animateWithDuration:0.3
            delay:duration
            options:0
            animations:^{
              banner.alpha = 0;
            }
            completion:^(BOOL done) {
              [banner removeFromSuperview];
            }];
      }];
}

void HRShowToast(NSString *text) {
  UIWindow *window = HRMainWindow(HRActiveScene()) ?: HRKeyWindow();
  if (!window || gBanner.superview) return;
  [gToast removeFromSuperview];

  UILabel *label = [UILabel new];
  label.text = text;
  label.font = [UIFont systemFontOfSize:13 weight:UIFontWeightMedium];
  label.textColor = UIColor.whiteColor;
  label.textAlignment = NSTextAlignmentCenter;
  label.translatesAutoresizingMaskIntoConstraints = NO;

  UIView *toast = [UIView new];
  toast.backgroundColor = [UIColor colorWithWhite:0 alpha:0.45];
  toast.layer.cornerRadius = 13;
  toast.translatesAutoresizingMaskIntoConstraints = NO;
  toast.userInteractionEnabled = NO;
  toast.alpha = 0;
  [toast addSubview:label];
  [window addSubview:toast];
  gToast = toast;

  [NSLayoutConstraint activateConstraints:@[
    [label.leadingAnchor constraintEqualToAnchor:toast.leadingAnchor constant:12],
    [label.trailingAnchor constraintEqualToAnchor:toast.trailingAnchor constant:-12],
    [label.topAnchor constraintEqualToAnchor:toast.topAnchor constant:6],
    [label.bottomAnchor constraintEqualToAnchor:toast.bottomAnchor constant:-6],
    [toast.centerXAnchor constraintEqualToAnchor:window.centerXAnchor],
    [toast.topAnchor constraintEqualToAnchor:window.safeAreaLayoutGuide.topAnchor constant:6],
    [toast.widthAnchor constraintLessThanOrEqualToAnchor:window.widthAnchor constant:-32],
  ]];

  // Fades in gently, stays a moment, fades out gently.
  [UIView animateWithDuration:0.35
      delay:0
      options:UIViewAnimationOptionBeginFromCurrentState | UIViewAnimationOptionAllowUserInteraction |
              UIViewAnimationOptionCurveEaseOut
      animations:^{
        toast.alpha = 0.85;
      }
      completion:^(BOOL finished) {
        [UIView animateWithDuration:0.5
            delay:0.6
            options:UIViewAnimationOptionBeginFromCurrentState | UIViewAnimationOptionAllowUserInteraction |
                    UIViewAnimationOptionCurveEaseIn
            animations:^{
              toast.alpha = 0;
            }
            completion:^(BOOL done) {
              [toast removeFromSuperview];
            }];
      }];
}

static void HRCloseSettingsWindow(void) {
  UIWindow *window = gSettingsWindow;
  if (!window) return;
  gSettingsWindow = nil;
  // Selecting text in the log can make Jax Reddit Eclipse's window key. Hand that back to
  // Reddit's window rather than leaving it to chance.
  BOOL wasKey = window.isKeyWindow;
  window.hidden = YES;
  if (wasKey) [HRMainWindow(window.windowScene) makeKeyWindow];
}

@interface HideReadNavigationController : UINavigationController
@end

@implementation HideReadNavigationController
- (void)viewDidDisappear:(BOOL)animated {
  [super viewDidDisappear:animated];
  // Done button or swipe down: take Jax Reddit Eclipse's window away again.
  if (self.isBeingDismissed || !self.presentingViewController) HRCloseSettingsWindow();
}
@end

void HRPresentSettings(void) {
  dispatch_async(dispatch_get_main_queue(), ^{
    if (gSettingsWindow) return;  // already open

    UIWindowScene *scene = HRActiveScene();
    if (!scene) {
      HRLog(@"[settings] couldn't open: no active window scene");
      HRShowBanner(@"Jax Reddit Eclipse couldn't open its settings (no active window).", 3);
      return;
    }

    HideReadWindow *window = [[HideReadWindow alloc] initWithWindowScene:scene];
    // Just above Reddit's own window, and below alerts and other tweaks'
    // overlays.
    window.windowLevel = UIWindowLevelNormal + 1;
    window.backgroundColor = UIColor.clearColor;
    UIViewController *host = [UIViewController new];
    host.view.backgroundColor = UIColor.clearColor;
    window.rootViewController = host;
    gSettingsWindow = window;
    window.hidden = NO;  // shown without becoming the key window

    HideReadNavigationController *navigation = [[HideReadNavigationController alloc]
        initWithRootViewController:[HideReadSettingsViewController new]];
    navigation.modalPresentationStyle = UIModalPresentationFormSheet;
    [host presentViewController:navigation animated:YES completion:nil];
    HRLog(@"[settings] opened");

    // If the sheet never came up, don't leave Jax Reddit Eclipse's window behind.
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.5 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
                     if (gSettingsWindow == window && !navigation.viewIfLoaded.window) {
                       HRLog(@"[settings] the settings sheet didn't appear");
                       HRCloseSettingsWindow();
                       HRShowBanner(@"Jax Reddit Eclipse couldn't open its settings. Please try again.", 3);
                     }
                   });
  });
}

#pragma mark - Two-finger double tap

// Opens the settings while the Hide button isn't in the tab bar (turned off, or
// Reddit has too many tabs for it). While it is, holding Hide opens them, and the
// double tap doesn't even begin.

@interface HideReadGestureHandler : NSObject <UIGestureRecognizerDelegate>
@end

@implementation HideReadGestureHandler

+ (instancetype)sharedHandler {
  static HideReadGestureHandler *handler;
  static dispatch_once_t once;
  dispatch_once(&once, ^{
    handler = [self new];
  });
  return handler;
}

- (void)handleDoubleTap:(UITapGestureRecognizer *)recognizer {
  if (recognizer.state != UIGestureRecognizerStateRecognized) return;
  HRLog(@"[settings] two-finger double tap detected");
  HRPresentSettings();
}

- (BOOL)gestureRecognizerShouldBegin:(UIGestureRecognizer *)gestureRecognizer {
  return !HRHideButtonIsInTabBar();
}

// Never get in the way of the app's own gestures. A double tap can't set off
// the app's own long press.
- (BOOL)gestureRecognizer:(UIGestureRecognizer *)gestureRecognizer
    shouldRecognizeSimultaneouslyWithGestureRecognizer:(UIGestureRecognizer *)other {
  return YES;
}

@end

void HRInstallSettingsGesture(UIWindow *window) {
  static char kInstalledKey;
  if (!window || [window isKindOfClass:HideReadWindow.class] ||
      objc_getAssociatedObject(window, &kInstalledKey))
    return;
  // Reddit's main window only. If its scene delegate doesn't say which window
  // that is, the window that just became key stands in.
  UIWindow *main = HRMainWindow(window.windowScene);
  if (main && main != window) return;

  HideReadGestureHandler *handler = [HideReadGestureHandler sharedHandler];
  UITapGestureRecognizer *doubleTap =
      [[UITapGestureRecognizer alloc] initWithTarget:handler action:@selector(handleDoubleTap:)];
  doubleTap.numberOfTouchesRequired = 2;
  doubleTap.numberOfTapsRequired = 2;
  doubleTap.cancelsTouchesInView = NO;
  doubleTap.delaysTouchesBegan = NO;
  doubleTap.delaysTouchesEnded = NO;
  doubleTap.delegate = handler;
  [window addGestureRecognizer:doubleTap];
  objc_setAssociatedObject(window, &kInstalledKey, doubleTap, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

void HRInstallSettingsGestures(void) {
  for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
    if (![scene isKindOfClass:UIWindowScene.class]) continue;
    UIWindow *main = HRMainWindow((UIWindowScene *)scene);
    if (main) HRInstallSettingsGesture(main);
  }
}

void HRShowFirstLaunchHintIfNeeded(void) {
  if (HRPref(HRPrefHintShown)) return;
  dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.5 * NSEC_PER_SEC)),
                 dispatch_get_main_queue(), ^{
                   if (HRPref(HRPrefHintShown) || !HRActiveScene()) return;
                   [NSUserDefaults.standardUserDefaults setBool:YES forKey:HRPrefHintShown];
                   HRShowBanner(HRHideButtonIsInTabBar()
                                    ? @"Jax Reddit Eclipse is on. Tap Hide in the tab bar to hide your read "
                                      @"posts on your account, or touch and hold it for the settings."
                                    : @"Jax Reddit Eclipse is on. Double-tap with two fingers to open its "
                                      @"settings.",
                                5);
                 });
}

void HRShowReadHintIfNeeded(void) {
  if (HRPref(HRPrefReadHintShown)) return;
  dispatch_async(dispatch_get_main_queue(), ^{
    if (HRPref(HRPrefReadHintShown) || !HRActiveScene()) return;
    [NSUserDefaults.standardUserDefaults setBool:YES forKey:HRPrefReadHintShown];
    HRShowBanner(@"Jax Reddit Eclipse counted a post as read, so it won't show up in your feeds again. "
                 @"Touch and hold Hide in the tab bar for its settings.",
                 5);
  });
}
