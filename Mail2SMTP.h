/* Mail2SMTP: sends one message through the account's submission server (libetpan's mailsmtp over Mail2TLS).
 * Synchronous: call it off the main thread. */
#import <Foundation/Foundation.h>
#import "Mail2Account.h"

/* recipients: the bare addresses of To, Cc and Bcc. NO with a reason in *err on failure. */
BOOL Mail2SendMessage(Mail2Account *account, NSData *raw, NSArray *recipients, NSString **err);
