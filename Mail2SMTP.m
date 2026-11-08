/* Mail2SMTP: sending through libetpan's mailsmtp (see Mail2SMTP.h).
 *
 * libetpan's SMTP authentication goes through Cyrus SASL, which this system does not have; without it
 * mailesmtp_auth_sasl() returns NOT_IMPLEMENTED. AUTH PLAIN and AUTH LOGIN (RFC 4954, RFC 4616) are two lines each,
 * sent here on the session's own stream, which by then is TLS. */
#import "Mail2SMTP.h"
#import "Mail2Util.h"
#import "Mail2OAuth.h"
#include "Mail2TLS.h"
#include <libetpan/libetpan-config.h>
#include <libetpan/mailsmtp.h>
#include <libetpan/mailstream_helper.h>
#include <stdlib.h>
#include <string.h>

#define TIMEOUT 60

static NSString *
smtp_error(mailsmtp *s, int r, NSString *what)
{
	if (s && s->response && *s->response)
		return [NSString stringWithFormat: @"%@: %s", what, s->response];
	return [NSString stringWithFormat: @"%@: %s.", what, mailsmtp_strerror(r)];
}

static void
logger(mailsmtp *s, int type, const char *str, size_t size, void *ctx)
{
	switch (type) {
	case MAILSTREAM_LOG_TYPE_DATA_RECEIVED: fprintf(stderr, "smtp S: %.*s", (int)size, str); break;
	case MAILSTREAM_LOG_TYPE_DATA_SENT: fprintf(stderr, "smtp C: %.*s", (int)(size > 300 ? 300 : size), str); break;
	case MAILSTREAM_LOG_TYPE_DATA_SENT_PRIVATE: fprintf(stderr, "smtp C: <private data>\n"); break;
	}
}

#define b64 Mail2Base64

/* sends a line (not logged when private) and reads the reply; its code, -1 on a stream error. The last reply line is
 * left in `reply`. */
static int
command(mailsmtp *s, NSString *line, BOOL private, NSString **reply)
{
	const char *c = [[line stringByAppendingString: @"\r\n"] UTF8String];
	int w;
	/* the session's stream logger would print the line as sent data: off while a credential goes out */
	if (Mail2Debug())
		mailsmtp_set_logger(s, NULL, NULL);
	if (Mail2Debug())
		fprintf(stderr, "smtp C: %s\n", private ? "<private data>" : [line UTF8String]);
	w = mailstream_write(s->stream, c, strlen(c)) < 0 || mailstream_flush(s->stream) < 0;
	if (Mail2Debug())
		mailsmtp_set_logger(s, logger, NULL);
	if (w)
		return -1;
	for (;;) {
		char *l = mailstream_read_line_remove_eol(s->stream, s->line_buffer);
		if (l == NULL)
			return -1;
		if (Mail2Debug())
			fprintf(stderr, "smtp S: %s\n", l);
		if (strlen(l) < 3)
			return -1;
		if (l[3] == '-')
			continue;
		*reply = [NSString stringWithUTF8String: l];
		return atoi(l);
	}
}

static BOOL
authenticate(mailsmtp *s, Mail2Account *a, NSString **err)
{
	NSString *user = [a smtpUser], *pass = [a password] ? [a password] : @"", *reply = nil;
	int code;
	if ((s->auth & MAILSMTP_AUTH_PLAIN) || !(s->auth & MAILSMTP_AUTH_LOGIN)) {
		NSMutableData *d = [NSMutableData data];
		[d appendBytes: "" length: 1];
		[d appendData: [user dataUsingEncoding: NSUTF8StringEncoding]];
		[d appendBytes: "" length: 1];
		[d appendData: [pass dataUsingEncoding: NSUTF8StringEncoding]];
		code = command(s, [@"AUTH PLAIN " stringByAppendingString: b64(d)], YES, &reply);
	} else {
		code = command(s, @"AUTH LOGIN", NO, &reply);
		if (code == 334)
			code = command(s, b64([user dataUsingEncoding: NSUTF8StringEncoding]), YES, &reply);
		if (code == 334)
			code = command(s, b64([pass dataUsingEncoding: NSUTF8StringEncoding]), YES, &reply);
	}
	if (code == 235)
		return YES;
	*err = code < 0 ? @"The connection to the outgoing server was lost while logging in."
	                : [NSString stringWithFormat: @"The outgoing server refused the login: %@", reply];
	return NO;
}

/* the address of the message's From header: the envelope sender (an alias sends as itself) */
static NSString *
header_from(NSData *raw)
{
	const char *p = [raw bytes];
	size_t n = [raw length];
	const char *end = memmem(p, n, "\r\n\r\n", 4);
	NSString *head = [[[NSString alloc] initWithBytes: p length: end ? (NSUInteger)(end - p) : MIN(n, (size_t)8192)
	    encoding: NSISOLatin1StringEncoding] autorelease];
	NSEnumerator *e = [[head componentsSeparatedByString: @"\r\n"] objectEnumerator];
	NSString *l, *from = nil;
	while ((l = [e nextObject]) != nil) {
		if (from != nil && ([l hasPrefix: @" "] || [l hasPrefix: @"\t"]))
			from = [from stringByAppendingString: l];
		else if (from != nil)
			break;
		else if ([[l lowercaseString] hasPrefix: @"from:"])
			from = [l substringFromIndex: 5];
	}
	NSString *addr = from ? Mail2AddressPart([from stringByTrimmingCharactersInSet: [NSCharacterSet whitespaceCharacterSet]]) : nil;
	return [addr rangeOfString: @"@"].location != NSNotFound ? addr : nil;
}

BOOL
Mail2SendMessage(Mail2Account *a, NSData *raw, NSArray *recipients, NSString **err)
{
	char e[256];
	mailsmtp *s;
	mailstream *st;
	int r;
	BOOL ok = NO;

	if ([[a smtpHost] length] == 0) {
		*err = @"No outgoing mail server is set for this account.";
		return NO;
	}
	st = mail2_connect([[a smtpHost] UTF8String], [a smtpPort], [a smtpSecurity] == Mail2SecurityTLS, TIMEOUT, e, sizeof(e));
	if (st == NULL) {
		*err = [NSString stringWithUTF8String: e];
		return NO;
	}
	s = mailsmtp_new(0, NULL);
	mailsmtp_set_timeout(s, TIMEOUT);
	if (Mail2Debug())
		mailsmtp_set_logger(s, logger, NULL);
	if ((r = mailsmtp_connect(s, st)) != MAILSMTP_NO_ERROR) {
		*err = smtp_error(s, r, [NSString stringWithFormat: @"Connecting to %@", [a smtpHost]]);
		goto out;
	}
	if ((r = mailesmtp_ehlo(s)) != MAILSMTP_NO_ERROR) {
		*err = smtp_error(s, r, @"EHLO");
		goto out;
	}
	if ([a smtpSecurity] == Mail2SecuritySTARTTLS) {
		if ((r = mailesmtp_starttls(s)) != MAILSMTP_NO_ERROR) {
			*err = smtp_error(s, r, @"STARTTLS");
			goto out;
		}
		if (mail2_starttls(s->stream, [[a smtpHost] UTF8String], e, sizeof(e)) != 0) {
			*err = [NSString stringWithUTF8String: e];
			goto out;
		}
		if ((r = mailesmtp_ehlo(s)) != MAILSMTP_NO_ERROR) {
			*err = smtp_error(s, r, @"EHLO");
			goto out;
		}
	}
	if ([a usesOAuth]) {
		/* XOAUTH2 with an access token; a refused one is renewed once */
		int attempt;
		for (attempt = 0; attempt < 2; attempt++) {
			NSString *tok = [Mail2OAuth accessTokenForAccount: a error: err];
			if (tok == nil)
				goto out;
			/* "AUTH XOAUTH2 <initial response>" for both: Exchange Online takes it too, as Thunderbird sends it
			 * (libetpan's two-step Outlook form is not accepted by every server) */
			r = mailsmtp_oauth2_authenticate(s, [[a smtpUser] UTF8String], [tok UTF8String]);
			if (r == MAILSMTP_NO_ERROR)
				break;
			[Mail2OAuth forgetAccessTokenForAccount: a];
			if (r == MAILSMTP_ERROR_STREAM) {
				*err = @"The connection to the outgoing server was lost while logging in.";
				goto out;
			}
		}
		if (r != MAILSMTP_NO_ERROR) {
			*err = smtp_error(s, r, @"The outgoing server refused the sign-in");
			goto out;
		}
	} else if (s->auth != MAILSMTP_AUTH_NOT_CHECKED && s->auth != MAILSMTP_AUTH_CHECKED && !authenticate(s, a, err))
		goto out;

	clist *rcpts = esmtp_address_list_new();
	NSEnumerator *en = [recipients objectEnumerator];
	NSString *addr;
	while ((addr = [en nextObject]) != nil)
		esmtp_address_list_add(rcpts, (char *)[addr UTF8String], 0, NULL);
	NSString *envFrom = header_from(raw);
	r = mailesmtp_send(s, [(envFrom ? envFrom : [a email]) UTF8String], 0, NULL, rcpts, [raw bytes], [raw length]);
	esmtp_address_list_free(rcpts);
	if (r != MAILSMTP_NO_ERROR) {
		*err = smtp_error(s, r, @"Sending");
		goto out;
	}
	ok = YES;
	mailsmtp_quit(s);
out:
	mailsmtp_free(s);
	return ok;
}
