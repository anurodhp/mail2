/* Mail2Outbox: messages on their way out (see Mail2Outbox.h). */
#import "Mail2Outbox.h"
#import "Mail2Session.h"
#import "Mail2Store.h"
#import "Mail2Util.h"

NSString *const Mail2OutboxChanged = @"Mail2OutboxChanged";

static NSString *
outbox_dir(void)
{
	NSString *d = [Mail2SupportDirectory() stringByAppendingPathComponent: @"Outbox"];
	[[NSFileManager defaultManager] createDirectoryAtPath: d withIntermediateDirectories: YES attributes: nil error: NULL];
	return d;
}

static NSString *
path_for(NSString *ident, NSString *ext)
{
	return [outbox_dir() stringByAppendingPathComponent: [ident stringByAppendingPathExtension: ext]];
}

@implementation Mail2Outbox

+ (Mail2Outbox *) shared
{
	static Mail2Outbox *o;
	if (o == nil)
		o = [[Mail2Outbox alloc] init];
	return o;
}

- (id) init
{
	if ((self = [super init]) == nil)
		return nil;
	items = [[NSMutableArray alloc] init];
	sending = [[NSMutableSet alloc] init];
	/* what a previous run left: sent in turn (an Undo moment that was cut short simply goes) */
	NSEnumerator *e = [[[[NSFileManager defaultManager] contentsOfDirectoryAtPath: outbox_dir() error: NULL]
	    sortedArrayUsingSelector: @selector(compare:)] objectEnumerator];
	NSString *f;
	while ((f = [e nextObject]) != nil) {
		if (![[f pathExtension] isEqualToString: @"plist"])
			continue;
		NSMutableDictionary *d = [NSMutableDictionary dictionaryWithContentsOfFile: [outbox_dir() stringByAppendingPathComponent: f]];
		if (d == nil || ![[NSFileManager defaultManager] fileExistsAtPath: path_for([d objectForKey: @"Id"], @"eml")])
			continue;
		[d removeObjectForKey: @"Undoable"];
		[items addObject: d];
	}
	[items sortUsingComparator: ^NSComparisonResult(id a, id b) {
		return [[a objectForKey: @"SendAt"] compare: [b objectForKey: @"SendAt"]];
	}];
	timer = [[NSTimer scheduledTimerWithTimeInterval: 1.0 target: self selector: @selector(timerFired:) userInfo: nil repeats: YES] retain];
	return self;
}

- (void) setSessionLookup: (id (^)(NSString *))lookup
{
	[sessionFor release];
	sessionFor = [lookup copy];
}

- (void) changed
{
	[[NSNotificationCenter defaultCenter] postNotificationName: Mail2OutboxChanged object: self];
}

- (void) save: (NSDictionary *)d
{
	[d writeToFile: path_for([d objectForKey: @"Id"], @"plist") atomically: YES];
}

- (NSString *) add: (NSData *)raw details: (NSDictionary *)details
{
	NSString *ident = [NSString stringWithFormat: @"%.0f-%@", [[NSDate date] timeIntervalSince1970] * 1000,
	    [[NSProcessInfo processInfo] globallyUniqueString]];
	NSMutableDictionary *d = [NSMutableDictionary dictionaryWithDictionary: details];
	[d setObject: ident forKey: @"Id"];
	if ([d objectForKey: @"SendAt"] == nil)
		[d setObject: [NSDate date] forKey: @"SendAt"];
	if (![raw writeToFile: path_for(ident, @"eml") atomically: YES])
		return nil;
	[self save: d];
	[items addObject: d];
	[self changed];
	[self tick];
	return ident;
}

- (NSArray *) items { return [NSArray arrayWithArray: items]; }

- (NSMutableDictionary *) find: (NSString *)ident
{
	NSEnumerator *e = [items objectEnumerator];
	NSMutableDictionary *d;
	while ((d = [e nextObject]) != nil)
		if ([[d objectForKey: @"Id"] isEqualToString: ident])
			return d;
	return nil;
}

- (NSDictionary *) itemFor: (NSString *)ident { return [self find: ident]; }

- (NSData *) messageFor: (NSString *)ident
{
	return [NSData dataWithContentsOfFile: path_for(ident, @"eml")];
}

- (void) drop: (NSString *)ident
{
	NSMutableDictionary *d = [self find: ident];
	if (d != nil)
		[items removeObjectIdenticalTo: d];
	[[NSFileManager defaultManager] removeItemAtPath: path_for(ident, @"eml") error: NULL];
	[[NSFileManager defaultManager] removeItemAtPath: path_for(ident, @"plist") error: NULL];
}

- (NSDictionary *) takeBack: (NSString *)ident
{
	NSMutableDictionary *d = [self find: ident];
	NSData *raw = [self messageFor: ident];
	if (d == nil || raw == nil || [sending containsObject: ident])
		return nil;
	NSMutableDictionary *r = [NSMutableDictionary dictionaryWithDictionary: d];
	[r setObject: raw forKey: @"Message"];
	[self drop: ident];
	[self changed];
	return r;
}

- (void) sendNow: (NSString *)ident
{
	NSMutableDictionary *d = [self find: ident];
	if (d == nil)
		return;
	[d setObject: [NSDate date] forKey: @"SendAt"];
	[d removeObjectForKey: @"NextTry"];
	[d removeObjectForKey: @"Undoable"];
	[self save: d];
	[self tick];
}

static NSTimeInterval
backoff(int attempts)
{
	static const NSTimeInterval steps[] = { 30, 120, 300 };
	return attempts <= 3 ? steps[attempts - 1] : 900;
}

- (void) timerFired: (NSTimer *)t
{
	/* the Undo moment ends when the item is due */
	NSEnumerator *e = [items objectEnumerator];
	NSMutableDictionary *d;
	BOOL changed = NO;
	while ((d = [e nextObject]) != nil)
		if ([d objectForKey: @"Undoable"] && [[d objectForKey: @"SendAt"] timeIntervalSinceNow] <= 0) {
			[d removeObjectForKey: @"Undoable"];
			changed = YES;
		}
	if (changed)
		[self changed];
	[self tick];
}

- (void) tick
{
	NSArray *now = [NSArray arrayWithArray: items];
	NSEnumerator *e = [now objectEnumerator];
	NSMutableDictionary *d;
	while ((d = [e nextObject]) != nil) {
		NSString *ident = [d objectForKey: @"Id"];
		NSDate *due = [d objectForKey: @"NextTry"] ? [d objectForKey: @"NextTry"] : [d objectForKey: @"SendAt"];
		if ([sending containsObject: ident] || [due timeIntervalSinceNow] > 0)
			continue;
		Mail2Session *s = sessionFor ? sessionFor([d objectForKey: @"Account"]) : nil;
		NSData *raw = [self messageFor: ident];
		if (s == nil || raw == nil)
			continue;
		[sending addObject: ident];
		NSArray *rcpts = [d objectForKey: @"Recipients"];
		Mail2MessageInfo *orig = [d objectForKey: @"ReplyTo"] ?
		    [[Mail2Store sharedStore] messageWithRowID: [[d objectForKey: @"ReplyTo"] longLongValue]] : nil;
		NSString *draft = [[d objectForKey: @"Draft"] copy];
		[s sendMessage: raw recipients: rcpts replyingTo: orig completion: ^(NSString *err) {
			[sending removeObject: ident];
			NSMutableDictionary *cur = [self find: ident];
			if (err == nil) {
				[self drop: ident];
				if (draft)
					[s deleteDraft: draft];
			} else if (cur != nil) {
				int attempts = [[cur objectForKey: @"Attempts"] intValue] + 1;
				[cur setObject: [NSNumber numberWithInt: attempts] forKey: @"Attempts"];
				[cur setObject: err forKey: @"Error"];
				[cur setObject: [NSDate dateWithTimeIntervalSinceNow: backoff(attempts)] forKey: @"NextTry"];
				[self save: cur];
				NSLog(@"mail2: outbox: not sent, again in %.0f s: %@", backoff(attempts), err);
			}
			[draft release];
			[self changed];
		}];
		[self changed];
	}
}

- (BOOL) isSending: (NSString *)ident { return [sending containsObject: ident]; }

@end
