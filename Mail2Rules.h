/* Mail2Rules: rules for new mail, kept in ~/GNUstep/Library/Mail2/Rules.plist. A rule applies to messages arriving in
 * an Inbox (not to the first sync's backlog, as in Apple Mail): when its field contains its text (case and accents
 * ignored), it moves the message to a mailbox, marks it read, flags it, or moves it to the Trash. Rules run in their
 * order; a move ends the run for that message. Message > Apply Rules runs them on the selection by hand. */
#import <Foundation/Foundation.h>
#import "Mail2Store.h"

typedef enum { Mail2RuleFrom = 0, Mail2RuleTo = 1, Mail2RuleSubject = 2, Mail2RuleAny = 3 } Mail2RuleField;
typedef enum { Mail2RuleMove = 0, Mail2RuleMarkRead = 1, Mail2RuleFlag = 2, Mail2RuleTrash = 3 } Mail2RuleAction;

@interface Mail2Rule : NSObject
{
@public
	NSString *name, *account, *text, *mailbox;	/* account: an identifier, or nil for every account; mailbox: IMAP name */
	Mail2RuleField field;
	Mail2RuleAction action;
	BOOL enabled;
}
+ (NSArray *) loadRules;
+ (BOOL) saveRules: (NSArray *)rules;
- (NSDictionary *) plist;
+ (Mail2Rule *) ruleWithPlist: (NSDictionary *)d;
/* the rule's condition, for a message of the given account */
- (BOOL) matches: (Mail2MessageInfo *)m account: (NSString *)ident;
- (BOOL) endsRun;	/* a move: nothing after it applies */
- (NSString *) summary;	/* "From contains “ann” → Move to Friends" */
@end

/* the enabled rules for an account, in order */
NSArray *Mail2RulesForAccount(NSString *ident);
