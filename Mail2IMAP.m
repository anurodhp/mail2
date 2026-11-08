/* Mail2IMAP: one IMAP connection over libetpan (see Mail2IMAP.h). */
#import "Mail2IMAP.h"
#import "Mail2Store.h"
#import "Mail2Util.h"
#include "Mail2TLS.h"
#include <libetpan/libetpan-config.h>
#include <libetpan/mailimap.h>
#include <libetpan/idle.h>
#include <libetpan/uidplus.h>
#include <libetpan/mailimf.h>
#include <errno.h>
#include <poll.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#define IMAP ((mailimap *)imap)
#define TIMEOUT 60
#define FETCH_BATCH 100

static NSString *
imap_error(mailimap *s, int r, NSString *what)
{
	const char *resp = s ? s->imap_response : NULL;
	if (resp != NULL && *resp)
		return [NSString stringWithFormat: @"%@: %s", what, resp];
	switch (r) {
	case MAILIMAP_ERROR_STREAM: return [NSString stringWithFormat: @"%@: the connection was lost.", what];
	case MAILIMAP_ERROR_PARSE: return [NSString stringWithFormat: @"%@: the server's answer could not be read.", what];
	case MAILIMAP_ERROR_LOGIN: return @"The server refused the user name or password.";
	case MAILIMAP_ERROR_MEMORY: return @"Out of memory.";
	default: return [NSString stringWithFormat: @"%@ failed (libetpan error %d).", what, r];
	}
}

static void
logger(mailimap *s, int type, const char *str, size_t size, void *ctx)
{
	const char *dir;
	switch (type) {
	case MAILSTREAM_LOG_TYPE_DATA_RECEIVED: dir = "S:"; break;
	case MAILSTREAM_LOG_TYPE_DATA_SENT: dir = "C:"; break;
	case MAILSTREAM_LOG_TYPE_DATA_SENT_PRIVATE: fprintf(stderr, "imap C: <private data>\n"); return;
	default: return;
	}
	/* long literals (message bodies) are cut */
	fprintf(stderr, "imap %s %.*s%s", dir, (int)(size > 400 ? 400 : size), str, size > 400 ? "...\n" : "");
}

/* seconds since 1970 for a civil date and time at a UTC offset given as +hhmm */
static NSDate *
make_date(int y, int mo, int d, int h, int mi, int s, int zone)
{
	if (y < 1970 || mo < 1 || mo > 12 || d < 1)
		return nil;
	/* days from civil (Howard Hinnant's algorithm) */
	int yy = y - (mo <= 2);
	int era = (yy >= 0 ? yy : yy - 399) / 400;
	unsigned yoe = (unsigned)(yy - era * 400);
	unsigned doy = (153 * (mo + (mo > 2 ? -3 : 9)) + 2) / 5 + d - 1;
	unsigned doe = yoe * 365 + yoe / 4 - yoe / 100 + doy;
	long long days = (long long)era * 146097 + doe - 719468;
	int sign = zone < 0 ? -1 : 1, az = zone * sign;
	long long off = sign * ((az / 100) * 3600 + (az % 100) * 60);
	return [NSDate dateWithTimeIntervalSince1970: (double)(days * 86400 + h * 3600 + mi * 60 + s - off)];
}

static NSString *
format_address(struct mailimap_address *a)
{
	NSString *addr;
	if (a->ad_mailbox_name == NULL)
		return nil;	/* group syntax markers */
	addr = a->ad_host_name ? [NSString stringWithFormat: @"%s@%s", a->ad_mailbox_name, a->ad_host_name]
	                       : [NSString stringWithUTF8String: a->ad_mailbox_name];
	NSString *name = Mail2DecodeHeader(a->ad_personal_name);
	if ([name length] == 0)
		return addr;
	return [NSString stringWithFormat: @"%@ <%@>", name, addr];
}

static NSString *
format_list(clist *l)
{
	NSMutableArray *r = [NSMutableArray array];
	clistiter *it;
	if (l == NULL)
		return nil;
	for (it = clist_begin(l); it != NULL; it = clist_next(it)) {
		NSString *s = format_address(clist_content(it));
		if (s != nil)
			[r addObject: s];
	}
	return [r count] ? [r componentsJoinedByString: @", "] : nil;
}

static int
flags_from_fetch(struct mailimap_msg_att_dynamic *dyn)
{
	int f = 0;
	clistiter *it;
	if (dyn == NULL || dyn->att_list == NULL)
		return 0;
	for (it = clist_begin(dyn->att_list); it != NULL; it = clist_next(it)) {
		struct mailimap_flag_fetch *ff = clist_content(it);
		if (ff->fl_type != MAILIMAP_FLAG_FETCH_OTHER || ff->fl_flag == NULL)
			continue;
		switch (ff->fl_flag->fl_type) {
		case MAILIMAP_FLAG_SEEN: f |= Mail2FlagSeen; break;
		case MAILIMAP_FLAG_ANSWERED: f |= Mail2FlagAnswered; break;
		case MAILIMAP_FLAG_FLAGGED: f |= Mail2FlagFlagged; break;
		case MAILIMAP_FLAG_DELETED: f |= Mail2FlagDeleted; break;
		case MAILIMAP_FLAG_DRAFT: f |= Mail2FlagDraft; break;
		}
	}
	return f;
}

static struct mailimap_flag_list *
flag_list(int flags)
{
	struct mailimap_flag_list *l = mailimap_flag_list_new_empty();
	if (flags & Mail2FlagSeen) mailimap_flag_list_add(l, mailimap_flag_new_seen());
	if (flags & Mail2FlagAnswered) mailimap_flag_list_add(l, mailimap_flag_new_answered());
	if (flags & Mail2FlagFlagged) mailimap_flag_list_add(l, mailimap_flag_new_flagged());
	if (flags & Mail2FlagDeleted) mailimap_flag_list_add(l, mailimap_flag_new_deleted());
	if (flags & Mail2FlagDraft) mailimap_flag_list_add(l, mailimap_flag_new_draft());
	return l;
}

static struct mailimap_set *
uid_set(NSArray *uids)
{
	struct mailimap_set *set = mailimap_set_new_empty();
	NSEnumerator *e = [uids objectEnumerator];
	NSNumber *u;
	while ((u = [e nextObject]) != nil)
		mailimap_set_add_single(set, [u unsignedIntValue]);
	return set;
}

static NSArray *
uids_from_search(clist *res)
{
	NSMutableArray *r = [NSMutableArray array];
	clistiter *it;
	for (it = clist_begin(res); it != NULL; it = clist_next(it))
		[r addObject: [NSNumber numberWithUnsignedInt: *(uint32_t *)clist_content(it)]];
	return r;
}

@implementation Mail2IMAP

- (id) initWithAccount: (Mail2Account *)a
{
	if ((self = [super init]) != nil)
		account = [a retain];
	return self;
}

- (void) dealloc
{
	[self disconnect];
	[account release];
	[selected release];
	[super dealloc];
}

- (BOOL) isConnected
{
	return imap != NULL;
}

- (void) disconnect
{
	if (imap != NULL) {
		mailimap_logout(IMAP);
		mailimap_free(IMAP);
		imap = NULL;
	}
	DESTROY(selected);
}

/* a stream error leaves the session unusable: drop it so the next call reconnects */
- (void) failed: (int)r
{
	if (r == MAILIMAP_ERROR_STREAM || r == MAILIMAP_ERROR_PARSE || r == MAILIMAP_ERROR_CONNECTION_REFUSED) {
		mailimap_free(IMAP);
		imap = NULL;
		DESTROY(selected);
	}
}

- (BOOL) connect: (NSString **)err
{
	char e[256];
	mailstream *s;
	mailimap *m;
	int r;
	BOOL tls = [account imapSecurity] == Mail2SecurityTLS;

	if (imap != NULL)
		return YES;
	if ([[account imapHost] length] == 0) {
		*err = @"No incoming mail server is set for this account.";
		return NO;
	}
	s = mail2_connect([[account imapHost] UTF8String], [account imapPort], tls, TIMEOUT, e, sizeof(e));
	if (s == NULL) {
		*err = [NSString stringWithUTF8String: e];
		return NO;
	}
	m = mailimap_new(0, NULL);
	mailimap_set_timeout(m, TIMEOUT);
	if (Mail2Debug())
		mailimap_set_logger(m, logger, NULL);
	r = mailimap_connect(m, s);
	if (r != MAILIMAP_NO_ERROR_AUTHENTICATED && r != MAILIMAP_NO_ERROR_NON_AUTHENTICATED) {
		*err = imap_error(m, r, [NSString stringWithFormat: @"Connecting to %@", [account imapHost]]);
		mailimap_free(m);	/* frees the stream too */
		return NO;
	}
	if ([account imapSecurity] == Mail2SecuritySTARTTLS) {
		r = mailimap_starttls(m);
		if (r != MAILIMAP_NO_ERROR || mail2_starttls(m->imap_stream, [[account imapHost] UTF8String], e, sizeof(e)) != 0) {
			*err = r != MAILIMAP_NO_ERROR ? imap_error(m, r, @"STARTTLS") : [NSString stringWithUTF8String: e];
			mailimap_free(m);
			return NO;
		}
	}
	r = mailimap_login(m, [[account imapUser] UTF8String], [[account password] UTF8String]);
	if (r != MAILIMAP_NO_ERROR) {
		*err = r == MAILIMAP_ERROR_LOGIN && m->imap_response && *m->imap_response
		    ? [NSString stringWithFormat: @"Login failed: %s", m->imap_response] : imap_error(m, r, @"Login");
		mailimap_free(m);
		return NO;
	}
	/* the capabilities after login (they change) */
	struct mailimap_capability_data *caps = NULL;
	if (mailimap_capability(m, &caps) == MAILIMAP_NO_ERROR && caps != NULL)
		mailimap_capability_data_free(caps);
	imap = m;
	return YES;
}

- (BOOL) hasCapability: (NSString *)cap
{
	return imap != NULL && mailimap_has_extension(IMAP, (char *)[cap UTF8String]);
}

- (NSArray *) listMailboxes: (NSString **)err
{
	clist *list = NULL;
	clistiter *it;
	NSMutableArray *r = [NSMutableArray array];
	int rc;
	if (![self connect: err])
		return nil;
	rc = mailimap_list(IMAP, "", "*", &list);
	if (rc != MAILIMAP_NO_ERROR) {
		*err = imap_error(IMAP, rc, @"Listing mailboxes");
		[self failed: rc];
		return nil;
	}
	for (it = clist_begin(list); it != NULL; it = clist_next(it)) {
		struct mailimap_mailbox_list *mb = clist_content(it);
		NSString *name = [NSString stringWithUTF8String: mb->mb_name];
		NSString *special = nil;
		BOOL selectable = YES;
		if ([name caseInsensitiveCompare: @"INBOX"] == NSOrderedSame) {
			name = @"INBOX";
			special = @"inbox";
		}
		if (mb->mb_flag != NULL) {
			if (mb->mb_flag->mbf_type == MAILIMAP_MBX_LIST_FLAGS_SFLAG && mb->mb_flag->mbf_sflag == MAILIMAP_MBX_LIST_SFLAG_NOSELECT)
				selectable = NO;
			clistiter *oi;
			for (oi = clist_begin(mb->mb_flag->mbf_oflags); oi != NULL; oi = clist_next(oi)) {
				struct mailimap_mbx_list_oflag *of = clist_content(oi);
				if (of->of_type != MAILIMAP_MBX_LIST_OFLAG_FLAG_EXT || of->of_flag_ext == NULL)
					continue;
				/* RFC 6154 SPECIAL-USE attributes (Gmail sends them in a plain LIST) */
				NSString *f = [[NSString stringWithUTF8String: of->of_flag_ext] lowercaseString];
				if ([f isEqualToString: @"noselect"] || [f isEqualToString: @"nonexistent"])
					selectable = NO;
				else if (special == nil && ([f isEqualToString: @"sent"] || [f isEqualToString: @"drafts"] ||
				    [f isEqualToString: @"trash"] || [f isEqualToString: @"junk"] || [f isEqualToString: @"archive"] ||
				    [f isEqualToString: @"all"] || [f isEqualToString: @"flagged"]))
					special = f;
			}
		}
		[r addObject: [NSDictionary dictionaryWithObjectsAndKeys:
		    name, @"Name",
		    mb->mb_delimiter ? [NSString stringWithFormat: @"%c", mb->mb_delimiter] : @"", @"Delimiter",
		    [NSNumber numberWithBool: selectable], @"Selectable",
		    special, @"Special",	/* last: nil ends the list */
		    nil]];
	}
	mailimap_list_result_free(list);
	/* servers without SPECIAL-USE: the usual names */
	NSDictionary *byName = [NSDictionary dictionaryWithObjectsAndKeys:	/* object, key */
	    @"sent", @"sent", @"sent", @"sent messages", @"sent", @"sent items", @"sent", @"sent mail",
	    @"drafts", @"drafts", @"trash", @"trash", @"trash", @"deleted messages", @"trash", @"deleted items",
	    @"junk", @"junk", @"junk", @"spam", @"archive", @"archive", nil];
	NSMutableSet *have = [NSMutableSet set];
	NSEnumerator *e = [r objectEnumerator];
	NSDictionary *d;
	while ((d = [e nextObject]) != nil)
		if ([d objectForKey: @"Special"])
			[have addObject: [d objectForKey: @"Special"]];
	NSUInteger i;
	for (i = 0; i < [r count]; i++) {
		d = [r objectAtIndex: i];
		NSString *leaf = [[[[d objectForKey: @"Name"] componentsSeparatedByString: [d objectForKey: @"Delimiter"]] lastObject] lowercaseString];
		NSString *sp = [byName objectForKey: leaf];
		if ([d objectForKey: @"Special"] == nil && sp != nil && ![have containsObject: sp]) {
			NSMutableDictionary *md = [[d mutableCopy] autorelease];
			[md setObject: sp forKey: @"Special"];
			[r replaceObjectAtIndex: i withObject: md];
			[have addObject: sp];
		}
	}
	return r;
}

- (BOOL) createMailbox: (NSString *)name error: (NSString **)err
{
	int rc;
	if (![self connect: err])
		return NO;
	rc = mailimap_create(IMAP, [name UTF8String]);
	if (rc != MAILIMAP_NO_ERROR) {
		*err = imap_error(IMAP, rc, @"Creating a mailbox");
		[self failed: rc];
		return NO;
	}
	return YES;
}

- (BOOL) select: (NSString *)mailbox uidValidity: (unsigned *)v uidNext: (unsigned *)n exists: (unsigned *)exists error: (NSString **)err
{
	int rc;
	if (![self connect: err])
		return NO;
	rc = mailimap_select(IMAP, [mailbox UTF8String]);
	if (rc != MAILIMAP_NO_ERROR) {
		*err = imap_error(IMAP, rc, [NSString stringWithFormat: @"Opening %@", Mail2DecodeMailboxName([mailbox UTF8String])]);
		[self failed: rc];
		DESTROY(selected);
		return NO;
	}
	ASSIGN(selected, mailbox);
	struct mailimap_selection_info *si = IMAP->imap_selection_info;
	if (v) *v = si ? si->sel_uidvalidity : 0;
	if (n) *n = si ? si->sel_uidnext : 0;
	if (exists) *exists = si ? si->sel_exists : 0;
	return YES;
}

- (NSArray *) search: (struct mailimap_search_key *)key what: (NSString *)what error: (NSString **)err
{
	clist *res = NULL;
	int rc = mailimap_uid_search(IMAP, NULL, key, &res);
	mailimap_search_key_free(key);
	if (rc != MAILIMAP_NO_ERROR) {
		*err = imap_error(IMAP, rc, what);
		[self failed: rc];
		return nil;
	}
	NSArray *r = uids_from_search(res);
	mailimap_search_result_free(res);
	return r;
}

/* a search with CHARSET UTF-8 when the text needs it */
- (NSArray *) search: (struct mailimap_search_key *)key utf8: (BOOL)utf8 what: (NSString *)what error: (NSString **)err
{
	clist *res = NULL;
	int rc = mailimap_uid_search(IMAP, utf8 ? "UTF-8" : NULL, key, &res);
	mailimap_search_key_free(key);
	if (rc != MAILIMAP_NO_ERROR) {
		*err = imap_error(IMAP, rc, what);
		[self failed: rc];
		return nil;
	}
	NSArray *r = uids_from_search(res);
	mailimap_search_result_free(res);
	return r;
}

- (NSArray *) uidsMatchingText: (NSString *)text error: (NSString **)err
{
	BOOL ascii = [text canBeConvertedToEncoding: NSASCIIStringEncoding];
	/* every word must match somewhere (TEXT: headers and body) */
	NSArray *words = [text componentsSeparatedByCharactersInSet: [NSCharacterSet whitespaceAndNewlineCharacterSet]];
	struct mailimap_search_key *all = mailimap_search_key_new_multiple_empty();
	NSEnumerator *e = [words objectEnumerator];
	NSString *w;
	int n = 0;
	while ((w = [e nextObject]) != nil) {
		if ([w length] == 0)
			continue;
		mailimap_search_key_multiple_add(all, mailimap_search_key_new_text(strdup([w UTF8String])));
		n++;
	}
	if (n == 0) {
		mailimap_search_key_free(all);
		return [NSArray array];
	}
	return [self search: all utf8: !ascii what: @"Searching" error: err];
}

- (NSArray *) uidsBelow: (unsigned)uid error: (NSString **)err
{
	if (uid <= 1)
		return [NSArray array];
	NSArray *all = [self search: mailimap_search_key_new_uid(mailimap_set_new_interval(1, uid - 1)) what: @"Searching" error: err];
	NSMutableArray *r = [NSMutableArray array];
	NSEnumerator *e = [all objectEnumerator];
	NSNumber *u;
	if (all == nil)
		return nil;
	while ((u = [e nextObject]) != nil)
		if ([u unsignedIntValue] < uid)
			[r addObject: u];
	return r;
}

- (NSArray *) uidsWithMessageID: (NSString *)mid error: (NSString **)err
{
	return [self search: mailimap_search_key_new_header(strdup("Message-ID"), strdup([mid UTF8String]))
	                 what: @"Searching" error: err];
}

- (NSArray *) uidsSince: (NSDate *)date error: (NSString **)err
{
	NSCalendarDate *cd = [NSCalendarDate dateWithTimeIntervalSinceReferenceDate: [date timeIntervalSinceReferenceDate]];
	struct mailimap_date *d = mailimap_date_new([cd dayOfMonth], [cd monthOfYear], [cd yearOfCommonEra]);
	return [self search: mailimap_search_key_new_since(d) what: @"Searching" error: err];
}

- (NSArray *) uidsAbove: (unsigned)uid error: (NSString **)err
{
	NSArray *all = [self search: mailimap_search_key_new_uid(mailimap_set_new_interval(uid + 1, 0)) what: @"Searching" error: err];
	NSMutableArray *r = [NSMutableArray array];
	NSEnumerator *e = [all objectEnumerator];
	NSNumber *u;
	if (all == nil)
		return nil;
	while ((u = [e nextObject]) != nil)
		if ([u unsignedIntValue] > uid)
			[r addObject: u];
	return r;
}

- (NSArray *) fetchHeaders: (NSArray *)uids mailbox: (long long)mbid error: (NSString **)err
{
	NSMutableArray *out = [NSMutableArray array];
	NSUInteger i;
	for (i = 0; i < [uids count]; i += FETCH_BATCH) {
		NSArray *batch = [uids subarrayWithRange: NSMakeRange(i, MIN(FETCH_BATCH, [uids count] - i))];
		struct mailimap_fetch_type *ft = mailimap_fetch_type_new_fetch_att_list_empty();
		clist *res = NULL;
		clistiter *it;
		int rc;
		mailimap_fetch_type_new_fetch_att_list_add(ft, mailimap_fetch_att_new_uid());
		mailimap_fetch_type_new_fetch_att_list_add(ft, mailimap_fetch_att_new_flags());
		mailimap_fetch_type_new_fetch_att_list_add(ft, mailimap_fetch_att_new_internaldate());
		mailimap_fetch_type_new_fetch_att_list_add(ft, mailimap_fetch_att_new_rfc822_size());
		mailimap_fetch_type_new_fetch_att_list_add(ft, mailimap_fetch_att_new_envelope());
		mailimap_fetch_type_new_fetch_att_list_add(ft, mailimap_fetch_att_new_bodystructure());
		/* References, for threading: not in the envelope */
		clist *hdrs = clist_new();
		clist_append(hdrs, strdup("References"));
		mailimap_fetch_type_new_fetch_att_list_add(ft, mailimap_fetch_att_new_body_peek_section(
		    mailimap_section_new_header_fields(mailimap_header_list_new(hdrs))));
		struct mailimap_set *set = uid_set(batch);
		rc = mailimap_uid_fetch(IMAP, set, ft, &res);
		mailimap_set_free(set);
		mailimap_fetch_type_free(ft);
		if (rc != MAILIMAP_NO_ERROR) {
			*err = imap_error(IMAP, rc, @"Fetching messages");
			[self failed: rc];
			return nil;
		}
		for (it = clist_begin(res); it != NULL; it = clist_next(it)) {
			struct mailimap_msg_att *ma = clist_content(it);
			Mail2MessageInfo *m = [[[Mail2MessageInfo alloc] init] autorelease];
			struct mailimap_envelope *env = NULL;
			NSDate *internal = nil;
			clistiter *ai;
			m->mbid = mbid;
			for (ai = clist_begin(ma->att_list); ai != NULL; ai = clist_next(ai)) {
				struct mailimap_msg_att_item *item = clist_content(ai);
				if (item->att_type == MAILIMAP_MSG_ATT_ITEM_DYNAMIC) {
					m->flags = flags_from_fetch(item->att_data.att_dyn);
					continue;
				}
				if (item->att_type != MAILIMAP_MSG_ATT_ITEM_STATIC)
					continue;
				struct mailimap_msg_att_static *st = item->att_data.att_static;
				switch (st->att_type) {
				case MAILIMAP_MSG_ATT_UID:
					m->uid = st->att_data.att_uid;
					break;
				case MAILIMAP_MSG_ATT_RFC822_SIZE:
					m->size = st->att_data.att_rfc822_size;
					break;
				case MAILIMAP_MSG_ATT_INTERNALDATE: {
					struct mailimap_date_time *dt = st->att_data.att_internal_date;
					if (dt)
						internal = make_date(dt->dt_year, dt->dt_month, dt->dt_day, dt->dt_hour, dt->dt_min, dt->dt_sec, dt->dt_zone);
					break;
				}
				case MAILIMAP_MSG_ATT_ENVELOPE:
					env = st->att_data.att_env;
					break;
				case MAILIMAP_MSG_ATT_BODY_SECTION: {
					struct mailimap_msg_att_body_section *bs = st->att_data.att_body_section;
					if (bs && bs->sec_body_part)
						m->references = [Mail2MessageIDsIn([[[NSString alloc] initWithBytes: bs->sec_body_part
						    length: bs->sec_length encoding: NSISOLatin1StringEncoding] autorelease]) retain];
					break;
				}
				case MAILIMAP_MSG_ATT_BODYSTRUCTURE: {
					struct mailimap_body *b = st->att_data.att_bodystructure;
					m->attachment = b && b->bd_type == MAILIMAP_BODY_MPART && b->bd_data.bd_body_mpart &&
					    strcasecmp(b->bd_data.bd_body_mpart->bd_media_subtype, "mixed") == 0;
					break;
				}
				}
			}
			if (m->uid == 0)
				continue;
			if (env != NULL) {
				struct mailimap_address *from = NULL;
				if (env->env_from && env->env_from->frm_list && clist_begin(env->env_from->frm_list))
					from = clist_content(clist_begin(env->env_from->frm_list));
				if (from != NULL) {
					m->fromName = [Mail2DecodeHeader(from->ad_personal_name) retain];
					if (from->ad_mailbox_name)
						m->fromAddr = [(from->ad_host_name ? [NSString stringWithFormat: @"%s@%s", from->ad_mailbox_name, from->ad_host_name]
						    : [NSString stringWithUTF8String: from->ad_mailbox_name]) retain];
				}
				m->subject = [Mail2DecodeHeader(env->env_subject) retain];
				m->to = [format_list(env->env_to ? env->env_to->to_list : NULL) retain];
				m->cc = [format_list(env->env_cc ? env->env_cc->cc_list : NULL) retain];
				m->replyTo = [format_list(env->env_reply_to ? env->env_reply_to->rt_list : NULL) retain];
				m->messageId = env->env_message_id ? [[NSString alloc] initWithUTF8String: env->env_message_id] : nil;
				m->inReplyTo = env->env_in_reply_to ? [[NSString alloc] initWithUTF8String: env->env_in_reply_to] : nil;
				if (internal == nil && env->env_date) {
					struct mailimf_date_time *dt = NULL;
					size_t idx = 0;
					if (mailimf_date_time_parse(env->env_date, strlen(env->env_date), &idx, &dt) == MAILIMF_NO_ERROR) {
						internal = make_date(dt->dt_year, dt->dt_month, dt->dt_day, dt->dt_hour, dt->dt_min, dt->dt_sec, dt->dt_zone);
						mailimf_date_time_free(dt);
					}
				}
			}
			m->date = [(internal ? internal : [NSDate date]) retain];
			[out addObject: m];
		}
		mailimap_fetch_list_free(res);
	}
	return out;
}

- (NSDictionary *) fetchFlagsFrom: (unsigned)uid error: (NSString **)err
{
	NSMutableDictionary *r = [NSMutableDictionary dictionary];
	struct mailimap_fetch_type *ft = mailimap_fetch_type_new_fetch_att_list_empty();
	struct mailimap_set *set = mailimap_set_new_interval(uid ? uid : 1, 0);
	clist *res = NULL;
	clistiter *it;
	int rc;
	mailimap_fetch_type_new_fetch_att_list_add(ft, mailimap_fetch_att_new_uid());
	mailimap_fetch_type_new_fetch_att_list_add(ft, mailimap_fetch_att_new_flags());
	rc = mailimap_uid_fetch(IMAP, set, ft, &res);
	mailimap_set_free(set);
	mailimap_fetch_type_free(ft);
	if (rc != MAILIMAP_NO_ERROR) {
		*err = imap_error(IMAP, rc, @"Fetching flags");
		[self failed: rc];
		return nil;
	}
	for (it = clist_begin(res); it != NULL; it = clist_next(it)) {
		struct mailimap_msg_att *ma = clist_content(it);
		unsigned u = 0;
		int f = 0;
		clistiter *ai;
		for (ai = clist_begin(ma->att_list); ai != NULL; ai = clist_next(ai)) {
			struct mailimap_msg_att_item *item = clist_content(ai);
			if (item->att_type == MAILIMAP_MSG_ATT_ITEM_DYNAMIC)
				f = flags_from_fetch(item->att_data.att_dyn);
			else if (item->att_type == MAILIMAP_MSG_ATT_ITEM_STATIC && item->att_data.att_static->att_type == MAILIMAP_MSG_ATT_UID)
				u = item->att_data.att_static->att_data.att_uid;
		}
		if (u >= uid && u != 0)
			[r setObject: [NSNumber numberWithInt: f] forKey: [NSNumber numberWithUnsignedInt: u]];
	}
	mailimap_fetch_list_free(res);
	return r;
}

- (NSData *) fetchMessage: (unsigned)uid error: (NSString **)err
{
	struct mailimap_fetch_type *ft = mailimap_fetch_type_new_fetch_att_list_empty();
	struct mailimap_set *set = mailimap_set_new_single(uid);
	clist *res = NULL;
	clistiter *it;
	NSData *data = nil;
	int rc;
	mailimap_fetch_type_new_fetch_att_list_add(ft, mailimap_fetch_att_new_body_peek_section(mailimap_section_new(NULL)));
	rc = mailimap_uid_fetch(IMAP, set, ft, &res);
	mailimap_set_free(set);
	mailimap_fetch_type_free(ft);
	if (rc != MAILIMAP_NO_ERROR) {
		*err = imap_error(IMAP, rc, @"Downloading the message");
		[self failed: rc];
		return nil;
	}
	for (it = clist_begin(res); it != NULL && data == nil; it = clist_next(it)) {
		struct mailimap_msg_att *ma = clist_content(it);
		clistiter *ai;
		for (ai = clist_begin(ma->att_list); ai != NULL; ai = clist_next(ai)) {
			struct mailimap_msg_att_item *item = clist_content(ai);
			if (item->att_type == MAILIMAP_MSG_ATT_ITEM_STATIC && item->att_data.att_static->att_type == MAILIMAP_MSG_ATT_BODY_SECTION) {
				struct mailimap_msg_att_body_section *bs = item->att_data.att_static->att_data.att_body_section;
				if (bs && bs->sec_body_part)
					data = [NSData dataWithBytes: bs->sec_body_part length: bs->sec_length];
			}
		}
	}
	mailimap_fetch_list_free(res);
	if (data == nil)
		*err = @"The server did not return the message (it may have been deleted).";
	return data;
}

- (BOOL) setFlags: (int)flags add: (BOOL)add uids: (NSArray *)uids error: (NSString **)err
{
	struct mailimap_set *set = uid_set(uids);
	struct mailimap_store_att_flags *sa = add ? mailimap_store_att_flags_new_add_flags_silent(flag_list(flags))
	                                          : mailimap_store_att_flags_new_remove_flags_silent(flag_list(flags));
	int rc = mailimap_uid_store(IMAP, set, sa);
	mailimap_store_att_flags_free(sa);
	mailimap_set_free(set);
	if (rc != MAILIMAP_NO_ERROR) {
		*err = imap_error(IMAP, rc, @"Changing flags");
		[self failed: rc];
		return NO;
	}
	return YES;
}

- (BOOL) moveUids: (NSArray *)uids to: (NSString *)mailbox error: (NSString **)err
{
	struct mailimap_set *set = uid_set(uids);
	int rc;
	if ([self hasCapability: @"MOVE"]) {
		rc = mailimap_uid_move(IMAP, set, [mailbox UTF8String]);
		mailimap_set_free(set);
		if (rc != MAILIMAP_NO_ERROR) {
			*err = imap_error(IMAP, rc, @"Moving messages");
			[self failed: rc];
			return NO;
		}
		return YES;
	}
	rc = mailimap_uid_copy(IMAP, set, [mailbox UTF8String]);
	mailimap_set_free(set);
	if (rc != MAILIMAP_NO_ERROR) {
		*err = imap_error(IMAP, rc, @"Copying messages");
		[self failed: rc];
		return NO;
	}
	return [self expungeUids: uids error: err];
}

- (BOOL) expungeUids: (NSArray *)uids error: (NSString **)err
{
	struct mailimap_set *set;
	int rc;
	if (![self setFlags: Mail2FlagDeleted add: YES uids: uids error: err])
		return NO;
	set = uid_set(uids);
	/* UID EXPUNGE removes only these; plain EXPUNGE would take every \Deleted message in the mailbox */
	rc = [self hasCapability: @"UIDPLUS"] ? mailimap_uid_expunge(IMAP, set) : mailimap_expunge(IMAP);
	mailimap_set_free(set);
	if (rc != MAILIMAP_NO_ERROR) {
		*err = imap_error(IMAP, rc, @"Expunging");
		[self failed: rc];
		return NO;
	}
	return YES;
}

- (BOOL) appendMessage: (NSData *)raw to: (NSString *)mailbox flags: (int)flags error: (NSString **)err
{
	if (![self connect: err])
		return NO;
	struct mailimap_flag_list *fl = flag_list(flags);
	int rc = mailimap_append(IMAP, [mailbox UTF8String], fl, NULL, [raw bytes], [raw length]);
	mailimap_flag_list_free(fl);
	if (rc != MAILIMAP_NO_ERROR) {
		*err = imap_error(IMAP, rc, [NSString stringWithFormat: @"Saving to %@", Mail2DecodeMailboxName([mailbox UTF8String])]);
		[self failed: rc];
		return NO;
	}
	return YES;
}

/* waits for any of the descriptors until the deadline, retrying when a signal interrupts poll() (on this system
 * signals reach every thread; an interrupted wait is not an event) */
static int
poll_until(struct pollfd *p, int n, NSTimeInterval deadline)
{
	for (;;) {
		int i, ms = (int)(([NSDate timeIntervalSinceReferenceDate] - deadline) * -1000.0), r;
		if (ms < 0)
			ms = 0;
		for (i = 0; i < n; i++)
			p[i].revents = 0;
		r = poll(p, n, ms);
		if (r >= 0 || errno != EINTR)
			return r;
	}
}

- (int) idleWithWakeFd: (int)wakeFd timeout: (int)seconds error: (NSString **)err
{
	struct pollfd p[2];
	NSTimeInterval deadline = [NSDate timeIntervalSinceReferenceDate] + seconds;
	int rc;
	if (![self hasCapability: @"IDLE"]) {
		p[0].fd = wakeFd; p[0].events = POLLIN;
		poll_until(p, 1, deadline);
		return 0;
	}
	rc = mailimap_idle(IMAP);
	if (rc != MAILIMAP_NO_ERROR) {
		*err = imap_error(IMAP, rc, @"IDLE");
		[self failed: rc];
		return -1;
	}
	/* an untagged EXISTS/EXPUNGE/FETCH on the socket, a wakeup, or the timeout (servers drop IDLE after 30 min) */
	p[0].fd = mailimap_idle_get_fd(IMAP); p[0].events = POLLIN;
	p[1].fd = wakeFd; p[1].events = POLLIN;
	poll_until(p, 2, deadline);
	BOOL news = (p[0].revents & (POLLIN | POLLHUP | POLLERR)) != 0;
	rc = mailimap_idle_done(IMAP);
	if (rc != MAILIMAP_NO_ERROR) {
		*err = imap_error(IMAP, rc, @"IDLE");
		[self failed: rc];
		return -1;
	}
	return news ? 1 : 0;
}

@end
