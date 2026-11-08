/* Mail2Session: one account's network work (see Mail2Session.h). */
#import "Mail2Session.h"
#import "Mail2IMAP.h"
#import "Mail2SMTP.h"
#import "Mail2Message.h"
#import "Mail2Util.h"
#import "Mail2Rules.h"
#import <AppKit/AppKit.h>
#include <dispatch/dispatch.h>
#include <fcntl.h>
#include <poll.h>
#include <unistd.h>

NSString *const Mail2MailboxesChanged = @"Mail2MailboxesChanged";
NSString *const Mail2MessagesChanged = @"Mail2MessagesChanged";
NSString *const Mail2StatusChanged = @"Mail2StatusChanged";

#define Q ((dispatch_queue_t)queue)
#define SYNC_DAYS_DEFAULT 30
#define FIRST_SYNC_MAX 500	/* at most this many messages on a mailbox's first sync */
#define PREFETCH_COUNT 25	/* bodies downloaded after a sync, newest first, for snippets and quick reading */
#define PREFETCH_MAX_SIZE (512 * 1024)
#define CHECK_INTERVAL 300.0
#define IDLE_TIMEOUT (25 * 60)

void
Mail2UpdateDockBadge(void)
{
	int n = [[Mail2Store sharedStore] unreadInInboxes];
	NSDictionary *info = [NSDictionary dictionaryWithObjectsAndKeys:
	    @"Mail2", @"App", n > 0 ? [NSString stringWithFormat: @"%d", n] : @"", @"Badge", nil];
	[[NSDistributedNotificationCenter defaultCenter] postNotificationName: @"NaplesBadgeChanged"
	    object: @"Mail2" userInfo: info deliverImmediately: YES];
}

void
Mail2ClearDockBadge(void)
{
	[[NSDistributedNotificationCenter defaultCenter] postNotificationName: @"NaplesBadgeChanged"
	    object: @"Mail2" userInfo: [NSDictionary dictionaryWithObjectsAndKeys: @"Mail2", @"App", @"", @"Badge", nil]
	    deliverImmediately: YES];
}

@implementation Mail2Session

- (id) initWithAccount: (Mail2Account *)a
{
	if ((self = [super init]) == nil)
		return nil;
	account = [a retain];
	NSString *qn = [NSString stringWithFormat: @"mail2.%@", [a identifier]];
	queue = dispatch_queue_create([qn UTF8String], NULL);
	imap = [[Mail2IMAP alloc] initWithAccount: a];
	fetching = [[NSMutableSet alloc] init];
	complete = [[NSMutableSet alloc] init];
	idleWake[0] = idleWake[1] = -1;
	return self;
}

- (void) dealloc
{
	[self stop];
	[account release];
	[imap release];
	[status release];
	[lastError release];
	[fetching release];
	[complete release];
	if (queue)
		dispatch_release(Q);
	[super dealloc];
}

- (Mail2Account *) account { return account; }
- (NSString *) status { return status; }
- (NSString *) lastError { return lastError; }

/* ---- main-thread notifications ---- */

- (void) postStatus
{
	[[NSNotificationCenter defaultCenter] postNotificationName: Mail2StatusChanged object: self];
}

/* begin/end bracket a piece of queued work; the status shows while any is running */
- (void) begin: (NSString *)what
{
	NSString *w = [what copy];
	void (^b)(void) = ^{
		busy++;
		if (w != nil)
			ASSIGN(status, w);
		[w release];
		[self postStatus];
	};
	/* counted at once when called on the main thread, so -isBusy is right straight after a call */
	if ([NSThread isMainThread])
		b();
	else
		Mail2RunOnMain(b);
}

- (BOOL) isBusy
{
	return busy > 0;
}

- (void) end: (NSString *)err
{
	NSString *e = [err copy];
	Mail2RunOnMain(^{
		if (busy > 0)
			busy--;
		if (e != nil) {
			ASSIGN(lastError, e);
			NSLog(@"mail2: %@: %@", [account email], e);
		} else if (busy == 0)
			DESTROY(lastError);
		if (busy == 0)
			DESTROY(status);
		[e release];
		[self postStatus];
	});
}

- (void) postMailboxesChanged
{
	Mail2RunOnMain(^{
		[[NSNotificationCenter defaultCenter] postNotificationName: Mail2MailboxesChanged object: self];
		Mail2UpdateDockBadge();
	});
}

- (void) postMessagesChanged: (long long)mbid
{
	Mail2RunOnMain(^{
		[[NSNotificationCenter defaultCenter] postNotificationName: Mail2MessagesChanged object: self
		    userInfo: [NSDictionary dictionaryWithObject: [NSNumber numberWithLongLong: mbid] forKey: @"Mailbox"]];
		Mail2UpdateDockBadge();
	});
}

/* ---- on the queue ---- */

- (BOOL) q_refreshMailboxes: (NSString **)err
{
	NSArray *l = [imap listMailboxes: err];
	if (l == nil)
		return NO;
	[[Mail2Store sharedStore] setMailboxes: l forAccount: [account identifier]];
	[self postMailboxesChanged];
	return YES;
}

- (Mail2Mailbox *) mailboxWithSpecial: (NSString *)special
{
	NSEnumerator *e = [[[Mail2Store sharedStore] mailboxesForAccount: [account identifier]] objectEnumerator];
	Mail2Mailbox *m;
	while ((m = [e nextObject]) != nil)
		if ([[m special] isEqualToString: special])
			return m;
	return nil;
}

/* downloads one message's body into the Maildir with its snippet; on the queue, mailbox already selected */
- (NSString *) q_download: (Mail2MessageInfo *)m
{
	NSString *err = nil;
	NSData *raw = [imap fetchMessage: [m uid] error: &err];
	if (raw == nil)
		return err;
	Mail2ParsedMessage *p = [Mail2ParsedMessage parseData: raw preferPlainText: YES];
	if (![[Mail2Store sharedStore] storeMessageData: raw forMessage: m snippet: [p snippet]
	    attachment: [[p attachments] count] > 0 || [m hasAttachment] body: [p body]])
		return @"The message could not be saved (is the disk full?).";
	return nil;
}

- (BOOL) q_sync: (Mail2Mailbox *)mb error: (NSString **)err
{
	Mail2Store *store = [Mail2Store sharedStore];
	unsigned validity = 0, next = 0, exists = 0;
	long long mbid = [mb mbid];
	NSArray *uids;

	if (![mb selectable])
		return YES;
	if (![imap select: [mb name] uidValidity: &validity uidNext: &next exists: &exists error: err])
		return NO;
	if (mb->uidValidity != 0 && validity != mb->uidValidity) {
		/* the server renumbered the mailbox: everything we have is stale */
		[store clearMailbox: mbid];
		[self postMessagesChanged: mbid];
	}
	mb->uidValidity = validity;
	unsigned maxKnown = [store maxUidInMailbox: mbid];

	/* new messages */
	if (exists == 0)
		uids = [NSArray array];
	else if (maxKnown == 0) {
		NSInteger days = [[NSUserDefaults standardUserDefaults] integerForKey: @"Mail2SyncDays"];
		NSDate *since = [NSDate dateWithTimeIntervalSinceNow: -86400.0 * (days > 0 ? days : SYNC_DAYS_DEFAULT)];
		uids = [imap uidsSince: since error: err];
		/* an old mailbox with nothing recent still shows its last messages */
		if (uids != nil && [uids count] == 0)
			uids = [imap uidsAbove: 0 error: err];
		if ([uids count] > FIRST_SYNC_MAX)
			uids = [uids subarrayWithRange: NSMakeRange([uids count] - FIRST_SYNC_MAX, FIRST_SYNC_MAX)];
	} else
		uids = next > maxKnown + 1 || next == 0 ? [imap uidsAbove: maxKnown error: err] : [NSArray array];
	if (uids == nil)
		return NO;
	if ([uids count] > 0) {
		/* newest first, so the top of the list fills in first */
		NSArray *rev = [[uids reverseObjectEnumerator] allObjects];
		NSUInteger i;
		for (i = 0; i < [rev count]; i += 100) {
			NSArray *batch = [rev subarrayWithRange: NSMakeRange(i, MIN(100, [rev count] - i))];
			NSArray *infos = [imap fetchHeaders: batch mailbox: mbid error: err];
			if (infos == nil)
				return NO;
			[store addMessages: infos];
			/* new mail in an Inbox meets the rules (not the first sync's backlog) */
			if (maxKnown > 0 && [[mb special] isEqualToString: @"inbox"] && ![self q_applyRules: infos inMailbox: mb error: err])
				return NO;
			[self postMessagesChanged: mbid];
		}
	}

	/* flags of what we already had, and what has gone */
	unsigned minKnown = [store minUidInMailbox: mbid];
	if (maxKnown > 0 && minKnown > 0) {
		NSDictionary *server = exists ? [imap fetchFlagsFrom: minKnown error: err] : [NSDictionary dictionary];
		if (server == nil)
			return NO;
		NSDictionary *local = [store flagsByUidInMailbox: mbid];
		NSMutableArray *gone = [NSMutableArray array];
		NSEnumerator *e = [local keyEnumerator];
		NSNumber *u;
		BOOL changed = NO;
		while ((u = [e nextObject]) != nil) {
			NSNumber *sf = [server objectForKey: u];
			if (sf == nil) {
				if ([u unsignedIntValue] <= maxKnown)
					[gone addObject: u];
			} else if (![sf isEqual: [local objectForKey: u]]) {
				[store setFlags: [sf intValue] forUid: [u unsignedIntValue] inMailbox: mbid];
				changed = YES;
			}
		}
		if ([gone count] > 0)
			[store removeUids: gone inMailbox: mbid];
		if (changed || [gone count] > 0)
			[self postMessagesChanged: mbid];
	}
	[store setUidValidity: validity uidNext: next forMailbox: mbid];

	/* bodies of the newest messages, for their snippets */
	NSEnumerator *pe = [[store messagesToPrefetchInMailbox: mbid limit: PREFETCH_COUNT maxSize: PREFETCH_MAX_SIZE] objectEnumerator];
	Mail2MessageInfo *m;
	int n = 0;
	while ((m = [pe nextObject]) != nil) {
		NSString *e2 = [self q_download: m];
		if (e2 != nil && ![imap isConnected]) {
			*err = e2;
			return NO;
		}
		if (++n % 5 == 0)
			[self postMessagesChanged: mbid];
	}
	if (n % 5)
		[self postMessagesChanged: mbid];
	return YES;
}

/* runs a block on the queue, retrying once on a dropped connection (servers close idle connections) */
- (void) run: (NSString *)what work: (BOOL (^)(NSString **err))work
{
	[self begin: what];
	dispatch_async(Q, ^{
		NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];
		NSString *err = nil;
		BOOL ok = [imap connect: &err] && work(&err);
		if (!ok && ![imap isConnected]) {
			if (Mail2Debug())
				NSLog(@"mail2: %@ -- reconnecting and trying again", err);
			err = nil;
			ok = [imap connect: &err] && work(&err);
		}
		[self end: ok ? nil : err];
		[pool release];
	});
}

/* ---- public ---- */

- (void) refreshMailboxes
{
	[self run: @"Checking mailboxes…" work: ^BOOL (NSString **err) {
		return [self q_refreshMailboxes: err];
	}];
}

- (void) syncMailbox: (Mail2Mailbox *)mb
{
	if (mb == nil)
		return;
	[mb retain];
	[self run: [NSString stringWithFormat: @"Checking %@…", [mb displayName]] work: ^BOOL (NSString **err) {
		/* the row may be newer than the one we were handed */
		Mail2Mailbox *cur = [[Mail2Store sharedStore] mailboxWithID: [mb mbid]];
		BOOL ok = cur == nil || [self q_sync: cur error: err];
		return ok;
	}];
	[mb release];
}

- (void) checkInboxAnd: (Mail2Mailbox *)mb
{
	Mail2Mailbox *inbox = [self mailboxWithSpecial: @"inbox"];
	if (inbox != nil)
		[self syncMailbox: inbox];
	if (mb != nil && [mb mbid] != [inbox mbid] && [[mb account] isEqualToString: [account identifier]])
		[self syncMailbox: mb];
}

- (void) checkAll
{
	[self refreshMailboxes];
	[self checkInboxAnd: nil];
}

- (void) timerFired: (NSTimer *)t
{
	[self checkInboxAnd: nil];
}

- (void) start
{
	[self run: @"Checking mail…" work: ^BOOL (NSString **err) {
		if (![self q_refreshMailboxes: err])
			return NO;
		Mail2Mailbox *inbox = [self mailboxWithSpecial: @"inbox"];
		return inbox == nil || [self q_sync: inbox error: err];
	}];
	if (timer == nil)
		timer = [[NSTimer scheduledTimerWithTimeInterval: CHECK_INTERVAL target: self selector: @selector(timerFired:)
		    userInfo: nil repeats: YES] retain];
	if (idleThread == nil && pipe(idleWake) == 0) {
		fcntl(idleWake[0], F_SETFL, O_NONBLOCK);
		fcntl(idleWake[1], F_SETFL, O_NONBLOCK);
		stopping = NO;
		idleThread = [[NSThread alloc] initWithTarget: self selector: @selector(idleLoop:) object: nil];
		[idleThread start];
	}
}

- (void) stop
{
	stopping = YES;
	if (idleWake[1] >= 0)
		(void)write(idleWake[1], "q", 1);
	[timer invalidate];
	DESTROY(timer);
	DESTROY(idleThread);	/* it exits on its own; its fds are closed there */
}

/* The IDLE thread: its own connection, on the Inbox. Each time the server says something changed, the Inbox is synced
 * on the main connection. Reconnects after errors, backing off up to 5 minutes. */
- (void) idleLoop: (id)unused
{
	NSAutoreleasePool *outer = [[NSAutoreleasePool alloc] init];
	Mail2IMAP *conn = [[Mail2IMAP alloc] initWithAccount: account];
	int backoff = 15;
	int wfd = idleWake[0], wfd1 = idleWake[1];
	[self retain];
	while (!stopping) {
		NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];
		NSString *err = nil;
		Mail2Mailbox *inbox = [self mailboxWithSpecial: @"inbox"];
		BOOL ok = inbox != nil && [conn connect: &err] &&
		    [conn select: [inbox name] uidValidity: NULL uidNext: NULL exists: NULL error: &err];
		if (ok && ![conn hasCapability: @"IDLE"]) {
			/* the 5-minute timer covers servers without IDLE */
			[pool release];
			break;
		}
		while (ok && !stopping) {
			int r = [conn idleWithWakeFd: wfd timeout: IDLE_TIMEOUT error: &err];
			char buf[16];
			while (read(wfd, buf, sizeof(buf)) > 0)
				;
			ok = r >= 0;
			if (r > 0 && !stopping) {	/* only when the server said something; the timer covers the rest */
				backoff = 15;
				Mail2RunOnMain(^{ [self checkInboxAnd: nil]; });
			}
		}
		[conn disconnect];
		[pool release];
		if (stopping)
			break;
		/* no Inbox yet (first start), or an error: wait, then try again */
		struct pollfd p = { wfd, POLLIN, 0 };
		poll(&p, 1, (inbox == nil ? 5 : backoff) * 1000);
		if (backoff < 300)
			backoff *= 2;
	}
	[conn release];
	close(wfd);
	close(wfd1);
	[self release];
	[outer release];
}

- (void) fetchMessage: (Mail2MessageInfo *)m completion: (void (^)(NSString *err))done
{
	NSNumber *key = [NSNumber numberWithLongLong: [m rowid]];
	void (^cb)(NSString *) = [done copy];
	[m retain];
	[fetching addObject: key];
	[self begin: @"Downloading message…"];
	dispatch_async(Q, ^{
		NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];
		NSString *err = nil;
		Mail2Mailbox *mb = [[Mail2Store sharedStore] mailboxWithID: [m mbid]];
		int attempt;
		for (attempt = 0; attempt < 2; attempt++) {
			err = nil;
			if (mb == nil) {
				err = @"The mailbox is gone.";
				break;
			}
			if ([imap connect: &err] && [imap select: [mb name] uidValidity: NULL uidNext: NULL exists: NULL error: &err])
				err = [self q_download: m];
			if (err == nil || [imap isConnected])
				break;
		}
		[err retain];
		[self end: nil];	/* a failed download is reported by the completion, not as a sync error */
		Mail2RunOnMain(^{
			[fetching removeObject: key];
			cb(err);
			[cb release];
			[err release];
			[m release];
		});
		[pool release];
	});
}

- (void) setFlag: (int)flag on: (BOOL)on forMessages: (NSArray *)msgs
{
	Mail2Store *store = [Mail2Store sharedStore];
	NSMutableDictionary *byMailbox = [NSMutableDictionary dictionary];
	NSEnumerator *e = [msgs objectEnumerator];
	Mail2MessageInfo *m;
	while ((m = [e nextObject]) != nil) {
		int nf = on ? (m->flags | flag) : (m->flags & ~flag);
		if (nf == m->flags)
			continue;
		m->flags = nf;
		[store setFlags: nf forMessage: [m rowid]];
		NSNumber *k = [NSNumber numberWithLongLong: [m mbid]];
		NSMutableArray *a = [byMailbox objectForKey: k];
		if (a == nil)
			[byMailbox setObject: (a = [NSMutableArray array]) forKey: k];
		[a addObject: [NSNumber numberWithUnsignedInt: [m uid]]];
	}
	NSEnumerator *ke = [byMailbox keyEnumerator];
	NSNumber *k;
	while ((k = [ke nextObject]) != nil) {
		long long mbid = [k longLongValue];
		NSArray *uids = [byMailbox objectForKey: k];
		[[NSNotificationCenter defaultCenter] postNotificationName: Mail2MessagesChanged object: self
		    userInfo: [NSDictionary dictionaryWithObject: k forKey: @"Mailbox"]];
		[self run: nil work: ^BOOL (NSString **err) {
			Mail2Mailbox *mb = [[Mail2Store sharedStore] mailboxWithID: mbid];
			return mb == nil || ([imap select: [mb name] uidValidity: NULL uidNext: NULL exists: NULL error: err] &&
			    [imap setFlags: flag add: on uids: uids error: err]);
		}];
	}
	Mail2UpdateDockBadge();
}

- (void) moveMessages: (NSArray *)msgs toSpecial: (NSString *)special
{
	Mail2Mailbox *dest = [self mailboxWithSpecial: special];
	if (dest == nil && [special isEqualToString: @"archive"])
		dest = [self mailboxWithSpecial: @"all"];	/* Gmail: archiving is leaving the Inbox for All Mail */
	[self moveMessages: msgs toMailbox: dest special: special];
}

- (void) moveMessages: (NSArray *)msgs toMailbox: (Mail2Mailbox *)dest
{
	if (dest != nil)
		[self moveMessages: msgs toMailbox: dest special: nil];
}

/* special says what a missing destination means: "trash" deletes for good, "archive" and "junk" are errors */
- (void) moveMessages: (NSArray *)msgs toMailbox: (Mail2Mailbox *)dest special: (NSString *)special
{
	Mail2Store *store = [Mail2Store sharedStore];
	if (dest == nil && ![special isEqualToString: @"trash"]) {
		/* nowhere to put them: say so, and touch nothing (a row removed here would not come back with the next sync) */
		NSString *e = [NSString stringWithFormat: @"This account has no %@ mailbox.",
		    [special isEqualToString: @"junk"] ? @"Junk" : @"Archive"];
		[self begin: nil];
		[self end: e];
		return;
	}
	NSMutableDictionary *byMailbox = [NSMutableDictionary dictionary];
	NSEnumerator *e = [msgs objectEnumerator];
	Mail2MessageInfo *m;
	while ((m = [e nextObject]) != nil) {
		if (dest != nil && [m mbid] == [dest mbid] && ![special isEqualToString: @"trash"])
			continue;	/* already there */
		NSNumber *k = [NSNumber numberWithLongLong: [m mbid]];
		NSMutableArray *a = [byMailbox objectForKey: k];
		if (a == nil)
			[byMailbox setObject: (a = [NSMutableArray array]) forKey: k];
		[a addObject: [NSNumber numberWithUnsignedInt: [m uid]]];
		[store removeMessage: [m rowid]];
	}
	NSEnumerator *ke = [byMailbox keyEnumerator];
	NSNumber *k;
	NSString *destName = [[dest name] copy];
	long long destId = dest ? [dest mbid] : 0;
	NSString *what = [special isEqualToString: @"trash"] ? @"Deleting…" : [special isEqualToString: @"archive"] ? @"Archiving…"
	    : @"Moving…";
	while ((k = [ke nextObject]) != nil) {
		long long mbid = [k longLongValue];
		NSArray *uids = [byMailbox objectForKey: k];
		[[NSNotificationCenter defaultCenter] postNotificationName: Mail2MessagesChanged object: self
		    userInfo: [NSDictionary dictionaryWithObject: k forKey: @"Mailbox"]];
		[self run: what work: ^BOOL (NSString **err) {
			Mail2Mailbox *mb = [[Mail2Store sharedStore] mailboxWithID: mbid];
			if (mb == nil || ![imap select: [mb name] uidValidity: NULL uidNext: NULL exists: NULL error: err])
				return mb == nil;
			if (destName == nil || mbid == destId) {
				/* no Trash (or deleting in the Trash): delete for good */
				if (destName == nil && ![special isEqualToString: @"trash"]) {
					*err = [NSString stringWithFormat: @"This account has no %@ mailbox.",
					    [special isEqualToString: @"junk"] ? @"Junk" : @"Archive"];
					return NO;
				}
				return [imap expungeUids: uids error: err];
			}
			if (![imap moveUids: uids to: destName error: err])
				return NO;
			/* the destination gets the messages on its next sync */
			Mail2Mailbox *d = [[Mail2Store sharedStore] mailboxWithID: destId];
			return d == nil || [self q_sync: d error: err];
		}];
	}
	[destName autorelease];
	Mail2UpdateDockBadge();
}

/* ---- rules ---- */

/* On the queue, with mb selected: each message meets the rules in order (Mail2Rules.h); the server first, then the
 * store. Returns NO only on a connection error. */
- (BOOL) q_applyRules: (NSArray *)infos inMailbox: (Mail2Mailbox *)mb error: (NSString **)err
{
	NSArray *rules = Mail2RulesForAccount([account identifier]);
	Mail2Store *store = [Mail2Store sharedStore];
	NSMutableArray *seen = [NSMutableArray array], *flagged = [NSMutableArray array];
	NSMutableDictionary *moves = [NSMutableDictionary dictionary];	/* destination IMAP name -> uids */
	NSEnumerator *e = [infos objectEnumerator];
	Mail2MessageInfo *m;
	NSString *trashName = [[self mailboxWithSpecial: @"trash"] name];
	while ((m = [e nextObject]) != nil) {
		NSEnumerator *re = [rules objectEnumerator];
		Mail2Rule *r;
		NSNumber *u = [NSNumber numberWithUnsignedInt: [m uid]];
		/* before any rule: a blocked sender's mail goes to the Trash, a muted conversation's is marked read */
		if ([store isAddressBlocked: [m fromAddr]] && trashName != nil && ![trashName isEqualToString: [mb name]]) {
			NSMutableArray *a = [moves objectForKey: trashName];
			if (a == nil)
				[moves setObject: (a = [NSMutableArray array]) forKey: trashName];
			[a addObject: u];
			continue;
		}
		if ([store isThreadMuted: [m thread]] && [m isUnread])
			[seen addObject: u];
		while ((r = [re nextObject]) != nil) {
			if (![r matches: m account: [account identifier]])
				continue;
			NSString *dest = nil;
			if (r->action == Mail2RuleMarkRead)
				[seen addObject: u];
			else if (r->action == Mail2RuleFlag)
				[flagged addObject: u];
			else if (r->action == Mail2RuleTrash)
				dest = [[self mailboxWithSpecial: @"trash"] name];
			else
				dest = r->mailbox;
			if (dest != nil && ![dest isEqualToString: [mb name]]) {
				NSMutableArray *a = [moves objectForKey: dest];
				if (a == nil)
					[moves setObject: (a = [NSMutableArray array]) forKey: dest];
				[a addObject: u];
			}
			if ([r endsRun])
				break;
		}
	}
	if ([seen count]) {
		if (![imap setFlags: Mail2FlagSeen add: YES uids: seen error: err])
			return ![imap isConnected] ? NO : YES;
		NSDictionary *flags = [store flagsByUidInMailbox: [mb mbid]];
		e = [seen objectEnumerator];
		NSNumber *u;
		while ((u = [e nextObject]) != nil)
			[store setFlags: [[flags objectForKey: u] intValue] | Mail2FlagSeen forUid: [u unsignedIntValue] inMailbox: [mb mbid]];
	}
	if ([flagged count]) {
		if (![imap setFlags: Mail2FlagFlagged add: YES uids: flagged error: err])
			return ![imap isConnected] ? NO : YES;
		NSDictionary *flags = [store flagsByUidInMailbox: [mb mbid]];
		e = [flagged objectEnumerator];
		NSNumber *u;
		while ((u = [e nextObject]) != nil)
			[store setFlags: [[flags objectForKey: u] intValue] | Mail2FlagFlagged forUid: [u unsignedIntValue] inMailbox: [mb mbid]];
	}
	NSEnumerator *de = [moves keyEnumerator];
	NSString *dest;
	while ((dest = [de nextObject]) != nil) {
		NSArray *uids = [moves objectForKey: dest];
		if (![imap moveUids: uids to: dest error: err]) {
			if (![imap isConnected])
				return NO;
			NSLog(@"mail2: a rule could not move to %@: %@", dest, *err);
			*err = nil;
			continue;
		}
		[store removeUids: uids inMailbox: [mb mbid]];
	}
	if (Mail2Debug() && ([seen count] || [flagged count] || [moves count]))
		NSLog(@"Mail2: rules: %lu read, %lu flagged, moved to %@", (unsigned long)[seen count], (unsigned long)[flagged count],
		    [moves allKeys]);
	return YES;
}

- (void) applyRulesTo: (NSArray *)msgs
{
	NSMutableDictionary *byMailbox = [NSMutableDictionary dictionary];
	NSEnumerator *e = [msgs objectEnumerator];
	Mail2MessageInfo *m;
	while ((m = [e nextObject]) != nil) {
		NSNumber *k = [NSNumber numberWithLongLong: [m mbid]];
		NSMutableArray *a = [byMailbox objectForKey: k];
		if (a == nil)
			[byMailbox setObject: (a = [NSMutableArray array]) forKey: k];
		[a addObject: m];
	}
	NSEnumerator *ke = [byMailbox keyEnumerator];
	NSNumber *k;
	while ((k = [ke nextObject]) != nil) {
		NSArray *mine = [[byMailbox objectForKey: k] retain];
		long long mbid = [k longLongValue];
		[self run: @"Applying rules…" work: ^BOOL (NSString **err) {
			Mail2Mailbox *mb = [[Mail2Store sharedStore] mailboxWithID: mbid];
			BOOL ok = mb == nil || ([imap select: [mb name] uidValidity: NULL uidNext: NULL exists: NULL error: err] &&
			    [self q_applyRules: mine inMailbox: mb error: err]);
			[self postMessagesChanged: mbid];
			return ok;
		}];
		[mine autorelease];
	}
}

/* Undo of a move: the messages found again in dest by Message-ID (their UIDs there are new) and moved back */
- (void) moveBackMessageIDs: (NSArray *)ids from: (Mail2Mailbox *)dest to: (Mail2Mailbox *)src
{
	if ([ids count] == 0 || dest == nil || src == nil)
		return;
	NSArray *mids = [ids copy];
	NSString *dn = [[dest name] copy], *sn = [[src name] copy];
	long long did = [dest mbid], sid = [src mbid];
	[self run: @"Undoing…" work: ^BOOL (NSString **err) {
		if (![imap select: dn uidValidity: NULL uidNext: NULL exists: NULL error: err])
			return NO;
		NSMutableArray *uids = [NSMutableArray array];
		NSEnumerator *e = [mids objectEnumerator];
		NSString *mid;
		while ((mid = [e nextObject]) != nil) {
			NSArray *u = [imap uidsWithMessageID: mid error: err];
			if (u == nil)
				return NO;
			[uids addObjectsFromArray: u];
		}
		if ([uids count] && ![imap moveUids: uids to: sn error: err])
			return NO;
		[[Mail2Store sharedStore] removeUids: uids inMailbox: did];
		[self postMessagesChanged: did];
		Mail2Mailbox *s2 = [[Mail2Store sharedStore] mailboxWithID: sid];
		return s2 == nil || [self q_sync: s2 error: err];
	}];
	[mids autorelease];
	[dn autorelease];
	[sn autorelease];
}

- (BOOL) isGmail
{
	NSString *h = [[account imapHost] lowercaseString];
	return [h hasSuffix: @"gmail.com"] || [h hasSuffix: @"googlemail.com"];
}

- (void) copyMessages: (NSArray *)msgs toMailbox: (Mail2Mailbox *)dest
{
	NSMutableDictionary *byMailbox = [NSMutableDictionary dictionary];
	NSEnumerator *e = [msgs objectEnumerator];
	Mail2MessageInfo *m;
	while ((m = [e nextObject]) != nil) {
		if ([m mbid] == [dest mbid])
			continue;
		NSNumber *k = [NSNumber numberWithLongLong: [m mbid]];
		NSMutableArray *a = [byMailbox objectForKey: k];
		if (a == nil)
			[byMailbox setObject: (a = [NSMutableArray array]) forKey: k];
		[a addObject: [NSNumber numberWithUnsignedInt: [m uid]]];
	}
	NSString *dn = [[dest name] copy];
	long long did = [dest mbid];
	NSEnumerator *ke = [byMailbox keyEnumerator];
	NSNumber *k;
	while ((k = [ke nextObject]) != nil) {
		long long mbid = [k longLongValue];
		NSArray *uids = [byMailbox objectForKey: k];
		[self run: [self isGmail] ? @"Labelling…" : @"Copying…" work: ^BOOL (NSString **err) {
			Mail2Mailbox *mb = [[Mail2Store sharedStore] mailboxWithID: mbid];
			if (mb == nil || ![imap select: [mb name] uidValidity: NULL uidNext: NULL exists: NULL error: err] ||
			    ![imap copyUids: uids to: dn error: err])
				return mb == nil;
			Mail2Mailbox *d = [[Mail2Store sharedStore] mailboxWithID: did];
			return d == nil || [self q_sync: d error: err];
		}];
	}
	[dn autorelease];
}

- (void) labelsOf: (Mail2MessageInfo *)m completion: (void (^)(NSArray *labels))done
{
	if (![self isGmail]) {
		done(nil);
		return;
	}
	void (^cb)(NSArray *) = [done copy];
	long long mbid = [m mbid];
	unsigned uid = [m uid];
	dispatch_async(Q, ^{
		NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];
		NSString *err = nil;
		Mail2Mailbox *mb = [[Mail2Store sharedStore] mailboxWithID: mbid];
		NSArray *labels = nil;
		if (mb && [imap connect: &err] && [imap select: [mb name] uidValidity: NULL uidNext: NULL exists: NULL error: &err])
			labels = [imap gmailLabelsOf: uid error: &err];
		[labels retain];
		Mail2RunOnMain(^{ cb(labels); [cb release]; [labels release]; });
		[pool release];
	});
}

- (Mail2Mailbox *) mailboxNamed: (NSString *)display
{
	NSEnumerator *e = [[[Mail2Store sharedStore] mailboxesForAccount: [account identifier]] objectEnumerator];
	Mail2Mailbox *m;
	while ((m = [e nextObject]) != nil)
		if ([m depth] == 0 && [[m displayName] isEqualToString: display])
			return m;
	return nil;
}

- (void) moveMessages: (NSArray *)msgs toNamedMailbox: (NSString *)name
{
	Mail2Mailbox *dest = [self mailboxNamed: name];
	if (dest != nil) {
		[self moveMessages: msgs toMailbox: dest];
		return;
	}
	/* made first, then the move */
	NSArray *keep = [msgs retain];
	NSString *n = [name copy];
	[self run: [NSString stringWithFormat: @"Making %@…", name] work: ^BOOL (NSString **err) {
		char d;
		NSString *full = [[self q_newMailboxPrefix: &d] stringByAppendingString: Mail2EncodeMailboxName(n)];
		BOOL ok = [imap createMailbox: full error: err] && [self q_refreshMailboxes: err];
		Mail2RunOnMain(^{
			Mail2Mailbox *made = [self mailboxNamed: n];
			if (made != nil)
				[self moveMessages: keep toMailbox: made];
			[keep release];
			[n release];
		});
		return ok;
	}];
}

- (void) moveBackFromNamed: (NSString *)fromDisplayName messageIDs: (NSArray *)ids toNamed: (NSString *)imapName markUnread: (BOOL)unread
{
	Mail2Mailbox *from = [self mailboxNamed: fromDisplayName];
	if (from == nil || [ids count] == 0)
		return;
	NSArray *mids = [ids copy];
	NSString *fn = [[from name] copy], *tn = [imapName copy];
	long long fid = [from mbid];
	[self run: @"Bringing back…" work: ^BOOL (NSString **err) {
		if (![imap select: fn uidValidity: NULL uidNext: NULL exists: NULL error: err])
			return NO;
		NSMutableArray *uids = [NSMutableArray array];
		NSEnumerator *e = [mids objectEnumerator];
		NSString *mid;
		while ((mid = [e nextObject]) != nil) {
			NSArray *u = [imap uidsWithMessageID: mid error: err];
			if (u == nil)
				return NO;
			[uids addObjectsFromArray: u];
		}
		if ([uids count] && ![imap moveUids: uids to: tn error: err])
			return NO;
		[[Mail2Store sharedStore] removeUids: uids inMailbox: fid];
		[self postMessagesChanged: fid];
		if (![imap select: tn uidValidity: NULL uidNext: NULL exists: NULL error: err])
			return NO;
		if (unread) {
			NSMutableArray *back = [NSMutableArray array];
			e = [mids objectEnumerator];
			while ((mid = [e nextObject]) != nil)
				[back addObjectsFromArray: [imap uidsWithMessageID: mid error: err]];
			if ([back count])
				[imap setFlags: Mail2FlagSeen add: NO uids: back error: err];
		}
		NSEnumerator *me = [[[Mail2Store sharedStore] mailboxesForAccount: [account identifier]] objectEnumerator];
		Mail2Mailbox *m;
		while ((m = [me nextObject]) != nil)
			if ([[m name] isEqualToString: tn])
				return [self q_sync: m error: err];
		return YES;
	}];
	[mids autorelease];
	[fn autorelease];
	[tn autorelease];
}

/* ---- mailboxes ---- */

/* the prefix new top-level mailboxes need: "INBOX." on servers whose folders all live under the Inbox */
- (NSString *) q_newMailboxPrefix: (char *)delim
{
	NSArray *all = [[Mail2Store sharedStore] mailboxesForAccount: [account identifier]];
	NSEnumerator *e = [all objectEnumerator];
	Mail2Mailbox *m;
	char d = '/';
	BOOL allUnderInbox = YES, any = NO;
	while ((m = [e nextObject]) != nil) {
		if (m->delimiter)
			d = m->delimiter;
		if ([[m special] isEqualToString: @"inbox"])
			continue;
		any = YES;
		if (![[[m name] uppercaseString] hasPrefix: [NSString stringWithFormat: @"INBOX%c", m->delimiter ? m->delimiter : '/']])
			allUnderInbox = NO;
	}
	*delim = d;
	return any && allUnderInbox ? [NSString stringWithFormat: @"INBOX%c", d] : @"";
}

- (void) createMailboxNamed: (NSString *)display
{
	NSString *n = [display copy];
	[self run: @"Creating the mailbox…" work: ^BOOL (NSString **err) {
		char d;
		NSString *full = [[self q_newMailboxPrefix: &d] stringByAppendingString: Mail2EncodeMailboxName(n)];
		return [imap createMailbox: full error: err] && [self q_refreshMailboxes: err];
	}];
	[n autorelease];
}

- (void) renameMailbox: (Mail2Mailbox *)mb to: (NSString *)display
{
	if (mb == nil || [mb special] != nil)
		return;
	NSString *old = [[mb name] copy];
	char delim = mb->delimiter;
	NSString *n = [display copy];
	[self run: @"Renaming the mailbox…" work: ^BOOL (NSString **err) {
		/* the same parent, a new last component */
		NSRange r = delim ? [old rangeOfString: [NSString stringWithFormat: @"%c", delim] options: NSBackwardsSearch]
		                  : NSMakeRange(NSNotFound, 0);
		NSString *parent = r.location != NSNotFound ? [old substringToIndex: r.location + 1] : @"";
		return [imap renameMailbox: old to: [parent stringByAppendingString: Mail2EncodeMailboxName(n)] error: err] &&
		    [self q_refreshMailboxes: err];
	}];
	[old autorelease];
	[n autorelease];
}

- (void) deleteMailbox: (Mail2Mailbox *)mb
{
	if (mb == nil || [mb special] != nil)
		return;
	NSString *old = [[mb name] copy];
	[self run: @"Deleting the mailbox…" work: ^BOOL (NSString **err) {
		return [imap deleteMailbox: old error: err] && [self q_refreshMailboxes: err];
	}];
	[old autorelease];
}

/* ---- older mail, search, drafts ---- */

- (BOOL) hasOlderMessagesIn: (Mail2Mailbox *)mb
{
	return mb != nil && [mb selectable] && ![complete containsObject: [NSNumber numberWithLongLong: [mb mbid]]];
}

- (void) loadOlderMessagesIn: (Mail2Mailbox *)mb count: (int)count completion: (void (^)(int added))done
{
	void (^cb)(int) = [done copy];
	long long mbid = [mb mbid];
	NSString *name = [[mb name] copy];
	__block int added = 0;
	[self run: @"Getting older messages…" work: ^BOOL (NSString **err) {
		Mail2Store *store = [Mail2Store sharedStore];
		added = 0;
		if (![imap select: name uidValidity: NULL uidNext: NULL exists: NULL error: err])
			return NO;
		unsigned lowest = [store minUidInMailbox: mbid];
		NSArray *older = lowest ? [imap uidsBelow: lowest error: err] : [imap uidsAbove: 0 error: err];
		if (older == nil)
			return NO;
		if ([older count] > (NSUInteger)count)
			older = [older subarrayWithRange: NSMakeRange([older count] - count, count)];
		if ([older count] == 0) {
			Mail2RunOnMain(^{ [complete addObject: [NSNumber numberWithLongLong: mbid]]; });
		} else {
			NSArray *infos = [imap fetchHeaders: [[older reverseObjectEnumerator] allObjects] mailbox: mbid error: err];
			if (infos == nil)
				return NO;
			[store addMessages: infos];
			added = (int)[infos count];
			[self postMessagesChanged: mbid];
		}
		return YES;
	}];
	/* the completion after the work: queued behind it on the same queue */
	dispatch_async(Q, ^{
		int n = added;
		Mail2RunOnMain(^{ if (cb) cb(n); [cb release]; [name release]; });
	});
}

- (void) searchServer: (NSString *)text inMailbox: (Mail2Mailbox *)mb completion: (void (^)(NSArray *uids, NSString *err))done
{
	void (^cb)(NSArray *, NSString *) = [done copy];
	long long mbid = [mb mbid];
	NSString *name = [[mb name] copy], *q = [text copy];
	dispatch_async(Q, ^{
		NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];
		NSString *err = nil;
		NSArray *uids = nil;
		int attempt;
		for (attempt = 0; attempt < 2 && uids == nil; attempt++) {
			err = nil;
			if ([imap connect: &err] && [imap select: name uidValidity: NULL uidNext: NULL exists: NULL error: &err])
				uids = [imap uidsMatchingText: q error: &err];
			if (uids == nil && [imap isConnected])
				break;
		}
		if (uids != nil) {
			/* matches we have no row for (older than what was synced): their headers, the newest 200 */
			NSDictionary *known = [[Mail2Store sharedStore] flagsByUidInMailbox: mbid];
			NSMutableArray *missing = [NSMutableArray array];
			NSEnumerator *e = [uids reverseObjectEnumerator];
			NSNumber *u;
			while ((u = [e nextObject]) != nil && [missing count] < 200)
				if ([known objectForKey: u] == nil)
					[missing addObject: u];
			if ([missing count]) {
				NSArray *infos = [imap fetchHeaders: missing mailbox: mbid error: &err];
				if (infos != nil)
					[[Mail2Store sharedStore] addMessages: infos];
			}
		}
		[uids retain];
		[err retain];
		Mail2RunOnMain(^{
			cb(uids, uids ? nil : err);
			[cb release];
			[uids release];
			[err release];
			[name release];
			[q release];
		});
		[pool release];
	});
}

/* the Drafts mailbox, created on the server when the account has none */
- (Mail2Mailbox *) q_draftsMailbox: (NSString **)err
{
	Mail2Mailbox *d = [self mailboxWithSpecial: @"drafts"];
	if (d != nil)
		return d;
	if (![imap createMailbox: @"Drafts" error: err] || ![self q_refreshMailboxes: err])
		return nil;
	d = [self mailboxWithSpecial: @"drafts"];
	if (d == nil)
		*err = @"The Drafts mailbox could not be made.";
	return d;
}

/* removes the copies of a draft (by its Message-ID) from Drafts, here and on the server */
- (BOOL) q_removeDraft: (NSString *)mid from: (Mail2Mailbox *)d error: (NSString **)err
{
	if (mid == nil)
		return YES;
	if (![imap select: [d name] uidValidity: NULL uidNext: NULL exists: NULL error: err])
		return NO;
	NSArray *uids = [imap uidsWithMessageID: mid error: err];
	if (uids == nil)
		return NO;
	if ([uids count] == 0)
		return YES;
	if (![imap expungeUids: uids error: err])
		return NO;
	[[Mail2Store sharedStore] removeUids: uids inMailbox: [d mbid]];
	[self postMessagesChanged: [d mbid]];
	return YES;
}

- (void) saveDraft: (NSData *)raw replacing: (NSString *)oldId completion: (void (^)(NSString *err))done
{
	void (^cb)(NSString *) = [done copy];
	NSString *old = [oldId copy];
	[raw retain];
	__block NSString *failure = nil;
	[self run: @"Saving draft…" work: ^BOOL (NSString **err) {
		Mail2Mailbox *d = [self q_draftsMailbox: err];
		failure = nil;
		if (d == nil || ![imap appendMessage: raw to: [d name] flags: Mail2FlagDraft | Mail2FlagSeen error: err]) {
			failure = [*err retain];
			return NO;
		}
		/* the new copy is there: the old one can go */
		[self q_removeDraft: old from: d error: err];
		return [self q_sync: d error: err];
	}];
	dispatch_async(Q, ^{
		NSString *f = failure;
		Mail2RunOnMain(^{
			if (cb) cb(f);
			[cb release];
			[f release];
			[old release];
			[raw release];
		});
	});
}

- (void) deleteDraft: (NSString *)mid
{
	if (mid == nil)
		return;
	NSString *m = [mid copy];
	[self run: nil work: ^BOOL (NSString **err) {
		Mail2Mailbox *d = [self mailboxWithSpecial: @"drafts"];
		return d == nil || [self q_removeDraft: m from: d error: err];
	}];
	[m autorelease];
}

- (void) sendMessage: (NSData *)raw recipients: (NSArray *)rcpts replyingTo: (Mail2MessageInfo *)orig
          completion: (void (^)(NSString *err))done
{
	void (^cb)(NSString *) = [done copy];
	[raw retain];
	[rcpts retain];
	[orig retain];
	[self begin: @"Sending…"];
	dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
		NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];
		NSString *err = nil;
		BOOL ok = Mail2SendMessage(account, raw, rcpts, &err);
		[err retain];
		[self end: nil];
		Mail2RunOnMain(^{
			cb(ok ? nil : err);
			[cb release];
			[err release];
		});
		if (ok) {
			/* the Sent copy (Gmail files sent mail itself) and \Answered on the original */
			BOOL gmail = [[[account imapHost] lowercaseString] hasSuffix: @"gmail.com"];
			Mail2Mailbox *sent = [self mailboxWithSpecial: @"sent"];
			if (sent != nil && !gmail) {
				NSString *sentName = [sent name];
				[self run: nil work: ^BOOL (NSString **e2) {
					return [imap appendMessage: raw to: sentName flags: Mail2FlagSeen error: e2];
				}];
			}
			if (orig != nil)
				Mail2RunOnMain(^{ [self setFlag: Mail2FlagAnswered on: YES forMessages: [NSArray arrayWithObject: orig]]; });
		}
		[raw release];
		[rcpts release];
		[orig release];
		[pool release];
	});
}

@end
