/* Mail2Store: SQLite index + Maildir files (see Mail2Store.h). */
#import "Mail2Store.h"
#import "Mail2Util.h"
#include <sqlite3.h>
#include <stdio.h>
#include <string.h>
#include <unistd.h>

#define DB ((sqlite3 *)db)

@implementation Mail2Mailbox
- (void) dealloc { [account release]; [name release]; [displayName release]; [special release]; [super dealloc]; }
- (long long) mbid { return mbid; }
- (NSString *) account { return account; }
- (NSString *) name { return name; }
- (NSString *) displayName { return displayName; }
- (NSString *) special { return special; }
- (BOOL) selectable { return selectable; }
- (int) unread { return unread; }
- (int) depth { return depth; }
- (NSString *) description { return [NSString stringWithFormat: @"<Mailbox %lld %@>", mbid, name]; }
- (BOOL) isVirtual { return mbid < 0; }

+ (Mail2Mailbox *) outbox: (int)count
{
	Mail2Mailbox *m = [[[Mail2Mailbox alloc] init] autorelease];
	m->mbid = Mail2OutboxID;
	m->name = [@"" retain];
	m->displayName = [@"Outbox" retain];
	m->special = [@"outbox" retain];
	m->selectable = YES;
	m->unread = count;
	return m;
}

+ (Mail2Mailbox *) savedSearch: (NSString *)title query: (NSString *)query index: (int)i
{
	Mail2Mailbox *m = [[[Mail2Mailbox alloc] init] autorelease];
	m->mbid = Mail2SavedSearchBase - i;
	m->name = [query copy];
	m->displayName = [title copy];
	m->special = [@"savedsearch" retain];
	m->selectable = YES;
	return m;
}

+ (Mail2Mailbox *) followUp: (int)count
{
	Mail2Mailbox *m = [[[Mail2Mailbox alloc] init] autorelease];
	m->mbid = Mail2FollowUpID;
	m->name = [@"" retain];
	m->displayName = [@"Follow Up" retain];
	m->special = [@"followup" retain];
	m->selectable = YES;
	m->unread = count;
	return m;
}

+ (Mail2Mailbox *) unreadSmart
{
	Mail2Mailbox *m = [[[Mail2Mailbox alloc] init] autorelease];
	m->mbid = Mail2UnreadID;
	m->name = [@"" retain];
	m->displayName = [@"Unread" retain];
	m->special = [@"unreadsmart" retain];
	m->selectable = YES;
	m->unread = [[Mail2Store sharedStore] unreadCount];
	return m;
}

+ (Mail2Mailbox *) flagged
{
	Mail2Mailbox *m = [[[Mail2Mailbox alloc] init] autorelease];
	m->mbid = Mail2FlaggedID;
	m->name = [@"" retain];
	m->displayName = [@"Flagged" retain];
	m->special = [@"flaggedsmart" retain];
	m->selectable = YES;
	m->unread = [[Mail2Store sharedStore] flaggedCount];
	return m;
}

+ (Mail2Mailbox *) allInboxes
{
	Mail2Mailbox *m = [[[Mail2Mailbox alloc] init] autorelease];
	m->mbid = Mail2AllInboxesID;
	m->name = [@"" retain];
	m->displayName = [@"All Inboxes" retain];
	m->special = [@"allinboxes" retain];
	m->selectable = YES;
	m->unread = [[Mail2Store sharedStore] unreadInInboxes];
	return m;
}
@end

@implementation Mail2MessageInfo
- (void) dealloc
{
	[date release]; [fromName release]; [fromAddr release]; [to release]; [cc release]; [replyTo release];
	[subject release]; [messageId release]; [inReplyTo release]; [references release]; [snippet release]; [file release];
	[thread release]; [outboxId release];
	[super dealloc];
}
- (long long) rowid { return rowid; }
- (long long) mbid { return mbid; }
- (unsigned) uid { return uid; }
- (int) flags { return flags; }
- (BOOL) isUnread { return (flags & Mail2FlagSeen) == 0; }
- (NSDate *) date { return date; }
- (NSString *) fromName { return fromName; }
- (NSString *) fromAddr { return fromAddr; }
- (NSString *) sender { return [fromName length] ? fromName : ([fromAddr length] ? fromAddr : @"(no sender)"); }
- (NSString *) to { return to; }
- (NSString *) cc { return cc; }
- (NSString *) replyTo { return replyTo; }
- (NSString *) subject { return subject; }
- (NSString *) messageId { return messageId; }
- (NSString *) inReplyTo { return inReplyTo; }
- (NSString *) snippet { return snippet; }
- (NSString *) file { return file; }
- (unsigned long long) size { return size; }
- (BOOL) hasAttachment { return attachment; }
- (NSString *) references { return references; }
- (NSString *) thread { return thread; }
- (int) threadCount { return threadCount > 0 ? threadCount : 1; }
- (int) threadUnread { return threadUnread; }
- (BOOL) isDraft { return (flags & Mail2FlagDraft) != 0; }
- (NSString *) outboxId { return outboxId; }
@end

static NSString *
col_string(sqlite3_stmt *st, int i)
{
	const unsigned char *t = sqlite3_column_text(st, i);
	return t ? [NSString stringWithUTF8String: (const char *)t] : nil;
}

static void
bind_string(sqlite3_stmt *st, int i, NSString *s)
{
	if (s == nil)
		sqlite3_bind_null(st, i);
	else
		sqlite3_bind_text(st, i, [s UTF8String], -1, SQLITE_TRANSIENT);
}

/* "S", "RS", "FS"...: Maildir info letters in ASCII order */
static NSString *
maildir_flags(int f)
{
	NSMutableString *s = [NSMutableString string];
	if (f & Mail2FlagDraft) [s appendString: @"D"];
	if (f & Mail2FlagFlagged) [s appendString: @"F"];
	if (f & Mail2FlagAnswered) [s appendString: @"R"];
	if (f & Mail2FlagSeen) [s appendString: @"S"];
	if (f & Mail2FlagDeleted) [s appendString: @"T"];
	return s;
}

/* the directory name of a mailbox: its IMAP name with the hierarchy delimiter as "." (Maildir++ style) and "/"
 * never appearing */
static NSString *
mailbox_dirname(Mail2Mailbox *m)
{
	NSString *n = [m name];
	if (m->delimiter && m->delimiter != '.')
		n = [n stringByReplacingOccurrencesOfString: [NSString stringWithFormat: @"%c", m->delimiter] withString: @"."];
	n = [n stringByReplacingOccurrencesOfString: @"/" withString: @"_"];
	if ([n hasPrefix: @"."])
		n = [@"_" stringByAppendingString: n];
	return n;
}

static int
special_rank(NSString *s)
{
	static NSString *order[] = { @"inbox", @"drafts", @"sent", @"archive", @"junk", @"trash" };
	int i;
	for (i = 0; i < 6; i++)
		if ([s isEqualToString: order[i]])
			return i;
	return 6;
}

@implementation Mail2Store

+ (Mail2Store *) sharedStore
{
	static Mail2Store *s;
	if (s == nil)
		s = [[Mail2Store alloc] init];
	return s;
}

- (BOOL) exec: (const char *)sql
{
	char *err = NULL;
	if (sqlite3_exec(DB, sql, NULL, NULL, &err) != SQLITE_OK) {
		NSLog(@"mail2: sqlite: %s in: %s", err ? err : "?", sql);
		sqlite3_free(err);
		return NO;
	}
	return YES;
}

- (sqlite3_stmt *) prepare: (const char *)sql
{
	sqlite3_stmt *st = NULL;
	if (sqlite3_prepare_v2(DB, sql, -1, &st, NULL) != SQLITE_OK) {
		NSLog(@"mail2: sqlite: %s in: %s", sqlite3_errmsg(DB), sql);
		return NULL;
	}
	return st;
}

- (id) init
{
	sqlite3 *h = NULL;
	if ((self = [super init]) == nil)
		return nil;
	lock = [[NSRecursiveLock alloc] init];
	NSString *p = [Mail2SupportDirectory() stringByAppendingPathComponent: @"Index.sqlite"];
	if (sqlite3_open_v2([p fileSystemRepresentation], &h, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, NULL) != SQLITE_OK) {
		NSLog(@"mail2: cannot open %@: %s", p, h ? sqlite3_errmsg(h) : "?");
		sqlite3_close(h);
		[self release];
		return nil;
	}
	db = h;
	sqlite3_busy_timeout(DB, 5000);
	[self exec: "PRAGMA journal_mode=WAL; PRAGMA synchronous=NORMAL; PRAGMA foreign_keys=ON;"];
	/* reads through a mapping of the file (the kernel's cache, no copy into SQLite's own), temporary tables and sorts in
	 * memory rather than on the SD card, and a 4 MB page cache (the default is 2 MB) */
	[self exec: "PRAGMA mmap_size=67108864; PRAGMA temp_store=MEMORY; PRAGMA cache_size=-4096;"];
	[self exec:
	    "CREATE TABLE IF NOT EXISTS mailboxes ("
	    "  id INTEGER PRIMARY KEY, account TEXT NOT NULL, name TEXT NOT NULL, delim TEXT, special TEXT,"
	    "  selectable INTEGER DEFAULT 1, uidvalidity INTEGER DEFAULT 0, uidnext INTEGER DEFAULT 0,"
	    "  UNIQUE(account, name));"
	    "CREATE TABLE IF NOT EXISTS messages ("
	    "  id INTEGER PRIMARY KEY, mailbox INTEGER NOT NULL REFERENCES mailboxes(id) ON DELETE CASCADE,"
	    "  uid INTEGER NOT NULL, flags INTEGER DEFAULT 0, date REAL, from_name TEXT, from_addr TEXT,"
	    "  to_list TEXT, cc_list TEXT, reply_to TEXT, subject TEXT, message_id TEXT, in_reply_to TEXT,"
	    "  refs TEXT, size INTEGER DEFAULT 0, attach INTEGER DEFAULT 0, snippet TEXT, file TEXT,"
	    "  UNIQUE(mailbox, uid));"
	    "CREATE INDEX IF NOT EXISTS messages_by_date ON messages(mailbox, date DESC);"];
	/* version 1: conversations (thread: the key every message of one shares) and full-text search of the bodies */
	if ([self userVersion] < 1) {
		[self exec: "BEGIN"];
		if (![self hasColumn: "thread"])
			[self exec: "ALTER TABLE messages ADD COLUMN thread TEXT"];
		[self exec:
		    "CREATE INDEX IF NOT EXISTS messages_by_thread ON messages(thread);"
		    "CREATE INDEX IF NOT EXISTS messages_by_msgid ON messages(message_id);"
		    "CREATE VIRTUAL TABLE IF NOT EXISTS bodies USING fts4(body, tokenize=unicode61);"
		    "CREATE TRIGGER IF NOT EXISTS messages_gone AFTER DELETE ON messages BEGIN"
		    "  DELETE FROM bodies WHERE docid = old.id; END;"
		    "UPDATE messages SET thread = COALESCE(substr(refs, 1, instr(refs || ' ', ' ') - 1), in_reply_to, message_id,"
		    "  'row:' || id) WHERE thread IS NULL;"
		    "PRAGMA user_version = 1;"];
		[self exec: "COMMIT"];
	}
	/* version 3: the server's message count and CONDSTORE modseq per mailbox */
	if ([self userVersion] < 3) {
		if (![self hasColumn: "exists_count" table: "mailboxes"])
			[self exec: "ALTER TABLE mailboxes ADD COLUMN exists_count INTEGER DEFAULT 0"];
		if (![self hasColumn: "modseq" table: "mailboxes"])
			[self exec: "ALTER TABLE mailboxes ADD COLUMN modseq INTEGER DEFAULT 0"];
	}
	/* version 2: muted conversations and blocked senders */
	if ([self userVersion] < 2)
		[self exec: "CREATE TABLE IF NOT EXISTS muted (thread TEXT PRIMARY KEY);"
		    "CREATE TABLE IF NOT EXISTS blocked (address TEXT PRIMARY KEY);"];
	if ([self userVersion] < 3)
		[self exec: "PRAGMA user_version = 3;"];
	muted = [[NSMutableSet alloc] init];
	blocked = [[NSMutableSet alloc] init];
	sqlite3_stmt *ms = [self prepare: "SELECT thread FROM muted"];
	while (ms && sqlite3_step(ms) == SQLITE_ROW)
		[muted addObject: col_string(ms, 0)];
	sqlite3_finalize(ms);
	ms = [self prepare: "SELECT address FROM blocked"];
	while (ms && sqlite3_step(ms) == SQLITE_ROW)
		[blocked addObject: col_string(ms, 0)];
	sqlite3_finalize(ms);
	return self;
}

- (int) userVersion
{
	int v = 0;
	sqlite3_stmt *st = [self prepare: "PRAGMA user_version"];
	if (st && sqlite3_step(st) == SQLITE_ROW)
		v = sqlite3_column_int(st, 0);
	sqlite3_finalize(st);
	return v;
}

- (BOOL) hasColumn: (const char *)name
{
	return [self hasColumn: name table: "messages"];
}

- (BOOL) hasColumn: (const char *)name table: (const char *)table
{
	BOOL found = NO;
	sqlite3_stmt *st = [self prepare: [[NSString stringWithFormat: @"PRAGMA table_info(%s)", table] UTF8String]];
	while (st && sqlite3_step(st) == SQLITE_ROW)
		if (sqlite3_column_text(st, 1) && strcmp((const char *)sqlite3_column_text(st, 1), name) == 0)
			found = YES;
	sqlite3_finalize(st);
	return found;
}

- (NSString *) maildirForMailbox: (Mail2Mailbox *)m create: (BOOL)create
{
	NSString *d = [[[Mail2SupportDirectory() stringByAppendingPathComponent: @"Mail"]
	    stringByAppendingPathComponent: [m account]] stringByAppendingPathComponent: mailbox_dirname(m)];
	if (create) {
		NSFileManager *fm = [NSFileManager defaultManager];
		NSString *sub;
		NSEnumerator *e = [[NSArray arrayWithObjects: @"cur", @"new", @"tmp", nil] objectEnumerator];
		while ((sub = [e nextObject]) != nil)
			[fm createDirectoryAtPath: [d stringByAppendingPathComponent: sub] withIntermediateDirectories: YES attributes: nil error: NULL];
	}
	return d;
}

/* ---- mailboxes ---- */

- (Mail2Mailbox *) mailboxFromRow: (sqlite3_stmt *)st
{
	Mail2Mailbox *m = [[[Mail2Mailbox alloc] init] autorelease];
	NSString *delim;
	m->mbid = sqlite3_column_int64(st, 0);
	m->account = [col_string(st, 1) retain];
	m->name = [col_string(st, 2) retain];
	delim = col_string(st, 3);
	m->delimiter = [delim length] ? (char)[delim characterAtIndex: 0] : 0;
	m->special = [col_string(st, 4) retain];
	m->selectable = sqlite3_column_int(st, 5) != 0;
	m->uidValidity = (unsigned)sqlite3_column_int64(st, 6);
	m->uidNext = (unsigned)sqlite3_column_int64(st, 7);
	m->unread = sqlite3_column_int(st, 8);
	m->exists = (unsigned)sqlite3_column_int64(st, 9);
	m->modseq = (unsigned long long)sqlite3_column_int64(st, 10);
	NSArray *parts = m->delimiter ? [m->name componentsSeparatedByString: [NSString stringWithFormat: @"%c", m->delimiter]]
	                              : [NSArray arrayWithObject: m->name];
	m->depth = (int)[parts count] - 1;
	if ([m->special isEqualToString: @"inbox"])
		m->displayName = [@"Inbox" retain];
	else
		m->displayName = [Mail2DecodeMailboxName([[parts lastObject] UTF8String]) retain];
	return m;
}

#define MAILBOX_COLUMNS "id, account, name, delim, special, selectable, uidvalidity, uidnext," \
	" (SELECT COUNT(*) FROM messages WHERE mailbox = mailboxes.id AND (flags & 1) = 0), exists_count, modseq"

- (NSArray *) mailboxesForAccount: (NSString *)account
{
	NSMutableArray *r = [NSMutableArray array];
	[lock lock];
	sqlite3_stmt *st = [self prepare: "SELECT " MAILBOX_COLUMNS " FROM mailboxes WHERE account = ?"];
	bind_string(st, 1, account);
	while (sqlite3_step(st) == SQLITE_ROW)
		[r addObject: [self mailboxFromRow: st]];
	sqlite3_finalize(st);
	[lock unlock];
	/* the special mailboxes first, in Apple Mail's order, then the rest by name (so children follow parents);
	 * a special mailbox inside another one (Gmail's [Gmail]/Sent Mail) is shown at the top level */
	[r sortUsingComparator: ^NSComparisonResult(id a, id b) {
		int ra = special_rank([a special]), rb = special_rank([b special]);
		if (ra != rb)
			return ra < rb ? NSOrderedAscending : NSOrderedDescending;
		return [[a name] caseInsensitiveCompare: [b name]];
	}];
	NSEnumerator *e = [r objectEnumerator];
	Mail2Mailbox *m;
	while ((m = [e nextObject]) != nil)
		if (special_rank([m special]) < 6)
			m->depth = 0;
	return r;
}

- (Mail2Mailbox *) mailboxWithID: (long long)mbid
{
	Mail2Mailbox *m = nil;
	[lock lock];
	sqlite3_stmt *st = [self prepare: "SELECT " MAILBOX_COLUMNS " FROM mailboxes WHERE id = ?"];
	sqlite3_bind_int64(st, 1, mbid);
	if (sqlite3_step(st) == SQLITE_ROW)
		m = [self mailboxFromRow: st];
	sqlite3_finalize(st);
	[lock unlock];
	return m;
}

- (void) removeFilesOfMailbox: (Mail2Mailbox *)m
{
	[[NSFileManager defaultManager] removeItemAtPath: [self maildirForMailbox: m create: NO] error: NULL];
}

- (void) setMailboxes: (NSArray *)list forAccount: (NSString *)account
{
	NSMutableSet *names = [NSMutableSet set];
	NSEnumerator *e;
	NSDictionary *d;
	Mail2Mailbox *m;
	[lock lock];
	[self exec: "BEGIN"];
	sqlite3_stmt *st = [self prepare:
	    "INSERT INTO mailboxes(account, name, delim, special, selectable) VALUES(?, ?, ?, ?, ?)"
	    " ON CONFLICT(account, name) DO UPDATE SET delim = excluded.delim, special = excluded.special,"
	    " selectable = excluded.selectable"];
	e = [list objectEnumerator];
	while ((d = [e nextObject]) != nil) {
		[names addObject: [d objectForKey: @"Name"]];
		sqlite3_reset(st);
		bind_string(st, 1, account);
		bind_string(st, 2, [d objectForKey: @"Name"]);
		bind_string(st, 3, [d objectForKey: @"Delimiter"]);
		bind_string(st, 4, [d objectForKey: @"Special"]);
		sqlite3_bind_int(st, 5, [[d objectForKey: @"Selectable"] boolValue]);
		sqlite3_step(st);
	}
	sqlite3_finalize(st);
	/* gone from the server: drop them */
	e = [[self mailboxesForAccount: account] objectEnumerator];
	while ((m = [e nextObject]) != nil) {
		if ([names containsObject: [m name]])
			continue;
		[self removeFilesOfMailbox: m];
		st = [self prepare: "DELETE FROM mailboxes WHERE id = ?"];
		sqlite3_bind_int64(st, 1, m->mbid);
		sqlite3_step(st);
		sqlite3_finalize(st);
	}
	[self exec: "COMMIT"];
	[lock unlock];
}

- (void) setUidValidity: (unsigned)v uidNext: (unsigned)n forMailbox: (long long)mbid
{
	[lock lock];
	sqlite3_stmt *st = [self prepare: "UPDATE mailboxes SET uidvalidity = ?, uidnext = ? WHERE id = ?"];
	sqlite3_bind_int64(st, 1, v);
	sqlite3_bind_int64(st, 2, n);
	sqlite3_bind_int64(st, 3, mbid);
	sqlite3_step(st);
	sqlite3_finalize(st);
	[lock unlock];
}

- (void) setExists: (unsigned)exists modseq: (unsigned long long)modseq forMailbox: (long long)mbid
{
	[lock lock];
	sqlite3_stmt *st = [self prepare: "UPDATE mailboxes SET exists_count = ?, modseq = ? WHERE id = ?"];
	sqlite3_bind_int64(st, 1, exists);
	sqlite3_bind_int64(st, 2, (sqlite3_int64)modseq);
	sqlite3_bind_int64(st, 3, mbid);
	sqlite3_step(st);
	sqlite3_finalize(st);
	[lock unlock];
}

- (void) clearMailbox: (long long)mbid
{
	[lock lock];
	Mail2Mailbox *m = [self mailboxWithID: mbid];
	if (m != nil)
		[self removeFilesOfMailbox: m];
	sqlite3_stmt *st = [self prepare: "DELETE FROM messages WHERE mailbox = ?"];
	sqlite3_bind_int64(st, 1, mbid);
	sqlite3_step(st);
	sqlite3_finalize(st);
	[lock unlock];
}

- (void) removeAccount: (NSString *)account
{
	[lock lock];
	sqlite3_stmt *st = [self prepare: "DELETE FROM mailboxes WHERE account = ?"];
	bind_string(st, 1, account);
	sqlite3_step(st);
	sqlite3_finalize(st);
	[[NSFileManager defaultManager] removeItemAtPath: [[Mail2SupportDirectory() stringByAppendingPathComponent: @"Mail"]
	    stringByAppendingPathComponent: account] error: NULL];
	[lock unlock];
}

/* ---- messages ---- */

/* a mailbox, or with Mail2AllInboxesID every account's Inbox (?1 is the mailbox id) */
#define MBOX "(mailbox = ?1 OR (?1 = -1 AND mailbox IN (SELECT id FROM mailboxes WHERE special = 'inbox'))" \
	" OR (?1 = -2 AND (flags & 4) != 0 AND mailbox NOT IN (SELECT id FROM mailboxes WHERE special IN ('trash', 'junk')))" \
	" OR (?1 = -4 AND (flags & 1) = 0 AND mailbox NOT IN (SELECT id FROM mailboxes WHERE special IN ('trash', 'junk', 'sent', 'drafts')))" \
	" OR (?1 = -5 AND mailbox NOT IN (SELECT id FROM mailboxes WHERE special IN ('trash', 'junk'))))"

#define MESSAGE_COLUMNS "id, mailbox, uid, flags, date, from_name, from_addr, to_list, cc_list, reply_to, subject," \
	" message_id, in_reply_to, refs, size, attach, snippet, file, thread"

- (Mail2MessageInfo *) messageFromRow: (sqlite3_stmt *)st
{
	Mail2MessageInfo *m = [[[Mail2MessageInfo alloc] init] autorelease];
	m->rowid = sqlite3_column_int64(st, 0);
	m->mbid = sqlite3_column_int64(st, 1);
	m->uid = (unsigned)sqlite3_column_int64(st, 2);
	m->flags = sqlite3_column_int(st, 3);
	m->date = [[NSDate dateWithTimeIntervalSince1970: sqlite3_column_double(st, 4)] retain];
	m->fromName = [col_string(st, 5) retain];
	m->fromAddr = [col_string(st, 6) retain];
	m->to = [col_string(st, 7) retain];
	m->cc = [col_string(st, 8) retain];
	m->replyTo = [col_string(st, 9) retain];
	m->subject = [col_string(st, 10) retain];
	m->messageId = [col_string(st, 11) retain];
	m->inReplyTo = [col_string(st, 12) retain];
	m->references = [col_string(st, 13) retain];
	m->size = sqlite3_column_int64(st, 14);
	m->attachment = sqlite3_column_int(st, 15) != 0;
	m->snippet = [col_string(st, 16) retain];
	m->file = [col_string(st, 17) retain];
	m->thread = [col_string(st, 18) retain];
	return m;
}

- (NSArray *) messagesInMailbox: (long long)mbid limit: (int)limit
{
	NSMutableArray *r = [NSMutableArray array];
	[lock lock];
	sqlite3_stmt *st = [self prepare: "SELECT " MESSAGE_COLUMNS " FROM messages WHERE " MBOX " AND (flags & 8) = 0"
	    " ORDER BY date DESC, uid DESC LIMIT ?2"];
	sqlite3_bind_int64(st, 1, mbid);
	sqlite3_bind_int(st, 2, limit);
	while (sqlite3_step(st) == SQLITE_ROW)
		[r addObject: [self messageFromRow: st]];
	sqlite3_finalize(st);
	[lock unlock];
	return r;
}

- (Mail2MessageInfo *) messageWithRowID: (long long)rowid
{
	Mail2MessageInfo *m = nil;
	[lock lock];
	sqlite3_stmt *st = [self prepare: "SELECT " MESSAGE_COLUMNS " FROM messages WHERE id = ?"];
	sqlite3_bind_int64(st, 1, rowid);
	if (sqlite3_step(st) == SQLITE_ROW)
		m = [self messageFromRow: st];
	sqlite3_finalize(st);
	[lock unlock];
	return m;
}

- (unsigned) uidQuery: (const char *)sql mailbox: (long long)mbid
{
	unsigned u = 0;
	[lock lock];
	sqlite3_stmt *st = [self prepare: sql];
	sqlite3_bind_int64(st, 1, mbid);
	if (sqlite3_step(st) == SQLITE_ROW)
		u = (unsigned)sqlite3_column_int64(st, 0);
	sqlite3_finalize(st);
	[lock unlock];
	return u;
}

- (unsigned) maxUidInMailbox: (long long)mbid
{
	return [self uidQuery: "SELECT IFNULL(MAX(uid), 0) FROM messages WHERE mailbox = ?" mailbox: mbid];
}

- (unsigned) minUidInMailbox: (long long)mbid
{
	return [self uidQuery: "SELECT IFNULL(MIN(uid), 0) FROM messages WHERE mailbox = ?" mailbox: mbid];
}

- (NSDictionary *) flagsByUidInMailbox: (long long)mbid
{
	NSMutableDictionary *r = [NSMutableDictionary dictionary];
	[lock lock];
	sqlite3_stmt *st = [self prepare: "SELECT uid, flags FROM messages WHERE mailbox = ?"];
	sqlite3_bind_int64(st, 1, mbid);
	while (sqlite3_step(st) == SQLITE_ROW)
		[r setObject: [NSNumber numberWithInt: sqlite3_column_int(st, 1)]
		      forKey: [NSNumber numberWithUnsignedInt: (unsigned)sqlite3_column_int64(st, 0)]];
	sqlite3_finalize(st);
	[lock unlock];
	return r;
}

- (void) addMessages: (NSArray *)infos
{
	NSEnumerator *e = [infos objectEnumerator];
	Mail2MessageInfo *m;
	[lock lock];
	[self exec: "BEGIN"];
	sqlite3_stmt *st = [self prepare:
	    "INSERT INTO messages(mailbox, uid, flags, date, from_name, from_addr, to_list, cc_list, reply_to, subject,"
	    " message_id, in_reply_to, refs, size, attach) VALUES(?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)"
	    " ON CONFLICT(mailbox, uid) DO UPDATE SET flags = excluded.flags"];
	while ((m = [e nextObject]) != nil) {
		sqlite3_reset(st);
		sqlite3_bind_int64(st, 1, m->mbid);
		sqlite3_bind_int64(st, 2, m->uid);
		sqlite3_bind_int(st, 3, m->flags);
		sqlite3_bind_double(st, 4, m->date ? [m->date timeIntervalSince1970] : 0);
		bind_string(st, 5, m->fromName);
		bind_string(st, 6, m->fromAddr);
		bind_string(st, 7, m->to);
		bind_string(st, 8, m->cc);
		bind_string(st, 9, m->replyTo);
		bind_string(st, 10, m->subject);
		bind_string(st, 11, m->messageId);
		bind_string(st, 12, m->inReplyTo);
		bind_string(st, 13, m->references);
		sqlite3_bind_int64(st, 14, m->size);
		sqlite3_bind_int(st, 15, m->attachment);
		if (sqlite3_step(st) != SQLITE_DONE)
			NSLog(@"mail2: sqlite: %s", sqlite3_errmsg(DB));
		else if (sqlite3_changes(DB) == 1)
			[self threadMessage: m];
	}
	sqlite3_finalize(st);
	[self exec: "COMMIT"];
	[lock unlock];
}

/* Gives a message its conversation key: the key of a known message it refers to (or that refers to it), else the
 * first id it refers to, else its own id. Conversations that this message shows to be one are merged. Called with
 * the row just inserted or updated. */
- (void) threadMessage: (Mail2MessageInfo *)m
{
	NSMutableArray *ids = [NSMutableArray array];
	NSString *refs = Mail2MessageIDsIn(m->references);
	if (refs)
		[ids addObjectsFromArray: [refs componentsSeparatedByString: @" "]];
	if ([m->inReplyTo length] && ![ids containsObject: m->inReplyTo])
		[ids addObject: m->inReplyTo];
	if ([m->messageId length])
		[ids addObject: m->messageId];
	sqlite3_stmt *st;
	NSString *key = nil;
	NSEnumerator *e = [ids objectEnumerator];
	NSString *i;
	st = [self prepare: "SELECT thread FROM messages WHERE message_id = ? AND thread IS NOT NULL AND NOT (mailbox = ? AND uid = ?)"
	    " LIMIT 1"];
	while (key == nil && (i = [e nextObject]) != nil) {
		sqlite3_reset(st);
		bind_string(st, 1, i);
		sqlite3_bind_int64(st, 2, m->mbid);
		sqlite3_bind_int64(st, 3, m->uid);
		if (sqlite3_step(st) == SQLITE_ROW)
			key = col_string(st, 0);
	}
	sqlite3_finalize(st);
	if (key == nil)
		key = [ids count] ? [ids objectAtIndex: 0] : [NSString stringWithFormat: @"uid:%lld:%u", m->mbid, m->uid];
	st = [self prepare: "UPDATE messages SET thread = ? WHERE mailbox = ? AND uid = ?"];
	bind_string(st, 1, key);
	sqlite3_bind_int64(st, 2, m->mbid);
	sqlite3_bind_int64(st, 3, m->uid);
	sqlite3_step(st);
	sqlite3_finalize(st);
	ASSIGN(m->thread, key);
	/* messages that were filed under one of these ids join this conversation */
	st = [self prepare: "UPDATE messages SET thread = ?1 WHERE thread = ?2 AND thread != ?1"];
	e = [ids objectEnumerator];
	while ((i = [e nextObject]) != nil) {
		sqlite3_reset(st);
		bind_string(st, 1, key);
		bind_string(st, 2, i);
		sqlite3_step(st);
	}
	sqlite3_finalize(st);
}

- (NSArray *) rowsFor: (sqlite3_stmt *)st counted: (BOOL)counted
{
	NSMutableArray *r = [NSMutableArray array];
	while (st && sqlite3_step(st) == SQLITE_ROW) {
		Mail2MessageInfo *m = [self messageFromRow: st];
		if (counted) {
			m->threadCount = sqlite3_column_int(st, 19);
			m->threadUnread = sqlite3_column_int(st, 20);
		}
		[r addObject: m];
	}
	sqlite3_finalize(st);
	return r;
}

- (NSArray *) conversationsInMailbox: (long long)mbid limit: (int)limit
{
	NSArray *r;
	[lock lock];
	sqlite3_stmt *st = [self prepare: "SELECT " MESSAGE_COLUMNS ", n, u FROM (SELECT *,"
	    " COUNT(*) OVER w AS n, SUM((flags & 1) = 0) OVER w AS u,"
	    " ROW_NUMBER() OVER (PARTITION BY IFNULL(thread, id) ORDER BY date DESC, uid DESC) AS k"
	    " FROM messages WHERE " MBOX " AND (flags & 8) = 0 WINDOW w AS (PARTITION BY IFNULL(thread, id)))"
	    " WHERE k = 1 ORDER BY date DESC, uid DESC LIMIT ?2"];
	sqlite3_bind_int64(st, 1, mbid);
	sqlite3_bind_int(st, 2, limit);
	r = [self rowsFor: st counted: YES];
	[lock unlock];
	return r;
}

- (NSArray *) messagesInConversation: (NSString *)thread mailbox: (long long)mbid
{
	NSArray *r;
	if (thread == nil)
		return [NSArray array];
	[lock lock];
	sqlite3_stmt *st = [self prepare: "SELECT " MESSAGE_COLUMNS " FROM messages WHERE " MBOX " AND thread = ?2"
	    " AND (flags & 8) = 0 ORDER BY date DESC, uid DESC"];
	sqlite3_bind_int64(st, 1, mbid);
	bind_string(st, 2, thread);
	r = [self rowsFor: st counted: NO];
	[lock unlock];
	return r;
}

/* "word1* word2*" for MATCH: each word a prefix, only letters and digits (no FTS syntax from the user) */
static NSString *
fts_query(NSString *text)
{
	NSMutableArray *terms = [NSMutableArray array];
	NSEnumerator *e = [[text componentsSeparatedByCharactersInSet: [[NSCharacterSet alphanumericCharacterSet] invertedSet]]
	    objectEnumerator];
	NSString *w;
	while ((w = [e nextObject]) != nil)
		if ([w length])
			[terms addObject: [NSString stringWithFormat: @"%@*", w]];
	return [terms componentsJoinedByString: @" "];
}

static NSString *
like_pattern(NSString *t)
{
	NSString *e = [[[t stringByReplacingOccurrencesOfString: @"\\" withString: @"\\\\"]
	    stringByReplacingOccurrencesOfString: @"%" withString: @"\\%"] stringByReplacingOccurrencesOfString: @"_" withString: @"\\_"];
	return [NSString stringWithFormat: @"%%%@%%", e];
}

/* Mail2ParseSearch's query in SQL: every filter, and every free word (in the envelope, the opening or the downloaded
 * body) -- or, for the words, being among the server's matches (uids) */
- (NSArray *) searchMailbox: (long long)mbid text: (NSString *)text alsoUids: (NSArray *)uids limit: (int)limit
{
	NSDictionary *q = Mail2ParseSearch(text ? text : @"");
	NSMutableArray *params = [NSMutableArray array];	/* strings, or NSNumber doubles */
	NSMutableString *sql = [NSMutableString stringWithString: @"SELECT " MESSAGE_COLUMNS " FROM messages WHERE " MBOX
	    " AND (flags & 8) = 0"];
#define P(v) ([params addObject: (v)], [NSString stringWithFormat: @"?%lu", (unsigned long)[params count] + 1])
	NSEnumerator *e;
	NSString *v;
	e = [[q objectForKey: @"From"] objectEnumerator];
	while ((v = [e nextObject]) != nil) {
		NSString *ph = P(like_pattern(v));
		[sql appendFormat: @" AND (from_name LIKE %@ ESCAPE '\\' OR from_addr LIKE %@ ESCAPE '\\')", ph, ph];
	}
	e = [[q objectForKey: @"To"] objectEnumerator];
	while ((v = [e nextObject]) != nil) {
		NSString *ph = P(like_pattern(v));
		[sql appendFormat: @" AND (to_list LIKE %@ ESCAPE '\\' OR cc_list LIKE %@ ESCAPE '\\')", ph, ph];
	}
	e = [[q objectForKey: @"Subject"] objectEnumerator];
	while ((v = [e nextObject]) != nil)
		[sql appendFormat: @" AND subject LIKE %@ ESCAPE '\\'", P(like_pattern(v))];
	if ([q objectForKey: @"Attachment"]) [sql appendString: @" AND attach = 1"];
	if ([q objectForKey: @"Unread"]) [sql appendString: @" AND (flags & 1) = 0"];
	if ([q objectForKey: @"Read"]) [sql appendString: @" AND (flags & 1) != 0"];
	if ([q objectForKey: @"Flagged"]) [sql appendString: @" AND (flags & 4) != 0"];
	if ([q objectForKey: @"Before"])
		[sql appendFormat: @" AND date < %@", P([NSNumber numberWithDouble: [[q objectForKey: @"Before"] timeIntervalSince1970]])];
	if ([q objectForKey: @"After"])
		[sql appendFormat: @" AND date >= %@", P([NSNumber numberWithDouble: [[q objectForKey: @"After"] timeIntervalSince1970]])];
	NSArray *words = [q objectForKey: @"Words"];
	if ([words count]) {
		NSMutableString *w = [NSMutableString stringWithString: @"(1"];
		e = [words objectEnumerator];
		while ((v = [e nextObject]) != nil) {
			NSString *ph = P(like_pattern(v));
			[w appendString: [@" AND (subject LIKE # ESCAPE '\\' OR from_name LIKE # ESCAPE '\\' OR from_addr LIKE # ESCAPE '\\'"
			    " OR to_list LIKE # ESCAPE '\\' OR cc_list LIKE # ESCAPE '\\' OR snippet LIKE # ESCAPE '\\'"
			    stringByReplacingOccurrencesOfString: @"#" withString: ph]];
			NSString *fq = fts_query(v);
			if ([fq length])
				[w appendFormat: @" OR id IN (SELECT docid FROM bodies WHERE body MATCH %@)", P(fq)];
			[w appendString: @")"];
		}
		[w appendString: @")"];
		NSString *uidList = [uids count] && mbid >= 0 ? [uids componentsJoinedByString: @","] : nil;	/* numbers only */
		if (uidList)
			[sql appendFormat: @" AND (%@ OR uid IN (%@))", w, uidList];
		else
			[sql appendFormat: @" AND %@", w];
	}
	[sql appendFormat: @" ORDER BY date DESC, uid DESC LIMIT %d", limit];
#undef P
	NSArray *r;
	[lock lock];
	sqlite3_stmt *st = [self prepare: [sql UTF8String]];
	sqlite3_bind_int64(st, 1, mbid);
	NSUInteger i;
	for (i = 0; i < [params count]; i++) {
		id pv = [params objectAtIndex: i];
		if ([pv isKindOfClass: [NSNumber class]])
			sqlite3_bind_double(st, (int)i + 2, [pv doubleValue]);
		else
			bind_string(st, (int)i + 2, pv);
	}
	r = [self rowsFor: st counted: NO];
	[lock unlock];
	return r;
}

/* renames the message's Maildir file to carry its new flags */
- (NSString *) renameFile: (NSString *)file ofMailbox: (long long)mbid flags: (int)flags
{
	Mail2Mailbox *mb;
	NSRange r;
	if (file == nil || (mb = [self mailboxWithID: mbid]) == nil)
		return file;
	r = [file rangeOfString: @":2," options: NSBackwardsSearch];
	NSString *base = r.location != NSNotFound ? [file substringToIndex: r.location] : file;
	NSString *nf = [NSString stringWithFormat: @"%@:2,%@", base, maildir_flags(flags)];
	if ([nf isEqualToString: file])
		return file;
	NSString *cur = [[self maildirForMailbox: mb create: NO] stringByAppendingPathComponent: @"cur"];
	if (rename([[cur stringByAppendingPathComponent: file] fileSystemRepresentation],
	           [[cur stringByAppendingPathComponent: nf] fileSystemRepresentation]) != 0)
		return file;
	return nf;
}

- (void) setFlags: (int)flags forMessage: (long long)rowid
{
	[lock lock];
	Mail2MessageInfo *m = [self messageWithRowID: rowid];
	if (m != nil) {
		NSString *f = [self renameFile: m->file ofMailbox: m->mbid flags: flags];
		sqlite3_stmt *st = [self prepare: "UPDATE messages SET flags = ?, file = ? WHERE id = ?"];
		sqlite3_bind_int(st, 1, flags);
		bind_string(st, 2, f);
		sqlite3_bind_int64(st, 3, rowid);
		sqlite3_step(st);
		sqlite3_finalize(st);
	}
	[lock unlock];
}

- (void) setFlags: (int)flags forUid: (unsigned)uid inMailbox: (long long)mbid
{
	[lock lock];
	sqlite3_stmt *st = [self prepare: "SELECT id FROM messages WHERE mailbox = ? AND uid = ?"];
	sqlite3_bind_int64(st, 1, mbid);
	sqlite3_bind_int64(st, 2, uid);
	long long rowid = sqlite3_step(st) == SQLITE_ROW ? sqlite3_column_int64(st, 0) : 0;
	sqlite3_finalize(st);
	if (rowid)
		[self setFlags: flags forMessage: rowid];
	[lock unlock];
}

- (void) removeMessage: (long long)rowid
{
	[lock lock];
	Mail2MessageInfo *m = [self messageWithRowID: rowid];
	NSString *p = m ? [self pathForMessage: m] : nil;
	if (p != nil)
		unlink([p fileSystemRepresentation]);
	sqlite3_stmt *st = [self prepare: "DELETE FROM messages WHERE id = ?"];
	sqlite3_bind_int64(st, 1, rowid);
	sqlite3_step(st);
	sqlite3_finalize(st);
	[lock unlock];
}

- (void) removeUids: (NSArray *)uids inMailbox: (long long)mbid
{
	NSEnumerator *e = [uids objectEnumerator];
	NSNumber *u;
	[lock lock];
	[self exec: "BEGIN"];
	sqlite3_stmt *st = [self prepare: "SELECT id FROM messages WHERE mailbox = ? AND uid = ?"];
	while ((u = [e nextObject]) != nil) {
		sqlite3_reset(st);
		sqlite3_bind_int64(st, 1, mbid);
		sqlite3_bind_int64(st, 2, [u unsignedIntValue]);
		if (sqlite3_step(st) == SQLITE_ROW)
			[self removeMessage: sqlite3_column_int64(st, 0)];
	}
	sqlite3_finalize(st);
	[self exec: "COMMIT"];
	[lock unlock];
}

- (int) countQuery: (const char *)sql mailbox: (long long)mbid
{
	return (int)[self uidQuery: sql mailbox: mbid];
}

- (int) unreadInMailbox: (long long)mbid
{
	if (mbid == Mail2AllInboxesID)
		return [self unreadInInboxes];
	if (mbid == Mail2FlaggedID)
		return [self flaggedCount];
	if (mbid == Mail2UnreadID)
		return [self unreadCount];
	return [self countQuery: "SELECT COUNT(*) FROM messages WHERE mailbox = ? AND (flags & 9) = 0" mailbox: mbid];
}

- (int) unreadCount
{
	int n = 0;
	[lock lock];
	sqlite3_stmt *st = [self prepare: "SELECT COUNT(*) FROM messages WHERE (flags & 9) = 0 AND"
	    " mailbox NOT IN (SELECT id FROM mailboxes WHERE special IN ('trash', 'junk', 'sent', 'drafts'))"];
	if (st && sqlite3_step(st) == SQLITE_ROW)
		n = sqlite3_column_int(st, 0);
	sqlite3_finalize(st);
	[lock unlock];
	return n;
}

- (int) flaggedCount
{
	int n = 0;
	[lock lock];
	sqlite3_stmt *st = [self prepare: "SELECT COUNT(*) FROM messages WHERE (flags & 12) = 4 AND"
	    " mailbox NOT IN (SELECT id FROM mailboxes WHERE special IN ('trash', 'junk'))"];
	if (st && sqlite3_step(st) == SQLITE_ROW)
		n = sqlite3_column_int(st, 0);
	sqlite3_finalize(st);
	[lock unlock];
	return n;
}

- (int) unreadInInboxes
{
	int n = 0;
	[lock lock];
	sqlite3_stmt *st = [self prepare: "SELECT COUNT(*) FROM messages JOIN mailboxes ON messages.mailbox = mailboxes.id"
	    " WHERE mailboxes.special = 'inbox' AND (messages.flags & 9) = 0"];
	if (sqlite3_step(st) == SQLITE_ROW)
		n = sqlite3_column_int(st, 0);
	sqlite3_finalize(st);
	[lock unlock];
	return n;
}

- (NSArray *) messagesToPrefetchInMailbox: (long long)mbid limit: (int)limit maxSize: (unsigned long long)maxSize
{
	NSMutableArray *r = [NSMutableArray array];
	[lock lock];
	sqlite3_stmt *st = [self prepare: "SELECT " MESSAGE_COLUMNS " FROM messages WHERE mailbox = ? AND file IS NULL"
	    " AND size <= ? AND (flags & 8) = 0 ORDER BY date DESC LIMIT ?"];
	sqlite3_bind_int64(st, 1, mbid);
	sqlite3_bind_int64(st, 2, maxSize);
	sqlite3_bind_int(st, 3, limit);
	while (sqlite3_step(st) == SQLITE_ROW)
		[r addObject: [self messageFromRow: st]];
	sqlite3_finalize(st);
	[lock unlock];
	return r;
}

- (BOOL) hasReplyTo: (NSString *)messageId
{
	if (messageId == nil)
		return NO;
	BOOL r = NO;
	[lock lock];
	sqlite3_stmt *st = [self prepare: "SELECT 1 FROM messages WHERE in_reply_to = ?1 OR instr(refs, ?1) > 0 LIMIT 1"];
	bind_string(st, 1, messageId);
	r = st && sqlite3_step(st) == SQLITE_ROW;
	sqlite3_finalize(st);
	[lock unlock];
	return r;
}

- (NSArray *) messagesWithMessageIDs: (NSArray *)ids
{
	NSMutableArray *r = [NSMutableArray array];
	NSEnumerator *e = [ids objectEnumerator];
	NSString *mid;
	[lock lock];
	sqlite3_stmt *st = [self prepare: "SELECT " MESSAGE_COLUMNS " FROM messages WHERE message_id = ? AND (flags & 8) = 0"
	    " ORDER BY (mailbox IN (SELECT id FROM mailboxes WHERE special = 'sent')) DESC LIMIT 1"];
	while ((mid = [e nextObject]) != nil) {
		sqlite3_reset(st);
		bind_string(st, 1, mid);
		if (sqlite3_step(st) == SQLITE_ROW)
			[r addObject: [self messageFromRow: st]];
	}
	sqlite3_finalize(st);
	[lock unlock];
	[r sortUsingComparator: ^NSComparisonResult(id a, id b) { return [[b date] compare: [a date]]; }];
	return r;
}

/* ---- muted conversations, blocked senders ---- */

- (void) setThread: (NSString *)thread muted: (BOOL)on
{
	if (thread == nil)
		return;
	[lock lock];
	sqlite3_stmt *st = [self prepare: on ? "INSERT OR IGNORE INTO muted(thread) VALUES(?)" : "DELETE FROM muted WHERE thread = ?"];
	bind_string(st, 1, thread);
	sqlite3_step(st);
	sqlite3_finalize(st);
	if (on) [muted addObject: thread]; else [muted removeObject: thread];
	[lock unlock];
}

- (BOOL) isThreadMuted: (NSString *)thread
{
	[lock lock];
	BOOL r = thread != nil && [muted containsObject: thread];
	[lock unlock];
	return r;
}

- (void) setAddress: (NSString *)addr blocked: (BOOL)on
{
	NSString *a = [[addr stringByTrimmingCharactersInSet: [NSCharacterSet whitespaceCharacterSet]] lowercaseString];
	if ([a length] == 0)
		return;
	[lock lock];
	sqlite3_stmt *st = [self prepare: on ? "INSERT OR IGNORE INTO blocked(address) VALUES(?)" : "DELETE FROM blocked WHERE address = ?"];
	bind_string(st, 1, a);
	sqlite3_step(st);
	sqlite3_finalize(st);
	if (on) [blocked addObject: a]; else [blocked removeObject: a];
	[lock unlock];
}

- (NSArray *) blockedAddresses
{
	[lock lock];
	NSArray *r = [[blocked allObjects] sortedArrayUsingSelector: @selector(compare:)];
	[lock unlock];
	return r;
}

- (BOOL) isAddressBlocked: (NSString *)addr
{
	[lock lock];
	BOOL r = addr != nil && [blocked containsObject: [addr lowercaseString]];
	[lock unlock];
	return r;
}

/* ---- addresses ---- */

- (NSArray *) addressesMatching: (NSString *)prefix limit: (int)limit
{
	NSMutableArray *r = [NSMutableArray array];
	NSMutableSet *seen = [NSMutableSet set];
	NSString *p = [[prefix lowercaseString] stringByTrimmingCharactersInSet: [NSCharacterSet whitespaceCharacterSet]];
	if ([p length] == 0)
		return r;
	NSString *like = [[[p stringByReplacingOccurrencesOfString: @"\\" withString: @"\\\\"]
	    stringByReplacingOccurrencesOfString: @"%" withString: @"\\%"] stringByReplacingOccurrencesOfString: @"_" withString: @"\\_"];
	[lock lock];
	/* senders, most frequent first: a name or an address starting with the text (or a word of the name) */
	sqlite3_stmt *st = [self prepare: "SELECT from_name, from_addr, COUNT(*) AS n FROM messages WHERE from_addr IS NOT NULL AND"
	    " (lower(from_addr) LIKE ?1 ESCAPE '\\' OR lower(from_name) LIKE ?1 ESCAPE '\\' OR lower(from_name) LIKE ?2 ESCAPE '\\')"
	    " GROUP BY lower(from_addr) ORDER BY n DESC, MAX(date) DESC LIMIT ?3"];
	bind_string(st, 1, [like stringByAppendingString: @"%"]);
	bind_string(st, 2, [NSString stringWithFormat: @"%% %@%%", like]);
	sqlite3_bind_int(st, 3, limit);
	while (st && sqlite3_step(st) == SQLITE_ROW) {
		NSString *name = col_string(st, 0), *addr = col_string(st, 1);
		if (addr == nil || [seen containsObject: [addr lowercaseString]])
			continue;
		[seen addObject: [addr lowercaseString]];
		[r addObject: [name length] ? [NSString stringWithFormat: @"%@ <%@>", name, addr] : addr];
	}
	sqlite3_finalize(st);
	/* and people written to (the To lines of Sent) */
	if ((int)[r count] < limit) {
		st = [self prepare: "SELECT to_list FROM messages JOIN mailboxes ON messages.mailbox = mailboxes.id"
		    " WHERE mailboxes.special = 'sent' AND lower(to_list) LIKE ?1 ORDER BY date DESC LIMIT 200"];
		bind_string(st, 1, [NSString stringWithFormat: @"%%%@%%", p]);
		while (st && sqlite3_step(st) == SQLITE_ROW && (int)[r count] < limit) {
			NSEnumerator *e = [Mail2SplitAddresses(col_string(st, 0)) objectEnumerator];
			NSString *a;
			while ((a = [e nextObject]) != nil && (int)[r count] < limit) {
				NSString *bare = [Mail2AddressPart(a) lowercaseString];
				if ([seen containsObject: bare] || ([bare rangeOfString: p].location != 0 &&
				    [[a lowercaseString] rangeOfString: p].location != 0))
					continue;
				[seen addObject: bare];
				[r addObject: a];
			}
		}
		sqlite3_finalize(st);
	}
	[lock unlock];
	return r;
}

/* ---- files ---- */

- (BOOL) storeMessageData: (NSData *)raw forMessage: (Mail2MessageInfo *)m snippet: (NSString *)snippet attachment: (BOOL)att
{
	return [self storeMessageData: raw forMessage: m snippet: snippet attachment: att body: nil];
}

- (BOOL) storeMessageData: (NSData *)raw forMessage: (Mail2MessageInfo *)m snippet: (NSString *)snippet attachment: (BOOL)att
                     body: (NSString *)body
{
	BOOL ok = NO;
	[lock lock];
	Mail2Mailbox *mb = [self mailboxWithID: m->mbid];
	Mail2MessageInfo *cur = [self messageWithRowID: m->rowid];
	if (mb != nil && cur != nil) {
		NSString *dir = [self maildirForMailbox: mb create: YES];
		NSString *base = [NSString stringWithFormat: @"%u_%u.mail2", mb->uidValidity, m->uid];
		NSString *name = [NSString stringWithFormat: @"%@:2,%@", base, maildir_flags(cur->flags)];
		NSString *tmp = [[dir stringByAppendingPathComponent: @"tmp"] stringByAppendingPathComponent: base];
		NSString *dst = [[dir stringByAppendingPathComponent: @"cur"] stringByAppendingPathComponent: name];
		if (cur->file != nil)
			unlink([[[dir stringByAppendingPathComponent: @"cur"] stringByAppendingPathComponent: cur->file] fileSystemRepresentation]);
		if ([raw writeToFile: tmp atomically: NO] && rename([tmp fileSystemRepresentation], [dst fileSystemRepresentation]) == 0) {
			sqlite3_stmt *st = [self prepare: "UPDATE messages SET file = ?, snippet = ?, attach = ? WHERE id = ?"];
			bind_string(st, 1, name);
			bind_string(st, 2, snippet);
			sqlite3_bind_int(st, 3, att);
			sqlite3_bind_int64(st, 4, m->rowid);
			sqlite3_step(st);
			sqlite3_finalize(st);
			if (body != nil) {
				st = [self prepare: "INSERT OR REPLACE INTO bodies(docid, body) VALUES(?, ?)"];
				sqlite3_bind_int64(st, 1, m->rowid);
				bind_string(st, 2, body);
				sqlite3_step(st);
				sqlite3_finalize(st);
			}
			ASSIGN(m->file, name);
			ASSIGN(m->snippet, snippet);
			m->attachment = att;
			ok = YES;
		} else
			unlink([tmp fileSystemRepresentation]);
	}
	[lock unlock];
	return ok;
}

- (NSString *) pathForMessage: (Mail2MessageInfo *)m
{
	Mail2MessageInfo *cur = [self messageWithRowID: m->rowid];	/* the name changes with the flags */
	Mail2Mailbox *mb;
	if (cur == nil || cur->file == nil || (mb = [self mailboxWithID: cur->mbid]) == nil)
		return nil;
	return [[[self maildirForMailbox: mb create: NO] stringByAppendingPathComponent: @"cur"] stringByAppendingPathComponent: cur->file];
}

@end
