/* Mail2Compose: the compose window (see Mail2Compose.h). */
#import "Mail2Compose.h"
#import "Mail2Views.h"
#import "Mail2Util.h"

static NSMutableSet *open_windows;	/* each compose window keeps itself alive until closed */

static NSTextField *
label(NSView *parent, NSString *s, NSRect r)
{
	NSTextField *l = [[[NSTextField alloc] initWithFrame: r] autorelease];
	[l setStringValue: s];
	[l setEditable: NO];
	[l setSelectable: NO];
	[l setBezeled: NO];
	[l setDrawsBackground: NO];
	[l setAlignment: NSRightTextAlignment];
	[l setTextColor: [NSColor colorWithCalibratedWhite: 0.45 alpha: 1]];
	[l setFont: [NSFont systemFontOfSize: 12]];
	[l setAutoresizingMask: NSViewMinYMargin];
	[parent addSubview: l];
	return l;
}

static NSTextField *
field(NSView *parent, NSRect r)
{
	NSTextField *f = [[[NSTextField alloc] initWithFrame: r] autorelease];
	[f setFont: [NSFont systemFontOfSize: 13]];
	[f setBezeled: NO];
	[f setBordered: NO];
	[f setDrawsBackground: NO];
	[f setAutoresizingMask: NSViewWidthSizable | NSViewMinYMargin];
	[parent addSubview: f];
	return f;
}

/* a hairline under each header row, as in Apple Mail */
@interface Mail2RuleView : NSView
@end
@implementation Mail2RuleView
- (void) drawRect: (NSRect)r { [[NSColor colorWithCalibratedWhite: 0.86 alpha: 1] set]; NSRectFill([self bounds]); }
@end

static void
rule(NSView *parent, CGFloat y, CGFloat width)
{
	Mail2RuleView *v = [[[Mail2RuleView alloc] initWithFrame: NSMakeRect(12, y, width - 24, 1)] autorelease];
	[v setAutoresizingMask: NSViewWidthSizable | NSViewMinYMargin];
	[parent addSubview: v];
}

static NSString *
strip_prefix(NSString *subject, NSString *prefix)
{
	NSString *s = subject ? subject : @"";
	NSString *t = [s stringByTrimmingCharactersInSet: [NSCharacterSet whitespaceCharacterSet]];
	if ([[t lowercaseString] hasPrefix: [prefix lowercaseString]])
		return t;
	return [NSString stringWithFormat: @"%@ %@", prefix, t];
}

static NSString *
quote(NSString *body)
{
	NSMutableArray *out = [NSMutableArray array];
	NSEnumerator *e = [[body componentsSeparatedByString: @"\n"] objectEnumerator];
	NSString *l;
	while ((l = [e nextObject]) != nil)
		[out addObject: [l hasPrefix: @">"] ? [@">" stringByAppendingString: l] : [@"> " stringByAppendingString: l]];
	return [out componentsJoinedByString: @"\n"];
}

@implementation Mail2Compose

- (id) initWithSessions: (NSArray *)all session: (Mail2Session *)s
{
	if ((self = [super init]) == nil)
		return nil;
	sessions = [all retain];
	session = [(s ? s : [all objectAtIndex: 0]) retain];
	if (open_windows == nil)
		open_windows = [[NSMutableSet alloc] init];
	[open_windows addObject: self];

	static int cascade;
	NSRect fr = NSMakeRect(220 + cascade * 24, 120 + (8 - cascade) * 24, 640, 560);
	cascade = (cascade + 1) % 8;
	window = [[Mail2KeyOrderWindow alloc] initWithContentRect: fr
	    styleMask: NSTitledWindowMask | NSClosableWindowMask | NSMiniaturizableWindowMask | NSResizableWindowMask
	    backing: NSBackingStoreBuffered defer: NO];
	[window setReleasedWhenClosed: NO];
	[window setTitle: @"New Message"];
	[window setDelegate: self];
	[window setMinSize: NSMakeSize(420, 300)];
	NSView *cv = [window contentView];
	CGFloat W = NSWidth([cv bounds]), H = NSHeight([cv bounds]), y = H - 44;

	/* the toolbar: Send on the left, as in Apple Mail */
	sendButton = [[NSButton alloc] initWithFrame: NSMakeRect(12, H - 36, 84, 28)];
	[sendButton setTitle: @"Send"];
	[sendButton setImage: Mail2Icon(@"sb-sent")];
	[sendButton setImagePosition: NSImageLeft];
	[sendButton setBezelStyle: NSRoundedBezelStyle];
	[sendButton setTarget: self];
	[sendButton setAction: @selector(send:)];
	[sendButton setKeyEquivalent: @"D"];	/* Shift-Cmd-D, Apple Mail's Send */
	[sendButton setKeyEquivalentModifierMask: NSCommandKeyMask | NSShiftKeyMask];
	[sendButton setAutoresizingMask: NSViewMinYMargin];
	[cv addSubview: sendButton];
	attachButton = [[NSButton alloc] initWithFrame: NSMakeRect(104, H - 36, 92, 28)];
	[attachButton setTitle: @"Attach…"];
	[attachButton setImage: Mail2Icon(@"sb-attachment")];
	[attachButton setImagePosition: NSImageLeft];
	[attachButton setBezelStyle: NSRoundedBezelStyle];
	[attachButton setTarget: self];
	[attachButton setAction: @selector(attachFile:)];
	[attachButton setAutoresizingMask: NSViewMinYMargin];
	[attachButton setRefusesFirstResponder: YES];
	[cv addSubview: attachButton];
	attachments = [[NSMutableArray alloc] init];

	y = H - 48;
	rule(cv, y, W);
	y -= 28;
	label(cv, @"To:", NSMakeRect(8, y + 4, 62, 18));
	toField = [field(cv, NSMakeRect(74, y + 3, W - 86, 22)) retain];
	rule(cv, y, W);
	y -= 28;
	label(cv, @"Cc:", NSMakeRect(8, y + 4, 62, 18));
	ccField = [field(cv, NSMakeRect(74, y + 3, W - 86, 22)) retain];
	rule(cv, y, W);
	y -= 28;
	label(cv, @"Bcc:", NSMakeRect(8, y + 4, 62, 18));
	bccField = [field(cv, NSMakeRect(74, y + 3, W - 86, 22)) retain];
	rule(cv, y, W);
	y -= 28;
	label(cv, @"Subject:", NSMakeRect(8, y + 4, 62, 18));
	subjectField = [field(cv, NSMakeRect(74, y + 3, W - 86, 22)) retain];

	rule(cv, y, W);
	y -= 30;
	label(cv, @"From:", NSMakeRect(8, y + 6, 62, 18));
	fromPopup = [[NSPopUpButton alloc] initWithFrame: NSMakeRect(74, y + 2, MIN(360, W - 86), 24) pullsDown: NO];
	NSEnumerator *e = [sessions objectEnumerator];
	Mail2Session *ss;
	while ((ss = [e nextObject]) != nil)
		[fromPopup addItemWithTitle: [[ss account] fromAddress]];
	[fromPopup selectItemAtIndex: [sessions indexOfObject: session]];
	[fromPopup setAutoresizingMask: NSViewMinYMargin];
	[cv addSubview: fromPopup];
	rule(cv, y, W);

	/* the attached files, a strip between the headers and the body (hidden while there are none) */
	attachBar = [[NSView alloc] initWithFrame: NSMakeRect(0, y, W, 0)];
	[attachBar setAutoresizingMask: NSViewWidthSizable | NSViewMinYMargin];
	[cv addSubview: attachBar];

	NSScrollView *sv = [[[NSScrollView alloc] initWithFrame: NSMakeRect(0, 0, W, y)] autorelease];
	bodyScroll = [sv retain];
	[sv setHasVerticalScroller: YES];
	[sv setAutohidesScrollers: YES];
	[sv setBorderType: NSNoBorder];
	[sv setAutoresizingMask: NSViewWidthSizable | NSViewHeightSizable];
	NSSize cs = [sv contentSize];
	bodyView = [[NSTextView alloc] initWithFrame: NSMakeRect(0, 0, cs.width, cs.height)];
	[bodyView setRichText: NO];
	[bodyView setImportsGraphics: NO];
	[bodyView setFont: [NSFont systemFontOfSize: 13]];
	[bodyView setTextContainerInset: NSMakeSize(12, 10)];
	[bodyView setMinSize: NSMakeSize(0, cs.height)];
	[bodyView setMaxSize: NSMakeSize(1e7, 1e7)];
	[bodyView setVerticallyResizable: YES];
	[bodyView setHorizontallyResizable: NO];
	[bodyView setAutoresizingMask: NSViewWidthSizable];
	[[bodyView textContainer] setWidthTracksTextView: YES];
	[sv setDocumentView: bodyView];
	[cv addSubview: sv];

	/* Tab walks To, Cc, Bcc, Subject, the body and round again. The loop is set here, not worked out from the layout:
	 * GNUstep's recalculated loop put the Send button after To, and Tab from that button crashed (QEMU, 2026-11-08). */
	[sendButton setRefusesFirstResponder: YES];
	[fromPopup setRefusesFirstResponder: YES];
	[window setAutorecalculatesKeyViewLoop: NO];
	[toField setNextKeyView: ccField];
	[ccField setNextKeyView: bccField];
	[bccField setNextKeyView: subjectField];
	[subjectField setNextKeyView: bodyView];
	[bodyView setNextKeyView: toField];
	[window setInitialFirstResponder: toField];
	[(Mail2KeyOrderWindow *)window setKeyOrder: [NSArray arrayWithObjects: toField, ccField, bccField, subjectField, bodyView, nil]];
	[subjectField setDelegate: (id)self];
	[toField setDelegate: (id)self];
	[ccField setDelegate: (id)self];
	[bccField setDelegate: (id)self];
	[bodyView setDelegate: (id)self];
	autosave = [[NSTimer scheduledTimerWithTimeInterval: 60 target: self selector: @selector(autosaveFired:)
	    userInfo: nil repeats: YES] retain];
	return self;
}

- (void) dealloc
{
	[window release]; [session release]; [sessions release]; [fromPopup release];
	[toField release]; [ccField release]; [bccField release]; [subjectField release];
	[bodyView release]; [sendButton release]; [original release]; [inReplyTo release]; [references release];
	[attachButton release]; [attachBar release]; [attachments release]; [bodyScroll release]; [draftId release];
	[autosave release];
	[super dealloc];
}

- (NSWindow *) window { return window; }

- (void) showFocusing: (NSView *)v
{
	[window makeKeyAndOrderFront: nil];
	[window makeFirstResponder: v];
}

- (NSString *) plainTitle
{
	return [[subjectField stringValue] length] ? [subjectField stringValue] : @"New Message";
}

- (void) setDirty: (BOOL)d
{
	dirty = d;
	[window setDocumentEdited: d];
}

- (void) controlTextDidChange: (NSNotification *)n
{
	if ([n object] == subjectField)
		[window setTitle: [self plainTitle]];
	[self setDirty: YES];
}

- (void) textDidChange: (NSNotification *)n
{
	[self setDirty: YES];
}

/* ---- attachments ---- */

- (void) removeAttachment: (NSButton *)b
{
	NSInteger i = [b tag];
	if (i >= 0 && i < (NSInteger)[attachments count]) {
		[attachments removeObjectAtIndex: i];
		[self layoutAttachments];
		[self setDirty: YES];
	}
}

/* one button per file ("name, 12 KB ✕": a click takes it off), wrapped onto as many lines as they need */
- (void) layoutAttachments
{
	NSView *cv = [window contentView];
	CGFloat W = NSWidth([cv bounds]);
	CGFloat top = NSMaxY([attachBar frame]);
	NSArray *old = [[[attachBar subviews] copy] autorelease];
	NSEnumerator *e = [old objectEnumerator];
	NSView *v;
	while ((v = [e nextObject]) != nil)
		[v removeFromSuperview];
	NSMutableArray *btns = [NSMutableArray array];
	NSUInteger i;
	for (i = 0; i < [attachments count]; i++) {
		Mail2Attachment *a = [attachments objectAtIndex: i];
		NSButton *b = [[[NSButton alloc] initWithFrame: NSZeroRect] autorelease];
		[b setTitle: [NSString stringWithFormat: @"%@, %@  ✕", [a filename], Mail2ByteSize([[a data] length])]];
		[b setImage: Mail2Icon(@"sb-attachment")];
		[b setImagePosition: NSImageLeft];
		[b setBezelStyle: NSRoundedBezelStyle];
		[b setFont: [NSFont systemFontOfSize: 11]];
		[b setTag: (NSInteger)i];
		[b setTarget: self];
		[b setAction: @selector(removeAttachment:)];
		[b setToolTip: @"Remove this attachment"];
		[b setRefusesFirstResponder: YES];
		[b sizeToFit];
		NSRect f = [b frame];
		f.size.width = MIN(MAX(NSWidth(f), 80), W - 24);
		f.size.height = 24;
		[b setFrame: f];
		[btns addObject: b];
	}
	/* rows from the top down */
	CGFloat x = 12, rows = [btns count] ? 1 : 0, lineH = 28;
	e = [btns objectEnumerator];
	NSButton *b;
	while ((b = [e nextObject]) != nil) {
		if (x > 12 && x + NSWidth([b frame]) > W - 12) {
			rows++;
			x = 12;
		}
		x += NSWidth([b frame]) + 6;
	}
	CGFloat h = rows ? rows * lineH + 6 : 0;
	[attachBar setFrame: NSMakeRect(0, top - h, W, h)];
	x = 12;
	CGFloat row = 0;
	e = [btns objectEnumerator];
	while ((b = [e nextObject]) != nil) {
		if (x > 12 && x + NSWidth([b frame]) > W - 12) {
			row++;
			x = 12;
		}
		[b setFrameOrigin: NSMakePoint(x, h - 3 - (row + 1) * lineH + 2)];
		[attachBar addSubview: b];
		x += NSWidth([b frame]) + 6;
	}
	[bodyScroll setFrame: NSMakeRect(0, 0, W, top - h)];
	[cv setNeedsDisplay: YES];
}

- (void) addAttachment: (Mail2Attachment *)a
{
	[attachments addObject: a];
}

- (void) attachFile: (id)sender
{
	NSOpenPanel *op = [NSOpenPanel openPanel];
	[op setAllowsMultipleSelection: YES];
	[op setCanChooseDirectories: NO];
	[op setTitle: @"Attach Files"];
	if ([op runModalForDirectory: [[NSUserDefaults standardUserDefaults] stringForKey: @"Mail2AttachDirectory"] file: nil types: nil] != NSOKButton)
		return;
	NSEnumerator *e = [[op filenames] objectEnumerator];
	NSString *path;
	unsigned long long total = 0;
	NSEnumerator *ae = [attachments objectEnumerator];
	Mail2Attachment *a;
	while ((a = [ae nextObject]) != nil)
		total += [[a data] length];
	while ((path = [e nextObject]) != nil) {
		NSData *d = [NSData dataWithContentsOfFile: path];
		if (d == nil) {
			NSRunAlertPanel(@"Cannot Attach", @"%@ could not be read.", @"OK", nil, nil, [path lastPathComponent]);
			continue;
		}
		total += [d length];
		[attachments addObject: [[[Mail2Attachment alloc] initWithName: [path lastPathComponent]
		    type: Mail2MimeTypeForFilename(path) data: d] autorelease]];
		[[NSUserDefaults standardUserDefaults] setObject: [path stringByDeletingLastPathComponent] forKey: @"Mail2AttachDirectory"];
	}
	if (total > 20 * 1024 * 1024)
		NSRunAlertPanel(@"Large Attachments", @"The attachments come to %@. Many mail servers refuse messages over 20 MB.",
		    @"OK", nil, nil, Mail2ByteSize(total));
	[self layoutAttachments];
	[self setDirty: YES];
}

/* ---- drafts ---- */

- (Mail2Session *) fromSession
{
	NSInteger fi = [fromPopup indexOfSelectedItem];
	return fi >= 0 && fi < (NSInteger)[sessions count] ? [sessions objectAtIndex: fi] : session;
}

- (BOOL) hasContent
{
	return [[toField stringValue] length] + [[ccField stringValue] length] + [[bccField stringValue] length] +
	    [[subjectField stringValue] length] + [[[bodyView string] stringByTrimmingCharactersInSet:
	    [NSCharacterSet whitespaceAndNewlineCharacterSet]] length] + [attachments count] > 0;
}

- (void) saveDraftQuietly: (BOOL)quiet
{
	if (saving || sending)
		return;
	Mail2Session *s = [self fromSession];
	NSString *mid = Mail2NewMessageID([[s account] email]);
	/* addresses that cannot be read yet are kept as they were typed: the draft is not sent */
	NSData *raw = Mail2BuildMessageEx([[s account] fromAddress], Mail2SplitAddresses([toField stringValue]),
	    Mail2SplitAddresses([ccField stringValue]), Mail2SplitAddresses([bccField stringValue]), [subjectField stringValue],
	    [bodyView string], inReplyTo, references, attachments, mid);
	if (raw == nil)
		raw = Mail2BuildMessageEx([[s account] fromAddress], nil, nil, nil, [subjectField stringValue],
		    [bodyView string], inReplyTo, references, attachments, mid);
	if (raw == nil) {
		if (!quiet)
			NSRunAlertPanel(@"Cannot Save", @"The draft could not be written.", @"OK", nil, nil);
		return;
	}
	saving = YES;
	[self setDirty: NO];	/* edits from now on are after this copy */
	[window setTitle: [NSString stringWithFormat: @"%@ (saving…)", [self plainTitle]]];
	[self retain];
	[s saveDraft: raw replacing: draftId completion: ^(NSString *err) {
		saving = NO;
		if (sent) {	/* sent while this copy was on its way: it goes too */
			if (err == nil)
				[s deleteDraft: mid];
			[window close];
			[self release];
			return;
		}
		[window setTitle: [self plainTitle]];
		if (err == nil) {
			ASSIGN(draftId, mid);
			if (closeAfterSave) {
				closeAfterSave = NO;
				[self setDirty: NO];
				[window close];
			}
		} else {
			BOOL tell = !quiet || closeAfterSave;
			[self setDirty: YES];
			closeAfterSave = NO;
			if (tell)
				NSRunAlertPanel(@"The Draft Was Not Saved", @"%@", @"OK", nil, nil, err);
		}
		[self release];
	}];
}

- (void) saveDraft: (id)sender
{
	[self saveDraftQuietly: NO];
}

- (void) autosaveFired: (NSTimer *)t
{
	if (dirty && [self hasContent])
		[self saveDraftQuietly: YES];
}

+ (Mail2Compose *) editDraft: (Mail2MessageInfo *)m parsed: (Mail2ParsedMessage *)p session: (Mail2Session *)s sessions: (NSArray *)all
{
	Mail2Compose *c = [[[Mail2Compose alloc] initWithSessions: all session: s] autorelease];
	[c->toField setStringValue: [m to] ? [m to] : @""];
	[c->ccField setStringValue: [m cc] ? [m cc] : @""];
	[c->bccField setStringValue: [p bcc] ? [p bcc] : @""];
	[c->subjectField setStringValue: [m subject] ? [m subject] : @""];
	[c->window setTitle: [c plainTitle]];
	[c->bodyView setString: [p body] ? [p body] : @""];
	[c->attachments addObjectsFromArray: [p attachments]];
	ASSIGN(c->inReplyTo, [p inReplyTo]);
	ASSIGN(c->references, [p references]);
	ASSIGN(c->draftId, [p messageId] ? [p messageId] : [m messageId]);
	[c layoutAttachments];
	[c setDirty: NO];
	[c showFocusing: [[c->toField stringValue] length] ? (NSView *)c->bodyView : (NSView *)c->toField];
	return c;
}

+ (Mail2Compose *) newMessageWithSessions: (NSArray *)all to: (NSString *)to
{
	Mail2Compose *c = [[[Mail2Compose alloc] initWithSessions: all session: nil] autorelease];
	if (to)
		[c->toField setStringValue: to];
	[c showFocusing: to ? (NSView *)c->subjectField : (NSView *)c->toField];
	return c;
}

static NSString *
own_address_filter(NSArray *addrs, NSString *mine, NSMutableSet *seen)
{
	NSMutableArray *r = [NSMutableArray array];
	NSEnumerator *e = [addrs objectEnumerator];
	NSString *a;
	while ((a = [e nextObject]) != nil) {
		NSString *bare = [Mail2AddressPart(a) lowercaseString];
		if ([bare isEqualToString: [mine lowercaseString]] || [seen containsObject: bare])
			continue;
		[seen addObject: bare];
		[r addObject: a];
	}
	return [r componentsJoinedByString: @", "];
}

- (void) setOriginal: (Mail2MessageInfo *)m parsed: (Mail2ParsedMessage *)p
{
	ASSIGN(original, m);
	NSString *mid = [p messageId] ? [p messageId] : [m messageId];
	ASSIGN(inReplyTo, mid);
	NSMutableArray *refs = [NSMutableArray arrayWithArray: [p references] ? [p references] : [NSArray array]];
	if ([refs count] == 0 && [m inReplyTo])
		[refs addObject: [m inReplyTo]];
	if (mid)
		[refs addObject: mid];
	ASSIGN(references, refs);
}

+ (Mail2Compose *) replyTo: (Mail2MessageInfo *)m parsed: (Mail2ParsedMessage *)p session: (Mail2Session *)s
                  sessions: (NSArray *)all replyAll: (BOOL)replyAll
{
	Mail2Compose *c = [[[Mail2Compose alloc] initWithSessions: all session: s] autorelease];
	NSString *mine = [[s account] email];
	NSMutableSet *seen = [NSMutableSet set];
	NSString *sender = [[m replyTo] length] ? [m replyTo]
	    : ([[m fromName] length] ? [NSString stringWithFormat: @"%@ <%@>", [m fromName], [m fromAddr]] : [m fromAddr]);
	NSString *to = own_address_filter(Mail2SplitAddresses(sender ? sender : @""), mine, seen);
	if ([to length] == 0)	/* replying to one's own message: to its recipients */
		to = sender;
	if (replyAll) {
		NSString *more = own_address_filter(Mail2SplitAddresses([m to] ? [m to] : @""), mine, seen);
		if ([more length])
			to = [NSString stringWithFormat: @"%@, %@", to, more];
		[c->ccField setStringValue: own_address_filter(Mail2SplitAddresses([m cc] ? [m cc] : @""), mine, seen)];
	}
	[c->toField setStringValue: to ? to : @""];
	[c->subjectField setStringValue: strip_prefix([m subject], @"Re:")];
	[c->window setTitle: [c->subjectField stringValue]];
	[c setOriginal: m parsed: p];
	NSString *body = [NSString stringWithFormat: @"\n\nOn %@, %@ wrote:\n\n%@\n", Mail2LongDate([m date]), [m sender],
	    quote([[p body] stringByTrimmingCharactersInSet: [NSCharacterSet whitespaceAndNewlineCharacterSet]])];
	[c->bodyView setString: body];
	[c->bodyView setSelectedRange: NSMakeRange(0, 0)];
	[c showFocusing: c->bodyView];
	return c;
}

+ (Mail2Compose *) forward: (Mail2MessageInfo *)m parsed: (Mail2ParsedMessage *)p session: (Mail2Session *)s sessions: (NSArray *)all
{
	Mail2Compose *c = [[[Mail2Compose alloc] initWithSessions: all session: s] autorelease];
	[c->subjectField setStringValue: strip_prefix([m subject], @"Fwd:")];
	[c->window setTitle: [c->subjectField stringValue]];
	NSString *from = [[m fromName] length] ? [NSString stringWithFormat: @"%@ <%@>", [m fromName], [m fromAddr]] : [m fromAddr];
	NSMutableString *body = [NSMutableString stringWithString: @"\n\nBegin forwarded message:\n\n"];
	[body appendFormat: @"From: %@\n", from ? from : @""];
	[body appendFormat: @"Subject: %@\n", [m subject] ? [m subject] : @""];
	[body appendFormat: @"Date: %@\n", Mail2LongDate([m date])];
	if ([[m to] length]) [body appendFormat: @"To: %@\n", [m to]];
	if ([[m cc] length]) [body appendFormat: @"Cc: %@\n", [m cc]];
	[body appendFormat: @"\n%@\n", [p body] ? [p body] : @""];
	[c->bodyView setString: body];
	[c->attachments addObjectsFromArray: [p attachments]];	/* forwarded with the message, as Apple Mail does */
	[c layoutAttachments];
	[c->bodyView setSelectedRange: NSMakeRange(0, 0)];
	[c showFocusing: c->toField];
	return c;
}

- (void) send: (id)sender
{
	if (sending)
		return;
	NSArray *to = Mail2SplitAddresses([toField stringValue]);
	NSArray *cc = Mail2SplitAddresses([ccField stringValue]);
	NSArray *bcc = Mail2SplitAddresses([bccField stringValue]);
	if ([to count] + [cc count] + [bcc count] == 0) {
		NSRunAlertPanel(@"No Recipients", @"Enter at least one address in To, Cc or Bcc.", @"OK", nil, nil);
		[window makeFirstResponder: toField];
		return;
	}
	if ([[subjectField stringValue] length] == 0 &&
	    NSRunAlertPanel(@"No Subject", @"Send this message without a subject?", @"Send", @"Cancel", nil) != NSAlertDefaultReturn)
		return;
	Mail2Session *s = [self fromSession];
	NSData *raw = Mail2BuildMessageEx([[s account] fromAddress], to, cc, nil, [subjectField stringValue], [bodyView string],
	    inReplyTo, references, attachments, nil);
	if (raw == nil) {
		NSRunAlertPanel(@"Cannot Send", @"One of the addresses could not be read. Check To, Cc and Bcc.", @"OK", nil, nil);
		return;
	}
	NSMutableArray *rcpts = [NSMutableArray array];
	NSEnumerator *e = [[[to arrayByAddingObjectsFromArray: cc] arrayByAddingObjectsFromArray: bcc] objectEnumerator];
	NSString *a;
	while ((a = [e nextObject]) != nil)
		[rcpts addObject: Mail2AddressPart(a)];

	sending = YES;
	[sendButton setEnabled: NO];
	[window setTitle: [NSString stringWithFormat: @"Sending: %@", [subjectField stringValue]]];
	[self retain];
	[s sendMessage: raw recipients: rcpts replyingTo: original completion: ^(NSString *err) {
		sending = NO;
		[sendButton setEnabled: YES];
		if (err == nil) {
			sent = YES;
			[s deleteDraft: draftId];	/* sent: the draft has done its job (one still being saved goes when it lands) */
			[self setDirty: NO];
			if (!saving)
				[window close];
		} else {
			[window setTitle: [self plainTitle]];
			NSRunAlertPanel(@"The Message Was Not Sent", @"%@", @"OK", nil, nil, err);
		}
		[self release];
	}];
}

- (BOOL) windowShouldClose: (id)w
{
	if (sent)
		return YES;
	if (sending || saving)
		return NO;
	if (!dirty || ![self hasContent])
		return YES;
	NSInteger r = NSRunAlertPanel(@"Save This Message as a Draft?", @"You can finish it later from the Drafts mailbox.",
	    @"Save", @"Don't Save", @"Cancel");
	if (r == NSAlertDefaultReturn) {
		closeAfterSave = YES;
		[self saveDraftQuietly: NO];
		return NO;
	}
	return r == NSAlertAlternateReturn;
}

- (void) windowWillClose: (NSNotification *)n
{
	[autosave invalidate];
	DESTROY(autosave);
	[self retain];
	[open_windows removeObject: self];
	[self autorelease];
}

@end
