# Jax Reddit Eclipse

A jailbreak tweak for the official Reddit app (`com.reddit.Reddit`) that hides posts you've already read. Its files are `HideRead.dylib` and `HideRead.plist`, named by the Makefile's `TWEAK_NAME`.

- A post you open counts as read. The next time a feed loads (pull to refresh, switch feeds, or scroll to load more), it's gone.
- Works in Home, Popular, subreddits and custom feeds. Search results and user profiles are optional. It never touches your Saved, History, Hidden or voted lists, or the post page itself.
- Optional Apollo-style mode: a post that stays on screen in the feed for a few seconds also counts as read.
- **Tap Hide in the tab bar to hide all your read posts on your Reddit account; touch and hold it for the settings.** With the button off, a two-finger double tap anywhere in Reddit opens the settings instead. A one-time banner says so after the first launch. Settings open in Jax Reddit Eclipse's own window, so they don't depend on how Reddit arranges its screens.

## Build

You need [Theos](https://theos.dev/docs/installation). On a Mac, install Xcode first. Theos' install script works on macOS, Linux and WSL:

```sh
bash -c "$(curl -fsSL https://raw.githubusercontent.com/theos/theos/master/bin/install-theos)"
```

Open a new terminal afterwards so `$THEOS` is set. Then, in this folder:

```sh
make package FINALPACKAGE=1                  # rootless (Dopamine, palera1n rootless, …)
make package FINALPACKAGE=1 ROOTFUL=1        # rootful (checkra1n, unc0ver, palera1n rootful, …)
make package THEOS_PACKAGE_SCHEME=roothide   # roothide Dopamine (needs roothide Theos)
```

The `.deb` lands in `packages/`. If a newer SDK turns a warning into a build error, add `GO_EASY_ON_ME=1`.

`HideRead.plist` has to be readable by everyone (`rw-r--r--`, `chmod 644 HideRead.plist`). The package installs it owned by root with the permissions it has in this folder, and the tweak loader reads it from inside Reddit, which runs as the mobile user. If only its owner can read it, Reddit never loads the tweak, with no error anywhere. On a Mac, `bash build-on-mac.sh` builds both packages, sets that permission first, and afterwards lists the permissions of the tweak's files in each package, stopping if one isn't readable by everyone.

Versions start at 0.0.20b and go up by one each build: 0.0.21b, 0.0.22b, and so on. The package ID is `com.jax.reddit-eclipse` (IDs can't have spaces), and the project folder is `Jax-Reddit-Eclipse` (Theos can't build in a folder whose path has spaces).

Before publishing, change the `Maintainer` and `Author` fields in `control`.

## Install

- **Download the release:** take the `.deb` from [github.com/alienjax/Reddit-Eclipse/releases/tag/v0.0.27b](https://github.com/alienjax/Reddit-Eclipse/releases/tag/v0.0.27b): the file ending in `_iphoneos-arm64.deb` for rootless jailbreaks (Dopamine, palera1n rootless), or `_iphoneos-arm.deb` for rootful ones (unc0ver, checkra1n, palera1n rootful). Download it on the phone, open it in Filza (tap Share on the downloaded file, then Filza), and tap Install. Then quit Reddit from the app switcher and reopen it.
- **From the phone:** copy the `.deb` over (AirDrop, then Save to Files), open it with Sileo, Zebra or Filza, and tap Install. Then quit Reddit from the app switcher and reopen it.
- **Over SSH:** with OpenSSH installed on the phone and both devices on the same Wi-Fi, run `make do THEOS_DEVICE_IP=<phone's IP>`. That builds, installs and relaunches Reddit in one step.

To uninstall, remove Jax Reddit Eclipse in your package manager, or run `sudo apt remove com.jax.reddit-eclipse`.

If Reddit shows no sign of the tweak (no Hide tab, and the two-finger double tap does nothing), look at `/var/jb/Library/MobileSubstrate/DynamicLibraries/` in Filza (`/Library/MobileSubstrate/DynamicLibraries/` on rootful jailbreaks). `HideRead.dylib` and `HideRead.plist` should both be there, and `HideRead.plist` must be `rw-r--r--` (see Build).

## Settings

| Setting | Default | What it does |
|---|---|---|
| Hide Read Posts | On | Master switch. Read tracking continues while it's off. |
| Hide Button in Tab Bar | On | Shows a Hide button in Reddit's tab bar, between Inbox and You. A tap hides all your read posts on your Reddit account; touch and hold it for these settings. With it off, a two-finger double tap anywhere opens them. |
| “Posts Hidden” Note | On | Now and then, once you stop scrolling, a faint note fades in at the top to say how many posts you've scrolled past were hidden. |
| Hide on Reddit Account | On | Posts counted as read are also hidden on your Reddit account, as "Hide post" in a post's ⋯ menu does. See below. |
| Hidden on Your Account | | How many posts Jax Reddit Eclipse has hidden on your account, and what it's doing now: posts waiting, waiting for the app's sign-in, a problem Reddit reported, and whether Reddit confirmed it. |
| Hide All Read Posts Now | | Hides every post in your read history that isn't hidden on your account yet, even with the switch off. Shows progress, and can be stopped. When it's done, a note says how many were hidden and whether Reddit confirms it. A tap on Hide in the tab bar does the same without asking first. |
| Since Reddit Opened | | Posts seen in feeds, counted as read, and how many of those you scrolled past, since Reddit was last opened. |
| You Open It | On | Opening a post counts it as read: its page, or its video, images or link full screen after you tap it. |
| You Scroll Past It | On | A post that has been on screen and then scrolled up out of view counts as read. It stays in the list you're scrolling until the feed reloads. |
| It Stays on Screen | Off | A post visible in the feed for a few seconds counts as read. |
| Search Results / User Profiles | Off | Also hide read posts there. |
| Clear Read History… | | Forget every read post. |
| Diagnostic Log | Off | Records what Jax Reddit Eclipse sees. View and copy it from the settings screen. |

Settings are stored in Reddit's own user defaults (`HR*` keys). Read posts are stored in Reddit's container at `Library/Application Support/HideRead/ReadPosts.plist`, for up to 90 days and 20,000 posts. The posts hidden on your account are recorded next to it in `AccountHidden.plist`, with the same limits. No preference bundle or sandbox workaround is needed.

## How it works

**Filtering happens at the network layer.** `Tweak.x` hooks `-[NSURLSession dataTaskWithRequest:completionHandler:]` (and the upload-task variant) for Reddit's API hosts: any `*.reddit.com` host with a label starting with `gql` or `oauth`, which includes `gql-fed.reddit.com`, `oauth.reddit.com` and `cf.gql-fed.reddit.com`. Some accounts get moved onto that last one, a Cloudflare route. Each response passes through `HRProcessResponse` before the app parses it.

**Read posts are taken out of the feed.** Each feed list loses its read posts, along with the posts Reddit marks as hidden on your account (`isHidden: true`, or a `CellGroup` with no `cells`), which the app would otherwise show as "Post hidden / Undo" rows. The list's `pageInfo` stays as it is, so infinite scroll keeps working.

**Thin pages are topped up.** Reddit's Home feed brings back many posts you've already read, so a page can end up with only a few left. That can be too short to scroll, and Reddit only loads more when you scroll near the end. So a feed page that would be left with fewer than six unread posts gets the next page fetched (the same request with `after` set to the page's `endCursor`) and merged in before the app sees it. That's up to three extra pages, within four seconds. Repeats are left out of the merged list, and paging carries on after the last page fetched. These requests are marked as Jax Reddit Eclipse's own, pass through Jax Reddit Eclipse's hook untouched, and go through every other tweak's hook like the app's own, so a tweak that blocks posts filters them too. Only if every post is still read after that does the last one stay visible, so the feed has something to scroll to.

**Detecting a read is the delicate part.** Reddit preloads a small comment tree (8 comments) for posts that sit on screen for a few seconds, then fetches about 200 when you open one ([r/RedditEng, May 2024](https://www.reddit.com/r/RedditEng/comments/1cwqqtp/instant_comment_loading_on_android_ios/)). A naive "comments were loaded" check would therefore mark posts you only scrolled past. Jax Reddit Eclipse counts a post as **opened** when one of these is true:

1. The post's page loads right after a post screen appears: `PostInfoById` (the post itself), or a `Pdp…` operation such as `PdpCommentsAds`, which names the post in its request.
2. A comment load returns more than 8 comments. As of Reddit 2026.10, preloads ask for 200 comments, the same as a real open, but never get more than 8 back. The page size therefore can't tell them apart; only the count can.
3. A comment load comes right after a post screen appears.
4. You tap the post's card in the feed, and within 1.5 seconds a screen with the post's content comes up: its page, or its video, images or link full screen. This is what counts a video you watch full screen, which never loads comments. The tap is seen by a gesture recognizer on Reddit's main window that never recognizes anything, so every other gesture, button and list gets the touch as if it weren't there; the card is matched to its post the way the scroll tracker matches cards (below). Content screens are matched by view-controller class name (`video`, `player`, `media`, `image`, `browser`, `safari`, …, but never `subreddit`, `profile`, `sheet`, `menu` and the like), in `HRIsPostContentScreen` in `HRScreenTracker.m`.

"Right after" means three things. The request was sent after the screen appeared, or at most half a second before (a page can start loading as you tap). The answer came within 6 seconds. And it's the first load to claim that screen. A preload that was already in flight when you tapped can't take the screen's place. Post screens are matched by view-controller class name. On 2026.10 that's `PDP_Impl.PDPViewController`; the patterns (`postdetail`, `pdp`, …) are in `HRScreenTracker.m`.

Every other comment load counts as a preload. Preloads count as read only when "It Stays on Screen" is on. With the diagnostic log on, `[read]` and `[feed]` lines include post titles, so you can check which posts were counted and hidden.

**Scrolling past a post is seen on screen, not on the network.** `HRScrollTracker.m` hooks nothing. A timer reads the feed list on screen five times a second. It finds the list by looking through Reddit's main window for a vertical collection or table view, outside any post screen, whose cards match known posts. Each card is matched to its post by title, against the titles in the feed responses Jax Reddit Eclipse has read (a card's title cell, not just any "title" field, which could be a recommendation's). It tries the cell's own accessibility label, then the first one inside it ("r/sub, Title, 12 upvotes, …"), then a post id in an accessibility identifier, and then the texts, labels and values inside the card. A title must be the whole text or whole comma-separated parts of it, so a title that's only part of another post's title never matches. A title that more than one post has (a crosspost, a repost, a recurring thread) isn't matched at all: such a card is left alone rather than risk counting the other post. Rows of any height count, since a feed may give a post's title a row of its own. A card that was on screen (at least 40 points, or half of a smaller row) and has since moved above the top of the visible area counts as scrolled past. A card flicked past too fast to be caught on screen once doesn't count. Positions are forgotten on a pull to refresh or a jump back to the top. Removing a card from the list you're scrolling would need Reddit's own list data, and would make the list jump. Now and then, once the list comes to rest, a faint note at the top says how many posts were hidden since the last one ("14 posts hidden"): scrolled past, or counted while still on screen with "It Stays on Screen" on. Opening a post and coming back doesn't start the count again. It waits for at least 10 posts and 20 seconds since the last note. It fades in over about a third of a second, stays about half a second and fades out over half a second, mostly transparent. The "“Posts Hidden” Note" setting turns it off.

**Hiding on your Reddit account.** With "Hide on Reddit Account" on, every post counted as read is also hidden on your Reddit account, as "Hide post" in a post's ⋯ menu does. It goes on your Hidden list, and Reddit leaves it out of your feeds on every device: the website and other apps too. `HRAccountHider.m` does this with Reddit's own `POST /api/hide`, which takes a list of posts:

- **A few at a time.** Posts wait in a queue, kept across launches and capped at 1,000. They go to Reddit in batches of up to 25, once 25 are waiting or 10 seconds after the first one, and never more than one batch every 10 seconds. If Reddit asks for less (too many requests, trouble on its side, no connection), the pause doubles each time, up to half an hour. With fewer than five requests left in Reddit's rate-limit window (its `x-ratelimit-*` headers), it waits for the next one.
- **The app's own sign-in.** It uses the Authorization header of the Reddit app's own requests, picked up as they go out, from requests with or without a completion handler (`Bearer` in any case). It's kept in memory only, never written down or logged, and only ever sent back to Reddit. If Reddit turns it down three times in a row, hiding on your account stops until Reddit is next opened, and the log says why.
- **Checked with Reddit.** `/api/hide` answers OK whether or not it hid anything. So posts are looked up with `GET /api/info`: one after the first batch each time Reddit opens, and the newest one at the end of each "Hide All Read Posts Now". The status in settings says whether Reddit lists it as hidden. A post Reddit doesn't list as hidden comes off the record, so it's sent again.
- **Never twice.** Posts Reddit took are recorded in `AccountHidden.plist` (90 days, 20,000 posts) and not sent again.
- **Hide All Read Posts Now** sends every post in the read history that isn't recorded as hidden yet, whether or not "Hide on Reddit Account" is on. It goes 25 posts every 2 seconds, after any posts just counted, while Reddit is open, and picks up where it left off when you come back. When it's done, a note at the top of the screen says how many were hidden and whether Reddit confirms the newest one is on your Hidden list (naming it), or what went wrong: Reddit turning the sign-in down, no connection, or no sign-in picked up yet. If every read post is recorded as hidden already, Reddit is asked about the newest one, and if it doesn't list it as hidden, the record is cleared and the whole read history is sent again. Posts that were already in the read history before "Hide on Reddit Account" was on are only sent this way.
- **Finishing in the background.** When Reddit leaves the screen with posts still waiting (you tapped Hide and switched to your browser, say), it asks iOS for the usual half a minute of background time and sends them then, 25 every 2 seconds. A note that comes while Reddit is away shows when you're back.
- **What it doesn't do.** Clearing the read history doesn't unhide anything; use your Hidden list for that. Posts already loaded in the feed you're on stay until it reloads, and their ⋯ menu still says "Hide post" until then, as the app doesn't know. To see that it worked, look at "Hidden on Your Account" in settings, or pull the feed down to reload it. On the website, a hidden post's ⋯ menu says "Remove from hidden". Reddit's site can still show hidden posts in a subreddit's feed; that menu is how to tell they're hidden.

The tweak still leaves read posts out of the feeds itself too. That covers posts still waiting to be sent, and any Reddit wouldn't take.

**The Hide button.** It sits in Reddit's tab bar, between Inbox and You. A tap hides every read post on your Reddit account, as "Hide All Read Posts Now" does (above), with a faint note when it starts and a note when it's done that says whether Reddit confirms it. Touching and holding it (0.45 seconds) opens Jax Reddit Eclipse's settings. The hold cancels the button's touch, so it's never also a tap, and other long presses on the way (Reddit's own, iOS's large-content viewer) wait for it. While the button is in the tab bar, the two-finger double tap doesn't even begin. With the button off, or with too many tabs in Reddit for it, the double tap opens the settings instead. The icon is the SF Symbol `eye.slash`. The code is in `HRHideButton.m`.

**How the button goes in.** `HRHideButton.m` works like this:

- **It goes in with the tab bar.** As soon as Reddit's tab bar is on screen, on the main queue's next pass. It never runs inside Reddit's own screen callbacks, and no view is ever made to load early.
- **It's a real tab bar item.** It's added at the end of the tab bar controller's list with UIKit's own setter (Reddit's override, if it has one, isn't involved). So Reddit's tabs keep their places in the list, in case Reddit counts its tabs by position, and iOS lays out five equal slots itself. When Reddit sets its tabs again (`-setViewControllers:animated:` is wrapped), Hide goes straight back in.
- **Hide and You trade slots.** iOS still places every button itself. Jax Reddit Eclipse only translates where iOS puts those two buttons, at the moment it puts them: `-[UITabBarButton setFrame:]` and `-setCenter:` are wrapped and act on those buttons only. So iOS and Jax Reddit Eclipse never disagree about where a button goes, and nothing has to be moved back. Buttons are told apart by UIKit's own link from each item to its button. You's slot is found by Reddit's names for its tabs (`reddit_tab_bar__inbox_button`, `reddit_tab_bar__profile_button`, on the item or its button), then by titles. If the tab bar ever lays itself out more than 30 times without the app getting back to its run loop, Jax Reddit Eclipse stops trading slots for good and Hide stays at the end.
- **Reddit's own tab bar views follow.** Reddit draws its Create button itself, at the middle of a slot in a bar of four tabs. Any such view (slot-sized, in or beside the tab bar, sitting in the middle of a four-tab slot but not on its tab's button) is shifted on screen onto its tab's button. The shift is a transform, which layout never looks at, and it's undone if the view moves back or Hide is taken out.
- **A tap on Hide goes to Hide.** With Hide and You trading slots, a touch could otherwise go by the slot iOS gave each button rather than where it's shown. So touches are matched to the buttons as shown, in four places:
  - Reddit's main window: a touch on Hide as it's shown goes to Hide, whatever would have taken it. A touch on another tab that would have gone to Hide goes to that tab's button. `-hitTest:withEvent:` is wrapped on the window's class, and only touches on the tab bar are affected, so anything covering the bar, like a sheet or a full-screen view, keeps its touches.
  - The two buttons that trade slots take touches where they're shown (`-[UITabBarButton pointInside:withEvent:]`).
  - Tab changes are vetted. No tab change comes of a tap on Hide, whether iOS or Reddit asks for it (`-setSelectedViewController:`, `-setSelectedIndex:`, `-tabBar:didSelectItem:` and the delegate's `-tabBarController:shouldSelectViewController:` are wrapped). If anything asks for Hide's empty tab, the tab actually under the finger opens instead.
  - Jax Reddit Eclipse takes the Hide button's own actions over, so iOS never selects its tab. If the empty tab opens anyway, it switches straight back.
- **At most five tabs.** It's only added when Reddit has four tabs or fewer, since iOS puts a sixth behind "More".
- **There's a safety net.** A flag is up while the tab goes in and for five seconds after, or until Reddit next leaves the foreground. If the flag is still up at the next launch, Reddit froze or crashed then. The Hide button is turned off, and a banner says so. You can turn it back on in settings.


## Status and limitations

- **Not yet run against a live Reddit build.** The code compiles cleanly with Theos' flags (`-Wall -Werror`, Logos `warnings=error`) against the iOS 16.5 SDK. The decision logic was checked against sample responses shaped like Reddit's GraphQL output. Reddit changes its app and schema often, so test on your device first.
- **Where server-driven feed items keep their post ID is inferred.** Jax Reddit Eclipse checks `groupId`, `postId`, `id` and `linkId`, then looks for a single post ID inside `cells`. If nothing is hidden, turn on the Diagnostic Log and look for lines like this:
  `[feed] HomeFeedSdui: 25 items without a single post id, e.g. CellGroup {…}, post ids at: cells[2].foo.id=t3_…`
  That line shows where the ID actually lives. Adjust `HRPostIDForNode` in `Sources/HRResponseProcessor.m` to match.
- **Posts you open depend on the post-screen match.** Only threads with more than 8 comments are recognised without it. The log prints a `[screen] ClassName` line for every screen. If your post screen isn't tagged `<- post screen`, add part of its name to the `matches` list in `HRScreenTracker.m`.
- **The Hide button depends on how Reddit builds its tab bar.** If Reddit freezes or closes just as it goes in, the next launch turns it off and says so. If it ends up at the end of the tab bar, the spacing is off, or a tap does the wrong thing, the `[hide]` and `[tabbar]` log lines say why.
- **Posts disappear on the next feed load, not instantly.** Going back from a post leaves the feed as it was. Pull down to refresh, or scroll on: pages that load later come in already filtered.
- A post that opens without any network request (everything already cached) isn't counted.
- Opening media full screen straight from the feed counts only if its screen's class name looks like a video, image or link viewer. With the diagnostic log on, a `[tap] … tapped` line with no `[read]` line after it means the screen that came up wasn't recognised: add part of its name (from its `[screen]` line) to the `matches` list in `HRIsPostContentScreen`.
- The hook covers completion-handler tasks, the same path RedditFilter relies on. A feed Reddit loads as a streamed response (no completion handler, e.g. with `@defer`) can't be filtered. With the diagnostic log on, such requests show up as `[api] … is streamed`. `-[NSURLSession dataTaskWithRequest:]` is hooked only to note them, and to pick up the app's sign-in from them.

## Reading the diagnostic log

| Prefix | Meaning |
|---|---|
| `[feed]` | A feed response: how many recognised posts it held, how many were hidden, and how many posts Reddit marks as hidden were taken out. |
| `[read]` | A post was marked as read, and why: post page loaded, more comments than a preload, post screen just opened, its card was tapped and its content came up, or stayed on screen. |
| `[tap]` | A post card in the feed was tapped (with "You Open It" on). A `[read] … opened (its card was tapped, then … came up)` line follows if its content came up. |
| `[skip]` | A comment preload or post page load that wasn't counted. |
| `[vars]` | How Reddit asked for a post's page or comments, with IDs blanked out. Logged once per distinct request shape. |
| `[screen]` | A screen appeared. `<- post screen` means it matched the post-screen patterns; `<- a post's video, images or link` means it counts as a post's content after a tap on its card. |
| `[api]` | The first response of each kind: read by Jax Reddit Eclipse, `passed through` untouched, or `streamed` (can't be read). |
| `[account]` | Hiding on your Reddit account: when the app's sign-in was picked up, each batch sent, how many are waiting, and why Reddit turned one down or it's waiting (for the sign-in, or a pause). Whether Reddit lists a hidden post as hidden when checked. "Hide All Read Posts Now" starting (with the newest post in it), stopping and finishing, and each note it put up. Sending in the background after Reddit left the screen. Never the sign-in itself. |
| `[hide]` | The Hide button: when it was added, with Reddit's names for its tabs, and which slot it shows in. Each tap, and how it arrived, and each time it was held down. What a tap on Hide was headed for, if not Hide, and any tab change that was ignored or redirected. Reddit views shifted onto their tabs. Also why Hide stays at the end of the tab bar, or was turned off, if that happens. |
| `[tabbar]` | Once per launch, about 1.5 seconds after the Hide button goes in: each tab (name, title, image, its button and what's in it), then the other views in and beside the tab bar, with where they are on screen. Then the gesture recognizers on the tab bar and the views above it, and which of the methods Jax Reddit Eclipse wraps the classes had of their own. |
| `[scroll]` | The scroll tracker. When it picks up a list: the list's position, insets and size, then its first six cards, each matched to a post or shown with its label or texts. While you scroll: a summary every 1,500 points (cards on screen, matched, counted so far). A list that could be the feed but matched nothing is shown with its cards, at most once a minute. A post counted this way shows as `[read] … scrolled past`. |

## Compatibility

Jax Reddit Eclipse is built to stay out of other tweaks' way:

- **Other tweaks see what Reddit sent.** Jax Reddit Eclipse's network hooks go in last, from the main queue's first pass, after every tweak's constructor has run. A hook installed later wraps the earlier ones, so on every response the other tweaks' handlers run first, on Reddit's original data. A second set of hooks, installed in Jax Reddit Eclipse's constructor, reads any request Reddit makes before then, and passes everything straight on once the outer hooks are in, so no response is read twice. A tweak that blocks posts filters exactly what it would without Jax Reddit Eclipse, and Jax Reddit Eclipse only removes read posts from what that tweak hands on. When Jax Reddit Eclipse does change a response, it re-encodes it without escaping slashes, so URLs stay as Reddit wrote them.
- **Few hooks, always chained.** It hooks `-[NSURLSession dataTaskWithRequest:completionHandler:]`, the upload-task variant and `-[UIViewController viewWillAppear:]`. Each calls the original, so tweaks hooking the same methods still run. It also hooks `-[NSURLSession dataTaskWithRequest:]`, only to pick up the app's sign-in from streamed requests and, with the diagnostic log on, to note them. The Hide button gets a long-press recognizer of its own, and wraps several methods at run time:
  - The tab bar's `-layoutSubviews`.
  - `-[UITabBarButton setFrame:]`, `-setCenter:` and `-pointInside:withEvent:`, which only change anything for the Hide and You buttons.
  - On the tab bar controller: `-setViewControllers:animated:`, `-setSelectedViewController:`, `-setSelectedIndex:` and `-tabBar:didSelectItem:`. They only intervene for Hide's tab or a tap on Hide.
  - The delegate's `-tabBarController:shouldSelectViewController:`.
  - `-hitTest:withEvent:` on Reddit's main window class, which only changes anything for touches on the tab bar.

  Each calls the original otherwise. There are no touch, shake or window hooks, and nothing in Reddit's feed is changed on screen. The scroll tracker adds one gesture recognizer to Reddit's main window that never recognizes anything (it doesn't delay or cancel touches either): it only notes which post card a tap lands on.
- **Its own requests, separately.** Hiding posts on your account sends Reddit's `POST /api/hide` from a URL session of its own, with the app's sign-in. Nothing of Reddit's is changed to do it, and the app's own requests go out exactly as before.
- **Only the responses it needs.** Feeds, post pages and comment loads are read. Telemetry, config and account calls, and anything unnamed, go to the app and other tweaks with their original completion handler. A response is re-encoded only when Jax Reddit Eclipse actually hides a post in it.
- **No takeover of the key window.** Settings open in a window just above Reddit's own (`UIWindowLevelNormal + 1`) that never becomes key. Reddit's and other tweaks' screens keep presenting where they did, and touches outside the sheet pass through.
- **Only Reddit's own window gets the gestures.** The two-finger double tap (which only works while the Hide button is off) goes on the window Reddit's scene delegate owns, installed through `UIWindowDidBecomeKeyNotification`, and so does the recognizer that notes taps on post cards. Windows put up by other tweaks are never touched.
- Can be installed alongside [RedditFilter](https://github.com/level3tjg/RedditFilter). Both wrap the same completion handler, so each sees the response in turn.

## Credits

The network-layer approach and the hosts it filters come from level3tjg's RedditFilter (MIT), as does marking posts `isHidden` / emptying `cells`, which Jax Reddit Eclipse only falls back on for a feed list it can't change. No code was copied.
