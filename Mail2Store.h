/* Mail2Store: the local copy of each account. An SQLite index (~/GNUstep/Library/Mail2/Index.sqlite) has a row per
 * mailbox and per message (envelope, flags, snippet); the messages themselves, once downloaded, are files in a Maildir
 * per mailbox (~/GNUstep/Library/Mail2/Mail/<account>/<mailbox>/{cur,new,tmp}), named
 * <uidvalidity>_<uid>.mail2:2,<flags> so their Maildir flags stay in step with the row. The row holds the file name.
 *
 * Safe to call from any thread (one connection, serialised by a lock). */
#import <Foundation/Foundation.h>

enum {
	Mail2FlagSeen = 1,
	Mail2FlagAnswered = 2,
	Mail2FlagFlagged = 4,
	Mail2FlagDeleted = 8,
	Mail2FlagDraft = 16,
};

/* the mailbox id that stands for every account's Inbox in the message queries (the viewer's All Inboxes) */
#define Mail2AllInboxesID (-1LL)
/* and for every flagged message of every account (not in Trash or Junk): the Flagged smart mailbox */
#define Mail2FlaggedID (-2LL)
/* the Outbox (Mail2Outbox): messages waiting to go, which are not in the index */
#define Mail2OutboxID (-3LL)
/* every unread message (not in Trash, Junk, Sent or Drafts): the Unread smart mailbox */
#define Mail2UnreadID (-4LL)
/* every mailbox but Trash and Junk: where saved searches (smart mailboxes) look */
#define Mail2EverywhereID (-5LL)
/* saved searches are shown as mailboxes with ids from here down: Mail2SavedSearchBase - index */
#define Mail2SavedSearchBase (-100LL)
/* sent messages whose follow-up reminder is due (Mail2Later): the Follow Up smart mailbox */
#define Mail2FollowUpID (-6LL)

@interface Mail2Mailbox : NSObject
{
@public
	long long mbid;
	NSString *account, *name, *displayName, *special;
	char delimiter;
	BOOL selectable;
	unsigned uidValidity, uidNext;
	int unread, depth;
}
- (long long) mbid;
- (NSString *) account;
- (NSString *) name;		/* the IMAP name (modified UTF-7), for commands */
- (NSString *) displayName;	/* the last path component, decoded; "Inbox" for INBOX */
- (NSString *) special;		/* inbox, drafts, sent, archive, junk, trash, all, flagged; "allinboxes" for the
				 * viewer's All Inboxes (mbid Mail2AllInboxesID, no account); or nil */
- (BOOL) selectable;
- (int) unread;
- (int) depth;			/* nesting level below its account */
+ (Mail2Mailbox *) allInboxes;	/* the viewer's All Inboxes, unread counted across the accounts */
+ (Mail2Mailbox *) flagged;
+ (Mail2Mailbox *) outbox: (int)count;
+ (Mail2Mailbox *) unreadSmart;
/* a saved search: its query in -name, shown as a mailbox (mbid Mail2SavedSearchBase - index) */
+ (Mail2Mailbox *) savedSearch: (NSString *)title query: (NSString *)query index: (int)i;	/* the Flagged smart mailbox, its count the flagged messages */
- (BOOL) isVirtual;		/* All Inboxes or Flagged: messages of several mailboxes, no account of its own */
@end

@interface Mail2MessageInfo : NSObject
{
@public
	long long rowid, mbid;
	unsigned uid;
	int flags;
	NSDate *date;
	NSString *fromName, *fromAddr, *to, *cc, *replyTo, *subject, *messageId, *inReplyTo, *references, *snippet, *file;
	NSString *thread, *outboxId;
	unsigned long long size;
	BOOL attachment;
	int threadCount, threadUnread;
}
- (long long) rowid;
- (long long) mbid;
- (unsigned) uid;
- (int) flags;
- (BOOL) isUnread;
- (NSDate *) date;
- (NSString *) fromName;
- (NSString *) fromAddr;
- (NSString *) sender;		/* the name, else the address */
- (NSString *) to;		/* "Name <addr>, ..." */
- (NSString *) cc;
- (NSString *) replyTo;
- (NSString *) subject;
- (NSString *) messageId;
- (NSString *) inReplyTo;
- (NSString *) snippet;
- (NSString *) file;		/* the Maildir file's name, nil until downloaded */
- (unsigned long long) size;
- (BOOL) hasAttachment;
- (NSString *) references;	/* "<id> <id> ..." */
- (NSString *) thread;		/* the conversation key */
- (int) threadCount;		/* in a conversation list: the messages in it here (1 otherwise) */
- (int) threadUnread;		/* and how many of them are unread */
- (BOOL) isDraft;
- (NSString *) outboxId;	/* an Outbox item's id (the row is not in the index), else nil */
@end

@interface Mail2Store : NSObject
{
	void *db;	/* sqlite3 * */
	NSRecursiveLock *lock;
	NSMutableSet *muted, *blocked;	/* thread keys; lowercased addresses */
}
+ (Mail2Store *) sharedStore;

/* ---- mailboxes ---- */
/* sorted: Inbox, Drafts, Sent, Archive, Junk, Trash, then the rest by path; with unread counts */
- (NSArray *) mailboxesForAccount: (NSString *)account;
- (Mail2Mailbox *) mailboxWithID: (long long)mbid;
/* the account's mailboxes as the server lists them now: dictionaries {Name, Delimiter, Special, Selectable}; mailboxes no
 * longer listed are removed with their messages and files */
- (void) setMailboxes: (NSArray *)list forAccount: (NSString *)account;
- (void) setUidValidity: (unsigned)v uidNext: (unsigned)n forMailbox: (long long)mbid;
/* removes every message (rows and files); for a UIDVALIDITY change */
- (void) clearMailbox: (long long)mbid;
- (void) removeAccount: (NSString *)account;

/* ---- messages ---- */
/* the message queries below take Mail2AllInboxesID for every account's Inbox together, and Mail2FlaggedID */
- (NSArray *) messagesInMailbox: (long long)mbid limit: (int)limit;	/* newest first */
/* the newest message of each conversation, newest first, with -threadCount and -threadUnread */
- (NSArray *) conversationsInMailbox: (long long)mbid limit: (int)limit;
- (NSArray *) messagesInConversation: (NSString *)thread mailbox: (long long)mbid;	/* newest first */
/* the messages a search finds (Mail2ParseSearch: filters and free words; each word in the sender, recipients,
 * subject, opening or downloaded body -- or the message among uids, the server's matches), newest first */
- (NSArray *) searchMailbox: (long long)mbid text: (NSString *)text alsoUids: (NSArray *)uids limit: (int)limit;
- (Mail2MessageInfo *) messageWithRowID: (long long)rowid;
- (unsigned) maxUidInMailbox: (long long)mbid;
- (unsigned) minUidInMailbox: (long long)mbid;
- (NSDictionary *) flagsByUidInMailbox: (long long)mbid;	/* NSNumber uid -> NSNumber flags */
/* inserts new rows and refreshes the flags and envelope of known ones (their file and snippet are kept) */
- (void) addMessages: (NSArray *)infos;
- (void) setFlags: (int)flags forMessage: (long long)rowid;
- (void) setFlags: (int)flags forUid: (unsigned)uid inMailbox: (long long)mbid;
- (void) removeUids: (NSArray *)uids inMailbox: (long long)mbid;
- (void) removeMessage: (long long)rowid;
- (int) unreadInMailbox: (long long)mbid;
- (int) unreadInInboxes;
- (int) flaggedCount;
- (int) unreadCount;	/* what the Unread smart mailbox holds */	/* every account's Inbox: the dock badge */
/* the newest messages without a file, for prefetching */
- (NSArray *) messagesToPrefetchInMailbox: (long long)mbid limit: (int)limit maxSize: (unsigned long long)maxSize;

/* whether anything in the index answers this Message-ID (In-Reply-To or References) */
- (BOOL) hasReplyTo: (NSString *)messageId;
/* one row per Message-ID (a Sent copy first), newest first */
- (NSArray *) messagesWithMessageIDs: (NSArray *)ids;
+ (Mail2Mailbox *) followUp: (int)count;

/* ---- muted conversations, blocked senders ---- */
- (void) setThread: (NSString *)thread muted: (BOOL)on;
- (BOOL) isThreadMuted: (NSString *)thread;		/* from memory: quick enough for drawing rows */
- (void) setAddress: (NSString *)addr blocked: (BOOL)on;
- (BOOL) isAddressBlocked: (NSString *)addr;
- (NSArray *) blockedAddresses;

/* ---- addresses ---- */
/* people seen ("Name <addr>" or "addr"), whose address or name starts with prefix (or a word of the name does),
 * those written most first: for completing To, Cc and Bcc */
- (NSArray *) addressesMatching: (NSString *)prefix limit: (int)limit;

/* ---- files ---- */
/* writes the raw message into the mailbox's Maildir (tmp, then renamed into cur) and records it with its snippet */
- (BOOL) storeMessageData: (NSData *)raw forMessage: (Mail2MessageInfo *)m snippet: (NSString *)snippet attachment: (BOOL)att;
/* and indexes the body text for search */
- (BOOL) storeMessageData: (NSData *)raw forMessage: (Mail2MessageInfo *)m snippet: (NSString *)snippet attachment: (BOOL)att
                     body: (NSString *)body;
/* the full path of a downloaded message, or nil */
- (NSString *) pathForMessage: (Mail2MessageInfo *)m;
@end
