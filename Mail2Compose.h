/* Mail2Compose: a compose window (To, Cc, Bcc, Subject, a plain-text body, attached files) for new messages, replies,
 * forwards and drafts.
 * Send builds the message (Mail2BuildMessage) and hands it to the account's session; the window closes when the
 * server has taken it and stays open with the reason when it has not. */
#import <AppKit/AppKit.h>
#import "Mail2Session.h"
#import "Mail2Message.h"

@interface Mail2BodyView : NSTextView
{
	id fileTarget;	/* not retained: the compose window's controller */
	NSArray *misspelled;	/* NSValue ranges, underlined in red (the layout manager's, never in the text sent) */
}
- (void) setFileTarget: (id)t;
- (void) checkSpellingSoon;
@end

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
	NSString *insertedSig;		/* the signature block put in the body, to swap when From changes */
	NSMutableDictionary *lastLengths;	/* per address field: its length at the last change */
	BOOL sending, saving, dirty, closeAfterSave, sent;
	BOOL rich;			/* the body is rich text (sent as HTML when it has formatting) */
}
+ (Mail2Compose *) newMessageWithSessions: (NSArray *)sessions to: (NSString *)to;
/* from a mailto: URL, with its cc, bcc, subject and body */
+ (Mail2Compose *) newMessageWithSessions: (NSArray *)sessions mailto: (NSString *)url;
/* all: Reply All */
+ (Mail2Compose *) replyTo: (Mail2MessageInfo *)m parsed: (Mail2ParsedMessage *)p session: (Mail2Session *)s
                  sessions: (NSArray *)all replyAll: (BOOL)replyAll;
+ (Mail2Compose *) forward: (Mail2MessageInfo *)m parsed: (Mail2ParsedMessage *)p session: (Mail2Session *)s sessions: (NSArray *)all;
/* a draft from the Drafts mailbox, to go on with; saving replaces it there, sending removes it */
+ (Mail2Compose *) editDraft: (Mail2MessageInfo *)m parsed: (Mail2ParsedMessage *)p session: (Mail2Session *)s sessions: (NSArray *)all;
- (NSWindow *) window;
- (void) attachFile: (id)sender;
- (void) attachPaths: (NSArray *)paths;
- (void) sendLater: (id)sender;
/* the Outbox's item (Mail2Outbox -takeBack:) in a compose window again */
+ (Mail2Compose *) reopenOutgoing: (NSDictionary *)item sessions: (NSArray *)sessions;
/* Format */
- (void) addLink: (id)sender;
- (void) toggleBulletList: (id)sender;
- (void) toggleNumberedList: (id)sender;
- (void) increaseQuoteLevel: (id)sender;
- (void) decreaseQuoteLevel: (id)sender;
- (void) togglePlainText: (id)sender;
- (void) saveDraft: (id)sender;		/* also every minute while there are unsaved changes */
@end
