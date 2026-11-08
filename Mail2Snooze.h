/* Mail2Snooze: snoozed messages and follow-up reminders, both kept in ~/GNUstep/Library/Mail2/Later.plist.
 *
 * Snooze moves a message to the account's "Snoozed" mailbox on the server (made if missing, so other mail programs
 * see it is put away) and brings it back to the mailbox it came from, unread, when its time comes -- found again by
 * Message-ID. Follow-up: a message sent with "Remind me if no reply" is listed in the Follow Up smart mailbox once
 * its day has come and nothing in the index answers it (In-Reply-To or References naming it).
 * A timer on the main thread checks once a minute. Posts Mail2LaterChanged. Main thread only. */
#import <Foundation/Foundation.h>

extern NSString *const Mail2LaterChanged;

@class Mail2Session, Mail2MessageInfo;

@interface Mail2Later : NSObject
{
	NSMutableArray *snoozed;	/* {Account, MessageId, Until, From (mailbox name), Subject} */
	NSMutableArray *followUps;	/* {Account, MessageId, Due, Subject, To} */
	NSTimer *timer;
	id (^sessionFor)(NSString *account);
}
+ (Mail2Later *) shared;
- (void) setSessionLookup: (id (^)(NSString *account))lookup;

/* snoozes these messages of one account until the date */
- (void) snooze: (NSArray *)msgs of: (Mail2Session *)s until: (NSDate *)when;
- (NSArray *) snoozed;
/* brings back now (the Snoozed mailbox's Unsnooze) */
- (void) wake: (NSString *)messageId;

/* a reminder for a message being sent */
- (void) remindAbout: (NSString *)messageId account: (NSString *)ident subject: (NSString *)subject to: (NSString *)to
               after: (NSTimeInterval)seconds;
/* the reminders whose day has come with no reply in the index: their Message-IDs */
- (NSArray *) dueFollowUps;
- (void) stopReminding: (NSString *)messageId;
- (void) check;
@end
