/* Mail2AccountPanel: adding or editing an account. The servers are filled in from the address (Gmail, iCloud,
 * Fastmail, Yahoo, Outlook.com, else imap./smtp. on its domain) and can be changed. "Sign in with" is a password or
 * OAuth with Google or Microsoft (Mail2OAuth: the browser, or a code to enter). Sign In logs in to the IMAP server
 * before the account is saved, so a wrong password or server is reported here and not later.
 *
 * Mail2AccountsWindow: Mail2 > Accounts…, the list of accounts with Add, Edit and Remove. */
#import <AppKit/AppKit.h>
#import "Mail2Account.h"

@interface Mail2AccountPanel : NSObject
{
	NSPanel *panel;
	NSTextField *nameField, *emailField, *imapHost, *imapPort, *imapUser, *smtpHost, *smtpPort, *smtpUser;
	NSSecureTextField *passField;
	NSPopUpButton *imapSec, *smtpSec, *authPopup;
	BOOL authChosen;		/* the user picked the sign-in method: the address no longer decides it */
	Mail2Account *existing;
	int cancelPipe[2];
	void (^completion)(Mail2Account *);
	NSTextField *message;
	NSTextView *sigView;
	NSButton *okButton, *cancelButton;
	NSString *autoDomain;
	BOOL testing;
	Mail2Account *result;
}
/* Shows the panel (one at a time); done gets the account to save, or nil if cancelled. `existing` fills the fields
 * for editing. */
+ (void) showForAccount: (Mail2Account *)existing completion: (void (^)(Mail2Account *a))done;
@end

/* what the accounts window asks of its owner (the application) */
@protocol Mail2AccountsOwner
- (NSArray *) accounts;
- (void) addAccount: (id)sender;
- (void) editAccountAtIndex: (NSUInteger)i;
- (void) removeAccountAtIndex: (NSUInteger)i;
@end

@interface Mail2AccountsWindow : NSObject
{
	NSPanel *panel;
	NSTableView *table;
	NSButton *editButton, *removeButton;
	id owner;
}
- (id) initWithOwner: (id)o;
- (void) show;
- (void) reload;
@end
