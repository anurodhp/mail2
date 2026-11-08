/* Mail2RichText: formatted text to HTML (see Mail2RichText.h). */
#import "Mail2RichText.h"
#import "Mail2Message.h"

NSString *
Mail2EscapeHTML(NSString *s)
{
	NSMutableString *r = [NSMutableString stringWithString: s ? s : @""];
	[r replaceOccurrencesOfString: @"&" withString: @"&amp;" options: 0 range: NSMakeRange(0, [r length])];
	[r replaceOccurrencesOfString: @"<" withString: @"&lt;" options: 0 range: NSMakeRange(0, [r length])];
	[r replaceOccurrencesOfString: @">" withString: @"&gt;" options: 0 range: NSMakeRange(0, [r length])];
	[r replaceOccurrencesOfString: @"\"" withString: @"&quot;" options: 0 range: NSMakeRange(0, [r length])];
	/* runs of spaces keep their width */
	[r replaceOccurrencesOfString: @"  " withString: @" &nbsp;" options: 0 range: NSMakeRange(0, [r length])];
	return r;
}

static NSString *
css_color(NSColor *c)
{
	NSColor *rgb = [c colorUsingColorSpaceName: NSCalibratedRGBColorSpace];
	if (rgb == nil)
		return nil;
	int r = (int)([rgb redComponent] * 255 + 0.5), g = (int)([rgb greenComponent] * 255 + 0.5), b = (int)([rgb blueComponent] * 255 + 0.5);
	if (r < 24 && g < 24 && b < 24)
		return nil;	/* black, the default */
	return [NSString stringWithFormat: @"#%02x%02x%02x", r, g, b];
}

/* the picture of an attachment as PNG or its own file's bytes, with a type and a name */
static Mail2Attachment *
picture_of(NSTextAttachment *ta, int n)
{
	NSFileWrapper *fw = [ta fileWrapper];
	NSData *d = nil;
	NSString *name = nil;
	if (fw != nil && [fw isRegularFile]) {
		d = [fw regularFileContents];
		name = [fw preferredFilename] ? [fw preferredFilename] : [fw filename];
	}
	NSString *type = name ? Mail2MimeTypeForFilename(name) : nil;
	if (d == nil || ![type hasPrefix: @"image/"]) {
		/* pasted: only the cell's image */
		NSImage *img = [(id)[ta attachmentCell] respondsToSelector: @selector(image)] ? [(id)[ta attachmentCell] image] : nil;
		NSBitmapImageRep *rep = img ? [NSBitmapImageRep imageRepWithData: [img TIFFRepresentation]] : nil;
		d = rep ? [rep representationUsingType: NSPNGFileType properties: [NSDictionary dictionary]] : nil;
		name = [NSString stringWithFormat: @"image%d.png", n];
		type = @"image/png";
	}
	if (d == nil)
		return nil;
	Mail2Attachment *a = [[[Mail2Attachment alloc] initWithName: name type: type data: d] autorelease];
	[a setContentId: [NSString stringWithFormat: @"img%d.%@@mail2", n, [[NSProcessInfo processInfo] globallyUniqueString]]];
	return a;
}

/* one line's text (from..to) with its runs */
static void
emit_runs(NSAttributedString *as, NSRange r, NSFont *base, NSMutableString *out, NSMutableArray *images, int *imgCount)
{
	NSUInteger i = r.location, end = NSMaxRange(r);
	NSFontManager *fm = [NSFontManager sharedFontManager];
	while (i < end) {
		NSRange run;
		NSDictionary *at = [as attributesAtIndex: i longestEffectiveRange: &run inRange: NSMakeRange(i, end - i)];
		NSString *t = [[as string] substringWithRange: run];
		NSTextAttachment *ta = [at objectForKey: NSAttachmentAttributeName];
		if (ta != nil) {
			NSUInteger k;
			for (k = 0; k < [t length]; k++) {
				if ([t characterAtIndex: k] != NSAttachmentCharacter)
					continue;
				Mail2Attachment *pic = picture_of(ta, ++*imgCount);
				if (pic == nil)
					continue;
				[images addObject: pic];
				[out appendFormat: @"<img src=\"cid:%@\" alt=\"%@\" style=\"max-width:100%%\">", [pic contentId],
				    Mail2EscapeHTML([pic filename])];
			}
			i = NSMaxRange(run);
			continue;
		}
		NSMutableString *open = [NSMutableString string], *close = [NSMutableString string];
		NSFont *f = [at objectForKey: NSFontAttributeName];
		NSFontTraitMask tr = f ? [fm traitsOfFont: f] : 0;
		NSMutableArray *style = [NSMutableArray array];
		if (f != nil && fabs([f pointSize] - [base pointSize]) >= 0.5)
			[style addObject: [NSString stringWithFormat: @"font-size:%.0fpx", [f pointSize] * 96.0 / 72.0]];
		NSString *col = [at objectForKey: NSForegroundColorAttributeName] ? css_color([at objectForKey: NSForegroundColorAttributeName]) : nil;
		if (col)
			[style addObject: [NSString stringWithFormat: @"color:%@", col]];
		id link = [at objectForKey: NSLinkAttributeName];
		if (link != nil) {
			NSString *href = [link isKindOfClass: [NSURL class]] ? [link absoluteString] : [link description];
			[open appendFormat: @"<a href=\"%@\">", Mail2EscapeHTML(href)];
			[close insertString: @"</a>" atIndex: 0];
		}
		if (tr & NSBoldFontMask) { [open appendString: @"<b>"]; [close insertString: @"</b>" atIndex: 0]; }
		if (tr & NSItalicFontMask) { [open appendString: @"<i>"]; [close insertString: @"</i>" atIndex: 0]; }
		if ([[at objectForKey: NSUnderlineStyleAttributeName] intValue] != 0 && link == nil) {
			[open appendString: @"<u>"];
			[close insertString: @"</u>" atIndex: 0];
		}
		if ([style count]) {
			[open appendFormat: @"<span style=\"%@\">", [style componentsJoinedByString: @";"]];
			[close insertString: @"</span>" atIndex: 0];
		}
		[out appendFormat: @"%@%@%@", open, Mail2EscapeHTML(t), close];
		i = NSMaxRange(run);
	}
}

/* ">" levels at the start of a line, and how many characters they take (with one space after each) */
static int
quote_depth(NSString *l, NSUInteger *skip)
{
	int d = 0;
	NSUInteger i = 0, n = [l length];
	while (i < n) {
		unichar c = [l characterAtIndex: i];
		if (c == '>') { d++; i++; if (i < n && [l characterAtIndex: i] == ' ') i++; }
		else break;
	}
	*skip = i;
	return d;
}

/* 0 none, 1 bullet ("• "), 2 numbered ("12. "); *skip: the marker's length */
static int
list_kind(NSString *l, NSUInteger *skip)
{
	if ([l hasPrefix: @"• "]) { *skip = 2; return 1; }
	NSUInteger i = 0, n = [l length];
	while (i < n && [l characterAtIndex: i] >= '0' && [l characterAtIndex: i] <= '9')
		i++;
	if (i > 0 && i + 1 < n && [l characterAtIndex: i] == '.' && [l characterAtIndex: i + 1] == ' ') {
		*skip = i + 2;
		return 2;
	}
	*skip = 0;
	return 0;
}

NSString *
Mail2HTMLFromRichText(NSAttributedString *as, NSMutableArray *images, NSString **plain)
{
	NSString *t = [as string];
	NSMutableString *out = [NSMutableString stringWithString:
	    @"<html><head><meta charset=\"utf-8\"></head><body style=\"font-family:sans-serif;font-size:14px\">\n"];
	NSFont *base = [NSFont systemFontOfSize: 13];
	NSMutableArray *imgs = images ? images : [NSMutableArray array];
	int imgCount = 0, depth = 0, list = 0;
	NSUInteger start = 0, n = [t length];
	while (start < n || (start == 0 && n == 0)) {
		if (n == 0)
			break;
		NSRange line = [t lineRangeForRange: NSMakeRange(start, 0)];
		NSUInteger contentEnd = NSMaxRange(line);
		while (contentEnd > line.location && ([t characterAtIndex: contentEnd - 1] == '\n' || [t characterAtIndex: contentEnd - 1] == '\r'))
			contentEnd--;
		NSString *l = [t substringWithRange: NSMakeRange(line.location, contentEnd - line.location)];
		NSUInteger qskip = 0, lskip = 0;
		int d = quote_depth(l, &qskip);
		int k = list_kind([l substringFromIndex: qskip], &lskip);
		if (k != list || d != depth) {	/* lists end before a quote level changes */
			if (list)
				[out appendString: list == 1 ? @"</ul>\n" : @"</ol>\n"];
			list = 0;
		}
		for (; depth < d; depth++)
			[out appendString: @"<blockquote type=\"cite\" style=\"margin:0 0 0 0.8ex;border-left:2px solid #2a6bcc;padding-left:1ex\">\n"];
		for (; depth > d; depth--)
			[out appendString: @"</blockquote>\n"];
		if (k != list) {
			[out appendString: k == 1 ? @"<ul>\n" : @"<ol>\n"];
			list = k;
		}
		NSRange body = NSMakeRange(line.location + qskip + lskip, contentEnd - line.location - qskip - lskip);
		NSMutableString *content = [NSMutableString string];
		emit_runs(as, body, base, content, imgs, &imgCount);
		if (list)
			[out appendFormat: @"<li>%@</li>\n", content];
		else
			[out appendFormat: @"<div>%@</div>\n", [content length] ? content : @"<br>"];
		start = NSMaxRange(line);
	}
	if (list)
		[out appendString: list == 1 ? @"</ul>\n" : @"</ol>\n"];
	for (; depth > 0; depth--)
		[out appendString: @"</blockquote>\n"];
	[out appendString: @"</body></html>\n"];
	if (plain)
		*plain = [t stringByReplacingOccurrencesOfString: [NSString stringWithFormat: @"%C", (unichar)NSAttachmentCharacter]
		    withString: @""];
	return out;
}

BOOL
Mail2RichTextHasFormatting(NSAttributedString *as, NSFont *bodyFont)
{
	NSUInteger i = 0, n = [as length];
	NSFontManager *fm = [NSFontManager sharedFontManager];
	while (i < n) {
		NSRange run;
		NSDictionary *at = [as attributesAtIndex: i effectiveRange: &run];
		NSFont *f = [at objectForKey: NSFontAttributeName];
		if ([at objectForKey: NSAttachmentAttributeName] || [at objectForKey: NSLinkAttributeName] ||
		    [[at objectForKey: NSUnderlineStyleAttributeName] intValue] != 0 ||
		    (f && (([fm traitsOfFont: f] & (NSBoldFontMask | NSItalicFontMask)) || fabs([f pointSize] - [bodyFont pointSize]) >= 0.5)) ||
		    ([at objectForKey: NSForegroundColorAttributeName] && css_color([at objectForKey: NSForegroundColorAttributeName])))
			return YES;
		i = NSMaxRange(run);
	}
	/* lists and quotes are plain text too: they need no HTML */
	return NO;
}
