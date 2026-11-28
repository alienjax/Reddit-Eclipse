#import "HRScrollTracker.h"
#import <UIKit/UIGestureRecognizerSubclass.h>
#import <objc/runtime.h>
#import "HideReadSettingsViewController.h"
#import "HideReadStore.h"
#import "HRResponseProcessor.h"
#import "HRScreenTracker.h"
#import "HRShared.h"

// Which posts you've browsed past, seen on screen rather than on the network, and
// without hooking anything: a timer looks at the feed list on screen five times
// a second. Each post card is matched to its post by title, from the feed
// responses Jax Reddit Eclipse read, using the card's accessibility label ("r/sub, Title,
// 12 upvotes, ...") or the texts in it.
//
// A card that was on screen and has since gone above the top of the list was
// scrolled past, which counts as read straight away while "You Scroll Past It" is
// on: the post is left out of every feed that loads from then on. So does every
// post the feed lists above the topmost card on screen, however fast it went by,
// even one never seen here (HRTakePostsListedBefore). Now and then,
// once the list comes to rest, a faint note at the top says how many posts were
// hidden while you browsed: scrolled past, or (with "It Stays on Screen" on)
// counted while still on screen. While "“Posts Hidden” Note" is on.
//
// A tap on a card is noted too (see "Taps on post cards"): if the post's video,
// images, link or page come up right after, it counts as opened.
//
// Only reading happens here: list positions, cells and their labels, and which
// card a tap lands on. Nothing in Reddit's views is changed. Main thread only.

static const NSTimeInterval kHRTickInterval = 0.2;
static const CFAbsoluteTime kHRSearchInterval = 1.0;
static const CGFloat kHRSeenMinimum = 40;  // points of a card that must have been on screen

static NSTimer *gTimer;
static __weak UIScrollView *gList;
static CFAbsoluteTime gLastSearch;
static CGFloat gLastOffset;
static CGFloat gLastContentHeight;
// Post id -> its card's frame (list coordinates) when last on screen.
static NSMutableDictionary<NSString *, NSValue *> *gSeen;
// Cell -> @[ signature, post id or NSNull, time matched ].
static NSMapTable<UIView *, NSArray *> *gCellCache;
// Posts hidden while you browse (scrolled past, or stayed on screen) since the
// last note, when the latest was, and when the last note went up. A note waits
// for at least kHRNoteMinPosts posts and kHRNoteMinInterval seconds since the
// last one. Opening a post and coming back doesn't start the count again.
static NSUInteger gHiddenSinceNote;
static CFAbsoluteTime gLastHidden;
static CFAbsoluteTime gLastNote;
static const NSUInteger kHRNoteMinPosts = 10;
static const CFAbsoluteTime kHRNoteMinInterval = 20;

// Posts counted as read by scrolling past them since Reddit opened.
static NSUInteger gScrolledPastThisRun;

// Diagnostics, per list watched: posts counted, and when the last summary went out.
static NSUInteger gWatchCounted;
static CGFloat gStatsOffset;
static CFAbsoluteTime gStatsTime;

#pragma mark - Views

// Reddit's own main window: the one its scene delegate owns.
static UIWindow *HRAppMainWindow(void) {
  for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
    if (![scene isKindOfClass:UIWindowScene.class] ||
        scene.activationState != UISceneActivationStateForegroundActive)
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

static BOOL HRIsList(UIView *view) {
  return [view isKindOfClass:UICollectionView.class] || [view isKindOfClass:UITableView.class];
}

static NSArray<UIView *> *HRVisibleCells(UIScrollView *list) {
  if ([list isKindOfClass:UICollectionView.class]) return ((UICollectionView *)list).visibleCells;
  if ([list isKindOfClass:UITableView.class]) return ((UITableView *)list).visibleCells;
  return @[];
}

static UIView *HRCellContent(UIView *cell) {
  if ([cell isKindOfClass:UICollectionViewCell.class]) return ((UICollectionViewCell *)cell).contentView;
  if ([cell isKindOfClass:UITableViewCell.class]) return ((UITableViewCell *)cell).contentView;
  return cell;
}

static UIViewController *HROwningController(UIView *view) {
  UIResponder *responder = view.nextResponder;
  while (responder && ![responder isKindOfClass:UIViewController.class])
    responder = responder.nextResponder;
  return (UIViewController *)responder;
}

// Lists inside a post's own screen (its comments) aren't feeds.
static BOOL HRIsInPostScreen(UIView *view) {
  for (UIViewController *controller = HROwningController(view); controller;
       controller = controller.parentViewController)
    if (HRIsPostScreenController(controller)) return YES;
  return NO;
}

// How much of the list you can see, or 0 if it's hidden, elsewhere, or too small
// to be a feed (carousels and the like).
static CGFloat HRVisibleArea(UIScrollView *list, UIWindow *window) {
  if (!window || list.window != window) return 0;
  for (UIView *view = list; view; view = view.superview)
    if (view.hidden || view.alpha < 0.05) return 0;
  // Pages side by side (Home's tabs) are a horizontal list; the feeds are inside.
  if (list.contentSize.width > list.bounds.size.width * 1.5) return 0;
  CGRect visible = CGRectIntersection([list convertRect:list.bounds toView:nil], window.bounds);
  if (CGRectIsNull(visible) || visible.size.height < window.bounds.size.height * 0.4 ||
      visible.size.width < window.bounds.size.width * 0.6)
    return 0;
  return visible.size.width * visible.size.height;
}

#pragma mark - Matching cards to posts

// A card's accessibility label: the cell's own if it has one, else the first
// one under it, which is the post card's ("r/sub, Title, 12 upvotes, ...").
static NSString *HRFirstLabel(UIView *cell) {
  NSString *own = cell.accessibilityLabel;
  if (own.length) return own;
  // Breadth first, and at most 60 views, as this runs for every card on screen
  // several times a second.
  NSMutableArray<UIView *> *queue = [NSMutableArray arrayWithObject:HRCellContent(cell)];
  for (NSUInteger i = 0; i < queue.count && i < 60; i++) {
    NSString *label = queue[i].accessibilityLabel;
    if (label.length) return label;
    [queue addObjectsFromArray:queue[i].subviews];
  }
  return nil;
}

static NSString *HRShortened(NSString *text) {
  return text.length > 80 ? [[text substringToIndex:77] stringByAppendingString:@"..."] : text;
}

// A post id ("t3_abc123") inside a string such as an accessibility identifier.
static NSString *HRPostIDInIdentifier(NSString *identifier) {
  NSRange range = [identifier rangeOfString:@"t3_[0-9a-z]+" options:NSRegularExpressionSearch];
  return range.location == NSNotFound ? nil : [identifier substringWithRange:range];
}

// The texts in a card, for the log when it matches nothing.
static NSArray<NSString *> *HRCardTexts(UIView *cell, NSUInteger limit) {
  NSMutableArray<NSString *> *texts = [NSMutableArray array];
  NSMutableArray<UIView *> *queue = [NSMutableArray arrayWithObject:HRCellContent(cell)];
  for (NSUInteger i = 0; i < queue.count && i < 300 && texts.count < limit; i++) {
    UIView *view = queue[i];
    NSString *text = nil;
    if ([view isKindOfClass:UILabel.class]) text = ((UILabel *)view).text;
    else if ([view isKindOfClass:UITextView.class]) text = ((UITextView *)view).text;
    if (!text.length) text = view.accessibilityLabel;
    if (text.length >= 3) [texts addObject:HRShortened(text)];
    [queue addObjectsFromArray:view.subviews];
  }
  return texts;
}

static NSString *HRMatchCell(UIView *cell, NSString *label) {
  NSString *postID = HRPostIDForText(label, YES) ?: HRPostIDInIdentifier(cell.accessibilityIdentifier);
  // Otherwise something in the card: a post id in an accessibility identifier,
  // or a text, label or value that is exactly a post's title.
  NSMutableArray<UIView *> *queue = [NSMutableArray arrayWithObject:HRCellContent(cell)];
  for (NSUInteger i = 0; !postID && i < queue.count && i < 300; i++) {
    UIView *view = queue[i];
    postID = HRPostIDInIdentifier(view.accessibilityIdentifier);
    NSString *text = nil;
    if ([view isKindOfClass:UILabel.class]) text = ((UILabel *)view).text;
    else if ([view isKindOfClass:UITextView.class]) text = ((UITextView *)view).text;
    if (!postID && text.length >= 3) postID = HRPostIDForText(text, NO);
    NSString *viewLabel = view.accessibilityLabel;
    if (!postID && viewLabel.length >= 3 && ![viewLabel isEqualToString:label])
      postID = HRPostIDForText(viewLabel, viewLabel.length >= 20);
    NSString *value = view.accessibilityValue;
    if (!postID && value.length >= 3) postID = HRPostIDForText(value, NO);
    [queue addObjectsFromArray:view.subviews];
  }
  return postID;
}

static NSString *HRPostIDForCell(UIView *cell) {
  NSString *label = HRFirstLabel(cell);
  // Cells are reused for other posts, so a cached match only stands while the
  // card keeps both its place in the list (which scrolling doesn't change) and
  // its label.
  NSString *signature = [NSString stringWithFormat:@"%.0f|%@", cell.frame.origin.y, label ?: @""];
  CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
  NSArray *cached = [gCellCache objectForKey:cell];
  if (cached && [cached[0] isEqualToString:signature]) {
    if (cached[1] != NSNull.null) return cached[1];
    // Not matched yet (the card may still be filling in): try again shortly.
    if (now - [cached[2] doubleValue] < 0.3) return nil;
  }
  NSString *postID = HRMatchCell(cell, label);
  [gCellCache setObject:@[ signature, postID ?: NSNull.null, @(now) ] forKey:cell];
  return postID;
}

#pragma mark - Finding the feed

static NSArray<UIView *> *HRCellsTopFirst(UIScrollView *list) {
  return [HRVisibleCells(list) sortedArrayUsingComparator:^NSComparisonResult(UIView *a, UIView *b) {
    return [@(CGRectGetMinY(a.frame)) compare:@(CGRectGetMinY(b.frame))];
  }];
}

static UIScrollView *HRFindFeedList(UIWindow *window) {
  UIScrollView *best = nil;
  NSUInteger bestMatches = 0;
  UIScrollView *unmatched = nil;
  NSMutableArray<UIView *> *stack = [NSMutableArray arrayWithObject:window];
  for (NSUInteger visited = 0; stack.count && visited < 5000; visited++) {
    UIView *view = stack.lastObject;
    [stack removeLastObject];
    if (view.hidden || view.alpha < 0.05) continue;
    if (HRIsList(view)) {
      UIScrollView *list = (UIScrollView *)view;
      if (HRVisibleArea(list, window) > 0 && !HRIsInPostScreen(list)) {
        NSUInteger matches = 0;
        for (UIView *cell in HRVisibleCells(list))
          if (HRPostIDForCell(cell)) matches++;
        if (matches > bestMatches) {
          best = list;
          bestMatches = matches;
        } else if (!matches && !unmatched) {
          unmatched = list;
        }
      }
    }
    [stack addObjectsFromArray:view.subviews];
  }
  // Diagnostics: a list that could be the feed but matched nothing, at most once
  // a minute, with its cards' labels or texts, to show why.
  static CFAbsoluteTime lastUnmatchedLog;
  CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
  if (!best && unmatched && HRPref(HRPrefDiagnostics) && now - lastUnmatchedLog > 60) {
    lastUnmatchedLog = now;
    HRLog(@"[scroll] a list on screen (%@ in %@) has no cards matching a known post:",
          NSStringFromClass(unmatched.class),
          NSStringFromClass(HROwningController(unmatched).class) ?: @"?");
    NSUInteger shown = 0;
    for (UIView *cell in HRCellsTopFirst(unmatched)) {
      if (shown++ == 4) break;
      NSString *label = HRFirstLabel(cell);
      HRLog(@"[scroll]   %@ at %.0f, %.0f tall: %@", NSStringFromClass(cell.class), cell.frame.origin.y,
            cell.frame.size.height,
            label.length ? [NSString stringWithFormat:@"label “%@”", HRShortened(label)]
                         : [NSString stringWithFormat:@"no label, texts: %@",
                                                      [HRCardTexts(cell, 3) componentsJoinedByString:@" | "]]);
    }
  }
  return best;
}

#pragma mark - Watching

static void HRCountHidden(void) {
  gHiddenSinceNote++;
  gLastHidden = CFAbsoluteTimeGetCurrent();
}

void HRScrollTrackerPostHidden(void) {
  dispatch_async(dispatch_get_main_queue(), ^{
    HRCountHidden();
  });
}

static void HRMarkScrolledPast(NSString *postID, BOOL listedAbove) {
  if (![HideReadStore.sharedStore markPostID:postID]) return;
  gScrolledPastThisRun++;
  gWatchCounted++;
  HRCountHidden();
  HRLog(@"[read] %@ scrolled past%@", HRDescribePost(postID),
        listedAbove ? @" (listed above the cards on screen)" : @"");
  HRShowReadHintIfNeeded();
}

// Diagnostics: the list just picked up and the cards on it, so the log shows how
// Reddit lays out its feed and whether the cards match.
static void HRLogWatchedList(UIScrollView *list) {
  if (!HRPref(HRPrefDiagnostics)) return;
  UIEdgeInsets inset = list.adjustedContentInset;
  NSArray<UIView *> *cells = HRCellsTopFirst(list);
  HRLog(@"[scroll] watching %@ in %@: at %.0f, insets %.0f/%.0f, %.0f tall, content %.0f, %lu cells",
        NSStringFromClass(list.class), NSStringFromClass(HROwningController(list).class) ?: @"?",
        list.contentOffset.y, inset.top, inset.bottom, list.bounds.size.height,
        list.contentSize.height, (unsigned long)cells.count);
  NSUInteger shown = 0;
  for (UIView *cell in cells) {
    if (shown++ == 6) break;
    NSString *postID = HRPostIDForCell(cell);
    NSString *detail;
    if (postID) {
      detail = HRDescribePost(postID);
    } else {
      NSString *label = HRFirstLabel(cell);
      detail = label.length ? [NSString stringWithFormat:@"no match, label “%@”", HRShortened(label)]
                            : [NSString stringWithFormat:@"no match, no label, texts: %@",
                                                         [HRCardTexts(cell, 3) componentsJoinedByString:@" | "]];
    }
    HRLog(@"[scroll]   %@ at %.0f, %.0f tall: %@", NSStringFromClass(cell.class), cell.frame.origin.y,
          cell.frame.size.height, detail);
  }
}

static void HRForgetPositions(void) {
  [gSeen removeAllObjects];
  [gCellCache removeAllObjects];
}

// Diagnostics: a post card Jax Reddit Eclipse never saw in any answer, or a read
// post's card that isn't in the list Jax Reddit Eclipse handed the app with the
// cards around it. Either way Reddit put it there by itself (below a post you
// opened, say), so the log names the app's requests in the 90 seconds before it
// showed up, to find the one that brought it. Once per card, and at most 12 of
// each kind per run.
static NSMutableDictionary<NSString *, NSNumber *> *gStrangerSince;  // card label or post id -> first on screen
static NSMutableSet<NSString *> *gStrangersTold;
static NSUInteger gUnknownCardsTold;
static NSUInteger gReadCardsTold;

static void HRNoteStrangers(UIScrollView *list, CGFloat top, CGFloat bottom) {
  if (!gStrangerSince) {
    gStrangerSince = [NSMutableDictionary dictionary];
    gStrangersTold = [NSMutableSet set];
  }
  if (gStrangerSince.count > 500) [gStrangerSince removeAllObjects];
  CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
  NSMutableArray<NSString *> *matched = [NSMutableArray array];
  NSMutableArray<UIView *> *unmatched = [NSMutableArray array];
  for (UIView *cell in HRVisibleCells(list)) {
    if (cell.hidden || cell.bounds.size.height < 40) continue;
    if (CGRectGetMaxY(cell.frame) <= top || CGRectGetMinY(cell.frame) >= bottom) continue;
    NSString *postID = HRPostIDForCell(cell);
    if (postID)
      [matched addObject:postID];
    else
      [unmatched addObject:cell];
  }

  for (UIView *cell in unmatched) {
    NSString *label = HRFirstLabel(cell);
    if (label.length < 12 || ![label hasPrefix:@"r/"]) continue;  // a post card's label starts with its subreddit
    NSString *key = [@"label:" stringByAppendingString:label];
    if ([gStrangersTold containsObject:key]) continue;
    NSNumber *since = gStrangerSince[key];
    if (!since) {
      gStrangerSince[key] = @(now);
      continue;
    }
    if (now - since.doubleValue < 1.5) continue;  // it may still be filling in
    [gStrangersTold addObject:key];
    if (gUnknownCardsTold++ >= 12) continue;
    HRLog(@"[scroll] a post card Jax Reddit Eclipse never saw in an answer: “%@” (the app's requests in the 90 "
          @"seconds before it showed up: %@)",
          HRShortened(label), HRRecentAPIRequests(since.doubleValue - 90));
  }

  if (matched.count < 2) return;  // nothing around it to tell by
  HideReadStore *store = HideReadStore.sharedStore;
  for (NSString *postID in matched) {
    NSString *key = [@"post:" stringByAppendingString:postID];
    if ([gStrangersTold containsObject:key]) continue;
    NSTimeInterval readAt = [store readTimeForPostID:postID];
    if (readAt <= 0) continue;
    NSNumber *since = gStrangerSince[key];
    if (!since) gStrangerSince[key] = since = @(now);
    if (HRIsListedWith(postID, matched)) continue;
    [gStrangersTold addObject:key];
    if (gReadCardsTold++ >= 12) continue;
    NSDateFormatter *formatter = [NSDateFormatter new];
    formatter.dateFormat = @"HH:mm:ss";
    HRLog(@"[scroll] %@, read at %@, is on screen, but Jax Reddit Eclipse didn't hand it to the app in this "
          @"list: Reddit added it by itself (the app's requests in the 90 seconds before it showed up: %@)",
          HRDescribePost(postID), [formatter stringFromDate:[NSDate dateWithTimeIntervalSince1970:readAt]],
          HRRecentAPIRequests(since.doubleValue - 90));
  }
}

static void HRWatchList(UIScrollView *list) {
  CGFloat offset = list.contentOffset.y;
  CGFloat height = list.bounds.size.height;
  UIEdgeInsets inset = list.adjustedContentInset;
  CGFloat top = offset + inset.top;  // the top of what's on screen, below the bars
  CGFloat bottom = offset + height - inset.bottom;

  // A jump up of more than two screens without you dragging, or the list
  // getting much shorter: it was refreshed or reset, so old positions are void.
  if ((offset < gLastOffset - 2 * height && !list.isTracking) ||
      list.contentSize.height < gLastContentHeight * 0.5)
    HRForgetPositions();
  // Pulled down past the top: a refresh is coming, and new posts will take the
  // old ones' places. Forgotten once per pull.
  static BOOL pulling;
  BOOL pulled = offset + inset.top < -40;
  if (pulled && !pulling) HRForgetPositions();
  pulling = pulled;
  gLastOffset = offset;
  gLastContentHeight = list.contentSize.height;

  BOOL markScrolledPast = HRPref(HRPrefMarkScrolledPast);
  NSMutableSet<NSString *> *listed = [NSMutableSet set];
  NSMutableArray<NSString *> *onScreen = [NSMutableArray array];  // cards at least partly on screen
  NSString *topmost = nil;                                         // the highest of them
  CGFloat topmostY = CGFLOAT_MAX;
  NSUInteger cellCount = 0;
  for (UIView *cell in HRVisibleCells(list)) {
    // Small rows count too: a feed can give a post's title a row of its own.
    if (cell.hidden || cell.bounds.size.height < 1) continue;
    cellCount++;
    NSString *postID = HRPostIDForCell(cell);
    if (!postID) continue;
    [listed addObject:postID];
    CGRect frame = cell.frame;
    CGFloat shown = MIN(CGRectGetMaxY(frame), bottom) - MAX(CGRectGetMinY(frame), top);
    if (shown >= MIN(kHRSeenMinimum, frame.size.height * 0.5)) {
      gSeen[postID] = [NSValue valueWithCGRect:frame];
    } else if (gSeen[postID] && CGRectGetMaxY(frame) <= top) {
      if (markScrolledPast) HRMarkScrolledPast(postID, NO);
      [gSeen removeObjectForKey:postID];
    }
    if (CGRectGetMaxY(frame) > top && CGRectGetMinY(frame) < bottom) {
      [onScreen addObject:postID];
      if (CGRectGetMinY(frame) < topmostY) {
        topmostY = CGRectGetMinY(frame);
        topmost = postID;
      }
    }
  }
  // Cards that have left the list's visible cells since they were on screen:
  // scrolled past if they're above the top now, otherwise (scrolled back up) not.
  for (NSString *postID in gSeen.allKeys) {
    if ([listed containsObject:postID]) continue;
    if (CGRectGetMaxY(gSeen[postID].CGRectValue) <= top && markScrolledPast) HRMarkScrolledPast(postID, NO);
    [gSeen removeObjectForKey:postID];
  }
  // Every post the feed lists above the topmost card still on screen was
  // scrolled past, however fast it went by: even one never seen here. The cards
  // below it say which list it is.
  if (markScrolledPast && topmost) {
    [onScreen removeObject:topmost];
    for (NSString *postID in HRTakePostsListedBefore(topmost, onScreen)) HRMarkScrolledPast(postID, YES);
  }

  if (HRPref(HRPrefDiagnostics)) HRNoteStrangers(list, top, bottom);

  // Diagnostics: a summary every 1,500 points of scrolling (or 5 seconds of it).
  CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
  CGFloat moved = fabs(offset - gStatsOffset);
  if (HRPref(HRPrefDiagnostics) && (moved > 1500 || (moved > 100 && now - gStatsTime > 5))) {
    gStatsOffset = offset;
    gStatsTime = now;
    HRLog(@"[scroll] at %.0f (top %.0f): %lu cells, %lu matched, %lu counted so far", offset, top,
          (unsigned long)cellCount, (unsigned long)listed.count, (unsigned long)gWatchCounted);
  }
}

#pragma mark - Taps on post cards

// A post's video, images or link can open full screen without its comments
// ever loading, so "You Open It" also counts a post whose card you tap when one
// of those, or the post's page, comes up within a second and a half. Taps are
// seen by a gesture recognizer on Reddit's main window that never recognizes
// anything: every other gesture, button and list gets each touch just as if it
// weren't there.

static const CFAbsoluteTime kHRTapToScreen = 1.5;  // seconds from a tap to the screen it opens
static NSString *gTappedPost;                       // the card tapped last, until a screen takes it
static CFAbsoluteTime gTappedTime;
static NSString *gContentScreen;                    // the post-content screen that came up last
static CFAbsoluteTime gContentScreenTime;

static void HRMarkOpenedByTap(NSString *screen) {
  NSString *postID = gTappedPost;
  gTappedPost = nil;
  gContentScreen = nil;
  if (!postID || !HRPref(HRPrefMarkOpened) || ![HideReadStore.sharedStore markPostID:postID]) return;
  HRLog(@"[read] %@ opened (its card was tapped, then %@ came up)", HRDescribePost(postID), screen);
  HRShowReadHintIfNeeded();
}

// The view of the screen `view` is on: its controller's, or that one's parent's,
// up to the screen-level controller (whose parent, if any, is a navigation, tab
// bar or page controller).
static UIView *HRScreenViewOf(UIView *view) {
  UIViewController *controller = HROwningController(view);
  for (UIViewController *parent = controller.parentViewController;
       parent && ![parent isKindOfClass:UINavigationController.class] &&
       ![parent isKindOfClass:UITabBarController.class] && ![parent isKindOfClass:UIPageViewController.class];
       parent = parent.parentViewController)
    controller = parent;
  return controller.viewIfLoaded;
}

static BOOL HRIsInBar(UIView *view) {
  for (; view; view = view.superview)
    if ([view isKindOfClass:UITabBar.class] || [view isKindOfClass:UINavigationBar.class] ||
        [view isKindOfClass:UIToolbar.class])
      return YES;
  return NO;
}

// The feed card a tap landed on: the cell holding `touched` (the view UIKit gave
// the touch to), else the one under `point` (window coordinates) when what took
// the touch is laid over the list on the same screen, as a video player can be.
static UIView *HRTappedCard(UIScrollView *list, UIView *touched, CGPoint point, BOOL *overlaid) {
  NSArray<UIView *> *cells = HRVisibleCells(list);
  for (UIView *cell in cells)
    if ([touched isDescendantOfView:cell]) return cell;
  UIView *screen = HRScreenViewOf(list);
  if (!screen || ![touched isDescendantOfView:screen] || HRIsInBar(touched)) return nil;
  CGPoint inList = [list convertPoint:point fromView:nil];
  UIEdgeInsets inset = list.adjustedContentInset;
  CGFloat top = list.contentOffset.y + inset.top;
  CGFloat bottom = list.contentOffset.y + list.bounds.size.height - inset.bottom;
  if (inList.y < top || inList.y > bottom || inList.x < 0 || inList.x > list.bounds.size.width) return nil;
  for (UIView *cell in cells)
    if (!cell.hidden && CGRectContainsPoint(cell.frame, inList)) {
      *overlaid = YES;
      return cell;
    }
  return nil;
}

// A quick single tap: notes the post whose card in the feed it landed on.
static void HRCardTapped(UIView *touched, CGPoint point) {
  UIScrollView *list = gList;
  if (!HRPref(HRPrefMarkOpened) || !list || !list.window || touched.window != list.window) return;
  BOOL overlaid = NO;
  UIView *card = HRTappedCard(list, touched, point, &overlaid);
  NSString *postID = card ? HRPostIDForCell(card) : nil;
  if (!postID) return;
  CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
  gTappedPost = postID;
  gTappedTime = now;
  HRLog(@"[tap] %@ tapped%@", HRDescribePost(postID),
        overlaid ? [NSString stringWithFormat:@" (on a %@ over its card)", NSStringFromClass(touched.class)] : @"");
  // Its screen may have started coming up a moment before the tap got here.
  if (gContentScreen && now - gContentScreenTime < 0.3) HRMarkOpenedByTap(gContentScreen);
}

@interface HideReadTapWatcher : UIGestureRecognizer <UIGestureRecognizerDelegate>
@end

@implementation HideReadTapWatcher {
  CGPoint _start;
  CFAbsoluteTime _startTime;
  __weak UIView *_touched;
}

- (instancetype)init {
  if ((self = [super initWithTarget:nil action:NULL])) {
    self.cancelsTouchesInView = NO;
    self.delaysTouchesBegan = NO;
    self.delaysTouchesEnded = NO;
    self.delegate = self;
  }
  return self;
}

- (void)touchesBegan:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
  [super touchesBegan:touches withEvent:event];
  if (touches.count != 1 || event.allTouches.count != 1) {
    self.state = UIGestureRecognizerStateFailed;
    return;
  }
  UITouch *touch = touches.anyObject;
  _start = [touch locationInView:nil];
  _startTime = CFAbsoluteTimeGetCurrent();
  _touched = touch.view;
}

- (void)touchesMoved:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
  [super touchesMoved:touches withEvent:event];
  CGPoint point = [touches.anyObject locationInView:nil];
  if (hypot(point.x - _start.x, point.y - _start.y) > 12) self.state = UIGestureRecognizerStateFailed;
}

- (void)touchesEnded:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
  [super touchesEnded:touches withEvent:event];
  UIView *touched = _touched;
  _touched = nil;
  if (touched && CFAbsoluteTimeGetCurrent() - _startTime < 0.8) HRCardTapped(touched, _start);
  self.state = UIGestureRecognizerStateFailed;
}

- (void)touchesCancelled:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
  [super touchesCancelled:touches withEvent:event];
  _touched = nil;
  self.state = UIGestureRecognizerStateFailed;
}

// It never recognizes, so it can't stand in another gesture's way; this makes sure.
- (BOOL)gestureRecognizer:(UIGestureRecognizer *)gestureRecognizer
    shouldRecognizeSimultaneouslyWithGestureRecognizer:(UIGestureRecognizer *)other {
  return YES;
}

@end

static void HRWatchTaps(UIWindow *window) {
  static char kWatcherKey;
  if (!window || objc_getAssociatedObject(window, &kWatcherKey)) return;
  HideReadTapWatcher *watcher = [HideReadTapWatcher new];
  [window addGestureRecognizer:watcher];
  objc_setAssociatedObject(window, &kWatcherKey, watcher, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

void HRScrollTrackerScreenAppeared(UIViewController *controller) {
  if (!HRIsPostContentScreen(controller)) return;
  NSString *name = NSStringFromClass(object_getClass(controller));
  CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
  gContentScreen = name;
  gContentScreenTime = now;
  if (gTappedPost && now - gTappedTime <= kHRTapToScreen) HRMarkOpenedByTap(name);
}

#pragma mark - Following the feed

// The feed list on screen now, if any. Looks for one at most once a second
// unless `force` is set.
static UIScrollView *HRCurrentList(BOOL force) {
  UIWindow *window = HRAppMainWindow();
  if (!window) return nil;
  HRWatchTaps(window);
  UIScrollView *list = gList;
  if (list && HRVisibleArea(list, window) <= 0) list = nil;
  if (list) return list;

  CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
  if (!force && now - gLastSearch < kHRSearchInterval) return nil;
  gLastSearch = now;
  list = HRFindFeedList(window);
  if (list != gList) {
    gList = list;
    [gSeen removeAllObjects];
    gLastOffset = list.contentOffset.y;
    gLastContentHeight = list.contentSize.height;
    gWatchCounted = 0;
    gStatsOffset = gLastOffset;
    gStatsTime = now;
    if (list) HRLogWatchedList(list);
  }
  return list;
}

// "12 posts hidden", for the posts scrolled past since the last note: once the
// list you're scrolling comes to rest, and not often (see kHRNoteMinPosts).
static void HRNoteHiddenIfResting(UIScrollView *list) {
  if (!gHiddenSinceNote) return;
  if (!HRPref(HRPrefHiddenNote)) {
    gHiddenSinceNote = 0;
    return;
  }
  CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
  if (gHiddenSinceNote < kHRNoteMinPosts || now - gLastNote < kHRNoteMinInterval) return;
  if (!list || list.isTracking || list.isDragging || list.isDecelerating || now - gLastHidden < 0.25) return;
  NSUInteger count = gHiddenSinceNote;
  gHiddenSinceNote = 0;
  gLastNote = now;
  HRLog(@"[scroll] note shown: %lu posts hidden", (unsigned long)count);
  HRShowToast([NSString stringWithFormat:@"%lu posts hidden", (unsigned long)count]);
}

static void HRTick(void) {
  if (UIApplication.sharedApplication.applicationState != UIApplicationStateActive) return;
  UIScrollView *list = HRCurrentList(NO);
  if (!list) return;
  HRWatchList(list);
  HRNoteHiddenIfResting(list);
}

void HRScrollTrackerStart(void) {
  if (gTimer) return;
  if (!gSeen) {
    gSeen = [NSMutableDictionary dictionary];
    gCellCache = [NSMapTable weakToStrongObjectsMapTable];
  }
  gTimer = [NSTimer timerWithTimeInterval:kHRTickInterval
                                  repeats:YES
                                    block:^(NSTimer *timer) {
                                      HRTick();
                                    }];
  gTimer.tolerance = 0.05;
  // Common modes, so it also runs while you're scrolling.
  [NSRunLoop.mainRunLoop addTimer:gTimer forMode:NSRunLoopCommonModes];
}

void HRScrollTrackerStop(void) {
  [gTimer invalidate];
  gTimer = nil;
  [gSeen removeAllObjects];
  gHiddenSinceNote = 0;  // no note about them when you come back
}

NSUInteger HRScrollTrackerScrolledPastCount(void) {
  return gScrolledPastThisRun;
}

void HRScrollTrackerScreenChanged(void) {
  gLastSearch = 0;
}
