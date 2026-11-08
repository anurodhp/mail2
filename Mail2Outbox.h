/* Mail2Outbox: messages on their way out, kept in ~/GNUstep/Library/Mail2/Outbox (the message as an .eml and its
 * details in a .plist beside it), so none is lost to a closed Mail2 or a missing network.
 *
 * Send puts a message here to go a few seconds later (Mail2UndoSendDelay, 5; 0 sends at once): until then Undo Send
 * takes it back. Send Later puts it here for a chosen time. A timer on the main thread sends what is due through the
 * account's session; a failure stays, with its reason, and is tried again after 30 s, 2, 5, then every 15 minutes.
 * Posts Mail2OutboxChanged (main thread) whenever an item comes, goes or changes. Main thread only. */
#import <Foundation/Foundation.h>

extern NSString *const Mail2OutboxChanged;

/* the item's details: Id, Account (identifier), Recipients, Bcc, SendAt (NSDate), Draft (Message-ID of the draft it
 * came from), ReplyTo (the rowid of the message answered), Subject, To, Error (the last failure), Undoable (YES while
 * the Undo Send moment lasts) */
@interface Mail2Outbox : NSObject
{
	NSMutableArray *items;		/* dictionaries, oldest first */
	NSTimer *timer;
	NSMutableSet *sending;		/* ids being sent */
	id (^sessionFor)(NSString *account);
}
+ (Mail2Outbox *) shared;
/* how to reach an account's session (Mail2Session), given by the application */
- (void) setSessionLookup: (id (^)(NSString *account))lookup;
- (NSString *) add: (NSData *)raw details: (NSDictionary *)details;
- (NSArray *) items;
- (NSData *) messageFor: (NSString *)ident;
- (NSDictionary *) itemFor: (NSString *)ident;
/* takes it out without sending: its message and details for the compose window (nil if it is already going) */
- (NSDictionary *) takeBack: (NSString *)ident;
- (void) sendNow: (NSString *)ident;
- (void) tick;			/* sends what is due (the timer calls it) */
- (BOOL) isSending: (NSString *)ident;
@end
