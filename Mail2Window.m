/* Mail2Window: the three-pane viewer (see Mail2Window.h). */
#import "Mail2Window.h"
#import "Mail2Compose.h"
#import "Mail2Util.h"
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

	/* pane 2: messages */
	messageCell = [[Mail2MessageCell alloc] initTextCell: @""];
	list = [self makeTable: messageCell rowHeight: 62 sidebar: NO];
	[list setBackgroundColor: [NSColor whiteColor]];
	[list setTarget: self];
	[list setDoubleAction: @selector(listDoubleClicked:)];
	childRows = [[NSMutableSet alloc] init];
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

- (BOOL) showingAllInboxes
{
	return current != nil && [current mbid] == Mail2AllInboxesID;
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
	return searchText == nil && [Mail2Window organizesByConversation];
}

/* the rows: search results; or the newest message of each conversation, with the opened one's other messages under
 * it; or every message */
- (NSArray *) rowsForCurrent
{
	Mail2Store *store = [Mail2Store sharedStore];
	[childRows removeAllObjects];
	if (current == nil)
		return [NSArray array];
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
	if (current != nil && (mbid == [current mbid] ||
	    ([self showingAllInboxes] && [[[[Mail2Store sharedStore] mailboxWithID: mbid] special] isEqualToString: @"inbox"])))
		[self reloadMessages];
	/* the unread counts */
	NSUInteger i;
	for (i = 0; i < [sidebarItems count]; i++) {
		id it = [sidebarItems objectAtIndex: i];
		if ([it isKindOfClass: [Mail2Mailbox class]] && ([it mbid] == mbid || [it mbid] == Mail2AllInboxesID)) {
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
				if (p != nil)
					[messageView showMessage: m body: [p body] attachments: [p attachments] html: [p htmlSource]
					    inlineParts: [p inlineParts]];
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
	if (a == @selector(getMail:) || a == @selector(compose:))
		return [sessions count] > 0;
	if (a == @selector(reply:) || a == @selector(replyAll:) || a == @selector(forward:))
		return [self selectedMessage] != nil && parsed != nil;
	if (a == @selector(archive:))
		return [[self selectedMessages] count] > 0 && ![[current special] isEqualToString: @"archive"] &&
		    ![[current special] isEqualToString: @"all"];
	if (a == @selector(deleteMessages:) || a == @selector(toggleFlag:) || a == @selector(toggleRead:))
		return [[self selectedMessages] count] > 0;
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
		[self eachSession: msgs do: ^(Mail2Session *s, NSArray *mine) { [s moveMessages: mine toSpecial: @"archive"]; }];
	}];
}

- (void) deleteMessages: (id)sender
{
	if ([[current special] isEqualToString: @"trash"] &&
	    NSRunAlertPanel(@"Delete Permanently?", @"Messages deleted from the Trash cannot be recovered.",
	        @"Delete", @"Cancel", nil) != NSAlertDefaultReturn)
		return;
	[self removeSelectedThen: ^(NSArray *msgs) {
		[self eachSession: msgs do: ^(Mail2Session *s, NSArray *mine) { [s moveMessages: mine toSpecial: @"trash"]; }];
	}];
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
