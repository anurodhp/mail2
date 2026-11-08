/* Mail2Views: the pieces of the main window's three panes. */
#import <AppKit/AppKit.h>
#import "Mail2Store.h"
#import "Mail2Message.h"

/* A table with Milan's rounded selection; Delete/Backspace and Return go to its delegate's -tableDeleteKey: and
 * -tableReturnKey: when it has them. */
@interface Mail2Table : NSTableView
{
	BOOL sidebarStyle;
}
- (void) setSidebarStyle: (BOOL)s;
@end

/* sidebar row: an account heading (NSString) or a mailbox (Mail2Mailbox) */
@interface Mail2SidebarCell : NSCell
{
	id item;
	BOOL selected;
}
- (void) setItem: (id)i selected: (BOOL)s;
@end

/* message list row: unread dot, sender and date, subject, snippet */
@interface Mail2MessageCell : NSCell
{
	Mail2MessageInfo *msg;
	BOOL selected, child;
	int count;
}
- (void) setMessage: (Mail2MessageInfo *)m selected: (BOOL)s;
/* child: a message of an opened conversation, drawn indented; count > 1: a conversation's head, with its count */
- (void) setMessage: (Mail2MessageInfo *)m selected: (BOOL)s child: (BOOL)c count: (int)n;
@end

/* the right pane: the header block, the attachment strip and the body */
@interface Mail2MessageView : NSView
{
	NSView *header;
	NSView *attachBar;
	NSScrollView *scroll;
	NSTextView *text;
	NSTextField *empty;
	Mail2MessageInfo *msg;
	NSArray *attachments;
	id web;				/* a FloWebView (libFloWeb), made the first time an HTML message is shown */
	NSDictionary *inlineParts;
	BOOL showingWeb;
	NSView *remoteBar;		/* "remote content was not loaded" and its button */
	NSButton *unsubButton;
	Mail2ParsedMessage *shown;	/* for Unsubscribe and Show Raw Source */
	BOOL remoteBlocked;		/* the shown HTML has remote content that was not loaded */
}
- (void) showNothing: (NSString *)why;		/* "No Message Selected", "3 messages selected" */
- (void) showMessage: (Mail2MessageInfo *)m body: (NSString *)body attachments: (NSArray *)att;
/* html non-nil and WebKit available (Mail2WebViewClass): the HTML in a sealed web view, else body as text */
- (void) showMessage: (Mail2MessageInfo *)m body: (NSString *)body attachments: (NSArray *)att
                html: (NSString *)html inlineParts: (NSDictionary *)parts;
- (Mail2MessageInfo *) message;
/* the parsed message shown: an Unsubscribe button when it has List-Unsubscribe */
- (void) setParsed: (Mail2ParsedMessage *)p;
- (NSTextView *) textView;
@end

/* Windows whose Tab / Shift-Tab order is a given list of views (then round again), whatever GNUstep's key-view loop
 * would choose: on this desktop it went back and forth between the first two fields of the compose window. */
@interface Mail2KeyOrderWindow : NSWindow
{
	NSArray *keyOrder;
}
- (void) setKeyOrder: (NSArray *)views;
@end
@interface Mail2KeyOrderPanel : NSPanel
{
	NSArray *keyOrder;
}
- (void) setKeyOrder: (NSArray *)views;
@end

/* Florence's WebKit, shared: /usr/local/lib/libFloWeb.1.dylib (MAIL2_FLOWEB overrides), loaded with dlopen() the first
 * time an HTML message is shown and its engine started then. Nil when it is not installed or did not start; the
 * message is then shown as text. Main thread only. */
Class Mail2WebViewClass(void);
BOOL Mail2WebViewInstalled(void);	/* the library is there (and has not failed): cheap, any thread */


/* small modal questions: a name (nil if cancelled), and one of the mailboxes (nil if cancelled) */
NSString *Mail2AskString(NSString *title, NSString *message, NSString *initial, NSString *okTitle);
Mail2Mailbox *Mail2ChooseMailbox(NSString *title, NSString *message, NSArray *mailboxes, NSString *okTitle);

/* quote levels coloured, the signature dimmed, links (NSLinkAttributeName) in a plain-text body */
void Mail2StyleBody(NSMutableAttributedString *as);

/* tail-truncated attributed string with Milan's font fallback */
NSAttributedString *Mail2FittedString(NSString *s, NSDictionary *attrs, CGFloat width);
NSImage *Mail2Icon(NSString *name);
