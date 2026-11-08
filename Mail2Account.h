/* Mail2Account: one mail account's settings, kept in ~/GNUstep/Library/Mail2/Accounts.plist (mode 0600: it holds the
 * password, there being no keychain on this system). */
#import <Foundation/Foundation.h>

typedef enum { Mail2SecurityTLS = 0, Mail2SecuritySTARTTLS = 1, Mail2SecurityNone = 2 } Mail2Security;
/* how the account logs in: a password (or app password), or OAuth 2.0 (XOAUTH2) with Google or Microsoft */
typedef enum { Mail2AuthPassword = 0, Mail2AuthGoogle = 1, Mail2AuthMicrosoft = 2 } Mail2Auth;

@interface Mail2Account : NSObject
{
	NSString *identifier, *fullName, *email, *password;
	NSString *imapHost, *imapUser, *smtpHost, *smtpUser;
	int imapPort, smtpPort;
	Mail2Security imapSecurity, smtpSecurity;
	Mail2Auth auth;
	NSString *refreshToken;		/* OAuth: kept in Accounts.plist like the password */
	NSString *signature;
}
/* the OAuth provider for an address (gmail.com: Google; outlook.com, hotmail.com, live.com, msn.com: Microsoft), else
 * Mail2AuthPassword */
+ (Mail2Auth) oauthProviderForEmail: (NSString *)email;
/* settings guessed from the address: Gmail, iCloud, Fastmail, Yahoo, else imap./smtp. on the domain */
+ (Mail2Account *) accountForEmail: (NSString *)email;
+ (NSArray *) loadAccounts;
+ (BOOL) saveAccounts: (NSArray *)accounts;

- (NSString *) identifier;	/* stable: the folder name of its Maildirs and its key in the index */
- (NSString *) fullName;
- (NSString *) email;
- (NSString *) password;
- (NSString *) imapHost;
- (NSString *) imapUser;
- (int) imapPort;
- (Mail2Security) imapSecurity;
- (NSString *) smtpHost;
- (NSString *) smtpUser;
- (int) smtpPort;
- (Mail2Security) smtpSecurity;
/* "Full Name <email>" */
- (NSString *) fromAddress;

- (void) setFullName: (NSString *)s;
- (void) setEmail: (NSString *)s;
- (void) setPassword: (NSString *)s;
- (void) setImapHost: (NSString *)s;
- (void) setImapUser: (NSString *)s;
- (void) setImapPort: (int)p;
- (void) setImapSecurity: (Mail2Security)s;
- (void) setSmtpHost: (NSString *)s;
- (void) setSmtpUser: (NSString *)s;
- (void) setSmtpPort: (int)p;
- (void) setSmtpSecurity: (Mail2Security)s;
- (Mail2Auth) auth;
- (void) setAuth: (Mail2Auth)a;
- (NSString *) refreshToken;
- (void) setRefreshToken: (NSString *)t;
- (BOOL) usesOAuth;
- (NSString *) signature;	/* added under "-- " to new messages, replies and forwards; nil or empty for none */
- (void) setSignature: (NSString *)s;
@end

/* posted (main thread) when a background refresh changed an account's saved settings (a new refresh token) */
extern NSString *const Mail2AccountChanged;
