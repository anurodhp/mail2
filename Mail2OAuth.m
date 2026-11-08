/* Mail2OAuth: OAuth 2.0 sign-in and tokens (see Mail2OAuth.h). */
#import "Mail2OAuth.h"
#import "Mail2Util.h"
#include "Mail2TLS.h"
#include <libetpan/libetpan-config.h>
#include <libetpan/mailstream.h>
#include <mbedtls/sha256.h>
#include <arpa/inet.h>
#include <errno.h>
#include <netinet/in.h>
#include <poll.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <unistd.h>

#define HTTP_TIMEOUT 30
#define SIGNIN_TIMEOUT 600	/* seconds the user has to finish signing in */

/* ---- configuration ---- */

static NSString *
setting(NSString *key, NSString *fallback)
{
	NSString *v = [[NSUserDefaults standardUserDefaults] stringForKey: key];
	return [v length] ? v : fallback;
}

#define GOOGLE_AUTH setting(@"Mail2GoogleAuthURL", @"https://accounts.google.com/o/oauth2/v2/auth")
#define GOOGLE_TOKEN setting(@"Mail2GoogleTokenURL", @"https://oauth2.googleapis.com/token")
#define GOOGLE_SCOPE @"https://mail.google.com/"
#define MS_DEVICE setting(@"Mail2MicrosoftDeviceURL", @"https://login.microsoftonline.com/common/oauth2/v2.0/devicecode")
#define MS_TOKEN setting(@"Mail2MicrosoftTokenURL", @"https://login.microsoftonline.com/common/oauth2/v2.0/token")
#define MS_SCOPE @"https://outlook.office.com/IMAP.AccessAsUser.All https://outlook.office.com/SMTP.Send offline_access"

static NSString *
client_id(Mail2Auth p)
{
	return setting(p == Mail2AuthGoogle ? @"Mail2GoogleClientID" : @"Mail2MicrosoftClientID", nil);
}

/* ---- HTTP ---- */

static NSString *
form_escape(NSString *s)
{
	NSMutableString *r = [NSMutableString string];
	const unsigned char *p = (const unsigned char *)[s UTF8String];
	for (; p && *p; p++) {
		if ((*p >= 'A' && *p <= 'Z') || (*p >= 'a' && *p <= 'z') || (*p >= '0' && *p <= '9') || strchr("-._~", *p))
			[r appendFormat: @"%c", *p];
		else
			[r appendFormat: @"%%%02X", *p];
	}
	return r;
}

static NSString *
form_encode(NSDictionary *form)
{
	NSMutableArray *parts = [NSMutableArray array];
	NSEnumerator *e = [[[form allKeys] sortedArrayUsingSelector: @selector(compare:)] objectEnumerator];
	NSString *k;
	while ((k = [e nextObject]) != nil)
		[parts addObject: [NSString stringWithFormat: @"%@=%@", form_escape(k), form_escape([form objectForKey: k])]];
	return [parts componentsJoinedByString: @"&"];
}

/* the body of a chunked response */
static NSData *
dechunk(NSData *d)
{
	NSMutableData *out = [NSMutableData data];
	const char *p = [d bytes], *end = p + [d length];
	while (p < end) {
		char *nl;
		unsigned long n = strtoul(p, &nl, 16);
		const char *line_end = memchr(p, '\n', end - p);
		if (line_end == NULL || n == 0)
			break;
		p = line_end + 1;
		if ((unsigned long)(end - p) < n)
			n = end - p;
		[out appendBytes: p length: n];
		p += n;
		if (p < end && *p == '\r') p++;
		if (p < end && *p == '\n') p++;
	}
	return out;
}

NSDictionary *
Mail2PostForm(NSString *url, NSDictionary *form, int *status, NSString **err)
{
	NSURL *u = [NSURL URLWithString: url];
	BOOL tls = [[[u scheme] lowercaseString] isEqualToString: @"https"];
	int port = [u port] ? [[u port] intValue] : (tls ? 443 : 80);
	NSString *path = [[u path] length] ? [u path] : @"/";
	char e[256];
	if ([u query])
		path = [NSString stringWithFormat: @"%@?%@", path, [u query]];
	*status = 0;
	if ([u host] == nil) {
		*err = [NSString stringWithFormat: @"Not a web address: %@", url];
		return nil;
	}
	mailstream *s = mail2_connect([[u host] UTF8String], port, tls, HTTP_TIMEOUT, e, sizeof(e));
	if (s == NULL) {
		*err = [NSString stringWithUTF8String: e];
		return nil;
	}
	mailstream_low_set_timeout(mailstream_get_low(s), HTTP_TIMEOUT);
	NSData *body = [form_encode(form) dataUsingEncoding: NSUTF8StringEncoding];
	NSString *head = [NSString stringWithFormat: @"POST %@ HTTP/1.1\r\nHost: %@\r\nUser-Agent: Mail2/0.3\r\n"
	    "Accept: application/json\r\nContent-Type: application/x-www-form-urlencoded\r\nContent-Length: %lu\r\n"
	    "Connection: close\r\n\r\n", path, [u host], (unsigned long)[body length]];
	NSMutableData *req = [NSMutableData dataWithData: [head dataUsingEncoding: NSUTF8StringEncoding]];
	[req appendData: body];
	/* the form carries secrets: never in the debug log (the stream has no logger; nothing else prints it) */
	if (mailstream_write(s, [req bytes], [req length]) < 0 || mailstream_flush(s) < 0) {
		mailstream_close(s);
		*err = [NSString stringWithFormat: @"%@ did not take the request.", [u host]];
		return nil;
	}
	NSMutableData *resp = [NSMutableData data];
	char buf[4096];
	ssize_t n;
	while ((n = mailstream_read(s, buf, sizeof(buf))) > 0 && [resp length] < 1024 * 1024)
		[resp appendBytes: buf length: n];
	mailstream_close(s);
	const char *r = [resp bytes];
	const char *sep = [resp length] ? memmem(r, [resp length], "\r\n\r\n", 4) : NULL;
	if (sep == NULL || sscanf(r, "HTTP/%*s %d", status) != 1) {
		*err = [NSString stringWithFormat: @"%@ gave no answer that could be read.", [u host]];
		return nil;
	}
	NSString *headers = [[[NSString alloc] initWithBytes: r length: sep - r encoding: NSISOLatin1StringEncoding] autorelease];
	NSData *content = [resp subdataWithRange: NSMakeRange(sep + 4 - r, [resp length] - (sep + 4 - r))];
	if ([[headers lowercaseString] rangeOfString: @"transfer-encoding: chunked"].location != NSNotFound)
		content = dechunk(content);
	id json = [content length] ? [NSJSONSerialization JSONObjectWithData: content options: 0 error: NULL] : nil;
	if (![json isKindOfClass: [NSDictionary class]]) {
		*err = [NSString stringWithFormat: @"%@ answered %d, not with JSON.", [u host], *status];
		return nil;
	}
	return json;
}

/* ---- PKCE and state ---- */

static NSString *
random_string(int len)
{
	static const char set[] = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~";
	unsigned char b[128];
	char out[129];
	int i;
	if (len > 128)
		len = 128;
	arc4random_buf(b, len);
	for (i = 0; i < len; i++)
		out[i] = set[b[i] % 66];
	out[len] = 0;
	return [NSString stringWithUTF8String: out];
}

static NSString *
pkce_challenge(NSString *verifier)
{
	unsigned char h[32];
	const char *v = [verifier UTF8String];
	mbedtls_sha256((const unsigned char *)v, strlen(v), h, 0);
	NSString *b = Mail2Base64([NSData dataWithBytes: h length: 32]);
	b = [[b stringByReplacingOccurrencesOfString: @"+" withString: @"-"] stringByReplacingOccurrencesOfString: @"/" withString: @"_"];
	return [b stringByReplacingOccurrencesOfString: @"=" withString: @""];
}

/* ---- the token cache ---- */

static NSMutableDictionary *tokens;	/* account identifier -> {Token, Expires} */
static NSLock *token_lock;

static void
cache_token(Mail2Account *a, NSString *tok, NSNumber *expiresIn)
{
	double life = expiresIn ? [expiresIn doubleValue] : 3600;
	[token_lock lock];
	[tokens setObject: [NSDictionary dictionaryWithObjectsAndKeys: tok, @"Token",
	    [NSDate dateWithTimeIntervalSinceNow: life - 60], @"Expires", nil] forKey: [a identifier]];
	[token_lock unlock];
}

static NSString *
token_error(NSDictionary *j, int status)
{
	NSString *e = [j objectForKey: @"error_description"] ? [j objectForKey: @"error_description"] : [j objectForKey: @"error"];
	NSString *t = e ? [NSString stringWithFormat: @"%@", e] : [NSString stringWithFormat: @"the sign-in server answered %d", status];
	return [t hasSuffix: @"."] ? [t substringToIndex: [t length] - 1] : t;
}

@implementation Mail2OAuth

+ (void) initialize
{
	if (tokens == nil) {
		tokens = [[NSMutableDictionary alloc] init];
		token_lock = [[NSLock alloc] init];
	}
}

+ (NSString *) providerName: (Mail2Auth)p
{
	return p == Mail2AuthGoogle ? @"Google" : p == Mail2AuthMicrosoft ? @"Microsoft" : @"Password";
}

+ (NSString *) missingClientMessage: (Mail2Auth)p
{
	if (p == Mail2AuthPassword || client_id(p) != nil)
		return nil;
	return [NSString stringWithFormat: @"Mail2 needs your own %@ OAuth client ID to sign in this way (see Mail2's README): "
	    "defaults write Mail2 %@ <id>.", [self providerName: p],
	    p == Mail2AuthGoogle ? @"Mail2GoogleClientID" : @"Mail2MicrosoftClientID"];
}

+ (void) forgetAccessTokenForAccount: (Mail2Account *)a
{
	[token_lock lock];
	[tokens removeObjectForKey: [a identifier]];
	[token_lock unlock];
}

+ (NSString *) accessTokenForAccount: (Mail2Account *)a error: (NSString **)err
{
	[token_lock lock];
	NSDictionary *c = [[[tokens objectForKey: [a identifier]] retain] autorelease];
	[token_lock unlock];
	if (c != nil && [[c objectForKey: @"Expires"] timeIntervalSinceNow] > 0)
		return [c objectForKey: @"Token"];
	if ([[a refreshToken] length] == 0) {
		*err = [NSString stringWithFormat: @"Sign in to %@ again (Accounts…).", [a email]];
		return nil;
	}
	NSString *missing = [self missingClientMessage: [a auth]];
	if (missing) {
		*err = missing;
		return nil;
	}
	NSMutableDictionary *form = [NSMutableDictionary dictionaryWithObjectsAndKeys: @"refresh_token", @"grant_type",
	    [a refreshToken], @"refresh_token", client_id([a auth]), @"client_id", nil];
	NSString *secret = setting(@"Mail2GoogleClientSecret", nil);
	if ([a auth] == Mail2AuthGoogle && secret)
		[form setObject: secret forKey: @"client_secret"];
	if ([a auth] == Mail2AuthMicrosoft)
		[form setObject: MS_SCOPE forKey: @"scope"];
	int status = 0;
	NSDictionary *j = Mail2PostForm([a auth] == Mail2AuthGoogle ? GOOGLE_TOKEN : MS_TOKEN, form, &status, err);
	if (j == nil)
		return nil;
	NSString *tok = [j objectForKey: @"access_token"];
	if (status != 200 || ![tok isKindOfClass: [NSString class]]) {
		*err = [NSString stringWithFormat: @"%@ refused to renew the sign-in of %@: %@. Sign in again (Accounts…).",
		    [self providerName: [a auth]], [a email], token_error(j, status)];
		return nil;
	}
	cache_token(a, tok, [j objectForKey: @"expires_in"]);
	/* Microsoft hands out a new refresh token each time: the old one stops working, so the new one is saved */
	NSString *nrt = [j objectForKey: @"refresh_token"];
	if ([nrt isKindOfClass: [NSString class]] && ![nrt isEqualToString: [a refreshToken]]) {
		[a setRefreshToken: nrt];
		Mail2RunOnMain(^{ [[NSNotificationCenter defaultCenter] postNotificationName: Mail2AccountChanged object: a]; });
	}
	return tok;
}

/* waits for fd to be readable, or cancel, for at most seconds; 1 readable, 0 timeout, -1 cancelled or error */
static int
wait_readable(int fd, int cancel, int seconds)
{
	struct pollfd p[2] = { { fd, POLLIN, 0 }, { cancel, POLLIN, 0 } };
	NSDate *end = [NSDate dateWithTimeIntervalSinceNow: seconds];
	for (;;) {
		int ms = (int)([end timeIntervalSinceNow] * 1000);
		if (ms <= 0)
			return 0;
		int r = poll(p, cancel >= 0 ? 2 : 1, ms);
		if (r < 0 && errno == EINTR)	/* signals reach every thread here */
			continue;
		if (r < 0 || (cancel >= 0 && p[1].revents))
			return -1;
		if (r > 0)
			return 1;
	}
}

/* the value of name in a query string, decoded */
static NSString *
query_value(NSString *query, NSString *name)
{
	NSEnumerator *e = [[query componentsSeparatedByString: @"&"] objectEnumerator];
	NSString *kv;
	while ((kv = [e nextObject]) != nil) {
		NSRange eq = [kv rangeOfString: @"="];
		if (eq.location != NSNotFound && [[kv substringToIndex: eq.location] isEqualToString: name])
			return [[[kv substringFromIndex: eq.location + 1] stringByReplacingOccurrencesOfString: @"+" withString: @" "]
			    stringByReplacingPercentEscapesUsingEncoding: NSUTF8StringEncoding];
	}
	return nil;
}

/* Google: the browser brings the code back to a listener on 127.0.0.1 */
+ (NSDictionary *) googleSignIn: (Mail2Account *)a prompt: (void (^)(NSString *, NSString *, NSString *))prompt
                       cancelFd: (int)cancel error: (NSString **)err
{
	int ls = socket(AF_INET, SOCK_STREAM, 0);
	struct sockaddr_in sin;
	socklen_t sl = sizeof(sin);
	memset(&sin, 0, sizeof(sin));
	sin.sin_family = AF_INET;
	sin.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
	if (ls < 0 || bind(ls, (struct sockaddr *)&sin, sizeof(sin)) != 0 || listen(ls, 4) != 0 ||
	    getsockname(ls, (struct sockaddr *)&sin, &sl) != 0) {
		if (ls >= 0)
			close(ls);
		*err = @"Could not listen for the browser's answer on 127.0.0.1.";
		return nil;
	}
	NSString *redirect = [NSString stringWithFormat: @"http://127.0.0.1:%d", ntohs(sin.sin_port)];
	NSString *verifier = random_string(64), *state = random_string(24);
	NSDictionary *q = [NSDictionary dictionaryWithObjectsAndKeys: client_id(Mail2AuthGoogle), @"client_id",
	    redirect, @"redirect_uri", @"code", @"response_type", GOOGLE_SCOPE, @"scope", pkce_challenge(verifier), @"code_challenge",
	    @"S256", @"code_challenge_method", state, @"state", @"offline", @"access_type", @"consent", @"prompt",
	    [a email], @"login_hint", nil];
	NSString *url = [NSString stringWithFormat: @"%@?%@", GOOGLE_AUTH, form_encode(q)];
	Mail2RunOnMain(^{ prompt(@"Sign in to Google in the browser window. Mail2 continues by itself when you are done.", url, nil); });

	NSString *code = nil, *denied = nil;
	while (code == nil && denied == nil) {
		int w = wait_readable(ls, cancel, SIGNIN_TIMEOUT);
		if (w <= 0) {
			*err = w == 0 ? @"The sign-in took too long." : @"Cancelled.";
			break;
		}
		int c = accept(ls, NULL, NULL);
		if (c < 0)
			continue;
		char buf[8192];
		size_t got = 0;
		while (got < sizeof(buf) - 1 && wait_readable(c, -1, 10) > 0) {
			ssize_t n = read(c, buf + got, sizeof(buf) - 1 - got);
			if (n <= 0)
				break;
			got += n;
			buf[got] = 0;
			if (strstr(buf, "\r\n\r\n"))
				break;
		}
		buf[got] = 0;
		NSString *line = [[[[[NSString alloc] initWithBytes: buf length: got encoding: NSISOLatin1StringEncoding] autorelease]
		    componentsSeparatedByString: @"\r\n"] objectAtIndex: 0];
		NSArray *parts = [line componentsSeparatedByString: @" "];
		NSString *target = [parts count] >= 2 ? [parts objectAtIndex: 1] : @"";
		NSRange qm = [target rangeOfString: @"?"];
		NSString *query = qm.location != NSNotFound ? [target substringFromIndex: qm.location + 1] : @"";
		BOOL ours = [query_value(query, @"state") isEqualToString: state];
		if (ours) {
			code = query_value(query, @"code");
			if (code == nil)
				denied = query_value(query, @"error") ? query_value(query, @"error") : @"no code";
		}
		const char *page = ours ? "HTTP/1.1 200 OK\r\nContent-Type: text/html; charset=utf-8\r\nConnection: close\r\n\r\n"
		    "<html><body style='font-family:sans-serif;margin:3em'><h2>Mail2</h2><p>You can close this window and go back "
		    "to Mail2.</p></body></html>"
		    : "HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\nConnection: close\r\n\r\n";
		(void)write(c, page, strlen(page));
		close(c);
	}
	close(ls);
	if (code == nil) {
		if (denied)
			*err = [NSString stringWithFormat: @"Google did not allow it (%@).", denied];
		return nil;
	}
	NSMutableDictionary *form = [NSMutableDictionary dictionaryWithObjectsAndKeys: @"authorization_code", @"grant_type",
	    code, @"code", client_id(Mail2AuthGoogle), @"client_id", redirect, @"redirect_uri", verifier, @"code_verifier", nil];
	NSString *secret = setting(@"Mail2GoogleClientSecret", nil);
	if (secret)
		[form setObject: secret forKey: @"client_secret"];
	int status = 0;
	NSDictionary *j = Mail2PostForm(GOOGLE_TOKEN, form, &status, err);
	if (j != nil && status != 200) {
		*err = [NSString stringWithFormat: @"Google refused the sign-in: %@.", token_error(j, status)];
		return nil;
	}
	return j;
}

/* Microsoft: a code the user enters on a Microsoft page, while this polls */
+ (NSDictionary *) microsoftSignIn: (Mail2Account *)a prompt: (void (^)(NSString *, NSString *, NSString *))prompt
                          cancelFd: (int)cancel error: (NSString **)err
{
	int status = 0;
	NSDictionary *d = Mail2PostForm(MS_DEVICE, [NSDictionary dictionaryWithObjectsAndKeys: client_id(Mail2AuthMicrosoft),
	    @"client_id", MS_SCOPE, @"scope", nil], &status, err);
	if (d == nil)
		return nil;
	NSString *device = [d objectForKey: @"device_code"], *user = [d objectForKey: @"user_code"];
	NSString *vurl = [d objectForKey: @"verification_uri"];
	if (status != 200 || device == nil || user == nil) {
		*err = [NSString stringWithFormat: @"Microsoft refused the sign-in: %@.", token_error(d, status)];
		return nil;
	}
	int interval = [d objectForKey: @"interval"] ? [[d objectForKey: @"interval"] intValue] : 5;
	int life = [d objectForKey: @"expires_in"] ? [[d objectForKey: @"expires_in"] intValue] : 900;
	Mail2RunOnMain(^{ prompt([NSString stringWithFormat: @"On this or any other device, go to %@ and enter the code %@.",
	    vurl ? vurl : @"microsoft.com/devicelogin", user], vurl, user); });
	NSDate *end = [NSDate dateWithTimeIntervalSinceNow: life];
	while ([end timeIntervalSinceNow] > 0) {
		if (wait_readable(cancel, -1, interval > 0 ? interval : 1) != 0) {
			*err = @"Cancelled.";
			return nil;
		}
		NSDictionary *t = Mail2PostForm(MS_TOKEN, [NSDictionary dictionaryWithObjectsAndKeys:
		    @"urn:ietf:params:oauth:grant-type:device_code", @"grant_type", client_id(Mail2AuthMicrosoft), @"client_id",
		    device, @"device_code", nil], &status, err);
		if (t == nil)
			return nil;
		if (status == 200 && [t objectForKey: @"access_token"])
			return t;
		NSString *e = [t objectForKey: @"error"];
		if ([e isEqualToString: @"authorization_pending"])
			continue;
		if ([e isEqualToString: @"slow_down"]) {
			interval += 5;
			continue;
		}
		*err = [NSString stringWithFormat: @"Microsoft refused the sign-in: %@.", token_error(t, status)];
		return nil;
	}
	*err = @"The code expired before the sign-in was finished.";
	return nil;
}

+ (BOOL) signIn: (Mail2Account *)a prompt: (void (^)(NSString *message, NSString *url, NSString *code))prompt
       cancelFd: (int)cancel error: (NSString **)err
{
	NSString *missing = [self missingClientMessage: [a auth]];
	if (missing) {
		*err = missing;
		return NO;
	}
	NSDictionary *j = [a auth] == Mail2AuthGoogle ? [self googleSignIn: a prompt: prompt cancelFd: cancel error: err]
	                                              : [self microsoftSignIn: a prompt: prompt cancelFd: cancel error: err];
	if (j == nil)
		return NO;
	NSString *rt = [j objectForKey: @"refresh_token"], *at = [j objectForKey: @"access_token"];
	if (![rt isKindOfClass: [NSString class]] || ![at isKindOfClass: [NSString class]]) {
		*err = @"The sign-in gave no lasting permission (no refresh token).";
		return NO;
	}
	[a setRefreshToken: rt];
	cache_token(a, at, [j objectForKey: @"expires_in"]);
	return YES;
}

@end
