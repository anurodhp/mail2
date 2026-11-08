# Mail2 plan

Mail2 is a small IMAP mail client for the GNUstep + Window Maker desktop on the Raspberry Pi 3 Darwin port (`../iokit`). It follows on from GNUstep's GNUMail and sits next to Milan, Naples, Venice, Rome, Florence and Turin. It uses AppKit and libdispatch, with the same layout, build and deploy conventions as Venice and Milan. Libraries do the work wherever one exists.

**First goal: basic email working end to end.** Polish comes after.

## Libraries

| Need | Library | Where it comes from |
|---|---|---|
| IMAP (IDLE, UIDPLUS, MOVE, CONDSTORE), SMTP for sending, MIME parse and build, RFC 2047, charsets | **libetpan** 1.9.x | new `build_libetpan.sh` in iokit (autotools, `--without-sasl --with-openssl`, iconv from iokit) |
| TLS | **OpenSSL 3.0** | Florence's `build_openssl.sh` builds it already (libetpan supports OpenSSL or GnuTLS, not mbedTLS); move it to iokit or link Florence's dylibs |
| Index | **SQLite 3.44** | Florence's `build_sqlite.sh` (`libsqlite3.dylib`, FTS3/4 on) |
| Body store | **Maildir**, one file per message | libetpan's maildir functions, or plain file writes |
| HTML → text | **libxml2** HTML parser | iokit `build_libxml2.sh` |
| Text in many scripts | Milan's `MilanText` / `MilanNFC` | copied in |

Rejected: **mailcore2** is built on libetpan, but it is C++ with ctemplate and tidy-html5, and its Objective-C layer targets Apple Foundation, not GNUstep. **Pantomime** (GNUMail's framework) is GNUstep-native but unmaintained and thin on IMAP extensions. **libcurl's IMAP** has no IDLE or untagged-response handling.

## Scope

- **IMAP only for receiving** (no POP3). SMTP stays in, only for sending; libetpan provides it.
- One account first, several later.
- App passwords (Gmail, iCloud, Fastmail), stored in `~/GNUstep/Library/Mail2/accounts.plist` with mode 0600. No OAuth2 yet.
- TLS certificates verified against the CA bundle.

## Architecture

```
UI (main thread)
  Mail2Window: sidebar | message list | message view   (NSSplitView, 3 panes)
  Mail2Compose: compose window
  Mail2AccountPanel: add/edit account
      ^ results posted back through a wake pipe on the run loop (Venice's pattern:
      | the main dispatch queue does not wake GNUstep's run loop)
Mail2Sync (one serial dispatch queue per account, libetpan mailimap session)
  connect/login, LIST, SELECT, UID FETCH headers, fetch body, STORE flags,
  MOVE/EXPUNGE, IDLE; SMTP send via libetpan mailsmtp
      v
Mail2Store (SQLite, own serial queue)       Maildir (~/GNUstep/Library/Mail2/Mail/<account>/<folder>/{cur,new,tmp})
  accounts, mailboxes(uidvalidity, uidnext)  raw RFC 822 files; the index row holds
  messages(uid, flags, date, from, subject,  the file name; the Maildir flag suffix
  snippet, has_attach, maildir_file)         (:2,S / F / R) is kept in step with the row
```

- The index has one row per message, keyed by `(mailbox_id, uid)`, with a `maildir_file` that is NULL until the body is downloaded. The list view reads only the index. The message view parses the Maildir file with libetpan's `mailmime_parse`.
- A UIDVALIDITY change drops the folder's rows and files.

## UI (Apple Mail layout)

- **Sidebar:** Inbox, Drafts, Sent, Archive, Junk, Trash (found with SPECIAL-USE), then the other folders, each with an unread count.
- **Message list:** unread dot, sender, date, subject, one-line snippet. Rows are drawn only when visible.
- **Message view:** a From/To/Cc/Date/Subject block, the body (text/plain, or HTML turned into text), and an attachment strip with Save.
- **Toolbar:** Get Mail, Compose, Reply, Reply All, Forward, Delete, Archive.
- **Compose:** To, Cc, Subject, a plain-text body and attachments. Send goes through SMTP, then the message is appended to Sent.
- **Dock badge:** Mail2 posts a distributed notification `NaplesBadgeChanged` `{app: "Mail2", badge: "12"}` (gdnc already runs in the session). Naples draws a red badge on that app's tile and clears it when the app quits. It is a small Naples change and works for any app.

## Milestone 1: basic email (the target now)

1. **iokit builds:** `build_libetpan.sh`; OpenSSL and SQLite available to iokit apps (move or reuse Florence's scripts); `build_mail2.sh` (gs_build_app, like `build_venice.sh`).
2. **Skeleton app:** GNUmakefile, `build.sh` / `build.sh deploy`, `Mail2Info.plist`, an icon, menus, and an empty three-pane window.
3. **`mail2-probe` CLI** (same libraries): log in, list folders, print the last 20 envelopes, fetch one message into a Maildir. Run it on the Pi against Gmail to prove TLS, libetpan and the CA bundle.
4. **Account panel and sync:** list folders, then sync the headers of the last 30 days for the selected folder (in batches, newest first) into SQLite.
5. **Reading:** select a message → fetch the body into Maildir → show it. Mark it read; Delete and Archive (MOVE).
6. **New mail:** IDLE on the selected folder, plus a 5-minute check of Inbox.
7. **Compose and send:** new, reply and forward, in plain text.
8. **Dock badge:** Inbox unread count → Naples (Mail2 side and Naples side).

Done when, on the Pi, you can add a Gmail account, read Inbox and other folders, get new mail without restarting, reply, and see the badge count change.

## After that (iterate)

Attachments in compose, drafts, threading, search (SQLite FTS4 plus `UID SEARCH`), offline action queue, several accounts with All Inboxes, better HTML rendering, address completion, `mailto:` and `.eml` Open With from Milan and Florence, notifications, keyboard shortcuts, and a self test (`-Mail2SelfTest YES`).

## Testing

- Dovecot on the Mac (brew) as a LAN server for repeatable runs; a real Gmail account with an app password.
- On the Pi: `DISPLAY=:0 XAUTHORITY=/var/lib/gsdm/auth-0 /Applications/Mail2.app/Mail2`, with `MAIL2_DEBUG=1` to log the IMAP conversation (libetpan's logger, passwords masked). Input injected with `xinject` as for Milan.
