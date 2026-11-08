/* Mail2Util: small shared helpers. */
#import <Foundation/Foundation.h>

/* Runs the block on the main thread from any thread (performSelectorOnMainThread wakes GNUstep's run loop; work queued
 * on the main dispatch queue does not). Never waits. */
void Mail2RunOnMain(void (^block)(void));
/* posts an application-defined event so GNUstep's event loop runs and redraws (see Mail2Util.m); the application's
 * -sendEvent: calls Mail2WakeEventHandled when it receives it */
#define MAIL2_WAKE_SUBTYPE 0x4d32
void Mail2WakeEventLoop(void);
void Mail2WakeEventHandled(void);

/* ~/GNUstep/Library/Mail2, created on first use */
NSString *Mail2SupportDirectory(void);

/* An RFC 2047 header value ("=?utf-8?B?...?=" words, or raw 8-bit text) as a string; nil in, nil out. */
NSString *Mail2DecodeHeader(const char *s);
/* An IMAP mailbox name (modified UTF-7, RFC 3501 5.1.3) as a string. */
NSString *Mail2DecodeMailboxName(const char *s);
/* and back: a name as IMAP wants it (printable ASCII as is, "&" as "&-", the rest as &...- modified base64) */
NSString *Mail2EncodeMailboxName(NSString *s);
/* A header value for an outgoing message: unchanged if ASCII, else RFC 2047 encoded words (UTF-8, base64). */
NSString *Mail2EncodeHeader(NSString *s);

/* "9:41", "Yesterday", "Monday", "12/3/26" for the message list, as Apple Mail does */
NSString *Mail2ListDate(NSDate *d);
/* "Saturday 7 November 2026 at 9:41" for the message header */
NSString *Mail2LongDate(NSDate *d);
/* "12 KB" */
NSString *Mail2ByteSize(unsigned long long n);

/* A search as typed: free words and from:, to:, subject:, has:attachment, is:unread, is:read, is:flagged,
 * before:YYYY-MM-DD, after:YYYY-MM-DD ("quotes" for values with spaces). Keys: Words, From, To, Subject (arrays of
 * strings), Attachment, Unread, Read, Flagged (YES when given), Before, After (NSDate, the start of that day). */
NSDictionary *Mail2ParseSearch(NSString *text);

/* A mailto: URL (RFC 6068) as {To, Cc, Bcc, Subject, Body}: the address part and its ?query, decoded. */
NSDictionary *Mail2ParseMailto(NSString *url);

/* The address in "Name <addr>" or bare "addr". */
NSString *Mail2AddressPart(NSString *s);
/* Splits "a@b, \"Last, First\" <c@d>" into address strings, honouring quotes and angle brackets. */
NSArray *Mail2SplitAddresses(NSString *s);

/* The message ids ("<a@b>") in a header value, in order, joined by single spaces; nil if there are none. */
NSString *Mail2MessageIDsIn(NSString *s);
/* A subject without its Re:/Fwd:/AW:/[list] prefixes, lowercased: what replies in a conversation share. */
NSString *Mail2BaseSubject(NSString *s);

/* base64 (RFC 4648, with padding) */
NSString *Mail2Base64(NSData *d);

/* Whether -Mail2Debug YES or MAIL2_DEBUG=1 is set: logs the IMAP/SMTP conversation (passwords masked). */
BOOL Mail2Debug(void);
