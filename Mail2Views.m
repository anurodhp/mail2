/* Mail2Views: sidebar and message-list rows, the message pane (see Mail2Views.h). */
#import "Mail2Views.h"
#import "Mail2Util.h"
#import "MilanText.h"
#import "Mail2OAuth.h"
#include <math.h>
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
	if ([s isEqualToString: @"outbox"]) return @"sb-sent";
	if ([s isEqualToString: @"unreadsmart"]) return @"sb-unread";
	if ([s isEqualToString: @"savedsearch"]) return @"sb-search";
	if ([s isEqualToString: @"followup"]) return @"sb-flag";
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
	if ([msg thread] && [[Mail2Store sharedStore] isThreadMuted: [msg thread]]) {	/* a muted conversation */
		NSImage *bell = Mail2Icon(selected ? @"sb-muted-sel" : @"sb-muted");
		[bell drawInRect: NSMakeRect(senderRight - 13, line1 + 2, 12, 12) fromRect: NSZeroRect
		    operation: NSCompositeSourceOver fraction: 0.8 respectFlipped: YES hints: nil];
		senderRight -= 18;
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
	NSArray *labels;
}
- (void) setMessage: (Mail2MessageInfo *)m;
- (void) setLabels: (NSArray *)l;
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
- (void) setMessage: (Mail2MessageInfo *)m { ASSIGN(msg, m); DESTROY(labels); [self setNeedsDisplay: YES]; }
- (void) setLabels: (NSArray *)l { ASSIGN(labels, [l count] ? l : nil); [self setNeedsDisplay: YES]; }

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
	if ([[msg cc] length]) {
		[Mail2FittedString([@"Cc: " stringByAppendingString: [msg cc]], la, right - x) drawAtPoint: NSMakePoint(x, y)];
		y += 16;
	}
	if (labels)	/* Gmail's labels */
		[Mail2FittedString([@"Labels: " stringByAppendingString: [labels componentsJoinedByString: @", "]], la, right - x)
		    drawAtPoint: NSMakePoint(x, y)];
}

@end

/* ---- attachments: preview, save, open ---- */

void
Mail2SaveAttachment(Mail2Attachment *a)
{
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

/* a copy under Mail2's tmp folder, opened by the desktop's application for its kind (Preview, Florence...) */
void
Mail2OpenAttachment(Mail2Attachment *a)
{
	NSString *dir = [[Mail2SupportDirectory() stringByAppendingPathComponent: @"tmp"]
	    stringByAppendingPathComponent: [[NSProcessInfo processInfo] globallyUniqueString]];
	[[NSFileManager defaultManager] createDirectoryAtPath: dir withIntermediateDirectories: YES attributes: nil error: NULL];
	NSString *path = [dir stringByAppendingPathComponent: [[a filename] length] ? [a filename] : @"Attachment"];
	if (![[a data] writeToFile: path atomically: YES] || ![[NSWorkspace sharedWorkspace] openFile: path])
		NSRunAlertPanel(@"Cannot Open", @"No application here opens %@. Save it instead.", @"OK", nil, nil, [a filename]);
}

static BOOL
is_text_type(NSString *t, NSString *name)
{
	NSString *ext = [[name pathExtension] lowercaseString];
	return [t hasPrefix: @"text/"] || [t isEqualToString: @"application/json"] || [t isEqualToString: @"application/xml"] ||
	    [t isEqualToString: @"message/rfc822"] || [[NSArray arrayWithObjects: @"txt", @"csv", @"log", @"md", @"json", @"xml",
	    @"eml", @"ics", @"vcf", @"c", @"h", @"m", @"py", @"sh", nil] containsObject: ext];
}

@interface Mail2PreviewController : NSObject
{
@public
	NSWindow *window;
	Mail2Attachment *att;
}
@end
@implementation Mail2PreviewController
- (void) dealloc { [window release]; [att release]; [super dealloc]; }
- (void) save: (id)s { Mail2SaveAttachment(att); }
- (void) open: (id)s { Mail2OpenAttachment(att); }
- (void) windowWillClose: (NSNotification *)n { [self autorelease]; }
@end

/* a window showing a picture or a text file, with Save and Open */
static BOOL
preview_attachment(Mail2Attachment *a)
{
	NSString *t = [[a mimeType] lowercaseString];
	NSView *content = nil;
	NSSize want = NSMakeSize(640, 480);
	if ([t hasPrefix: @"image/"]) {
		NSImage *img = [[[NSImage alloc] initWithData: [a data]] autorelease];
		if (img == nil || [img size].width < 1)
			return NO;
		NSSize s = [img size];
		NSRect vis = [[NSScreen mainScreen] visibleFrame];
		double k = MIN(1.0, MIN((NSWidth(vis) - 120) / s.width, (NSHeight(vis) - 160) / s.height));
		want = NSMakeSize(MAX(240, s.width * k), MAX(160, s.height * k));
		NSImageView *iv = [[[NSImageView alloc] initWithFrame: NSMakeRect(0, 0, want.width, want.height)] autorelease];
		[iv setImage: img];
		[iv setImageScaling: NSImageScaleProportionallyDown];
		content = iv;
	} else if (is_text_type(t, [a filename])) {
		NSString *str = [[[NSString alloc] initWithData: [a data] encoding: NSUTF8StringEncoding] autorelease];
		if (str == nil)
			str = [[[NSString alloc] initWithData: [a data] encoding: NSISOLatin1StringEncoding] autorelease];
		NSScrollView *sv = [[[NSScrollView alloc] initWithFrame: NSMakeRect(0, 0, want.width, want.height)] autorelease];
		[sv setHasVerticalScroller: YES];
		NSTextView *tv = [[[NSTextView alloc] initWithFrame: NSMakeRect(0, 0, [sv contentSize].width, [sv contentSize].height)] autorelease];
		[tv setEditable: NO];
		[tv setRichText: NO];
		[tv setFont: [NSFont userFixedPitchFontOfSize: 11]];
		[tv setTextContainerInset: NSMakeSize(10, 8)];
		[tv setVerticallyResizable: YES];
		[tv setAutoresizingMask: NSViewWidthSizable];
		[[tv textContainer] setWidthTracksTextView: YES];
		[tv setString: str ? str : @""];
		[sv setDocumentView: tv];
		content = sv;
	} else
		return NO;
	Mail2PreviewController *c = [[Mail2PreviewController alloc] init];
	c->att = [a retain];
	NSRect vis = [[NSScreen mainScreen] visibleFrame];
	NSRect fr = NSMakeRect(NSMidX(vis) - want.width / 2, NSMidY(vis) - want.height / 2, want.width, want.height + 44);
	c->window = [[NSWindow alloc] initWithContentRect: fr
	    styleMask: NSTitledWindowMask | NSClosableWindowMask | NSMiniaturizableWindowMask | NSResizableWindowMask
	    backing: NSBackingStoreBuffered defer: NO];
	[c->window setReleasedWhenClosed: NO];
	[c->window setTitle: [a filename] ? [a filename] : @"Attachment"];
	[c->window setDelegate: c];
	NSView *cv = [c->window contentView];
	[content setFrame: NSMakeRect(0, 44, want.width, want.height)];
	[content setAutoresizingMask: NSViewWidthSizable | NSViewHeightSizable];
	[cv addSubview: content];
	NSButton *save = [[[NSButton alloc] initWithFrame: NSMakeRect(want.width - 196, 8, 90, 28)] autorelease];
	[save setTitle: @"Save…"];
	[save setBezelStyle: NSRoundedBezelStyle];
	[save setTarget: c];
	[save setAction: @selector(save:)];
	[save setAutoresizingMask: NSViewMinXMargin];
	[cv addSubview: save];
	NSButton *open = [[[NSButton alloc] initWithFrame: NSMakeRect(want.width - 100, 8, 90, 28)] autorelease];
	[open setTitle: @"Open"];
	[open setBezelStyle: NSRoundedBezelStyle];
	[open setTarget: c];
	[open setAction: @selector(open:)];
	[open setAutoresizingMask: NSViewMinXMargin];
	[cv addSubview: open];
	[c->window makeKeyAndOrderFront: nil];
	return YES;
}


/* An attachment's button: a click previews it (or offers Save and Open), a drag hands the file to wherever it is dropped (Milan, the desktop) as
 * a copy written under Mail2's tmp folder. */
@implementation Mail2AttachmentButton
- (void) dealloc { [attachment release]; [super dealloc]; }
- (void) setAttachment: (Mail2Attachment *)a { ASSIGN(attachment, a); }

- (void) mouseDown: (NSEvent *)ev
{
	NSPoint start = [ev locationInWindow];
	for (;;) {
		NSEvent *e = [NSApp nextEventMatchingMask: NSLeftMouseDraggedMask | NSLeftMouseUpMask untilDate: [NSDate distantFuture]
		    inMode: NSEventTrackingRunLoopMode dequeue: YES];
		if ([e type] == NSLeftMouseUp) {	/* a click */
			[self highlight: YES];
			[self sendAction: [self action] to: [self target]];
			[self highlight: NO];
			return;
		}
		NSPoint p = [e locationInWindow];
		if (fabs(p.x - start.x) + fabs(p.y - start.y) > 5) {
			NSString *dir = [[Mail2SupportDirectory() stringByAppendingPathComponent: @"tmp"]
			    stringByAppendingPathComponent: [[NSProcessInfo processInfo] globallyUniqueString]];
			[[NSFileManager defaultManager] createDirectoryAtPath: dir withIntermediateDirectories: YES attributes: nil error: NULL];
			NSString *path = [dir stringByAppendingPathComponent: [[attachment filename] length] ? [attachment filename] : @"Attachment"];
			if (![[attachment data] writeToFile: path atomically: YES])
				return;
			[self dragFile: path fromRect: [self bounds] slideBack: YES event: ev];
			return;
		}
	}
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
	[labelsShown release];
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

/* a click on an attachment: a preview of what can be shown here, else Save or Open */
- (void) saveAttachment: (NSButton *)b
{
	NSInteger i = [b tag];
	if (i < 0 || i >= (NSInteger)[attachments count])
		return;
	Mail2Attachment *a = [attachments objectAtIndex: i];
	if (preview_attachment(a))
		return;
	NSInteger r = NSRunAlertPanel([a filename], @"%@, %@.", @"Save…", @"Cancel", @"Open", [a mimeType], Mail2ByteSize([[a data] length]));
	if (r == NSAlertDefaultReturn)
		Mail2SaveAttachment(a);
	else if (r == NSAlertOtherReturn)
		Mail2OpenAttachment(a);
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
		Mail2AttachmentButton *b = [[[Mail2AttachmentButton alloc] initWithFrame: NSMakeRect(x, 4, 10, 26)] autorelease];
		[b setAttachment: a];
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
		[b setToolTip: @"Click to preview or save; drag to put it somewhere"];
		[attachBar addSubview: b];
		x += bf.size.width + 6;
	}
	CGFloat hh = 70 + ([[msg to] length] ? 16 : 0) + ([[msg cc] length] ? 16 : 0) + ([labelsShown count] ? 16 : 0) + 10;
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

/* ---- a conversation ---- */

/* a reply's own words: without the quote of what it answers ("> " lines and the "On ..., X wrote:" before them) */
static NSString *
own_words(NSString *body)
{
	NSMutableArray *keep = [NSMutableArray array];
	NSArray *lines = [body componentsSeparatedByString: @"\n"];
	NSUInteger i;
	for (i = 0; i < [lines count]; i++) {
		NSString *l = [lines objectAtIndex: i];
		NSString *tr = [l stringByTrimmingCharactersInSet: [NSCharacterSet whitespaceCharacterSet]];
		if ([tr hasPrefix: @">"])
			continue;
		if ([tr hasSuffix: @"wrote:"] && i + 1 < [lines count]) {
			/* "On ... wrote:" followed (after blank lines) by a quote */
			NSUInteger j = i + 1;
			while (j < [lines count] && [[[lines objectAtIndex: j] stringByTrimmingCharactersInSet: [NSCharacterSet whitespaceCharacterSet]] length] == 0)
				j++;
			if (j < [lines count] && [[[lines objectAtIndex: j] stringByTrimmingCharactersInSet: [NSCharacterSet whitespaceCharacterSet]] hasPrefix: @">"])
				continue;
		}
		[keep addObject: l];
	}
	return [[keep componentsJoinedByString: @"\n"] stringByTrimmingCharactersInSet: [NSCharacterSet whitespaceAndNewlineCharacterSet]];
}

- (void) showConversation: (NSArray *)msgs parsed: (NSArray *)parsed
{
	Mail2MessageInfo *newest = [msgs lastObject];
	NSMutableArray *allAtt = [NSMutableArray array];
	NSMutableAttributedString *as = [[[NSMutableAttributedString alloc] init] autorelease];
	NSDictionary *body = [NSDictionary dictionaryWithObjectsAndKeys: [NSFont systemFontOfSize: 13], NSFontAttributeName,
	    [NSColor blackColor], NSForegroundColorAttributeName, nil];
	NSDictionary *who = [NSDictionary dictionaryWithObjectsAndKeys: [NSFont boldSystemFontOfSize: 13], NSFontAttributeName,
	    [NSColor blackColor], NSForegroundColorAttributeName, nil];
	NSDictionary *when = [NSDictionary dictionaryWithObjectsAndKeys: [NSFont systemFontOfSize: 11], NSFontAttributeName,
	    gray(), NSForegroundColorAttributeName, nil];
	NSDictionary *rule = [NSDictionary dictionaryWithObjectsAndKeys: [NSFont systemFontOfSize: 6], NSFontAttributeName,
	    [NSColor colorWithCalibratedWhite: 0.80 alpha: 1], NSForegroundColorAttributeName, nil];
	NSUInteger i;
	for (i = 0; i < [msgs count]; i++) {
		Mail2MessageInfo *m = [msgs objectAtIndex: i];
		id p = i < [parsed count] ? [parsed objectAtIndex: i] : [NSNull null];
		NSString *text = [p isKindOfClass: [Mail2ParsedMessage class]] ? [p body] : @"(not downloaded)";
		if (i > 0) {
			text = own_words(text);
			[as appendAttributedString: [[[NSAttributedString alloc] initWithString: @"\n\n" attributes: body] autorelease]];
			[as appendAttributedString: [[[NSAttributedString alloc] initWithString:
			    [@"" stringByPaddingToLength: 120 withString: @"─" startingAtIndex: 0] attributes: rule] autorelease]];
			[as appendAttributedString: [[[NSAttributedString alloc] initWithString: @"\n\n" attributes: body] autorelease]];
		}
		[as appendAttributedString: MilanDisplayString([m sender], who)];
		[as appendAttributedString: [[[NSAttributedString alloc] initWithString:
		    [NSString stringWithFormat: @"   %@\n\n", Mail2LongDate([m date])] attributes: when] autorelease]];
		NSMutableAttributedString *b = [[MilanDisplayString(text ? text : @"", body) mutableCopy] autorelease];
		Mail2StyleBody(b);
		[as appendAttributedString: b];
		if ([p isKindOfClass: [Mail2ParsedMessage class]])
			[allAtt addObjectsFromArray: [p attachments]];
	}
	[self showMessage: newest body: @"" attachments: allAtt html: nil inlineParts: nil];
	[[text textStorage] setAttributedString: as];
	[text scrollRangeToVisible: NSMakeRange([as length], 0)];	/* the newest, at the end */
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

- (void) setLabels: (NSArray *)l
{
	ASSIGN(labelsShown, [l count] ? l : nil);
	[(Mail2HeaderView *)header setLabels: l];
	[self layoutAttachments];
}

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
	/* attached pictures under the text, as Apple Mail shows them (at most the pane's width) */
	NSEnumerator *ie = [att objectEnumerator];
	Mail2Attachment *ia;
	CGFloat maxW = MAX(120, NSWidth([self bounds]) - 60);
	int shownImages = 0;
	while ((ia = [ie nextObject]) != nil && shownImages < 8) {
		NSString *t = [[ia mimeType] lowercaseString];
		if (![t hasPrefix: @"image/"] || [[ia data] length] > 8 * 1024 * 1024)
			continue;
		NSImage *img = [[[NSImage alloc] initWithData: [ia data]] autorelease];
		if (img == nil || [img size].width < 1)
			continue;
		NSSize sz = [img size];
		if (sz.width > maxW) {
			sz = NSMakeSize(maxW, floor(sz.height * maxW / sz.width));
			[img setScalingAllowed: YES];
			[img setSize: sz];
		}
		NSTextAttachmentCell *cell = [[[NSTextAttachmentCell alloc] initImageCell: img] autorelease];
		NSTextAttachment *ta = [[[NSTextAttachment alloc] init] autorelease];
		[ta setAttachmentCell: cell];
		[as appendAttributedString: [[[NSAttributedString alloc] initWithString: @"\n\n" attributes: attrs] autorelease]];
		[as appendAttributedString: [NSAttributedString attributedStringWithAttachment: ta]];
		shownImages++;
	}
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

NSDate *
Mail2ChooseSendTime(void)
{
	NSCalendarDate *now = [NSCalendarDate calendarDate];
	NSCalendarDate *today8 = [NSCalendarDate dateWithYear: [now yearOfCommonEra] month: [now monthOfYear] day: [now dayOfMonth]
	    hour: 8 minute: 0 second: 0 timeZone: [now timeZone]];
	NSCalendarDate *evening = [today8 dateByAddingYears: 0 months: 0 days: 0 hours: 10 minutes: 0 seconds: 0];
	if ([evening timeIntervalSinceNow] < 600)
		evening = [evening dateByAddingYears: 0 months: 0 days: 1 hours: 0 minutes: 0 seconds: 0];
	NSCalendarDate *tomorrow = [today8 dateByAddingYears: 0 months: 0 days: 1 hours: 0 minutes: 0 seconds: 0];
	int toMonday = (8 - [now dayOfWeek]) % 7;
	NSCalendarDate *monday = [today8 dateByAddingYears: 0 months: 0 days: toMonday ? toMonday : 7 hours: 0 minutes: 0 seconds: 0];
	NSArray *when = [NSArray arrayWithObjects: [NSDate dateWithTimeIntervalSinceNow: 3600], evening, tomorrow, monday, nil];
	NSArray *titles = [NSArray arrayWithObjects: @"In an hour", [NSString stringWithFormat: @"This evening (%@)", Mail2LongDate(evening)],
	    [NSString stringWithFormat: @"Tomorrow morning (%@)", Mail2LongDate(tomorrow)],
	    [NSString stringWithFormat: @"Monday morning (%@)", Mail2LongDate(monday)], @"At a time I type…", nil];
	NSPopUpButton *pop = [[[NSPopUpButton alloc] initWithFrame: NSMakeRect(0, 0, 368, 26) pullsDown: NO] autorelease];
	[pop addItemsWithTitles: titles];
	if (run_question(@"Send Later", @"Send the message:", pop, @"Schedule") != NSOKButton)
		return nil;
	NSInteger i = [pop indexOfSelectedItem];
	if (i >= 0 && i < (NSInteger)[when count])
		return [when objectAtIndex: i];
	NSString *typed = Mail2AskString(@"Send Later", @"Date and time (YYYY-MM-DD HH:MM):",
	    [tomorrow descriptionWithCalendarFormat: @"%Y-%m-%d %H:%M"], @"Schedule");
	NSCalendarDate *d = typed ? [NSCalendarDate dateWithString: typed calendarFormat: @"%Y-%m-%d %H:%M"] : nil;
	if (typed != nil && (d == nil || [d timeIntervalSinceNow] < 0)) {
		NSRunAlertPanel(@"Send Later", @"“%@” is not a time to come (YYYY-MM-DD HH:MM).", @"OK", nil, nil, typed);
		return nil;
	}
	return d;
}

NSDate *
Mail2ChooseSnoozeTime(void)
{
	NSCalendarDate *now = [NSCalendarDate calendarDate];
	NSCalendarDate *today8 = [NSCalendarDate dateWithYear: [now yearOfCommonEra] month: [now monthOfYear] day: [now dayOfMonth]
	    hour: 8 minute: 0 second: 0 timeZone: [now timeZone]];
	NSCalendarDate *evening = [today8 dateByAddingYears: 0 months: 0 days: 0 hours: 10 minutes: 0 seconds: 0];
	if ([evening timeIntervalSinceNow] < 600)
		evening = [evening dateByAddingYears: 0 months: 0 days: 1 hours: 0 minutes: 0 seconds: 0];
	NSCalendarDate *tomorrow = [today8 dateByAddingYears: 0 months: 0 days: 1 hours: 0 minutes: 0 seconds: 0];
	int toMonday = (8 - [now dayOfWeek]) % 7;
	NSCalendarDate *monday = [today8 dateByAddingYears: 0 months: 0 days: toMonday ? toMonday : 7 hours: 0 minutes: 0 seconds: 0];
	NSArray *when = [NSArray arrayWithObjects: [NSDate dateWithTimeIntervalSinceNow: 3 * 3600], evening, tomorrow, monday, nil];
	NSArray *titles = [NSArray arrayWithObjects: @"Later today (in 3 hours)", [NSString stringWithFormat: @"This evening (%@)", Mail2LongDate(evening)],
	    [NSString stringWithFormat: @"Tomorrow morning (%@)", Mail2LongDate(tomorrow)],
	    [NSString stringWithFormat: @"Next week (%@)", Mail2LongDate(monday)], @"At a time I type…", nil];
	NSPopUpButton *pop = [[[NSPopUpButton alloc] initWithFrame: NSMakeRect(0, 0, 368, 26) pullsDown: NO] autorelease];
	[pop addItemsWithTitles: titles];
	if (run_question(@"Snooze", @"Bring it back:", pop, @"Snooze") != NSOKButton)
		return nil;
	NSInteger i = [pop indexOfSelectedItem];
	if (i >= 0 && i < (NSInteger)[when count])
		return [when objectAtIndex: i];
	NSString *typed = Mail2AskString(@"Snooze", @"Date and time (YYYY-MM-DD HH:MM):",
	    [tomorrow descriptionWithCalendarFormat: @"%Y-%m-%d %H:%M"], @"Snooze");
	NSCalendarDate *d = typed ? [NSCalendarDate dateWithString: typed calendarFormat: @"%Y-%m-%d %H:%M"] : nil;
	if (typed != nil && (d == nil || [d timeIntervalSinceNow] < 0)) {
		NSRunAlertPanel(@"Snooze", @"“%@” is not a time to come (YYYY-MM-DD HH:MM).", @"OK", nil, nil, typed);
		return nil;
	}
	return d;
}

int
Mail2ChooseFollowUpDays(void)
{
	static const int days[] = { 1, 2, 3, 5, 7 };
	NSPopUpButton *pop = [[[NSPopUpButton alloc] initWithFrame: NSMakeRect(0, 0, 368, 26) pullsDown: NO] autorelease];
	unsigned i;
	for (i = 0; i < 5; i++)
		[pop addItemWithTitle: days[i] == 1 ? @"After a day" : [NSString stringWithFormat: @"After %d days", days[i]]];
	[pop selectItemAtIndex: 2];
	if (run_question(@"Remind Me If No Reply", @"If nobody answers, list it in Follow Up:", pop, @"Remind Me") != NSOKButton)
		return 0;
	return days[[pop indexOfSelectedItem]];
}
