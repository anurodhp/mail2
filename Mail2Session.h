/* Mail2Session: everything an account does on the network. Commands run in order on the account's serial dispatch
 * queue over one IMAP connection; new mail is watched on a second connection that IDLEs on the Inbox in a thread of
 * its own. Results reach the main thread as notifications (object: the session):
 *
 *   Mail2MailboxesChanged   the mailbox list was refreshed
 *   Mail2MessagesChanged    userInfo {Mailbox: NSNumber mbid}: rows were added, changed or removed
 *   Mail2StatusChanged      -status changed ("Checking mail…", an error, or nil when idle)
 *
 * Local changes (read, flagged, moved) are written to the store at once, so the UI shows them before the server
 * hears of them. */
#import <Foundation/Foundation.h>
#import "Mail2Account.h"
#import "Mail2Store.h"

extern NSString *const Mail2MailboxesChanged;
extern NSString *const Mail2MessagesChanged;
extern NSString *const Mail2StatusChanged;

@interface Mail2Session : NSObject
{
	Mail2Account *account;
	void *queue;		/* dispatch_queue_t */
	id imap;		/* Mail2IMAP, used only on queue */
	NSString *status, *lastError;
	int busy;
	NSThread *idleThread;
	int idleWake[2];
	volatile BOOL stopping;
	NSTimer *timer;
	NSMutableSet *fetching;	/* rowids being downloaded */
	NSMutableSet *complete;	/* mbids with nothing older left on the server */
}
- (id) initWithAccount: (Mail2Account *)a;
- (Mail2Account *) account;
- (void) start;		/* lists mailboxes, syncs the Inbox, starts IDLE and the 5-minute check */
- (void) stop;
- (NSString *) status;
- (BOOL) isBusy;		/* queued network work not finished yet */
- (NSString *) lastError;

- (void) refreshMailboxes;
- (void) syncMailbox: (Mail2Mailbox *)mb;
- (void) checkAll;	/* the Inbox and the given mailbox (the one shown), from the toolbar's Get Mail */
- (void) checkInboxAnd: (Mail2Mailbox *)mb;
/* every other folder by STATUS, syncing the ones that changed (every 2 minutes, and Get Mail) */
- (void) watchFolders;

/* downloads the message into its Maildir; the completion runs on the main thread with nil or an error */
- (void) fetchMessage: (Mail2MessageInfo *)m completion: (void (^)(NSString *err))done;
- (void) setFlag: (int)flag on: (BOOL)on forMessages: (NSArray *)msgs;
/* special: "trash" or "archive" (falls back to Gmail's All Mail for archive); deleting in the Trash itself
 * removes for good */
- (void) moveMessages: (NSArray *)msgs toSpecial: (NSString *)special;
/* to one of this account's mailboxes (Move To, a drop on the sidebar) */
- (void) moveMessages: (NSArray *)msgs toMailbox: (Mail2Mailbox *)dest;
/* a copy in another mailbox (on Gmail: the label that mailbox is, added; the message stays where it is) */
- (void) copyMessages: (NSArray *)msgs toMailbox: (Mail2Mailbox *)dest;
/* Gmail's labels of a message; the completion (main thread) gets nil elsewhere */
- (void) labelsOf: (Mail2MessageInfo *)m completion: (void (^)(NSArray *labels))done;
- (BOOL) isGmail;
/* to the mailbox with this display name at the top of the account, made if it is missing (Snoozed) */
- (void) moveMessages: (NSArray *)msgs toNamedMailbox: (NSString *)name;
/* from the mailbox with that display name back to the one with this IMAP name, by Message-ID, unread if asked */
- (void) moveBackFromNamed: (NSString *)fromDisplayName messageIDs: (NSArray *)ids toNamed: (NSString *)imapName markUnread: (BOOL)unread;
/* Undo of a move: the messages with these Message-IDs go from dest back to src */
- (void) moveBackMessageIDs: (NSArray *)ids from: (Mail2Mailbox *)dest to: (Mail2Mailbox *)src;
/* folders: a new one at the top (under INBOX. on servers that keep them there), and renaming or deleting one of the
 * user's own (never a special mailbox) */
- (void) createMailboxNamed: (NSString *)name;
- (void) renameMailbox: (Mail2Mailbox *)mb to: (NSString *)name;
- (void) deleteMailbox: (Mail2Mailbox *)mb;
/* the rules (Mail2Rules.h) on these messages now: Message > Apply Rules */
- (void) applyRulesTo: (NSArray *)msgs;
/* sends, then saves a copy in Sent (not on Gmail, whose server does that); completion on the main thread */
- (void) sendMessage: (NSData *)raw recipients: (NSArray *)rcpts replyingTo: (Mail2MessageInfo *)orig
          completion: (void (^)(NSString *err))done;
- (Mail2Mailbox *) mailboxWithSpecial: (NSString *)special;

/* the first sync takes the last 30 days (at most 500); this takes the `count` messages before the oldest one here.
 * The completion (main thread) gets how many came; 0 also means there are no more. */
- (void) loadOlderMessagesIn: (Mail2Mailbox *)mb count: (int)count completion: (void (^)(int added))done;
- (BOOL) hasOlderMessagesIn: (Mail2Mailbox *)mb;
/* UID SEARCH TEXT on the server; matches without a row yet get one (newest 200). Completion on the main thread. */
- (void) searchServer: (NSString *)text inMailbox: (Mail2Mailbox *)mb completion: (void (^)(NSArray *uids, NSString *err))done;
/* APPENDs a draft (\Draft \Seen) to Drafts (made if missing), then removes the copy with Message-ID oldId */
- (void) saveDraft: (NSData *)raw replacing: (NSString *)oldId completion: (void (^)(NSString *err))done;
- (void) deleteDraft: (NSString *)messageId;
@end

/* Posts the unread count of every Inbox to Naples' dock (distributed notification NaplesBadgeChanged). */
void Mail2UpdateDockBadge(void);
void Mail2ClearDockBadge(void);
