/* Mail2Spell: spell checking with Hunspell (iokit's build_hunspell.sh, MPL 1.1) and the en_US dictionary in
 * Mail2.app (dict/, SCOWL's licence). Words the user teaches it ("Learn Spelling") are kept in
 * ~/GNUstep/Library/Mail2/Words.txt. */
#import <Foundation/Foundation.h>

@interface Mail2Spell : NSObject
{
	void *handle;		/* Hunhandle * */
	NSMutableSet *learned;
}
/* nil when there is no dictionary */
+ (Mail2Spell *) shared;
/* a Mail2Spell on these files (the tests) */
- (id) initWithAffix: (NSString *)aff dictionary: (NSString *)dic;
- (BOOL) isCorrect: (NSString *)word;
- (NSArray *) suggestionsFor: (NSString *)word;	/* at most 8, best first */
- (void) learn: (NSString *)word;
/* the ranges of the misspelled words of a text: words of letters (and inner apostrophes); quoted lines (">"),
 * web and mail addresses, words with digits and short all-capital words are left alone */
- (NSArray *) misspellingsIn: (NSString *)text;
@end
