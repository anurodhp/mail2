/* Mail2Account: one account's settings (see Mail2Account.h). */
#import "Mail2Account.h"
#import "Mail2Util.h"
#include <sys/stat.h>

static NSString *
accounts_path(void)
{
	return [Mail2SupportDirectory() stringByAppendingPathComponent: @"Accounts.plist"];
}

/* A file-name-safe identifier from the address: "jane.doe@gmail.com" -> "jane.doe@gmail.com" with anything but
 * letters, digits, ".", "-", "_" and "@" replaced by "_". */
static NSString *
identifier_for(NSString *email)
{
	NSMutableString *r = [NSMutableString string];
	NSCharacterSet *ok = [NSCharacterSet characterSetWithCharactersInString:
	    @"abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789.-_@"];
	NSUInteger i;
	for (i = 0; i < [email length]; i++) {
		unichar c = [email characterAtIndex: i];
		[r appendFormat: @"%C", (unichar)([ok characterIsMember: c] ? c : '_')];
	}
	return [r length] ? [r lowercaseString] : @"account";
}

NSString *const Mail2AccountChanged = @"Mail2AccountChanged";

@implementation Mail2Account

+ (Mail2Auth) oauthProviderForEmail: (NSString *)addr
{
	NSString *domain = [[[addr componentsSeparatedByString: @"@"] lastObject] lowercaseString];
	if ([domain isEqualToString: @"gmail.com"] || [domain isEqualToString: @"googlemail.com"])
		return Mail2AuthGoogle;
	if ([domain isEqualToString: @"outlook.com"] || [domain isEqualToString: @"hotmail.com"] || [domain isEqualToString: @"live.com"] ||
	    [domain isEqualToString: @"msn.com"] || [domain hasPrefix: @"outlook."] || [domain hasPrefix: @"hotmail."])
		return Mail2AuthMicrosoft;
	return Mail2AuthPassword;
}

+ (Mail2Account *) accountForEmail: (NSString *)addr
{
	Mail2Account *a = [[[Mail2Account alloc] init] autorelease];
	NSString *domain = [[[addr componentsSeparatedByString: @"@"] lastObject] lowercaseString];
	[a setEmail: addr];
	[a setImapUser: addr];
	[a setSmtpUser: addr];
	[a setImapPort: 993];
	[a setImapSecurity: Mail2SecurityTLS];
	[a setSmtpPort: 465];
	[a setSmtpSecurity: Mail2SecurityTLS];
	if ([domain isEqualToString: @"gmail.com"] || [domain isEqualToString: @"googlemail.com"]) {
		[a setImapHost: @"imap.gmail.com"];
		[a setSmtpHost: @"smtp.gmail.com"];
	} else if ([domain isEqualToString: @"icloud.com"] || [domain isEqualToString: @"me.com"] || [domain isEqualToString: @"mac.com"]) {
		[a setImapHost: @"imap.mail.me.com"];
		[a setSmtpHost: @"smtp.mail.me.com"];
		[a setSmtpPort: 587];
		[a setSmtpSecurity: Mail2SecuritySTARTTLS];
		/* iCloud logs in with the name before the @ */
		[a setImapUser: [[addr componentsSeparatedByString: @"@"] objectAtIndex: 0]];
	} else if ([domain isEqualToString: @"fastmail.com"] || [domain isEqualToString: @"fastmail.fm"]) {
		[a setImapHost: @"imap.fastmail.com"];
		[a setSmtpHost: @"smtp.fastmail.com"];
	} else if ([Mail2Account oauthProviderForEmail: addr] == Mail2AuthMicrosoft) {
		/* Outlook.com and Microsoft 365: OAuth only */
		[a setImapHost: @"outlook.office365.com"];
		[a setSmtpHost: @"smtp.office365.com"];
		[a setSmtpPort: 587];
		[a setSmtpSecurity: Mail2SecuritySTARTTLS];
		[a setAuth: Mail2AuthMicrosoft];
	} else if ([domain hasPrefix: @"yahoo."] || [domain isEqualToString: @"ymail.com"]) {
		[a setImapHost: @"imap.mail.yahoo.com"];
		[a setSmtpHost: @"smtp.mail.yahoo.com"];
	} else if ([domain length] > 0) {
		[a setImapHost: [@"imap." stringByAppendingString: domain]];
		[a setSmtpHost: [@"smtp." stringByAppendingString: domain]];
	}
	return a;
}

+ (NSArray *) loadAccounts
{
	NSArray *plist = [NSArray arrayWithContentsOfFile: accounts_path()];
	NSMutableArray *r = [NSMutableArray array];
	NSEnumerator *e = [plist objectEnumerator];
	NSDictionary *d;
	while ((d = [e nextObject]) != nil) {
		if (![d isKindOfClass: [NSDictionary class]] || [d objectForKey: @"Email"] == nil)
			continue;
		Mail2Account *a = [[[Mail2Account alloc] init] autorelease];
		ASSIGN(a->identifier, [d objectForKey: @"Identifier"]);
		[a setFullName: [d objectForKey: @"FullName"]];
		[a setEmail: [d objectForKey: @"Email"]];
		[a setPassword: [d objectForKey: @"Password"]];
		[a setImapHost: [d objectForKey: @"IMAPHost"]];
		[a setImapUser: [d objectForKey: @"IMAPUser"]];
		[a setImapPort: [[d objectForKey: @"IMAPPort"] intValue]];
		[a setImapSecurity: [[d objectForKey: @"IMAPSecurity"] intValue]];
		[a setSmtpHost: [d objectForKey: @"SMTPHost"]];
		[a setSmtpUser: [d objectForKey: @"SMTPUser"]];
		[a setSmtpPort: [[d objectForKey: @"SMTPPort"] intValue]];
		[a setSmtpSecurity: [[d objectForKey: @"SMTPSecurity"] intValue]];
		[a setAuth: [[d objectForKey: @"Auth"] intValue]];
		[a setRefreshToken: [[d objectForKey: @"RefreshToken"] length] ? [d objectForKey: @"RefreshToken"] : nil];
		[a setSignature: [d objectForKey: @"Signature"]];
		[r addObject: a];
	}
	return r;
}

+ (BOOL) saveAccounts: (NSArray *)accounts
{
	NSMutableArray *plist = [NSMutableArray array];
	NSEnumerator *e = [accounts objectEnumerator];
	Mail2Account *a;
	while ((a = [e nextObject]) != nil) {
		[plist addObject: [NSDictionary dictionaryWithObjectsAndKeys:
		    [a identifier], @"Identifier",
		    [a fullName] ? [a fullName] : @"", @"FullName",
		    [a email], @"Email",
		    [a password] ? [a password] : @"", @"Password",
		    [a imapHost] ? [a imapHost] : @"", @"IMAPHost",
		    [a imapUser] ? [a imapUser] : @"", @"IMAPUser",
		    [NSNumber numberWithInt: [a imapPort]], @"IMAPPort",
		    [NSNumber numberWithInt: [a imapSecurity]], @"IMAPSecurity",
		    [a smtpHost] ? [a smtpHost] : @"", @"SMTPHost",
		    [a smtpUser] ? [a smtpUser] : @"", @"SMTPUser",
		    [NSNumber numberWithInt: [a smtpPort]], @"SMTPPort",
		    [NSNumber numberWithInt: [a smtpSecurity]], @"SMTPSecurity",
		    [NSNumber numberWithInt: [a auth]], @"Auth",
		    [a refreshToken] ? [a refreshToken] : @"", @"RefreshToken",
		    [a signature] ? [a signature] : @"", @"Signature",
		    nil]];
	}
	NSString *p = accounts_path();
	/* created 0600 before the password is written into it */
	if (![[NSFileManager defaultManager] fileExistsAtPath: p])
		[[NSFileManager defaultManager] createFileAtPath: p contents: [NSData data] attributes:
		    [NSDictionary dictionaryWithObject: [NSNumber numberWithShort: 0600] forKey: NSFilePosixPermissions]];
	chmod([p fileSystemRepresentation], 0600);
	BOOL ok = [plist writeToFile: p atomically: NO];
	chmod([p fileSystemRepresentation], 0600);
	return ok;
}

- (void) dealloc
{
	[identifier release]; [fullName release]; [email release]; [password release];
	[imapHost release]; [imapUser release]; [smtpHost release]; [smtpUser release]; [refreshToken release];
	[signature release];
	[super dealloc];
}

- (NSString *) identifier
{
	if (identifier == nil)
		ASSIGN(identifier, identifier_for(email ? email : @""));
	return identifier;
}
- (NSString *) fullName { return fullName; }
- (NSString *) email { return email; }
- (NSString *) password { return password; }
- (NSString *) imapHost { return imapHost; }
- (NSString *) imapUser { return [imapUser length] ? imapUser : email; }
- (int) imapPort { return imapPort > 0 ? imapPort : (imapSecurity == Mail2SecurityTLS ? 993 : 143); }
- (Mail2Security) imapSecurity { return imapSecurity; }
- (NSString *) smtpHost { return smtpHost; }
- (NSString *) smtpUser { return [smtpUser length] ? smtpUser : [self imapUser]; }
- (int) smtpPort { return smtpPort > 0 ? smtpPort : (smtpSecurity == Mail2SecurityTLS ? 465 : 587); }
- (Mail2Security) smtpSecurity { return smtpSecurity; }

- (NSString *) fromAddress
{
	if ([fullName length] == 0)
		return email;
	/* quoted when the name has characters with a meaning in an address */
	NSCharacterSet *special = [NSCharacterSet characterSetWithCharactersInString: @"()<>[]:;@\\,.\""];
	NSString *n = fullName;
	if ([n rangeOfCharacterFromSet: special].location != NSNotFound)
		n = [NSString stringWithFormat: @"\"%@\"", [[n stringByReplacingOccurrencesOfString: @"\\" withString: @"\\\\"]
		    stringByReplacingOccurrencesOfString: @"\"" withString: @"\\\""]];
	return [NSString stringWithFormat: @"%@ <%@>", n, email];
}

- (void) setFullName: (NSString *)s { ASSIGN(fullName, s); }
- (void) setEmail: (NSString *)s { ASSIGN(email, [s stringByTrimmingCharactersInSet: [NSCharacterSet whitespaceCharacterSet]]); }
- (void) setPassword: (NSString *)s { ASSIGN(password, s); }
- (void) setImapHost: (NSString *)s { ASSIGN(imapHost, [s stringByTrimmingCharactersInSet: [NSCharacterSet whitespaceCharacterSet]]); }
- (void) setImapUser: (NSString *)s { ASSIGN(imapUser, s); }
- (void) setImapPort: (int)p { imapPort = p; }
- (void) setImapSecurity: (Mail2Security)s { imapSecurity = s; }
- (void) setSmtpHost: (NSString *)s { ASSIGN(smtpHost, [s stringByTrimmingCharactersInSet: [NSCharacterSet whitespaceCharacterSet]]); }
- (void) setSmtpUser: (NSString *)s { ASSIGN(smtpUser, s); }
- (void) setSmtpPort: (int)p { smtpPort = p; }
- (void) setSmtpSecurity: (Mail2Security)s { smtpSecurity = s; }
- (Mail2Auth) auth { return auth; }
- (void) setAuth: (Mail2Auth)a { auth = a; }
- (NSString *) refreshToken { return refreshToken; }
- (void) setRefreshToken: (NSString *)t { ASSIGN(refreshToken, t); }
- (BOOL) usesOAuth { return auth != Mail2AuthPassword; }
- (NSString *) signature { return signature; }
- (void) setSignature: (NSString *)s { ASSIGN(signature, [s length] ? s : nil); }
@end
