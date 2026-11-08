/* Mail2Rules: rules for new mail (see Mail2Rules.h). */
#import "Mail2Rules.h"
#import "Mail2Util.h"
#include <sys/stat.h>

static NSString *
rules_path(void)
{
	return [Mail2SupportDirectory() stringByAppendingPathComponent: @"Rules.plist"];
}

@implementation Mail2Rule

- (id) init
{
	if ((self = [super init]) != nil)
		enabled = YES;
	return self;
}

- (void) dealloc
{
	[name release]; [account release]; [text release]; [mailbox release];
	[super dealloc];
}

+ (Mail2Rule *) ruleWithPlist: (NSDictionary *)d
{
	Mail2Rule *r = [[[Mail2Rule alloc] init] autorelease];
	r->name = [[d objectForKey: @"Name"] copy];
	r->account = [[d objectForKey: @"Account"] length] ? [[d objectForKey: @"Account"] copy] : nil;
	r->text = [[d objectForKey: @"Contains"] copy];
	r->mailbox = [[d objectForKey: @"Mailbox"] length] ? [[d objectForKey: @"Mailbox"] copy] : nil;
	r->field = [[d objectForKey: @"Field"] intValue];
	r->action = [[d objectForKey: @"Action"] intValue];
	r->enabled = [d objectForKey: @"Enabled"] == nil || [[d objectForKey: @"Enabled"] boolValue];
	return r;
}

- (NSDictionary *) plist
{
	return [NSDictionary dictionaryWithObjectsAndKeys:
	    name ? name : @"", @"Name", account ? account : @"", @"Account", text ? text : @"", @"Contains",
	    mailbox ? mailbox : @"", @"Mailbox", [NSNumber numberWithInt: field], @"Field",
	    [NSNumber numberWithInt: action], @"Action", [NSNumber numberWithBool: enabled], @"Enabled", nil];
}

+ (NSArray *) loadRules
{
	NSMutableArray *r = [NSMutableArray array];
	NSEnumerator *e = [[NSArray arrayWithContentsOfFile: rules_path()] objectEnumerator];
	NSDictionary *d;
	while ((d = [e nextObject]) != nil)
		if ([d isKindOfClass: [NSDictionary class]])
			[r addObject: [Mail2Rule ruleWithPlist: d]];
	return r;
}

+ (BOOL) saveRules: (NSArray *)rules
{
	NSMutableArray *a = [NSMutableArray array];
	NSEnumerator *e = [rules objectEnumerator];
	Mail2Rule *r;
	while ((r = [e nextObject]) != nil)
		[a addObject: [r plist]];
	return [a writeToFile: rules_path() atomically: YES];
}

static BOOL
has(NSString *hay, NSString *needle)
{
	return hay != nil && [hay rangeOfString: needle options: NSCaseInsensitiveSearch | NSDiacriticInsensitiveSearch].location != NSNotFound;
}

- (BOOL) matches: (Mail2MessageInfo *)m account: (NSString *)ident
{
	if (!enabled || [text length] == 0 || (account != nil && ![account isEqualToString: ident]))
		return NO;
	NSString *from = [NSString stringWithFormat: @"%@ %@", [m fromName] ? [m fromName] : @"", [m fromAddr] ? [m fromAddr] : @""];
	NSString *to = [NSString stringWithFormat: @"%@ %@", [m to] ? [m to] : @"", [m cc] ? [m cc] : @""];
	switch (field) {
	case Mail2RuleFrom: return has(from, text);
	case Mail2RuleTo: return has(to, text);
	case Mail2RuleSubject: return has([m subject], text);
	default: return has(from, text) || has(to, text) || has([m subject], text);
	}
}

- (BOOL) endsRun
{
	return action == Mail2RuleMove || action == Mail2RuleTrash;
}

- (NSString *) summary
{
	static NSString *fields[] = { @"From", @"To or Cc", @"Subject", @"From, To or Subject" };
	NSString *what;
	switch (action) {
	case Mail2RuleMove: what = [NSString stringWithFormat: @"Move to %@", mailbox ? Mail2DecodeMailboxName([mailbox UTF8String]) : @"?"]; break;
	case Mail2RuleMarkRead: what = @"Mark as Read"; break;
	case Mail2RuleFlag: what = @"Flag"; break;
	default: what = @"Move to Trash"; break;
	}
	return [NSString stringWithFormat: @"%@ contains “%@” → %@", fields[field <= 3 ? field : 3], text ? text : @"", what];
}

@end

NSArray *
Mail2RulesForAccount(NSString *ident)
{
	NSMutableArray *r = [NSMutableArray array];
	NSEnumerator *e = [[Mail2Rule loadRules] objectEnumerator];
	Mail2Rule *rule;
	while ((rule = [e nextObject]) != nil)
		if (rule->enabled && (rule->account == nil || [rule->account isEqualToString: ident]))
			[r addObject: rule];
	return r;
}
