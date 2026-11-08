/* Mail2Util: small shared helpers (see Mail2Util.h). */
#import "Mail2Util.h"
#import <AppKit/AppKit.h>
#include <libetpan/libetpan-config.h>
#include <libetpan/mailimf.h>
#include <libetpan/mailmime_decode.h>
#include <stdlib.h>
#include <string.h>

@interface Mail2BlockBox : NSObject
{
	void (^blk)(void);
}
- (id) initWithBlock: (void (^)(void))b;
- (void) fire;
@end

@implementation Mail2BlockBox
- (id) initWithBlock: (void (^)(void))b { self = [super init]; blk = [b copy]; return self; }
- (void) fire
{
	blk();
	Mail2WakeEventLoop();
}
- (void) dealloc { [blk release]; [super dealloc]; }
@end

/* GNUstep draws windows that need it (and flushes to X) after it handles an event; a performSelector from another
 * thread is not one, so without an event (a mouse move, a key) the change stays undrawn. An application-defined
 * event, at most one queued at a time, makes the event loop go round. */
static BOOL wake_pending;

void
Mail2WakeEventLoop(void)
{
	if (wake_pending || NSApp == nil)
		return;
	wake_pending = YES;
	[NSApp postEvent: [NSEvent otherEventWithType: NSApplicationDefined location: NSZeroPoint modifierFlags: 0
	    timestamp: 0 windowNumber: 0 context: nil subtype: MAIL2_WAKE_SUBTYPE data1: 0 data2: 0] atStart: NO];
}

void
Mail2WakeEventHandled(void)
{
	wake_pending = NO;
}

void
Mail2RunOnMain(void (^block)(void))
{
	NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];
	Mail2BlockBox *b = [[Mail2BlockBox alloc] initWithBlock: block];
	[b performSelectorOnMainThread: @selector(fire) withObject: nil waitUntilDone: NO
	    modes: [NSArray arrayWithObjects: NSDefaultRunLoopMode, NSModalPanelRunLoopMode, NSEventTrackingRunLoopMode, nil]];
	[b release];
	[pool release];
}

NSString *
Mail2SupportDirectory(void)
{
	static NSString *dir;
	if (dir == nil) {
		NSArray *a = NSSearchPathForDirectoriesInDomains(NSLibraryDirectory, NSUserDomainMask, YES);
		NSString *lib = [a count] ? [a objectAtIndex: 0] : [NSHomeDirectory() stringByAppendingPathComponent: @"GNUstep/Library"];
		const char *env = getenv("MAIL2_SUPPORT_DIR");	/* tests: a scratch directory */
		dir = [(env && *env ? [NSString stringWithUTF8String: env] : [lib stringByAppendingPathComponent: @"Mail2"]) retain];
		[[NSFileManager defaultManager] createDirectoryAtPath: dir withIntermediateDirectories: YES attributes:
		    [NSDictionary dictionaryWithObject: [NSNumber numberWithShort: 0700] forKey: NSFilePosixPermissions] error: NULL];
	}
	return dir;
}

static NSString *
string_from_bytes(const char *s, size_t n)
{
	NSString *r = [[[NSString alloc] initWithBytes: s length: n encoding: NSUTF8StringEncoding] autorelease];
	if (r == nil)	/* not UTF-8: take it as Latin-1, which never fails */
		r = [[[NSString alloc] initWithBytes: s length: n encoding: NSISOLatin1StringEncoding] autorelease];
	return r;
}

NSString *
Mail2DecodeHeader(const char *s)
{
	char *out = NULL;
	size_t idx = 0;
	NSString *r;
	if (s == NULL)
		return nil;
	/* raw 8-bit bytes in a header are most often UTF-8 nowadays */
	if (mailmime_encoded_phrase_parse("utf-8", s, strlen(s), &idx, "utf-8", &out) == MAILIMF_NO_ERROR && out != NULL) {
		r = string_from_bytes(out, strlen(out));
		free(out);
	} else
		r = string_from_bytes(s, strlen(s));
	/* folded headers keep their line breaks and tabs */
	r = [[r componentsSeparatedByCharactersInSet: [NSCharacterSet characterSetWithCharactersInString: @"\r\n\t"]]
	    componentsJoinedByString: @" "];
	return [r stringByTrimmingCharactersInSet: [NSCharacterSet whitespaceCharacterSet]];
}

static int
b64val(unichar c)
{
	if (c >= 'A' && c <= 'Z') return c - 'A';
	if (c >= 'a' && c <= 'z') return c - 'a' + 26;
	if (c >= '0' && c <= '9') return c - '0' + 52;
	if (c == '+') return 62;
	if (c == ',') return 63;
	return -1;
}

NSString *
Mail2DecodeMailboxName(const char *s)
{
	NSMutableString *r = [NSMutableString string];
	size_t i, n = strlen(s);
	for (i = 0; i < n; i++) {
		if (s[i] != '&') {
			[r appendFormat: @"%c", s[i]];
			continue;
		}
		if (i + 1 < n && s[i + 1] == '-') {	/* "&-" is "&" */
			[r appendString: @"&"];
			i++;
			continue;
		}
		/* "&" base64(UTF-16BE) "-" */
		unsigned bits = 0, nbits = 0;
		unichar u[256];
		int nu = 0;
		for (i++; i < n && s[i] != '-'; i++) {
			int v = b64val(s[i]);
			if (v < 0)
				break;
			bits = (bits << 6) | v;
			nbits += 6;
			if (nbits >= 16) {
				nbits -= 16;
				if (nu < 256)
					u[nu++] = (bits >> nbits) & 0xffff;
			}
		}
		[r appendString: [NSString stringWithCharacters: u length: nu]];
	}
	return r;
}

NSString *
Mail2EncodeHeader(NSString *s)
{
	if (s == nil || [s canBeConvertedToEncoding: NSASCIIStringEncoding])
		return s;
	/* encoded words of at most 45 bytes of UTF-8 (60 base64 chars), split between characters */
	NSMutableArray *words = [NSMutableArray array];
	NSUInteger i = 0, len = [s length];
	while (i < len) {
		NSUInteger j = i;
		NSUInteger bytes = 0;
		while (j < len) {
			NSRange cr = [s rangeOfComposedCharacterSequenceAtIndex: j];
			NSUInteger b = [[s substringWithRange: cr] lengthOfBytesUsingEncoding: NSUTF8StringEncoding];
			if (bytes + b > 45 && j > i)
				break;
			bytes += b;
			j = NSMaxRange(cr);
		}
		NSData *d = [[s substringWithRange: NSMakeRange(i, j - i)] dataUsingEncoding: NSUTF8StringEncoding];
		static const char tbl[] = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
		const unsigned char *p = [d bytes];
		NSUInteger k, dl = [d length];
		NSMutableString *w = [NSMutableString stringWithString: @"=?UTF-8?B?"];
		for (k = 0; k < dl; k += 3) {
			unsigned v = p[k] << 16 | (k + 1 < dl ? p[k + 1] << 8 : 0) | (k + 2 < dl ? p[k + 2] : 0);
			[w appendFormat: @"%c%c%c%c", tbl[v >> 18 & 63], tbl[v >> 12 & 63],
			    k + 1 < dl ? tbl[v >> 6 & 63] : '=', k + 2 < dl ? tbl[v & 63] : '='];
		}
		[w appendString: @"?="];
		[words addObject: w];
		i = j;
	}
	return [words componentsJoinedByString: @" "];
}

static NSCalendar *
calendar(void)
{
	return [NSCalendar currentCalendar];
}

NSString *
Mail2ListDate(NSDate *d)
{
	if (d == nil)
		return @"";
	NSCalendar *cal = calendar();
	NSDate *now = [NSDate date];
	unsigned units = NSYearCalendarUnit | NSMonthCalendarUnit | NSDayCalendarUnit;
	NSDateComponents *a = [cal components: units fromDate: d], *b = [cal components: units fromDate: now];
	NSDate *da = [cal dateFromComponents: a], *db = [cal dateFromComponents: b];
	NSInteger days = (NSInteger)floor(([db timeIntervalSinceReferenceDate] - [da timeIntervalSinceReferenceDate]) / 86400.0 + 0.5);
	if (days <= 0)
		return [d descriptionWithCalendarFormat: @"%H:%M" timeZone: nil locale: nil];
	if (days == 1)
		return @"Yesterday";
	if (days < 7)
		return [d descriptionWithCalendarFormat: @"%A" timeZone: nil locale: nil];
	return [d descriptionWithCalendarFormat: @"%d/%m/%y" timeZone: nil locale: nil];
}

NSString *
Mail2LongDate(NSDate *d)
{
	if (d == nil)
		return @"";
	return [d descriptionWithCalendarFormat: @"%A %e %B %Y at %H:%M" timeZone: nil locale: nil];
}

NSString *
Mail2ByteSize(unsigned long long n)
{
	if (n < 1024)
		return [NSString stringWithFormat: @"%llu bytes", n];
	if (n < 1024 * 1024)
		return [NSString stringWithFormat: @"%llu KB", (n + 1023) / 1024];
	return [NSString stringWithFormat: @"%.1f MB", n / 1048576.0];
}

NSString *
Mail2AddressPart(NSString *s)
{
	NSRange lt = [s rangeOfString: @"<" options: NSBackwardsSearch];
	if (lt.location != NSNotFound) {
		NSRange gt = [s rangeOfString: @">" options: 0 range: NSMakeRange(lt.location, [s length] - lt.location)];
		if (gt.location != NSNotFound)
			return [[s substringWithRange: NSMakeRange(lt.location + 1, gt.location - lt.location - 1)]
			    stringByTrimmingCharactersInSet: [NSCharacterSet whitespaceCharacterSet]];
	}
	return [s stringByTrimmingCharactersInSet: [NSCharacterSet whitespaceAndNewlineCharacterSet]];
}

NSArray *
Mail2SplitAddresses(NSString *s)
{
	NSMutableArray *out = [NSMutableArray array];
	NSUInteger i, start = 0, len = [s length];
	BOOL quoted = NO, angle = NO;
	for (i = 0; i <= len; i++) {
		unichar c = i < len ? [s characterAtIndex: i] : ',';
		if (c == '"')
			quoted = !quoted;
		else if (c == '<' && !quoted)
			angle = YES;
		else if (c == '>' && !quoted)
			angle = NO;
		else if ((c == ',' || c == ';') && !quoted && !angle) {
			NSString *a = [[s substringWithRange: NSMakeRange(start, i - start)]
			    stringByTrimmingCharactersInSet: [NSCharacterSet whitespaceAndNewlineCharacterSet]];
			if ([a length] > 0)
				[out addObject: a];
			start = i + 1;
		}
	}
	return out;
}

BOOL
Mail2Debug(void)
{
	static int v = -1;
	if (v < 0) {
		const char *e = getenv("MAIL2_DEBUG");
		v = (e != NULL && *e == '1') || [[NSUserDefaults standardUserDefaults] boolForKey: @"Mail2Debug"];
	}
	return v;
}

NSString *
Mail2MessageIDsIn(NSString *s)
{
	NSMutableArray *ids = [NSMutableArray array];
	NSScanner *sc;
	if (s == nil)
		return nil;
	sc = [NSScanner scannerWithString: s];
	[sc setCharactersToBeSkipped: nil];
	while (![sc isAtEnd]) {
		NSString *idv = nil;
		[sc scanUpToString: @"<" intoString: NULL];
		if (![sc scanString: @"<" intoString: NULL])
			break;
		if ([sc scanUpToString: @">" intoString: &idv] && [sc scanString: @">" intoString: NULL] &&
		    [idv rangeOfCharacterFromSet: [NSCharacterSet whitespaceAndNewlineCharacterSet]].location == NSNotFound)
			[ids addObject: [NSString stringWithFormat: @"<%@>", idv]];
	}
	return [ids count] ? [ids componentsJoinedByString: @" "] : nil;
}

NSString *
Mail2BaseSubject(NSString *s)
{
	NSString *t = [[s ? s : @"" stringByTrimmingCharactersInSet: [NSCharacterSet whitespaceCharacterSet]] lowercaseString];
	static NSString *prefixes[] = { @"re:", @"re :", @"fwd:", @"fw:", @"aw:", @"wg:", @"sv:", @"vs:", @"tr:", @"rif:" };
	BOOL again = YES;
	while (again && [t length]) {
		unsigned i;
		again = NO;
		for (i = 0; i < sizeof(prefixes) / sizeof(prefixes[0]); i++)
			if ([t hasPrefix: prefixes[i]]) {
				t = [[t substringFromIndex: [prefixes[i] length]] stringByTrimmingCharactersInSet: [NSCharacterSet whitespaceCharacterSet]];
				again = YES;
			}
		/* "[list-name] " */
		if ([t hasPrefix: @"["]) {
			NSRange e = [t rangeOfString: @"]"];
			if (e.location != NSNotFound && e.location < 40) {
				t = [[t substringFromIndex: e.location + 1] stringByTrimmingCharactersInSet: [NSCharacterSet whitespaceCharacterSet]];
				again = YES;
			}
		}
	}
	return t;
}

NSString *
Mail2Base64(NSData *d)
{
	static const char tbl[] = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
	const unsigned char *p = [d bytes];
	NSUInteger k, n = [d length];
	NSMutableString *s = [NSMutableString stringWithCapacity: (n + 2) / 3 * 4];
	for (k = 0; k < n; k += 3) {
		unsigned v = p[k] << 16 | (k + 1 < n ? p[k + 1] << 8 : 0) | (k + 2 < n ? p[k + 2] : 0);
		[s appendFormat: @"%c%c%c%c", tbl[v >> 18 & 63], tbl[v >> 12 & 63], k + 1 < n ? tbl[v >> 6 & 63] : '=', k + 2 < n ? tbl[v & 63] : '='];
	}
	return s;
}

NSString *
Mail2EncodeMailboxName(NSString *s)
{
	static const char tbl[] = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+,";
	NSMutableString *out = [NSMutableString string];
	NSUInteger i = 0, n = [s length];
	while (i < n) {
		unichar c = [s characterAtIndex: i];
		if (c >= 0x20 && c <= 0x7e) {
			[out appendString: c == '&' ? @"&-" : [NSString stringWithCharacters: &c length: 1]];
			i++;
			continue;
		}
		/* a run of others: UTF-16 big-endian, base64 with "," for "/", no padding */
		NSMutableData *d = [NSMutableData data];
		while (i < n && ((c = [s characterAtIndex: i]) < 0x20 || c > 0x7e)) {
			unsigned char be[2] = { c >> 8, c & 0xff };
			[d appendBytes: be length: 2];
			i++;
		}
		const unsigned char *p = [d bytes];
		NSUInteger k, len = [d length];
		[out appendString: @"&"];
		for (k = 0; k < len; k += 3) {
			unsigned v = p[k] << 16 | (k + 1 < len ? p[k + 1] << 8 : 0) | (k + 2 < len ? p[k + 2] : 0);
			[out appendFormat: @"%c%c", tbl[v >> 18 & 63], tbl[v >> 12 & 63]];
			if (k + 1 < len) [out appendFormat: @"%c", tbl[v >> 6 & 63]];
			if (k + 2 < len) [out appendFormat: @"%c", tbl[v & 63]];
		}
		[out appendString: @"-"];
	}
	return out;
}

static NSString *
pct(NSString *s)
{
	NSString *d = [[s stringByReplacingOccurrencesOfString: @"+" withString: @"%2B"] stringByReplacingPercentEscapesUsingEncoding: NSUTF8StringEncoding];
	return d ? d : s;
}

NSDictionary *
Mail2ParseMailto(NSString *url)
{
	NSMutableDictionary *r = [NSMutableDictionary dictionary];
	NSString *s = [[url lowercaseString] hasPrefix: @"mailto:"] ? [url substringFromIndex: 7] : url;
	NSRange q = [s rangeOfString: @"?"];
	NSString *to = q.location == NSNotFound ? s : [s substringToIndex: q.location];
	if ([to length])
		[r setObject: pct(to) forKey: @"To"];
	if (q.location != NSNotFound) {
		NSEnumerator *e = [[[s substringFromIndex: q.location + 1] componentsSeparatedByString: @"&"] objectEnumerator];
		NSString *kv;
		while ((kv = [e nextObject]) != nil) {
			NSRange eq = [kv rangeOfString: @"="];
			if (eq.location == NSNotFound)
				continue;
			NSString *k = [[kv substringToIndex: eq.location] lowercaseString], *v = pct([kv substringFromIndex: eq.location + 1]);
			NSString *key = [k isEqualToString: @"to"] ? @"To" : [k isEqualToString: @"cc"] ? @"Cc" : [k isEqualToString: @"bcc"] ? @"Bcc"
			    : [k isEqualToString: @"subject"] ? @"Subject" : [k isEqualToString: @"body"] ? @"Body" : nil;
			if (key == nil)
				continue;
			NSString *old = [r objectForKey: key];
			[r setObject: old && ([key isEqualToString: @"To"] || [key isEqualToString: @"Cc"] || [key isEqualToString: @"Bcc"])
			    ? [NSString stringWithFormat: @"%@, %@", old, v] : v forKey: key];
		}
	}
	return r;
}

NSDictionary *
Mail2ParseSearch(NSString *text)
{
	NSMutableDictionary *q = [NSMutableDictionary dictionary];
	NSMutableArray *words = [NSMutableArray array], *from = [NSMutableArray array], *to = [NSMutableArray array],
	    *subject = [NSMutableArray array];
	NSUInteger i = 0, n = [text length];
	while (i < n) {
		while (i < n && [text characterAtIndex: i] == ' ')
			i++;
		if (i >= n)
			break;
		/* a token: up to a space outside quotes */
		NSMutableString *tok = [NSMutableString string];
		BOOL quoted = NO;
		while (i < n && (quoted || [text characterAtIndex: i] != ' ')) {
			unichar c = [text characterAtIndex: i++];
			if (c == '"')
				quoted = !quoted;
			else
				[tok appendFormat: @"%C", c];
		}
		NSRange colon = [tok rangeOfString: @":"];
		NSString *key = colon.location != NSNotFound ? [[tok substringToIndex: colon.location] lowercaseString] : nil;
		NSString *val = colon.location != NSNotFound ? [tok substringFromIndex: colon.location + 1] : nil;
		NSCalendarDate *day = nil;
		if (key && ([key isEqualToString: @"before"] || [key isEqualToString: @"after"]))
			day = [NSCalendarDate dateWithString: val calendarFormat: @"%Y-%m-%d"];
		if ([key isEqualToString: @"from"] && [val length])
			[from addObject: val];
		else if ([key isEqualToString: @"to"] && [val length])
			[to addObject: val];
		else if ([key isEqualToString: @"subject"] && [val length])
			[subject addObject: val];
		else if ([key isEqualToString: @"has"] && [[val lowercaseString] hasPrefix: @"attach"])
			[q setObject: [NSNumber numberWithBool: YES] forKey: @"Attachment"];
		else if ([key isEqualToString: @"is"] && [[val lowercaseString] isEqualToString: @"unread"])
			[q setObject: [NSNumber numberWithBool: YES] forKey: @"Unread"];
		else if ([key isEqualToString: @"is"] && [[val lowercaseString] isEqualToString: @"read"])
			[q setObject: [NSNumber numberWithBool: YES] forKey: @"Read"];
		else if ([key isEqualToString: @"is"] && [[val lowercaseString] isEqualToString: @"flagged"])
			[q setObject: [NSNumber numberWithBool: YES] forKey: @"Flagged"];
		else if (day != nil)
			[q setObject: day forKey: [key isEqualToString: @"before"] ? @"Before" : @"After"];
		else if ([tok length])
			[words addObject: tok];
	}
	[q setObject: words forKey: @"Words"];
	[q setObject: from forKey: @"From"];
	[q setObject: to forKey: @"To"];
	[q setObject: subject forKey: @"Subject"];
	return q;
}

#define MAP_FROM (256 * 1024)	/* below it a read is cheaper than setting up a mapping */

NSData *
Mail2ReadMessageFile(NSString *path)
{
	if (path == nil)
		return nil;
	NSDictionary *a = [[NSFileManager defaultManager] attributesOfItemAtPath: path error: NULL];
	if (a != nil && [a fileSize] >= MAP_FROM) {
		NSData *d = [NSData dataWithContentsOfMappedFile: path];
		if (d != nil)
			return d;
	}
	return [NSData dataWithContentsOfFile: path];
}
