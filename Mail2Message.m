/* Mail2Message: parsing and building messages with libetpan (see Mail2Message.h). */
#import "Mail2Message.h"
#import "Mail2Util.h"
#include <libetpan/libetpan-config.h>
#include <libetpan/mailmime.h>
#include <libetpan/mailimf.h>
#include <libetpan/charconv.h>
#include <libxml/HTMLparser.h>
#include <libxml/tree.h>
#include <stdlib.h>
#include <string.h>
#include <strings.h>

@implementation Mail2Attachment
- (id) initWithName: (NSString *)n type: (NSString *)t data: (NSData *)d
{
	if ((self = [super init]) != nil) {
		filename = [n retain];
		mimeType = [t retain];
		data = [d retain];
	}
	return self;
}
- (void) dealloc { [filename release]; [mimeType release]; [data release]; [super dealloc]; }
- (NSString *) filename { return filename; }
- (NSString *) mimeType { return mimeType; }
- (NSData *) data { return data; }
@end

/* ---- HTML to text ---- */

static BOOL
is_block(const char *n)
{
	static const char *blocks[] = { "p", "div", "h1", "h2", "h3", "h4", "h5", "h6", "table", "tr", "ul", "ol",
		"blockquote", "section", "article", "header", "footer", "center", "pre", "address", "dl", "dt", "dd",
		"form", "fieldset", "figure", "main", "nav", "aside", NULL };
	int i;
	for (i = 0; blocks[i]; i++)
		if (strcasecmp(n, blocks[i]) == 0)
			return YES;
	return NO;
}

static void
newline(NSMutableString *out, int want)
{
	/* at most `want` line breaks in a row at the end of out */
	NSUInteger len = [out length];
	int have = 0;
	while (have < (int)len && [out characterAtIndex: len - 1 - have] == '\n')
		have++;
	/* trailing spaces before a break are noise */
	while ([out length] > 0 && [out characterAtIndex: [out length] - 1] == ' ' && have == 0)
		[out deleteCharactersInRange: NSMakeRange([out length] - 1, 1)];
	if (len == 0)
		return;
	for (; have < want; have++)
		[out appendString: @"\n"];
}

static void
html_walk(xmlNode *n, NSMutableString *out, BOOL pre)
{
	for (; n != NULL; n = n->next) {
		if (n->type == XML_TEXT_NODE || n->type == XML_CDATA_SECTION_NODE) {
			NSString *t = [NSString stringWithUTF8String: (const char *)(n->content ? n->content : (xmlChar *)"")];
			if (t == nil)
				continue;
			if (pre) {
				[out appendString: t];
				continue;
			}
			/* collapse runs of white space to one space; none at the start of a line */
			NSArray *words = [t componentsSeparatedByCharactersInSet: [NSCharacterSet whitespaceAndNewlineCharacterSet]];
			NSEnumerator *e = [words objectEnumerator];
			NSString *w;
			BOOL lead = [t length] > 0 && [[NSCharacterSet whitespaceAndNewlineCharacterSet] characterIsMember: [t characterAtIndex: 0]];
			BOOL first = YES;
			while ((w = [e nextObject]) != nil) {
				if ([w length] == 0)
					continue;
				unichar last = [out length] ? [out characterAtIndex: [out length] - 1] : '\n';
				if ((!first || lead) && last != '\n' && last != ' ')
					[out appendString: @" "];
				[out appendString: [w stringByReplacingOccurrencesOfString: @" " withString: @" "]];
				first = NO;
			}
			if ([t length] > 0 && [[NSCharacterSet whitespaceAndNewlineCharacterSet] characterIsMember: [t characterAtIndex: [t length] - 1]] &&
			    [out length] > 0 && [out characterAtIndex: [out length] - 1] != '\n')
				[out appendString: @" "];
			continue;
		}
		if (n->type != XML_ELEMENT_NODE)
			continue;
		const char *name = (const char *)n->name;
		if (strcasecmp(name, "head") == 0 || strcasecmp(name, "script") == 0 || strcasecmp(name, "style") == 0 ||
		    strcasecmp(name, "title") == 0 || strcasecmp(name, "noscript") == 0)
			continue;
		if (strcasecmp(name, "br") == 0) {
			[out appendString: @"\n"];
			continue;
		}
		if (strcasecmp(name, "hr") == 0) {
			newline(out, 1);
			[out appendString: @"――――――――――――――――\n"];
			continue;
		}
		if (strcasecmp(name, "img") == 0) {
			xmlChar *alt = xmlGetProp(n, (const xmlChar *)"alt");
			if (alt != NULL && *alt) {
				NSString *a = [NSString stringWithUTF8String: (const char *)alt];
				if ([a length] > 0 && [a length] < 80)
					[out appendFormat: @"[%@]", a];
			}
			xmlFree(alt);
			continue;
		}
		BOOL block = is_block(name);
		BOOL para = strcasecmp(name, "p") == 0 || (name[0] == 'h' && name[1] >= '1' && name[1] <= '6' && name[2] == 0) ||
		    strcasecmp(name, "blockquote") == 0;
		if (block)
			newline(out, para ? 2 : 1);
		if (strcasecmp(name, "li") == 0) {
			newline(out, 1);
			[out appendString: @"• "];
		}
		if ((strcasecmp(name, "td") == 0 || strcasecmp(name, "th") == 0) && [out length] > 0 &&
		    [out characterAtIndex: [out length] - 1] != '\n')
			[out appendString: @"  "];
		html_walk(n->children, out, pre || strcasecmp(name, "pre") == 0);
		if (block || strcasecmp(name, "li") == 0)
			newline(out, para ? 2 : 1);
	}
}

static NSString *
html_to_text(NSString *html)
{
	NSData *d = [html dataUsingEncoding: NSUTF8StringEncoding];
	htmlDocPtr doc = htmlReadMemory([d bytes], (int)[d length], NULL, "UTF-8",
	    HTML_PARSE_RECOVER | HTML_PARSE_NOERROR | HTML_PARSE_NOWARNING | HTML_PARSE_NONET);
	NSMutableString *out = [NSMutableString string];
	if (doc == NULL)
		return html;
	html_walk(xmlDocGetRootElement(doc), out, NO);
	xmlFreeDoc(doc);
	/* no spaces at line starts, at most one blank line in a row */
	NSArray *lines = [out componentsSeparatedByString: @"\n"];
	NSMutableArray *clean = [NSMutableArray array];
	NSEnumerator *e = [lines objectEnumerator];
	NSString *l;
	int blanks = 0;
	while ((l = [e nextObject]) != nil) {
		l = [l stringByTrimmingCharactersInSet: [NSCharacterSet whitespaceCharacterSet]];
		if ([l length] == 0) {
			if (++blanks > 1 || [clean count] == 0)
				continue;
		} else
			blanks = 0;
		[clean addObject: l];
	}
	return [[clean componentsJoinedByString: @"\n"] stringByTrimmingCharactersInSet: [NSCharacterSet whitespaceAndNewlineCharacterSet]];
}

/* ---- parsing ---- */

static NSData *
decode_part(struct mailmime *m)
{
	struct mailmime_data *d = m->mm_data.mm_single;
	char *out = NULL;
	size_t idx = 0, outlen = 0;
	NSData *r;
	if (d == NULL || d->dt_type != MAILMIME_DATA_TEXT)
		return [NSData data];
	if (!d->dt_encoded)
		return [NSData dataWithBytes: d->dt_data.dt_text.dt_data length: d->dt_data.dt_text.dt_length];
	if (mailmime_part_parse(d->dt_data.dt_text.dt_data, d->dt_data.dt_text.dt_length, &idx, d->dt_encoding, &out, &outlen) != MAILIMF_NO_ERROR)
		return [NSData dataWithBytes: d->dt_data.dt_text.dt_data length: d->dt_data.dt_text.dt_length];
	r = [NSData dataWithBytes: out length: outlen];
	mailmime_decoded_part_free(out);
	return r;
}

static NSString *
text_of(NSData *bytes, const char *charset)
{
	NSString *s = nil;
	char *conv = NULL;
	if (charset != NULL && strcasecmp(charset, "utf-8") != 0 && strcasecmp(charset, "us-ascii") != 0 &&
	    charconv("utf-8", charset, [bytes bytes], [bytes length], &conv) == MAIL_CHARCONV_NO_ERROR && conv != NULL) {
		s = [NSString stringWithUTF8String: conv];
		charconv_buffer_free(conv);
	}
	if (s == nil)
		s = [[[NSString alloc] initWithData: bytes encoding: NSUTF8StringEncoding] autorelease];
	if (s == nil)
		s = [[[NSString alloc] initWithData: bytes encoding: NSWindowsCP1252StringEncoding] autorelease];
	if (s == nil)
		s = [[[NSString alloc] initWithData: bytes encoding: NSISOLatin1StringEncoding] autorelease];
	return [s stringByReplacingOccurrencesOfString: @"\r\n" withString: @"\n"];
}

static NSString *
content_type(struct mailmime_content *ct)
{
	const char *type = "application";
	if (ct == NULL || ct->ct_type == NULL)
		return @"text/plain";
	if (ct->ct_type->tp_type == MAILMIME_TYPE_DISCRETE_TYPE && ct->ct_type->tp_data.tp_discrete_type) {
		switch (ct->ct_type->tp_data.tp_discrete_type->dt_type) {
		case MAILMIME_DISCRETE_TYPE_TEXT: type = "text"; break;
		case MAILMIME_DISCRETE_TYPE_IMAGE: type = "image"; break;
		case MAILMIME_DISCRETE_TYPE_AUDIO: type = "audio"; break;
		case MAILMIME_DISCRETE_TYPE_VIDEO: type = "video"; break;
		case MAILMIME_DISCRETE_TYPE_APPLICATION: type = "application"; break;
		default: type = ct->ct_type->tp_data.tp_discrete_type->dt_extension ? ct->ct_type->tp_data.tp_discrete_type->dt_extension : "application";
		}
	} else if (ct->ct_type->tp_type == MAILMIME_TYPE_COMPOSITE_TYPE && ct->ct_type->tp_data.tp_composite_type) {
		type = ct->ct_type->tp_data.tp_composite_type->ct_type == MAILMIME_COMPOSITE_TYPE_MESSAGE ? "message" : "multipart";
	}
	return [[NSString stringWithFormat: @"%s/%s", type, ct->ct_subtype ? ct->ct_subtype : "octet-stream"] lowercaseString];
}

@implementation Mail2ParsedMessage

- (void) dealloc
{
	[body release]; [attachments release]; [messageId release]; [references release]; [inReplyTo release]; [bcc release];
	[htmlSource release]; [inlineParts release];
	[super dealloc];
}

- (void) addText: (NSString *)t html: (BOOL)isHTML
{
	if (isHTML) {
		if ([t length]) {	/* the source too, for a web view */
			NSString *src = htmlSource ? [NSString stringWithFormat: @"%@\n%@", htmlSource, t] : t;
			ASSIGN(htmlSource, src);
		}
		t = html_to_text(t);
		html = YES;
	}
	if ([t length] == 0)
		return;
	if (body == nil)
		body = [t retain];
	else {
		NSString *b = [NSString stringWithFormat: @"%@\n\n%@", body, t];
		ASSIGN(body, b);
	}
}

/* in multipart/alternative: the part to show (plain or HTML as preferred, else the last one we can read) */
static struct mailmime *
choose_alternative(struct mailmime *m, BOOL plain)
{
	struct mailmime *best = NULL, *other = NULL;
	clistiter *it;
	for (it = clist_begin(m->mm_data.mm_multipart.mm_mp_list); it != NULL; it = clist_next(it)) {
		struct mailmime *c = clist_content(it);
		NSString *t = content_type(c->mm_content_type);
		BOOL isPlain = [t isEqualToString: @"text/plain"];
		BOOL isHTML = [t isEqualToString: @"text/html"] || [t isEqualToString: @"multipart/related"] ||
		    [t isEqualToString: @"multipart/mixed"];
		if ((plain && isPlain) || (!plain && isHTML))
			best = c;
		else if (isPlain || isHTML)
			other = c;
	}
	return best ? best : other;
}

- (void) walk: (struct mailmime *)m plain: (BOOL)plain
{
	clistiter *it;
	if (m == NULL)
		return;
	switch (m->mm_type) {
	case MAILMIME_MESSAGE:
		if (m->mm_parent == NULL) {
			[self walk: m->mm_data.mm_message.mm_msg_mime plain: plain];
			return;
		}
		/* a forwarded message inside: offered as a file */
		[attachments addObject: [[[Mail2Attachment alloc] initWithName: @"message.eml" type: @"message/rfc822"
		    data: [NSData dataWithBytes: m->mm_mime_start length: m->mm_length]] autorelease]];
		return;
	case MAILMIME_MULTIPLE: {
		NSString *t = content_type(m->mm_content_type);
		if ([t isEqualToString: @"multipart/alternative"]) {
			[self walk: choose_alternative(m, plain) plain: plain];
			return;
		}
		for (it = clist_begin(m->mm_data.mm_multipart.mm_mp_list); it != NULL; it = clist_next(it))
			[self walk: clist_content(it) plain: plain];
		return;
	}
	case MAILMIME_SINGLE: {
		struct mailmime_single_fields sf;
		NSString *t = content_type(m->mm_content_type);
		mailmime_single_fields_init(&sf, m->mm_mime_fields, m->mm_content_type);
		const char *fname = sf.fld_disposition_filename ? sf.fld_disposition_filename : sf.fld_content_name;
		BOOL attached = sf.fld_disposition && sf.fld_disposition->dsp_type &&
		    sf.fld_disposition->dsp_type->dsp_type == MAILMIME_DISPOSITION_TYPE_ATTACHMENT;
		BOOL isText = [t isEqualToString: @"text/plain"] || [t isEqualToString: @"text/html"];
		if (isText && !attached && fname == NULL) {
			[self addText: text_of(decode_part(m), sf.fld_content_charset) html: [t isEqualToString: @"text/html"]];
			return;
		}
		/* inline images of an HTML body (Content-ID, no name): not files, but kept for the web view's cid: URLs */
		if (!attached && fname == NULL && sf.fld_id != NULL && [t hasPrefix: @"image/"]) {
			if (inlineParts == nil)
				inlineParts = [[NSMutableDictionary alloc] init];
			[inlineParts setObject: [[[Mail2Attachment alloc] initWithName: @"" type: t data: decode_part(m)] autorelease]
			    forKey: [NSString stringWithUTF8String: sf.fld_id]];
			return;
		}
		NSString *name = fname ? Mail2DecodeHeader(fname) : nil;
		if ([name length] == 0)
			name = [t hasPrefix: @"text/"] ? @"Attachment.txt" : @"Attachment";
		name = [name lastPathComponent];	/* never a path */
		[attachments addObject: [[[Mail2Attachment alloc] initWithName: name type: t data: decode_part(m)] autorelease]];
		return;
	}
	}
}

static NSString *
msgid_string(const char *s)
{
	return s ? [NSString stringWithFormat: @"<%s>", s] : nil;
}

/* "Name <addr>, addr, ..." from a parsed address list (groups flattened) */
static NSString *
format_imf_list(struct mailimf_address_list *l)
{
	NSMutableArray *out = [NSMutableArray array];
	clistiter *it;
	if (l == NULL)
		return @"";
	for (it = clist_begin(l->ad_list); it != NULL; it = clist_next(it)) {
		struct mailimf_address *a = clist_content(it);
		clist *mbs = NULL;
		clistiter *mi;
		if (a->ad_type == MAILIMF_ADDRESS_MAILBOX) {
			mbs = clist_new();
			clist_append(mbs, a->ad_data.ad_mailbox);
		} else if (a->ad_data.ad_group && a->ad_data.ad_group->grp_mb_list)
			mbs = a->ad_data.ad_group->grp_mb_list->mb_list;
		for (mi = mbs ? clist_begin(mbs) : NULL; mi != NULL; mi = clist_next(mi)) {
			struct mailimf_mailbox *mb = clist_content(mi);
			NSString *addr = mb->mb_addr_spec ? [NSString stringWithUTF8String: mb->mb_addr_spec] : @"";
			NSString *name = Mail2DecodeHeader(mb->mb_display_name);
			[out addObject: [name length] ? [NSString stringWithFormat: @"%@ <%@>", name, addr] : addr];
		}
		if (a->ad_type == MAILIMF_ADDRESS_MAILBOX)
			clist_free(mbs);
	}
	return [out componentsJoinedByString: @", "];
}

+ (Mail2ParsedMessage *) parseData: (NSData *)raw preferPlainText: (BOOL)plain
{
	struct mailmime *mime = NULL;
	size_t idx = 0;
	if (raw == nil || mailmime_parse([raw bytes], [raw length], &idx, &mime) != MAILIMF_NO_ERROR || mime == NULL)
		return nil;
	Mail2ParsedMessage *p = [[[Mail2ParsedMessage alloc] init] autorelease];
	p->attachments = [[NSMutableArray alloc] init];
	[p walk: mime plain: plain];
	if (p->body == nil)
		p->body = [@"" retain];
	/* Message-ID and References, for replies */
	if (mime->mm_type == MAILMIME_MESSAGE && mime->mm_data.mm_message.mm_fields) {
		clistiter *it;
		for (it = clist_begin(mime->mm_data.mm_message.mm_fields->fld_list); it != NULL; it = clist_next(it)) {
			struct mailimf_field *f = clist_content(it);
			if (f->fld_type == MAILIMF_FIELD_MESSAGE_ID && f->fld_data.fld_message_id)
				ASSIGN(p->messageId, msgid_string(f->fld_data.fld_message_id->mid_value));
			else if (f->fld_type == MAILIMF_FIELD_REFERENCES && f->fld_data.fld_references) {
				NSMutableArray *refs = [NSMutableArray array];
				clistiter *ri;
				for (ri = clist_begin(f->fld_data.fld_references->mid_list); ri != NULL; ri = clist_next(ri))
					[refs addObject: msgid_string(clist_content(ri))];
				ASSIGN(p->references, refs);
			} else if (f->fld_type == MAILIMF_FIELD_IN_REPLY_TO && f->fld_data.fld_in_reply_to &&
			           clist_begin(f->fld_data.fld_in_reply_to->mid_list))
				ASSIGN(p->inReplyTo, msgid_string(clist_content(clist_begin(f->fld_data.fld_in_reply_to->mid_list))));
			else if (f->fld_type == MAILIMF_FIELD_BCC && f->fld_data.fld_bcc)
				ASSIGN(p->bcc, format_imf_list(f->fld_data.fld_bcc->bcc_addr_list));
		}
	}
	mailmime_free(mime);
	return p;
}

- (NSString *) body { return body; }
- (NSString *) htmlSource { return htmlSource; }
- (NSDictionary *) inlineParts { return inlineParts; }
- (BOOL) bodyWasHTML { return html; }
- (NSArray *) attachments { return attachments; }
- (NSString *) messageId { return messageId; }
- (NSArray *) references { return references; }
- (NSString *) inReplyTo { return inReplyTo; }
- (NSString *) bcc { return bcc; }

- (NSString *) snippet
{
	NSMutableString *s = [NSMutableString string];
	NSEnumerator *e = [[body componentsSeparatedByString: @"\n"] objectEnumerator];
	NSString *l;
	while ((l = [e nextObject]) != nil && [s length] < 200) {
		l = [l stringByTrimmingCharactersInSet: [NSCharacterSet whitespaceCharacterSet]];
		if ([l length] == 0 || [l hasPrefix: @">"])
			continue;
		/* "On <date>, X wrote:" before a quote ends the new text */
		if ([l hasSuffix: @"wrote:"] && [l hasPrefix: @"On "])
			break;
		if ([s length])
			[s appendString: @" "];
		[s appendString: l];
	}
	return [s length] > 200 ? [s substringToIndex: 200] : s;
}

@end

/* ---- building ---- */

static char *
dup_utf8(NSString *s)
{
	return s ? strdup([s UTF8String]) : NULL;
}

/* "Name <addr>" or "addr" as a mailbox, the name RFC 2047-encoded when needed */
static struct mailimf_mailbox *
make_mailbox(NSString *s)
{
	NSString *addr = Mail2AddressPart(s);
	NSString *name = nil;
	NSRange lt = [s rangeOfString: @"<" options: NSBackwardsSearch];
	if ([addr rangeOfString: @"@"].location == NSNotFound || [addr rangeOfCharacterFromSet: [NSCharacterSet whitespaceCharacterSet]].location != NSNotFound)
		return NULL;
	if (lt.location != NSNotFound && lt.location > 0) {
		name = [[s substringToIndex: lt.location] stringByTrimmingCharactersInSet: [NSCharacterSet whitespaceCharacterSet]];
		if ([name hasPrefix: @"\""] && [name hasSuffix: @"\""] && [name length] >= 2)
			name = [name substringWithRange: NSMakeRange(1, [name length] - 2)];
		if ([name length] == 0)
			name = nil;
	}
	return mailimf_mailbox_new(dup_utf8(Mail2EncodeHeader(name)), dup_utf8(addr));
}

static struct mailimf_address_list *
make_address_list(NSArray *addrs, BOOL *bad)
{
	struct mailimf_address_list *l;
	NSEnumerator *e = [addrs objectEnumerator];
	NSString *a;
	if ([addrs count] == 0)
		return NULL;
	l = mailimf_address_list_new_empty();
	while ((a = [e nextObject]) != nil) {
		struct mailimf_mailbox *mb = make_mailbox(a);
		if (mb == NULL) {
			*bad = YES;
			continue;
		}
		mailimf_address_list_add(l, mailimf_address_new(MAILIMF_ADDRESS_MAILBOX, mb, NULL));
	}
	return l;
}

/* "<id>" -> "id", which is how libetpan keeps message ids */
static char *
bare_msgid(NSString *s)
{
	s = [s stringByTrimmingCharactersInSet: [NSCharacterSet characterSetWithCharactersInString: @"<> \t"]];
	return [s length] ? dup_utf8(s) : NULL;
}

NSString *
Mail2MimeTypeForFilename(NSString *name)
{
	static NSDictionary *types;
	if (types == nil)
		types = [[NSDictionary alloc] initWithObjectsAndKeys:
		    @"application/pdf", @"pdf", @"image/png", @"png", @"image/jpeg", @"jpg", @"image/jpeg", @"jpeg",
		    @"image/gif", @"gif", @"image/tiff", @"tiff", @"image/tiff", @"tif", @"image/webp", @"webp",
		    @"image/svg+xml", @"svg", @"text/plain", @"txt", @"text/plain", @"log", @"text/plain", @"md",
		    @"text/html", @"html", @"text/html", @"htm", @"text/csv", @"csv", @"text/calendar", @"ics",
		    @"text/vcard", @"vcf", @"application/zip", @"zip", @"application/gzip", @"gz", @"application/x-tar", @"tar",
		    @"application/json", @"json", @"application/xml", @"xml", @"message/rfc822", @"eml",
		    @"audio/mpeg", @"mp3", @"video/mp4", @"mp4", @"application/msword", @"doc",
		    @"application/vnd.openxmlformats-officedocument.wordprocessingml.document", @"docx",
		    @"application/vnd.ms-excel", @"xls",
		    @"application/vnd.openxmlformats-officedocument.spreadsheetml.sheet", @"xlsx",
		    @"application/vnd.openxmlformats-officedocument.presentationml.presentation", @"pptx", nil];
	NSString *t = [types objectForKey: [[name pathExtension] lowercaseString]];
	return t ? t : @"application/octet-stream";
}

NSString *
Mail2NewMessageID(NSString *fromAddress)
{
	NSString *addr = Mail2AddressPart(fromAddress ? fromAddress : @"");
	NSRange at = [addr rangeOfString: @"@" options: NSBackwardsSearch];
	NSString *host = at.location != NSNotFound ? [addr substringFromIndex: at.location + 1] : @"mail2.local";
	return [NSString stringWithFormat: @"<%@.mail2@%@>", [[NSProcessInfo processInfo] globallyUniqueString], host];
}

/* an attachment part: base64, with its file name (RFC 2047-encoded when it is not ASCII, which mail programs read) */
static struct mailmime *
attachment_part(Mail2Attachment *a)
{
	NSString *type = [[a mimeType] length] ? [a mimeType] : Mail2MimeTypeForFilename([a filename]);
	struct mailmime_content *ct = mailmime_content_new_with_str([type UTF8String]);
	if (ct == NULL)
		ct = mailmime_content_new_with_str("application/octet-stream");
	NSString *name = Mail2EncodeHeader([a filename] ? [a filename] : @"Attachment");
	clist_append(ct->ct_parameters, mailmime_param_new_with_data(strdup("name"), dup_utf8(name)));
	struct mailmime_fields *mf = mailmime_fields_new_filename(MAILMIME_DISPOSITION_TYPE_ATTACHMENT, dup_utf8(name),
	    MAILMIME_MECHANISM_BASE64);
	struct mailmime *part = mailmime_new_empty(ct, mf);
	mailmime_set_body_text(part, (char *)[[a data] bytes], [[a data] length]);	/* not copied: a outlives the write */
	return part;
}

NSData *
Mail2BuildMessageEx(NSString *from, NSArray *to, NSArray *cc, NSArray *bccHeader, NSString *subject, NSString *body,
    NSString *inReplyTo, NSArray *references, NSArray *attachments, NSString *messageId)
{
	BOOL bad = NO;
	struct mailimf_mailbox *fromMb = make_mailbox(from);
	if (fromMb == NULL)
		return nil;
	struct mailimf_mailbox_list *fromList = mailimf_mailbox_list_new_empty();
	mailimf_mailbox_list_add(fromList, fromMb);
	struct mailimf_address_list *toList = make_address_list(to, &bad);
	struct mailimf_address_list *ccList = make_address_list(cc, &bad);
	struct mailimf_address_list *bccList = make_address_list(bccHeader, &bad);
	clist *irt = NULL, *refs = NULL;
	char *m;
	if (inReplyTo != nil && (m = bare_msgid(inReplyTo)) != NULL) {
		irt = clist_new();
		clist_append(irt, m);
	}
	if ([references count] > 0) {
		NSEnumerator *e = [references objectEnumerator];
		NSString *r;
		refs = clist_new();
		while ((r = [e nextObject]) != nil)
			if ((m = bare_msgid(r)) != NULL)
				clist_append(refs, m);
	}
	char *mid = messageId ? bare_msgid(messageId) : NULL;
	if (mid == NULL)
		mid = bare_msgid(Mail2NewMessageID(from));
	struct mailimf_fields *fields = mailimf_fields_new_with_data_all(mailimf_get_current_date(), fromList, NULL, NULL,
	    toList, ccList, bccList, mid, irt, refs,
	    dup_utf8(Mail2EncodeHeader([subject length] ? subject : @"")));
	mailimf_fields_add(fields, mailimf_field_new_custom(strdup("User-Agent"), strdup("Mail2/0.2 (GNUstep)")));

	/* the body: lines end in CRLF on the wire */
	NSString *crlf = [[(body ? body : @"") stringByReplacingOccurrencesOfString: @"\r\n" withString: @"\n"]
	    stringByReplacingOccurrencesOfString: @"\n" withString: @"\r\n"];
	NSData *text = [crlf dataUsingEncoding: NSUTF8StringEncoding];
	struct mailmime_content *ct = mailmime_content_new_with_str("text/plain");
	clist_append(ct->ct_parameters, mailmime_param_new_with_data(strdup("charset"), strdup("utf-8")));
	struct mailmime *part = mailmime_new_empty(ct, mailmime_fields_new_encoding(MAILMIME_MECHANISM_QUOTED_PRINTABLE));
	mailmime_set_body_text(part, (char *)[text bytes], [text length]);	/* not copied: text outlives the write */
	struct mailmime *msg = mailmime_new_message_data(NULL);
	mailmime_set_imf_fields(msg, fields);
	if ([attachments count] == 0)
		mailmime_smart_add_part(msg, part);
	else {
		/* multipart/mixed: the text, then each file */
		struct mailmime *mixed = mailmime_multiple_new("multipart/mixed");
		NSEnumerator *e = [attachments objectEnumerator];
		Mail2Attachment *a;
		mailmime_smart_add_part(mixed, part);
		while ((a = [e nextObject]) != nil)
			mailmime_smart_add_part(mixed, attachment_part(a));
		mailmime_smart_add_part(msg, mixed);
	}

	MMAPString *out = mmap_string_new("");
	int col = 0;
	NSData *r = nil;
	if (mailmime_write_mem(out, &col, msg) == MAILIMF_NO_ERROR)
		r = [NSData dataWithBytes: out->str length: out->len];
	mmap_string_free(out);
	mailmime_free(msg);
	return bad ? nil : r;
}

NSData *
Mail2BuildMessage(NSString *from, NSArray *to, NSArray *cc, NSString *subject, NSString *body,
    NSString *inReplyTo, NSArray *references)
{
	return Mail2BuildMessageEx(from, to, cc, nil, subject, body, inReplyTo, references, nil, nil);
}
