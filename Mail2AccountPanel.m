/* Mail2AccountPanel: the add/edit account panel (see Mail2AccountPanel.h). */
#import "Mail2AccountPanel.h"
#import "Mail2IMAP.h"
#import "Mail2Util.h"
#import "Mail2Views.h"
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

@implementation Mail2AccountPanel

- (id) init
{
	if ((self = [super init]) == nil)
		return nil;
	panel = [[Mail2KeyOrderPanel alloc] initWithContentRect: NSMakeRect(0, 0, 480, 470)
	    styleMask: NSTitledWindowMask backing: NSBackingStoreBuffered defer: NO];
	[panel setTitle: @"Mail Account"];
	NSView *v = [panel contentView];
	CGFloat y = 430, lx = 16, lw = 110, fx = 132, fw = 330;

	make_label(v, @"Sign in to your mail account. For Gmail, iCloud and Yahoo, use an app password.",
	    NSMakeRect(lx, y, 448, 18), NO);
	[[[v subviews] lastObject] setAlignment: NSLeftTextAlignment];
	y -= 34;
	make_label(v, @"Full Name:", NSMakeRect(lx, y, lw, 18), NO);
	nameField = [make_field(v, NSMakeRect(fx, y - 2, fw, 22)) retain];
	y -= 30;
	make_label(v, @"Email Address:", NSMakeRect(lx, y, lw, 18), NO);
	emailField = [make_field(v, NSMakeRect(fx, y - 2, fw, 22)) retain];
	[emailField setDelegate: (id)self];
	y -= 30;
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

	y -= 46;
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
	[smtpUser setNextKeyView: nameField];
	return self;
}

- (void) dealloc
{
	[panel release]; [nameField release]; [emailField release]; [passField release];
	[imapHost release]; [imapPort release]; [imapUser release]; [imapSec release];
	[smtpHost release]; [smtpPort release]; [smtpUser release]; [smtpSec release];
	[message release]; [okButton release]; [cancelButton release]; [autoDomain release]; [result release];
	[super dealloc];
}

- (NSArray *) fieldOrder
{
	return [NSArray arrayWithObjects: nameField, emailField, passField, imapHost, imapPort, imapUser, smtpHost, smtpPort,
	    smtpUser, nil];
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
	if ([[passField stringValue] length] == 0) {
		[message setStringValue: @"Enter your password."];
		return;
	}
	Mail2Account *a = [[self accountFromFields] retain];
	[message setTextColor: [NSColor colorWithCalibratedWhite: 0.35 alpha: 1]];
	[message setStringValue: [NSString stringWithFormat: @"Connecting to %@…", [a imapHost]]];
	[self setBusy: YES];
	dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
		NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];
		Mail2IMAP *imap = [[Mail2IMAP alloc] initWithAccount: a];
		NSString *err = nil;
		BOOL ok = [imap connect: &err];
		[imap disconnect];
		[imap release];
		[err retain];
		Mail2RunOnMain(^{
			[self setBusy: NO];
			if (ok) {
				ASSIGN(result, a);
				[NSApp stopModal];
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

- (void) cancel: (id)sender
{
	if (testing)
		return;
	DESTROY(result);
	[NSApp stopModal];
}

+ (Mail2Account *) runForAccount: (Mail2Account *)existing
{
	Mail2AccountPanel *p = [[[Mail2AccountPanel alloc] init] autorelease];
	if (existing != nil) {
		[p->nameField setStringValue: [existing fullName] ? [existing fullName] : @""];
		[p->emailField setStringValue: [existing email]];
		[p->passField setStringValue: [existing password] ? [existing password] : @""];
		[p fillFrom: existing];
		[p->emailField setEditable: NO];	/* the address names the account's files */
	} else {
		[p->nameField setStringValue: NSFullUserName() ? NSFullUserName() : @""];
		[p->imapSec selectItemAtIndex: 0];
		[p->smtpSec selectItemAtIndex: 0];
	}
	[p->panel center];
	[p->panel makeKeyAndOrderFront: nil];
	[p->panel makeFirstResponder: existing ? (NSView *)p->passField : (NSView *)p->emailField];
	[NSApp runModalForWindow: p->panel];
	[p->panel orderOut: nil];
	return [[p->result retain] autorelease];
}

@end
