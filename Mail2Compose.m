/* Mail2Compose: the compose window (see Mail2Compose.h). */
#import "Mail2Compose.h"
#import "Mail2Views.h"
#import "Mail2Util.h"
#import "Mail2RichText.h"
#import "Mail2Outbox.h"
#import "Mail2Spell.h"
#include <ctype.h>
#include <math.h>

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

/* the body: files dropped on it are attached (not pasted in as their paths) */
@implementation Mail2BodyView
- (void) setFileTarget: (id)t { fileTarget = t; }

- (void) dealloc
{
	[NSObject cancelPreviousPerformRequestsWithTarget: self];
	[misspelled release];
	[super dealloc];
}

/* ---- spelling (Mail2Spell, Hunspell) ---- */

- (void) checkSpellingSoon
{
	[NSObject cancelPreviousPerformRequestsWithTarget: self selector: @selector(checkSpelling) object: nil];
	[self performSelector: @selector(checkSpelling) withObject: nil afterDelay: 0.6];
}

- (void) checkSpelling
{
	Mail2Spell *sp = [Mail2Spell shared];
	NSLayoutManager *lm = [self layoutManager];
	NSUInteger n = [[self textStorage] length];
	BOOL temp = [lm respondsToSelector: @selector(addTemporaryAttribute:value:forCharacterRange:)];
	if (sp == nil || !temp)
		return;
	[lm removeTemporaryAttribute: NSUnderlineStyleAttributeName forCharacterRange: NSMakeRange(0, n)];
	[lm removeTemporaryAttribute: NSUnderlineColorAttributeName forCharacterRange: NSMakeRange(0, n)];
	NSArray *bad = [sp misspellingsIn: [self string]];
	NSRange sel = [self selectedRange];
	NSEnumerator *e = [bad objectEnumerator];
	NSValue *v;
	NSMutableArray *kept = [NSMutableArray array];
	while ((v = [e nextObject]) != nil) {
		NSRange r = [v rangeValue];
		if (sel.length == 0 && sel.location == NSMaxRange(r))
			continue;	/* the word being typed */
		[lm addTemporaryAttribute: NSUnderlineStyleAttributeName value: [NSNumber numberWithInt: NSUnderlineStyleSingle] forCharacterRange: r];
		[lm addTemporaryAttribute: NSUnderlineColorAttributeName value: [NSColor redColor] forCharacterRange: r];
		[kept addObject: v];
	}
	ASSIGN(misspelled, kept);
	[self setNeedsDisplay: YES];
}

- (NSRange) misspellingAt: (NSUInteger)i
{
	NSEnumerator *e = [misspelled objectEnumerator];
	NSValue *v;
	while ((v = [e nextObject]) != nil)
		if (NSLocationInRange(i, [v rangeValue]))
			return [v rangeValue];
	return NSMakeRange(NSNotFound, 0);
}

- (void) replaceMisspelling: (NSMenuItem *)it
{
	NSRange r = NSRangeFromString([[it representedObject] objectAtIndex: 0]);
	NSString *with = [[it representedObject] objectAtIndex: 1];
	if (NSMaxRange(r) <= [[self textStorage] length] && [self shouldChangeTextInRange: r replacementString: with]) {
		[[self textStorage] replaceCharactersInRange: r withString: with];
		[self didChangeText];
	}
	[self checkSpelling];
}

- (void) learnSpelling: (NSMenuItem *)it
{
	[[Mail2Spell shared] learn: [it representedObject]];
	[self checkSpelling];
}

/* a right-click on an underlined word: its suggestions and Learn Spelling, then the usual items */
- (NSMenu *) menuForEvent: (NSEvent *)ev
{
	NSMenu *base = [super menuForEvent: ev];
	NSPoint p = [self convertPoint: [ev locationInWindow] fromView: nil];
	NSUInteger i = [self characterIndexForPoint: [[self window] convertBaseToScreen: [ev locationInWindow]]];
	(void)p;
	NSRange r = [self misspellingAt: i];
	if (r.location == NSNotFound)
		return base;
	NSString *word = [[self string] substringWithRange: r];
	NSMenu *m = [[[NSMenu alloc] initWithTitle: @""] autorelease];
	NSArray *sug = [[Mail2Spell shared] suggestionsFor: word];
	NSEnumerator *e = [sug objectEnumerator];
	NSString *sg;
	while ((sg = [e nextObject]) != nil) {
		NSMenuItem *it = (NSMenuItem *)[m addItemWithTitle: sg action: @selector(replaceMisspelling:) keyEquivalent: @""];
		[it setTarget: self];
		[it setRepresentedObject: [NSArray arrayWithObjects: NSStringFromRange(r), sg, nil]];
	}
	if ([sug count] == 0)
		[[m addItemWithTitle: @"No Guesses Found" action: NULL keyEquivalent: @""] setEnabled: NO];
	[m addItem: [NSMenuItem separatorItem]];
	NSMenuItem *learn = (NSMenuItem *)[m addItemWithTitle: [NSString stringWithFormat: @"Learn “%@”", word]
	    action: @selector(learnSpelling:) keyEquivalent: @""];
	[learn setTarget: self];
	[learn setRepresentedObject: word];
	if (base != nil && [base numberOfItems] > 0) {
		[m addItem: [NSMenuItem separatorItem]];
		NSArray *items = [[[base itemArray] copy] autorelease];
		NSEnumerator *be = [items objectEnumerator];
		NSMenuItem *bi;
		while ((bi = [be nextObject]) != nil) {
			[base removeItem: bi];
			[m addItem: bi];
		}
	}
	return m;
}
- (NSDragOperation) draggingEntered: (id <NSDraggingInfo>)info
{
	if ([[[info draggingPasteboard] types] containsObject: NSFilenamesPboardType])
		return NSDragOperationCopy;
	return [super draggingEntered: info];
}
- (NSDragOperation) draggingUpdated: (id <NSDraggingInfo>)info
{
	if ([[[info draggingPasteboard] types] containsObject: NSFilenamesPboardType])
		return NSDragOperationCopy;
	return [super draggingUpdated: info];
}
- (BOOL) performDragOperation: (id <NSDraggingInfo>)info
{
	NSArray *files = [[info draggingPasteboard] propertyListForType: NSFilenamesPboardType];
	if ([files count] && [fileTarget respondsToSelector: @selector(attachPaths:)]) {
		[fileTarget attachPaths: files];
		return YES;
	}
	return [super performDragOperation: info];
}
@end

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
	lastLengths = [[NSMutableDictionary alloc] init];

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
	/* every account's addresses, its aliases after it; the account's own address chosen */
	while ((ss = [e nextObject]) != nil) {
		NSEnumerator *ae = [[[ss account] fromAddresses] objectEnumerator];
		NSString *addr;
		BOOL firstOfAccount = YES;
		while ((addr = [ae nextObject]) != nil) {
			[fromPopup addItemWithTitle: addr];
			[[fromPopup lastItem] setRepresentedObject: [NSArray arrayWithObjects: ss, addr, nil]];
			if (ss == session && firstOfAccount)
				[fromPopup selectItem: [fromPopup lastItem]];
			firstOfAccount = NO;
		}
	}
	[fromPopup setTarget: self];
	[fromPopup setAction: @selector(fromChanged:)];
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
	bodyView = [[Mail2BodyView alloc] initWithFrame: NSMakeRect(0, 0, cs.width, cs.height)];
	[(Mail2BodyView *)bodyView setFileTarget: self];
	[bodyView registerForDraggedTypes: [NSArray arrayWithObject: NSFilenamesPboardType]];
	/* rich text unless the user prefers plain (Mail2ComposeRich NO, or Format > Make Plain Text) */
	NSUserDefaults *ud = [NSUserDefaults standardUserDefaults];
	rich = [ud objectForKey: @"Mail2ComposeRich"] == nil || [ud boolForKey: @"Mail2ComposeRich"];
	[bodyView setRichText: rich];
	[bodyView setImportsGraphics: rich];
	[bodyView setTypingAttributes: [NSDictionary dictionaryWithObject: [NSFont systemFontOfSize: 13] forKey: NSFontAttributeName]];
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
	[insertedSig release]; [lastLengths release];
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

/* ---- signatures ---- */

/* "\n\n-- \nsignature" for the account, or "" */
static NSString *
signature_block(Mail2Session *s)
{
	NSString *sig = [[s account] signature];
	return [sig length] ? [NSString stringWithFormat: @"\n\n-- \n%@", sig] : @"";
}

/* another From: its signature replaces the one in the body */
- (void) fromChanged: (id)sender
{
	NSString *now = signature_block([self fromSession]);
	NSString *body = [bodyView string];
	NSRange r = [insertedSig length] ? [body rangeOfString: insertedSig] : NSMakeRange(NSNotFound, 0);
	if (r.location != NSNotFound)
		[bodyView replaceCharactersInRange: r withString: now];
	else if ([now length] && [insertedSig length] == 0 && [[body stringByTrimmingCharactersInSet:
	    [NSCharacterSet whitespaceAndNewlineCharacterSet]] length] == 0)
		[bodyView setString: now];
	ASSIGN(insertedSig, now);
}

/* ---- address completion ---- */

/* As in Apple Mail: typing in To, Cc or Bcc completes the address being typed from the people in the index, the
 * completed part selected so that typing on replaces it and Tab, Return or a comma keeps it. Only when the caret is
 * at the end and the text grew (deleting never completes). */
- (void) completeAddressIn: (NSTextField *)f editor: (NSText *)ed
{
	NSString *text = [ed string];
	NSUInteger len = [text length];
	NSRange sel = [ed selectedRange];
	NSUInteger last = [[lastLengths objectForKey: [NSValue valueWithNonretainedObject: f]] unsignedIntegerValue];
	[lastLengths setObject: [NSNumber numberWithUnsignedInteger: len] forKey: [NSValue valueWithNonretainedObject: f]];
	if (len <= last || sel.location != len || sel.length != 0)
		return;
	NSRange comma = [text rangeOfString: @"," options: NSBackwardsSearch];
	NSUInteger start = comma.location == NSNotFound ? 0 : comma.location + 1;
	while (start < len && [text characterAtIndex: start] == ' ')
		start++;
	NSString *frag = [text substringFromIndex: start];
	if ([frag length] < 2 || [frag rangeOfString: @"<"].location != NSNotFound)
		return;
	NSEnumerator *e = [[[Mail2Store sharedStore] addressesMatching: frag limit: 8] objectEnumerator];
	NSString *m;
	while ((m = [e nextObject]) != nil) {
		if ([[m lowercaseString] hasPrefix: [frag lowercaseString]] && [m length] > [frag length]) {
			/* the typed part keeps its case; the rest is the completion, selected */
			[ed replaceCharactersInRange: NSMakeRange(len, 0) withString: [m substringFromIndex: [frag length]]];
			[ed setSelectedRange: NSMakeRange(len, [m length] - [frag length])];
			return;
		}
	}
}

- (void) controlTextDidChange: (NSNotification *)n
{
	id o = [n object];
	if (o == subjectField)
		[window setTitle: [self plainTitle]];
	else if (o == toField || o == ccField || o == bccField) {
		NSText *ed = [[n userInfo] objectForKey: @"NSFieldEditor"];
		if (ed == nil)
			ed = [window fieldEditor: NO forObject: o];
		if (ed != nil)
			[self completeAddressIn: o editor: ed];
	}
	[self setDirty: YES];
}

- (void) textDidChange: (NSNotification *)n
{
	[(Mail2BodyView *)bodyView checkSpellingSoon];
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
	[self attachPaths: [op filenames]];
}

/* files from the open panel or dropped on the window */
- (void) attachPaths: (NSArray *)paths
{
	NSEnumerator *e = [paths objectEnumerator];
	NSString *path;
	unsigned long long total = 0;
	NSEnumerator *ae = [attachments objectEnumerator];
	Mail2Attachment *a;
	while ((a = [ae nextObject]) != nil)
		total += [[a data] length];
	while ((path = [e nextObject]) != nil) {
		BOOL dir = NO;
		if ([[NSFileManager defaultManager] fileExistsAtPath: path isDirectory: &dir] && dir) {
			NSRunAlertPanel(@"Cannot Attach", @"%@ is a folder: attach the files in it.", @"OK", nil, nil, [path lastPathComponent]);
			continue;
		}
		NSData *d = [NSData dataWithContentsOfFile: path];
		if (d == nil) {
			NSRunAlertPanel(@"Cannot Attach", @"%@ could not be read.", @"OK", nil, nil, [path lastPathComponent]);
			continue;
		}
		total += [d length];
		if (rich && [Mail2MimeTypeForFilename(path) hasPrefix: @"image/"] && [d length] <= 10 * 1024 * 1024 &&
		    [self insertPicture: d named: [path lastPathComponent]])
			continue;
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
	NSArray *c = [[fromPopup selectedItem] representedObject];
	return c ? [c objectAtIndex: 0] : session;
}

/* the From line chosen: the account's address or one of its aliases */
- (NSString *) fromLine
{
	NSArray *c = [[fromPopup selectedItem] representedObject];
	return c ? [c objectAtIndex: 1] : [[session account] fromAddress];
}

/* a reply goes from the address the original was sent to, when that is one of the aliases */
- (void) chooseFromFor: (Mail2MessageInfo *)m
{
	NSString *all = [[NSString stringWithFormat: @"%@, %@", [m to] ? [m to] : @"", [m cc] ? [m cc] : @""] lowercaseString];
	NSInteger i;
	for (i = 0; i < [fromPopup numberOfItems]; i++) {
		NSArray *c = [[fromPopup itemAtIndex: i] representedObject];
		if ([c objectAtIndex: 0] != session)
			continue;
		NSString *addr = [Mail2AddressPart([c objectAtIndex: 1]) lowercaseString];
		if ([addr length] && [all rangeOfString: addr].location != NSNotFound) {
			[fromPopup selectItemAtIndex: i];
			return;
		}
	}
}

/* ---- the message ---- */

/* the body as it goes out: plain text, or plain text and HTML with its pictures when there is formatting */
- (NSData *) buildFrom: (NSString *)from to: (NSArray *)to cc: (NSArray *)cc bcc: (NSArray *)bcc messageId: (NSString *)mid
{
	NSTextStorage *ts = [bodyView textStorage];
	if (rich && Mail2RichTextHasFormatting(ts, [NSFont systemFontOfSize: 13])) {
		NSMutableArray *imgs = [NSMutableArray array];
		NSString *plain = nil;
		NSString *html = Mail2HTMLFromRichText(ts, imgs, &plain);
		return Mail2BuildMessageRich(from, to, cc, bcc, [subjectField stringValue], plain, html, imgs, inReplyTo, references,
		    attachments, mid);
	}
	return Mail2BuildMessageEx(from, to, cc, bcc, [subjectField stringValue], [bodyView string], inReplyTo, references,
	    attachments, mid);
}

/* drafts keep their formatting here (RTFD by Message-ID): the server's copy is HTML, which this window cannot read back */
static NSString *
rtfd_path(NSString *mid)
{
	NSMutableString *n = [NSMutableString string];
	NSUInteger i;
	for (i = 0; i < [mid length]; i++) {
		unichar c = [mid characterAtIndex: i];
		[n appendFormat: @"%C", (unichar)(isalnum(c) || c == '.' || c == '-' ? c : '_')];
	}
	NSString *dir = [Mail2SupportDirectory() stringByAppendingPathComponent: @"DraftText"];
	[[NSFileManager defaultManager] createDirectoryAtPath: dir withIntermediateDirectories: YES attributes: nil error: NULL];
	return [dir stringByAppendingPathComponent: [n stringByAppendingPathExtension: @"rtfd"]];
}

- (void) keepRichDraft: (NSString *)mid replacing: (NSString *)old
{
	if (old != nil)
		[[NSFileManager defaultManager] removeItemAtPath: rtfd_path(old) error: NULL];
	NSTextStorage *ts = [bodyView textStorage];
	if (!rich || !Mail2RichTextHasFormatting(ts, [NSFont systemFontOfSize: 13]))
		return;
	NSData *d = [ts RTFDFromRange: NSMakeRange(0, [ts length]) documentAttributes: [NSDictionary dictionary]];
	[d writeToFile: rtfd_path(mid) atomically: YES];
}

/* ---- Format ---- */

- (void) addLink: (id)sender
{
	NSRange sel = [bodyView selectedRange];
	NSString *u = Mail2AskString(@"Add Link", @"Link to (a web address):", @"https://", @"Add");
	if (u == nil || [u isEqualToString: @"https://"])
		return;
	if ([u rangeOfString: @":"].location == NSNotFound)
		u = [@"https://" stringByAppendingString: u];
	NSTextStorage *ts = [bodyView textStorage];
	if (sel.length == 0) {	/* nothing selected: the address itself, linked */
		NSDictionary *ta = [bodyView typingAttributes];
		[ts replaceCharactersInRange: sel withAttributedString: [[[NSAttributedString alloc] initWithString: u attributes: ta] autorelease]];
		sel = NSMakeRange(sel.location, [u length]);
	}
	[ts addAttribute: NSLinkAttributeName value: u range: sel];
	[self setDirty: YES];
}

/* the paragraphs touched by the selection, last first (so that edits do not move the next ones) */
- (NSArray *) selectedParagraphStarts
{
	NSString *t = [bodyView string];
	NSRange sel = [bodyView selectedRange];
	NSRange para = [t paragraphRangeForRange: sel];
	NSMutableArray *starts = [NSMutableArray array];
	NSUInteger i = para.location;
	while (i < NSMaxRange(para) || (i == para.location && [starts count] == 0)) {
		[starts insertObject: [NSNumber numberWithUnsignedInteger: i] atIndex: 0];
		NSRange r = [t paragraphRangeForRange: NSMakeRange(i, 0)];
		if (NSMaxRange(r) <= i)
			break;
		i = NSMaxRange(r);
	}
	return starts;
}

- (void) prefixParagraphs: (NSString *(^)(NSString *line, NSUInteger index, NSUInteger count))change
{
	NSTextStorage *ts = [bodyView textStorage];
	NSArray *starts = [self selectedParagraphStarts];
	NSUInteger n = [starts count], k = 0;
	[ts beginEditing];
	NSEnumerator *e = [starts objectEnumerator];
	NSNumber *st;
	while ((st = [e nextObject]) != nil) {
		NSRange r = [[ts string] paragraphRangeForRange: NSMakeRange([st unsignedIntegerValue], 0)];
		NSString *line = [[ts string] substringWithRange: r];
		NSString *now = change(line, n - 1 - k, n);
		k++;
		if (now == nil || [now isEqualToString: line])
			continue;
		/* only the start of the line changes: its formatting stays */
		NSUInteger common = 0;
		while (common < [line length] && common < [now length] && [line characterAtIndex: [line length] - 1 - common] ==
		    [now characterAtIndex: [now length] - 1 - common])
			common++;
		NSRange head = NSMakeRange(r.location, [line length] - common);
		NSDictionary *at = [ts length] ? [ts attributesAtIndex: MIN(r.location, [ts length] - 1) effectiveRange: NULL]
		    : [bodyView typingAttributes];
		[ts replaceCharactersInRange: head withAttributedString: [[[NSAttributedString alloc] initWithString:
		    [now substringToIndex: [now length] - common] attributes: at] autorelease]];
	}
	[ts endEditing];
	[self setDirty: YES];
}

static NSString *
strip_list(NSString *l)
{
	if ([l hasPrefix: @"• "])
		return [l substringFromIndex: 2];
	NSUInteger i = 0;
	while (i < [l length] && isdigit([l characterAtIndex: i]))
		i++;
	if (i > 0 && i + 1 < [l length] && [l characterAtIndex: i] == '.' && [l characterAtIndex: i + 1] == ' ')
		return [l substringFromIndex: i + 2];
	return l;
}

- (void) toggleBulletList: (id)sender
{
	NSString *first = [[bodyView string] substringWithRange: [[bodyView string] paragraphRangeForRange: [bodyView selectedRange]]];
	BOOL off = [first hasPrefix: @"• "];
	[self prefixParagraphs: ^NSString *(NSString *l, NSUInteger i, NSUInteger n) {
		return off ? strip_list(l) : [@"• " stringByAppendingString: strip_list(l)];
	}];
}

- (void) toggleNumberedList: (id)sender
{
	NSString *first = [[bodyView string] substringWithRange: [[bodyView string] paragraphRangeForRange: [bodyView selectedRange]]];
	BOOL off = [first length] > 2 && isdigit([first characterAtIndex: 0]) && [strip_list(first) length] < [first length];
	[self prefixParagraphs: ^NSString *(NSString *l, NSUInteger i, NSUInteger n) {
		return off ? strip_list(l) : [NSString stringWithFormat: @"%lu. %@", (unsigned long)(i + 1), strip_list(l)];
	}];
}

- (void) increaseQuoteLevel: (id)sender
{
	[self prefixParagraphs: ^NSString *(NSString *l, NSUInteger i, NSUInteger n) {
		return [l hasPrefix: @">"] ? [@">" stringByAppendingString: l] : [@"> " stringByAppendingString: l];
	}];
}

- (void) decreaseQuoteLevel: (id)sender
{
	[self prefixParagraphs: ^NSString *(NSString *l, NSUInteger i, NSUInteger n) {
		if ([l hasPrefix: @"> "]) return [l substringFromIndex: 2];
		if ([l hasPrefix: @">"]) return [l substringFromIndex: 1];
		return l;
	}];
}

/* plain: formatting goes, pictures become attached files; rich: the formatting tools come back */
- (void) togglePlainText: (id)sender
{
	NSTextStorage *ts = [bodyView textStorage];
	if (rich) {
		if (Mail2RichTextHasFormatting(ts, [NSFont systemFontOfSize: 13]) &&
		    NSRunAlertPanel(@"Make Plain Text?", @"The formatting goes; pictures in the text become attachments.",
		        @"Make Plain Text", @"Cancel", nil) != NSAlertDefaultReturn)
			return;
		NSMutableArray *imgs = [NSMutableArray array];
		NSString *plain = nil;
		Mail2HTMLFromRichText(ts, imgs, &plain);
		NSEnumerator *e = [imgs objectEnumerator];
		Mail2Attachment *a;
		while ((a = [e nextObject]) != nil) {
			[a setContentId: nil];
			[attachments addObject: a];
		}
		rich = NO;
		[bodyView setRichText: NO];
		[bodyView setImportsGraphics: NO];
		[bodyView setString: plain ? plain : @""];
		[bodyView setFont: [NSFont systemFontOfSize: 13]];
		[self layoutAttachments];
	} else {
		rich = YES;
		[bodyView setRichText: YES];
		[bodyView setImportsGraphics: YES];
	}
	[self setDirty: YES];
}

- (BOOL) validateMenuItem: (NSMenuItem *)item
{
	SEL a = [item action];
	if (a == @selector(togglePlainText:))
		[item setTitle: rich ? @"Make Plain Text" : @"Make Rich Text"];
	if (a == @selector(addLink:) || a == @selector(toggleBulletList:) || a == @selector(toggleNumberedList:))
		return rich || a != @selector(addLink:);
	return YES;
}

/* a picture file dropped or attached in rich text goes into the text, where the caret is */
- (BOOL) insertPicture: (NSData *)d named: (NSString *)name
{
	NSImage *img = [[[NSImage alloc] initWithData: d] autorelease];
	if (img == nil || [img size].width < 1)
		return NO;
	NSSize sz = [img size];
	CGFloat maxW = MAX(100, NSWidth([bodyView frame]) - 40);
	if (sz.width > maxW) {
		[img setScalingAllowed: YES];
		[img setSize: NSMakeSize(maxW, floor(sz.height * maxW / sz.width))];
	}
	NSFileWrapper *fw = [[[NSFileWrapper alloc] initRegularFileWithContents: d] autorelease];
	[fw setPreferredFilename: name];
	NSTextAttachment *ta = [[[NSTextAttachment alloc] initWithFileWrapper: fw] autorelease];
	NSTextAttachmentCell *cell = [[[NSTextAttachmentCell alloc] initImageCell: img] autorelease];
	[ta setAttachmentCell: cell];
	NSRange sel = [bodyView selectedRange];
	[[bodyView textStorage] replaceCharactersInRange: sel withAttributedString: [NSAttributedString attributedStringWithAttachment: ta]];
	[bodyView setSelectedRange: NSMakeRange(sel.location + 1, 0)];
	return YES;
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
	NSData *raw = [self buildFrom: [self fromLine] to: Mail2SplitAddresses([toField stringValue])
	    cc: Mail2SplitAddresses([ccField stringValue]) bcc: Mail2SplitAddresses([bccField stringValue]) messageId: mid];
	if (raw == nil)
		raw = [self buildFrom: [self fromLine] to: nil cc: nil bcc: nil messageId: mid];
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
			[self keepRichDraft: mid replacing: draftId];
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
	/* the draft's formatting, when this machine kept it */
	NSString *mid = [p messageId] ? [p messageId] : [m messageId];
	NSData *rtfd = mid ? [NSData dataWithContentsOfFile: rtfd_path(mid)] : nil;
	NSAttributedString *kept = rtfd ? [[[NSAttributedString alloc] initWithRTFD: rtfd documentAttributes: NULL] autorelease] : nil;
	if (kept != nil && c->rich)
		[[c->bodyView textStorage] setAttributedString: kept];
	else
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
	ASSIGN(c->insertedSig, signature_block([c fromSession]));
	[c->bodyView setString: c->insertedSig];
	[c->bodyView setSelectedRange: NSMakeRange(0, 0)];
	[c showFocusing: to ? (NSView *)c->subjectField : (NSView *)c->toField];
	return c;
}

+ (Mail2Compose *) newMessageWithSessions: (NSArray *)all mailto: (NSString *)url
{
	NSDictionary *d = Mail2ParseMailto(url);
	Mail2Compose *c = [self newMessageWithSessions: all to: [d objectForKey: @"To"]];
	if ([d objectForKey: @"Cc"]) [c->ccField setStringValue: [d objectForKey: @"Cc"]];
	if ([d objectForKey: @"Bcc"]) [c->bccField setStringValue: [d objectForKey: @"Bcc"]];
	if ([d objectForKey: @"Subject"]) {
		[c->subjectField setStringValue: [d objectForKey: @"Subject"]];
		[c->window setTitle: [c plainTitle]];
	}
	if ([d objectForKey: @"Body"])
		[c->bodyView setString: [[d objectForKey: @"Body"] stringByAppendingString: [c->bodyView string]]];
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
	[c chooseFromFor: m];
	NSString *body = [NSString stringWithFormat: @"\n\nOn %@, %@ wrote:\n\n%@\n", Mail2LongDate([m date]), [m sender],
	    quote([[p body] stringByTrimmingCharactersInSet: [NSCharacterSet whitespaceAndNewlineCharacterSet]])];
	ASSIGN(c->insertedSig, signature_block(s));
	[c->bodyView setString: [c->insertedSig stringByAppendingString: body]];
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
	ASSIGN(c->insertedSig, signature_block(s));
	NSMutableString *body = [NSMutableString stringWithFormat: @"%@\n\nBegin forwarded message:\n\n", c->insertedSig];
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

/* Send and Send Later: the message goes to the Outbox (Mail2Outbox.h), which sends it when it is due -- after the Undo
 * Send moment (Mail2UndoSendDelay seconds, 5) or at the time chosen -- and keeps trying while the network is away */
- (void) queueAt: (NSDate *)when undoable: (BOOL)undoable
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
	NSString *mid = Mail2NewMessageID([[s account] email]);
	NSData *raw = [self buildFrom: [self fromLine] to: to cc: cc bcc: nil messageId: mid];
	if (raw == nil) {
		NSRunAlertPanel(@"Cannot Send", @"One of the addresses could not be read. Check To, Cc and Bcc.", @"OK", nil, nil);
		return;
	}
	NSMutableArray *rcpts = [NSMutableArray array];
	NSEnumerator *e = [[[to arrayByAddingObjectsFromArray: cc] arrayByAddingObjectsFromArray: bcc] objectEnumerator];
	NSString *a;
	while ((a = [e nextObject]) != nil)
		[rcpts addObject: Mail2AddressPart(a)];
	NSMutableDictionary *d = [NSMutableDictionary dictionaryWithObjectsAndKeys:
	    [[s account] identifier], @"Account", rcpts, @"Recipients", when, @"SendAt", mid, @"MessageId",
	    [subjectField stringValue], @"Subject", [toField stringValue], @"To", [ccField stringValue], @"Cc",
	    [bccField stringValue], @"Bcc", [self fromLine], @"From", nil];
	if (undoable)
		[d setObject: [NSNumber numberWithBool: YES] forKey: @"Undoable"];
	if (followUpDays > 0)
		[d setObject: [NSNumber numberWithInt: followUpDays] forKey: @"FollowUpDays"];
	if (draftId)
		[d setObject: draftId forKey: @"Draft"];
	if (original)
		[d setObject: [NSNumber numberWithLongLong: [original rowid]] forKey: @"ReplyTo"];
	/* its formatting, for Undo or an edit from the Outbox */
	[self keepRichDraft: mid replacing: nil];
	if ([[Mail2Outbox shared] add: raw details: d] == nil) {
		NSRunAlertPanel(@"Cannot Send", @"The message could not be put in the Outbox (is the disk full?).", @"OK", nil, nil);
		return;
	}
	sent = YES;
	[self setDirty: NO];
	if (!saving)
		[window close];
}

- (void) send: (id)sender
{
	NSUserDefaults *ud = [NSUserDefaults standardUserDefaults];
	NSTimeInterval delay = [ud objectForKey: @"Mail2UndoSendDelay"] ? [ud doubleForKey: @"Mail2UndoSendDelay"] : 5;
	[self queueAt: [NSDate dateWithTimeIntervalSinceNow: MAX(0, delay)] undoable: delay > 0];
}

- (void) remindIfNoReply: (id)sender
{
	int d = Mail2ChooseFollowUpDays();
	if (d <= 0)
		return;
	followUpDays = d;
	[window setTitle: [NSString stringWithFormat: @"%@ (reminder after %d day%@)", [self plainTitle], d, d == 1 ? @"" : @"s"]];
}

- (void) sendLater: (id)sender
{
	NSDate *when = Mail2ChooseSendTime();
	if (when != nil)
		[self queueAt: when undoable: NO];
}

/* a message the Outbox gave back (Undo Send, or Edit in the Outbox): in a compose window again */
+ (Mail2Compose *) reopenOutgoing: (NSDictionary *)d sessions: (NSArray *)all
{
	Mail2Session *s = nil;
	NSEnumerator *e = [all objectEnumerator];
	Mail2Session *x;
	while ((x = [e nextObject]) != nil)
		if ([[[x account] identifier] isEqualToString: [d objectForKey: @"Account"]])
			s = x;
	Mail2Compose *c = [[[Mail2Compose alloc] initWithSessions: all session: s] autorelease];
	Mail2ParsedMessage *p = [Mail2ParsedMessage parseData: [d objectForKey: @"Message"] preferPlainText: YES];
	[c->toField setStringValue: [d objectForKey: @"To"] ? [d objectForKey: @"To"] : @""];
	[c->ccField setStringValue: [d objectForKey: @"Cc"] ? [d objectForKey: @"Cc"] : @""];
	[c->bccField setStringValue: [d objectForKey: @"Bcc"] ? [d objectForKey: @"Bcc"] : @""];
	[c->subjectField setStringValue: [d objectForKey: @"Subject"] ? [d objectForKey: @"Subject"] : @""];
	[c->window setTitle: [c plainTitle]];
	NSInteger i;
	for (i = 0; i < [c->fromPopup numberOfItems]; i++)
		if ([[[[c->fromPopup itemAtIndex: i] representedObject] objectAtIndex: 1] isEqualToString: [d objectForKey: @"From"]])
			[c->fromPopup selectItemAtIndex: i];
	NSString *mid = [d objectForKey: @"MessageId"];
	NSData *rtfd = mid ? [NSData dataWithContentsOfFile: rtfd_path(mid)] : nil;
	NSAttributedString *kept = rtfd ? [[[NSAttributedString alloc] initWithRTFD: rtfd documentAttributes: NULL] autorelease] : nil;
	if (kept != nil && c->rich)
		[[c->bodyView textStorage] setAttributedString: kept];
	else
		[c->bodyView setString: [p body] ? [p body] : @""];
	if (mid)
		[[NSFileManager defaultManager] removeItemAtPath: rtfd_path(mid) error: NULL];
	[c->attachments addObjectsFromArray: [p attachments]];
	ASSIGN(c->inReplyTo, [p inReplyTo]);
	ASSIGN(c->references, [p references]);
	ASSIGN(c->draftId, [d objectForKey: @"Draft"]);
	if ([d objectForKey: @"ReplyTo"])
		ASSIGN(c->original, [[Mail2Store sharedStore] messageWithRowID: [[d objectForKey: @"ReplyTo"] longLongValue]]);
	c->followUpDays = [[d objectForKey: @"FollowUpDays"] intValue];
	[c layoutAttachments];
	[c setDirty: YES];
	[c showFocusing: c->bodyView];
	return c;
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
