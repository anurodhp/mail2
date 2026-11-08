/* core_test: Mail2's mail core against a real IMAP/SMTP server (GreenMail on 127.0.0.1, started by
 * tests/run_host_tests.sh). Exits 0 when every check passes. */
#import <Foundation/Foundation.h>
#import "Mail2Account.h"
#import "Mail2IMAP.h"
#import "Mail2SMTP.h"
#import "Mail2Message.h"
#import "Mail2Store.h"
#import "Mail2Session.h"
#import "Mail2Util.h"
#import "Mail2OAuth.h"
#import "Mail2Rules.h"
#import "Mail2RichText.h"
#import "Mail2Outbox.h"
#import "Mail2Spell.h"
#include <mbedtls/sha256.h>
#include "Mail2TLS.h"
#include <libetpan/mailstream.h>
#include <libetpan/mailstream_helper.h>
#include <stdio.h>
#include <stdlib.h>

static int failures, checks;

#define CHECK(cond, ...) do { checks++; if (cond) printf("  ok    "); else { failures++; printf("  FAIL  "); } \
	printf("%s\n", [[NSString stringWithFormat: @__VA_ARGS__] UTF8String]); fflush(stdout); } while (0)

static Mail2Account *
account(NSString *user, NSString *pw)
{
	Mail2Account *a = [Mail2Account accountForEmail: user];
	[a setFullName: @"Test Üser"];
	[a setPassword: pw];
	[a setImapHost: @"127.0.0.1"];
	[a setImapPort: 3143];
	[a setImapSecurity: Mail2SecurityNone];
	[a setSmtpHost: @"127.0.0.1"];
	[a setSmtpPort: 3025];
	[a setSmtpSecurity: Mail2SecurityNone];
	return a;
}

static const char *html_message =
	"From: \"Ann Example\" <ann@example.com>\r\n"
	"To: test1@localhost\r\n"
	"Subject: =?UTF-8?Q?Quarterly_r=C3=A9port?=\r\n"
	"Message-ID: <html-1@example.com>\r\n"
	"References: <a@example.com> <b@example.com>\r\n"
	"Date: Fri, 06 Nov 2026 10:00:00 +0100\r\n"
	"MIME-Version: 1.0\r\n"
	"Content-Type: multipart/mixed; boundary=\"MIX\"\r\n"
	"\r\n"
	"--MIX\r\n"
	"Content-Type: multipart/alternative; boundary=\"ALT\"\r\n"
	"\r\n"
	"--ALT\r\n"
	"Content-Type: text/plain; charset=iso-8859-1\r\n"
	"Content-Transfer-Encoding: quoted-printable\r\n"
	"\r\n"
	"Hello, here is the r=E9port.\r\n"
	"\r\n"
	"--ALT\r\n"
	"Content-Type: text/html; charset=utf-8\r\n"
	"\r\n"
	"<html><head><style>p{color:red}</style></head><body><h1>Report</h1><p>Hello,&nbsp;here is the <b>report</b>.</p>"
	"<ul><li>One</li><li>Two</li></ul><script>alert(1)</script></body></html>\r\n"
	"--ALT--\r\n"
	"\r\n"
	"--MIX\r\n"
	"Content-Type: text/plain; name=\"report.txt\"\r\n"
	"Content-Disposition: attachment; filename=\"report.txt\"\r\n"
	"Content-Transfer-Encoding: base64\r\n"
	"\r\n"
	"bnVtYmVycyBnbyBoZXJlCg==\r\n"
	"--MIX--\r\n";

/* runs the main run loop until the condition holds or the time is up */
static BOOL
wait_for(BOOL (^cond)(void), double seconds)
{
	NSDate *end = [NSDate dateWithTimeIntervalSinceNow: seconds];
	while (!cond() && [end timeIntervalSinceNow] > 0)
		[[NSRunLoop currentRunLoop] runMode: NSDefaultRunLoopMode beforeDate: [NSDate dateWithTimeIntervalSinceNow: 0.1]];
	return cond();
}

static void
test_tls(void)
{
	char err[256];
	printf("TLS\n");
	mailstream *s = mail2_connect("127.0.0.1", 3993, 1, 10, err, sizeof(err));
	CHECK(s == NULL && strstr(err, "trusted") != NULL, "a self-signed certificate is refused (%s)", err);
	if (s)
		mailstream_close(s);
	if (getenv("NETWORK_TLS") && *getenv("NETWORK_TLS") == '0')
		return;
	s = mail2_connect("imap.gmail.com", 993, 1, 20, err, sizeof(err));
	CHECK(s != NULL, "imap.gmail.com:993 verifies against the CA bundle %s", s ? "" : err);
	if (s != NULL) {
		MMAPString *line = mmap_string_new("");
		char *l = mailstream_read_line_remove_eol(s, line);
		CHECK(l != NULL && strncmp(l, "* OK", 4) == 0, "and greets over TLS: %.40s", l ? l : "(nothing)");
		mmap_string_free(line);
		mailstream_close(s);
	}
}

int
main(void)
{
	NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];
	NSString *err = nil;
	Mail2Account *a1 = account(@"test1@localhost", @"pw1"), *a2 = account(@"test2@localhost", @"pw2");

	test_tls();

	printf("Headers\n");
	CHECK([Mail2DecodeHeader("=?UTF-8?B?R3LDvMOfZQ==?= world") isEqualToString: @"Grüße world"], "RFC 2047 decode");
	CHECK([Mail2DecodeMailboxName("Entw&APw-rfe") isEqualToString: @"Entwürfe"], "modified UTF-7 mailbox name");
	CHECK([Mail2DecodeHeader([Mail2EncodeHeader(@"Grüße ✓ — a longer subject line that must be split into words") UTF8String])
	    isEqualToString: @"Grüße ✓ — a longer subject line that must be split into words"], "RFC 2047 encode round trip");
	NSArray *split = Mail2SplitAddresses(@"a@b.c, \"Last, First\" <f@l.org>; x@y.z");
	CHECK([split count] == 3 && [Mail2AddressPart([split objectAtIndex: 1]) isEqualToString: @"f@l.org"], "address splitting");

	printf("SMTP\n");
	NSData *raw = Mail2BuildMessage([a2 fromAddress], [NSArray arrayWithObject: @"Test One <test1@localhost>"], nil,
	    @"Grüße ✓", @"Héllo there,\nthis is line two.\n\n> quoted\n", @"<orig@x>", [NSArray arrayWithObjects: @"<r1@x>", @"<orig@x>", nil]);
	CHECK(raw != nil, "message built (%lu bytes)", (unsigned long)[raw length]);
	NSString *rawStr = [[[NSString alloc] initWithData: raw encoding: NSUTF8StringEncoding] autorelease];
	CHECK([rawStr rangeOfString: @"Subject: =?UTF-8?B?"].location != NSNotFound, "subject encoded");
	CHECK([rawStr rangeOfString: @"In-Reply-To: <orig@x>"].location != NSNotFound, "In-Reply-To written");
	CHECK([rawStr rangeOfString: @"Content-Transfer-Encoding: quoted-printable"].location != NSNotFound, "quoted-printable body");
	CHECK([rawStr rangeOfString: @"=?UTF-8?B?VGVzdCDDnHNlcg==?= <test2@localhost>"].location != NSNotFound, "From name encoded, unquoted");
	CHECK(Mail2SendMessage(a2, raw, [NSArray arrayWithObject: @"test1@localhost"], &err), "sent through SMTP %@", err ? err : @"");
	Mail2Account *bad = account(@"test2@localhost", @"wrong");
	[bad setSmtpHost: @"127.0.0.1"];
	CHECK(Mail2BuildMessage(@"x <not an address>", [NSArray arrayWithObject: @"a@b"], nil, @"s", @"b", nil, nil) == nil,
	    "a bad From address is refused");

	printf("IMAP\n");
	Mail2IMAP *imap = [[Mail2IMAP alloc] initWithAccount: a1];
	Mail2IMAP *wrong = [[Mail2IMAP alloc] initWithAccount: account(@"test1@localhost", @"nope")];
	err = nil;
	CHECK(![wrong connect: &err] && err != nil, "a wrong password is refused: %@", err);
	err = nil;
	CHECK([imap connect: &err], "logged in %@", err ? err : @"");
	CHECK([imap createMailbox: @"Archive" error: &err] && [imap createMailbox: @"Trash" error: &err], "created Archive, Trash");
	CHECK([imap appendMessage: [NSData dataWithBytes: html_message length: strlen(html_message)] to: @"INBOX" flags: 0 error: &err],
	    "appended a multipart message %@", err ? err : @"");
	NSArray *boxes = [imap listMailboxes: &err];
	NSMutableDictionary *specials = [NSMutableDictionary dictionary];
	NSEnumerator *e = [boxes objectEnumerator];
	NSDictionary *d;
	while ((d = [e nextObject]) != nil)
		if ([d objectForKey: @"Special"])
			[specials setObject: [d objectForKey: @"Name"] forKey: [d objectForKey: @"Special"]];
	CHECK([[specials objectForKey: @"inbox"] isEqualToString: @"INBOX"] && [[specials objectForKey: @"archive"] isEqualToString: @"Archive"] &&
	    [[specials objectForKey: @"trash"] isEqualToString: @"Trash"], "listed %lu mailboxes, specials %@", (unsigned long)[boxes count], specials);

	unsigned validity = 0, next = 0, exists = 0;
	CHECK([imap select: @"INBOX" uidValidity: &validity uidNext: &next exists: &exists error: &err] && exists == 2,
	    "selected INBOX: %u messages, UIDVALIDITY %u, UIDNEXT %u", exists, validity, next);
	NSArray *uids = [imap uidsSince: [NSDate dateWithTimeIntervalSinceNow: -30 * 86400.0] error: &err];
	CHECK([uids count] == 2, "SEARCH SINCE: %@", uids);
	CHECK([[imap uidsAbove: [[uids objectAtIndex: 0] unsignedIntValue] error: &err] count] == 1, "SEARCH UID n+1:*");
	CHECK([[imap uidsAbove: [[uids lastObject] unsignedIntValue] error: &err] count] == 0, "SEARCH UID above the last is empty");

	Mail2Store *store = [Mail2Store sharedStore];
	[store setMailboxes: boxes forAccount: [a1 identifier]];
	NSArray *mbs = [store mailboxesForAccount: [a1 identifier]];
	Mail2Mailbox *inbox = [mbs objectAtIndex: 0];
	CHECK([[inbox special] isEqualToString: @"inbox"] && [[inbox displayName] isEqualToString: @"Inbox"], "store: Inbox first of %lu", (unsigned long)[mbs count]);
	NSArray *infos = [imap fetchHeaders: uids mailbox: [inbox mbid] error: &err];
	CHECK([infos count] == 2, "fetched %lu envelopes %@", (unsigned long)[infos count], err ? err : @"");
	Mail2MessageInfo *sent = nil, *html = nil;
	e = [infos objectEnumerator];
	Mail2MessageInfo *m;
	while ((m = [e nextObject]) != nil) {
		if ([[m subject] isEqualToString: @"Grüße ✓"]) sent = m;
		if ([[m subject] isEqualToString: @"Quarterly réport"]) html = m;
	}
	CHECK(sent != nil && [[sent fromName] isEqualToString: @"Test Üser"] && [[sent fromAddr] isEqualToString: @"test2@localhost"],
	    "envelope: %@ <%@> \"%@\"", [sent fromName], [sent fromAddr], [sent subject]);
	CHECK(html != nil && [html hasAttachment] && [[html fromName] isEqualToString: @"Ann Example"], "multipart/mixed seen as having an attachment");
	CHECK([[sent inReplyTo] isEqualToString: @"<orig@x>"], "In-Reply-To from the envelope: %@", [sent inReplyTo]);
	[store addMessages: infos];
	[store setUidValidity: validity uidNext: next forMailbox: [inbox mbid]];
	NSArray *rows = [store messagesInMailbox: [inbox mbid] limit: 100];
	CHECK([rows count] == 2 && [store unreadInMailbox: [inbox mbid]] == 2 && [store unreadInInboxes] == 2, "store: 2 rows, 2 unread");
	[store addMessages: infos];
	CHECK([[store messagesInMailbox: [inbox mbid] limit: 100] count] == 2, "adding again does not duplicate");

	printf("Messages\n");
	Mail2MessageInfo *row = nil;
	e = [rows objectEnumerator];
	while ((m = [e nextObject]) != nil)
		if ([m uid] == [html uid]) row = m;
	NSData *body = [imap fetchMessage: [row uid] error: &err];
	CHECK(body != nil && [body length] == strlen(html_message), "downloaded %lu bytes", (unsigned long)[body length]);
	Mail2ParsedMessage *pp = [Mail2ParsedMessage parseData: body preferPlainText: YES];
	CHECK([[pp body] rangeOfString: @"here is the réport"].location != NSNotFound && ![pp bodyWasHTML], "plain part, Latin-1 to UTF-8: %@",
	    [pp body]);
	Mail2ParsedMessage *ph = [Mail2ParsedMessage parseData: body preferPlainText: NO];
	CHECK([ph bodyWasHTML] && [[ph body] rangeOfString: @"Report\n\nHello, here is the report."].location != NSNotFound &&
	    [[ph body] rangeOfString: @"• One\n• Two"].location != NSNotFound && [[ph body] rangeOfString: @"alert"].location == NSNotFound &&
	    [[ph body] rangeOfString: @"color"].location == NSNotFound, "HTML to text: %@", [[ph body] stringByReplacingOccurrencesOfString: @"\n" withString: @"⏎"]);
	CHECK([[pp attachments] count] == 1 && [[[[pp attachments] objectAtIndex: 0] filename] isEqualToString: @"report.txt"] &&
	    [[[[NSString alloc] initWithData: [[[pp attachments] objectAtIndex: 0] data] encoding: NSUTF8StringEncoding] autorelease]
	    isEqualToString: @"numbers go here\n"], "the attachment, decoded");
	CHECK([[pp messageId] isEqualToString: @"<html-1@example.com>"] && [[pp references] count] == 2, "Message-ID and References");
	CHECK([[pp snippet] hasPrefix: @"Hello, here is the réport."], "snippet: %@", [pp snippet]);
	CHECK([store storeMessageData: body forMessage: row snippet: [pp snippet] attachment: YES], "written to the Maildir");
	NSString *path = [store pathForMessage: row];
	CHECK(path && [[NSFileManager defaultManager] fileExistsAtPath: path] && [path hasSuffix: @":2,"] &&
	    [[path stringByDeletingLastPathComponent] hasSuffix: @"/INBOX/cur"], "Maildir file %@", [path lastPathComponent]);
	[store setFlags: Mail2FlagSeen | Mail2FlagFlagged forMessage: [row rowid]];
	NSString *path2 = [store pathForMessage: row];
	CHECK([path2 hasSuffix: @":2,FS"] && [[NSFileManager defaultManager] fileExistsAtPath: path2] &&
	    ![[NSFileManager defaultManager] fileExistsAtPath: path], "flags renamed it to %@", [path2 lastPathComponent]);
	CHECK([[[store messageWithRowID: [row rowid]] snippet] hasPrefix: @"Hello"], "snippet stored");

	printf("Flags and moving\n");
	CHECK([imap setFlags: Mail2FlagSeen add: YES uids: [NSArray arrayWithObject: [NSNumber numberWithUnsignedInt: [row uid]]] error: &err],
	    "STORE +FLAGS \\Seen");
	NSDictionary *flags = [imap fetchFlagsFrom: 1 error: &err];
	CHECK(([[flags objectForKey: [NSNumber numberWithUnsignedInt: [row uid]]] intValue] & Mail2FlagSeen) &&
	    !([[flags objectForKey: [NSNumber numberWithUnsignedInt: [sent uid]]] intValue] & Mail2FlagSeen), "FETCH FLAGS: %@", flags);
	CHECK([imap moveUids: [NSArray arrayWithObject: [NSNumber numberWithUnsignedInt: [row uid]]] to: @"Archive" error: &err],
	    "moved to Archive (%@) %@", [imap hasCapability: @"MOVE"] ? @"MOVE" : @"COPY+EXPUNGE", err ? err : @"");
	CHECK([imap select: @"INBOX" uidValidity: NULL uidNext: NULL exists: &exists error: &err] && exists == 1, "INBOX has 1 left");
	CHECK([imap select: @"Archive" uidValidity: NULL uidNext: NULL exists: &exists error: &err] && exists == 1, "Archive has 1");
	NSArray *au = [imap uidsAbove: 0 error: &err];
	CHECK([imap expungeUids: au error: &err] && [imap select: @"Archive" uidValidity: NULL uidNext: NULL exists: &exists error: &err] &&
	    exists == 0, "expunged for good");
	[store removeMessage: [row rowid]];
	CHECK(![[NSFileManager defaultManager] fileExistsAtPath: path2], "removing the row removes the file");

	printf("IDLE\n");
	if (![imap hasCapability: @"IDLE"])
		printf("  skip  the server has no IDLE\n");
	else {
		Mail2IMAP *idler = [[Mail2IMAP alloc] initWithAccount: a1];
		CHECK([idler connect: &err] && [idler select: @"INBOX" uidValidity: NULL uidNext: NULL exists: NULL error: &err], "second connection");
		int p[2];
		pipe(p);
		dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 2 * NSEC_PER_SEC), dispatch_get_global_queue(0, 0), ^{
			NSString *e2 = nil;
			NSData *r2 = Mail2BuildMessage(@"test2@localhost", [NSArray arrayWithObject: @"test1@localhost"], nil, @"ping", @"new mail", nil, nil);
			Mail2SendMessage(a2, r2, [NSArray arrayWithObject: @"test1@localhost"], &e2);
		});
		NSDate *t0 = [NSDate date];
		int r = [idler idleWithWakeFd: p[0] timeout: 30 error: &err];
		double dt = -[t0 timeIntervalSinceNow];
		CHECK(r == 1 && dt > 1.5 && dt < 15, "IDLE woke %.1f s after it started, on new mail", dt);
		t0 = [NSDate date];
		write(p[1], "x", 1);
		r = [idler idleWithWakeFd: p[0] timeout: 30 error: &err];
		CHECK(r == 0 && -[t0 timeIntervalSinceNow] < 5, "a wakeup ends IDLE without reporting a change");
		[idler release];
	}

	printf("Session\n");
	[store clearMailbox: [inbox mbid]];
	Mail2Session *sess = [[Mail2Session alloc] initWithAccount: a1];
	__block int changes = 0;
	[[NSNotificationCenter defaultCenter] addObserverForName: Mail2MessagesChanged object: sess queue: nil
	    usingBlock: ^(NSNotification *n) { changes++; }];
	[sess start];
	BOOL synced = wait_for(^BOOL { return ![sess isBusy] && changes > 0 &&
	    [[store messagesInMailbox: [inbox mbid] limit: 100] count] >= 2; }, 30);
	NSArray *srows = [store messagesInMailbox: [inbox mbid] limit: 100];
	CHECK(synced, "start: synced the Inbox, %lu messages, error %@", (unsigned long)[srows count], [sess lastError]);
	BOOL snippets = wait_for(^BOOL {
		NSEnumerator *se = [[store messagesInMailbox: [inbox mbid] limit: 100] objectEnumerator];
		Mail2MessageInfo *x;
		while ((x = [se nextObject]) != nil)
			if ([x file] == nil) return NO;
		return YES;
	}, 20);
	CHECK(snippets, "bodies prefetched with snippets: \"%@\"", [[srows lastObject] snippet]);
	[sess setFlag: Mail2FlagSeen on: YES forMessages: srows];
	CHECK([store unreadInMailbox: [inbox mbid]] == 0, "marked read locally at once");
	wait_for(^BOOL { return ![sess isBusy]; }, 15);
	flags = nil;
	[imap select: @"INBOX" uidValidity: NULL uidNext: NULL exists: NULL error: &err];
	flags = [imap fetchFlagsFrom: 1 error: &err];
	BOOL allSeen = [flags count] > 0;
	e = [flags objectEnumerator];
	NSNumber *f;
	while ((f = [e nextObject]) != nil)
		allSeen = allSeen && ([f intValue] & Mail2FlagSeen);
	CHECK(allSeen, "and on the server: %@", flags);
	/* new mail through IDLE reaches the store without any action */
	unsigned before = (unsigned)[[store messagesInMailbox: [inbox mbid] limit: 100] count];
	NSData *r3 = Mail2BuildMessage(@"test2@localhost", [NSArray arrayWithObject: @"test1@localhost"], nil, @"pushed", @"via IDLE", nil, nil);
	Mail2SendMessage(a2, r3, [NSArray arrayWithObject: @"test1@localhost"], &err);
	BOOL pushed = wait_for(^BOOL { return [[store messagesInMailbox: [inbox mbid] limit: 100] count] == before + 1; }, 20);
	CHECK(pushed, "new mail arrived through IDLE without a check");
	[sess moveMessages: [NSArray arrayWithObject: [[store messagesInMailbox: [inbox mbid] limit: 1] objectAtIndex: 0]] toSpecial: @"trash"];
	CHECK([[store messagesInMailbox: [inbox mbid] limit: 100] count] == before, "moved to Trash locally at once");
	wait_for(^BOOL { return ![sess isBusy]; }, 15);
	Mail2Mailbox *trash = [sess mailboxWithSpecial: @"trash"];
	CHECK([[store messagesInMailbox: [trash mbid] limit: 100] count] == 1, "and the Trash synced with it (%@)", [sess lastError]);
	[sess stop];

	printf("Attachments\n");
	{
		const char bin[] = { 'P', 'D', 'F', 0, 1, 2, (char)0xff };
		NSArray *files = [NSArray arrayWithObjects:
		    [[[Mail2Attachment alloc] initWithName: @"report.pdf" type: nil data: [NSData dataWithBytes: bin length: sizeof(bin)]] autorelease],
		    [[[Mail2Attachment alloc] initWithName: @"résumé.txt" type: @"text/plain"
		        data: [@"plain file" dataUsingEncoding: NSUTF8StringEncoding]] autorelease], nil];
		NSData *raw = Mail2BuildMessageEx(@"Test <test2@localhost>", [NSArray arrayWithObject: @"test1@localhost"], nil,
		    [NSArray arrayWithObject: @"Hidden One <hidden@localhost>"], @"with files", @"see attached", nil, nil, files,
		    @"<fixed-1@localhost>");
		Mail2ParsedMessage *pm = [Mail2ParsedMessage parseData: raw preferPlainText: YES];
		NSArray *got = [pm attachments];
		CHECK([got count] == 2 && [[[got objectAtIndex: 0] filename] isEqualToString: @"report.pdf"] &&
		    [[[got objectAtIndex: 0] data] isEqualToData: [NSData dataWithBytes: bin length: sizeof(bin)]] &&
		    [[[got objectAtIndex: 0] mimeType] isEqualToString: @"application/pdf"],
		    "binary attachment round trip (%lu parts)", (unsigned long)[got count]);
		CHECK([got count] == 2 && [[[got objectAtIndex: 1] filename] isEqualToString: @"résumé.txt"], "non-ASCII file name: %@",
		    [got count] > 1 ? [[got objectAtIndex: 1] filename] : @"-");
		CHECK([[pm body] hasPrefix: @"see attached"], "the text part is the body");
		CHECK([[pm messageId] isEqualToString: @"<fixed-1@localhost>"], "given Message-ID: %@", [pm messageId]);
		CHECK([[pm bcc] rangeOfString: @"hidden@localhost"].location != NSNotFound, "draft Bcc header: %@", [pm bcc]);
		NSData *sent = Mail2BuildMessageEx(@"test2@localhost", [NSArray arrayWithObject: @"test1@localhost"], nil, nil,
		    @"s", @"b", nil, nil, files, nil);
		CHECK([[[NSString alloc] initWithData: sent encoding: NSISOLatin1StringEncoding] rangeOfString: @"hidden"].location == NSNotFound &&
		    [[Mail2ParsedMessage parseData: sent preferPlainText: YES] messageId] != nil, "a sent message gets its own Message-ID and no Bcc");
	}

	printf("Conversations, search, older mail\n");
	{
		Mail2Session *s2 = [[Mail2Session alloc] initWithAccount: a1];
		[store clearMailbox: [inbox mbid]];
		/* A, B replying to A, C replying to B, and an unrelated D */
		struct { NSString *mid, *irt, *refs, *subject, *body; } t[] = {
			{ @"<thr-a@localhost>", nil, nil, @"Trip plans", @"Shall we go? zebracorn" },
			{ @"<thr-b@localhost>", @"<thr-a@localhost>", @"<thr-a@localhost>", @"Re: Trip plans", @"Yes" },
			{ @"<thr-c@localhost>", @"<thr-b@localhost>", @"<thr-a@localhost> <thr-b@localhost>", @"Re: Trip plans", @"Great" },
			{ @"<other-d@localhost>", nil, nil, @"Invoice quokka", @"Unrelated" },
		};
		unsigned k;
		for (k = 0; k < 4; k++) {
			NSData *r = Mail2BuildMessageEx(@"test2@localhost", [NSArray arrayWithObject: @"test1@localhost"], nil, nil,
			    t[k].subject, t[k].body, t[k].irt, t[k].refs ? [t[k].refs componentsSeparatedByString: @" "] : nil, nil, t[k].mid);
			Mail2SendMessage(a2, r, [NSArray arrayWithObject: @"test1@localhost"], &err);
		}
		BOOL arrived = wait_for(^BOOL {
			NSString *e3 = nil;
			unsigned ex = 0;
			return [imap select: @"INBOX" uidValidity: NULL uidNext: NULL exists: &ex error: &e3] && ex >= 5;
		}, 15);
		[s2 refreshMailboxes];
		[s2 syncMailbox: inbox];
		wait_for(^BOOL { return ![s2 isBusy]; }, 30);
		NSArray *all = [store messagesInMailbox: [inbox mbid] limit: 100];
		NSArray *conv = [store conversationsInMailbox: [inbox mbid] limit: 100];
		Mail2MessageInfo *head = nil, *x;
		NSEnumerator *ce = [conv objectEnumerator];
		while ((x = [ce nextObject]) != nil)
			if ([[x thread] isEqualToString: @"<thr-a@localhost>"])
				head = x;
		CHECK(arrived && [all count] >= 5, "synced %lu messages", (unsigned long)[all count]);
		CHECK(head != nil && [head threadCount] == 3 && [[head messageId] isEqualToString: @"<thr-c@localhost>"],
		    "A, B and C are one conversation of 3, newest first (%d, %@)", [head threadCount], [head messageId]);
		CHECK([conv count] == [all count] - 2, "%lu conversation rows for %lu messages", (unsigned long)[conv count], (unsigned long)[all count]);
		CHECK([[store messagesInConversation: [head thread] mailbox: [inbox mbid]] count] == 3, "its messages");
		NSArray *hits = [store searchMailbox: [inbox mbid] text: @"quokka" alsoUids: nil limit: 50];
		CHECK([hits count] == 1 && [[[hits objectAtIndex: 0] subject] isEqualToString: @"Invoice quokka"], "local search by subject");
		BOOL bodies = wait_for(^BOOL { return [[store searchMailbox: [inbox mbid] text: @"zebrac" alsoUids: nil limit: 50] count] == 1; }, 15);
		CHECK(bodies, "local search of downloaded bodies (word prefix)");
		CHECK([[store searchMailbox: [inbox mbid] text: @"100%_\"'*" alsoUids: nil limit: 50] count] == 0, "search text with SQL and FTS syntax is harmless");
		__block NSArray *srv = nil;
		__block BOOL srvDone = NO;
		[s2 searchServer: @"zebracorn" inMailbox: inbox completion: ^(NSArray *u, NSString *e4) { srv = [u retain]; srvDone = YES; }];
		wait_for(^BOOL { return srvDone; }, 15);
		CHECK([srv count] == 1, "server search (UID SEARCH TEXT): %@", srv);

		/* older mail: keep only the newest row, then fetch what came before it, 2 at a time */
		Mail2MessageInfo *newest = [all objectAtIndex: 0];
		NSUInteger total = [all count];
		[store clearMailbox: [inbox mbid]];
		[imap select: @"INBOX" uidValidity: NULL uidNext: NULL exists: NULL error: &err];
		[store addMessages: [imap fetchHeaders: [NSArray arrayWithObject: [NSNumber numberWithUnsignedInt: [newest uid]]] mailbox: [inbox mbid] error: &err]];
		CHECK([[store messagesInMailbox: [inbox mbid] limit: 100] count] == 1, "one message left here");
		__block int got = -1, rounds = 0;
		while ([s2 hasOlderMessagesIn: inbox] && rounds < 10) {
			got = -1;
			[s2 loadOlderMessagesIn: inbox count: 2 completion: ^(int n) { got = n; }];
			wait_for(^BOOL { return got >= 0; }, 15);
			rounds++;
		}
		CHECK([[store messagesInMailbox: [inbox mbid] limit: 100] count] == total && ![s2 hasOlderMessagesIn: inbox],
		    "older messages fetched back, 2 at a time, in %d rounds: %lu of %lu", rounds,
		    (unsigned long)[[store messagesInMailbox: [inbox mbid] limit: 100] count], (unsigned long)total);

		printf("Drafts\n");
		NSData *d1 = Mail2BuildMessageEx(@"test1@localhost", [NSArray arrayWithObject: @"someone@localhost"], nil, nil,
		    @"draft v1", @"first", nil, nil, nil, @"<draft-1@localhost>");
		NSData *d2 = Mail2BuildMessageEx(@"test1@localhost", [NSArray arrayWithObject: @"someone@localhost"], nil, nil,
		    @"draft v2", @"second", nil, nil, nil, @"<draft-2@localhost>");
		__block BOOL saved = NO;
		__block NSString *serr = nil;
		[s2 saveDraft: d1 replacing: nil completion: ^(NSString *e5) { serr = [e5 retain]; saved = YES; }];
		wait_for(^BOOL { return saved && ![s2 isBusy]; }, 20);
		Mail2Mailbox *drafts = [s2 mailboxWithSpecial: @"drafts"];
		NSArray *dl = drafts ? [store messagesInMailbox: [drafts mbid] limit: 10] : nil;
		CHECK(serr == nil && [dl count] == 1 && [[dl objectAtIndex: 0] isDraft], "saved to Drafts (made on the server: %@) %@",
		    [drafts name], serr ? serr : @"");
		saved = NO;
		[s2 saveDraft: d2 replacing: @"<draft-1@localhost>" completion: ^(NSString *e5) { saved = YES; }];
		wait_for(^BOOL { return saved && ![s2 isBusy]; }, 20);
		dl = drafts ? [store messagesInMailbox: [drafts mbid] limit: 10] : nil;
		CHECK([dl count] == 1 && [[[dl objectAtIndex: 0] subject] isEqualToString: @"draft v2"], "saving again replaces it (%lu)",
		    (unsigned long)[dl count]);
		[s2 deleteDraft: @"<draft-2@localhost>"];
		wait_for(^BOOL { return ![s2 isBusy]; }, 20);
		unsigned dex = 99;
		[imap select: [drafts name] uidValidity: NULL uidNext: NULL exists: &dex error: &err];
		CHECK(drafts && [[store messagesInMailbox: [drafts mbid] limit: 10] count] == 0 && dex == 0, "sent: the draft is removed");
		[s2 release];
	}

	printf("All Inboxes (two accounts)\n");
	{
		Mail2Account *b1 = account(@"test1@localhost", @"pw1"), *b2 = account(@"test2@localhost", @"pw2");
		Mail2Session *t1 = [[Mail2Session alloc] initWithAccount: b1], *t2 = [[Mail2Session alloc] initWithAccount: b2];
		NSData *r = Mail2BuildMessage(@"test1@localhost", [NSArray arrayWithObject: @"test2@localhost"], nil, @"for two zebrafish",
		    @"hello two", nil, nil);
		Mail2SendMessage(a1, r, [NSArray arrayWithObject: @"test2@localhost"], &err);
		[t1 refreshMailboxes];
		[t2 refreshMailboxes];
		wait_for(^BOOL { return ![t1 isBusy] && ![t2 isBusy]; }, 20);
		[t1 checkInboxAnd: nil];
		[t2 checkInboxAnd: nil];
		BOOL both = wait_for(^BOOL { return ![t1 isBusy] && ![t2 isBusy] &&
		    [[store messagesInMailbox: [[t2 mailboxWithSpecial: @"inbox"] mbid] limit: 100] count] > 0; }, 30);
		NSUInteger n1 = [[store messagesInMailbox: [[t1 mailboxWithSpecial: @"inbox"] mbid] limit: 1000] count];
		NSUInteger n2 = [[store messagesInMailbox: [[t2 mailboxWithSpecial: @"inbox"] mbid] limit: 1000] count];
		NSUInteger all = [[store messagesInMailbox: Mail2AllInboxesID limit: 1000] count];
		CHECK(both && n1 > 0 && n2 > 0 && all == n1 + n2, "every Inbox together: %lu = %lu + %lu", (unsigned long)all,
		    (unsigned long)n1, (unsigned long)n2);
		CHECK([store unreadInMailbox: Mail2AllInboxesID] == [store unreadInInboxes], "its unread count");
		CHECK([[store conversationsInMailbox: Mail2AllInboxesID limit: 1000] count] > 0 &&
		    [[store conversationsInMailbox: Mail2AllInboxesID limit: 1000] count] <= all, "as conversations");
		NSArray *z = [store searchMailbox: Mail2AllInboxesID text: @"zebrafish" alsoUids: nil limit: 50];
		CHECK([z count] == 1 && [[[store mailboxWithID: [[z objectAtIndex: 0] mbid]] account] isEqualToString: @"test2@localhost"],
		    "search across them finds test2's message");
		[t1 release];
		[t2 release];
	}

	printf("OAuth (a stand-in for the providers on 127.0.0.1:3080)\n");
	{
		NSUserDefaults *ud = [NSUserDefaults standardUserDefaults];
		[ud registerDefaults: [NSDictionary dictionaryWithObjectsAndKeys:
		    @"test-google-client", @"Mail2GoogleClientID", @"test-ms-client", @"Mail2MicrosoftClientID",
		    @"http://127.0.0.1:3080/auth", @"Mail2GoogleAuthURL", @"http://127.0.0.1:3080/token", @"Mail2GoogleTokenURL",
		    @"http://127.0.0.1:3080/devicecode", @"Mail2MicrosoftDeviceURL", @"http://127.0.0.1:3080/token", @"Mail2MicrosoftTokenURL",
		    nil]];
		CHECK([Mail2Account oauthProviderForEmail: @"a@gmail.com"] == Mail2AuthGoogle &&
		    [Mail2Account oauthProviderForEmail: @"a@outlook.com"] == Mail2AuthMicrosoft &&
		    [Mail2Account oauthProviderForEmail: @"a@example.com"] == Mail2AuthPassword &&
		    [[[Mail2Account accountForEmail: @"a@hotmail.com"] imapHost] isEqualToString: @"outlook.office365.com"],
		    "providers from the address; Outlook.com's servers");

		/* a refresh: the token, the rotated refresh token saved and announced */
		Mail2Account *g = account(@"test1@localhost", nil);
		[g setAuth: Mail2AuthGoogle];
		[g setRefreshToken: @"rt-1"];
		__block int announced = 0;
		id obs = [[NSNotificationCenter defaultCenter] addObserverForName: Mail2AccountChanged object: g queue: nil
		    usingBlock: ^(NSNotification *n) { announced++; }];
		NSString *tok = [Mail2OAuth accessTokenForAccount: g error: &err];
		wait_for(^BOOL { return announced > 0; }, 5);
		CHECK([tok isEqualToString: @"pw1"] && [[g refreshToken] hasPrefix: @"rt-rotated-"] && announced == 1,
		    "refresh: access token, new refresh token kept and announced (%@, %@)", tok, err);
		int st = 0;
		int before = [[Mail2PostForm(@"http://127.0.0.1:3080/last", [NSDictionary dictionary], &st, &err) objectForKey: @"refreshes"] intValue];
		[Mail2OAuth accessTokenForAccount: g error: &err];
		int after = [[Mail2PostForm(@"http://127.0.0.1:3080/last", [NSDictionary dictionary], &st, &err) objectForKey: @"refreshes"] intValue];
		CHECK(after == before, "the access token is cached until it expires");
		[[NSNotificationCenter defaultCenter] removeObserver: obs];

		/* IMAP and SMTP with XOAUTH2 (GreenMail takes the password as the token) */
		Mail2IMAP *oi = [[Mail2IMAP alloc] initWithAccount: g];
		err = nil;
		CHECK([oi connect: &err] && [oi select: @"INBOX" uidValidity: NULL uidNext: NULL exists: NULL error: &err],
		    "IMAP AUTHENTICATE XOAUTH2 (%@)", err);
		[oi release];
		err = nil;
		NSData *om = Mail2BuildMessage(@"test1@localhost", [NSArray arrayWithObject: @"test2@localhost"], nil, @"via xoauth2", @"x", nil, nil);
		CHECK(Mail2SendMessage(g, om, [NSArray arrayWithObject: @"test2@localhost"], &err), "SMTP AUTH XOAUTH2, Google's form (%@)", err);
		Mail2Account *ms = account(@"test1@localhost", nil);
		[ms setAuth: Mail2AuthMicrosoft];
		[ms setRefreshToken: @"rt-ms0"];
		[Mail2OAuth forgetAccessTokenForAccount: ms];
		err = nil;
		CHECK(Mail2SendMessage(ms, om, [NSArray arrayWithObject: @"test2@localhost"], &err), "SMTP AUTH XOAUTH2 for a Microsoft account (%@)", err);

		/* a revoked refresh token: a clear error, no crash */
		Mail2Account *bad = account(@"test1@localhost", nil);
		[bad setAuth: Mail2AuthGoogle];
		[bad setRefreshToken: @"bad"];
		[Mail2OAuth forgetAccessTokenForAccount: bad];
		err = nil;
		Mail2IMAP *bi = [[Mail2IMAP alloc] initWithAccount: bad];
		CHECK(![bi connect: &err] && [err rangeOfString: @"revoked"].location != NSNotFound, "revoked: %@", err);
		[bi release];

		/* Microsoft's device flow: the code shown, pending once, then the tokens (a chunked answer) */
		Mail2Account *dev = account(@"dev@localhost", nil);
		[dev setAuth: Mail2AuthMicrosoft];
		__block NSString *shown = nil;
		int cpa[2];
		pipe(cpa);
		int cp0 = cpa[0], cp1 = cpa[1];
		__block BOOL done = NO, ok = NO;
		__block NSString *derr = nil;
		dispatch_async(dispatch_get_global_queue(0, 0), ^{
			NSString *e2 = nil;
			ok = [Mail2OAuth signIn: dev prompt: ^(NSString *msg, NSString *url, NSString *code) { shown = [code retain]; }
			    cancelFd: cp0 error: &e2];
			derr = [e2 retain];
			done = YES;
		});
		wait_for(^BOOL { return done; }, 20);
		CHECK(ok && [shown isEqualToString: @"ABCD-1234"] && [[dev refreshToken] isEqualToString: @"rt-ms"],
		    "device flow: code %@ shown, signed in (%@)", shown, derr);

		/* Google's flow: the test plays the browser, coming back to the listener with the code */
		Mail2Account *goo = account(@"goo@localhost", nil);
		[goo setAuth: Mail2AuthGoogle];
		__block NSString *authURL = nil;
		done = NO; ok = NO;
		dispatch_async(dispatch_get_global_queue(0, 0), ^{
			NSString *e2 = nil;
			ok = [Mail2OAuth signIn: goo prompt: ^(NSString *msg, NSString *url, NSString *code) {
				authURL = [url retain];
				NSURLComponents *uc = [NSURLComponents componentsWithString: url];
				NSString *redirect = nil, *stateV = nil;
				for (NSURLQueryItem *qi in [uc queryItems]) {
					if ([[qi name] isEqualToString: @"redirect_uri"]) redirect = [qi value];
					if ([[qi name] isEqualToString: @"state"]) stateV = [qi value];
				}
				NSString *back = [NSString stringWithFormat: @"%@/?state=%@&code=good-code", redirect, stateV];
				dispatch_async(dispatch_get_global_queue(0, 0), ^{
					[NSData dataWithContentsOfURL: [NSURL URLWithString: @"/favicon.ico" relativeToURL: [NSURL URLWithString: redirect]]];
					[NSData dataWithContentsOfURL: [NSURL URLWithString: back]];
				});
			} cancelFd: cp0 error: &e2];
			derr = [e2 retain];
			done = YES;
		});
		wait_for(^BOOL { return done; }, 20);
		NSDictionary *last = Mail2PostForm(@"http://127.0.0.1:3080/last", [NSDictionary dictionary], &st, &err);
		NSString *verifier = [last objectForKey: @"verifier"];
		NSString *challenge = nil;
		for (NSURLQueryItem *qi in [[NSURLComponents componentsWithString: authURL] queryItems])
			if ([[qi name] isEqualToString: @"code_challenge"]) challenge = [qi value];
		unsigned char h[32];
		mbedtls_sha256((const unsigned char *)[verifier UTF8String], strlen([verifier UTF8String]), h, 0);
		NSString *expect = [[[[[NSData dataWithBytes: h length: 32] base64EncodedStringWithOptions: 0]
		    stringByReplacingOccurrencesOfString: @"+" withString: @"-"] stringByReplacingOccurrencesOfString: @"/" withString: @"_"]
		    stringByReplacingOccurrencesOfString: @"=" withString: @""];
		CHECK(ok && [[goo refreshToken] isEqualToString: @"rt-google"], "browser flow: back on 127.0.0.1 with the code (%@)", derr);
		CHECK([challenge isEqualToString: expect], "PKCE: the challenge is S256 of the verifier sent with the code");

		/* Cancel ends a sign-in that is waiting */
		Mail2Account *can = account(@"can@localhost", nil);
		[can setAuth: Mail2AuthGoogle];
		done = NO; ok = YES;
		dispatch_async(dispatch_get_global_queue(0, 0), ^{
			NSString *e2 = nil;
			ok = [Mail2OAuth signIn: can prompt: ^(NSString *msg, NSString *url, NSString *code) {
				(void)write(cp1, "c", 1);
			} cancelFd: cp0 error: &e2];
			derr = [e2 retain];
			done = YES;
		});
		wait_for(^BOOL { return done; }, 10);
		CHECK(done && !ok && [derr isEqualToString: @"Cancelled."], "Cancel stops the wait (%@)", derr);
	}

	printf("Addresses and signatures\n");
	{
		NSArray *m1 = [store addressesMatching: @"tes" limit: 5];
		CHECK([m1 count] > 0 && [[[m1 objectAtIndex: 0] lowercaseString] rangeOfString: @"test"].location != NSNotFound,
		    "people from the index by address: %@", m1);
		NSArray *m2 = [store addressesMatching: @"zz-nobody" limit: 5];
		CHECK([m2 count] == 0, "no match, nothing offered");
		CHECK([[store addressesMatching: @"%_" limit: 5] count] == 0, "LIKE wildcards in the text are taken literally");
		Mail2Account *sa = account(@"sig@localhost", @"x");
		[sa setSignature: @"Jane\nSent from a Raspberry Pi"];
		[Mail2Account saveAccounts: [NSArray arrayWithObject: sa]];
		NSArray *back = [Mail2Account loadAccounts];
		CHECK([back count] == 1 && [[[back objectAtIndex: 0] signature] isEqualToString: @"Jane\nSent from a Raspberry Pi"],
		    "the signature is saved with the account");
	}

	printf("Remote content\n");
	CHECK(Mail2HTMLHasRemoteContent(@"<p>Hi</p><img src=\"https://t.example.com/open.gif\" width=1>"), "a tracking pixel");
	CHECK(Mail2HTMLHasRemoteContent(@"<div style=\"background: URL( 'http://x/y.png' )\">"), "a CSS background");
	CHECK(Mail2HTMLHasRemoteContent(@"<img SRC = //cdn.example.com/a.png>"), "protocol-relative, odd spacing and case");
	CHECK(!Mail2HTMLHasRemoteContent(@"<img src=\"cid:part1@x\"><a href=\"https://example.com\">a link</a>"),
	    "inline images and links are not remote content");

	printf("Folders and moving\n");
	{
		NSString *names[] = { @"Reçus", @"Projects & Plans", @"日本語", @"a/b" };
		unsigned k;
		BOOL round = YES;
		for (k = 0; k < 4; k++)
			round = round && [Mail2DecodeMailboxName([Mail2EncodeMailboxName(names[k]) UTF8String]) isEqualToString: names[k]];
		CHECK(round && [Mail2EncodeMailboxName(@"Reçus") isEqualToString: @"Re&AOc-us"] &&
		    [Mail2EncodeMailboxName(@"A&B") isEqualToString: @"A&-B"], "mailbox names to modified UTF-7 and back (%@)",
		    Mail2EncodeMailboxName(@"日本語"));
		Mail2Session *fs = [[Mail2Session alloc] initWithAccount: a1];
		[fs refreshMailboxes];
		wait_for(^BOOL { return ![fs isBusy]; }, 20);
		[fs createMailboxNamed: @"Reçus 2026"];
		wait_for(^BOOL { return ![fs isBusy]; }, 20);
		Mail2Mailbox *made = nil, *mb;
		NSEnumerator *me = [[store mailboxesForAccount: @"test1@localhost"] objectEnumerator];
		while ((mb = [me nextObject]) != nil)
			if ([[mb displayName] isEqualToString: @"Reçus 2026"])
				made = mb;
		CHECK(made != nil, "New Mailbox: “Reçus 2026” on the server (%@) %@", [made name], [fs lastError] ? [fs lastError] : @"");
		Mail2Mailbox *ib = [fs mailboxWithSpecial: @"inbox"];
		[fs syncMailbox: ib];
		wait_for(^BOOL { return ![fs isBusy]; }, 20);
		NSArray *two = [store messagesInMailbox: [ib mbid] limit: 2];
		NSUInteger inboxBefore = [[store messagesInMailbox: [ib mbid] limit: 1000] count];
		if (made != nil && [two count] == 2) {
			[fs moveMessages: two toMailbox: made];
			CHECK([[store messagesInMailbox: [ib mbid] limit: 1000] count] == inboxBefore - 2, "Move To: gone from the Inbox at once");
			wait_for(^BOOL { return ![fs isBusy]; }, 20);
			CHECK([[store messagesInMailbox: [made mbid] limit: 100] count] == 2, "and in the folder after its sync (%@)",
			    [fs lastError] ? [fs lastError] : @"");
		}
		[fs renameMailbox: made to: @"Archive 2026"];
		wait_for(^BOOL { return ![fs isBusy]; }, 20);
		Mail2Mailbox *renamed = nil;
		me = [[store mailboxesForAccount: @"test1@localhost"] objectEnumerator];
		while ((mb = [me nextObject]) != nil)
			if ([[mb displayName] isEqualToString: @"Archive 2026"])
				renamed = mb;
		CHECK(renamed != nil && [store mailboxWithID: [made mbid]] == nil, "Rename Mailbox (%@)", [fs lastError] ? [fs lastError] : @"");
		[fs deleteMailbox: renamed];
		wait_for(^BOOL { return ![fs isBusy]; }, 20);
		BOOL gone = YES;
		me = [[store mailboxesForAccount: @"test1@localhost"] objectEnumerator];
		while ((mb = [me nextObject]) != nil)
			if ([[mb displayName] isEqualToString: @"Archive 2026"])
				gone = NO;
		CHECK(renamed != nil && gone, "Delete Mailbox");
		CHECK([fs mailboxWithSpecial: @"junk"] == nil, "(GreenMail has no Junk mailbox)");
		NSArray *one = [store messagesInMailbox: [ib mbid] limit: 1];
		NSUInteger have = [[store messagesInMailbox: [ib mbid] limit: 1000] count];
		[fs moveMessages: one toSpecial: @"junk"];
		wait_for(^BOOL { return ![fs isBusy]; }, 20);
		CHECK([[fs lastError] rangeOfString: @"no Junk"].location != NSNotFound &&
		    [[store messagesInMailbox: [ib mbid] limit: 1000] count] == have,
		    "Junk without a Junk mailbox says so and keeps the message: %@", [fs lastError]);
		[fs release];
	}

	printf("Rules\n");
	{
		Mail2MessageInfo *probe = [[[Mail2MessageInfo alloc] init] autorelease];
		probe->fromName = [@"Ann Éxample" retain];
		probe->fromAddr = [@"ann@example.com" retain];
		probe->subject = [@"Weekly NEWSLETTER" retain];
		Mail2Rule *r1 = [Mail2Rule ruleWithPlist: [NSDictionary dictionaryWithObjectsAndKeys: @"newsletter", @"Contains",
		    [NSNumber numberWithInt: Mail2RuleSubject], @"Field", [NSNumber numberWithInt: Mail2RuleMarkRead], @"Action", nil]];
		Mail2Rule *r2 = [Mail2Rule ruleWithPlist: [NSDictionary dictionaryWithObjectsAndKeys: @"ann exa", @"Contains",
		    [NSNumber numberWithInt: Mail2RuleFrom], @"Field", nil]];
		Mail2Rule *r3 = [Mail2Rule ruleWithPlist: [NSDictionary dictionaryWithObjectsAndKeys: @"newsletter", @"Contains",
		    @"other@localhost", @"Account", nil]];
		CHECK([r1 matches: probe account: @"test1@localhost"] && [r2 matches: probe account: @"test1@localhost"] &&
		    ![r3 matches: probe account: @"test1@localhost"], "matching: case and accents ignored, per account");

		/* a folder, rules for it, then new mail through a sync */
		Mail2Session *rs = [[Mail2Session alloc] initWithAccount: a1];
		[rs refreshMailboxes];
		wait_for(^BOOL { return ![rs isBusy]; }, 20);
		[rs createMailboxNamed: @"Lists"];
		wait_for(^BOOL { return ![rs isBusy]; }, 20);
		Mail2Mailbox *lists = nil, *mb;
		NSEnumerator *me = [[store mailboxesForAccount: @"test1@localhost"] objectEnumerator];
		while ((mb = [me nextObject]) != nil)
			if ([[mb displayName] isEqualToString: @"Lists"])
				lists = mb;
		NSArray *ruleList = [NSArray arrayWithObjects:
		    [Mail2Rule ruleWithPlist: [NSDictionary dictionaryWithObjectsAndKeys: @"digest", @"Contains",
		        [NSNumber numberWithInt: Mail2RuleSubject], @"Field", [NSNumber numberWithInt: Mail2RuleMove], @"Action",
		        [lists name], @"Mailbox", @"test1@localhost", @"Account", nil]],
		    [Mail2Rule ruleWithPlist: [NSDictionary dictionaryWithObjectsAndKeys: @"fyi", @"Contains",
		        [NSNumber numberWithInt: Mail2RuleAny], @"Field", [NSNumber numberWithInt: Mail2RuleMarkRead], @"Action", nil]], nil];
		CHECK([Mail2Rule saveRules: ruleList] && [[Mail2Rule loadRules] count] == 2, "rules saved and read back");
		Mail2Mailbox *ib = [rs mailboxWithSpecial: @"inbox"];
		[rs syncMailbox: ib];
		wait_for(^BOOL { return ![rs isBusy]; }, 20);
		NSString *subj[] = { @"Daily digest #12", @"FYI: the plan" };
		unsigned k;
		for (k = 0; k < 2; k++) {
			NSData *r = Mail2BuildMessage(@"test2@localhost", [NSArray arrayWithObject: @"test1@localhost"], nil, subj[k], @"x", nil, nil);
			Mail2SendMessage(a2, r, [NSArray arrayWithObject: @"test1@localhost"], &err);
		}
		BOOL done = wait_for(^BOOL {
			[rs syncMailbox: ib];
			wait_for(^BOOL { return ![rs isBusy]; }, 10);
			NSArray *in = [store searchMailbox: [ib mbid] text: @"FYI" alsoUids: nil limit: 5];
			return [in count] == 1;
		}, 30);
		NSArray *fyi = [store searchMailbox: [ib mbid] text: @"FYI" alsoUids: nil limit: 5];
		CHECK(done && [fyi count] == 1 && ![[fyi objectAtIndex: 0] isUnread], "new mail: “FYI” marked read by a rule");
		CHECK([[store searchMailbox: [ib mbid] text: @"digest" alsoUids: nil limit: 5] count] == 0, "“digest” left the Inbox");
		[rs syncMailbox: lists];
		wait_for(^BOOL { return ![rs isBusy]; }, 20);
		CHECK([[store searchMailbox: [lists mbid] text: @"digest" alsoUids: nil limit: 5] count] == 1, "and is in Lists");
		[Mail2Rule saveRules: [NSArray array]];
		[rs release];
	}

	printf("Flagged, mailto, unsubscribe, undo\n");
	{
		Mail2Session *us = [[Mail2Session alloc] initWithAccount: a1];
		[us refreshMailboxes];
		wait_for(^BOOL { return ![us isBusy]; }, 20);
		Mail2Mailbox *ib = [us mailboxWithSpecial: @"inbox"], *trash = [us mailboxWithSpecial: @"trash"];
		[us syncMailbox: ib];
		wait_for(^BOOL { return ![us isBusy]; }, 20);
		NSArray *two = [store messagesInMailbox: [ib mbid] limit: 2];
		[us setFlag: Mail2FlagFlagged on: YES forMessages: two];
		wait_for(^BOOL { return ![us isBusy]; }, 20);
		CHECK([store flaggedCount] >= 2 && [[store messagesInMailbox: Mail2FlaggedID limit: 100] count] == (NSUInteger)[store flaggedCount],
		    "Flagged: every flagged message (%d)", [store flaggedCount]);

		NSDictionary *mt = Mail2ParseMailto(@"mailto:list@example.com?subject=unsubscribe%20me&body=please&cc=a@b.c");
		CHECK([[mt objectForKey: @"To"] isEqualToString: @"list@example.com"] && [[mt objectForKey: @"Subject"] isEqualToString: @"unsubscribe me"] &&
		    [[mt objectForKey: @"Body"] isEqualToString: @"please"] && [[mt objectForKey: @"Cc"] isEqualToString: @"a@b.c"], "mailto: with a query");

		const char *lu = "From: news@example.com\r\nTo: test1@localhost\r\nSubject: News\r\nMessage-ID: <n1@example.com>\r\n"
		    "List-Unsubscribe: <mailto:leave@example.com?subject=leave>, <https://example.com/u/123>\r\n"
		    "List-Unsubscribe-Post: List-Unsubscribe=One-Click\r\n\r\nhello\r\n";
		Mail2ParsedMessage *pu = [Mail2ParsedMessage parseData: [NSData dataWithBytes: lu length: strlen(lu)] preferPlainText: YES];
		CHECK([[pu unsubscribeURL] isEqualToString: @"https://example.com/u/123"] &&
		    [[pu unsubscribeMailto] isEqualToString: @"mailto:leave@example.com?subject=leave"] && [pu unsubscribeOneClick],
		    "List-Unsubscribe: https, mailto, one-click");
		int st = 0;
		NSString *perr = nil;
		NSDictionary *pr = Mail2PostForm(@"http://127.0.0.1:3080/last", [NSDictionary dictionaryWithObject: @"One-Click" forKey: @"List-Unsubscribe"], &st, &perr);
		CHECK(pr != nil && st == 200, "a form POST (as one-click unsubscribe sends) answered %d", st);

		/* undo of a delete: by Message-ID from the Trash back to the Inbox */
		NSArray *one = [store messagesInMailbox: [ib mbid] limit: 1];
		NSString *mid = [[one objectAtIndex: 0] messageId];
		NSUInteger before = [[store messagesInMailbox: [ib mbid] limit: 1000] count];
		[us moveMessages: one toMailbox: trash];
		wait_for(^BOOL { return ![us isBusy]; }, 20);
		CHECK([[store messagesInMailbox: [ib mbid] limit: 1000] count] == before - 1, "deleted to the Trash");
		[us moveBackMessageIDs: [NSArray arrayWithObject: mid] from: trash to: ib];
		wait_for(^BOOL { return ![us isBusy]; }, 20);
		NSArray *back = [store messagesInMailbox: [ib mbid] limit: 1000];
		BOOL found = NO;
		NSEnumerator *be = [back objectEnumerator];
		Mail2MessageInfo *bm;
		while ((bm = [be nextObject]) != nil)
			if ([[bm messageId] isEqualToString: mid])
				found = YES;
		CHECK(found && [back count] == before, "Undo: back in the Inbox (%@)", [us lastError] ? [us lastError] : @"");
		[us release];
	}

	printf("Rich text\n");
	{
		NSFont *base = [NSFont systemFontOfSize: 13];
		NSFont *bold = [[NSFontManager sharedFontManager] convertFont: base toHaveTrait: NSBoldFontMask];
		NSMutableAttributedString *rt = [[[NSMutableAttributedString alloc] initWithString:
		    @"Hello <world> & bold\n• one\n• two\n> quoted\n>> deeper\nback" attributes:
		    [NSDictionary dictionaryWithObject: base forKey: NSFontAttributeName]] autorelease];
		[rt addAttribute: NSFontAttributeName value: bold range: [[rt string] rangeOfString: @"bold"]];
		[rt addAttribute: NSLinkAttributeName value: @"https://example.com/?a=1&b=2" range: [[rt string] rangeOfString: @"world"]];
		NSImage *img = [[[NSImage alloc] initWithSize: NSMakeSize(4, 4)] autorelease];
		[img lockFocus]; [[NSColor redColor] set]; NSRectFill(NSMakeRect(0, 0, 4, 4)); [img unlockFocus];
		NSTextAttachment *ta = [[[NSTextAttachment alloc] init] autorelease];
		NSTextAttachmentCell *cell = [[[NSTextAttachmentCell alloc] initImageCell: img] autorelease];
		[ta setAttachmentCell: cell];
		[rt appendAttributedString: [NSAttributedString attributedStringWithAttachment: ta]];
		NSMutableArray *imgs = [NSMutableArray array];
		NSString *plainOut = nil;
		NSString *html = Mail2HTMLFromRichText(rt, imgs, &plainOut);
		CHECK([html rangeOfString: @"&lt;<a href=\"https://example.com/?a=1&amp;b=2\">world</a>&gt; &amp; <b>bold</b>"].location != NSNotFound,
		    "escaping, a link and bold");
		CHECK([html rangeOfString: @"<ul>\n<li>one</li>\n<li>two</li>\n</ul>"].location != NSNotFound, "a bulleted list");
		CHECK([html rangeOfString: @"<blockquote"].location != NSNotFound &&
		    [[html componentsSeparatedByString: @"<blockquote"] count] == 3 &&
		    [[html componentsSeparatedByString: @"</blockquote>"] count] == 3, "two quote levels, closed");
		NSString *cidRef = [imgs count] ? [@"cid:" stringByAppendingString: [[imgs objectAtIndex: 0] contentId]] : @"-";
		CHECK([imgs count] == 1 && [[[imgs objectAtIndex: 0] mimeType] isEqualToString: @"image/png"] &&
		    [html rangeOfString: cidRef].location != NSNotFound, "a pasted picture as an inline PNG");
		CHECK([plainOut hasSuffix: @"back"] && Mail2RichTextHasFormatting(rt, base), "the plain alternative; formatting seen");
		Mail2Attachment *fileAtt = [[[Mail2Attachment alloc] initWithName: @"a.txt" type: nil
		    data: [@"file" dataUsingEncoding: NSUTF8StringEncoding]] autorelease];
		NSData *raw = Mail2BuildMessageRich(@"test1@localhost", [NSArray arrayWithObject: @"test2@localhost"], nil, nil, @"rich",
		    plainOut, html, imgs, nil, nil, [NSArray arrayWithObject: fileAtt], nil);
		NSString *rawS = [[[NSString alloc] initWithData: raw encoding: NSISOLatin1StringEncoding] autorelease];
		CHECK([rawS rangeOfString: @"multipart/mixed"].location != NSNotFound && [rawS rangeOfString: @"multipart/alternative"].location != NSNotFound &&
		    [rawS rangeOfString: @"multipart/related"].location != NSNotFound && [rawS rangeOfString: @"Content-ID:"].location != NSNotFound,
		    "MIME: mixed( alternative( plain, related( html, picture ) ), file )");
		Mail2ParsedMessage *rp = [Mail2ParsedMessage parseData: raw preferPlainText: NO];
		CHECK([[rp htmlSource] rangeOfString: @"<b>bold</b>"].location != NSNotFound && [[rp inlineParts] count] == 1 &&
		    [[rp attachments] count] == 1, "read back: the HTML, its picture inline, the file attached");
		Mail2ParsedMessage *rp2 = [Mail2ParsedMessage parseData: raw preferPlainText: YES];
		CHECK([[rp2 body] hasPrefix: @"Hello <world> & bold"], "and the plain part for plain readers");
	}

	printf("Outbox\n");
	{
		Mail2Session *os1 = [[Mail2Session alloc] initWithAccount: a2];
		Mail2Account *broken = account(@"broken@localhost", @"x");
		[broken setSmtpPort: 1];	/* nothing listens there */
		Mail2Session *osb = [[Mail2Session alloc] initWithAccount: broken];
		Mail2Outbox *ob = [Mail2Outbox shared];
		[ob setSessionLookup: ^id (NSString *ident) {
			return [ident isEqualToString: @"broken@localhost"] ? osb : os1;
		}];
		NSData *m1 = Mail2BuildMessage(@"test2@localhost", [NSArray arrayWithObject: @"test1@localhost"], nil, @"outbox later", @"x", nil, nil);
		NSString *later = [ob add: m1 details: [NSDictionary dictionaryWithObjectsAndKeys: @"test2@localhost", @"Account",
		    [NSArray arrayWithObject: @"test1@localhost"], @"Recipients", [NSDate dateWithTimeIntervalSinceNow: 3600], @"SendAt",
		    [NSNumber numberWithBool: YES], @"Undoable", @"outbox later", @"Subject", nil]];
		NSString *path = [[Mail2SupportDirectory() stringByAppendingPathComponent: @"Outbox"] stringByAppendingPathComponent:
		    [later stringByAppendingPathExtension: @"eml"]];
		CHECK(later != nil && [[NSFileManager defaultManager] fileExistsAtPath: path], "queued on disk for later");
		NSDictionary *back = [ob takeBack: later];
		CHECK(back != nil && [[back objectForKey: @"Message"] isEqualToData: m1] && ![[NSFileManager defaultManager] fileExistsAtPath: path] &&
		    [[ob items] count] == 0, "Undo Send takes it back, files and all");
		NSData *m2 = Mail2BuildMessage(@"test2@localhost", [NSArray arrayWithObject: @"test1@localhost"], nil, @"outbox now zebu", @"x", nil, nil);
		[ob add: m2 details: [NSDictionary dictionaryWithObjectsAndKeys: @"test2@localhost", @"Account",
		    [NSArray arrayWithObject: @"test1@localhost"], @"Recipients", nil]];
		BOOL gone = wait_for(^BOOL { return [[ob items] count] == 0; }, 20);
		BOOL arrived = wait_for(^BOOL {
			NSString *e3 = nil;
			[imap select: @"INBOX" uidValidity: NULL uidNext: NULL exists: NULL error: &e3];
			return [[imap uidsMatchingText: @"zebu" error: &e3] count] == 1;
		}, 20);
		CHECK(gone && arrived, "due: sent, and gone from the Outbox");
		NSData *m3 = Mail2BuildMessage(@"broken@localhost", [NSArray arrayWithObject: @"test1@localhost"], nil, @"no network", @"x", nil, nil);
		NSString *bad = [ob add: m3 details: [NSDictionary dictionaryWithObjectsAndKeys: @"broken@localhost", @"Account",
		    [NSArray arrayWithObject: @"test1@localhost"], @"Recipients", nil]];
		BOOL failed = wait_for(^BOOL { return [[ob itemFor: bad] objectForKey: @"Error"] != nil; }, 30);
		NSDictionary *bi = [ob itemFor: bad];
		CHECK(failed && [[bi objectForKey: @"Attempts"] intValue] == 1 && [[bi objectForKey: @"NextTry"] timeIntervalSinceNow] > 20,
		    "a failure stays, with its reason, to be tried again: %@", [bi objectForKey: @"Error"]);
		[ob takeBack: bad];
		[os1 release];
		[osb release];
	}

	printf("Spelling (Hunspell, en_US)\n");
	{
		NSString *dir = [[[NSString stringWithUTF8String: __FILE__] stringByDeletingLastPathComponent]
		    stringByAppendingPathComponent: @"../dict"];
		Mail2Spell *sp = [[[Mail2Spell alloc] initWithAffix: [dir stringByAppendingPathComponent: @"en_US.aff"]
		    dictionary: [dir stringByAppendingPathComponent: @"en_US.dic"]] autorelease];
		CHECK(sp != nil && [sp isCorrect: @"receive"] && ![sp isCorrect: @"recieve"] && [sp isCorrect: @"don't"] &&
		    [sp isCorrect: @"don’t"], "words, and both apostrophes");
		NSArray *sugs = [sp suggestionsFor: @"recieve"];
		CHECK([sugs containsObject: @"receive"], "suggestions: %@", sugs);
		NSString *text = @"Teh plan is ready, see https://exmaple.com or mail ann@exmaple.com.\n> Quoted txet stays.\nNASA and 3rd and Mail2 are fine; wrold";
		NSArray *bad = [sp misspellingsIn: text];
		NSMutableArray *words = [NSMutableArray array];
		NSEnumerator *e = [bad objectEnumerator];
		NSValue *v;
		while ((v = [e nextObject]) != nil)
			[words addObject: [text substringWithRange: [v rangeValue]]];
		NSArray *expectWords = [NSArray arrayWithObjects: @"Teh", @"wrold", nil];
		CHECK([words isEqualToArray: expectWords],
		    "misspellings, not links, addresses, quotes, acronyms or words with digits: %@", words);
		[sp learn: @"Wrold"];
		NSString *wordsFile = [NSString stringWithContentsOfFile: [Mail2SupportDirectory() stringByAppendingPathComponent: @"Words.txt"]
		    encoding: NSUTF8StringEncoding error: NULL];
		CHECK([sp isCorrect: @"Wrold"] && [wordsFile rangeOfString: @"Wrold"].location != NSNotFound, "Learn Spelling keeps the word");
	}

	printf("\n%d checks, %d failed\n", checks, failures);
	[pool release];
	return failures ? 1 : 0;
}
