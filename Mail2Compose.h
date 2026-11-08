/* Mail2Compose: a compose window (To, Cc, Bcc, Subject, a plain-text body, attached files) for new messages, replies,
 * forwards and drafts.
 * Send builds the message (Mail2BuildMessage) and hands it to the account's session; the window closes when the
 * server has taken it and stays open with the reason when it has not. */
#import <AppKit/AppKit.h>
#import "Mail2Session.h"
#import "Mail2Message.h"

@interface Mail2Compose : NSObject <NSWindowDelegate>
{
	NSWindow *window;
	Mail2Session *session;
	NSArray *sessions;
	NSPopUpButton *fromPopup;
	NSTextField *toField, *ccField, *bccField, *subjectField;
	NSTextView *bodyView;
	NSScrollView *bodyScroll;
	NSButton *sendButton, *attachButton;
	NSView *attachBar;
	NSMutableArray *attachments;	/* Mail2Attachment */
	Mail2MessageInfo *original;	/* the message replied to */
	NSString *inReplyTo;
	NSArray *references;
	NSString *draftId;		/* Message-ID of the copy in Drafts, nil before the first save */
	NSTimer *autosave;
	BOOL sending, saving, dirty, closeAfterSave, sent;
}
+ (Mail2Compose *) newMessageWithSessions: (NSArray *)sessions to: (NSString *)to;
/* all: Reply All */
+ (Mail2Compose *) replyTo: (Mail2MessageInfo *)m parsed: (Mail2ParsedMessage *)p session: (Mail2Session *)s
                  sessions: (NSArray *)all replyAll: (BOOL)replyAll;
+ (Mail2Compose *) forward: (Mail2MessageInfo *)m parsed: (Mail2ParsedMessage *)p session: (Mail2Session *)s sessions: (NSArray *)all;
/* a draft from the Drafts mailbox, to go on with; saving replaces it there, sending removes it */
+ (Mail2Compose *) editDraft: (Mail2MessageInfo *)m parsed: (Mail2ParsedMessage *)p session: (Mail2Session *)s sessions: (NSArray *)all;
- (NSWindow *) window;
- (void) attachFile: (id)sender;
- (void) saveDraft: (id)sender;		/* also every minute while there are unsaved changes */
@end
