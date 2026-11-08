/* Mail2Sieve: Mail2's rules (Mail2Rules.h) and blocked senders on the server, as a Sieve script (RFC 5228, with
 * fileinto and imap4flags) put there over ManageSieve (RFC 5804, port 4190), so that they run on mail even while Mail2
 * is closed. The script is named "mail2" and made the active one, replacing whatever script was active before.
 * Servers with ManageSieve: Dovecot (most hosts), Fastmail, Proton Bridge; not Gmail or iCloud. */
#import <Foundation/Foundation.h>
#import "Mail2Account.h"

/* the script for an account: blocked senders to its Trash, then its rules in order (a move stops) */
NSString *Mail2SieveScript(NSArray *rules, NSString *account, NSArray *blocked, NSString *trashName);
/* uploads and activates it; blocking (a background queue). NO with *err when the server has no ManageSieve or says no. */
BOOL Mail2SieveUpload(Mail2Account *a, NSString *script, NSString **err);
