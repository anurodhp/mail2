/* Mail2IMAP: one IMAP connection (libetpan's mailimap), synchronous. Every call blocks on the network, so it is used
 * only from an account's own dispatch queue or the IDLE thread, never from the main thread. Errors come back as an
 * NSString in *err (the server's own text where it gave one). */
#import <Foundation/Foundation.h>
#import "Mail2Account.h"

@interface Mail2IMAP : NSObject
{
	Mail2Account *account;
	void *imap;		/* mailimap * */
	NSString *selected;
	BOOL readOnly;
}
- (id) initWithAccount: (Mail2Account *)a;
- (BOOL) isConnected;
/* connects, logs in and reads the capabilities; a no-op when already connected */
- (BOOL) connect: (NSString **)err;
- (void) disconnect;
- (BOOL) hasCapability: (NSString *)cap;

- (BOOL) createMailbox: (NSString *)name error: (NSString **)err;
- (BOOL) renameMailbox: (NSString *)from to: (NSString *)to error: (NSString **)err;
- (BOOL) deleteMailbox: (NSString *)name error: (NSString **)err;
/* every mailbox: dictionaries {Name, Delimiter, Special, Selectable} as Mail2Store -setMailboxes:forAccount: takes */
- (NSArray *) listMailboxes: (NSString **)err;
- (BOOL) select: (NSString *)mailbox uidValidity: (unsigned *)v uidNext: (unsigned *)n exists: (unsigned *)exists error: (NSString **)err;
/* UIDs (NSNumber) of the messages that arrived on or after the date */
- (NSArray *) uidsSince: (NSDate *)date error: (NSString **)err;
/* UIDs above uid (UID SEARCH UID uid+1:*, which on an empty range still names the last message: filtered) */
- (NSArray *) uidsAbove: (unsigned)uid error: (NSString **)err;
/* UIDs of the messages whose headers or body contain every word of text (UID SEARCH TEXT ...) */
- (NSArray *) uidsMatchingText: (NSString *)text error: (NSString **)err;
/* UIDs below uid, oldest first */
- (NSArray *) uidsBelow: (unsigned)uid error: (NSString **)err;
/* UIDs of the messages with this Message-ID header ("<id>"): a draft's earlier copies */
- (NSArray *) uidsWithMessageID: (NSString *)mid error: (NSString **)err;
/* envelopes, flags, dates and sizes (Mail2MessageInfo, mbid set) for the selected mailbox */
- (NSArray *) fetchHeaders: (NSArray *)uids mailbox: (long long)mbid error: (NSString **)err;
/* flags of every message from uid up: NSNumber uid -> NSNumber flags; nil on error */
- (NSDictionary *) fetchFlagsFrom: (unsigned)uid error: (NSString **)err;
/* the whole message (BODY.PEEK[]: does not set \Seen) */
- (NSData *) fetchMessage: (unsigned)uid error: (NSString **)err;
- (BOOL) setFlags: (int)flags add: (BOOL)add uids: (NSArray *)uids error: (NSString **)err;
/* MOVE where the server has it, else COPY + \Deleted + EXPUNGE */
- (BOOL) moveUids: (NSArray *)uids to: (NSString *)mailbox error: (NSString **)err;
/* deletes for good: \Deleted, then UID EXPUNGE (plain EXPUNGE without UIDPLUS) */
- (BOOL) expungeUids: (NSArray *)uids error: (NSString **)err;
/* UID COPY (Gmail: adds the label that mailbox is) */
- (BOOL) copyUids: (NSArray *)uids to: (NSString *)mailbox error: (NSString **)err;
/* Gmail's labels of a message (X-GM-LABELS), decoded; nil when the server has none */
- (NSArray *) gmailLabelsOf: (unsigned)uid error: (NSString **)err;
- (BOOL) appendMessage: (NSData *)raw to: (NSString *)mailbox flags: (int)flags error: (NSString **)err;

/* IDLE on the selected mailbox until the server reports a change, wakeFd becomes readable, or timeout seconds pass.
 * Returns 1 when the server sent something (a change to sync), 0 on a wakeup or the timeout, -1 on a connection
 * error. Without IDLE, sleeps until wakeFd or the timeout and returns 0. */
- (int) idleWithWakeFd: (int)wakeFd timeout: (int)seconds error: (NSString **)err;
@end
