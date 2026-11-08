/* Mail2AccountPanel: the add/edit account panel (see Mail2AccountPanel.h). */
#import "Mail2AccountPanel.h"
#import "Mail2IMAP.h"
#import "Mail2Util.h"
#import "Mail2Views.h"
#import "Mail2OAuth.h"
#include <fcntl.h>
#include <unistd.h>
#include <dispatch/dispatch.h>

static NSTextField *
make_label(NSView *v, NSString *s, NSRect r, BOOL bold)
{
	NSTextField *l = [[[NSTextField alloc] initWithFrame: r] autorelease];
	[l setStringValue: s];
	[l setEditable: NO];
	[l setSelectable: NO];
	[l setBezeled: NO];
	[l setDrawsBackground: NO];
	[l setFont: bold ? [NSFont boldSystemFontOfSize: 12] : [NSFont systemFontOfSize: 12]];
	[l setAlignment: bold ? NSLeftTextAlignment : NSRightTextAlignment];
	[v addSubview: l];
	return l;
}

static NSTextField *
make_field(NSView *v, NSRect r)
{
	NSTextField *f = [[[NSTextField alloc] initWithFrame: r] autorelease];
	[f setFont: [NSFont systemFontOfSize: 12]];
	[v addSubview: f];
	return f;
}

static NSPopUpButton *
make_security(NSView *v, NSRect r)
{
	NSPopUpButton *p = [[[NSPopUpButton alloc] initWithFrame: r pullsDown: NO] autorelease];
	[p addItemWithTitle: @"TLS"];
	[p addItemWithTitle: @"STARTTLS"];
	[p addItemWithTitle: @"None"];
	[v addSubview: p];
	return p;
}

/* Drawn once more a moment after it is shown: its first drawing can happen before the window is mapped, and GNUstep
 * repaints only after an event, so it sat there empty until one came (QEMU, 2026-11-08: the window held its contents,
 * the screen did not). */
@interface NSWindow (Mail2Kick)
- (void) mail2Kick;
@end
@implementation NSWindow (Mail2Kick)
/* a frame change and back, displayed: the window is configured (and exposed) again */
- (void) mail2Kick
{
	NSRect f = [self frame], g = f;
	g.size.height += 1;
	[self setFrame: g display: YES];
	[self setFrame: f display: YES];
	[self display];
	[self flushWindow];
}
@end

static void
redisplay_soon(NSWindow *w)
{
	NSArray *modes = [NSArray arrayWithObjects: NSDefaultRunLoopMode, NSModalPanelRunLoopMode, nil];
	[w performSelector: @selector(display) withObject: nil afterDelay: 0.3 inModes: modes];
	[w performSelector: @selector(mail2Kick) withObject: nil afterDelay: 1.5 inModes: modes];
	Mail2WakeEventLoop();
}

/* a content rect of this size in the middle of the screen. Windows are made where they will be: -center after
 * creation left these windows' contents unpainted on screen (QEMU, 2026-11-08), while the viewer and compose
 * windows, made in place, were fine. */
/* the panel's background; logs its drawing with MAIL2_DEBUG (whether it is drawn at all, QEMU 2026-11-08) */
@interface Mail2PanelBackground : NSView
@end
@implementation Mail2PanelBackground
- (void) drawRect: (NSRect)r
{
	if (Mail2Debug())
		NSLog(@"Mail2: %@ drawn %@", [[self window] title], NSStringFromRect(r));
	[[NSColor windowBackgroundColor] set];
	NSRectFill(r);
}
@end

static NSRect
centered(CGFloat w, CGFloat h)
{
	NSRect v = [[NSScreen mainScreen] visibleFrame];
	if (NSWidth(v) <= 0)
		return NSMakeRect(100, 100, w, h);
	return NSMakeRect(floor(NSMidX(v) - w / 2), floor(NSMidY(v) - h / 2 + 60), w, h);
}

@implementation Mail2AccountPanel

- (id) init
{
	if ((self = [super init]) == nil)
		return nil;
	cancelPipe[0] = cancelPipe[1] = -1;
	/* a panel, not a window: a window becoming key makes the Eau theme push the application's menu to Naples, and that
	 * distributed-objects call crashed GNUstep base here twice (QEMU, 2026-11-08); a panel makes no push */
	panel = [[Mail2KeyOrderPanel alloc] initWithContentRect: centered(480, 590)
	    styleMask: NSTitledWindowMask | NSClosableWindowMask backing: NSBackingStoreBuffered defer: NO];
	[panel setHidesOnDeactivate: NO];
	[panel setContentView: [[[Mail2PanelBackground alloc] initWithFrame: [[panel contentView] frame]] autorelease]];
	[panel setDelegate: (id)self];
	[panel setTitle: @"Mail Account"];
	NSView *v = [panel contentView];
	CGFloat y = 550, lx = 16, lw = 110, fx = 132, fw = 330;

	make_label(v, @"Sign in to your mail account. iCloud and Yahoo need an app password.",
	    NSMakeRect(lx, y, 448, 18), NO);
	[[[v subviews] lastObject] setAlignment: NSLeftTextAlignment];
	y -= 34;
	make_label(v, @"Full Name:", NSMakeRect(lx, y, lw, 18), NO);
	nameField = [make_field(v, NSMakeRect(fx, y - 2, fw, 22)) retain];
	y -= 30;
	make_label(v, @"Email Address:", NSMakeRect(lx, y, lw, 18), NO);
	emailField = [make_field(v, NSMakeRect(fx, y - 2, fw, 22)) retain];
	[emailField setDelegate: (id)self];
	y -= 32;
	make_label(v, @"Sign in with:", NSMakeRect(lx, y, lw, 18), NO);
	authPopup = [[NSPopUpButton alloc] initWithFrame: NSMakeRect(fx, y - 4, 200, 26) pullsDown: NO];
	[authPopup addItemWithTitle: @"Password"];
	[authPopup addItemWithTitle: @"Google (OAuth)"];
	[authPopup addItemWithTitle: @"Microsoft (OAuth)"];
	[authPopup setTarget: self];
	[authPopup setAction: @selector(authChanged:)];
	[authPopup setRefusesFirstResponder: YES];
	[v addSubview: authPopup];
	y -= 32;
	make_label(v, @"Password:", NSMakeRect(lx, y, lw, 18), NO);
	passField = [[NSSecureTextField alloc] initWithFrame: NSMakeRect(fx, y - 2, fw, 22)];
	[v addSubview: passField];

	y -= 38;
	make_label(v, @"Incoming Mail (IMAP)", NSMakeRect(lx, y, 300, 18), YES);
	y -= 28;
	make_label(v, @"Server:", NSMakeRect(lx, y, lw, 18), NO);
	imapHost = [make_field(v, NSMakeRect(fx, y - 2, 200, 22)) retain];
	make_label(v, @"Port:", NSMakeRect(fx + 204, y, 36, 18), NO);
	imapPort = [make_field(v, NSMakeRect(fx + 244, y - 2, 50, 22)) retain];
	y -= 30;
	make_label(v, @"User Name:", NSMakeRect(lx, y, lw, 18), NO);
	imapUser = [make_field(v, NSMakeRect(fx, y - 2, 200, 22)) retain];
	imapSec = [make_security(v, NSMakeRect(fx + 210, y - 4, 120, 26)) retain];

	y -= 38;
	make_label(v, @"Outgoing Mail (SMTP)", NSMakeRect(lx, y, 300, 18), YES);
	y -= 28;
	make_label(v, @"Server:", NSMakeRect(lx, y, lw, 18), NO);
	smtpHost = [make_field(v, NSMakeRect(fx, y - 2, 200, 22)) retain];
	make_label(v, @"Port:", NSMakeRect(fx + 204, y, 36, 18), NO);
	smtpPort = [make_field(v, NSMakeRect(fx + 244, y - 2, 50, 22)) retain];
	y -= 30;
	make_label(v, @"User Name:", NSMakeRect(lx, y, lw, 18), NO);
	smtpUser = [make_field(v, NSMakeRect(fx, y - 2, 200, 22)) retain];
	smtpSec = [make_security(v, NSMakeRect(fx + 210, y - 4, 120, 26)) retain];

	y -= 40;
	make_label(v, @"Signature:", NSMakeRect(lx, y, lw, 18), NO);
	NSScrollView *ss = [[[NSScrollView alloc] initWithFrame: NSMakeRect(fx, y - 50, fw, 70)] autorelease];
	[ss setHasVerticalScroller: YES];
	[ss setBorderType: NSBezelBorder];
	sigView = [[NSTextView alloc] initWithFrame: NSMakeRect(0, 0, [ss contentSize].width, [ss contentSize].height)];
	[sigView setRichText: NO];
	[sigView setFont: [NSFont systemFontOfSize: 12]];
	[sigView setVerticallyResizable: YES];
	[sigView setHorizontallyResizable: NO];
	[sigView setAutoresizingMask: NSViewWidthSizable];
	[[sigView textContainer] setWidthTracksTextView: YES];
	[ss setDocumentView: sigView];
	[v addSubview: ss];
	y -= 60;
	message = [make_label(v, @"", NSMakeRect(lx, y - 14, 448, 34), NO) retain];
	[message setAlignment: NSLeftTextAlignment];
	[message setTextColor: [NSColor colorWithCalibratedRed: 0.75 green: 0.1 blue: 0.1 alpha: 1]];

	okButton = [[NSButton alloc] initWithFrame: NSMakeRect(372, 12, 92, 28)];
	[okButton setTitle: @"Sign In"];
	[okButton setBezelStyle: NSRoundedBezelStyle];
	[okButton setKeyEquivalent: @"\r"];
	[okButton setTarget: self];
	[okButton setAction: @selector(signIn:)];
	[v addSubview: okButton];
	cancelButton = [[NSButton alloc] initWithFrame: NSMakeRect(274, 12, 92, 28)];
	[cancelButton setTitle: @"Cancel"];
	[cancelButton setBezelStyle: NSRoundedBezelStyle];
	[cancelButton setKeyEquivalent: @"\e"];
	[cancelButton setTarget: self];
	[cancelButton setAction: @selector(cancel:)];
	[v addSubview: cancelButton];

	/* an explicit loop of the text fields (see Mail2Compose.m: GNUstep's recalculated one included buttons) */
	[okButton setRefusesFirstResponder: YES];
	[cancelButton setRefusesFirstResponder: YES];
	[imapSec setRefusesFirstResponder: YES];
	[smtpSec setRefusesFirstResponder: YES];
	[panel setAutorecalculatesKeyViewLoop: NO];
	[(Mail2KeyOrderPanel *)panel setKeyOrder: [self fieldOrder]];
	[nameField setNextKeyView: emailField];
	[emailField setNextKeyView: passField];
	[passField setNextKeyView: imapHost];
	[imapHost setNextKeyView: imapPort];
	[imapPort setNextKeyView: imapUser];
	[imapUser setNextKeyView: smtpHost];
	[smtpHost setNextKeyView: smtpPort];
	[smtpPort setNextKeyView: smtpUser];
	[smtpUser setNextKeyView: sigView];
	[sigView setNextKeyView: nameField];
	return self;
}

- (void) dealloc
{
	[panel release]; [nameField release]; [emailField release]; [passField release];
	[imapHost release]; [imapPort release]; [imapUser release]; [imapSec release];
	[smtpHost release]; [smtpPort release]; [smtpUser release]; [smtpSec release];
	[message release]; [okButton release]; [cancelButton release]; [autoDomain release]; [result release];
	[authPopup release]; [existing release]; [completion release]; [sigView release];
	if (cancelPipe[0] >= 0) { close(cancelPipe[0]); close(cancelPipe[1]); }
	[super dealloc];
}

- (NSArray *) fieldOrder
{
	return [NSArray arrayWithObjects: nameField, emailField, passField, imapHost, imapPort, imapUser, smtpHost, smtpPort,
	    smtpUser, sigView, nil];
}

- (void) fillFrom: (Mail2Account *)a
{
	[imapHost setStringValue: [a imapHost] ? [a imapHost] : @""];
	[imapPort setIntValue: [a imapPort]];
	[imapUser setStringValue: [a imapUser] ? [a imapUser] : @""];
	[imapSec selectItemAtIndex: [a imapSecurity]];
	[smtpHost setStringValue: [a smtpHost] ? [a smtpHost] : @""];
	[smtpPort setIntValue: [a smtpPort]];
	[smtpUser setStringValue: [a smtpUser] ? [a smtpUser] : @""];
	[smtpSec selectItemAtIndex: [a smtpSecurity]];
}

/* the servers follow the address until the user changes them */
- (void) controlTextDidChange: (NSNotification *)n
{
	if ([n object] != emailField)
		return;
	NSString *e = [emailField stringValue];
	NSRange at = [e rangeOfString: @"@"];
	if (at.location == NSNotFound)
		return;
	NSString *domain = [e substringFromIndex: at.location + 1];
	BOOL untouched = [[imapHost stringValue] length] == 0 ||
	    (autoDomain != nil && [[imapHost stringValue] isEqualToString: [[Mail2Account accountForEmail: [@"x@" stringByAppendingString: autoDomain]] imapHost]]);
	if (!untouched && ![[imapUser stringValue] isEqualToString: e])
		return;
	ASSIGN(autoDomain, domain);
	[self fillFrom: [Mail2Account accountForEmail: e]];
	if (!authChosen) {
		[authPopup selectItemAtIndex: [Mail2Account oauthProviderForEmail: e]];
		[self updateAuth];
	}
}

/* OAuth: no password; what Sign In will do */
- (void) updateAuth
{
	Mail2Auth a = (Mail2Auth)[authPopup indexOfSelectedItem];
	[passField setEnabled: a == Mail2AuthPassword];
	[passField setEditable: a == Mail2AuthPassword];
	if (a == Mail2AuthPassword) {
		[message setStringValue: @""];
		return;
	}
	NSString *missing = [Mail2OAuth missingClientMessage: a];
	[message setTextColor: missing ? [NSColor colorWithCalibratedRed: 0.75 green: 0.1 blue: 0.1 alpha: 1]
	                               : [NSColor colorWithCalibratedWhite: 0.35 alpha: 1]];
	[message setStringValue: missing ? missing : (a == Mail2AuthGoogle
	    ? @"Sign In opens Google's sign-in page in the browser."
	    : @"Sign In shows a code to enter on Microsoft's sign-in page.")];
}

- (void) authChanged: (id)sender
{
	authChosen = YES;
	[self updateAuth];
}

- (Mail2Account *) accountFromFields
{
	Mail2Account *a = [Mail2Account accountForEmail: [emailField stringValue]];
	[a setFullName: [nameField stringValue]];
	[a setPassword: [passField stringValue]];
	[a setImapHost: [imapHost stringValue]];
	[a setImapPort: [imapPort intValue]];
	[a setImapUser: [imapUser stringValue]];
	[a setImapSecurity: (Mail2Security)[imapSec indexOfSelectedItem]];
	[a setSmtpHost: [smtpHost stringValue]];
	[a setSmtpPort: [smtpPort intValue]];
	[a setSmtpUser: [smtpUser stringValue]];
	[a setSmtpSecurity: (Mail2Security)[smtpSec indexOfSelectedItem]];
	[a setAuth: (Mail2Auth)[authPopup indexOfSelectedItem]];
	[a setSignature: [[sigView string] stringByTrimmingCharactersInSet: [NSCharacterSet whitespaceAndNewlineCharacterSet]]];
	/* editing an OAuth account keeps its sign-in */
	if (existing != nil && [existing auth] == [a auth] && [a usesOAuth])
		[a setRefreshToken: [existing refreshToken]];
	if ([a usesOAuth])
		[a setPassword: nil];
	return a;
}

- (void) setBusy: (BOOL)b
{
	testing = b;
	[okButton setEnabled: !b];
	[okButton setTitle: b ? @"Signing In…" : @"Sign In"];
}

- (void) signIn: (id)sender
{
	if (testing)
		return;
	if ([[emailField stringValue] rangeOfString: @"@"].location == NSNotFound) {
		[message setStringValue: @"Enter your email address."];
		return;
	}
	Mail2Auth auth = (Mail2Auth)[authPopup indexOfSelectedItem];
	if (auth == Mail2AuthPassword && [[passField stringValue] length] == 0) {
		[message setStringValue: @"Enter your password."];
		return;
	}
	if ([Mail2OAuth missingClientMessage: auth]) {
		[self updateAuth];
		return;
	}
	Mail2Account *a = [[self accountFromFields] retain];
	BOOL needSignIn = [a usesOAuth] && [[a refreshToken] length] == 0;
	[message setTextColor: [NSColor colorWithCalibratedWhite: 0.35 alpha: 1]];
	[message setStringValue: needSignIn ? [NSString stringWithFormat: @"Starting the %@ sign-in…", [Mail2OAuth providerName: auth]]
	                                    : [NSString stringWithFormat: @"Connecting to %@…", [a imapHost]]];
	[self setBusy: YES];
	if (cancelPipe[0] < 0 && pipe(cancelPipe) == 0) {
		fcntl(cancelPipe[0], F_SETFL, O_NONBLOCK);
		fcntl(cancelPipe[1], F_SETFL, O_NONBLOCK);
	}
	char junk[16];
	while (cancelPipe[0] >= 0 && read(cancelPipe[0], junk, sizeof(junk)) > 0)	/* an earlier Cancel */
		;
	int cfd = cancelPipe[0];
	dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
		NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];
		Mail2IMAP *imap = [[Mail2IMAP alloc] initWithAccount: a];
		NSString *err = nil;
		BOOL ok = YES;
		if (needSignIn)
			ok = [Mail2OAuth signIn: a prompt: ^(NSString *msg, NSString *url, NSString *code) {
				[message setStringValue: msg];
				/* Google's page, or Microsoft's code page, in the browser (Florence) */
				if (url != nil)
					[[NSWorkspace sharedWorkspace] openURL: [NSURL URLWithString: url]];
			} cancelFd: cfd error: &err];
		if (ok)
			Mail2RunOnMain(^{ [message setStringValue: [NSString stringWithFormat: @"Connecting to %@…", [a imapHost]]]; });
		ok = ok && [imap connect: &err];
		[imap disconnect];
		[imap release];
		[err retain];
		Mail2RunOnMain(^{
			[self setBusy: NO];
			if (ok) {
				ASSIGN(result, a);
				[self finish];
			} else {
				[message setTextColor: [NSColor colorWithCalibratedRed: 0.75 green: 0.1 blue: 0.1 alpha: 1]];
				[message setStringValue: err ? err : @"Cannot sign in."];
			}
			[err release];
			[a release];
		});
		[pool release];
	});
}

/* the close button is Cancel */
- (BOOL) windowShouldClose: (id)w
{
	[self cancel: w];
	return NO;
}

- (void) cancel: (id)sender
{
	if (testing) {	/* stops a sign-in waiting for the browser or the code */
		if (cancelPipe[1] >= 0)
			(void)write(cancelPipe[1], "c", 1);
		return;
	}
	DESTROY(result);
	[self finish];
}

static Mail2AccountPanel *open_panel;	/* one at a time; it keeps itself alive while open */

/* the panel goes and the caller hears the result (nil: cancelled) */
- (void) finish
{
	void (^done)(Mail2Account *) = [completion autorelease];
	completion = nil;
	[panel orderOut: nil];
	if (done)
		done(result);
	if (open_panel == self) {
		open_panel = nil;
		[self autorelease];
	}
}

/* Not modal: on this desktop a panel run with -runModalForWindow: was never painted (QEMU, 2026-11-08), while the
 * same panel shown normally is. */
+ (void) showForAccount: (Mail2Account *)existing completion: (void (^)(Mail2Account *a))done
{
	if (open_panel != nil) {
		[open_panel->panel makeKeyAndOrderFront: nil];
		return;
	}
	Mail2AccountPanel *p = [[Mail2AccountPanel alloc] init];
	open_panel = p;
	p->completion = [done copy];
	ASSIGN(p->existing, existing);
	if (existing != nil) {
		[p->authPopup selectItemAtIndex: [existing auth]];
		p->authChosen = YES;
		[p->nameField setStringValue: [existing fullName] ? [existing fullName] : @""];
		[p->emailField setStringValue: [existing email]];
		[p->passField setStringValue: [existing password] ? [existing password] : @""];
		[p fillFrom: existing];
		[p->sigView setString: [existing signature] ? [existing signature] : @""];
		[p->emailField setEditable: NO];	/* the address names the account's files */
		[p updateAuth];
	} else {
		[p->nameField setStringValue: NSFullUserName() ? NSFullUserName() : @""];
		[p->imapSec selectItemAtIndex: 0];
		[p->smtpSec selectItemAtIndex: 0];
	}
	[NSApp activateIgnoringOtherApps: YES];
	[p->panel makeKeyAndOrderFront: nil];
	redisplay_soon(p->panel);
	[p->panel makeFirstResponder: existing ? (NSView *)p->passField : (NSView *)p->emailField];
}

@end

/* ---- Mail2 > Accounts… ---- */

@implementation Mail2AccountsWindow

static NSButton *
small_button(NSView *v, NSString *title, NSRect r, id target, SEL action)
{
	NSButton *b = [[[NSButton alloc] initWithFrame: r] autorelease];
	[b setTitle: title];
	[b setBezelStyle: NSRoundedBezelStyle];
	[b setTarget: target];
	[b setAction: action];
	[v addSubview: b];
	return b;
}

- (id) initWithOwner: (id)o
{
	if ((self = [super init]) == nil)
		return nil;
	owner = o;
	panel = [[NSPanel alloc] initWithContentRect: centered(460, 300)	/* a panel: see the account panel */
	    styleMask: NSTitledWindowMask | NSClosableWindowMask | NSResizableWindowMask backing: NSBackingStoreBuffered defer: NO];
	[panel setHidesOnDeactivate: NO];
	[panel setContentView: [[[Mail2PanelBackground alloc] initWithFrame: [[panel contentView] frame]] autorelease]];
	[panel setTitle: @"Accounts"];
	[panel setReleasedWhenClosed: NO];
	[panel setMinSize: NSMakeSize(360, 200)];
	NSView *v = [panel contentView];
	NSScrollView *sv = [[[NSScrollView alloc] initWithFrame: NSMakeRect(16, 56, 428, 228)] autorelease];
	[sv setHasVerticalScroller: YES];
	[sv setBorderType: NSBezelBorder];
	[sv setAutoresizingMask: NSViewWidthSizable | NSViewHeightSizable];
	table = [[NSTableView alloc] initWithFrame: NSMakeRect(0, 0, 410, 228)];
	NSTableColumn *c1 = [[[NSTableColumn alloc] initWithIdentifier: @"email"] autorelease];
	[[c1 headerCell] setStringValue: @"Account"];
	[c1 setWidth: 270];
	[c1 setEditable: NO];
	NSTableColumn *c2 = [[[NSTableColumn alloc] initWithIdentifier: @"auth"] autorelease];
	[[c2 headerCell] setStringValue: @"Signs in with"];
	[c2 setWidth: 130];
	[c2 setEditable: NO];
	[table addTableColumn: c1];
	[table addTableColumn: c2];
	[table setRowHeight: 22];
	[table setDataSource: (id)self];
	[table setDelegate: (id)self];
	[table setTarget: self];
	[table setDoubleAction: @selector(edit:)];
	[sv setDocumentView: table];
	[v addSubview: sv];
	small_button(v, @"Add…", NSMakeRect(16, 14, 90, 28), self, @selector(add:));
	editButton = [small_button(v, @"Edit…", NSMakeRect(112, 14, 90, 28), self, @selector(edit:)) retain];
	removeButton = [small_button(v, @"Remove…", NSMakeRect(208, 14, 100, 28), self, @selector(remove:)) retain];
	[self reload];
	return self;
}

- (void) dealloc
{
	[panel release]; [table release]; [editButton release]; [removeButton release];
	[super dealloc];
}

- (void) show
{
	[self reload];
	[NSApp activateIgnoringOtherApps: YES];
	[panel makeKeyAndOrderFront: nil];
	redisplay_soon(panel);
}

- (void) reload
{
	[table reloadData];
	if ([table selectedRow] < 0 && [[owner accounts] count] > 0)
		[table selectRowIndexes: [NSIndexSet indexSetWithIndex: 0] byExtendingSelection: NO];
	[self tableViewSelectionDidChange: nil];
}

- (NSInteger) numberOfRowsInTableView: (NSTableView *)t
{
	return (NSInteger)[[owner accounts] count];
}

- (id) tableView: (NSTableView *)t objectValueForTableColumn: (NSTableColumn *)c row: (NSInteger)r
{
	NSArray *a = [owner accounts];
	if (r < 0 || r >= (NSInteger)[a count])
		return nil;
	Mail2Account *acc = [a objectAtIndex: r];
	if ([[c identifier] isEqual: @"email"])
		return [acc email];
	if (![acc usesOAuth])
		return @"Password";
	return [NSString stringWithFormat: @"%@%@", [Mail2OAuth providerName: [acc auth]],
	    [[acc refreshToken] length] ? @"" : @" (sign in again)"];
}

- (void) tableViewSelectionDidChange: (NSNotification *)n
{
	BOOL any = [table selectedRow] >= 0;
	[editButton setEnabled: any];
	[removeButton setEnabled: any];
}

- (void) add: (id)sender { [owner addAccount: sender]; [self reload]; }

- (void) edit: (id)sender
{
	NSInteger r = [table selectedRow];
	if (r >= 0)
		[owner editAccountAtIndex: (NSUInteger)r];
	[self reload];
}

- (void) remove: (id)sender
{
	NSInteger r = [table selectedRow];
	if (r >= 0)
		[owner removeAccountAtIndex: (NSUInteger)r];
	[table deselectAll: nil];
	[self reload];
}

@end
