/* Mail2AccountPanel: adding or editing an account. The servers are filled in from the address (Gmail, iCloud,
 * Fastmail, Yahoo, else imap./smtp. on its domain) and can be changed. Sign In logs in to the IMAP server before the
 * account is saved, so a wrong password or server is reported here and not later. */
#import <AppKit/AppKit.h>
#import "Mail2Account.h"

@interface Mail2AccountPanel : NSObject
{
	NSPanel *panel;
	NSTextField *nameField, *emailField, *imapHost, *imapPort, *imapUser, *smtpHost, *smtpPort, *smtpUser;
	NSSecureTextField *passField;
	NSPopUpButton *imapSec, *smtpSec;
	NSTextField *message;
	NSButton *okButton, *cancelButton;
	NSString *autoDomain;
	BOOL testing;
	Mail2Account *result;
}
/* modal; the account (saved by the caller) or nil if cancelled. `existing` fills the fields for editing. */
+ (Mail2Account *) runForAccount: (Mail2Account *)existing;
@end
