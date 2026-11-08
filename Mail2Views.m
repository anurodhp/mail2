/* Mail2Views: sidebar and message-list rows, the message pane (see Mail2Views.h). */
#import "Mail2Views.h"
#import "Mail2Util.h"
#import "MilanText.h"
#import "Mail2OAuth.h"
#include <dlfcn.h>
#include <unistd.h>

static int web_state;	/* 0 not tried, 1 loaded and running, -1 failed */

static const char *
floweb_path(void)
{
	const char *p = getenv("MAIL2_FLOWEB");
	return p && *p ? p : "/usr/local/lib/libFloWeb.1.dylib";
}

BOOL
Mail2WebViewInstalled(void)
{
	return web_state >= 0 && access(floweb_path(), R_OK) == 0;
}

Class
Mail2WebViewClass(void)
{
	static Class cls;
	if (web_state != 0)
		return web_state > 0 ? cls : Nil;
	web_state = -1;
	if (dlopen(floweb_path(), RTLD_NOW | RTLD_GLOBAL) == NULL) {
		NSLog(@"Mail2: no WebKit for HTML mail (%s): %s", floweb_path(), dlerror());
		return Nil;
	}
	cls = NSClassFromString(@"FloWebView");
	NSString *dir = [Mail2SupportDirectory() stringByAppendingPathComponent: @"Web"];
	if (cls == Nil || ![(id)cls startEngineWithDirectory: dir]) {
		NSLog(@"Mail2: WebKit did not start; HTML mail is shown as text");
		cls = Nil;
		return Nil;
	}
	web_state = 1;
	return cls;
}

/* what FloWebView.h declares; called through id */
@interface NSObject (Mail2FloWebView)
+ (BOOL) startEngineWithDirectory: (NSString *)dir;
- (void) setDelegate: (id)d;
- (void) loadHTMLString: (NSString *)html;
- (void) setAllowsRemoteContent: (BOOL)yes;
@end


/* the strip over an HTML message whose remote content was held back */
@interface Mail2RemoteBar : NSView
@end
@implementation Mail2RemoteBar
- (void) drawRect: (NSRect)r
{
	[[NSColor colorWithCalibratedRed: 1.0 green: 0.97 blue: 0.85 alpha: 1] set];
	NSRectFill([self bounds]);
	[[NSColor colorWithCalibratedRed: 0.90 green: 0.84 blue: 0.62 alpha: 1] set];
	NSRectFill(NSMakeRect(0, 0, NSWidth([self bounds]), 1));
}
@end

NSImage *
Mail2Icon(NSString *name)
{
	static NSMutableDictionary *cache;
	NSImage *i;
	if (cache == nil)
		cache = [[NSMutableDictionary alloc] init];
	if ((i = [cache objectForKey: name]) == nil) {
		NSString *p = [[NSBundle mainBundle] pathForResource: name ofType: @"tiff"];
		i = p ? [[[NSImage alloc] initWithContentsOfFile: p] autorelease] : nil;
		if (i == nil)
			return nil;
		[cache setObject: i forKey: name];
	}
	return i;
}

NSAttributedString *
Mail2FittedString(NSString *s, NSDictionary *attrs, CGFloat width)
{
	NSAttributedString *a;
	NSUInteger lo, hi;
	if (s == nil)
		s = @"";
	a = MilanDisplayString(s, attrs);
	if ([a size].width <= width)
		return a;
	/* the longest prefix that fits with "…" */
	lo = 0;
	hi = [s length];
	while (lo < hi) {
		NSUInteger mid = (lo + hi + 1) / 2;
		NSRange r = [s rangeOfComposedCharacterSequencesForRange: NSMakeRange(0, mid)];
		NSString *t = [[[s substringWithRange: r] stringByTrimmingCharactersInSet: [NSCharacterSet whitespaceCharacterSet]]
		    stringByAppendingString: @"…"];
		if ([MilanDisplayString(t, attrs) size].width <= width)
			lo = mid;
		else
			hi = mid - 1;
	}
	return MilanDisplayString([[[s substringToIndex: lo] stringByTrimmingCharactersInSet: [NSCharacterSet whitespaceCharacterSet]]
	    stringByAppendingString: @"…"], attrs);
}

static NSColor *
accent(void)
{
	return [NSColor colorWithCalibratedRed: 0.18 green: 0.50 blue: 0.85 alpha: 1];
}

static NSColor *
gray(void)
{
	return [NSColor colorWithCalibratedWhite: 0.45 alpha: 1];
}

/* ---- the tables ---- */

@implementation Mail2Table

- (void) setSidebarStyle: (BOOL)s
{
	sidebarStyle = s;
	if (s)
		[self setBackgroundColor: [NSColor colorWithCalibratedRed: 0.93 green: 0.94 blue: 0.96 alpha: 1]];
}

- (void) highlightSelectionInClipRect: (NSRect)clip
{
	NSIndexSet *rows = [self selectedRowIndexes];
	NSUInteger i;
	BOOL key = [[self window] isKeyWindow] && [[self window] firstResponder] == self;
	[(key || sidebarStyle ? accent() : [NSColor colorWithCalibratedWhite: 0.80 alpha: 1]) set];
	for (i = [rows firstIndex]; i != NSNotFound; i = [rows indexGreaterThanIndex: i]) {
		NSRect r = NSInsetRect([self rectOfRow: (NSInteger)i], sidebarStyle ? 6 : 4, sidebarStyle ? 1 : 2);
		if (NSIntersectsRect(r, clip))
			[[NSBezierPath bezierPathWithRoundedRect: r xRadius: 6 yRadius: 6] fill];
	}
}

- (BOOL) becomeFirstResponder
{
	[self setNeedsDisplay: YES];
	return [super becomeFirstResponder];
}

- (BOOL) resignFirstResponder
{
	[self setNeedsDisplay: YES];
	return [super resignFirstResponder];
}

- (void) keyDown: (NSEvent *)ev
{
	NSString *k = [ev charactersIgnoringModifiers];
	unichar c = [k length] ? [k characterAtIndex: 0] : 0;
	id d = [self delegate];
	if ((c == NSDeleteCharacter || c == NSBackspaceCharacter || c == NSDeleteFunctionKey) &&
	    [d respondsToSelector: @selector(tableDeleteKey:)]) {
		[d performSelector: @selector(tableDeleteKey:) withObject: self];
		return;
	}
	if ((c == '\r' || c == NSEnterCharacter) && [d respondsToSelector: @selector(tableReturnKey:)]) {
		[d performSelector: @selector(tableReturnKey:) withObject: self];
		return;
	}
	[super keyDown: ev];
}

@end

/* ---- sidebar rows ---- */

static NSString *
mailbox_icon(Mail2Mailbox *m)
{
	NSString *s = [m special];
	if ([s isEqualToString: @"inbox"] || [s isEqualToString: @"allinboxes"]) return @"sb-inbox";
	if ([s isEqualToString: @"flaggedsmart"]) return @"sb-flag";
	if ([s isEqualToString: @"drafts"]) return @"sb-drafts";
	if ([s isEqualToString: @"sent"]) return @"sb-sent";
	if ([s isEqualToString: @"archive"] || [s isEqualToString: @"all"]) return @"sb-archive";
	if ([s isEqualToString: @"junk"]) return @"sb-junk";
	if ([s isEqualToString: @"trash"]) return @"sb-trash";
	return @"sb-folder";
}

@implementation Mail2SidebarCell

- (id) copyWithZone: (NSZone *)z
{
	Mail2SidebarCell *c = [super copyWithZone: z];
	c->item = [item retain];
	return c;
}

- (void) dealloc { [item release]; [super dealloc]; }

- (void) setItem: (id)i selected: (BOOL)s
{
	ASSIGN(item, i);
	selected = s;
}

- (void) drawWithFrame: (NSRect)f inView: (NSView *)v
{
	if ([item isKindOfClass: [NSString class]]) {
		/* an account heading */
		NSDictionary *a = [NSDictionary dictionaryWithObjectsAndKeys: [NSFont boldSystemFontOfSize: 11], NSFontAttributeName,
		    gray(), NSForegroundColorAttributeName, nil];
		[Mail2FittedString([item uppercaseString], a, NSWidth(f) - 20) drawAtPoint: NSMakePoint(NSMinX(f) + 12, NSMinY(f) + ([v isFlipped] ? 8 : 4))];
		return;
	}
	Mail2Mailbox *m = item;
	CGFloat x = NSMinX(f) + 14 + 14 * [m depth];
	NSImage *icon = Mail2Icon(selected ? [mailbox_icon(m) stringByAppendingString: @"-sel"] : mailbox_icon(m));
	[icon drawInRect: NSMakeRect(x, NSMinY(f) + (NSHeight(f) - 16) / 2, 16, 16) fromRect: NSZeroRect
	    operation: NSCompositeSourceOver fraction: [m selectable] ? 1 : 0.4 respectFlipped: YES hints: nil];
	x += 24;
	CGFloat right = NSMaxX(f) - 14;
	if ([m unread] > 0) {
		NSDictionary *ca = [NSDictionary dictionaryWithObjectsAndKeys: [NSFont systemFontOfSize: 11], NSFontAttributeName,
		    selected ? [NSColor whiteColor] : gray(), NSForegroundColorAttributeName, nil];
		NSAttributedString *cs = [[[NSAttributedString alloc] initWithString:
		    [NSString stringWithFormat: @"%d", [m unread]] attributes: ca] autorelease];
		NSSize sz = [cs size];
		[cs drawAtPoint: NSMakePoint(right - sz.width, NSMinY(f) + (NSHeight(f) - sz.height) / 2)];
		right -= sz.width + 8;
	}
	NSDictionary *ta = [NSDictionary dictionaryWithObjectsAndKeys:
	    [m unread] > 0 && [[m special] isEqualToString: @"inbox"] ? [NSFont boldSystemFontOfSize: 13] : [NSFont systemFontOfSize: 13],
	    NSFontAttributeName,
	    selected ? [NSColor whiteColor] : ([m selectable] ? [NSColor blackColor] : gray()), NSForegroundColorAttributeName, nil];
	NSAttributedString *t = Mail2FittedString([m displayName], ta, right - x);
	[t drawAtPoint: NSMakePoint(x, NSMinY(f) + (NSHeight(f) - [t size].height) / 2)];
}

@end

/* ---- message list rows ---- */

@implementation Mail2MessageCell

- (id) copyWithZone: (NSZone *)z
{
	Mail2MessageCell *c = [super copyWithZone: z];
	c->msg = [msg retain];
	return c;
}

- (void) dealloc { [msg release]; [super dealloc]; }

- (void) setMessage: (Mail2MessageInfo *)m selected: (BOOL)s
{
	[self setMessage: m selected: s child: NO count: 1];
}

- (void) setMessage: (Mail2MessageInfo *)m selected: (BOOL)s child: (BOOL)c count: (int)n
{
	ASSIGN(msg, m);
	selected = s;
	child = c;
	count = n;
}

- (void) drawWithFrame: (NSRect)f inView: (NSView *)v
{
	NSColor *fg = selected ? [NSColor whiteColor] : [NSColor blackColor];
	NSColor *dim = selected ? [NSColor colorWithCalibratedWhite: 0.92 alpha: 1] : gray();
	BOOL flipped = [v isFlipped];
	if (child) {	/* inside an opened conversation: a tinted, indented row */
		if (!selected) {
			[[NSColor colorWithCalibratedRed: 0.96 green: 0.97 blue: 0.99 alpha: 1] set];
			NSRectFill(f);
		}
		f.origin.x += 14;
		f.size.width -= 14;
	}
	CGFloat left = NSMinX(f) + 22, right = NSMaxX(f) - 12, y = NSMinY(f) + 6;

	/* the separator under the row */
	if (!selected) {
		[[NSColor colorWithCalibratedWhite: 0.88 alpha: 1] set];
		NSRectFill(NSMakeRect(left, flipped ? NSMaxY(f) - 1 : NSMinY(f), NSMaxX(f) - left, 1));
	}
	if ([msg isUnread] || (count > 1 && [msg threadUnread] > 0)) {
		[(selected ? [NSColor whiteColor] : accent()) set];
		[[NSBezierPath bezierPathWithOvalInRect: NSMakeRect(NSMinX(f) + 8, (flipped ? y + 4 : NSMaxY(f) - y - 13), 9, 9)] fill];
	}
	if ([msg flags] & Mail2FlagFlagged) {
		[[NSColor colorWithCalibratedRed: 0.96 green: 0.55 blue: 0.10 alpha: 1] set];
		[[NSBezierPath bezierPathWithOvalInRect: NSMakeRect(NSMinX(f) + 9, (flipped ? y + 22 : NSMaxY(f) - y - 29), 7, 7)] fill];
	}

	/* line 1: sender, date (and a paperclip) */
	NSDictionary *da = [NSDictionary dictionaryWithObjectsAndKeys: [NSFont systemFontOfSize: 11], NSFontAttributeName,
	    dim, NSForegroundColorAttributeName, nil];
	NSAttributedString *ds = [[[NSAttributedString alloc] initWithString: Mail2ListDate([msg date]) attributes: da] autorelease];
	NSSize dsz = [ds size];
	CGFloat line1 = flipped ? y : NSMaxY(f) - y - 16;
	[ds drawAtPoint: NSMakePoint(right - dsz.width, line1 + 1)];
	CGFloat senderRight = right - dsz.width - 8;
	if (count > 1) {	/* the conversation's message count, in a gray pill */
		NSDictionary *ca = [NSDictionary dictionaryWithObjectsAndKeys: [NSFont boldSystemFontOfSize: 10], NSFontAttributeName,
		    selected ? accent() : [NSColor whiteColor], NSForegroundColorAttributeName, nil];
		NSAttributedString *cs = [[[NSAttributedString alloc] initWithString: [NSString stringWithFormat: @"%d", count]
		    attributes: ca] autorelease];
		NSSize csz = [cs size];
		NSRect pill = NSMakeRect(senderRight - csz.width - 10, line1 + 1, csz.width + 10, 14);
		[(selected ? [NSColor whiteColor] : [NSColor colorWithCalibratedWhite: 0.62 alpha: 1]) set];
		[[NSBezierPath bezierPathWithRoundedRect: pill xRadius: 7 yRadius: 7] fill];
		[cs drawAtPoint: NSMakePoint(NSMinX(pill) + 5, NSMinY(pill) + (14 - csz.height) / 2)];
		senderRight = NSMinX(pill) - 6;
	}
	if ([msg hasAttachment]) {
		NSImage *clip = Mail2Icon(selected ? @"sb-attachment-sel" : @"sb-attachment");
		[clip drawInRect: NSMakeRect(senderRight - 13, line1 + 2, 12, 12) fromRect: NSZeroRect
		    operation: NSCompositeSourceOver fraction: 0.8 respectFlipped: YES hints: nil];
		senderRight -= 18;
	}
	NSDictionary *sa = [NSDictionary dictionaryWithObjectsAndKeys: [NSFont boldSystemFontOfSize: 13], NSFontAttributeName,
	    fg, NSForegroundColorAttributeName, nil];
	/* in Drafts and Sent the recipients matter, as in Apple Mail */
	NSString *who = [msg isDraft] ? ([[msg to] length] ? [msg to] : @"Draft") : [msg sender];
	[Mail2FittedString(who, sa, senderRight - left) drawAtPoint: NSMakePoint(left, line1)];

	/* line 2: subject */
	NSDictionary *ja = [NSDictionary dictionaryWithObjectsAndKeys: [NSFont systemFontOfSize: 12], NSFontAttributeName,
	    fg, NSForegroundColorAttributeName, nil];
	NSString *subj = [[msg subject] length] ? [msg subject] : @"(no subject)";
	[Mail2FittedString(subj, ja, right - left) drawAtPoint: NSMakePoint(left, flipped ? y + 18 : NSMaxY(f) - y - 34)];

	/* line 3: the start of the body, once downloaded */
	NSString *sn = [msg snippet];
	if ([sn length]) {
		NSDictionary *na = [NSDictionary dictionaryWithObjectsAndKeys: [NSFont systemFontOfSize: 11], NSFontAttributeName,
		    dim, NSForegroundColorAttributeName, nil];
		[Mail2FittedString(sn, na, right - left) drawAtPoint: NSMakePoint(left, flipped ? y + 35 : NSMaxY(f) - y - 50)];
	}
}

@end

/* ---- the message pane ---- */

@interface Mail2HeaderView : NSView
{
	Mail2MessageInfo *msg;
}
- (void) setMessage: (Mail2MessageInfo *)m;
@end

static NSString *
initials(NSString *name)
{
	NSMutableString *r = [NSMutableString string];
	NSEnumerator *e = [[name componentsSeparatedByCharactersInSet: [NSCharacterSet whitespaceCharacterSet]] objectEnumerator];
	NSString *w;
	while ((w = [e nextObject]) != nil && [r length] < 2)
		if ([w length] && [[NSCharacterSet letterCharacterSet] characterIsMember: [w characterAtIndex: 0]])
			[r appendString: [[w substringToIndex: 1] uppercaseString]];
	return [r length] ? r : @"?";
}

@implementation Mail2HeaderView

- (BOOL) isFlipped { return YES; }
- (void) dealloc { [msg release]; [super dealloc]; }
- (void) setMessage: (Mail2MessageInfo *)m { ASSIGN(msg, m); [self setNeedsDisplay: YES]; }

- (void) drawRect: (NSRect)r
{
	NSRect b = [self bounds];
	[[NSColor whiteColor] set];
	NSRectFill(r);
	[[NSColor colorWithCalibratedWhite: 0.86 alpha: 1] set];
	NSRectFill(NSMakeRect(16, NSMaxY(b) - 1, NSWidth(b) - 32, 1));
	if (msg == nil)
		return;

	/* the sender's initials in a circle, as Apple Mail does */
	NSRect av = NSMakeRect(16, 14, 40, 40);
	[[NSColor colorWithCalibratedRed: 0.62 green: 0.66 blue: 0.72 alpha: 1] set];
	[[NSBezierPath bezierPathWithOvalInRect: av] fill];
	NSDictionary *ia = [NSDictionary dictionaryWithObjectsAndKeys: [NSFont boldSystemFontOfSize: 15], NSFontAttributeName,
	    [NSColor whiteColor], NSForegroundColorAttributeName, nil];
	NSAttributedString *in = [[[NSAttributedString alloc] initWithString: initials([msg sender]) attributes: ia] autorelease];
	[in drawAtPoint: NSMakePoint(NSMidX(av) - [in size].width / 2, NSMidY(av) - [in size].height / 2)];

	CGFloat x = 68, right = NSWidth(b) - 16, y = 12;
	NSDictionary *da = [NSDictionary dictionaryWithObjectsAndKeys: [NSFont systemFontOfSize: 11], NSFontAttributeName,
	    gray(), NSForegroundColorAttributeName, nil];
	NSAttributedString *ds = [[[NSAttributedString alloc] initWithString: Mail2LongDate([msg date]) attributes: da] autorelease];
	[ds drawAtPoint: NSMakePoint(right - [ds size].width, y + 2)];

	NSString *from = [[msg fromName] length] ? [NSString stringWithFormat: @"%@ <%@>", [msg fromName], [msg fromAddr]]
	                                         : ([msg fromAddr] ? [msg fromAddr] : @"");
	NSDictionary *fa = [NSDictionary dictionaryWithObjectsAndKeys: [NSFont boldSystemFontOfSize: 14], NSFontAttributeName,
	    [NSColor blackColor], NSForegroundColorAttributeName, nil];
	[Mail2FittedString(from, fa, right - x - [ds size].width - 12) drawAtPoint: NSMakePoint(x, y)];
	y += 20;
	NSDictionary *sa = [NSDictionary dictionaryWithObjectsAndKeys: [NSFont systemFontOfSize: 13], NSFontAttributeName,
	    [NSColor blackColor], NSForegroundColorAttributeName, nil];
	[Mail2FittedString([[msg subject] length] ? [msg subject] : @"(no subject)", sa, right - x) drawAtPoint: NSMakePoint(x, y)];
	y += 19;
	NSDictionary *la = [NSDictionary dictionaryWithObjectsAndKeys: [NSFont systemFontOfSize: 11], NSFontAttributeName,
	    gray(), NSForegroundColorAttributeName, nil];
	if ([[msg to] length]) {
		[Mail2FittedString([@"To: " stringByAppendingString: [msg to]], la, right - x) drawAtPoint: NSMakePoint(x, y)];
		y += 16;
	}
	if ([[msg cc] length])
		[Mail2FittedString([@"Cc: " stringByAppendingString: [msg cc]], la, right - x) drawAtPoint: NSMakePoint(x, y)];
}

@end

@implementation Mail2MessageView

- (BOOL) isFlipped { return YES; }

- (id) initWithFrame: (NSRect)fr
{
	if ((self = [super initWithFrame: fr]) == nil)
		return nil;
	header = [[Mail2HeaderView alloc] initWithFrame: NSMakeRect(0, 0, NSWidth(fr), 96)];
	[header setAutoresizingMask: NSViewWidthSizable];
	[self addSubview: header];
	attachBar = [[NSView alloc] initWithFrame: NSMakeRect(0, 96, NSWidth(fr), 0)];
	[attachBar setAutoresizingMask: NSViewWidthSizable];
	[self addSubview: attachBar];
	scroll = [[NSScrollView alloc] initWithFrame: NSMakeRect(0, 96, NSWidth(fr), NSHeight(fr) - 96)];
	[scroll setHasVerticalScroller: YES];
	[scroll setAutohidesScrollers: YES];
	[scroll setBorderType: NSNoBorder];
	[scroll setAutoresizingMask: NSViewWidthSizable | NSViewHeightSizable];
	NSSize cs = [scroll contentSize];
	text = [[NSTextView alloc] initWithFrame: NSMakeRect(0, 0, cs.width, cs.height)];
	[text setEditable: NO];
	[text setSelectable: YES];
	[text setRichText: NO];
	[text setTextContainerInset: NSMakeSize(14, 12)];
	[text setMinSize: NSMakeSize(0, cs.height)];
	[text setMaxSize: NSMakeSize(1e7, 1e7)];
	[text setVerticallyResizable: YES];
	[text setHorizontallyResizable: NO];
	[text setAutoresizingMask: NSViewWidthSizable];
	[[text textContainer] setWidthTracksTextView: YES];
	[scroll setDocumentView: text];
	[self addSubview: scroll];
	empty = [[NSTextField alloc] initWithFrame: NSMakeRect(0, NSHeight(fr) / 2 - 12, NSWidth(fr), 24)];
	[empty setEditable: NO];
	[empty setSelectable: NO];
	[empty setBezeled: NO];
	[empty setDrawsBackground: NO];
	[empty setAlignment: NSCenterTextAlignment];
	[empty setFont: [NSFont systemFontOfSize: 16]];
	[empty setTextColor: gray()];
	[empty setAutoresizingMask: NSViewWidthSizable | NSViewMinYMargin | NSViewMaxYMargin];
	[self addSubview: empty];
	[self showNothing: @"No Message Selected"];
	return self;
}

- (void) dealloc
{
	[header release]; [attachBar release]; [scroll release]; [text release]; [empty release];
	[msg release]; [attachments release]; [web release]; [inlineParts release]; [remoteBar release];
	[unsubButton release]; [shown release];
	[super dealloc];
}

- (void) drawRect: (NSRect)r
{
	[[NSColor whiteColor] set];
	NSRectFill(r);
}

- (Mail2MessageInfo *) message { return msg; }
- (NSTextView *) textView { return text; }

- (void) showNothing: (NSString *)why
{
	DESTROY(msg);
	DESTROY(attachments);
	[header setHidden: YES];
	[attachBar setHidden: YES];
	[scroll setHidden: YES];
	[web setHidden: YES];
	[remoteBar setHidden: YES];
	remoteBlocked = NO;
	[unsubButton setHidden: YES];
	DESTROY(shown);
	[empty setStringValue: why ? why : @""];
	[empty setHidden: NO];
	[self setNeedsDisplay: YES];
}

- (void) saveAttachment: (NSButton *)b
{
	NSInteger i = [b tag];
	if (i < 0 || i >= (NSInteger)[attachments count])
		return;
	Mail2Attachment *a = [attachments objectAtIndex: i];
	NSSavePanel *sp = [NSSavePanel savePanel];
	[sp setTitle: @"Save Attachment"];
	NSString *dir = [NSHomeDirectory() stringByAppendingPathComponent: @"Downloads"];
	if (![[NSFileManager defaultManager] fileExistsAtPath: dir])
		dir = NSHomeDirectory();
	if ([sp runModalForDirectory: dir file: [a filename]] == NSOKButton) {
		if (![[a data] writeToFile: [sp filename] atomically: YES])
			NSRunAlertPanel(@"Cannot Save", @"%@ could not be written.", @"OK", nil, nil, [sp filename]);
	}
}

- (void) layoutAttachments
{
	NSArray *subs = [[[attachBar subviews] copy] autorelease];
	[subs makeObjectsPerformSelector: @selector(removeFromSuperview)];
	CGFloat h = [attachments count] ? 34 : 0, x = 16;
	NSUInteger i;
	for (i = 0; i < [attachments count]; i++) {
		Mail2Attachment *a = [attachments objectAtIndex: i];
		NSString *title = [NSString stringWithFormat: @"%@  (%@)", [a filename], Mail2ByteSize([[a data] length])];
		NSButton *b = [[[NSButton alloc] initWithFrame: NSMakeRect(x, 4, 10, 26)] autorelease];
		[b setTitle: title];
		[b setImage: Mail2Icon(@"sb-attachment")];
		[b setImagePosition: NSImageLeft];
		[b setBezelStyle: NSRoundedBezelStyle];
		[b setFont: [NSFont systemFontOfSize: 11]];
		[b sizeToFit];
		NSRect bf = [b frame];
		bf.size.width = MIN(bf.size.width + 8, 260);
		bf.size.height = 26;
		[b setFrame: bf];
		[b setTag: i];
		[b setTarget: self];
		[b setAction: @selector(saveAttachment:)];
		[b setToolTip: @"Save…"];
		[attachBar addSubview: b];
		x += bf.size.width + 6;
	}
	CGFloat hh = 70 + ([[msg to] length] ? 16 : 0) + ([[msg cc] length] ? 16 : 0) + 10;
	NSRect b = [self bounds];
	[header setFrame: NSMakeRect(0, 0, NSWidth(b), hh)];
	[attachBar setFrame: NSMakeRect(0, hh, NSWidth(b), h)];
	[scroll setFrame: NSMakeRect(0, hh + h, NSWidth(b), NSHeight(b) - hh - h)];
	CGFloat rb = remoteBlocked ? 32 : 0;
	[remoteBar setFrame: NSMakeRect(0, hh + h, NSWidth(b), rb)];
	[web setFrame: NSMakeRect(0, hh + h + rb, NSWidth(b), NSHeight(b) - hh - h - rb)];
}

- (void) makeRemoteBar
{
	if (remoteBar != nil)
		return;
	remoteBar = [[Mail2RemoteBar alloc] initWithFrame: NSMakeRect(0, 0, NSWidth([self bounds]), 32)];
	[remoteBar setAutoresizingMask: NSViewWidthSizable];
	NSTextField *l = [[[NSTextField alloc] initWithFrame: NSMakeRect(14, 7, NSWidth([self bounds]) - 200, 18)] autorelease];
	[l setStringValue: @"Remote content was not loaded, so the sender cannot tell you opened this."];
	[l setEditable: NO];
	[l setSelectable: NO];
	[l setBezeled: NO];
	[l setDrawsBackground: NO];
	[l setFont: [NSFont systemFontOfSize: 11]];
	[l setAutoresizingMask: NSViewWidthSizable];
	[remoteBar addSubview: l];
	NSButton *b = [[[NSButton alloc] initWithFrame: NSMakeRect(NSWidth([self bounds]) - 178, 3, 166, 26)] autorelease];
	[b setTitle: @"Load Remote Content"];
	[b setBezelStyle: NSRoundedBezelStyle];
	[b setFont: [NSFont systemFontOfSize: 11]];
	[b setTarget: self];
	[b setAction: @selector(loadRemoteContent:)];
	[b setAutoresizingMask: NSViewMinXMargin];
	[remoteBar addSubview: b];
	[self addSubview: remoteBar];
}

/* this message's images and styles from the web, through Florence's tracker list (FloWebView) */
- (void) loadRemoteContent: (id)sender
{
	remoteBlocked = NO;
	[remoteBar setHidden: YES];
	[self layoutAttachments];
	[web setAllowsRemoteContent: YES];
}

- (void) showMessage: (Mail2MessageInfo *)m body: (NSString *)body attachments: (NSArray *)att
{
	[self showMessage: m body: body attachments: att html: nil inlineParts: nil];
}

/* ---- plain text: quotes, signature, links ---- */

/* Quoted lines in the colours of their depth (as Apple Mail's bars), the signature after "-- " dimmed, and web and
 * mail addresses as links (Mail2MessageView opens them). */
void
Mail2StyleBody(NSMutableAttributedString *as)
{
	static NSColor *depth[3];
	if (depth[0] == nil) {
		depth[0] = [[NSColor colorWithCalibratedRed: 0.16 green: 0.42 blue: 0.80 alpha: 1] retain];
		depth[1] = [[NSColor colorWithCalibratedRed: 0.20 green: 0.55 blue: 0.30 alpha: 1] retain];
		depth[2] = [[NSColor colorWithCalibratedRed: 0.70 green: 0.40 blue: 0.10 alpha: 1] retain];
	}
	NSString *t = [as string];
	NSUInteger n = [t length], start = 0;
	BOOL inSig = NO;
	[as beginEditing];
	while (start < n) {
		NSRange line = [t lineRangeForRange: NSMakeRange(start, 0)];
		NSString *l = [t substringWithRange: line];
		NSString *bare = [l stringByTrimmingCharactersInSet: [NSCharacterSet newlineCharacterSet]];
		if ([bare isEqualToString: @"-- "] || [bare isEqualToString: @"--"])
			inSig = YES;
		NSUInteger d = 0, i;
		for (i = 0; i < [l length]; i++) {
			unichar c = [l characterAtIndex: i];
			if (c == '>') d++;
			else if (c != ' ') break;
		}
		if (d > 0)
			[as addAttribute: NSForegroundColorAttributeName value: depth[(d - 1) % 3] range: line];
		else if (inSig)
			[as addAttribute: NSForegroundColorAttributeName value: [NSColor colorWithCalibratedWhite: 0.45 alpha: 1] range: line];
		start = NSMaxRange(line);
	}
	/* links: http(s)://, www., mailto: and bare addresses, to the first space or closing bracket */
	NSCharacterSet *stop = [NSCharacterSet characterSetWithCharactersInString: @" \t\r\n<>\"()[]{}"];
	static NSString *starts[] = { @"https://", @"http://", @"www.", @"mailto:" };
	unsigned k;
	for (k = 0; k < 4; k++) {
		NSRange r = NSMakeRange(0, n);
		for (;;) {
			NSRange f = [t rangeOfString: starts[k] options: NSCaseInsensitiveSearch range: r];
			if (f.location == NSNotFound)
				break;
			/* "www." inside a link already found */
			if (f.location > 0 && ![stop characterIsMember: [t characterAtIndex: f.location - 1]] && k == 2) {
				r = NSMakeRange(NSMaxRange(f), n - NSMaxRange(f));
				continue;
			}
			NSUInteger e = f.location;
			while (e < n && ![stop characterIsMember: [t characterAtIndex: e]])
				e++;
			/* a sentence's full stop or comma is not part of it */
			while (e > NSMaxRange(f) && [@".,;:!?'" rangeOfString: [t substringWithRange: NSMakeRange(e - 1, 1)]].location != NSNotFound)
				e--;
			if (e > NSMaxRange(f)) {
				NSString *u = [t substringWithRange: NSMakeRange(f.location, e - f.location)];
				if (k == 2)
					u = [@"http://" stringByAppendingString: u];
				if ([as attribute: NSLinkAttributeName atIndex: f.location effectiveRange: NULL] == nil) {
					NSRange lr = NSMakeRange(f.location, e - f.location);
					[as addAttribute: NSLinkAttributeName value: u range: lr];
					[as addAttribute: NSForegroundColorAttributeName value: depth[0] range: lr];
					[as addAttribute: NSUnderlineStyleAttributeName value: [NSNumber numberWithInt: NSUnderlineStyleSingle] range: lr];
				}
			}
			r = NSMakeRange(e, n - e);
		}
	}
	[as endEditing];
}

/* ---- Unsubscribe ---- */

- (void) setParsed: (Mail2ParsedMessage *)p
{
	ASSIGN(shown, p);
	BOOL can = [p unsubscribeURL] != nil || [p unsubscribeMailto] != nil;
	if (can && unsubButton == nil) {
		unsubButton = [[NSButton alloc] initWithFrame: NSMakeRect(0, 0, 100, 22)];
		[unsubButton setTitle: @"Unsubscribe"];
		[unsubButton setBezelStyle: NSRoundedBezelStyle];
		[unsubButton setFont: [NSFont systemFontOfSize: 11]];
		[unsubButton setTarget: self];
		[unsubButton setAction: @selector(unsubscribe:)];
		[unsubButton setAutoresizingMask: NSViewMinXMargin];
		[unsubButton setToolTip: @"Ask the sender to stop sending this list (List-Unsubscribe)"];
		[self addSubview: unsubButton];
	}
	[unsubButton setFrameOrigin: NSMakePoint(NSWidth([self bounds]) - 116, 30)];
	[unsubButton setHidden: !can];
}

- (void) unsubscribe: (id)sender
{
	Mail2ParsedMessage *p = shown;
	NSString *who = [msg sender] ? [msg sender] : @"this sender";
	if (p == nil || NSRunAlertPanel(@"Unsubscribe?", @"Ask %@ to stop sending you this mail?", @"Unsubscribe", @"Cancel",
	    nil, who) != NSAlertDefaultReturn)
		return;
	if ([p unsubscribeOneClick]) {
		/* RFC 8058: a POST does it, nothing to open */
		NSString *url = [[p unsubscribeURL] copy];
		[unsubButton setEnabled: NO];
		[unsubButton setTitle: @"Unsubscribing…"];
		dispatch_async(dispatch_get_global_queue(0, 0), ^{
			int status = 0;
			NSString *err = nil;
			NSDictionary *d = Mail2PostForm(url, [NSDictionary dictionaryWithObject: @"One-Click" forKey: @"List-Unsubscribe"],
			    &status, &err);
			BOOL ok = d != nil && status >= 200 && status < 300;
			[err retain];
			Mail2RunOnMain(^{
				[unsubButton setEnabled: YES];
				[unsubButton setTitle: @"Unsubscribe"];
				if (ok)
					[unsubButton setHidden: YES];
				NSRunAlertPanel(ok ? @"Unsubscribed" : @"Not Unsubscribed", ok ? @"The sender was asked to stop sending this mail."
				    : @"The request failed (%@).", @"OK", nil, nil, err ? err : [NSString stringWithFormat: @"HTTP %d", status]);
				[err release];
				[url release];
			});
		});
		return;
	}
	if ([p unsubscribeMailto]) {	/* a message to the list's address, ready to send */
		id d = [NSApp delegate];
		if ([d respondsToSelector: @selector(application:openFile:)])
			[d application: NSApp openFile: [p unsubscribeMailto]];
		return;
	}
	[self webView: nil openLink: [p unsubscribeURL]];	/* the list's own page, in the browser */
}

/* a link in the plain text */
- (BOOL) textView: (NSTextView *)tv clickedOnLink: (id)link atIndex: (NSUInteger)i
{
	NSString *u = [link isKindOfClass: [NSURL class]] ? [link absoluteString] : [link description];
	[self webView: nil openLink: u];
	return YES;
}

/* ---- the web view's delegate ---- */

- (void) webView: (id)v openLink: (NSString *)url
{
	if ([[url lowercaseString] hasPrefix: @"mailto:"]) {
		id d = [NSApp delegate];
		if ([d respondsToSelector: @selector(application:openFile:)])
			[d application: NSApp openFile: url];
		return;
	}
	NSURL *u = [NSURL URLWithString: url];
	if (u != nil && ([[[u scheme] lowercaseString] isEqualToString: @"http"] || [[[u scheme] lowercaseString] isEqualToString: @"https"]))
		[[NSWorkspace sharedWorkspace] openURL: u];
}

- (NSData *) webView: (id)v dataForURL: (NSString *)url mimeType: (NSString **)type
{
	if (![[url lowercaseString] hasPrefix: @"cid:"])
		return nil;
	NSString *cid = [[url substringFromIndex: 4] stringByReplacingPercentEscapesUsingEncoding: NSUTF8StringEncoding];
	Mail2Attachment *a = [inlineParts objectForKey: cid];
	if (a == nil)
		a = [inlineParts objectForKey: [NSString stringWithFormat: @"<%@>", cid]];
	if (a == nil)
		return nil;
	*type = [a mimeType];
	return [a data];
}

- (void) showMessage: (Mail2MessageInfo *)m body: (NSString *)body attachments: (NSArray *)att
                html: (NSString *)html inlineParts: (NSDictionary *)parts
{
	Class wc = html != nil ? Mail2WebViewClass() : Nil;
	if (wc != Nil) {
		if (web == nil) {
			web = [[wc alloc] initWithFrame: [scroll frame]];
			[web setAutoresizingMask: NSViewWidthSizable | NSViewHeightSizable];
			[web setDelegate: self];
			[self addSubview: web];
		}
		ASSIGN(msg, m);
		ASSIGN(attachments, att);
		ASSIGN(inlineParts, parts);
		[(Mail2HeaderView *)header setMessage: m];
		/* remote content only when asked: per message (the bar's button), or always (Mail2LoadRemoteContent) */
		BOOL always = [[NSUserDefaults standardUserDefaults] boolForKey: @"Mail2LoadRemoteContent"];
		remoteBlocked = !always && Mail2HTMLHasRemoteContent(html);
		[web setAllowsRemoteContent: always];
		if (remoteBlocked)
			[self makeRemoteBar];
		[remoteBar setHidden: !remoteBlocked];
		[self layoutAttachments];
		/* a readable default for mail that sets no style of its own */
		[web loadHTMLString: [@"<meta charset=\"utf-8\"><style>body{font-family:sans-serif;font-size:14px;margin:14px;"
		    "overflow-wrap:break-word}img{max-width:100%;height:auto}</style>" stringByAppendingString: html]];
		[header setHidden: NO];
		[attachBar setHidden: [att count] == 0];
		[scroll setHidden: YES];
		[web setHidden: NO];
		[empty setHidden: YES];
		[self setNeedsDisplay: YES];
		return;
	}
	[web setHidden: YES];
	[remoteBar setHidden: YES];
	remoteBlocked = NO;
	ASSIGN(msg, m);
	ASSIGN(attachments, att);
	[(Mail2HeaderView *)header setMessage: m];
	[self layoutAttachments];
	NSDictionary *attrs = [NSDictionary dictionaryWithObjectsAndKeys: [NSFont systemFontOfSize: 13], NSFontAttributeName,
	    [NSColor blackColor], NSForegroundColorAttributeName, nil];
	NSMutableAttributedString *as = [[MilanDisplayString(body ? body : @"", attrs) mutableCopy] autorelease];
	Mail2StyleBody(as);
	[[text textStorage] setAttributedString: as];
	[text setDelegate: (id)self];
	[text scrollRangeToVisible: NSMakeRange(0, 0)];
	[header setHidden: NO];
	[attachBar setHidden: [att count] == 0];
	[scroll setHidden: NO];
	[empty setHidden: YES];
	[self setNeedsDisplay: YES];
}

@end

/* ---- windows with a fixed Tab order ---- */

/* the view after (step 1) or before (step -1) v in order, or nil if v is not in it */
static NSView *
step_in(NSArray *order, NSView *v, int step)
{
	NSUInteger i, n = [order count];
	/* the shared field editor stands for the text field it is editing */
	if ([v isKindOfClass: [NSTextView class]] && [(NSTextView *)v isFieldEditor] && [[(NSTextView *)v delegate] isKindOfClass: [NSView class]])
		v = (NSView *)[(NSTextView *)v delegate];
	if (![v isKindOfClass: [NSView class]])
		return nil;
	if (Mail2Debug())
		NSLog(@"Mail2: Tab order step %d from %@ at y=%.0f", step, [v class], NSMinY([v frame]));
	for (i = 0; i < n; i++) {
		NSView *o = [order objectAtIndex: i];
		/* v may be the view itself or something inside it (an NSTextView in its scroll view) */
		if (o == v || [v isDescendantOf: o] || [o isDescendantOf: v])
			return [order objectAtIndex: (i + n + step) % n];
	}
	return nil;
}

#define KEY_ORDER_METHODS \
- (void) dealloc { [keyOrder release]; [super dealloc]; } \
- (void) setKeyOrder: (NSArray *)views { ASSIGN(keyOrder, views); } \
- (void) selectKeyViewFollowingView: (NSView *)v \
{ \
	NSView *n = step_in(keyOrder, v, 1); \
	if (n) [self makeFirstResponder: n]; else [super selectKeyViewFollowingView: v]; \
} \
- (void) selectKeyViewPrecedingView: (NSView *)v \
{ \
	NSView *n = step_in(keyOrder, v, -1); \
	if (n) [self makeFirstResponder: n]; else [super selectKeyViewPrecedingView: v]; \
} \
- (void) selectNextKeyView: (id)sender \
{ \
	NSView *n = step_in(keyOrder, (NSView *)[self firstResponder], 1); \
	if (n) [self makeFirstResponder: n]; else [super selectNextKeyView: sender]; \
} \
- (void) selectPreviousKeyView: (id)sender \
{ \
	NSView *n = step_in(keyOrder, (NSView *)[self firstResponder], -1); \
	if (n) [self makeFirstResponder: n]; else [super selectPreviousKeyView: sender]; \
}

@implementation Mail2KeyOrderWindow
KEY_ORDER_METHODS
@end

@implementation Mail2KeyOrderPanel
KEY_ORDER_METHODS
@end

/* ---- small questions ---- */

@interface Mail2Asker : NSObject
@end
@implementation Mail2Asker
- (void) ok: (id)s { [NSApp stopModalWithCode: NSOKButton]; }
- (void) cancel: (id)s { [NSApp stopModalWithCode: NSCancelButton]; }
@end

/* a panel with a line of text, a control, Cancel and OK; runs it modally */
static NSInteger
run_question(NSString *title, NSString *message, NSView *control, NSString *okTitle)
{
	NSRect v = [[NSScreen mainScreen] visibleFrame];
	NSRect r = NSMakeRect(floor(NSMidX(v) - 200), floor(NSMidY(v)), 400, 132);
	NSPanel *p = [[NSPanel alloc] initWithContentRect: r styleMask: NSTitledWindowMask backing: NSBackingStoreBuffered defer: NO];
	Mail2Asker *a = [[Mail2Asker alloc] init];
	[p setTitle: title];
	[p setHidesOnDeactivate: NO];
	NSView *cv = [p contentView];
	NSTextField *l = [[[NSTextField alloc] initWithFrame: NSMakeRect(16, 96, 368, 20)] autorelease];
	[l setStringValue: message];
	[l setEditable: NO];
	[l setSelectable: NO];
	[l setBezeled: NO];
	[l setDrawsBackground: NO];
	[cv addSubview: l];
	[control setFrame: NSMakeRect(16, 60, 368, 26)];
	[cv addSubview: control];
	NSButton *ok = [[[NSButton alloc] initWithFrame: NSMakeRect(292, 12, 92, 28)] autorelease];
	[ok setTitle: okTitle ? okTitle : @"OK"];
	[ok setBezelStyle: NSRoundedBezelStyle];
	[ok setKeyEquivalent: @"\r"];
	[ok setTarget: a];
	[ok setAction: @selector(ok:)];
	[cv addSubview: ok];
	NSButton *cancel = [[[NSButton alloc] initWithFrame: NSMakeRect(194, 12, 92, 28)] autorelease];
	[cancel setTitle: @"Cancel"];
	[cancel setBezelStyle: NSRoundedBezelStyle];
	[cancel setKeyEquivalent: @"\e"];
	[cancel setTarget: a];
	[cancel setAction: @selector(cancel:)];
	[cv addSubview: cancel];
	[NSApp activateIgnoringOtherApps: YES];
	[p makeKeyAndOrderFront: nil];
	[p makeFirstResponder: control];
	[p display];
	NSInteger rc = [NSApp runModalForWindow: p];
	[p orderOut: nil];
	[p release];
	[a release];
	return rc;
}

NSString *
Mail2AskString(NSString *title, NSString *message, NSString *initial, NSString *okTitle)
{
	NSTextField *f = [[[NSTextField alloc] initWithFrame: NSMakeRect(0, 0, 368, 24)] autorelease];
	[f setStringValue: initial ? initial : @""];
	NSInteger rc = run_question(title, message, f, okTitle);
	NSString *v = [[f stringValue] stringByTrimmingCharactersInSet: [NSCharacterSet whitespaceCharacterSet]];
	return rc == NSOKButton && [v length] ? v : nil;
}

Mail2Mailbox *
Mail2ChooseMailbox(NSString *title, NSString *message, NSArray *mailboxes, NSString *okTitle)
{
	NSPopUpButton *pop = [[[NSPopUpButton alloc] initWithFrame: NSMakeRect(0, 0, 368, 26) pullsDown: NO] autorelease];
	NSEnumerator *e = [mailboxes objectEnumerator];
	Mail2Mailbox *m;
	while ((m = [e nextObject]) != nil) {
		NSString *indent = [@"" stringByPaddingToLength: (NSUInteger)[m depth] * 3 withString: @" " startingAtIndex: 0];
		[pop addItemWithTitle: [NSString stringWithFormat: @"%@%@", indent, [m displayName]]];
		[[pop lastItem] setRepresentedObject: m];
	}
	if ([mailboxes count] == 0)
		return nil;
	NSInteger rc = run_question(title, message, pop, okTitle);
	return rc == NSOKButton ? [[pop selectedItem] representedObject] : nil;
}
