#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// YES for requests to Reddit's GraphQL / OAuth API hosts (gql.reddit.com,
/// gql-fed.reddit.com, cf.gql-fed.reddit.com, oauth.reddit.com).
BOOL HRShouldProcessRequest(NSURLRequest *request);

/// YES for reddit.com and its subdomains.
BOOL HRIsRedditHost(NSString *_Nullable host);

/// The GraphQL operation a request runs (from its X-APOLLO-OPERATION-NAME
/// header, its body, or its URL), or nil.
NSString *_Nullable HROperationName(NSURLRequest *request, NSData *_Nullable body);

/// YES if Jax Reddit Eclipse needs to see this operation's response: a feed it may hide
/// read posts in, or a post page or comment load that says a post was opened.
/// Everything else (telemetry, config, account calls...) passes through
/// untouched, and unnamed requests are never read.
BOOL HRShouldWatchOperation(NSString *_Nullable operation);

/// The post whose title is `text`, or one of its comma-separated parts (an
/// on-screen label such as "r/sub, Title, 12 upvotes, ..."), among posts seen in
/// recent feeds, or nil. With `searchInside`, a title anywhere in the text (as
/// whole words) also counts. Titles are only kept while the log, "You Open It"
/// or "You Scroll Past It" is on.
NSString *_Nullable HRPostIDForText(NSString *_Nullable text, BOOL searchInside);

/// The title of a post seen in a feed or a post page since Reddit opened
/// (shortened to 60 characters), or nil. Any thread.
NSString *_Nullable HRPostTitle(NSString *_Nullable postID);

/// Posts seen in feed responses since Reddit opened, read or not. Any thread.
NSUInteger HRFeedPostsSeenCount(void);

/// "t3_abc “Title”" for the log ("t3_abc" when the title isn't known).
NSString *HRDescribePost(NSString *postID);

/// Looks at one API response before the app sees it:
///  1. records read signals (a post's comments being loaded), and
///  2. hides posts already marked as read from feed listings.
/// `body` is the request body (it carries the GraphQL operation name and
/// variables); `requestTime` is when the request was sent
/// (CFAbsoluteTimeGetCurrent). Returns the data to hand to the app: the
/// original object when nothing changed, or on any parsing problem.
NSData *HRProcessResponse(NSURLRequest *request, NSData *_Nullable body, NSData *data,
                          CFAbsoluteTime requestTime);

/// YES for Jax Reddit Eclipse's own requests for a next page (see HRFeedTopUpRequest).
/// They pass through Jax Reddit Eclipse's hook untouched; other tweaks still see them.
BOOL HRIsTopUpRequest(NSURLRequest *request);

/// For a feed page that would be left with fewer than six unread posts once
/// read posts are hidden: the same request for the next page (marked as
/// Jax Reddit Eclipse's own). Nil when the page has enough, there's no next page, or the
/// request can't be rewritten.
NSURLRequest *_Nullable HRFeedTopUpRequest(NSURLRequest *request, NSData *_Nullable body, NSData *page);

/// `page` with `nextPage`'s items appended (repeats left out) and its pageInfo,
/// so paging carries on after both. Nil if either can't be read.
NSData *_Nullable HRMergeFeedPages(NSData *page, NSData *nextPage);

NS_ASSUME_NONNULL_END
