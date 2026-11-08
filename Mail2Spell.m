/* Mail2Spell: Hunspell (see Mail2Spell.h). */
#import "Mail2Spell.h"
#import "Mail2Util.h"
#include <hunspell/hunspell.h>

static NSString *
words_path(void)
{
	return [Mail2SupportDirectory() stringByAppendingPathComponent: @"Words.txt"];
}

@implementation Mail2Spell

+ (Mail2Spell *) shared
{
	static Mail2Spell *s;
	static BOOL tried;
	if (!tried) {
		tried = YES;
		NSBundle *b = [NSBundle mainBundle];
		NSString *aff = [b pathForResource: @"en_US" ofType: @"aff"], *dic = [b pathForResource: @"en_US" ofType: @"dic"];
		if (aff && dic)
			s = [[Mail2Spell alloc] initWithAffix: aff dictionary: dic];
	}
	return s;
}

- (id) initWithAffix: (NSString *)aff dictionary: (NSString *)dic
{
	if ((self = [super init]) == nil)
		return nil;
	handle = Hunspell_create([aff fileSystemRepresentation], [dic fileSystemRepresentation]);
	if (handle == NULL) {
		[self release];
		return nil;
	}
	learned = [[NSMutableSet alloc] init];
	NSString *w = [NSString stringWithContentsOfFile: words_path() encoding: NSUTF8StringEncoding error: NULL];
	NSEnumerator *e = [[w componentsSeparatedByString: @"\n"] objectEnumerator];
	NSString *word;
	while ((word = [e nextObject]) != nil)
		if ([word length]) {
			[learned addObject: word];
			Hunspell_add(handle, [word UTF8String]);
		}
	return self;
}

- (void) dealloc
{
	if (handle)
		Hunspell_destroy(handle);
	[learned release];
	[super dealloc];
}

- (BOOL) isCorrect: (NSString *)word
{
	/* typographic apostrophes as the dictionary has them */
	NSString *w = [word stringByReplacingOccurrencesOfString: @"’" withString: @"'"];
	return Hunspell_spell(handle, [w UTF8String]) != 0;
}

- (NSArray *) suggestionsFor: (NSString *)word
{
	char **list = NULL;
	int n = Hunspell_suggest(handle, &list, [[word stringByReplacingOccurrencesOfString: @"’" withString: @"'"] UTF8String]);
	NSMutableArray *r = [NSMutableArray array];
	int i;
	for (i = 0; i < n && i < 8; i++) {
		NSString *s = [NSString stringWithUTF8String: list[i]];
		if (s)
			[r addObject: s];
	}
	if (list)
		Hunspell_free_list(handle, &list, n);
	return r;
}

- (void) learn: (NSString *)word
{
	if ([word length] == 0 || [learned containsObject: word])
		return;
	[learned addObject: word];
	Hunspell_add(handle, [word UTF8String]);
	NSArray *all = [[learned allObjects] sortedArrayUsingSelector: @selector(compare:)];
	[[[all componentsJoinedByString: @"\n"] stringByAppendingString: @"\n"] writeToFile: words_path() atomically: YES
	    encoding: NSUTF8StringEncoding error: NULL];
}

static BOOL
is_word_char(unichar c)
{
	return [[NSCharacterSet letterCharacterSet] characterIsMember: c];
}

- (NSArray *) misspellingsIn: (NSString *)text
{
	NSMutableArray *r = [NSMutableArray array];
	NSUInteger n = [text length], i = 0;
	while (i < n) {
		NSRange line = [text lineRangeForRange: NSMakeRange(i, 0)];
		NSString *l = [text substringWithRange: line];
		if ([[l stringByTrimmingCharactersInSet: [NSCharacterSet whitespaceCharacterSet]] hasPrefix: @">"]) {
			i = NSMaxRange(line);	/* someone else's words */
			continue;
		}
		NSUInteger j = line.location, end = NSMaxRange(line);
		while (j < end) {
			/* a token: up to white space */
			while (j < end && [[NSCharacterSet whitespaceAndNewlineCharacterSet] characterIsMember: [text characterAtIndex: j]])
				j++;
			NSUInteger ts = j;
			while (j < end && ![[NSCharacterSet whitespaceAndNewlineCharacterSet] characterIsMember: [text characterAtIndex: j]])
				j++;
			if (j == ts)
				continue;
			NSString *tok = [text substringWithRange: NSMakeRange(ts, j - ts)];
			if ([tok rangeOfString: @"@"].location != NSNotFound || [tok rangeOfString: @"://"].location != NSNotFound ||
			    [tok hasPrefix: @"www."] || [tok rangeOfCharacterFromSet: [NSCharacterSet decimalDigitCharacterSet]].location != NSNotFound)
				continue;
			/* the word inside the token: letters with apostrophes between them */
			NSUInteger a = 0, b = [tok length];
			while (a < b && !is_word_char([tok characterAtIndex: a])) a++;
			while (b > a && !is_word_char([tok characterAtIndex: b - 1])) b--;
			if (b <= a)
				continue;
			NSString *w = [tok substringWithRange: NSMakeRange(a, b - a)];
			BOOL clean = YES;
			NSUInteger k;
			for (k = 0; k < [w length]; k++) {
				unichar c = [w characterAtIndex: k];
				if (!is_word_char(c) && c != '\'' && c != 0x2019 && c != '-')
					clean = NO;
			}
			if (!clean || [w length] < 2)
				continue;
			if ([w length] <= 5 && [[w uppercaseString] isEqualToString: w])
				continue;	/* an acronym */
			if (![self isCorrect: w])
				[r addObject: [NSValue valueWithRange: NSMakeRange(ts + a, b - a)]];
		}
		i = NSMaxRange(line);
	}
	return r;
}

@end
