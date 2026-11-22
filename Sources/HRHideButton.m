#import "HRHideButton.h"
#import <objc/runtime.h>
#import "HRAccountHider.h"
#import "HideReadSettingsViewController.h"
#import "HideReadStore.h"
#import "HRScrollTracker.h"
#import "HRShared.h"

// The Hide button: an extra item in Reddit's tab bar, between Inbox and You. A tap
// hides every read post on your Reddit account ("Hide All Read Posts Now", see
// HRAccountHider); touching and holding it opens Jax Reddit Eclipse's settings.
//
// How it stays out of Reddit's way:
//  - It goes in as soon as Reddit's tab bar is on screen, on the main queue's
//    next pass (never inside one of Reddit's own callbacks). Nothing is ever
//    made to load early.
//  - It's a real tab bar item, added at the end of the tab bar controller's list
//    with UIKit's own setter. Reddit's tabs keep their places in that list, in
//    case Reddit counts its tabs by position, and iOS spaces all five slots.
//    When Reddit sets its tabs again, Hide goes straight back in.
//  - To show between Inbox and You, the Hide and You buttons trade slots. iOS
//    still places every button itself: Jax Reddit Eclipse only translates where iOS puts
//    those two, as it puts them (-[UITabBarButton setFrame:] and -setCenter:
//    are wrapped, and act on those buttons only). So iOS and Jax Reddit Eclipse never
//    disagree about where a button goes. Moving them after each layout instead
//    would make the tab bar lay itself out again and again. If it ever does
//    anyway, Jax Reddit Eclipse stops trading slots for good and Hide stays at the end.
//  - Reddit draws some of its tab bar itself (its Create button) at the places
//    the tabs have in a bar without Hide. Any such view is shifted on screen to
//    where its tab now is, with a transform, which layout never looks at.
//  - Its taps are Jax Reddit Eclipse's, matched to the buttons as they're shown: a touch on
//    Hide goes to it whatever would have taken it (Reddit's main window's
//    -hitTest:withEvent: is wrapped), and the button's actions are taken over,
//    so its empty tab is never selected. No tab change comes of a tap on it
//    (tab changes are vetted), and anything that asks for its empty tab gets the
//    tab actually under the finger.
//  - At most five tabs, as iOS puts a sixth behind "More".
//  - Safety net: a flag is up while the tab goes in and for five seconds after.
//    If Reddit freezes or crashes then, the flag is still up at the next launch,
//    and the Hide button is turned off.

static NSString *const kHRHideTabID = @"jax_reddit_eclipse_tab_bar__hide_button";
static NSString *const kHRHideTitle = @"Hide";
static NSString *const kHRAddingTabFlag = @"HRAddingHideTab";

static void HRHideTapped(NSString *via);
static void HRQueueShiftCheck(UITabBar *tabBar);
static void HRSelectTab(UITabBarController *tabs, UIViewController *tab);

static __weak UITabBarController *gTabs;
static UINavigationController *gHideTab;
static __weak UIViewController *gLastTab;  // the last of Reddit's own tabs that was selected
static BOOL gArrangeOff;                   // the tab bar kept relaying out: Hide stays at the end
static BOOL gUpdateQueued;
static BOOL gTurnedOffLastRun;
static BOOL gChangingTabsOurselves;        // a tab change of our own, not to be vetted
static NSMutableSet<NSString *> *gWrapped;
static NSMutableArray<NSString *> *gWrapNotes;  // what the wrapped classes had of their own, for the log
static NSHashTable<UIView *> *gShiftedViews;    // Reddit's views shifted onto their tabs
static char kHRSlotsKey;                        // on a button: @[ iOS's slot, slot shown, number of slots ]
static char kHRShiftKey;                        // on a shifted view: by how much

// The latest touch on the tab bar: when, where (tab bar coordinates), and
// whether it was on Hide as Hide is shown.
static CFAbsoluteTime gTouchTime;
static CGPoint gTouchPoint;
static BOOL gTouchOnHide;

// Storage for a wrapped method's previous implementation, kept for the rest of
// the app's run.
static IMP *HRNewSlot(void) {
  return calloc(1, sizeof(IMP));
}

// Wraps a method on a class at run time: adds an override if the class only
// inherits the method, otherwise swaps the replacement in. The previous
// implementation goes in *previous (NULL if there was none and the method was
// added with `typesIfMissing`). Notes for the log which classes had their own.
static void HRInstallWrapper(Class cls, SEL selector, IMP *previous, IMP replacement,
                             const char *typesIfMissing) {
  Method method = class_getInstanceMethod(cls, selector);
  const char *types = method ? method_getTypeEncoding(method) : typesIfMissing;
  if (!cls || !types) return;
  *previous = method ? method_getImplementation(method) : NULL;
  if (class_addMethod(cls, selector, replacement, types)) return;
  *previous = method_setImplementation(class_getInstanceMethod(cls, selector), replacement);
  if (!gWrapNotes) gWrapNotes = [NSMutableArray array];
  [gWrapNotes addObject:[NSString stringWithFormat:@"%@ has its own -%@", NSStringFromClass(cls),
                                                   NSStringFromSelector(selector)]];
}

#pragma mark - Finding things

static UIWindow *HRMainWindow(void) {
  for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
    if (![scene isKindOfClass:UIWindowScene.class] ||
        (scene.activationState != UISceneActivationStateForegroundActive &&
         scene.activationState != UISceneActivationStateForegroundInactive))
      continue;
    id delegate = scene.delegate;
    if ([delegate respondsToSelector:@selector(window)]) {
      id window = [delegate window];
      if ([window isKindOfClass:UIWindow.class]) return window;
    }
    for (UIWindow *window in ((UIWindowScene *)scene).windows)
      if (window.isKeyWindow) return window;
  }
  return nil;
}

// Reddit's tab bar controller, if it's on screen. Only reads the view controller
// tree, which loads nothing.
static UITabBarController *HRFindTabBarController(void) {
  UIWindow *window = HRMainWindow();
  if (!window.rootViewController) return nil;
  NSMutableArray<UIViewController *> *queue = [NSMutableArray arrayWithObject:window.rootViewController];
  NSHashTable<UIViewController *> *queued = [NSHashTable weakObjectsHashTable];
  [queued addObject:window.rootViewController];
  UITabBarController *first = nil;
  for (NSUInteger i = 0; i < queue.count && i < 300; i++) {
    UIViewController *controller = queue[i];
    if ([controller isKindOfClass:UITabBarController.class] && controller.viewIfLoaded.window) {
      UITabBarController *tabs = (UITabBarController *)controller;
      for (UIViewController *tab in tabs.viewControllers)
        if ([tab.tabBarItem.accessibilityIdentifier hasPrefix:@"reddit_tab_bar__"]) return tabs;
      if (!first) first = tabs;
    }
    NSMutableArray<UIViewController *> *next = [controller.childViewControllers mutableCopy];
    if (controller.presentedViewController) [next addObject:controller.presentedViewController];
    for (UIViewController *candidate in next) {
      if ([queued containsObject:candidate]) continue;
      [queued addObject:candidate];
      [queue addObject:candidate];
    }
  }
  return first;
}

// An item's button: UIKit's own link from an item to its button (the private
// -[UITabBarItem view], there since iOS 8), checked to be a button of this tab
// bar.
static UIControl *HRButtonForItem(UITabBar *tabBar, UITabBarItem *item) {
  static SEL selector;
  if (!selector) selector = NSSelectorFromString(@"view");
  if (!tabBar || ![item respondsToSelector:selector]) return nil;
  id view = ((id (*)(id, SEL))[item methodForSelector:selector])(item, selector);
  if (![view isKindOfClass:UIControl.class] || [(UIView *)view superview] != tabBar) return nil;
  return view;
}

// Reddit names its tabs ("reddit_tab_bar__inbox_button"), on the item or its button.
static NSString *HRItemID(UITabBar *tabBar, UITabBarItem *item) {
  NSString *identifier = item.accessibilityIdentifier;
  if (identifier.length) return identifier;
  return HRButtonForItem(tabBar, item).accessibilityIdentifier;
}

// Whether a tab is Reddit's "home", "inbox" or "profile": by its name, or failing
// that its title.
static BOOL HRIsTab(UITabBar *tabBar, UITabBarItem *item, NSString *name) {
  if ([HRItemID(tabBar, item).lowercaseString containsString:name]) return YES;
  return item.title.length && [item.title caseInsensitiveCompare:name] == NSOrderedSame;
}

static UIViewController *HRHomeTab(UITabBarController *tabs) {
  UITabBar *tabBar = tabs.viewIfLoaded ? tabs.tabBar : nil;
  for (UIViewController *tab in tabs.viewControllers)
    if (tab != gHideTab && HRIsTab(tabBar, tab.tabBarItem, @"home")) return tab;
  for (UIViewController *tab in tabs.viewControllers)
    if (tab != gHideTab) return tab;
  return nil;
}

static BOOL HRIsTabBarButton(UIView *view) {
  return [view isKindOfClass:UIControl.class] && [NSStringFromClass(view.class) containsString:@"TabBarButton"];
}

static BOOL HRShowsText(UIView *root, NSString *text) {
  NSMutableArray<UIView *> *queue = [NSMutableArray arrayWithObject:root];
  for (NSUInteger i = 0; i < queue.count && i < 20; i++) {
    UIView *view = queue[i];
    if ([view isKindOfClass:UILabel.class] && [((UILabel *)view).text isEqualToString:text]) return YES;
    [queue addObjectsFromArray:view.subviews];
  }
  return NO;
}

// Each item's button, in the items' order, from UIKit's own link from an item to
// its button; nil if that link is missing for any of them.
static NSArray<UIControl *> *HRLinkedButtons(UITabBar *tabBar, NSArray<UITabBarItem *> *items) {
  NSMutableArray<UIControl *> *buttons = [NSMutableArray array];
  for (UITabBarItem *item in items) {
    UIControl *button = HRButtonForItem(tabBar, item);
    if (!button || [buttons indexOfObjectIdenticalTo:button] != NSNotFound) return nil;
    [buttons addObject:button];
  }
  return buttons;
}

// The Hide button found by its label, for when that link is missing.
static UIControl *HRHideButtonByLabel(UITabBar *tabBar) {
  for (UIView *view in tabBar.subviews)
    if (HRIsTabBarButton(view) && HRShowsText(view, kHRHideTitle)) return (UIControl *)view;
  return nil;
}

#pragma mark - Slots

// The width of each slot in a tab bar of `count` tabs laid out the way iOS lays
// out an iPhone's: equal slots across the safe area. 0 on an iPad, which lays
// tabs out differently.
static CGFloat HRSlotWidth(UIView *tabBar, NSUInteger count, CGFloat *left) {
  if (!tabBar || count == 0 || UIDevice.currentDevice.userInterfaceIdiom != UIUserInterfaceIdiomPhone) return 0;
  UIEdgeInsets safe = tabBar.safeAreaInsets;
  CGFloat width = tabBar.bounds.size.width - safe.left - safe.right;
  if (width <= 0) return 0;
  if (left) *left = safe.left;
  return width / count;
}

static BOOL HRIsRightToLeft(UIView *view) {
  return view.effectiveUserInterfaceLayoutDirection == UIUserInterfaceLayoutDirectionRightToLeft;
}

// Which slot a point across the tab bar is in, counted from the leading edge.
static NSInteger HRSlotAt(UIView *tabBar, CGFloat x, CGFloat left, CGFloat slot, NSUInteger count) {
  NSInteger index = (NSInteger)floor((x - left) / slot);
  return HRIsRightToLeft(tabBar) ? (NSInteger)count - 1 - index : index;
}

// The middle of a slot, across the tab bar.
static CGFloat HRSlotMiddle(UIView *tabBar, NSInteger index, CGFloat left, CGFloat slot, NSUInteger count) {
  NSInteger fromLeft = HRIsRightToLeft(tabBar) ? (NSInteger)count - 1 - index : index;
  return left + ((CGFloat)fromLeft + 0.5) * slot;
}

// Where a button goes when something puts its middle at `x`: for a button that
// trades slots, if `x` is in the slot iOS gives it, the same place in the slot
// it shows in. Anywhere else (already there, or passing through in an
// animation), it stays.
static CGFloat HRMappedX(UIView *button, CGFloat x) {
  if (gArrangeOff) return x;
  NSArray<NSNumber *> *slots = objc_getAssociatedObject(button, &kHRSlotsKey);
  if (slots.count != 3) return x;
  UIView *tabBar = button.superview;
  NSInteger from = slots[0].integerValue, to = slots[1].integerValue;
  NSUInteger count = slots[2].unsignedIntegerValue;
  CGFloat left = 0;
  CGFloat slot = HRSlotWidth(tabBar, count, &left);
  if (slot <= 0 || HRSlotAt(tabBar, x, left, slot, count) != from) return x;
  return x + HRSlotMiddle(tabBar, to, left, slot, count) - HRSlotMiddle(tabBar, from, left, slot, count);
}

// Wraps -setFrame: and -setCenter: of the tab bar's button class, so every
// placing of a button that trades slots goes through HRMappedX, and
// -pointInside:withEvent:, so such a button takes touches where it's shown
// (iOS may still go by the slot it gave it). Other buttons are untouched.
static void HRWrapButtonGeometry(Class cls) {
  if (!cls) return;
  NSString *key = [@"geometry:" stringByAppendingString:NSStringFromClass(cls)];
  if ([gWrapped containsObject:key]) return;
  [gWrapped addObject:key];

  SEL frameSelector = @selector(setFrame:);
  IMP *previousFrame = HRNewSlot();
  HRInstallWrapper(cls, frameSelector, previousFrame, imp_implementationWithBlock(^(UIView *me, CGRect frame) {
                     CGFloat x = CGRectGetMidX(frame);
                     frame.origin.x += HRMappedX(me, x) - x;
                     ((void (*)(id, SEL, CGRect)) * previousFrame)(me, frameSelector, frame);
                   }),
                   NULL);

  SEL centerSelector = @selector(setCenter:);
  IMP *previousCenter = HRNewSlot();
  HRInstallWrapper(cls, centerSelector, previousCenter, imp_implementationWithBlock(^(UIView *me, CGPoint center) {
                     center.x = HRMappedX(me, center.x);
                     ((void (*)(id, SEL, CGPoint)) * previousCenter)(me, centerSelector, center);
                   }),
                   NULL);

  SEL insideSelector = @selector(pointInside:withEvent:);
  IMP *previousInside = HRNewSlot();
  HRInstallWrapper(cls, insideSelector, previousInside,
                   imp_implementationWithBlock(^BOOL(UIView *me, CGPoint point, UIEvent *event) {
                     if (!gArrangeOff && objc_getAssociatedObject(me, &kHRSlotsKey))
                       return CGRectContainsPoint(me.bounds, point);
                     return ((BOOL (*)(id, SEL, CGPoint, UIEvent *)) * previousInside)(me, insideSelector, point,
                                                                                         event);
                   }),
                   NULL);
}

static void HRClearSlots(UITabBar *tabBar) {
  for (UIView *view in tabBar.subviews)
    if (objc_getAssociatedObject(view, &kHRSlotsKey))
      objc_setAssociatedObject(view, &kHRSlotsKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

#pragma mark - Reddit's own views in the tab bar

static void HRShiftView(UIView *view, CGFloat dx) {
  if (fabs(dx) < 0.5) dx = 0;
  BOOL ours = objc_getAssociatedObject(view, &kHRShiftKey) != nil;
  CGAffineTransform transform = view.transform;
  BOOL identity = CGAffineTransformIsIdentity(transform);
  BOOL ourShift = ours && transform.a == 1 && transform.b == 0 && transform.c == 0 && transform.d == 1 &&
                  transform.ty == 0;
  if (!identity && !ourShift) return;  // a transform of Reddit's own (an animation, say): left alone
  if (fabs(transform.tx - dx) < 0.5) return;
  view.transform = dx == 0 ? CGAffineTransformIdentity : CGAffineTransformMakeTranslation(dx, 0);
  objc_setAssociatedObject(view, &kHRShiftKey, dx == 0 ? nil : @(dx), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
  if (!gShiftedViews) gShiftedViews = [NSHashTable weakObjectsHashTable];
  if (dx == 0) [gShiftedViews removeObject:view];
  else [gShiftedViews addObject:view];
}

static void HRUnshiftViews(void) {
  for (UIView *view in gShiftedViews.allObjects) HRShiftView(view, 0);
}

// The views to look at: the tab bar's, and the small ones beside it in the tab
// bar controller's view, each with how deep it is.
static void HRAddTabBarViews(UITabBar *tabBar, NSMutableArray<UIView *> *views,
                             NSMutableArray<NSNumber *> *depths) {
  for (UIView *view in tabBar.subviews) {
    [views addObject:view];
    [depths addObject:@0];
  }
  for (UIView *view in gTabs.viewIfLoaded.subviews)
    if (view != tabBar && view.bounds.size.height <= tabBar.bounds.size.height * 2) {
      [views addObject:view];
      [depths addObject:@0];
    }
}

// Reddit's own views, in or beside the tab bar, that sit in the middle of a slot
// of the bar without Hide but not on that tab's button any more (its Create
// button), are shifted on screen onto their tab's button. Views Jax Reddit Eclipse shifted
// that no longer need it go back.
static void HRShiftStaleViews(UITabBar *tabBar) {
  UITabBarController *tabs = gTabs;
  NSArray<UITabBarItem *> *items = tabBar.items;
  NSUInteger ours = gHideTab ? [items indexOfObjectIdenticalTo:gHideTab.tabBarItem] : NSNotFound;
  // Hide is always last in the list, so Reddit's tabs keep their positions.
  NSArray<UIControl *> *buttons =
      tabs.tabBar == tabBar && ours != NSNotFound && ours == items.count - 1 ? HRLinkedButtons(tabBar, items) : nil;
  NSUInteger before = items.count - 1;
  CGFloat left = 0;
  CGFloat slot = buttons ? HRSlotWidth(tabBar, before, &left) : 0;
  NSHashTable<UIView *> *stale = [NSHashTable weakObjectsHashTable];

  if (slot > 0) {
    CGFloat barHeight = tabBar.bounds.size.height;
    NSMutableArray<UIView *> *views = [NSMutableArray array];
    NSMutableArray<NSNumber *> *depths = [NSMutableArray array];
    HRAddTabBarViews(tabBar, views, depths);
    for (NSUInteger i = 0; i < views.count && i < 300; i++) {
      UIView *view = views[i];
      if (view.hidden || view.alpha < 0.05 || HRIsTabBarButton(view) || !view.superview) continue;
      CGSize size = view.bounds.size;
      if (size.width > 4 && size.width <= slot * 1.4 && size.height > 4 && size.height <= barHeight * 1.5) {
        CGPoint center = [view.superview convertPoint:view.center toView:tabBar];
        NSInteger index = HRSlotAt(tabBar, center.x, left, slot, before);
        if (center.y > -barHeight * 0.5 && center.y < barHeight * 1.5 && index >= 0 && index < (NSInteger)before &&
            fabs(center.x - HRSlotMiddle(tabBar, index, left, slot, before)) <= 3) {
          UIControl *button = buttons[index];
          CGFloat target = [button.superview convertPoint:button.center toView:tabBar].x;
          if (fabs(target - center.x) >= 1) {
            [stale addObject:view];
            HRShiftView(view, target - center.x);
            HRLogOnce([@"shift-" stringByAppendingString:NSStringFromClass(view.class)],
                      @"[hide] Reddit's %@%@ sat where tab %ld is in a bar without Hide; shifted it %.0f points onto "
                      @"its tab",
                      NSStringFromClass(view.class),
                      view.accessibilityIdentifier.length
                          ? [NSString stringWithFormat:@" (%@)", view.accessibilityIdentifier]
                          : @"",
                      (long)index + 1, target - center.x);
          }
          continue;
        }
      }
      if (depths[i].integerValue < 3)
        for (UIView *subview in view.subviews) {
          [views addObject:subview];
          [depths addObject:@(depths[i].integerValue + 1)];
        }
    }
  }
  for (UIView *view in gShiftedViews.allObjects)
    if (![stale containsObject:view]) HRShiftView(view, 0);
}

// After a layout pass, once the whole pass is over: Reddit lays out its own
// views in the same pass, some after the tab bar.
static void HRQueueShiftCheck(UITabBar *tabBar) {
  static BOOL queued;
  if (queued) return;
  queued = YES;
  __weak UITabBar *weakBar = tabBar;
  dispatch_async(dispatch_get_main_queue(), ^{
    queued = NO;
    UITabBar *bar = weakBar;
    if (bar) HRShiftStaleViews(bar);
  });
}

#pragma mark - Diagnostics

static NSString *HRDescribeView(UIView *view, UIView *tabBar) {
  CGRect frame = [view convertRect:view.bounds toView:tabBar];
  NSMutableString *text =
      [NSMutableString stringWithFormat:@"%@ at %.0f,%.0f %.0fx%.0f", NSStringFromClass(view.class),
                                        frame.origin.x, frame.origin.y, frame.size.width, frame.size.height];
  if (view.accessibilityIdentifier.length) [text appendFormat:@", id %@", view.accessibilityIdentifier];
  NSString *words = [view isKindOfClass:UILabel.class] ? ((UILabel *)view).text : view.accessibilityLabel;
  if (words.length) [text appendFormat:@", “%@”", words.length > 30 ? [words substringToIndex:30] : words];
  if ([view isKindOfClass:UIImageView.class])
    [text appendString:((UIImageView *)view).image ? @", has image" : @", no image"];
  if (view.hidden || view.alpha < 0.05) [text appendString:@", hidden"];
  NSNumber *shift = objc_getAssociatedObject(view, &kHRShiftKey);
  if (shift) [text appendFormat:@", shifted %.0f by Jax Reddit Eclipse", shift.doubleValue];
  else if (!CGAffineTransformIsIdentity(view.transform)) [text appendString:@", transformed"];
  return text;
}

static NSString *HRGestureList(UIView *view) {
  NSMutableArray<NSString *> *names = [NSMutableArray array];
  for (UIGestureRecognizer *recognizer in view.gestureRecognizers)
    [names addObject:[NSString stringWithFormat:@"%@%@", NSStringFromClass(recognizer.class),
                                                recognizer.enabled ? @"" : @" (off)"]];
  return names.count ? [names componentsJoinedByString:@", "] : @"none";
}

// The tab bar's tabs and the views in and beside it, once, so the log shows how
// Reddit builds its tab bar and handles touches on it.
static void HRLogTabBar(UITabBarController *tabs) {
  if (!HRPref(HRPrefDiagnostics) || !tabs.viewIfLoaded.window) return;
  UITabBar *tabBar = tabs.tabBar;
  NSArray<UITabBarItem *> *items = tabBar.items;
  HRLog(@"[tabbar] %@, %.0fx%.0f, %lu tabs:", NSStringFromClass(tabBar.class), tabBar.bounds.size.width,
        tabBar.bounds.size.height, (unsigned long)items.count);
  for (NSUInteger i = 0; i < items.count; i++) {
    UITabBarItem *item = items[i];
    UIControl *button = HRButtonForItem(tabBar, item);
    HRLog(@"[tabbar]   tab %lu: id %@, title %@, image %@; button %@", (unsigned long)i + 1,
          item.accessibilityIdentifier.length ? item.accessibilityIdentifier : @"none",
          item.title.length ? [NSString stringWithFormat:@"“%@”", item.title] : @"none",
          item.image ? [NSString stringWithFormat:@"%.0fx%.0f", item.image.size.width, item.image.size.height]
                     : @"none",
          button ? HRDescribeView(button, tabBar) : @"not found");
    if (button.gestureRecognizers.count) HRLog(@"[tabbar]       gestures: %@", HRGestureList(button));
    NSUInteger shown = 0;
    for (UIView *subview in button.subviews) {
      if (shown++ == 4) break;
      HRLog(@"[tabbar]       %@", HRDescribeView(subview, tabBar));
    }
  }
  NSMutableArray<NSString *> *chain = [NSMutableArray array];
  for (UIView *view = tabBar; view; view = view.superview)
    if (view.gestureRecognizers.count)
      [chain addObject:[NSString stringWithFormat:@"%@: %@", NSStringFromClass(view.class), HRGestureList(view)]];
  HRLog(@"[tabbar] gesture recognizers on the tab bar and up: %@",
        chain.count ? [chain componentsJoinedByString:@"; "] : @"none");
  for (NSString *note in gWrapNotes) HRLog(@"[tabbar] %@ (wrapped)", note);
  HRLog(@"[tabbar] other views in and beside it:");
  NSMutableArray<UIView *> *views = [NSMutableArray array];
  NSMutableArray<NSNumber *> *depths = [NSMutableArray array];
  HRAddTabBarViews(tabBar, views, depths);
  NSUInteger logged = 0;
  for (NSUInteger i = 0; i < views.count && logged < 30; i++) {
    UIView *view = views[i];
    if (HRIsTabBarButton(view)) continue;
    NSInteger depth = depths[i].integerValue;
    HRLog(@"[tabbar]   %@%@", [@"" stringByPaddingToLength:(NSUInteger)depth * 2 withString:@" " startingAtIndex:0],
          HRDescribeView(view, tabBar));
    logged++;
    if (depth < 2) {
      NSUInteger at = i + 1;  // right after it, in order
      for (UIView *subview in view.subviews) {
        [views insertObject:subview atIndex:at];
        [depths insertObject:@(depth + 1) atIndex:at];
        at++;
      }
    }
  }
}

#pragma mark - The tab

@interface HideReadTabTapHandler : NSObject <UIGestureRecognizerDelegate>
@end

// When Hide was last held down: the tap ways in (see HRHideTapped) stand down
// for that touch.
static CFAbsoluteTime gHeldTime;

@implementation HideReadTabTapHandler
- (void)hideTapped {
  [[[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleLight] impactOccurred];
  HRHideTapped(@"its button");
}

- (void)hideHeld:(UILongPressGestureRecognizer *)recognizer {
  if (recognizer.state != UIGestureRecognizerStateBegan) return;
  gHeldTime = CFAbsoluteTimeGetCurrent();
  [[[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleMedium] impactOccurred];
  HRLog(@"[hide] Hide held down: opening the settings");
  HRPresentSettings();
}

// Other long presses on the way (Reddit's own on its tab bar, iOS's large-content
// viewer) wait for this one, so holding Hide only ever opens the settings.
- (BOOL)gestureRecognizer:(UIGestureRecognizer *)gestureRecognizer
    shouldBeRequiredToFailByGestureRecognizer:(UIGestureRecognizer *)other {
  return [other isKindOfClass:UILongPressGestureRecognizer.class];
}
@end

static HideReadTabTapHandler *gTapHandler;

#pragma mark - Touches on the tab bar

static BOOL HRRecentTouch(void) {
  return CFAbsoluteTimeGetCurrent() - gTouchTime < 1.5;
}

static void HRHideTappedSoon(NSString *via) {
  dispatch_async(dispatch_get_main_queue(), ^{
    HRHideTapped(via);
  });
}

static NSString *HRTabName(UITabBarController *tabs, UIViewController *tab) {
  if (!tab) return @"no tab";
  if (tab == gHideTab) return @"the Hide tab";
  NSString *name = HRItemID(tabs.viewIfLoaded ? tabs.tabBar : nil, tab.tabBarItem) ?: tab.tabBarItem.title;
  return name.length ? name : NSStringFromClass(tab.class);
}

// The tab whose button is where the latest touch was (as the buttons are
// shown), if that touch was recent.
static UIViewController *HRTabUnderTouch(UITabBarController *tabs) {
  if (!HRRecentTouch() || !tabs.viewIfLoaded) return nil;
  UITabBar *tabBar = tabs.tabBar;
  NSArray<UITabBarItem *> *items = tabBar.items;
  NSArray<UIControl *> *buttons = HRLinkedButtons(tabBar, items);
  for (NSUInteger i = 0; i < buttons.count; i++) {
    if (!CGRectContainsPoint(buttons[i].frame, gTouchPoint)) continue;
    for (UIViewController *tab in tabs.viewControllers)
      if (tab.tabBarItem == items[i]) return tab;
  }
  return nil;
}

// A tab change of Jax Reddit Eclipse's own, past its own vetting.
static void HRChangeTabOurselves(UITabBarController *tabs, UIViewController *tab) {
  gChangingTabsOurselves = YES;
  @try {
    HRSelectTab(tabs, tab);
  } @finally {
    gChangingTabsOurselves = NO;
  }
}

// Every tab change Reddit's tab bar controller is asked for goes through here.
// None comes of a tap on Hide, whatever took that tap; and the Hide tab's empty screen
// is never shown (the tab actually under the finger instead, if there is one).
// Returns the tab to change to, or nil for none.
static UIViewController *HRVetTabChange(UITabBarController *tabs, UIViewController *target) {
  if (gChangingTabsOurselves || !gHideTab || tabs != gTabs || target == tabs.selectedViewController) return target;
  if (HRRecentTouch() && gTouchOnHide) {
    HRLog(@"[hide] a tap on Hide also asked to switch to %@; ignored that", HRTabName(tabs, target));
    HRHideTappedSoon(@"a tab change");
    return nil;
  }
  if (target != gHideTab) return target;
  UIViewController *under = HRTabUnderTouch(tabs);
  if (under && under != gHideTab) {
    HRLog(@"[hide] the Hide tab was asked for, but the tap was on %@; switched to that", HRTabName(tabs, under));
    return under;
  }
  HRLog(@"[hide] the Hide tab was asked for without a tap on the tab bar; stayed put");
  return nil;
}

// The (empty) screen behind the Hide item. It's only ever shown if a tab change
// got past HRVetTabChange: then it goes straight back.
@interface HideReadTabRootController : UIViewController
@end

@implementation HideReadTabRootController
- (void)viewWillAppear:(BOOL)animated {
  [super viewWillAppear:animated];
  dispatch_async(dispatch_get_main_queue(), ^{
    UITabBarController *tabs = gTabs;
    if (!tabs || tabs.selectedViewController != gHideTab) return;
    UIViewController *back = HRTabUnderTouch(tabs);
    if (!back || back == gHideTab) back = gLastTab ?: HRHomeTab(tabs);
    if (back && back != gHideTab) {
      gChangingTabsOurselves = YES;
      tabs.selectedViewController = back;
      gChangingTabsOurselves = NO;
    }
    HRLog(@"[hide] the Hide tab's empty screen opened; went back to %@", HRTabName(tabs, back));
    if (HRRecentTouch() && gTouchOnHide) HRHideTapped(@"its empty tab");
  });
}
@end

static UINavigationController *HRMakeHideTab(void) {
  UINavigationController *tab =
      [[UINavigationController alloc] initWithRootViewController:[HideReadTabRootController new]];
  UIImage *icon = [UIImage systemImageNamed:@"eye.slash"];
  tab.tabBarItem = [[UITabBarItem alloc] initWithTitle:kHRHideTitle image:icon selectedImage:icon];
  tab.tabBarItem.accessibilityIdentifier = kHRHideTabID;
  tab.tabBarItem.accessibilityHint =
      @"Hides your read posts on your Reddit account. Touch and hold for Jax Reddit Eclipse's settings.";
  return tab;
}

// Sets the tabs with UIKit's own setter, so an override in Reddit's tab bar
// controller (and anything it keeps about its tabs) isn't involved.
static void HRSetTabs(UITabBarController *tabs, NSArray<UIViewController *> *controllers) {
  SEL selector = @selector(setViewControllers:animated:);
  IMP base = class_getMethodImplementation(UITabBarController.class, selector);
  ((void (*)(id, SEL, NSArray *, BOOL))base)(tabs, selector, controllers, NO);
}

// Taps on Hide are Jax Reddit Eclipse's alone, so iOS never selects its tab. Holding
// it down opens the settings: the long press cancels the button's touch, so that
// touch is no tap.
static void HRTakeTaps(UIControl *button) {
  static char kHRHoldKey;
  if (!objc_getAssociatedObject(button, &kHRHoldKey)) {
    UILongPressGestureRecognizer *hold =
        [[UILongPressGestureRecognizer alloc] initWithTarget:gTapHandler action:@selector(hideHeld:)];
    hold.minimumPressDuration = 0.45;
    hold.delegate = gTapHandler;
    [button addGestureRecognizer:hold];
    objc_setAssociatedObject(button, &kHRHoldKey, hold, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
  }
  NSSet *targets = button.allTargets;
  if (targets.count == 1 && [targets containsObject:gTapHandler]) return;
  [button removeTarget:nil action:NULL forControlEvents:UIControlEventAllEvents];
  [button addTarget:gTapHandler action:@selector(hideTapped) forControlEvents:UIControlEventTouchUpInside];
}

#pragma mark - Arranging the tab bar

// Where Hide shows: You's slot (just after Inbox), or straight after Inbox.
static NSUInteger HRHideSlot(UITabBar *tabBar, NSArray<UITabBarItem *> *items) {
  NSUInteger inbox = NSNotFound;
  for (NSUInteger i = 0; i < items.count; i++) {
    if (items[i] == gHideTab.tabBarItem) continue;
    if (HRIsTab(tabBar, items[i], @"profile")) return i;
    if (HRIsTab(tabBar, items[i], @"inbox")) inbox = i;
  }
  return inbox == NSNotFound ? NSNotFound : inbox + 1;
}

// Loop breaker: the tab bar laid out more than 30 times without the app getting
// back to its run loop is a loop that would freeze Reddit. Jax Reddit Eclipse then stops
// trading slots for good, and iOS puts the buttons back in its own order.
static BOOL HRArrangeLooping(UITabBar *tabBar) {
  static NSUInteger passes;
  static BOOL resetQueued;
  if (!resetQueued) {
    resetQueued = YES;
    dispatch_async(dispatch_get_main_queue(), ^{
      passes = 0;
      resetQueued = NO;
    });
  }
  if (++passes <= 30) return NO;
  gArrangeOff = YES;
  [tabBar setNeedsLayout];
  HRLog(@"[hide] the tab bar keeps laying itself out, so Hide stays at the end of it from now on");
  return YES;
}

// After each layout of the tab bar: takes the Hide button's taps over, tells the
// buttons that trade slots which ones, and has Reddit's own views checked.
static void HRArrangeTabBar(UITabBar *tabBar) {
  UITabBarController *tabs = gTabs;
  if (!tabs || tabs.tabBar != tabBar) return;
  NSArray<UITabBarItem *> *items = tabBar.items;
  NSUInteger ours = gHideTab ? [items indexOfObjectIdenticalTo:gHideTab.tabBarItem] : NSNotFound;
  if (ours == NSNotFound) {
    HRClearSlots(tabBar);
    if (gShiftedViews.count) HRQueueShiftCheck(tabBar);
    return;
  }
  NSArray<UIControl *> *buttons = HRLinkedButtons(tabBar, items);
  UIControl *hideButton = buttons ? buttons[ours] : HRHideButtonByLabel(tabBar);
  if (hideButton) HRTakeTaps(hideButton);
  else HRLogOnce(@"hide-no-button", @"[hide] couldn't find the Hide button among the tab bar's buttons");
  HRQueueShiftCheck(tabBar);
  if (!buttons) {
    HRLogOnce(@"hide-no-link", @"[hide] can't tell which button is whose, so Hide stays at the end");
    return;
  }
  if (gArrangeOff || HRArrangeLooping(tabBar)) return;
  HRWrapButtonGeometry([hideButton class]);

  NSUInteger count = items.count;
  NSUInteger target = HRHideSlot(tabBar, items);
  if (target == NSNotFound || target > ours || HRSlotWidth(tabBar, count, NULL) <= 0) target = ours;
  NSMutableArray<UIControl *> *trading = [NSMutableArray array];
  BOOL changed = NO;
  for (NSUInteger i = 0; i < count; i++) {
    NSUInteger to = i == ours ? target : (i >= target && i < ours ? i + 1 : i);
    NSArray<NSNumber *> *slots = to == i ? nil : @[ @(i), @(to), @(count) ];
    NSArray *current = objc_getAssociatedObject(buttons[i], &kHRSlotsKey);
    if (current == slots || [current isEqual:slots]) continue;
    objc_setAssociatedObject(buttons[i], &kHRSlotsKey, slots, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    if (slots) [trading addObject:buttons[i]];
    changed = YES;
  }
  if (!changed) return;
  // Into their slots now, each through the same translation as iOS's own placing.
  for (UIControl *button in trading) button.center = button.center;
  [tabBar setNeedsLayout];
  if (target != ours)
    HRLogOnce(@"hide-slot", @"[hide] Hide shows in slot %lu of %lu, the tab there moves one slot along",
              (unsigned long)target + 1, (unsigned long)count);
}

// Runs HRArrangeTabBar after the tab bar's own -layoutSubviews, every time
// (wrapped once, at run time, on the tab bar's own class; the original always
// runs first).
static void HRWrapTabBarLayout(UITabBar *tabBar) {
  Class cls = [tabBar class];
  NSString *key = [@"layout:" stringByAppendingString:NSStringFromClass(cls)];
  if ([gWrapped containsObject:key]) return;
  [gWrapped addObject:key];
  SEL selector = @selector(layoutSubviews);
  Method method = class_getInstanceMethod(cls, selector);
  if (!method) return;
  IMP *previous = calloc(1, sizeof(IMP));
  *previous = method_getImplementation(method);
  IMP replacement = imp_implementationWithBlock(^(UITabBar *bar) {
    ((void (*)(id, SEL)) * previous)(bar, selector);
    @try {
      HRArrangeTabBar(bar);
    } @catch (NSException *exception) {
      gArrangeOff = YES;
      HRLog(@"[hide] couldn't arrange the tab bar: %@", exception.reason);
    }
  });
  if (!class_addMethod(cls, selector, replacement, method_getTypeEncoding(method)))
    *previous = method_setImplementation(class_getInstanceMethod(cls, selector), replacement);
}

// What a tap that iOS reported as Hide's (or that was on Hide but reported as
// another tab's) really was: Hide, or the tab actually under the finger.
static void HRHandleMisroutedTap(UITabBarController *tabs) {
  UIViewController *under = HRRecentTouch() && !gTouchOnHide ? HRTabUnderTouch(tabs) : nil;
  if (under && under != gHideTab) {
    dispatch_async(dispatch_get_main_queue(), ^{
      HRChangeTabOurselves(tabs, under);
    });
    return;
  }
  HRHideTappedSoon(@"the tab bar");
}

// Reddit's tab bar controller never hears of a tap on Hide (its own handling
// of taps, if it has any, only sees its own tabs), nor of another tab for a tap
// that was on Hide.
static void HRWrapDidSelectItem(UITabBarController *tabs) {
  Class cls = [tabs class];
  NSString *key = [@"item:" stringByAppendingString:NSStringFromClass(cls)];
  if ([gWrapped containsObject:key]) return;
  [gWrapped addObject:key];
  SEL selector = @selector(tabBar:didSelectItem:);
  IMP *previous = HRNewSlot();
  HRInstallWrapper(cls, selector, previous, imp_implementationWithBlock(^(id me, UITabBar *bar, UITabBarItem *item) {
                     if (!gChangingTabsOurselves && gHideTab && me == gTabs) {
                       if (item && item == gHideTab.tabBarItem) {
                         HRHandleMisroutedTap(gTabs);
                         return;
                       }
                       if (HRRecentTouch() && gTouchOnHide) {
                         HRHideTappedSoon(@"the tab bar");
                         return;
                       }
                     }
                     if (*previous) ((void (*)(id, SEL, id, id)) * previous)(me, selector, bar, item);
                   }),
                   "v32@0:8@16@24");
}

// The delegate says no to the Hide tab, and to any tab change that comes of a
// tap on Hide, and asks Reddit as before about anything else.
static void HRWrapShouldSelect(id delegate) {
  if (!delegate) return;
  Class cls = [delegate class];
  NSString *key = [@"delegate:" stringByAppendingString:NSStringFromClass(cls)];
  if ([gWrapped containsObject:key]) return;
  [gWrapped addObject:key];
  SEL selector = @selector(tabBarController:shouldSelectViewController:);
  IMP *previous = HRNewSlot();
  HRInstallWrapper(
      cls, selector, previous,
      imp_implementationWithBlock(^BOOL(id me, UITabBarController *tabs, UIViewController *controller) {
        if (!gChangingTabsOurselves && gHideTab && tabs == gTabs) {
          if (controller && controller == gHideTab) {
            HRHandleMisroutedTap(tabs);
            return NO;
          }
          if (controller != tabs.selectedViewController && HRRecentTouch() && gTouchOnHide) {
            HRHideTappedSoon(@"the tab bar");
            return NO;
          }
        }
        if (!*previous) return YES;
        return ((BOOL (*)(id, SEL, id, id)) * previous)(me, selector, tabs, controller);
      }),
      "B32@0:8@16@24");
}

// Tab changes asked of Reddit's tab bar controller, by Reddit or by iOS, are
// vetted (HRVetTabChange) before they happen.
static void HRWrapTabChanges(UITabBarController *tabs) {
  Class cls = [tabs class];
  NSString *key = [@"select:" stringByAppendingString:NSStringFromClass(cls)];
  if ([gWrapped containsObject:key]) return;
  [gWrapped addObject:key];

  SEL controllerSelector = @selector(setSelectedViewController:);
  IMP *previousController = HRNewSlot();
  HRInstallWrapper(cls, controllerSelector, previousController,
                   imp_implementationWithBlock(^(UITabBarController *me, UIViewController *controller) {
                     UIViewController *vetted = controller;
                     if (me == gTabs && controller) {
                       vetted = HRVetTabChange(me, controller);
                       if (!vetted) return;
                       if (vetted != gHideTab) gLastTab = vetted;
                     }
                     ((void (*)(id, SEL, id)) * previousController)(me, controllerSelector, vetted);
                   }),
                   NULL);

  SEL indexSelector = @selector(setSelectedIndex:);
  IMP *previousIndex = HRNewSlot();
  HRInstallWrapper(cls, indexSelector, previousIndex, imp_implementationWithBlock(^(UITabBarController *me, NSUInteger index) {
                     if (me == gTabs) {
                       NSArray<UIViewController *> *controllers = me.viewControllers;
                       if (index < controllers.count) {
                         UIViewController *vetted = HRVetTabChange(me, controllers[index]);
                         if (!vetted) return;
                         NSUInteger vettedIndex = [controllers indexOfObjectIdenticalTo:vetted];
                         if (vettedIndex == NSNotFound) return;
                         index = vettedIndex;
                       }
                     }
                     ((void (*)(id, SEL, NSUInteger)) * previousIndex)(me, indexSelector, index);
                   }),
                   NULL);
}

// A view sized and placed like part of the tab bar (Reddit's own, beside it).
static BOOL HRIsOverTabBar(UIView *view, UITabBar *tabBar) {
  CGRect frame = [view convertRect:view.bounds toView:tabBar];
  return CGRectContainsRect(CGRectInset(tabBar.bounds, -2, -30), frame);
}

// Every touch on Reddit's main window. One on the tab bar is noted (for
// HRVetTabChange). One on Hide, as Hide is shown, goes to Hide, whatever iOS or
// Reddit would have given it to; one on another tab's button that would have
// gone to Hide goes to that button.
static UIView *HRRouteTouch(UIWindow *window, UIEvent *event, CGPoint point, UIView *result) {
  UITabBarController *tabs = gTabs;
  if (!gHideTab || !event || event.type != UIEventTypeTouches || window != tabs.viewIfLoaded.window) return result;
  UITabBar *tabBar = tabs.tabBar;
  if (tabBar.hidden || tabBar.alpha < 0.05 || tabBar.window != window) return result;
  CGPoint inBar = [tabBar convertPoint:point fromView:window];
  if (!CGRectContainsPoint(tabBar.bounds, inBar)) return result;
  // Only touches that would go to the tab bar, something in it or sized like
  // part of it, or to nothing more than what it's in. Anything covering it (a
  // sheet, a full-screen view) keeps its touches.
  BOOL tabBarTouch = !result || [result isDescendantOfView:tabBar] || [tabBar isDescendantOfView:result] ||
                     HRIsOverTabBar(result, tabBar);
  if (!tabBarTouch) return result;
  NSArray<UITabBarItem *> *items = tabBar.items;
  NSUInteger ours = [items indexOfObjectIdenticalTo:gHideTab.tabBarItem];
  if (ours == NSNotFound) return result;
  NSArray<UIControl *> *buttons = HRLinkedButtons(tabBar, items);
  UIControl *hideButton = buttons ? buttons[ours] : HRHideButtonByLabel(tabBar);
  if (!hideButton) return result;

  BOOL onHide = CGRectContainsPoint(hideButton.frame, inBar);
  gTouchTime = CFAbsoluteTimeGetCurrent();
  gTouchPoint = inBar;
  gTouchOnHide = onHide;
  BOOL resultInHide = result && (result == hideButton || [result isDescendantOfView:hideButton]);
  if (onHide) {
    if (resultInHide)
      HRLogOnce(@"hide-touch-direct", @"[hide] taps on Hide reach it directly");
    else
      HRLogOnce(@"hide-touch-routed", @"[hide] a tap on Hide was headed for %@%@; gave it to Hide",
                result ? NSStringFromClass(result.class) : @"nothing",
                result.accessibilityIdentifier.length
                    ? [NSString stringWithFormat:@" (%@)", result.accessibilityIdentifier]
                    : @"");
    return hideButton;
  }
  if (resultInHide)
    for (UIControl *button in buttons)
      if (button != hideButton && CGRectContainsPoint(button.frame, inBar)) {
        HRLogOnce(@"hide-touch-rerouted", @"[hide] a tap on another tab was headed for Hide; gave it to that tab");
        return button;
      }
  return result;
}

static void HRWrapWindowHitTest(UIWindow *window) {
  if (!window) return;
  Class cls = [window class];
  NSString *key = [@"hittest:" stringByAppendingString:NSStringFromClass(cls)];
  if ([gWrapped containsObject:key]) return;
  [gWrapped addObject:key];
  SEL selector = @selector(hitTest:withEvent:);
  IMP *previous = HRNewSlot();
  HRInstallWrapper(cls, selector, previous,
                   imp_implementationWithBlock(^UIView *(UIWindow *me, CGPoint point, UIEvent *event) {
                     UIView *result = ((UIView * (*)(id, SEL, CGPoint, UIEvent *)) * previous)(me, selector, point,
                                                                                                event);
                     @try {
                       return HRRouteTouch(me, event, point, result);
                     } @catch (NSException *exception) {
                       return result;
                     }
                   }),
                   NULL);
}

// When Reddit sets its tabs again (without Hide), Hide goes straight back in.
static void HRWrapSetTabs(UITabBarController *tabs) {
  Class cls = [tabs class];
  NSString *key = [@"tabs:" stringByAppendingString:NSStringFromClass(cls)];
  if ([gWrapped containsObject:key]) return;
  [gWrapped addObject:key];
  SEL selector = @selector(setViewControllers:animated:);
  Method method = class_getInstanceMethod(cls, selector);
  if (!method) return;
  IMP *previous = calloc(1, sizeof(IMP));
  *previous = method_getImplementation(method);
  IMP replacement = imp_implementationWithBlock(^(UITabBarController *me, NSArray *controllers, BOOL animated) {
    ((void (*)(id, SEL, NSArray *, BOOL)) * previous)(me, selector, controllers, animated);
    if (me == gTabs && gHideTab && [controllers indexOfObjectIdenticalTo:gHideTab] == NSNotFound)
      HRHideButtonUpdateLater();
  });
  if (!class_addMethod(cls, selector, replacement, method_getTypeEncoding(method)))
    *previous = method_setImplementation(class_getInstanceMethod(cls, selector), replacement);
}

#pragma mark - Hiding

static void HRSelectTab(UITabBarController *tabs, UIViewController *tab) {
  if (!tabs || !tab || tabs.selectedViewController == tab) return;
  id<UITabBarControllerDelegate> delegate = tabs.delegate;
  if ([delegate respondsToSelector:@selector(tabBarController:shouldSelectViewController:)] &&
      ![delegate tabBarController:tabs shouldSelectViewController:tab])
    return;
  tabs.selectedViewController = tab;
  if ([delegate respondsToSelector:@selector(tabBarController:didSelectViewController:)])
    [delegate tabBarController:tabs didSelectViewController:tab];
}

// A tap on Hide: every read post goes on your Reddit account's Hidden list
// ("Hide All Read Posts Now"), with a faint note now and when it's done. Not
// for a touch that held the button down: that one opened the settings.
static void HRHideTapped(NSString *via) {
  // One tap can arrive more than one way.
  static CFAbsoluteTime last;
  CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
  if (now - last < 1.0 || now - gHeldTime < 2.0) return;
  last = now;
  HRLog(@"[hide] Hide tapped (through %@)", via);
  HRAccountHiderHideAllRead(YES);
}

BOOL HRHideButtonIsInTabBar(void) {
  UITabBarController *tabs = gTabs;
  return gHideTab && tabs.viewIfLoaded.window && [tabs.viewControllers indexOfObjectIdenticalTo:gHideTab] != NSNotFound;
}

#pragma mark - Safety net

// Up while the Hide tab goes in and for five seconds after.
static void HRRaiseSafetyFlag(void) {
  static NSUInteger generation;
  NSUInteger mine = ++generation;
  [NSUserDefaults.standardUserDefaults setBool:YES forKey:kHRAddingTabFlag];
  dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
    if (mine == generation) [NSUserDefaults.standardUserDefaults removeObjectForKey:kHRAddingTabFlag];
  });
}

void HRHideButtonCheckLastRun(void) {
  NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
  if (![defaults boolForKey:kHRAddingTabFlag]) return;
  [defaults removeObjectForKey:kHRAddingTabFlag];
  if (!HRPref(HRPrefHideButton)) return;
  [defaults setBool:NO forKey:HRPrefHideButton];
  gTurnedOffLastRun = YES;
}

void HRHideButtonAppWillResignActive(void) {
  // Reddit is still answering, so it didn't freeze.
  NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
  if ([defaults objectForKey:kHRAddingTabFlag]) [defaults removeObjectForKey:kHRAddingTabFlag];
}

#pragma mark - Putting the tab in

void HRHideButtonUpdate(void) {
  if (!gWrapped) gWrapped = [NSMutableSet set];
  UITabBarController *tabs = gTabs;
  if (!tabs.viewIfLoaded.window) {
    tabs = HRFindTabBarController();
    gTabs = tabs;
  }
  // Only a tab bar that's on screen, so nothing is made to load early.
  if (!tabs.viewIfLoaded.window) return;

  NSArray<UIViewController *> *controllers = tabs.viewControllers ?: @[];
  BOOL present = gHideTab && [controllers indexOfObjectIdenticalTo:gHideTab] != NSNotFound;
  if (!HRPref(HRPrefHideButton)) {
    if (present) {
      HRClearSlots(tabs.tabBar);
      HRUnshiftViews();
      NSMutableArray *without = [controllers mutableCopy];
      [without removeObjectIdenticalTo:gHideTab];
      @try {
        HRSetTabs(tabs, without);
        HRLog(@"[hide] Hide tab taken out");
      } @catch (NSException *exception) {
        HRLog(@"[hide] couldn't take the Hide tab out: %@", exception.reason);
      }
    }
    return;
  }
  UIViewController *selected = tabs.selectedViewController;
  if (selected && selected != gHideTab) gLastTab = selected;
  if (present) return;

  if (controllers.count < 2 || controllers.count > 4) {
    HRLogOnce([NSString stringWithFormat:@"hide-tabs-%lu", (unsigned long)controllers.count],
              @"[hide] no Hide tab: Reddit has %lu tabs, and iOS shows at most five", (unsigned long)controllers.count);
    return;
  }
  if (!gHideTab) gHideTab = HRMakeHideTab();
  if (!gTapHandler) gTapHandler = [HideReadTabTapHandler new];
  UITabBar *tabBar = tabs.tabBar;
  HRWrapButtonGeometry(NSClassFromString(@"UITabBarButton"));
  HRWrapTabBarLayout(tabBar);
  HRWrapDidSelectItem(tabs);
  HRWrapShouldSelect(tabs.delegate);
  HRWrapSetTabs(tabs);
  HRWrapTabChanges(tabs);
  HRWrapWindowHitTest(tabs.view.window);
  HRRaiseSafetyFlag();
  @try {
    HRSetTabs(tabs, [controllers arrayByAddingObject:gHideTab]);
  } @catch (NSException *exception) {
    HRLog(@"[hide] couldn't add the Hide tab: %@", exception.reason);
    return;
  }

  NSMutableArray<NSString *> *names = [NSMutableArray array];
  for (UIViewController *tab in controllers)
    [names addObject:HRItemID(tabBar, tab.tabBarItem) ?: (tab.tabBarItem.title ?: @"?")];
  HRLog(@"[hide] Hide tab added to %@ (tab bar %@%@; tabs: %@)", NSStringFromClass(tabs.class),
        NSStringFromClass(tabBar.class), tabBar.hidden ? @", hidden" : @"", [names componentsJoinedByString:@", "]);

  static BOOL described;
  if (!described) {
    described = YES;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
      HRLogTabBar(gTabs);
    });
  }
}

void HRHideButtonUpdateLater(void) {
  if (gUpdateQueued) return;
  gUpdateQueued = YES;
  dispatch_async(dispatch_get_main_queue(), ^{
    gUpdateQueued = NO;
    HRHideButtonUpdate();
  });
}

void HRHideButtonUpdateSoon(void) {
  if (gTurnedOffLastRun) {
    gTurnedOffLastRun = NO;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
      HRLog(@"[hide] Reddit froze or closed last time while the Hide button went in, so it's turned off");
      HRShowBanner(@"Reddit froze or closed last time just as Jax Reddit Eclipse added its Hide button, so the "
                   @"button is off now. You can turn it back on in its settings (two-finger double tap).",
                   7);
    });
  }
  HRHideButtonUpdateLater();
  // In case the tab bar takes a moment to be on screen.
  for (NSNumber *delay in @[ @0.5, @1.5, @3.0 ])
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay.doubleValue * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
                     HRHideButtonUpdate();
                   });
}
