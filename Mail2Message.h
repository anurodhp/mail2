/* Mail2Message: reading a downloaded message (libetpan's MIME parser) and building an outgoing one (libetpan's
 * MIME writer). HTML bodies are turned into text with libxml2's HTML parser: no remote content is ever loaded. */
#import <Foundation/Foundation.h>

@interface Mail2Attachment : NSObject
{
	NSString *filename, *mimeType;
	NSData *data;
}
- (id) initWithName: (NSString *)n type: (NSString *)t data: (NSData *)d;	/* t nil: from the name */
- (NSString *) filename;
- (NSString *) mimeType;
- (NSData *) data;	/* decoded */
@end

@interface Mail2ParsedMessage : NSObject
{
	NSString *body;
	BOOL html;
	NSMutableArray *attachments;
	NSString *messageId, *inReplyTo, *bcc;
	NSArray *references;
	NSString *htmlSource;
	NSMutableDictionary *inlineParts;
}
/* nil if it cannot be parsed at all */
+ (Mail2ParsedMessage *) parseData: (NSData *)raw preferPlainText: (BOOL)plain;
- (NSString *) body;		/* the text to show */
- (BOOL) bodyWasHTML;
- (NSString *) htmlSource;	/* the HTML shown, as HTML (when the HTML part was chosen), else nil */
- (NSDictionary *) inlineParts;	/* Content-ID (no <>) -> Mail2Attachment: the images an HTML body shows by cid: */
- (NSArray *) attachments;	/* Mail2Attachment */
- (NSString *) snippet;		/* the opening of the body, quotes and blank lines left out, at most 200 characters */
- (NSString *) messageId;	/* "<id@host>" */
- (NSArray *) references;	/* "<id@host>" each, oldest first */
- (NSString *) inReplyTo;	/* "<id@host>" or nil */
- (NSString *) bcc;		/* a draft's Bcc header, "Name <addr>, ..." or nil */
@end

/* An RFC 5322 message: text/plain UTF-8, quoted-printable. `to`, `cc` are arrays of "Name <addr>" or "addr" strings
 * (Bcc recipients are not written into the message: Mail2SMTP gives them to the server only). `inReplyTo` and
 * `references` are "<id>" strings or nil. Returns nil if an address cannot be read. */
NSData *Mail2BuildMessage(NSString *from, NSArray *to, NSArray *cc, NSString *subject, NSString *body,
    NSString *inReplyTo, NSArray *references);
/* the same, with files (Mail2Attachment: multipart/mixed, each base64), a Bcc header (only for a draft, which keeps its
 * Bcc; never for a message sent) and a given Message-ID ("<id>"; nil makes one). */
NSData *Mail2BuildMessageEx(NSString *from, NSArray *to, NSArray *cc, NSArray *bccHeader, NSString *subject, NSString *body,
    NSString *inReplyTo, NSArray *references, NSArray *attachments, NSString *messageId);
NSString *Mail2MimeTypeForFilename(NSString *name);
NSString *Mail2NewMessageID(NSString *fromAddress);	/* "<unique.mail2@the sender's domain>" */

/* whether HTML refers to anything on the web (images, styles): what Load Remote Content would fetch */
BOOL Mail2HTMLHasRemoteContent(NSString *html);
