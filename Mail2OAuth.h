/* Mail2OAuth: OAuth 2.0 for Google and Microsoft accounts, for IMAP and SMTP's XOAUTH2.
 *
 * Signing in (once, from the account panel):
 *   Google     the authorization-code flow with PKCE in the browser (Florence), redirected to a one-time listener on
 *              127.0.0.1 -- Google's "desktop app" flow. (Google does not allow its mail scope in the device flow.)
 *   Microsoft  the device-code flow: a short code to enter at microsoft.com/devicelogin, on this machine or any other.
 * Both end with a refresh token, kept in Accounts.plist (mode 600) like a password. Access tokens are asked for with
 * it when needed and kept in memory until a minute before they expire.
 *
 * The client IDs are the user's own (registered with Google Cloud and Microsoft Entra, see README): defaults
 * Mail2GoogleClientID and Mail2GoogleClientSecret, Mail2MicrosoftClientID. The endpoints can be changed with
 * Mail2GoogleAuthURL, Mail2GoogleTokenURL, Mail2MicrosoftDeviceURL, Mail2MicrosoftTokenURL (the tests do).
 *
 * Every call that touches the network blocks: never on the main thread. */
#import <Foundation/Foundation.h>
#import "Mail2Account.h"

@interface Mail2OAuth : NSObject
/* nil when the provider's client ID is set, else what to tell the user */
+ (NSString *) missingClientMessage: (Mail2Auth)provider;
+ (NSString *) providerName: (Mail2Auth)provider;

/* A valid access token for the account, refreshed if needed; nil with *err when that fails (then the account has to
 * sign in again). A refresh that returns a new refresh token stores it in the account and posts Mail2AccountChanged on
 * the main thread. Thread-safe. */
+ (NSString *) accessTokenForAccount: (Mail2Account *)a error: (NSString **)err;
/* after the server refused a token */
+ (void) forgetAccessTokenForAccount: (Mail2Account *)a;

/* The sign-in. prompt (main thread) is told what the user has to do: open url (Google: opened for them as well), or
 * for Microsoft enter code at url. Writing to cancelFd's other end cancels. On success the account gets its refresh
 * token and the access token is cached; returns NO with *err otherwise. */
+ (BOOL) signIn: (Mail2Account *)a prompt: (void (^)(NSString *message, NSString *url, NSString *code))prompt
       cancelFd: (int)cancelFd error: (NSString **)err;
@end

/* An HTTP(S) POST of a form, the answer parsed as JSON (an error status still returns the body: OAuth errors are
 * JSON; an answer that is not JSON gives an empty dictionary, with *status). nil with *err when there is no answer.
 * Used by Mail2OAuth and the one-click unsubscribe. */
NSDictionary *Mail2PostForm(NSString *url, NSDictionary *form, int *status, NSString **err);
