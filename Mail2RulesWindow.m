/* Mail2RulesWindow: the rules list and editor (see Mail2RulesWindow.h). */
#import "Mail2RulesWindow.h"
#import "Mail2Account.h"
#import "Mail2Store.h"
#import "Mail2Util.h"
#import "Mail2Sieve.h"
#include <dispatch/dispatch.h>

/* ---- the editor of one rule (modal) ---- */

@interface Mail2RuleEditor : NSObject
{
@public
	NSPanel *panel;
	NSPopUpButton *accountPop, *fieldPop, *actionPop, *mailboxPop;
	NSTextField *textField, *note;
	NSArray *accounts;
}
@end

@implementation Mail2RuleEditor

static NSTextField *
label(NSView *v, NSString *s, NSRect r)
{
	NSTextField *l = [[[NSTextField alloc] initWithFrame: r] autorelease];
	[l setStringValue: s];
	[l setEditable: NO];
	[l setSelectable: NO];
	[l setBezeled: NO];
	[l setDrawsBackground: NO];
	[l setAlignment: NSRightTextAlignment];
	[v addSubview: l];
	return l;
}

static NSPopUpButton *
popup(NSView *v, NSRect r, id target, SEL action)
{
	NSPopUpButton *p = [[[NSPopUpButton alloc] initWithFrame: r pullsDown: NO] autorelease];
	[p setTarget: target];
	[p setAction: action];
	[v addSubview: p];
	return p;
}

- (id) initWithAccounts: (NSArray *)a
{
	if ((self = [super init]) == nil)
		return nil;
	accounts = [a retain];
	NSRect v = [[NSScreen mainScreen] visibleFrame];
	panel = [[NSPanel alloc] initWithContentRect: NSMakeRect(floor(NSMidX(v) - 230), floor(NSMidY(v) - 40), 460, 250)
	    styleMask: NSTitledWindowMask backing: NSBackingStoreBuffered defer: NO];
	[panel setTitle: @"Rule"];
	[panel setHidesOnDeactivate: NO];
	NSView *cv = [panel contentView];
	CGFloat y = 206;
	label(cv, @"For mail to:", NSMakeRect(10, y + 4, 110, 18));
	accountPop = [popup(cv, NSMakeRect(126, y, 316, 26), self, @selector(accountChanged:)) retain];
	[accountPop addItemWithTitle: @"Every account"];
	NSEnumerator *e = [accounts objectEnumerator];
	Mail2Account *acc;
	while ((acc = [e nextObject]) != nil)
		[accountPop addItemWithTitle: [acc email]];
	y -= 36;
	label(cv, @"If:", NSMakeRect(10, y + 4, 110, 18));
	fieldPop = [popup(cv, NSMakeRect(126, y, 150, 26), nil, NULL) retain];
	[fieldPop addItemWithTitle: @"From"];
	[fieldPop addItemWithTitle: @"To or Cc"];
	[fieldPop addItemWithTitle: @"Subject"];
	[fieldPop addItemWithTitle: @"Any of these"];
	label(cv, @"contains", NSMakeRect(276, y + 4, 60, 18));
	y -= 32;
	textField = [[NSTextField alloc] initWithFrame: NSMakeRect(126, y, 316, 24)];
	[cv addSubview: textField];
	y -= 40;
	label(cv, @"Then:", NSMakeRect(10, y + 4, 110, 18));
	actionPop = [popup(cv, NSMakeRect(126, y, 316, 26), self, @selector(actionChanged:)) retain];
	[actionPop addItemWithTitle: @"Move to mailbox"];
	[actionPop addItemWithTitle: @"Mark as Read"];
	[actionPop addItemWithTitle: @"Flag"];
	[actionPop addItemWithTitle: @"Move to Trash"];
	y -= 32;
	mailboxPop = [popup(cv, NSMakeRect(126, y, 316, 26), nil, NULL) retain];
	note = [label(cv, @"", NSMakeRect(10, 44, 440, 18)) retain];
	[note setAlignment: NSLeftTextAlignment];
	[note setTextColor: [NSColor colorWithCalibratedRed: 0.75 green: 0.1 blue: 0.1 alpha: 1]];
	NSButton *ok = [[[NSButton alloc] initWithFrame: NSMakeRect(350, 10, 92, 28)] autorelease];
	[ok setTitle: @"OK"];
	[ok setBezelStyle: NSRoundedBezelStyle];
	[ok setKeyEquivalent: @"\r"];
	[ok setTarget: self];
	[ok setAction: @selector(ok:)];
	[cv addSubview: ok];
	NSButton *cancel = [[[NSButton alloc] initWithFrame: NSMakeRect(252, 10, 92, 28)] autorelease];
	[cancel setTitle: @"Cancel"];
	[cancel setBezelStyle: NSRoundedBezelStyle];
	[cancel setKeyEquivalent: @"\e"];
	[cancel setTarget: self];
	[cancel setAction: @selector(cancel:)];
	[cv addSubview: cancel];
	return self;
}

- (void) dealloc
{
	[panel release]; [accountPop release]; [fieldPop release]; [actionPop release]; [mailboxPop release];
	[textField release]; [note release]; [accounts release];
	[super dealloc];
}

/* the mailboxes of the chosen account (a move needs one) */
- (void) accountChanged: (id)sender
{
	NSString *keep = [[mailboxPop selectedItem] representedObject];
	[mailboxPop removeAllItems];
	NSInteger i = [accountPop indexOfSelectedItem];
	if (i <= 0) {
		[mailboxPop addItemWithTitle: @"(choose one account to move mail)"];
		[mailboxPop setEnabled: NO];
		return;
	}
	Mail2Account *a = [accounts objectAtIndex: i - 1];
	NSEnumerator *e = [[[Mail2Store sharedStore] mailboxesForAccount: [a identifier]] objectEnumerator];
	Mail2Mailbox *m;
	while ((m = [e nextObject]) != nil) {
		if (![m selectable] || [[m special] isEqualToString: @"inbox"])
			continue;
		[mailboxPop addItemWithTitle: [m displayName]];
		[[mailboxPop lastItem] setRepresentedObject: [m name]];
		if ([[m name] isEqualToString: keep])
			[mailboxPop selectItem: [mailboxPop lastItem]];
	}
	[self actionChanged: nil];
}

- (void) actionChanged: (id)sender
{
	[mailboxPop setEnabled: [actionPop indexOfSelectedItem] == Mail2RuleMove && [accountPop indexOfSelectedItem] > 0];
}

- (void) ok: (id)s
{
	if ([[[textField stringValue] stringByTrimmingCharactersInSet: [NSCharacterSet whitespaceCharacterSet]] length] == 0) {
		[note setStringValue: @"Enter the text to look for."];
		return;
	}
	if ([actionPop indexOfSelectedItem] == Mail2RuleMove && ([accountPop indexOfSelectedItem] <= 0 ||
	    [[mailboxPop selectedItem] representedObject] == nil)) {
		[note setStringValue: @"Moving needs one account and one of its mailboxes."];
		return;
	}
	[NSApp stopModalWithCode: NSOKButton];
}

- (void) cancel: (id)s { [NSApp stopModalWithCode: NSCancelButton]; }

- (BOOL) runFor: (Mail2Rule *)r
{
	NSUInteger ai = r->account ? [[accounts valueForKey: @"identifier"] indexOfObject: r->account] : NSNotFound;
	[accountPop selectItemAtIndex: ai == NSNotFound ? 0 : (NSInteger)ai + 1];
	[self accountChanged: nil];
	NSInteger mi = r->mailbox ? [mailboxPop indexOfItemWithRepresentedObject: r->mailbox] : -1;
	if (mi >= 0)
		[mailboxPop selectItemAtIndex: mi];
	[fieldPop selectItemAtIndex: r->field];
	[actionPop selectItemAtIndex: r->action];
	[textField setStringValue: r->text ? r->text : @""];
	[self actionChanged: nil];
	[NSApp activateIgnoringOtherApps: YES];
	[panel makeKeyAndOrderFront: nil];
	[panel makeFirstResponder: textField];
	[panel display];
	NSInteger rc = [NSApp runModalForWindow: panel];
	[panel orderOut: nil];
	if (rc != NSOKButton)
		return NO;
	NSInteger ac = [accountPop indexOfSelectedItem];
	ASSIGN(r->account, ac > 0 ? [[accounts objectAtIndex: ac - 1] identifier] : nil);
	r->field = (Mail2RuleField)[fieldPop indexOfSelectedItem];
	r->action = (Mail2RuleAction)[actionPop indexOfSelectedItem];
	ASSIGN(r->text, [[textField stringValue] stringByTrimmingCharactersInSet: [NSCharacterSet whitespaceCharacterSet]]);
	ASSIGN(r->mailbox, r->action == Mail2RuleMove ? [[mailboxPop selectedItem] representedObject] : nil);
	return YES;
}

@end

/* ---- the list ---- */

@implementation Mail2RulesWindow

- (id) initWithAccounts: (NSArray *)a
{
	if ((self = [super init]) == nil)
		return nil;
	accounts = [a retain];
	rules = [[NSMutableArray alloc] initWithArray: [Mail2Rule loadRules]];
	NSRect v = [[NSScreen mainScreen] visibleFrame];
	panel = [[NSPanel alloc] initWithContentRect: NSMakeRect(floor(NSMidX(v) - 260), floor(NSMidY(v) - 100), 520, 300)
	    styleMask: NSTitledWindowMask | NSClosableWindowMask | NSResizableWindowMask backing: NSBackingStoreBuffered defer: NO];
	[panel setTitle: @"Rules"];
	[panel setReleasedWhenClosed: NO];
	[panel setHidesOnDeactivate: NO];
	NSView *cv = [panel contentView];
	NSScrollView *sv = [[[NSScrollView alloc] initWithFrame: NSMakeRect(16, 56, 488, 228)] autorelease];
	[sv setHasVerticalScroller: YES];
	[sv setBorderType: NSBezelBorder];
	[sv setAutoresizingMask: NSViewWidthSizable | NSViewHeightSizable];
	table = [[NSTableView alloc] initWithFrame: NSMakeRect(0, 0, 470, 228)];
	NSTableColumn *on = [[[NSTableColumn alloc] initWithIdentifier: @"on"] autorelease];
	[[on headerCell] setStringValue: @"On"];
	[on setWidth: 30];
	NSButtonCell *check = [[[NSButtonCell alloc] init] autorelease];
	[check setButtonType: NSSwitchButton];
	[check setTitle: @""];
	[on setDataCell: check];
	NSTableColumn *what = [[[NSTableColumn alloc] initWithIdentifier: @"rule"] autorelease];
	[[what headerCell] setStringValue: @"Rule"];
	[what setWidth: 430];
	[what setEditable: NO];
	[table addTableColumn: on];
	[table addTableColumn: what];
	[table setRowHeight: 22];
	[table setDataSource: (id)self];
	[table setDelegate: (id)self];
	[table setTarget: self];
	[table setDoubleAction: @selector(edit:)];
	[sv setDocumentView: table];
	[cv addSubview: sv];
	struct { NSString *t; SEL s; CGFloat x, w; } b[] = {
		{ @"Add…", @selector(add:), 16, 90 }, { @"Edit…", @selector(edit:), 112, 90 }, { @"Remove", @selector(remove:), 208, 90 },
	};
	unsigned i;
	for (i = 0; i < 3; i++) {
		NSButton *btn = [[[NSButton alloc] initWithFrame: NSMakeRect(b[i].x, 14, b[i].w, 28)] autorelease];
		[btn setTitle: b[i].t];
		[btn setBezelStyle: NSRoundedBezelStyle];
		[btn setTarget: self];
		[btn setAction: b[i].s];
		[cv addSubview: btn];
		if (i == 1) editButton = [btn retain];
		if (i == 2) removeButton = [btn retain];
	}
	NSButton *srv = [[[NSButton alloc] initWithFrame: NSMakeRect(304, 14, 130, 28)] autorelease];
	[srv setTitle: @"Put on Server…"];
	[srv setBezelStyle: NSRoundedBezelStyle];
	[srv setTarget: self];
	[srv setAction: @selector(putOnServer:)];
	[srv setToolTip: @"Run these rules on the server too (Sieve), even while Mail2 is closed"];
	[cv addSubview: srv];
	NSTextField *hint = [[[NSTextField alloc] initWithFrame: NSMakeRect(438, 18, 80, 18)] autorelease];
	[hint setStringValue: @"New mail."];
	[hint setEditable: NO];
	[hint setBezeled: NO];
	[hint setDrawsBackground: NO];
	[hint setFont: [NSFont systemFontOfSize: 11]];
	[hint setTextColor: [NSColor colorWithCalibratedWhite: 0.45 alpha: 1]];
	[cv addSubview: hint];
	return self;
}

- (void) dealloc
{
	[panel release]; [table release]; [editButton release]; [removeButton release]; [rules release]; [accounts release];
	[super dealloc];
}

- (void) setAccounts: (NSArray *)a { ASSIGN(accounts, a); }

- (void) save
{
	if (![Mail2Rule saveRules: rules])
		NSRunAlertPanel(@"Cannot Save the Rules", @"Rules.plist could not be written.", @"OK", nil, nil);
	[table reloadData];
	[self tableViewSelectionDidChange: nil];
}

- (void) show
{
	[rules setArray: [Mail2Rule loadRules]];
	[table reloadData];
	[self tableViewSelectionDidChange: nil];
	[NSApp activateIgnoringOtherApps: YES];
	[panel makeKeyAndOrderFront: nil];
	[panel display];
}

- (NSInteger) numberOfRowsInTableView: (NSTableView *)t { return (NSInteger)[rules count]; }

- (id) tableView: (NSTableView *)t objectValueForTableColumn: (NSTableColumn *)c row: (NSInteger)r
{
	if (r < 0 || r >= (NSInteger)[rules count])
		return nil;
	Mail2Rule *rule = [rules objectAtIndex: r];
	if ([[c identifier] isEqual: @"on"])
		return [NSNumber numberWithBool: rule->enabled];
	NSString *who = @"";
	if (rule->account != nil && [accounts count] > 1)
		who = [NSString stringWithFormat: @"  (%@)", rule->account];
	return [[rule summary] stringByAppendingString: who];
}

/* the checkbox */
- (void) tableView: (NSTableView *)t setObjectValue: (id)v forTableColumn: (NSTableColumn *)c row: (NSInteger)r
{
	if (r < 0 || r >= (NSInteger)[rules count] || ![[c identifier] isEqual: @"on"])
		return;
	((Mail2Rule *)[rules objectAtIndex: r])->enabled = [v boolValue];
	[self save];
}

- (void) tableViewSelectionDidChange: (NSNotification *)n
{
	BOOL any = [table selectedRow] >= 0;
	[editButton setEnabled: any];
	[removeButton setEnabled: any];
}

- (void) add: (id)sender
{
	Mail2RuleEditor *ed = [[[Mail2RuleEditor alloc] initWithAccounts: accounts] autorelease];
	Mail2Rule *r = [[[Mail2Rule alloc] init] autorelease];
	if ([ed runFor: r]) {
		[rules addObject: r];
		[self save];
	}
}

- (void) edit: (id)sender
{
	NSInteger i = [table selectedRow];
	if (i < 0 || i >= (NSInteger)[rules count])
		return;
	Mail2RuleEditor *ed = [[[Mail2RuleEditor alloc] initWithAccounts: accounts] autorelease];
	if ([ed runFor: [rules objectAtIndex: i]])
		[self save];
}

/* every account's rules and blocked senders as its Sieve script, over ManageSieve */
- (void) putOnServer: (id)sender
{
	if (NSRunAlertPanel(@"Put the Rules on the Server?", @"Each account's server will run these rules (and the blocked senders) "
	    "on new mail even while Mail2 is closed, as a Sieve script named mail2 that replaces the active one. Servers with "
	    "ManageSieve only (Dovecot, Fastmail; not Gmail or iCloud).", @"Put on Server", @"Cancel", nil) != NSAlertDefaultReturn)
		return;
	NSArray *rs = [[rules copy] autorelease];
	NSArray *blocked = [[Mail2Store sharedStore] blockedAddresses];
	NSArray *accs = [[accounts copy] autorelease];
	NSMutableArray *scripts = [NSMutableArray array];
	NSEnumerator *e = [accs objectEnumerator];
	Mail2Account *a;
	while ((a = [e nextObject]) != nil) {
		NSString *trash = nil;
		NSEnumerator *me = [[[Mail2Store sharedStore] mailboxesForAccount: [a identifier]] objectEnumerator];
		Mail2Mailbox *m;
		while ((m = [me nextObject]) != nil)
			if ([[m special] isEqualToString: @"trash"])
				trash = [m name];
		[scripts addObject: Mail2SieveScript(rs, [a identifier], blocked, trash)];
	}
	[scripts retain];
	[accs retain];
	dispatch_async(dispatch_get_global_queue(0, 0), ^{
		NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];
		NSMutableArray *report = [NSMutableArray array];
		NSUInteger i;
		for (i = 0; i < [accs count]; i++) {
			NSString *err = nil;
			Mail2Account *acc = [accs objectAtIndex: i];
			BOOL ok = Mail2SieveUpload(acc, [scripts objectAtIndex: i], &err);
			[report addObject: [NSString stringWithFormat: @"%@: %@", [acc email], ok ? @"on the server" : err]];
		}
		NSString *msg = [[report componentsJoinedByString: @"\n"] retain];
		Mail2RunOnMain(^{
			NSRunAlertPanel(@"Rules on the Server", @"%@", @"OK", nil, nil, msg);
			[msg release];
			[scripts release];
			[accs release];
		});
		[pool release];
	});
}

- (void) remove: (id)sender
{
	NSInteger i = [table selectedRow];
	if (i < 0 || i >= (NSInteger)[rules count])
		return;
	[rules removeObjectAtIndex: i];
	[table deselectAll: nil];
	[self save];
}

@end
