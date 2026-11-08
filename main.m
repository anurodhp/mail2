/*
 * Mail2: a small IMAP mail client for GNUstep, on libetpan, SQLite and Mbed TLS. See README.md.
 *
 *   Mail2 [mailto:address]
 *
 * Defaults (all optional): Mail2SyncDays (days of mail fetched when a mailbox is first opened, 30),
 * Mail2PreferPlainText (NO shows the HTML part, as text, when a message has both), Mail2Debug (YES logs the
 * IMAP and SMTP conversation, passwords left out; also MAIL2_DEBUG=1).
 */
#import <AppKit/AppKit.h>
#include <signal.h>
#include <stdlib.h>
#import "Mail2Account.h"
#import "Mail2AccountPanel.h"
#import "Mail2Compose.h"
#import "Mail2Session.h"
#import "Mail2Store.h"
#import "Mail2Window.h"
#import "Mail2Util.h"

/* Exceptions raised inside the event loop are reported through an NSAlert that this theme suppresses when the text
 * is empty (Milan's main.m). Log them instead. */
@interface Mail2Application : NSApplication
@end

/* "NSTextView editing <field at y>" for a field editor, else the class */
static NSString *
responder_name(id r)
{
	if ([r isKindOfClass: [NSTextView class]] && [r isFieldEditor] && [r delegate] != nil)
		return [NSString stringWithFormat: @"field editor of %@ at y=%.0f", [[r delegate] class], NSMinY([[r delegate] frame])];
	return NSStringFromClass([r class]);
}

@implementation Mail2Application
- (void) sendEvent: (NSEvent *)e
{
	if ([e type] == NSApplicationDefined && [e subtype] == MAIL2_WAKE_SUBTYPE) {
		Mail2WakeEventHandled();
		return;
	}
	BOOL log = Mail2Debug() && ([e type] == NSLeftMouseDown || [e type] == NSLeftMouseUp || [e type] == NSKeyDown);
	if (log) {
		NSString *chars = [e type] == NSKeyDown ? [e charactersIgnoringModifiers] : @"";
		NSLog(@"Mail2: event %d '%@' (0x%x) window %ld, first responder %@", (int)[e type],
		    [chars length] && [chars characterAtIndex: 0] >= 32 ? chars : @"", [chars length] ? [chars characterAtIndex: 0] : 0,
		    (long)[e windowNumber], responder_name([[self keyWindow] firstResponder]));
	}
	[super sendEvent: e];
	if (log)
		NSLog(@"Mail2: handled; first responder %@", responder_name([[self keyWindow] firstResponder]));
}

- (void) reportException: (NSException *)e
{
	NSLog(@"MAIL2 EXCEPTION %@: %@ %@", [e name], [e reason], [e userInfo]);
}
@end

@interface Mail2App : NSObject
{
	NSMutableArray *accounts;
	NSMutableArray *sessions;
	Mail2Window *viewer;
}
@end

static NSMenuItem *
add_item(NSMenu *m, NSString *title, SEL action, NSString *key, id target)
{
	NSMenuItem *i = (NSMenuItem *)[m addItemWithTitle: title action: action keyEquivalent: key ? key : @""];
	[i setTarget: target];
	return i;
}

static NSString *
mailto_argument(void)
{
	NSArray *args = [[NSProcessInfo processInfo] arguments];
	NSUInteger i;
	for (i = 1; i < [args count]; i++) {
		NSString *a = [args objectAtIndex: i];
		if ([a hasPrefix: @"-"] && [a length] > 1) {
			i++;	/* a default and its value */
			continue;
		}
		if ([[a lowercaseString] hasPrefix: @"mailto:"])
			return [[a substringFromIndex: 7] stringByReplacingPercentEscapesUsingEncoding: NSUTF8StringEncoding];
	}
	return nil;
}

/* MAIL2_DEBUG=1: a heartbeat on the main thread's run loop and a watchdog thread that logs when it stops, with the
 * run-loop mode it was last seen in (a stuck main thread, or one inside a tracking loop) */
static volatile double heartbeat;
static NSString *volatile heartbeatMode;

@interface Mail2Watchdog : NSObject
@end
@implementation Mail2Watchdog
- (void) beat: (NSTimer *)t
{
	heartbeat = [NSDate timeIntervalSinceReferenceDate];
	heartbeatMode = [[NSRunLoop currentRunLoop] currentMode];
}
- (void) watch: (id)unused
{
	for (;;) {
		NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];
		double age;
		[NSThread sleepForTimeInterval: 5];
		age = [NSDate timeIntervalSinceReferenceDate] - heartbeat;
		if (heartbeat > 0 && age > 4)
			NSLog(@"Mail2 watchdog: main run loop silent for %.0f s, last in %@", age, heartbeatMode);
		[pool release];
	}
}
+ (void) start
{
	Mail2Watchdog *w = [[Mail2Watchdog alloc] init];
	NSTimer *t = [NSTimer timerWithTimeInterval: 1 target: w selector: @selector(beat:) userInfo: nil repeats: YES];
	NSRunLoop *rl = [NSRunLoop currentRunLoop];
	[rl addTimer: t forMode: NSDefaultRunLoopMode];
	[rl addTimer: t forMode: NSEventTrackingRunLoopMode];
	[rl addTimer: t forMode: NSModalPanelRunLoopMode];
	[NSThread detachNewThreadSelector: @selector(watch:) toTarget: w withObject: nil];
}
@end

@implementation Mail2App

- (void) startSessions
{
	NSEnumerator *e = [sessions objectEnumerator];
	Mail2Session *s;
	while ((s = [e nextObject]) != nil)
		[s stop];
	[sessions removeAllObjects];
	e = [accounts objectEnumerator];
	Mail2Account *a;
	while ((a = [e nextObject]) != nil) {
		Mail2Session *ns = [[[Mail2Session alloc] initWithAccount: a] autorelease];
		[sessions addObject: ns];
		[ns start];
	}
	if (viewer == nil)
		viewer = [[Mail2Window alloc] initWithSessions: sessions];
	else
		[viewer setSessions: sessions];
	Mail2UpdateDockBadge();
}

- (void) addAccount: (id)sender
{
	Mail2Account *a = [Mail2AccountPanel runForAccount: nil];
	if (a == nil)
		return;
	NSEnumerator *e = [accounts objectEnumerator];
	Mail2Account *old;
	while ((old = [e nextObject]) != nil)
		if ([[old identifier] isEqualToString: [a identifier]]) {
			[accounts removeObject: old];
			break;
		}
	[accounts addObject: a];
	if (![Mail2Account saveAccounts: accounts])
		NSRunAlertPanel(@"Cannot Save the Account", @"The account settings could not be written to ~/GNUstep/Library/Mail2.",
		    @"OK", nil, nil);
	[self startSessions];
}

- (void) editAccount: (id)sender
{
	if ([accounts count] == 0) {
		[self addAccount: sender];
		return;
	}
	Mail2Account *cur = [accounts objectAtIndex: 0];
	Mail2Account *a = [Mail2AccountPanel runForAccount: cur];
	if (a == nil)
		return;
	[accounts replaceObjectAtIndex: 0 withObject: a];
	[Mail2Account saveAccounts: accounts];
	[self startSessions];
}

- (void) removeAccount: (id)sender
{
	if ([accounts count] == 0)
		return;
	Mail2Account *a = [accounts lastObject];
	if (NSRunAlertPanel(@"Remove Account?", @"Remove %@ from Mail2? Its downloaded mail is deleted from this computer; "
	    "nothing changes on the server.", @"Remove", @"Cancel", nil, [a email]) != NSAlertDefaultReturn)
		return;
	[[Mail2Store sharedStore] removeAccount: [a identifier]];
	[accounts removeObject: a];
	[Mail2Account saveAccounts: accounts];
	[self startSessions];
}

- (void) showViewer: (id)sender
{
	[[viewer window] makeKeyAndOrderFront: nil];
}

- (void) showAbout: (id)sender
{
	NSDictionary *opts = [NSDictionary dictionaryWithObjectsAndKeys:
	    @"Mail2", @"ApplicationName",
	    @"A small IMAP mail client for GNUstep.", @"ApplicationDescription",
	    @"0.2", @"ApplicationRelease",
	    [NSArray arrayWithObject: @"Anurodh Pokharel"], @"Authors",
	    @"Copyright © 2026 Anurodh Pokharel. MIT license.", @"Copyright",
	    @"Mail by libetpan 1.9.4 (BSD), SQLite 3.44 (public domain) and Mbed TLS 3.6 (Apache-2.0). Icons from Lucide (ISC).",
	    @"CopyrightDescription", nil];
	[NSApp orderFrontStandardAboutPanelWithOptions: opts];
}

/* the viewer's actions, from the menus */
- (void) getMail: (id)s { [viewer getMail: s]; }
- (void) compose: (id)s { [viewer compose: s]; }
- (void) reply: (id)s { [viewer reply: s]; }
- (void) replyAll: (id)s { [viewer replyAll: s]; }
- (void) forward: (id)s { [viewer forward: s]; }
- (void) archive: (id)s { [viewer archive: s]; }
- (void) deleteMessages: (id)s { [viewer deleteMessages: s]; }
- (void) toggleFlag: (id)s { [viewer toggleFlag: s]; }
- (void) toggleRead: (id)s { [viewer toggleRead: s]; }
- (void) getOlderMessages: (id)s { [viewer getOlderMessages: s]; }
- (void) focusSearch: (id)s { [viewer focusSearch: s]; }
- (void) toggleConversations: (id)s { [viewer toggleConversations: s]; }
- (void) editDraft: (id)s { [viewer editDraft: s]; }

- (BOOL) validateMenuItem: (NSMenuItem *)i
{
	SEL a = [i action];
	if (a == @selector(removeAccount:) || a == @selector(editAccount:))
		return [accounts count] > 0;
	if (a == @selector(toggleConversations:)) {
		[i setState: [Mail2Window organizesByConversation] ? NSOnState : NSOffState];
		return YES;
	}
	if (a == @selector(focusSearch:))
		return viewer != nil;
	if ([viewer respondsToSelector: a] && a != @selector(window))
		return [viewer validateAction: a];
	return YES;
}

- (void) buildMenus
{
	NSMenu *main = [[NSMenu alloc] initWithTitle: @"Mail2"], *m;
	NSMenuItem *it;

	m = [[NSMenu alloc] initWithTitle: @"Mail2"];
	add_item(m, @"About Mail2", @selector(showAbout:), nil, self);
	add_item(m, @"Add Account…", @selector(addAccount:), nil, self);
	add_item(m, @"Account Settings…", @selector(editAccount:), @",", self);
	add_item(m, @"Remove Account…", @selector(removeAccount:), nil, self);
	add_item(m, @"Hide Mail2", @selector(hide:), @"h", NSApp);
	add_item(m, @"Quit Mail2", @selector(terminate:), @"q", NSApp);
	[main setSubmenu: m forItem: add_item(main, @"Mail2", NULL, nil, nil)]; [m release];

	m = [[NSMenu alloc] initWithTitle: @"File"];
	add_item(m, @"New Message", @selector(compose:), @"n", self);
	add_item(m, @"Viewer Window", @selector(showViewer:), @"0", self);
	add_item(m, @"Attach File…", @selector(attachFile:), nil, nil);		/* to the compose window in front */
	add_item(m, @"Save as Draft", @selector(saveDraft:), @"s", nil);
	add_item(m, @"Close Window", @selector(performClose:), @"w", nil);
	[main setSubmenu: m forItem: add_item(main, @"File", NULL, nil, nil)]; [m release];

	m = [[NSMenu alloc] initWithTitle: @"Edit"];
	add_item(m, @"Undo", @selector(undo:), @"z", nil);
	add_item(m, @"Cut", @selector(cut:), @"x", nil);
	add_item(m, @"Copy", @selector(copy:), @"c", nil);
	add_item(m, @"Paste", @selector(paste:), @"v", nil);
	add_item(m, @"Select All", @selector(selectAll:), @"a", nil);
	add_item(m, @"Find…", @selector(focusSearch:), @"f", self);
	[main setSubmenu: m forItem: add_item(main, @"Edit", NULL, nil, nil)]; [m release];

	m = [[NSMenu alloc] initWithTitle: @"View"];
	add_item(m, @"Organize by Conversation", @selector(toggleConversations:), nil, self);
	[main setSubmenu: m forItem: add_item(main, @"View", NULL, nil, nil)]; [m release];

	m = [[NSMenu alloc] initWithTitle: @"Mailbox"];
	it = add_item(m, @"Get All New Mail", @selector(getMail:), @"N", self);
	add_item(m, @"Get Older Messages", @selector(getOlderMessages:), nil, self);
	[main setSubmenu: m forItem: add_item(main, @"Mailbox", NULL, nil, nil)]; [m release];

	m = [[NSMenu alloc] initWithTitle: @"Message"];
	add_item(m, @"Edit Draft", @selector(editDraft:), @"e", self);
	add_item(m, @"Reply", @selector(reply:), @"r", self);
	add_item(m, @"Reply All", @selector(replyAll:), @"R", self);
	add_item(m, @"Forward", @selector(forward:), @"F", self);
	add_item(m, @"Archive", @selector(archive:), @"A", self);
	add_item(m, @"Move to Trash", @selector(deleteMessages:), nil, self);
	add_item(m, @"Mark as Read/Unread", @selector(toggleRead:), @"U", self);
	add_item(m, @"Flag/Unflag", @selector(toggleFlag:), @"L", self);
	[main setSubmenu: m forItem: add_item(main, @"Message", NULL, nil, nil)]; [m release];

	m = [[NSMenu alloc] initWithTitle: @"Windows"];
	add_item(m, @"Minimize", @selector(performMiniaturize:), @"m", nil);
	[main setSubmenu: m forItem: add_item(main, @"Windows", NULL, nil, nil)];
	[NSApp setWindowsMenu: m];
	[m release];

	[NSApp setMainMenu: main];
	[main release];
	(void)it;
}

- (void) applicationDidFinishLaunching: (NSNotification *)n
{
	[self buildMenus];
	if (Mail2Debug())
		[Mail2Watchdog start];
	accounts = [[NSMutableArray alloc] initWithArray: [Mail2Account loadAccounts]];
	NSLog(@"Mail2: %lu account(s) in %@", (unsigned long)[accounts count], Mail2SupportDirectory());
	sessions = [[NSMutableArray alloc] init];
	if ([Mail2Store sharedStore] == nil) {
		NSRunAlertPanel(@"Mail2 Cannot Start", @"The mail index in ~/GNUstep/Library/Mail2 could not be opened.", @"Quit", nil, nil);
		[NSApp terminate: nil];
		return;
	}
	if ([accounts count] == 0) {
		Mail2Account *a = [Mail2AccountPanel runForAccount: nil];
		if (a != nil) {
			[accounts addObject: a];
			[Mail2Account saveAccounts: accounts];
		}
	}
	[self startSessions];
	NSString *to = mailto_argument();
	if (to != nil && [sessions count] > 0)
		[Mail2Compose newMessageWithSessions: sessions to: to];
}

/* mailto: from Milan or Florence (NSWorkspace openURL / openFile) */
- (BOOL) application: (NSApplication *)app openFile: (NSString *)file
{
	if ([[file lowercaseString] hasPrefix: @"mailto:"] && [sessions count] > 0) {
		[Mail2Compose newMessageWithSessions: sessions to: [[file substringFromIndex: 7]
		    stringByReplacingPercentEscapesUsingEncoding: NSUTF8StringEncoding]];
		return YES;
	}
	return NO;
}

- (BOOL) applicationShouldTerminateAfterLastWindowClosed: (NSApplication *)a
{
	return NO;	/* keeps checking mail and the dock badge; quit with Cmd-Q */
}

- (BOOL) applicationShouldHandleReopen: (NSApplication *)a hasVisibleWindows: (BOOL)visible
{
	[self showViewer: nil];
	return NO;
}

- (void) applicationWillTerminate: (NSNotification *)n
{
	NSEnumerator *e = [sessions objectEnumerator];
	Mail2Session *s;
	while ((s = [e nextObject]) != nil)
		[s stop];
	Mail2ClearDockBadge();
}

@end

/* with MAIL2_DEBUG=1, SIGUSR1 exits at once through exit(), so atexit reports (iokit's sample_prof.dylib) are written
 * even when the main thread is stuck */
static void
debug_exit(int sig)
{
	exit(3);
}

int
main(int argc, const char *argv[])
{
	NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];
	if (getenv("MAIL2_DEBUG") && *getenv("MAIL2_DEBUG") == '1')
		signal(SIGUSR1, debug_exit);
	Mail2App *delegate;
	[Mail2Application sharedApplication];
	delegate = [[Mail2App alloc] init];
	[NSApp setDelegate: delegate];
	[NSApp run];
	[pool release];
	return 0;
}
