/* Mail2RulesWindow: Mail2 > Rules…, the list of rules (Mail2Rules.h) with each one's checkbox, Add, Edit and Remove,
 * and the editor of one rule: account, field, text, action and the mailbox to move to. */
#import <AppKit/AppKit.h>
#import "Mail2Rules.h"

@interface Mail2RulesWindow : NSObject
{
	NSPanel *panel;
	NSTableView *table;
	NSButton *editButton, *removeButton;
	NSMutableArray *rules;
	NSArray *accounts;		/* Mail2Account, for the editor's popups */
}
- (id) initWithAccounts: (NSArray *)accounts;
- (void) setAccounts: (NSArray *)accounts;
- (void) show;
@end
