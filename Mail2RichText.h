/* Mail2RichText: the compose window's formatted text as the HTML of a message.
 *
 * Paragraph by paragraph: lines starting with ">" become nested <blockquote type="cite"> (replies quote that way),
 * lines starting with "• " or "1. " become list items, the rest <div>s. Within a line: bold, italic, underline, a size
 * other than the body's, a colour other than black, and links; pictures (NSTextAttachment) become <img src="cid:...">
 * with the picture returned as a Mail2Attachment carrying its Content-ID. */
#import <AppKit/AppKit.h>

/* images (out, may be nil): the inline pictures in order; plain (out, may be nil): the text without pictures */
NSString *Mail2HTMLFromRichText(NSAttributedString *as, NSMutableArray *images, NSString **plain);
/* whether the text has anything plain text would lose (formatting, links, pictures) */
BOOL Mail2RichTextHasFormatting(NSAttributedString *as, NSFont *bodyFont);
/* "&", "<", ">", '"' as entities */
NSString *Mail2EscapeHTML(NSString *s);
