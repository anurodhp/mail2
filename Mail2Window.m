/* Mail2Window: the three-pane viewer (see Mail2Window.h). */
#import "Mail2Window.h"
#import "Mail2Compose.h"
#import "Mail2Util.h"
#import "Mail2Outbox.h"
#import "Mail2Snooze.h"
#include <dispatch/dispatch.h>

#define BAR_H 44.0
#define SIDEBAR_W 200.0
#define LIST_W 340.0
#define STATUS_H 22.0
#define LIST_LIMIT 3000

@interface Mail2ToolbarView : NSView
@end
@implementation Mail2ToolbarView
- (void) drawRect: (NSRect)r
{
	NSRect b = [self bounds];
	NSGradient *g = [[[NSGradient alloc] initWithStartingColor: [NSColor colorWithCalibratedWhite: 0.97 alpha: 1]
	                                               endingColor: [NSColor colorWithCalibratedWhite: 0.90 alpha: 1]] autorelease];
	[g drawInRect: b angle: -90];
	[[NSColor colorWithCalibratedWhite: 0.75 alpha: 1] set];
	NSRectFill(NSMakeRect(0, 0, NSWidth(b), 1));
}
@end

/* the sidebar pane: the mailbox table over a status line */
@interface Mail2SidebarPane : NSView
@end
@implementation Mail2SidebarPane
- (void) drawRect: (NSRect)r
{
	[[NSColor colorWithCalibratedRed: 0.93 green: 0.94 blue: 0.96 alpha: 1] set];
	NSRectFill(r);
}
@end

@implementation Mail2Window

static NSButton *
tool_button(NSString *icon, NSString *tip, id target, SEL action, NSRect r)
{
	NSButton *b = [[[NSButton alloc] initWithFrame: r] autorelease];
	[b setImage: Mail2Icon([NSString stringWithFormat: @"tb-%@-normal", icon])];
	[b setImagePosition: NSImageOnly];
	[b setBezelStyle: NSRegularSquareBezelStyle];
	[b setBordered: NO];
	[b setTarget: target];
	[b setAction: action];
	[b setToolTip: tip];
	return b;
}

- (Mail2Table *) makeTable: (id)cell rowHeight: (CGFloat)h sidebar: (BOOL)sb
{
	Mail2Table *t = [[Mail2Table alloc] initWithFrame: NSMakeRect(0, 0, 100, 100)];
	NSTableColumn *c = [[[NSTableColumn alloc] initWithIdentifier: @"main"] autorelease];
	[c setDataCell: cell];
	[c setEditable: NO];
	[c setResizingMask: NSTableColumnAutoresizingMask];
	[t addTableColumn: c];
	[t setHeaderView: nil];
	[t setCornerView: nil];
	[t setRowHeight: h];
	[t setIntercellSpacing: NSMakeSize(0, 0)];
	[t setColumnAutoresizingStyle: NSTableViewUniformColumnAutoresizingStyle];
	[t setAllowsEmptySelection: YES];
	[t setAllowsMultipleSelection: !sb];
	[t setSidebarStyle: sb];
	[t setDataSource: (id)self];
	[t setDelegate: (id)self];
	if (sb)
		[t registerForDraggedTypes: [NSArray arrayWithObject: @"Mail2MessageRows"]];
	return t;
}

static NSScrollView *
scroller_for(NSTableView *t, NSRect r)
{
	NSScrollView *s = [[[NSScrollView alloc] initWithFrame: r] autorelease];
	[s setHasVerticalScroller: YES];
	[s setAutohidesScrollers: YES];
	[s setBorderType: NSNoBorder];
	[s setDocumentView: t];
	[s setAutoresizingMask: NSViewWidthSizable | NSViewHeightSizable];
	[t setFrameSize: NSMakeSize([s contentSize].width, NSHeight([t frame]))];
	[[[t tableColumns] objectAtIndex: 0] setWidth: [s contentSize].width];
	return s;
}

- (id) initWithSessions: (NSArray *)s
{
	if ((self = [super init]) == nil)
		return nil;
	sessions = [s retain];
	sidebarItems = [[NSMutableArray alloc] init];
	buttons = [[NSMutableDictionary alloc] init];

	NSRect fr = NSMakeRect(80, 80, 1120, 700);
	NSRect screen = [[NSScreen mainScreen] visibleFrame];
	if (NSWidth(screen) > 0) {
		fr.size.width = MIN(fr.size.width, NSWidth(screen) - 40);
		fr.size.height = MIN(fr.size.height, NSHeight(screen) - 60);
		fr.origin.x = NSMinX(screen) + (NSWidth(screen) - NSWidth(fr)) / 2;
		fr.origin.y = NSMinY(screen) + (NSHeight(screen) - NSHeight(fr)) / 2;
	}
	window = [[NSWindow alloc] initWithContentRect: fr
	    styleMask: NSTitledWindowMask | NSClosableWindowMask | NSMiniaturizableWindowMask | NSResizableWindowMask
	    backing: NSBackingStoreBuffered defer: NO];
	[window setReleasedWhenClosed: NO];
	[window setTitle: @"Mail2"];
	[window setDelegate: self];
	[window setMinSize: NSMakeSize(760, 400)];
	[window setFrameAutosaveName: @"Mail2Viewer"];
	NSView *cv = [window contentView];
	NSRect b = [cv bounds];

	/* toolbar: Get Mail, Compose | Archive, Delete | Reply, Reply All, Forward | Flag -- Apple Mail's order */
	Mail2ToolbarView *bar = [[[Mail2ToolbarView alloc] initWithFrame: NSMakeRect(0, NSHeight(b) - BAR_H, NSWidth(b), BAR_H)] autorelease];
	[bar setAutoresizingMask: NSViewWidthSizable | NSViewMinYMargin];
	struct { NSString *icon, *tip; SEL sel; CGFloat gap; } tb[] = {
		{ @"getmail", @"Get Mail", @selector(getMail:), 0 },
		{ @"compose", @"New Message", @selector(compose:), 14 },
		{ @"archive", @"Archive", @selector(archive:), 0 },
		{ @"delete", @"Delete", @selector(deleteMessages:), 14 },
		{ @"reply", @"Reply", @selector(reply:), 0 },
		{ @"replyall", @"Reply All", @selector(replyAll:), 0 },
		{ @"forward", @"Forward", @selector(forward:), 14 },
		{ @"flag", @"Flag", @selector(toggleFlag:), 0 },
	};
	CGFloat x = 12;
	unsigned i;
	for (i = 0; i < sizeof(tb) / sizeof(tb[0]); i++) {
		NSButton *btn = tool_button(tb[i].icon, tb[i].tip, self, tb[i].sel, NSMakeRect(x, 7, 36, 30));
		[bar addSubview: btn];
		[buttons setObject: btn forKey: tb[i].icon];
		x += 38 + tb[i].gap;
	}
	searchField = [[NSSearchField alloc] initWithFrame: NSMakeRect(NSWidth(b) - 232, 10, 220, 24)];
	[searchField setAutoresizingMask: NSViewMinXMargin];
	[[searchField cell] setPlaceholderString: @"Search"];
	[[searchField cell] setSendsSearchStringImmediately: NO];
	[searchField setTarget: self];
	[searchField setAction: @selector(search:)];
	[bar addSubview: searchField];
	[cv addSubview: bar];

	NSSplitView *split = [[[NSSplitView alloc] initWithFrame: NSMakeRect(0, 0, NSWidth(b), NSHeight(b) - BAR_H)] autorelease];
	[split setVertical: YES];
	[split setDelegate: self];
	[split setAutoresizingMask: NSViewWidthSizable | NSViewHeightSizable];
	CGFloat h = NSHeight([split bounds]);

	/* pane 1: mailboxes and the status line */
	Mail2SidebarPane *sp = [[[Mail2SidebarPane alloc] initWithFrame: NSMakeRect(0, 0, SIDEBAR_W, h)] autorelease];
	sidebarCell = [[Mail2SidebarCell alloc] initTextCell: @""];
	sidebar = [self makeTable: sidebarCell rowHeight: 26 sidebar: YES];
	NSScrollView *ss = scroller_for(sidebar, NSMakeRect(0, STATUS_H, SIDEBAR_W, h - STATUS_H));
	sidebarScroll = [ss retain];
	/* Undo Send: over the status line while a message waits its few seconds */
	undoBar = [[NSView alloc] initWithFrame: NSMakeRect(0, STATUS_H, SIDEBAR_W, 32)];
	[undoBar setAutoresizingMask: NSViewWidthSizable | NSViewMaxYMargin];
	undoLabel = [[NSTextField alloc] initWithFrame: NSMakeRect(10, 7, SIDEBAR_W - 90, 18)];
	[undoLabel setEditable: NO];
	[undoLabel setSelectable: NO];
	[undoLabel setBezeled: NO];
	[undoLabel setDrawsBackground: NO];
	[undoLabel setFont: [NSFont systemFontOfSize: 11]];
	[undoLabel setStringValue: @"Sending…"];
	[undoBar addSubview: undoLabel];
	NSButton *ub = [[[NSButton alloc] initWithFrame: NSMakeRect(SIDEBAR_W - 76, 3, 68, 26)] autorelease];
	[ub setTitle: @"Undo"];
	[ub setBezelStyle: NSRoundedBezelStyle];
	[ub setTarget: self];
	[ub setAction: @selector(undoSend:)];
	[ub setAutoresizingMask: NSViewMinXMargin];
	[undoBar addSubview: ub];
	[undoBar setHidden: YES];
	[ss setDrawsBackground: NO];
	[sp addSubview: ss];
	statusField = [[NSTextField alloc] initWithFrame: NSMakeRect(10, 2, SIDEBAR_W - 16, STATUS_H - 4)];
	[statusField setEditable: NO];
	[statusField setSelectable: NO];
	[statusField setBezeled: NO];
	[statusField setDrawsBackground: NO];
	[statusField setFont: [NSFont systemFontOfSize: 11]];
	[statusField setTextColor: [NSColor colorWithCalibratedWhite: 0.40 alpha: 1]];
	[statusField setAutoresizingMask: NSViewWidthSizable | NSViewMaxYMargin];
	[sp addSubview: statusField];
	[sp addSubview: undoBar];

	/* pane 2: messages */
	messageCell = [[Mail2MessageCell alloc] initTextCell: @""];
	list = [self makeTable: messageCell rowHeight: 62 sidebar: NO];
	[list setBackgroundColor: [NSColor whiteColor]];
	[list setTarget: self];
	[list setDoubleAction: @selector(listDoubleClicked:)];
	childRows = [[NSMutableSet alloc] init];
	stickyRows = [[NSMutableSet alloc] init];
	NSScrollView *ls = scroller_for(list, NSMakeRect(0, 0, LIST_W, h));

	/* pane 3: the message */
	messageView = [[Mail2MessageView alloc] initWithFrame: NSMakeRect(0, 0, NSWidth(b) - SIDEBAR_W - LIST_W - 2, h)];

	[split addSubview: sp];
	[split addSubview: ls];
	[split addSubview: messageView];
	[split adjustSubviews];
	[self layoutSplit: split keepFirst: YES];
	[cv addSubview: split];

	NSNotificationCenter *nc = [NSNotificationCenter defaultCenter];
	[nc addObserver: self selector: @selector(mailboxesChanged:) name: Mail2MailboxesChanged object: nil];
	[nc addObserver: self selector: @selector(messagesChanged:) name: Mail2MessagesChanged object: nil];
	[nc addObserver: self selector: @selector(statusChanged:) name: Mail2StatusChanged object: nil];
	[nc addObserver: self selector: @selector(outboxChanged:) name: Mail2OutboxChanged object: nil];
	[nc addObserver: self selector: @selector(laterChanged:) name: Mail2LaterChanged object: nil];

	[self reloadSidebar];
	[self updateButtons];
	[window makeKeyAndOrderFront: nil];
	[window makeFirstResponder: list];
	return self;
}

- (void) dealloc
{
	[NSObject cancelPreviousPerformRequestsWithTarget: self];
	[[NSNotificationCenter defaultCenter] removeObserver: self];
	[window release]; [sessions release]; [sidebarItems release]; [sidebar release]; [list release];
	[sidebarCell release]; [messageCell release]; [messageView release]; [statusField release]; [buttons release];
	[current release]; [messages release]; [parsed release];
	[searchField release]; [searchText release]; [serverHits release]; [expanded release]; [childRows release];
	[stickyRows release];
	[undo release]; [undoBar release]; [undoLabel release]; [sidebarScroll release];
	[super dealloc];
}

- (NSWindow *) window { return window; }

- (void) setSessions: (NSArray *)s
{
	ASSIGN(sessions, s);
	[self reloadSidebar];
}

/* ---- split view: fixed sidebar and list widths ---- */

- (void) layoutSplit: (NSSplitView *)sv keepFirst: (BOOL)keep
{
	NSArray *v = [sv subviews];
	if ([v count] != 3)
		return;
	NSRect b = [sv bounds];
	CGFloat d = [sv dividerThickness];
	CGFloat w0 = NSWidth([[v objectAtIndex: 0] frame]), w1 = NSWidth([[v objectAtIndex: 1] frame]);
	if (keep) {
		w0 = SIDEBAR_W;
		w1 = LIST_W;
	}
	w0 = MAX(140, MIN(w0, 320));
	w1 = MAX(220, MIN(w1, NSWidth(b) - w0 - 2 * d - 240));
	CGFloat w2 = MAX(0, NSWidth(b) - w0 - w1 - 2 * d);
	[[v objectAtIndex: 0] setFrame: NSMakeRect(0, 0, w0, NSHeight(b))];
	[[v objectAtIndex: 1] setFrame: NSMakeRect(w0 + d, 0, w1, NSHeight(b))];
	[[v objectAtIndex: 2] setFrame: NSMakeRect(w0 + w1 + 2 * d, 0, w2, NSHeight(b))];
}

- (void) splitView: (NSSplitView *)sv resizeSubviewsWithOldSize: (NSSize)old
{
	[self layoutSplit: sv keepFirst: NO];
}

- (CGFloat) splitView: (NSSplitView *)sv constrainMinCoordinate: (CGFloat)p ofSubviewAt: (NSInteger)i
{
	return i == 0 ? 140 : NSMaxX([[[sv subviews] objectAtIndex: 0] frame]) + 220;
}

- (CGFloat) splitView: (NSSplitView *)sv constrainMaxCoordinate: (CGFloat)p ofSubviewAt: (NSInteger)i
{
	return i == 0 ? 320 : NSWidth([sv bounds]) - 240;
}

/* ---- data ---- */

- (Mail2Session *) sessionForAccount: (NSString *)ident
{
	NSEnumerator *e = [sessions objectEnumerator];
	Mail2Session *s;
	while ((s = [e nextObject]) != nil)
		if ([[[s account] identifier] isEqualToString: ident])
			return s;
	return nil;
}

/* All Inboxes or Flagged: messages of several mailboxes and accounts */
- (BOOL) showingAllInboxes
{
	return current != nil && [current isVirtual];
}

/* the account of the mailbox shown; in All Inboxes, of the selected message (else the first account) */
- (Mail2Session *) currentSession
{
	if ([self showingAllInboxes]) {
		Mail2MessageInfo *m = [[self selectedMessages] count] ? [[self selectedMessages] objectAtIndex: 0] : nil;
		Mail2Session *s = m ? [self sessionForMessage: m] : nil;
		return s ? s : ([sessions count] ? [sessions objectAtIndex: 0] : nil);
	}
	return current ? [self sessionForAccount: [current account]] : nil;
}

- (Mail2Session *) sessionForMessage: (Mail2MessageInfo *)m
{
	Mail2Mailbox *mb = [[Mail2Store sharedStore] mailboxWithID: [m mbid]];
	return mb ? [self sessionForAccount: [mb account]] : nil;
}

/* runs the action once per account with that account's messages (All Inboxes mixes them) */
- (void) eachSession: (NSArray *)msgs do: (void (^)(Mail2Session *s, NSArray *mine))action
{
	NSMutableDictionary *by = [NSMutableDictionary dictionary];
	NSEnumerator *e = [msgs objectEnumerator];
	Mail2MessageInfo *m;
	while ((m = [e nextObject]) != nil) {
		Mail2Session *s = [self sessionForMessage: m];
		if (s == nil)
			continue;
		NSValue *k = [NSValue valueWithNonretainedObject: s];
		NSMutableArray *a = [by objectForKey: k];
		if (a == nil)
			[by setObject: (a = [NSMutableArray array]) forKey: k];
		[a addObject: m];
	}
	NSEnumerator *ke = [by keyEnumerator];
	NSValue *k;
	while ((k = [ke nextObject]) != nil)
		action([k nonretainedObjectValue], [by objectForKey: k]);
}

- (void) reloadSidebar
{
	NSEnumerator *e = [sessions objectEnumerator];
	Mail2Session *s;
	[sidebarItems removeAllObjects];
	if ([sessions count] > 1)
		[sidebarItems addObject: [Mail2Mailbox allInboxes]];
	/* Unread, while there is something unread (or it is shown) */
	if ([sessions count] > 0 && ([[Mail2Store sharedStore] unreadCount] > 0 || [current mbid] == Mail2UnreadID))
		[sidebarItems addObject: [Mail2Mailbox unreadSmart]];
	/* Follow Up, while a reminder is due */
	NSUInteger due = [[[Mail2Later shared] dueFollowUps] count];
	if (due > 0 || [current mbid] == Mail2FollowUpID)
		[sidebarItems addObject: [Mail2Mailbox followUp: (int)due]];
	/* the Outbox, while something waits to go */
	NSUInteger waiting = [[[Mail2Outbox shared] items] count];
	if (waiting > 0 || [current mbid] == Mail2OutboxID)
		[sidebarItems addObject: [Mail2Mailbox outbox: (int)waiting]];
	/* Flagged, while there is something flagged (or it is the mailbox shown) */
	Mail2Mailbox *fl = [Mail2Mailbox flagged];
	if ([sessions count] > 0 && ([fl unread] > 0 || [current mbid] == Mail2FlaggedID))
		[sidebarItems addObject: fl];
	/* saved searches */
	NSArray *saved = [[NSUserDefaults standardUserDefaults] arrayForKey: @"Mail2SavedSearches"];
	NSUInteger si;
	for (si = 0; si < [saved count] && [sessions count] > 0; si++) {
		NSDictionary *d = [saved objectAtIndex: si];
		if ([d isKindOfClass: [NSDictionary class]] && [[d objectForKey: @"Query"] length])
			[sidebarItems addObject: [Mail2Mailbox savedSearch: [d objectForKey: @"Name"] query: [d objectForKey: @"Query"] index: (int)si]];
	}
	while ((s = [e nextObject]) != nil) {
		NSArray *boxes = [[Mail2Store sharedStore] mailboxesForAccount: [[s account] identifier]];
		[sidebarItems addObject: [[s account] email]];
		[sidebarItems addObjectsFromArray: boxes];
	}
	[sidebar reloadData];
	/* keep (or make) the selection */
	NSInteger sel = -1, first = -1;
	NSUInteger i;
	for (i = 0; i < [sidebarItems count]; i++) {
		id it = [sidebarItems objectAtIndex: i];
		if (![it isKindOfClass: [Mail2Mailbox class]])
			continue;
		if (current && [it mbid] == [current mbid])
			sel = i;
		if (first < 0 && ([[it special] isEqualToString: @"inbox"] || [[it special] isEqualToString: @"allinboxes"]))
			first = i;
	}
	syncingSelection = YES;
	if (sel >= 0) {
		ASSIGN(current, [sidebarItems objectAtIndex: sel]);	/* fresh counts */
		[sidebar selectRowIndexes: [NSIndexSet indexSetWithIndex: sel] byExtendingSelection: NO];
	} else if (first >= 0) {	/* nothing chosen yet, or the mailbox shown is gone (its account removed) */
		DESTROY(current);
		[sidebar selectRowIndexes: [NSIndexSet indexSetWithIndex: first] byExtendingSelection: NO];
		syncingSelection = NO;
		[self selectMailbox: [sidebarItems objectAtIndex: first]];
	}
	syncingSelection = NO;
	[self updateTitle];
}

- (void) updateTitle
{
	if (current == nil) {
		[window setTitle: @"Mail2"];
		return;
	}
	if (searchText != nil) {
		[window setTitle: [NSString stringWithFormat: @"%@ — %lu found for “%@”", [current displayName],
		    (unsigned long)[messages count], searchText]];
		return;
	}
	int unread = [[Mail2Store sharedStore] unreadInMailbox: [current mbid]];
	[window setTitle: unread > 0 ? [NSString stringWithFormat: @"%@ (%d unread)", [current displayName], unread]
	                             : [NSString stringWithFormat: @"%@ (%lu messages)", [current displayName], (unsigned long)[messages count]]];
}

- (NSArray *) selectedMessages
{
	NSMutableArray *r = [NSMutableArray array];
	NSIndexSet *rows = [list selectedRowIndexes];
	NSUInteger i;
	for (i = [rows firstIndex]; i != NSNotFound; i = [rows indexGreaterThanIndex: i])
		if (i < [messages count])
			[r addObject: [messages objectAtIndex: i]];
	return r;
}

- (Mail2MessageInfo *) selectedMessage
{
	NSArray *s = [self selectedMessages];
	return [s count] == 1 ? [s objectAtIndex: 0] : nil;
}

+ (BOOL) organizesByConversation
{
	NSUserDefaults *d = [NSUserDefaults standardUserDefaults];
	return [d objectForKey: @"Mail2Conversations"] == nil || [d boolForKey: @"Mail2Conversations"];
}

- (BOOL) showsConversations
{
	return searchText == nil && [Mail2Window organizesByConversation] && [current mbid] != Mail2UnreadID &&
	    [current mbid] != Mail2FollowUpID &&
	    [current mbid] > Mail2SavedSearchBase;
}

/* the rows: search results; or the newest message of each conversation, with the opened one's other messages under
 * it; or every message */
- (NSArray *) rowsForCurrent
{
	Mail2Store *store = [Mail2Store sharedStore];
	[childRows removeAllObjects];
	if (current == nil)
		return [NSArray array];
	if ([current mbid] == Mail2OutboxID)
		return [self outboxRows];
	if ([current mbid] == Mail2FollowUpID)
		return [store messagesWithMessageIDs: [[Mail2Later shared] dueFollowUps]];
	if ([current mbid] <= Mail2SavedSearchBase) {	/* a saved search, narrowed by the search field */
		NSString *q = searchText ? [NSString stringWithFormat: @"%@ %@", [current name], searchText] : [current name];
		return [store searchMailbox: Mail2EverywhereID text: q alsoUids: nil limit: LIST_LIMIT];
	}
	if ([current mbid] == Mail2UnreadID && searchText == nil) {
		/* what was read here stays until the mailbox is left, as in Apple Mail */
		NSMutableArray *r = [NSMutableArray arrayWithArray: [store messagesInMailbox: Mail2UnreadID limit: LIST_LIMIT]];
		NSMutableSet *have = [NSMutableSet set];
		NSEnumerator *ue = [r objectEnumerator];
		Mail2MessageInfo *um;
		while ((um = [ue nextObject]) != nil)
			[have addObject: [NSNumber numberWithLongLong: [um rowid]]];
		ue = [[stickyRows allObjects] objectEnumerator];
		NSNumber *rid;
		while ((rid = (NSNumber *)[ue nextObject]) != nil)
			if (![have containsObject: rid]) {
				Mail2MessageInfo *sm = [store messageWithRowID: [rid longLongValue]];
				if (sm != nil && ([sm flags] & Mail2FlagDeleted) == 0)
					[r addObject: sm];
			}
		[r sortUsingComparator: ^NSComparisonResult(id a, id b) { return [[b date] compare: [a date]]; }];
		ue = [r objectEnumerator];
		while ((um = [ue nextObject]) != nil)
			[stickyRows addObject: [NSNumber numberWithLongLong: [um rowid]]];
		return r;
	}
	if (searchText != nil)
		return [store searchMailbox: [current mbid] text: searchText alsoUids: serverHits limit: LIST_LIMIT];
	if (![self showsConversations])
		return [store messagesInMailbox: [current mbid] limit: LIST_LIMIT];
	NSArray *heads = [store conversationsInMailbox: [current mbid] limit: LIST_LIMIT];
	if (expanded == nil)
		return heads;
	NSMutableArray *rows = [NSMutableArray arrayWithCapacity: [heads count] + 8];
	NSEnumerator *e = [heads objectEnumerator];
	Mail2MessageInfo *h;
	while ((h = [e nextObject]) != nil) {
		[rows addObject: h];
		if ([h threadCount] > 1 && [[h thread] isEqualToString: expanded]) {
			NSEnumerator *ce = [[store messagesInConversation: expanded mailbox: [current mbid]] objectEnumerator];
			Mail2MessageInfo *c;
			while ((c = [ce nextObject]) != nil) {
				if ([c rowid] == [h rowid])
					continue;
				[rows addObject: c];
				[childRows addObject: [NSNumber numberWithLongLong: [c rowid]]];
			}
		}
	}
	return rows;
}

/* reloads the list from the index, keeping the selection by row id */
- (void) reloadMessages
{
	NSMutableSet *keep = [NSMutableSet set];
	NSEnumerator *e = [[self selectedMessages] objectEnumerator];
	Mail2MessageInfo *m;
	while ((m = [e nextObject]) != nil)
		[keep addObject: [NSNumber numberWithLongLong: [m rowid]]];
	ASSIGN(messages, [self rowsForCurrent]);
	[list reloadData];
	NSMutableIndexSet *rows = [NSMutableIndexSet indexSet];
	NSUInteger i;
	for (i = 0; i < [messages count]; i++)
		if ([keep containsObject: [NSNumber numberWithLongLong: [[messages objectAtIndex: i] rowid]]])
			[rows addIndex: i];
	syncingSelection = YES;
	[list selectRowIndexes: rows byExtendingSelection: NO];
	syncingSelection = NO;
	/* the shown message vanished (moved, deleted on another device) */
	if ([messageView message] != nil && [rows count] == 0)
		[self showSelection];
	[self updateTitle];
	[self updateButtons];
}

/* opens the conversation of the selected row, and closes the one open when the selection leaves it */
- (BOOL) updateExpansion
{
	NSArray *sel = [self selectedMessages];
	NSString *want = expanded;
	if (![self showsConversations])
		return NO;
	if ([sel count] == 1) {
		Mail2MessageInfo *m = [sel objectAtIndex: 0];
		BOOL isChild = [childRows containsObject: [NSNumber numberWithLongLong: [m rowid]]];
		if (!isChild)
			want = [m threadCount] > 1 ? [m thread] : nil;
	} else if ([sel count] == 0)
		want = nil;
	if (want == expanded || [want isEqualToString: expanded])
		return NO;
	ASSIGN(expanded, want);
	[self reloadMessages];
	return YES;
}

/* the messages an action applies to: a closed conversation's row stands for all its messages */
- (NSArray *) actionMessages
{
	NSMutableArray *r = [NSMutableArray array];
	NSEnumerator *e = [[self selectedMessages] objectEnumerator];
	Mail2MessageInfo *m;
	while ((m = [e nextObject]) != nil) {
		if ([self showsConversations] && [m threadCount] > 1 && ![[m thread] isEqualToString: expanded])
			[r addObjectsFromArray: [[Mail2Store sharedStore] messagesInConversation: [m thread] mailbox: [m mbid]]];
		else
			[r addObject: m];
	}
	return r;
}

- (void) selectMailbox: (Mail2Mailbox *)m
{
	if (current != nil && m != nil && [current mbid] == [m mbid])
		return;
	ASSIGN(current, m);
	DESTROY(expanded);
	[stickyRows removeAllObjects];
	if (searchText != nil) {	/* a search is of one mailbox */
		DESTROY(searchText);
		DESTROY(serverHits);
		[searchField setStringValue: @""];
	}
	loadingOlder = NO;
	[list deselectAll: nil];
	DESTROY(messages);
	[self reloadMessages];
	[list scrollRowToVisible: 0];
	[self showSelection];
	if ([self showingAllInboxes]) {
		NSEnumerator *e = [sessions objectEnumerator];
		Mail2Session *ss;
		while ((ss = [e nextObject]) != nil)
			[ss checkInboxAnd: nil];
	} else if (m != nil && [m selectable])
		[[self currentSession] syncMailbox: m];
}

/* ---- notifications ---- */

- (void) mailboxesChanged: (NSNotification *)n
{
	[self reloadSidebar];
}

- (void) messagesChanged: (NSNotification *)n
{
	long long mbid = [[[n userInfo] objectForKey: @"Mailbox"] longLongValue];
	if (current != nil && (mbid == [current mbid] || [current mbid] == Mail2FlaggedID || [current mbid] == Mail2UnreadID ||
	    [current mbid] <= Mail2SavedSearchBase ||
	    ([current mbid] == Mail2AllInboxesID && [[[[Mail2Store sharedStore] mailboxWithID: mbid] special] isEqualToString: @"inbox"])))
		[self reloadMessages];
	/* Flagged comes and goes with the flagged messages */
	BOOL listed = NO;
	NSUInteger j;
	for (j = 0; j < [sidebarItems count]; j++)
		if ([[sidebarItems objectAtIndex: j] isKindOfClass: [Mail2Mailbox class]] && [[sidebarItems objectAtIndex: j] mbid] == Mail2FlaggedID)
			listed = YES;
	BOOL unreadListed = NO;
	for (j = 0; j < [sidebarItems count]; j++)
		if ([[sidebarItems objectAtIndex: j] isKindOfClass: [Mail2Mailbox class]] && [[sidebarItems objectAtIndex: j] mbid] == Mail2UnreadID)
			unreadListed = YES;
	if (listed != ([[Mail2Store sharedStore] flaggedCount] > 0 || [current mbid] == Mail2FlaggedID) ||
	    unreadListed != ([[Mail2Store sharedStore] unreadCount] > 0 || [current mbid] == Mail2UnreadID))
		[self reloadSidebar];
	/* the unread counts */
	NSUInteger i;
	for (i = 0; i < [sidebarItems count]; i++) {
		id it = [sidebarItems objectAtIndex: i];
		if ([it isKindOfClass: [Mail2Mailbox class]] && ([it mbid] == mbid || [it isVirtual])) {
			((Mail2Mailbox *)it)->unread = [[Mail2Store sharedStore] unreadInMailbox: [it mbid]];
			[sidebar setNeedsDisplayInRect: [sidebar rectOfRow: i]];
		}
	}
}

- (void) statusChanged: (NSNotification *)n
{
	NSEnumerator *e = [sessions objectEnumerator];
	Mail2Session *s;
	NSString *st = nil, *err = nil;
	while ((s = [e nextObject]) != nil) {
		if ([s status] && st == nil)
			st = [s status];
		if ([s lastError] && err == nil)
			err = [s lastError];
	}
	if (st != nil) {
		[statusField setTextColor: [NSColor colorWithCalibratedWhite: 0.40 alpha: 1]];
		[statusField setStringValue: st];
		[statusField setToolTip: nil];
	} else if (err != nil) {
		[statusField setTextColor: [NSColor colorWithCalibratedRed: 0.75 green: 0.1 blue: 0.1 alpha: 1]];
		[statusField setStringValue: err];
		[statusField setToolTip: err];
	} else {
		[statusField setStringValue: @""];
		[statusField setToolTip: nil];
	}
}

/* ---- table data ---- */

- (NSInteger) numberOfRowsInTableView: (NSTableView *)t
{
	return t == sidebar ? (NSInteger)[sidebarItems count] : (NSInteger)[messages count];
}

- (id) tableView: (NSTableView *)t objectValueForTableColumn: (NSTableColumn *)c row: (NSInteger)r
{
	return nil;	/* the cells draw their items, set in willDisplayCell */
}

- (void) tableView: (NSTableView *)t willDisplayCell: (id)cell forTableColumn: (NSTableColumn *)c row: (NSInteger)r
{
	if (t == sidebar && r < (NSInteger)[sidebarItems count])
		[(Mail2SidebarCell *)cell setItem: [sidebarItems objectAtIndex: r] selected: [t isRowSelected: r]];
	else if (t == list && r < (NSInteger)[messages count]) {
		Mail2MessageInfo *m = [messages objectAtIndex: r];
		BOOL child = [childRows containsObject: [NSNumber numberWithLongLong: [m rowid]]];
		[(Mail2MessageCell *)cell setMessage: m selected: [t isRowSelected: r] child: child
		    count: [self showsConversations] && !child ? [m threadCount] : 1];
		/* the end of the list is in view: fetch what came before the first sync's 30 days */
		if (r == (NSInteger)[messages count] - 1 && searchText == nil)
			[self performSelector: @selector(loadOlderIfNeeded) withObject: nil afterDelay: 0];
	}
}

- (void) loadOlderIfNeeded
{
	Mail2Session *s = [self currentSession];
	if (loadingOlder || current == nil || [self showingAllInboxes] || searchText != nil || ![s hasOlderMessagesIn: current] || [s isBusy])
		return;
	[self getOlderMessages: nil];
}

- (void) getOlderMessages: (id)sender
{
	Mail2Session *s = [self currentSession];
	if (loadingOlder || current == nil || [self showingAllInboxes] || ![s hasOlderMessagesIn: current])
		return;
	loadingOlder = YES;
	long long mbid = [current mbid];
	[s loadOlderMessagesIn: current count: 100 completion: ^(int added) {
		if (current != nil && [current mbid] == mbid)
			loadingOlder = NO;
	}];
}

/* ---- search ---- */

- (void) focusSearch: (id)sender
{
	[window makeKeyAndOrderFront: nil];
	[window makeFirstResponder: searchField];
}

/* GNUstep's search field sends its action at every keystroke: the list follows at once (the index is quick), the
 * server is asked once typing pauses */
- (void) search: (id)sender
{
	NSString *q = [[searchField stringValue] stringByTrimmingCharactersInSet: [NSCharacterSet whitespaceAndNewlineCharacterSet]];
	searchGeneration++;
	[NSObject cancelPreviousPerformRequestsWithTarget: self selector: @selector(searchServer) object: nil];
	if ([q length] == 0 || current == nil) {
		DESTROY(searchText);
		DESTROY(serverHits);
		[self reloadMessages];
		[self statusChanged: nil];
		return;
	}
	if (![q isEqualToString: searchText])
		DESTROY(serverHits);
	ASSIGN(searchText, q);
	DESTROY(expanded);
	[self reloadMessages];
	[list scrollRowToVisible: 0];
	[self performSelector: @selector(searchServer) withObject: nil afterDelay: 0.8];
}

/* the server's matches, which also finds mail older than what was synced */
- (void) searchServer
{
	if (searchText == nil || current == nil || [self showingAllInboxes])	/* All Inboxes: what is here */
		return;
	unsigned gen = searchGeneration;
	NSString *q = [[searchText copy] autorelease];
	[statusField setStringValue: @"Searching the server…"];
	[[self currentSession] searchServer: q inMailbox: current completion: ^(NSArray *uids, NSString *err) {
		if (gen != searchGeneration)
			return;
		[self statusChanged: nil];
		if (uids != nil) {
			ASSIGN(serverHits, uids);
			[self reloadMessages];
		} else if (err != nil)
			[statusField setStringValue: err];
	}];
}

/* ---- drafts ---- */

- (void) listDoubleClicked: (id)sender
{
	if ([list clickedRow] >= 0)
		[self editDraft: sender];
}

- (void) tableReturnKey: (NSTableView *)t
{
	if (t == list)
		[self editDraft: t];
}

- (void) editDraft: (id)sender
{
	Mail2MessageInfo *m = [self selectedMessage];
	if ([m outboxId]) {	/* back out of the Outbox, into a compose window */
		NSDictionary *back = [[Mail2Outbox shared] takeBack: [m outboxId]];
		if (back != nil)
			[Mail2Compose reopenOutgoing: back sessions: sessions];
		return;
	}
	if (m == nil || !([m isDraft] || [[current special] isEqualToString: @"drafts"]))
		return;
	if (parsed == nil || [[messageView message] rowid] != [m rowid])
		return;	/* still downloading: the next try works */
	[Mail2Compose editDraft: m parsed: parsed session: [self sessionForMessage: m] sessions: sessions];
}

- (BOOL) tableView: (NSTableView *)t shouldSelectRow: (NSInteger)r
{
	if (t != sidebar)
		return YES;
	id it = r < (NSInteger)[sidebarItems count] ? [sidebarItems objectAtIndex: r] : nil;
	return [it isKindOfClass: [Mail2Mailbox class]] && [it selectable];
}

- (void) tableViewSelectionDidChange: (NSNotification *)n
{
	if (syncingSelection)
		return;
	if ([n object] == sidebar) {
		NSInteger r = [sidebar selectedRow];
		if (r >= 0 && r < (NSInteger)[sidebarItems count])
			[self selectMailbox: [sidebarItems objectAtIndex: r]];
	} else if ([n object] == list) {
		[self updateExpansion];
		[self showSelection];
		[self updateButtons];
	}
}

- (void) tableDeleteKey: (NSTableView *)t
{
	if (t == list)
		[self deleteMessages: t];
}

/* ---- showing a message ---- */

- (void) display: (Mail2MessageInfo *)m path: (NSString *)path generation: (unsigned)gen
{
	[m retain];
	[path retain];
	dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
		NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];
		NSData *raw = [NSData dataWithContentsOfFile: path];
		NSUserDefaults *ud = [NSUserDefaults standardUserDefaults];
		/* HTML in a web view when Florence's WebKit is installed (Mail2ShowHTML, default YES), else the plain part
		 * (Mail2PreferPlainText, default YES) or the HTML as text */
		BOOL web = ([ud objectForKey: @"Mail2ShowHTML"] == nil || [ud boolForKey: @"Mail2ShowHTML"]) && Mail2WebViewInstalled();
		BOOL plain = !web && (![ud objectForKey: @"Mail2PreferPlainText"] || [ud boolForKey: @"Mail2PreferPlainText"]);
		Mail2ParsedMessage *p = [[Mail2ParsedMessage parseData: raw preferPlainText: plain] retain];
		Mail2RunOnMain(^{
			if (Mail2Debug())
				NSLog(@"Mail2: parsed uid %u: %lu characters, %s", [m uid], (unsigned long)[[p body] length], gen == showGeneration ? "shown" : "stale");
			if (gen == showGeneration) {
				ASSIGN(parsed, p);
				if (p != nil) {
					[messageView showMessage: m body: [p body] attachments: [p attachments] html: [p htmlSource]
					    inlineParts: [p inlineParts]];
					[messageView setParsed: p];
				}
				else
					[messageView showMessage: m body: @"This message could not be read." attachments: nil];
				[self updateButtons];
			}
			[p release];
			[m release];
			[path release];
		});
		[pool release];
	});
}

- (void) showSelection
{
	NSArray *sel = [self selectedMessages];
	showGeneration++;
	DESTROY(parsed);
	if ([sel count] != 1) {
		[messageView showNothing: [sel count] > 1 ? [NSString stringWithFormat: @"%lu messages selected", (unsigned long)[sel count]]
		                                          : @"No Message Selected"];
		return;
	}
	Mail2MessageInfo *m = [sel objectAtIndex: 0];
	if ([m outboxId]) {	/* waiting in the Outbox: its own file */
		Mail2ParsedMessage *op = [Mail2ParsedMessage parseData: [[Mail2Outbox shared] messageFor: [m outboxId]] preferPlainText: NO];
		ASSIGN(parsed, op);
		[messageView showMessage: m body: [op body] attachments: [op attachments] html: [op htmlSource] inlineParts: [op inlineParts]];
		[self updateButtons];
		return;
	}
	/* a closed conversation's row: all of it, one after the other */
	if ([self showsConversations] && [m threadCount] > 1 && ![childRows containsObject: [NSNumber numberWithLongLong: [m rowid]]]) {
		[self showConversationOf: m generation: showGeneration];
		return;
	}
	Mail2Session *s = [self sessionForMessage: m];
	if (Mail2Debug())
		NSLog(@"Mail2: show message uid %u (%@)", [m uid], [m file] ? @"downloaded" : @"to download");
	unsigned gen = showGeneration;
	NSString *path = [[Mail2Store sharedStore] pathForMessage: m];
	if (path != nil && [[NSFileManager defaultManager] fileExistsAtPath: path])
		[self display: m path: path generation: gen];
	else {
		[messageView showMessage: m body: @"Downloading…" attachments: nil];
		[s fetchMessage: m completion: ^(NSString *err) {
			if (gen != showGeneration)
				return;
			NSString *p = [[Mail2Store sharedStore] pathForMessage: m];
			if (err == nil && p != nil)
				[self display: m path: p generation: gen];
			else
				[messageView showMessage: m body: [NSString stringWithFormat: @"The message could not be downloaded.\n\n%@",
				    err ? err : @""] attachments: nil];
		}];
	}
	/* read as soon as it is shown, as Apple Mail does */
	if ([m isUnread])
		[s setFlag: Mail2FlagSeen on: YES forMessages: [NSArray arrayWithObject: m]];
}

/* ---- actions ---- */

- (BOOL) validateAction: (SEL)a
{
	if ([current mbid] == Mail2OutboxID) {	/* only what makes sense for messages not sent yet */
		if (a == @selector(deleteMessages:) || a == @selector(sendNow:) || a == @selector(showSource:))
			return [[self selectedMessages] count] > 0;
		if (a == @selector(editDraft:))
			return [self selectedMessage] != nil;
		if (a == @selector(getMail:) || a == @selector(compose:) || a == @selector(newMailbox:))
			return [sessions count] > 0;
		return NO;
	}
	if (a == @selector(sendNow:) || a == @selector(undoSend:))
		return NO;
	if (a == @selector(getMail:) || a == @selector(compose:))
		return [sessions count] > 0;
	if (a == @selector(reply:) || a == @selector(replyAll:) || a == @selector(forward:))
		return [self selectedMessage] != nil && parsed != nil;
	if (a == @selector(archive:))
		return [[self selectedMessages] count] > 0 && ![[current special] isEqualToString: @"archive"] &&
		    ![[current special] isEqualToString: @"all"];
	if (a == @selector(deleteMessages:) || a == @selector(toggleFlag:) || a == @selector(toggleRead:))
		return [[self selectedMessages] count] > 0;
	if (a == @selector(showSource:))
		return [self selectedMessage] != nil;
	if (a == @selector(toggleMute:))
		return [[self selectedMessage] thread] != nil;
	if (a == @selector(snooze:))
		return [[self selectedMessages] count] > 0 && ([self inSnoozed] || ![current isVirtual] || [current mbid] == Mail2AllInboxesID);
	if (a == @selector(stopReminding:))
		return [current mbid] == Mail2FollowUpID && [[self selectedMessages] count] > 0;
	if (a == @selector(toggleBlock:))
		return [[self selectedMessage] fromAddr] != nil;
	if (a == @selector(moveTo:) || a == @selector(markJunk:) || a == @selector(applyRules:))
		return [[self selectedMessages] count] > 0;
	if (a == @selector(saveSearch:))
		return searchText != nil;
	if (a == @selector(deleteMailbox:))
		return [self currentIsOwnFolder] || [current mbid] <= Mail2SavedSearchBase;
	if (a == @selector(renameMailbox:))
		return [self currentIsOwnFolder];
	if (a == @selector(newMailbox:))
		return [sessions count] > 0;
	if (a == @selector(getOlderMessages:))
		return current != nil && ![self showingAllInboxes] && !loadingOlder && [[self currentSession] hasOlderMessagesIn: current];
	if (a == @selector(editDraft:))
		return [[self selectedMessage] isDraft] && parsed != nil;
	return YES;
}

- (void) updateButtons
{
	struct { NSString *icon; SEL sel; } map[] = {
		{ @"getmail", @selector(getMail:) }, { @"compose", @selector(compose:) }, { @"archive", @selector(archive:) },
		{ @"delete", @selector(deleteMessages:) }, { @"reply", @selector(reply:) }, { @"replyall", @selector(replyAll:) },
		{ @"forward", @selector(forward:) }, { @"flag", @selector(toggleFlag:) },
	};
	unsigned i;
	for (i = 0; i < sizeof(map) / sizeof(map[0]); i++) {
		BOOL on = [self validateAction: map[i].sel];
		NSButton *b = [buttons objectForKey: map[i].icon];
		if ([b isEnabled] != on) {
			[b setEnabled: on];
			[b setImage: Mail2Icon([NSString stringWithFormat: @"tb-%@-%@", map[i].icon, on ? @"normal" : @"disabled"])];
		}
	}
}

- (BOOL) validateMenuItem: (NSMenuItem *)item
{
	Mail2MessageInfo *m = [self selectedMessage];
	if ([item action] == @selector(snooze:))
		[item setTitle: [self inSnoozed] ? @"Unsnooze" : @"Snooze…"];
	if ([item action] == @selector(toggleMute:))
		[item setTitle: m && [[Mail2Store sharedStore] isThreadMuted: [m thread]] ? @"Unmute Conversation" : @"Mute Conversation"];
	if ([item action] == @selector(toggleBlock:))
		[item setTitle: m && [[Mail2Store sharedStore] isAddressBlocked: [m fromAddr]] ? @"Unblock Sender" : @"Block Sender"];
	return [self validateAction: [item action]];
}

- (void) toggleConversations: (id)sender
{
	[[NSUserDefaults standardUserDefaults] setBool: ![Mail2Window organizesByConversation] forKey: @"Mail2Conversations"];
	DESTROY(expanded);
	[self reloadMessages];
}

- (void) getMail: (id)sender
{
	NSEnumerator *e = [sessions objectEnumerator];
	Mail2Session *s;
	while ((s = [e nextObject]) != nil) {
		[s refreshMailboxes];
		[s checkInboxAnd: current];
	}
}

- (void) compose: (id)sender
{
	if (Mail2Debug())
		NSLog(@"Mail2: compose");
	if ([sessions count] == 0)
		return;
	NSMutableArray *ordered = [NSMutableArray arrayWithArray: sessions];
	Mail2Session *s = [self currentSession];
	if (s != nil) {	/* From: the account being looked at */
		[ordered removeObject: s];
		[ordered insertObject: s atIndex: 0];
	}
	[Mail2Compose newMessageWithSessions: ordered to: nil];
}

- (void) reply: (id)sender
{
	Mail2MessageInfo *m = [self selectedMessage];
	if (m != nil && parsed != nil)
		[Mail2Compose replyTo: m parsed: parsed session: [self sessionForMessage: m] sessions: sessions replyAll: NO];
}

- (void) replyAll: (id)sender
{
	Mail2MessageInfo *m = [self selectedMessage];
	if (m != nil && parsed != nil)
		[Mail2Compose replyTo: m parsed: parsed session: [self sessionForMessage: m] sessions: sessions replyAll: YES];
}

- (void) forward: (id)sender
{
	Mail2MessageInfo *m = [self selectedMessage];
	if (m != nil && parsed != nil)
		[Mail2Compose forward: m parsed: parsed session: [self sessionForMessage: m] sessions: sessions];
}

/* after removing rows: select the next message down, as Apple Mail does */
- (void) removeSelectedThen: (void (^)(NSArray *msgs))action
{
	NSArray *sel = [self selectedMessages];
	if ([sel count] == 0)
		return;
	NSInteger next = (NSInteger)[[list selectedRowIndexes] lastIndex] + 1 - (NSInteger)[sel count];
	action([self actionMessages]);
	DESTROY(expanded);
	[self reloadMessages];
	if ([messages count] > 0) {
		next = MAX(0, MIN(next, (NSInteger)[messages count] - 1));
		[list selectRowIndexes: [NSIndexSet indexSetWithIndex: next] byExtendingSelection: NO];
		[list scrollRowToVisible: next];
	}
	[self showSelection];
}

/* ---- a conversation in the message pane ---- */

/* downloads what is missing (one after the other), parses them all off the main thread, shows them, marks them read */
- (void) showConversationOf: (Mail2MessageInfo *)head generation: (unsigned)gen
{
	NSArray *newestFirst = [[Mail2Store sharedStore] messagesInConversation: [head thread] mailbox: [current mbid]];
	NSArray *msgs = [[newestFirst reverseObjectEnumerator] allObjects];
	NSMutableArray *missing = [NSMutableArray array];
	NSEnumerator *e = [msgs objectEnumerator];
	Mail2MessageInfo *m;
	while ((m = [e nextObject]) != nil)
		if ([[Mail2Store sharedStore] pathForMessage: m] == nil)
			[missing addObject: m];
	if ([missing count]) {
		[messageView showMessage: head body: @"Downloading the conversation…" attachments: nil];
		Mail2MessageInfo *first = [missing objectAtIndex: 0];
		[[self sessionForMessage: first] fetchMessage: first completion: ^(NSString *err) {
			if (gen != showGeneration)
				return;
			if (err != nil) {
				[messageView showMessage: head body: [NSString stringWithFormat: @"The conversation could not be downloaded.\n\n%@", err]
				    attachments: nil];
				return;
			}
			[self showConversationOf: head generation: gen];
		}];
		return;
	}
	[msgs retain];
	dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
		NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];
		NSMutableArray *parsedAll = [NSMutableArray array];
		NSEnumerator *pe = [msgs objectEnumerator];
		Mail2MessageInfo *pm;
		while ((pm = [pe nextObject]) != nil) {
			NSString *path = [[Mail2Store sharedStore] pathForMessage: pm];
			Mail2ParsedMessage *p = path ? [Mail2ParsedMessage parseData: [NSData dataWithContentsOfFile: path] preferPlainText: YES] : nil;
			[parsedAll addObject: p ? (id)p : (id)[NSNull null]];
		}
		[parsedAll retain];
		Mail2RunOnMain(^{
			if (gen == showGeneration) {
				[messageView showConversation: msgs parsed: parsedAll];
				id last = [parsedAll lastObject];
				if ([last isKindOfClass: [Mail2ParsedMessage class]])
					ASSIGN(parsed, last);	/* Reply answers the newest */
				[self updateButtons];
				NSMutableArray *unread = [NSMutableArray array];
				NSEnumerator *ue = [msgs objectEnumerator];
				Mail2MessageInfo *um;
				while ((um = [ue nextObject]) != nil)
					if ([um isUnread])
						[unread addObject: um];
				[self eachSession: unread do: ^(Mail2Session *s, NSArray *mine) { [s setFlag: Mail2FlagSeen on: YES forMessages: mine]; }];
			}
			[parsedAll release];
			[msgs release];
		});
		[pool release];
	});
}

/* ---- the Outbox ---- */

/* its items as rows: To, Subject, when (or why not yet) */
- (NSArray *) outboxRows
{
	NSMutableArray *r = [NSMutableArray array];
	NSEnumerator *e = [[[Mail2Outbox shared] items] reverseObjectEnumerator];
	NSDictionary *d;
	long long n = 0;
	while ((d = [e nextObject]) != nil) {
		Mail2MessageInfo *m = [[[Mail2MessageInfo alloc] init] autorelease];
		m->rowid = -(++n);
		m->mbid = Mail2OutboxID;
		m->flags = Mail2FlagSeen;
		m->fromName = [[NSString stringWithFormat: @"To: %@", [d objectForKey: @"To"] ? [d objectForKey: @"To"] : @""] retain];
		m->to = [[d objectForKey: @"To"] retain];
		m->subject = [[d objectForKey: @"Subject"] retain];
		m->date = [[d objectForKey: @"SendAt"] retain];
		m->outboxId = [[d objectForKey: @"Id"] retain];
		NSString *state;
		if ([[Mail2Outbox shared] isSending: [d objectForKey: @"Id"]])
			state = @"Sending now…";
		else if ([d objectForKey: @"Error"])
			state = [NSString stringWithFormat: @"Not sent yet: %@", [d objectForKey: @"Error"]];
		else if ([[d objectForKey: @"SendAt"] timeIntervalSinceNow] > 60)
			state = [NSString stringWithFormat: @"Sends %@", Mail2LongDate([d objectForKey: @"SendAt"])];
		else
			state = @"Sending…";
		m->snippet = [state retain];
		[r addObject: m];
	}
	return r;
}

- (void) outboxChanged: (NSNotification *)n
{
	NSArray *items = [[Mail2Outbox shared] items];
	NSDictionary *undoable = nil;
	NSEnumerator *e = [items objectEnumerator];
	NSDictionary *d;
	while ((d = [e nextObject]) != nil)
		if ([d objectForKey: @"Undoable"])
			undoable = d;
	if (undoable)
		[undoLabel setStringValue: [NSString stringWithFormat: @"Sending “%@”…", [undoable objectForKey: @"Subject"]]];
	BOOL show = undoable != nil;
	if ([undoBar isHidden] == show) {
		[undoBar setHidden: !show];
		NSRect f = [sidebarScroll frame], sb = [[sidebarScroll superview] bounds];
		CGFloat bottom = STATUS_H + (show ? 32 : 0);
		f.origin.y = bottom;
		f.size.height = NSHeight(sb) - bottom;
		[sidebarScroll setFrame: f];
	}
	[self reloadSidebar];
	if ([current mbid] == Mail2OutboxID)
		[self reloadMessages];
}

/* the newest message still in its Undo moment comes back to a compose window */
- (void) undoSend: (id)sender
{
	NSString *ident = nil;
	NSEnumerator *e = [[[Mail2Outbox shared] items] objectEnumerator];
	NSDictionary *d;
	while ((d = [e nextObject]) != nil)
		if ([d objectForKey: @"Undoable"])
			ident = [d objectForKey: @"Id"];
	NSDictionary *back = ident ? [[Mail2Outbox shared] takeBack: ident] : nil;
	if (back != nil)
		[Mail2Compose reopenOutgoing: back sessions: sessions];
	else if (ident != nil)
		NSRunAlertPanel(@"Undo Send", @"Too late: the message is on its way.", @"OK", nil, nil);
}

- (void) sendNow: (id)sender
{
	NSEnumerator *e = [[self selectedMessages] objectEnumerator];
	Mail2MessageInfo *m;
	while ((m = [e nextObject]) != nil)
		if ([m outboxId])
			[[Mail2Outbox shared] sendNow: [m outboxId]];
}

/* ---- moves that Edit > Undo takes back ---- */

- (NSUndoManager *) windowWillReturnUndoManager: (NSWindow *)w
{
	if (undo == nil)
		undo = [[NSUndoManager alloc] init];
	return undo;
}

/* moves the account's messages to dest and remembers how to bring them back (by Message-ID, per source mailbox) */
- (void) move: (NSArray *)mine of: (Mail2Session *)s to: (Mail2Mailbox *)dest action: (NSString *)name
{
	NSMutableDictionary *bySource = [NSMutableDictionary dictionary];
	NSEnumerator *e = [mine objectEnumerator];
	Mail2MessageInfo *m;
	while ((m = [e nextObject]) != nil) {
		if ([m messageId] == nil || [m mbid] == [dest mbid])
			continue;
		NSNumber *k = [NSNumber numberWithLongLong: [m mbid]];
		NSMutableArray *a = [bySource objectForKey: k];
		if (a == nil)
			[bySource setObject: (a = [NSMutableArray array]) forKey: k];
		[a addObject: [m messageId]];
	}
	[s moveMessages: mine toMailbox: dest];
	NSUndoManager *um = [self windowWillReturnUndoManager: window];
	NSEnumerator *ke = [bySource keyEnumerator];
	NSNumber *k;
	while ((k = [ke nextObject]) != nil) {
		Mail2Mailbox *src = [[Mail2Store sharedStore] mailboxWithID: [k longLongValue]];
		if (src == nil)
			continue;
		[[um prepareWithInvocationTarget: self] moveBack: [bySource objectForKey: k] of: s from: dest to: src action: name];
		[um setActionName: name];
	}
}

/* the undo (and, the other way round, the redo) of a move */
- (void) moveBack: (NSArray *)ids of: (Mail2Session *)s from: (Mail2Mailbox *)from to: (Mail2Mailbox *)to action: (NSString *)name
{
	[s moveBackMessageIDs: ids from: from to: to];
	NSUndoManager *um = [self windowWillReturnUndoManager: window];
	[[um prepareWithInvocationTarget: self] moveBack: ids of: s from: to to: from action: name];
	[um setActionName: name];
}

/* the destination of Archive, Delete or Junk for an account; nil when it has none (Delete in the Trash: for good) */
- (Mail2Mailbox *) destination: (NSString *)special of: (Mail2Session *)s
{
	Mail2Mailbox *d = [s mailboxWithSpecial: special];
	if (d == nil && [special isEqualToString: @"archive"])
		d = [s mailboxWithSpecial: @"all"];
	return d;
}

- (void) archive: (id)sender
{
	if (![self validateAction: _cmd])
		return;
	__block BOOL missing = NO;
	[self eachSession: [self selectedMessages] do: ^(Mail2Session *s, NSArray *mine) {
		if ([s mailboxWithSpecial: @"archive"] == nil && [s mailboxWithSpecial: @"all"] == nil)
			missing = YES;
	}];
	if (missing) {
		NSRunAlertPanel(@"No Archive Mailbox", @"The account has no Archive mailbox.", @"OK", nil, nil);
		return;
	}
	[self removeSelectedThen: ^(NSArray *msgs) {
		[self eachSession: msgs do: ^(Mail2Session *s, NSArray *mine) {
			[self move: mine of: s to: [self destination: @"archive" of: s] action: @"Archive"];
		}];
	}];
}

- (void) deleteMessages: (id)sender
{
	if ([current mbid] == Mail2OutboxID) {	/* unsent: they never go */
		NSArray *sel = [self selectedMessages];
		if ([sel count] == 0 || NSRunAlertPanel(@"Delete Unsent Messages?", @"They will not be sent.", @"Delete", @"Cancel", nil)
		    != NSAlertDefaultReturn)
			return;
		NSEnumerator *e = [sel objectEnumerator];
		Mail2MessageInfo *m;
		while ((m = [e nextObject]) != nil)
			[[Mail2Outbox shared] takeBack: [m outboxId]];
		return;
	}
	if ([[current special] isEqualToString: @"trash"] &&
	    NSRunAlertPanel(@"Delete Permanently?", @"Messages deleted from the Trash cannot be recovered.",
	        @"Delete", @"Cancel", nil) != NSAlertDefaultReturn)
		return;
	[self removeSelectedThen: ^(NSArray *msgs) {
		[self eachSession: msgs do: ^(Mail2Session *s, NSArray *mine) {
			Mail2Mailbox *trash = [self destination: @"trash" of: s];
			if (trash == nil || [[current special] isEqualToString: @"trash"])
				[s moveMessages: mine toSpecial: @"trash"];	/* for good: nothing to undo */
			else
				[self move: mine of: s to: trash action: @"Delete"];
		}];
	}];
}

/* ---- moving and folders ---- */

/* the selected messages' account, when they all have the same one */
- (Mail2Session *) sessionOfSelection
{
	Mail2Session *one = nil;
	NSEnumerator *e = [[self actionMessages] objectEnumerator];
	Mail2MessageInfo *m;
	while ((m = [e nextObject]) != nil) {
		Mail2Session *s = [self sessionForMessage: m];
		if (one != nil && s != one)
			return nil;
		one = s;
	}
	return one;
}

- (void) moveTo: (id)sender
{
	Mail2Session *s = [self sessionOfSelection];
	if (s == nil) {
		if ([[self selectedMessages] count])
			NSRunAlertPanel(@"Move To", @"The messages are in different accounts: move them from each account's own mailbox.",
			    @"OK", nil, nil);
		return;
	}
	NSMutableArray *boxes = [NSMutableArray array];
	NSEnumerator *e = [[[Mail2Store sharedStore] mailboxesForAccount: [[s account] identifier]] objectEnumerator];
	Mail2Mailbox *m;
	while ((m = [e nextObject]) != nil)
		if ([m selectable] && [m mbid] != [current mbid])
			[boxes addObject: m];
	unsigned long n = (unsigned long)[[self actionMessages] count];
	Mail2Mailbox *dest = Mail2ChooseMailbox(@"Move To", [NSString stringWithFormat: n == 1 ? @"Move the message to:"
	    : @"Move the %lu messages to:", n], boxes, @"Move");
	if (dest != nil)
		[self removeSelectedThen: ^(NSArray *msgs) { [self move: msgs of: s to: dest action: @"Move"]; }];
}

/* the message as it came, in a window of its own */
- (void) showSource: (id)sender
{
	Mail2MessageInfo *m = [self selectedMessage];
	NSString *path = m && ![m outboxId] ? [[Mail2Store sharedStore] pathForMessage: m] : nil;
	NSData *raw = [m outboxId] ? [[Mail2Outbox shared] messageFor: [m outboxId]] : path ? [NSData dataWithContentsOfFile: path] : nil;
	if (raw == nil) {
		if (m != nil)
			NSRunAlertPanel(@"Raw Source", @"The message is not downloaded yet: show it first.", @"OK", nil, nil);
		return;
	}
	NSString *text = [[[NSString alloc] initWithData: raw encoding: NSUTF8StringEncoding] autorelease];
	if (text == nil)
		text = [[[NSString alloc] initWithData: raw encoding: NSISOLatin1StringEncoding] autorelease];
	NSRect f = NSOffsetRect([window frame], 40, -40);
	f.size = NSMakeSize(720, 560);
	NSWindow *w = [[NSWindow alloc] initWithContentRect: f
	    styleMask: NSTitledWindowMask | NSClosableWindowMask | NSMiniaturizableWindowMask | NSResizableWindowMask
	    backing: NSBackingStoreBuffered defer: NO];
	[w setTitle: [NSString stringWithFormat: @"Source: %@", [[m subject] length] ? [m subject] : @"(no subject)"]];
	[w setReleasedWhenClosed: YES];
	NSScrollView *sv = [[[NSScrollView alloc] initWithFrame: [[w contentView] bounds]] autorelease];
	[sv setHasVerticalScroller: YES];
	[sv setHasHorizontalScroller: YES];
	[sv setAutoresizingMask: NSViewWidthSizable | NSViewHeightSizable];
	NSTextView *tv = [[[NSTextView alloc] initWithFrame: NSMakeRect(0, 0, [sv contentSize].width, [sv contentSize].height)] autorelease];
	[tv setEditable: NO];
	[tv setRichText: NO];
	[tv setFont: [NSFont userFixedPitchFontOfSize: 11]];
	[tv setHorizontallyResizable: YES];
	[tv setVerticallyResizable: YES];
	[tv setMaxSize: NSMakeSize(1e7, 1e7)];
	[[tv textContainer] setContainerSize: NSMakeSize(1e7, 1e7)];
	[[tv textContainer] setWidthTracksTextView: NO];
	[tv setString: text];
	[sv setDocumentView: tv];
	[[w contentView] addSubview: sv];
	[w makeKeyAndOrderFront: nil];
}

/* ---- snooze, follow up ---- */

- (BOOL) inSnoozed
{
	return current != nil && ![current isVirtual] && [current depth] == 0 && [[current displayName] isEqualToString: @"Snoozed"];
}

- (void) snooze: (id)sender
{
	if ([self inSnoozed]) {	/* Unsnooze: back now */
		NSEnumerator *e = [[self actionMessages] objectEnumerator];
		Mail2MessageInfo *m;
		while ((m = [e nextObject]) != nil)
			if ([m messageId])
				[[Mail2Later shared] wake: [m messageId]];
		return;
	}
	NSArray *msgs = [self actionMessages];
	if ([msgs count] == 0)
		return;
	NSDate *when = Mail2ChooseSnoozeTime();
	if (when == nil)
		return;
	[self removeSelectedThen: ^(NSArray *sel) {
		[self eachSession: msgs do: ^(Mail2Session *s, NSArray *mine) { [[Mail2Later shared] snooze: mine of: s until: when]; }];
	}];
}

- (void) stopReminding: (id)sender
{
	NSEnumerator *e = [[self selectedMessages] objectEnumerator];
	Mail2MessageInfo *m;
	while ((m = [e nextObject]) != nil)
		if ([m messageId])
			[[Mail2Later shared] stopReminding: [m messageId]];
}

- (void) laterChanged: (NSNotification *)n
{
	BOOL listed = NO;
	NSUInteger j;
	for (j = 0; j < [sidebarItems count]; j++)
		if ([[sidebarItems objectAtIndex: j] isKindOfClass: [Mail2Mailbox class]] && [[sidebarItems objectAtIndex: j] mbid] == Mail2FollowUpID)
			listed = YES;
	if (listed != ([[[Mail2Later shared] dueFollowUps] count] > 0 || [current mbid] == Mail2FollowUpID))
		[self reloadSidebar];
	if ([current mbid] == Mail2FollowUpID)
		[self reloadMessages];
}

/* ---- mute, block ---- */

- (void) toggleMute: (id)sender
{
	Mail2MessageInfo *m = [self selectedMessage];
	if ([m thread] == nil)
		return;
	[[Mail2Store sharedStore] setThread: [m thread] muted: ![[Mail2Store sharedStore] isThreadMuted: [m thread]]];
	[list setNeedsDisplay: YES];
}

- (void) toggleBlock: (id)sender
{
	Mail2MessageInfo *m = [self selectedMessage];
	NSString *addr = [m fromAddr];
	Mail2Store *store = [Mail2Store sharedStore];
	if (addr == nil)
		return;
	if ([store isAddressBlocked: addr]) {
		[store setAddress: addr blocked: NO];
		return;
	}
	NSInteger r = NSRunAlertPanel(@"Block Sender?", @"New mail from %@ will go straight to the Trash.",
	    @"Block and Move Their Mail", @"Cancel", @"Block", addr);
	if (r == NSAlertAlternateReturn)
		return;
	[store setAddress: addr blocked: YES];
	if (r == NSAlertDefaultReturn) {	/* what is here from them, to the Trash too */
		NSString *q = [NSString stringWithFormat: @"from:\"%@\"", addr];
		NSArray *theirs = [store searchMailbox: [current isVirtual] ? Mail2EverywhereID : [current mbid] text: q alsoUids: nil limit: 5000];
		[self eachSession: theirs do: ^(Mail2Session *s, NSArray *mine) {
			Mail2Mailbox *trash = [s mailboxWithSpecial: @"trash"];
			NSMutableArray *notInTrash = [NSMutableArray array];
			NSEnumerator *e = [mine objectEnumerator];
			Mail2MessageInfo *x;
			while ((x = [e nextObject]) != nil)
				if ([x mbid] != [trash mbid])
					[notInTrash addObject: x];
			if (trash != nil && [notInTrash count])
				[self move: notInTrash of: s to: trash action: @"Block Sender"];
		}];
		[self reloadMessages];
		[self showSelection];
	}
}

- (void) applyRules: (id)sender
{
	[self eachSession: [self actionMessages] do: ^(Mail2Session *s, NSArray *mine) { [s applyRulesTo: mine]; }];
}

/* Junk; in the Junk mailbox, "not junk" back to the Inbox */
- (void) markJunk: (id)sender
{
	BOOL inJunk = [[current special] isEqualToString: @"junk"];
	__block BOOL missing = NO;
	[self eachSession: [self actionMessages] do: ^(Mail2Session *s, NSArray *mine) {
		if ([s mailboxWithSpecial: inJunk ? @"inbox" : @"junk"] == nil)
			missing = YES;
	}];
	if (missing) {
		NSRunAlertPanel(@"No Junk Mailbox", @"The account has no Junk mailbox.", @"OK", nil, nil);
		return;
	}
	[self removeSelectedThen: ^(NSArray *msgs) {
		[self eachSession: msgs do: ^(Mail2Session *s, NSArray *mine) {
			[self move: mine of: s to: [self destination: inJunk ? @"inbox" : @"junk" of: s]
			    action: inJunk ? @"Not Junk" : @"Mark as Junk"];
		}];
	}];
}

- (void) newMailbox: (id)sender
{
	Mail2Session *s = [self showingAllInboxes] || current == nil ? ([sessions count] ? [sessions objectAtIndex: 0] : nil)
	                                                             : [self currentSession];
	if (s == nil)
		return;
	NSString *name = Mail2AskString(@"New Mailbox", [NSString stringWithFormat: @"A new mailbox in %@:", [[s account] email]],
	    @"", @"Create");
	if (name != nil)
		[s createMailboxNamed: name];
}

/* the search in the field (with a saved search's own, if one is shown) as a smart mailbox */
- (void) saveSearch: (id)sender
{
	if (searchText == nil)
		return;
	NSString *q = [current mbid] <= Mail2SavedSearchBase ? [NSString stringWithFormat: @"%@ %@", [current name], searchText] : searchText;
	NSString *name = Mail2AskString(@"Save Search", @"Name of the smart mailbox:", searchText, @"Save");
	if (name == nil)
		return;
	NSMutableArray *saved = [NSMutableArray arrayWithArray: [[NSUserDefaults standardUserDefaults] arrayForKey: @"Mail2SavedSearches"]];
	[saved addObject: [NSDictionary dictionaryWithObjectsAndKeys: name, @"Name", q, @"Query", nil]];
	[[NSUserDefaults standardUserDefaults] setObject: saved forKey: @"Mail2SavedSearches"];
	[self reloadSidebar];
}

- (void) deleteSavedSearch
{
	NSInteger i = (NSInteger)(Mail2SavedSearchBase - [current mbid]);
	NSMutableArray *saved = [NSMutableArray arrayWithArray: [[NSUserDefaults standardUserDefaults] arrayForKey: @"Mail2SavedSearches"]];
	if (i < 0 || i >= (NSInteger)[saved count])
		return;
	if (NSRunAlertPanel(@"Delete Smart Mailbox?", @"Delete “%@”? The messages stay where they are.", @"Delete", @"Cancel", nil,
	    [current displayName]) != NSAlertDefaultReturn)
		return;
	[saved removeObjectAtIndex: i];
	[[NSUserDefaults standardUserDefaults] setObject: saved forKey: @"Mail2SavedSearches"];
	DESTROY(current);
	[self reloadSidebar];
}

- (BOOL) currentIsOwnFolder
{
	return current != nil && ![self showingAllInboxes] && [current special] == nil;
}

- (void) renameMailbox: (id)sender
{
	if (![self currentIsOwnFolder])
		return;
	NSString *name = Mail2AskString(@"Rename Mailbox", [NSString stringWithFormat: @"Rename “%@” to:", [current displayName]],
	    [current displayName], @"Rename");
	if (name != nil && ![name isEqualToString: [current displayName]])
		[[self currentSession] renameMailbox: current to: name];
}

- (void) deleteMailbox: (id)sender
{
	if ([current mbid] <= Mail2SavedSearchBase) {
		[self deleteSavedSearch];
		return;
	}
	if (![self currentIsOwnFolder])
		return;
	if (NSRunAlertPanel(@"Delete Mailbox?", @"Delete “%@” and every message in it, on the server too? This cannot be undone.",
	    @"Delete", @"Cancel", nil, [current displayName]) != NSAlertDefaultReturn)
		return;
	[[self currentSession] deleteMailbox: current];
}

/* ---- drag messages onto a mailbox ---- */

#define MAIL2_MESSAGES_TYPE @"Mail2MessageRows"

- (BOOL) tableView: (NSTableView *)t writeRowsWithIndexes: (NSIndexSet *)rows toPasteboard: (NSPasteboard *)pb
{
	if (t != list)
		return NO;
	NSMutableArray *ids = [NSMutableArray array];
	NSUInteger i;
	for (i = [rows firstIndex]; i != NSNotFound; i = [rows indexGreaterThanIndex: i])
		if (i < [messages count])
			[ids addObject: [NSNumber numberWithLongLong: [[messages objectAtIndex: i] rowid]]];
	if ([ids count] == 0)
		return NO;
	/* dragging part of the selection drags all of it (and a closed conversation all its messages), as in Apple Mail */
	if ([[list selectedRowIndexes] containsIndexes: rows]) {
		[ids removeAllObjects];
		NSEnumerator *e = [[self actionMessages] objectEnumerator];
		Mail2MessageInfo *m;
		while ((m = [e nextObject]) != nil)
			[ids addObject: [NSNumber numberWithLongLong: [m rowid]]];
	}
	[pb declareTypes: [NSArray arrayWithObject: MAIL2_MESSAGES_TYPE] owner: nil];
	return [pb setPropertyList: ids forType: MAIL2_MESSAGES_TYPE];
}

/* the older form of the same, which some versions of gnustep-gui call */
- (BOOL) tableView: (NSTableView *)t writeRows: (NSArray *)rows toPasteboard: (NSPasteboard *)pb
{
	NSMutableIndexSet *set = [NSMutableIndexSet indexSet];
	NSEnumerator *e = [rows objectEnumerator];
	NSNumber *n;
	while ((n = [e nextObject]) != nil)
		[set addIndex: [n unsignedIntegerValue]];
	return [self tableView: t writeRowsWithIndexes: set toPasteboard: pb];
}

- (NSArray *) draggedMessages: (id <NSDraggingInfo>)info
{
	NSArray *ids = [[info draggingPasteboard] propertyListForType: MAIL2_MESSAGES_TYPE];
	NSMutableArray *r = [NSMutableArray array];
	NSEnumerator *e = [ids objectEnumerator];
	NSNumber *n;
	while ((n = [e nextObject]) != nil) {
		Mail2MessageInfo *m = [[Mail2Store sharedStore] messageWithRowID: [n longLongValue]];
		if (m != nil)
			[r addObject: m];
	}
	return r;
}

- (NSDragOperation) tableView: (NSTableView *)t validateDrop: (id <NSDraggingInfo>)info proposedRow: (NSInteger)row
       proposedDropOperation: (NSTableViewDropOperation)op
{
	if (t != sidebar || row < 0 || row >= (NSInteger)[sidebarItems count])
		return NSDragOperationNone;
	id it = [sidebarItems objectAtIndex: row];
	if (![it isKindOfClass: [Mail2Mailbox class]] || ![it selectable] || [it isVirtual])
		return NSDragOperationNone;
	NSArray *msgs = [self draggedMessages: info];
	if ([msgs count] == 0)
		return NSDragOperationNone;
	/* within one account: IMAP moves inside a server */
	NSEnumerator *e = [msgs objectEnumerator];
	Mail2MessageInfo *m;
	while ((m = [e nextObject]) != nil)
		if (![[[[Mail2Store sharedStore] mailboxWithID: [m mbid]] account] isEqualToString: [it account]] || [m mbid] == [it mbid])
			return NSDragOperationNone;
	[t setDropRow: row dropOperation: NSTableViewDropOn];
	return NSDragOperationMove;
}

- (BOOL) tableView: (NSTableView *)t acceptDrop: (id <NSDraggingInfo>)info row: (NSInteger)row
     dropOperation: (NSTableViewDropOperation)op
{
	if ([self tableView: t validateDrop: info proposedRow: row proposedDropOperation: op] == NSDragOperationNone)
		return NO;
	Mail2Mailbox *dest = [sidebarItems objectAtIndex: row];
	NSArray *msgs = [self draggedMessages: info];
	Mail2Session *s = [self sessionForAccount: [dest account]];
	[self move: msgs of: s to: dest action: @"Move"];
	[self reloadMessages];
	[self showSelection];
	return YES;
}

- (void) toggleFlag: (id)sender
{
	NSArray *sel = [self actionMessages];
	if ([sel count] == 0)
		return;
	BOOL on = ([[sel objectAtIndex: 0] flags] & Mail2FlagFlagged) == 0;
	[self eachSession: sel do: ^(Mail2Session *s, NSArray *mine) { [s setFlag: Mail2FlagFlagged on: on forMessages: mine]; }];
	[list setNeedsDisplay: YES];
}

- (void) toggleRead: (id)sender
{
	NSArray *sel = [self actionMessages];
	if ([sel count] == 0)
		return;
	BOOL read = [[sel objectAtIndex: 0] isUnread];
	[self eachSession: sel do: ^(Mail2Session *s, NSArray *mine) { [s setFlag: Mail2FlagSeen on: read forMessages: mine]; }];
	[list setNeedsDisplay: YES];
}

- (BOOL) windowShouldClose: (id)w
{
	/* the viewer hides; the app keeps running for new mail and the badge */
	[window orderOut: nil];
	return NO;
}

@end
