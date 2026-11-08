/* Mail2Window: the viewer window, laid out like Apple Mail: a toolbar over three panes -- mailboxes, the messages of the
 * selected mailbox, and the selected message. The panes are an NSSplitView; on a window resize the sidebar and the
 * list keep their widths and the message pane takes the rest. */
#import <AppKit/AppKit.h>
#import "Mail2Session.h"
#import "Mail2Views.h"

@interface Mail2Window : NSObject <NSWindowDelegate, NSSplitViewDelegate>
{
	NSWindow *window;
	NSArray *sessions;
	NSMutableArray *sidebarItems;	/* NSString account headings and Mail2Mailbox */
	Mail2Table *sidebar, *list;
	Mail2SidebarCell *sidebarCell;
	Mail2MessageCell *messageCell;
	Mail2MessageView *messageView;
	NSTextField *statusField;
	NSMutableDictionary *buttons;
	Mail2Mailbox *current;
	NSArray *messages;
	Mail2ParsedMessage *parsed;	/* the shown message's body */
	BOOL syncingSelection;
	unsigned showGeneration;
	NSSearchField *searchField;
	NSString *searchText;		/* nil: no search */
	NSArray *serverHits;		/* UIDs the server's search found */
	unsigned searchGeneration;
	NSString *expanded;		/* the opened conversation */
	NSMutableSet *childRows;	/* rowids of its messages shown under it */
	BOOL loadingOlder;
	NSUndoManager *undo;		/* moves (Archive, Delete, Junk, Move To, drops) */
}
- (id) initWithSessions: (NSArray *)s;
- (void) setSessions: (NSArray *)s;
- (NSWindow *) window;

- (void) getMail: (id)sender;
- (void) compose: (id)sender;
- (void) reply: (id)sender;
- (void) replyAll: (id)sender;
- (void) forward: (id)sender;
- (void) archive: (id)sender;
- (void) deleteMessages: (id)sender;
- (void) toggleFlag: (id)sender;
- (void) toggleRead: (id)sender;
- (void) getOlderMessages: (id)sender;
- (void) focusSearch: (id)sender;
- (void) toggleConversations: (id)sender;
- (void) editDraft: (id)sender;
- (void) moveTo: (id)sender;
- (void) markJunk: (id)sender;
- (void) applyRules: (id)sender;
- (void) showSource: (id)sender;
- (void) newMailbox: (id)sender;
- (void) renameMailbox: (id)sender;
- (void) deleteMailbox: (id)sender;
+ (BOOL) organizesByConversation;
- (BOOL) validateAction: (SEL)a;
@end
