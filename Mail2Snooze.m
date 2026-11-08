/* Mail2Snooze: snoozed messages and follow-up reminders (see Mail2Snooze.h). */
#import "Mail2Snooze.h"
#import "Mail2Session.h"
#import "Mail2Store.h"
#import "Mail2Util.h"

NSString *const Mail2LaterChanged = @"Mail2LaterChanged";

static NSString *
later_path(void)
{
	return [Mail2SupportDirectory() stringByAppendingPathComponent: @"Later.plist"];
}

@implementation Mail2Later

+ (Mail2Later *) shared
{
	static Mail2Later *l;
	if (l == nil)
		l = [[Mail2Later alloc] init];
	return l;
}

- (id) init
{
	if ((self = [super init]) == nil)
		return nil;
	NSDictionary *d = [NSDictionary dictionaryWithContentsOfFile: later_path()];
	snoozed = [[NSMutableArray alloc] initWithArray: [d objectForKey: @"Snoozed"] ? [d objectForKey: @"Snoozed"] : [NSArray array]];
	followUps = [[NSMutableArray alloc] initWithArray: [d objectForKey: @"FollowUps"] ? [d objectForKey: @"FollowUps"] : [NSArray array]];
	timer = [[NSTimer scheduledTimerWithTimeInterval: 60 target: self selector: @selector(timerFired:) userInfo: nil repeats: YES] retain];
	return self;
}

- (void) setSessionLookup: (id (^)(NSString *))lookup
{
	[sessionFor release];
	sessionFor = [lookup copy];
}

- (void) save
{
	[[NSDictionary dictionaryWithObjectsAndKeys: snoozed, @"Snoozed", followUps, @"FollowUps", nil] writeToFile: later_path() atomically: YES];
	[[NSNotificationCenter defaultCenter] postNotificationName: Mail2LaterChanged object: self];
}

/* ---- snooze ---- */

- (void) snooze: (NSArray *)msgs of: (Mail2Session *)s until: (NSDate *)when
{
	NSEnumerator *e = [msgs objectEnumerator];
	Mail2MessageInfo *m;
	NSMutableArray *movable = [NSMutableArray array];
	while ((m = [e nextObject]) != nil) {
		Mail2Mailbox *from = [[Mail2Store sharedStore] mailboxWithID: [m mbid]];
		if ([m messageId] == nil || from == nil)
			continue;	/* without a Message-ID it could not be found again */
		[snoozed addObject: [NSDictionary dictionaryWithObjectsAndKeys: [[s account] identifier], @"Account",
		    [m messageId], @"MessageId", when, @"Until", [from name], @"From", [m subject] ? [m subject] : @"", @"Subject", nil]];
		[movable addObject: m];
	}
	[self save];
	[s moveMessages: movable toNamedMailbox: @"Snoozed"];
}

- (NSArray *) snoozed { return [NSArray arrayWithArray: snoozed]; }

- (void) wakeItem: (NSDictionary *)d
{
	Mail2Session *s = sessionFor ? sessionFor([d objectForKey: @"Account"]) : nil;
	if (s == nil)
		return;
	[s moveBackFromNamed: @"Snoozed" messageIDs: [NSArray arrayWithObject: [d objectForKey: @"MessageId"]]
	          toNamed: [d objectForKey: @"From"] markUnread: YES];
	[snoozed removeObject: d];
}

- (void) wake: (NSString *)messageId
{
	NSEnumerator *e = [[NSArray arrayWithArray: snoozed] objectEnumerator];
	NSDictionary *d;
	while ((d = [e nextObject]) != nil)
		if ([[d objectForKey: @"MessageId"] isEqualToString: messageId])
			[self wakeItem: d];
	[self save];
}

/* ---- follow-up ---- */

- (void) remindAbout: (NSString *)messageId account: (NSString *)ident subject: (NSString *)subject to: (NSString *)to
               after: (NSTimeInterval)seconds
{
	if (messageId == nil)
		return;
	[followUps addObject: [NSDictionary dictionaryWithObjectsAndKeys: ident, @"Account", messageId, @"MessageId",
	    [NSDate dateWithTimeIntervalSinceNow: seconds], @"Due", subject ? subject : @"", @"Subject", to ? to : @"", @"To", nil]];
	[self save];
}

- (NSArray *) dueFollowUps
{
	NSMutableArray *r = [NSMutableArray array];
	NSEnumerator *e = [followUps objectEnumerator];
	NSDictionary *d;
	while ((d = [e nextObject]) != nil)
		if ([[d objectForKey: @"Due"] timeIntervalSinceNow] <= 0 &&
		    ![[Mail2Store sharedStore] hasReplyTo: [d objectForKey: @"MessageId"]])
			[r addObject: [d objectForKey: @"MessageId"]];
	return r;
}

- (void) stopReminding: (NSString *)messageId
{
	NSEnumerator *e = [[NSArray arrayWithArray: followUps] objectEnumerator];
	NSDictionary *d;
	while ((d = [e nextObject]) != nil)
		if ([[d objectForKey: @"MessageId"] isEqualToString: messageId])
			[followUps removeObject: d];
	[self save];
}

- (void) check
{
	BOOL changed = NO;
	NSEnumerator *e = [[NSArray arrayWithArray: snoozed] objectEnumerator];
	NSDictionary *d;
	while ((d = [e nextObject]) != nil)
		if ([[d objectForKey: @"Until"] timeIntervalSinceNow] <= 0) {
			[self wakeItem: d];
			changed = YES;
		}
	/* a reminder answered meanwhile is done */
	e = [[NSArray arrayWithArray: followUps] objectEnumerator];
	while ((d = [e nextObject]) != nil)
		if ([[Mail2Store sharedStore] hasReplyTo: [d objectForKey: @"MessageId"]]) {
			[followUps removeObject: d];
			changed = YES;
		}
	if (changed)
		[self save];
	else
		[[NSNotificationCenter defaultCenter] postNotificationName: Mail2LaterChanged object: self];
}

- (void) timerFired: (NSTimer *)t { [self check]; }

@end
