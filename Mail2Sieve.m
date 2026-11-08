/* Mail2Sieve: rules as Sieve over ManageSieve (see Mail2Sieve.h). */
#import "Mail2Sieve.h"
#import "Mail2Rules.h"
#import "Mail2OAuth.h"
#import "Mail2Util.h"
#include "Mail2TLS.h"
#include <libetpan/libetpan-config.h>
#include <libetpan/mailstream.h>
#include <libetpan/mailstream_helper.h>
#include <libetpan/mmapstring.h>

#define SIEVE_PORT 4190
#define TIMEOUT 30

static NSString *
sieve_string(NSString *s)
{
	NSString *e = [[s stringByReplacingOccurrencesOfString: @"\\" withString: @"\\\\"]
	    stringByReplacingOccurrencesOfString: @"\"" withString: @"\\\""];
	return [NSString stringWithFormat: @"\"%@\"", e];
}

NSString *
Mail2SieveScript(NSArray *rules, NSString *account, NSArray *blocked, NSString *trashName)
{
	NSMutableString *s = [NSMutableString stringWithString:
	    @"# Mail2's rules, put here by Mail2 (Mail2 > Rules > Put on Server). Changing them in Mail2 replaces this script.\n"
	    "require [\"fileinto\", \"imap4flags\"];\n\n"];
	NSString *trash = trashName ? Mail2DecodeMailboxName([trashName UTF8String]) : @"Trash";
	if ([blocked count]) {
		NSMutableArray *q = [NSMutableArray array];
		NSEnumerator *e = [blocked objectEnumerator];
		NSString *b;
		while ((b = [e nextObject]) != nil)
			[q addObject: sieve_string(b)];
		[s appendFormat: @"# blocked senders\nif address :is \"from\" [%@] {\n  fileinto %@;\n  stop;\n}\n\n",
		    [q componentsJoinedByString: @", "], sieve_string(trash)];
	}
	NSEnumerator *e = [rules objectEnumerator];
	Mail2Rule *r;
	while ((r = [e nextObject]) != nil) {
		if (!r->enabled || [r->text length] == 0 || (r->account != nil && ![r->account isEqualToString: account]))
			continue;
		NSString *t = sieve_string(r->text), *cond;
		switch (r->field) {
		case Mail2RuleFrom: cond = [NSString stringWithFormat: @"header :contains \"from\" %@", t]; break;
		case Mail2RuleTo: cond = [NSString stringWithFormat: @"header :contains [\"to\", \"cc\"] %@", t]; break;
		case Mail2RuleSubject: cond = [NSString stringWithFormat: @"header :contains \"subject\" %@", t]; break;
		default: cond = [NSString stringWithFormat: @"header :contains [\"from\", \"to\", \"cc\", \"subject\"] %@", t]; break;
		}
		NSString *act;
		switch (r->action) {
		case Mail2RuleMove:
			if (r->mailbox == nil)
				continue;
			act = [NSString stringWithFormat: @"fileinto %@;\n  stop;", sieve_string(Mail2DecodeMailboxName([r->mailbox UTF8String]))];
			break;
		case Mail2RuleMarkRead: act = @"addflag \"\\\\Seen\";"; break;
		case Mail2RuleFlag: act = @"addflag \"\\\\Flagged\";"; break;
		default: act = [NSString stringWithFormat: @"fileinto %@;\n  stop;", sieve_string(trash)]; break;
		}
		[s appendFormat: @"# %@\nif %@ {\n  %@\n}\n\n", [r summary], cond, act];
	}
	return s;
}

/* ---- ManageSieve ---- */

/* the lines of a response up to OK, NO or BYE; YES for OK. *last: that line. */
static BOOL
read_response(mailstream *st, MMAPString *buf, NSString **last, NSMutableArray *lines)
{
	for (;;) {
		char *l = mailstream_read_line_remove_eol(st, buf);
		if (l == NULL) {
			*last = @"The connection was closed.";
			return NO;
		}
		NSString *line = [NSString stringWithUTF8String: l];
		if (line == nil)
			line = @"";
		if (Mail2Debug())
			fprintf(stderr, "sieve S: %s\n", l);
		if ([line hasPrefix: @"OK"]) { *last = line; return YES; }
		if ([line hasPrefix: @"NO"] || [line hasPrefix: @"BYE"]) { *last = line; return NO; }
		[lines addObject: line];
	}
}

static BOOL
command(mailstream *st, NSString *cmd, BOOL private)
{
	if (Mail2Debug())
		fprintf(stderr, "sieve C: %s\n", private ? "<private data>" : [cmd UTF8String]);
	NSData *d = [[cmd stringByAppendingString: @"\r\n"] dataUsingEncoding: NSUTF8StringEncoding];
	return mailstream_write(st, [d bytes], [d length]) >= 0 && mailstream_flush(st) >= 0;
}

static BOOL
has_cap(NSArray *lines, NSString *cap)
{
	NSEnumerator *e = [lines objectEnumerator];
	NSString *l;
	while ((l = [e nextObject]) != nil)
		if ([[l uppercaseString] hasPrefix: [NSString stringWithFormat: @"\"%@\"", cap]])
			return YES;
	return NO;
}

static NSString *
sasl_list(NSArray *lines)
{
	NSEnumerator *e = [lines objectEnumerator];
	NSString *l;
	while ((l = [e nextObject]) != nil)
		if ([[l uppercaseString] hasPrefix: @"\"SASL\""])
			return [l uppercaseString];
	return @"";
}

BOOL
Mail2SieveUpload(Mail2Account *a, NSString *script, NSString **err)
{
	char e[256];
	NSString *host = [a imapHost];
	/* ManageSieve is STARTTLS on 4190; a server answering TLS straight away is rare */
	mailstream *st = mail2_connect([host UTF8String], SIEVE_PORT, NO, TIMEOUT, e, sizeof(e));
	if (st == NULL) {
		*err = [NSString stringWithFormat: @"%@ has no ManageSieve (port %d): %s", host, SIEVE_PORT, e];
		return NO;
	}
	mailstream_low_set_timeout(mailstream_get_low(st), TIMEOUT);
	MMAPString *buf = mmap_string_new("");
	NSMutableArray *caps = [NSMutableArray array];
	NSString *last = nil;
	BOOL ok = read_response(st, buf, &last, caps);
	if (ok && has_cap(caps, @"STARTTLS")) {
		[caps removeAllObjects];
		ok = command(st, @"STARTTLS", NO) && read_response(st, buf, &last, caps);
		if (ok && mail2_starttls(st, [host UTF8String], e, sizeof(e)) != 0) {
			last = [NSString stringWithUTF8String: e];
			ok = NO;
		}
		[caps removeAllObjects];
		if (ok)	/* the capabilities again, now over TLS */
			ok = read_response(st, buf, &last, caps);
	} else if (ok && [a imapSecurity] != Mail2SecurityNone) {	/* no STARTTLS: the password would go in clear */
		last = @"The server offers ManageSieve without TLS: Mail2 will not send the password that way.";
		ok = NO;
	}
	if (ok) {
		NSString *sasl = sasl_list(caps), *resp = nil;
		NSMutableData *pl = [NSMutableData data];
		NSString *user = [a imapUser];
		if ([a usesOAuth]) {
			NSString *tok = [Mail2OAuth accessTokenForAccount: a error: err];
			if (tok == nil)
				ok = NO;
			else
				resp = [NSString stringWithFormat: @"AUTHENTICATE \"XOAUTH2\" \"%@\"", Mail2Base64([[NSString stringWithFormat:
				    @"user=%@\001auth=Bearer %@\001\001", user, tok] dataUsingEncoding: NSUTF8StringEncoding])];
		} else if ([sasl rangeOfString: @"PLAIN"].location != NSNotFound) {
			[pl appendBytes: "" length: 1];
			[pl appendData: [user dataUsingEncoding: NSUTF8StringEncoding]];
			[pl appendBytes: "" length: 1];
			[pl appendData: [[a password] ? [a password] : @"" dataUsingEncoding: NSUTF8StringEncoding]];
			resp = [NSString stringWithFormat: @"AUTHENTICATE \"PLAIN\" \"%@\"", Mail2Base64(pl)];
		} else {
			last = @"The server's ManageSieve offers no login Mail2 knows (PLAIN).";
			ok = NO;
		}
		NSMutableArray *ignore = [NSMutableArray array];
		if (ok)
			ok = command(st, resp, YES) && read_response(st, buf, &last, ignore);
	}
	if (ok) {
		NSData *body = [script dataUsingEncoding: NSUTF8StringEncoding];
		NSMutableArray *ignore = [NSMutableArray array];
		/* a literal: {length+}, then the script */
		ok = command(st, [NSString stringWithFormat: @"PUTSCRIPT \"mail2\" {%lu+}", (unsigned long)[body length]], NO) &&
		    mailstream_write(st, [body bytes], [body length]) >= 0 && command(st, @"", NO) &&
		    read_response(st, buf, &last, ignore);
		if (ok)
			ok = command(st, @"SETACTIVE \"mail2\"", NO) && read_response(st, buf, &last, ignore);
		if (ok) {
			command(st, @"LOGOUT", NO);
			read_response(st, buf, &last, ignore);
		}
	}
	if (!ok && *err == nil)
		*err = [NSString stringWithFormat: @"%@ refused the rules: %@", host, last ? last : @"no answer"];
	mmap_string_free(buf);
	mailstream_close(st);
	return ok;
}
