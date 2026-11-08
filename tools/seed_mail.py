#!/usr/bin/env python3
"""Puts a handful of realistic messages into test1@localhost's Inbox on a GreenMail test server (SMTP on
127.0.0.1:3025), for tools/qemu_shots.sh: plain text, HTML with a plain alternative, an attachment, a non-ASCII
subject and sender, and a three-message conversation (References). Also a draft with an attachment in a Drafts
mailbox (IMAP APPEND), which the QEMU run opens and sends. Standard library only."""
import imaplib
import smtplib
import sys
import time
from email.message import EmailMessage
from email.utils import formataddr, make_msgid

TO = "test1@localhost"
LUNCH = ["<lunch-1@example.com>", "<lunch-2@example.org>", "<lunch-3@example.com>"]
MSGS = [
    ("Ann Example", "ann@example.com", "Lunch on Friday?",
     "Hi,\n\nAre you free for lunch on Friday? The new place on Elm Street does a good soup.\n\nAnn", None, None),
    ("Priya Raman", "priya@example.org", "Re: Lunch on Friday?",
     "Count me in. Noon?\n\n> Are you free for lunch on Friday?", None, None),
    ("GitHub", "noreply@github.com", "[anurodhp/mail2] Build passed",
     "The build for main passed.\n\n12 checks, 0 failures.",
     "<html><body><h2>Build passed</h2><p>The build for <b>main</b> passed.</p><ul><li>12 checks</li>"
     "<li>0 failures</li></ul><p style='color:#888'>You are receiving this because you watch this repository.</p>"
     "</body></html>", None),
    ("Jürgen Müller", "juergen@example.de", "Grüße aus Berlin ✓",
     "Hallo!\n\nViele Grüße aus Berlin. Das Wetter ist schön.\n\nJürgen", None, None),
    ("Priya Raman", "priya@example.org", "Quarterly report",
     "Hello,\n\nThe quarterly report is attached. Numbers are up across the board.\n\nPriya",
     None, ("report.txt", b"Q3 revenue: 1.2M\nQ3 costs: 0.8M\n")),
    ("Raspberry Pi", "news@example.com", "Darwin on the Pi 3",
     "This week: a from-source Darwin port boots to a GNUstep desktop on the Raspberry Pi 3, with a dock, a "
     "file manager, a video player, a web browser and now a mail client.", None, None),
    ("Ann Example", "ann@example.com", "Re: Lunch on Friday?",
     "Great, see you at noon.\n\n> Count me in. Noon?\n>\n>> Are you free for lunch on Friday?", None, None),
]

DRAFT_SUBJECT = "Draft with an attachment"


def seed_draft(host):
    m = EmailMessage()
    m["From"] = formataddr(("Test One", TO))
    m["To"] = "test2@localhost"
    m["Subject"] = DRAFT_SUBJECT
    m["Message-ID"] = make_msgid(domain="localhost")
    m.set_content("Started on the Mac, finished in Mail2.\n")
    m.add_attachment(b"%PDF-1.4\n% a tiny test file\n", maintype="application", subtype="pdf", filename="plan.pdf")
    i = imaplib.IMAP4(host, 3143)
    i.login(TO, "pw1")
    i.create("Drafts")
    i.append("Drafts", "(\\Draft \\Seen)", None, m.as_bytes())
    i.logout()


def main():
    host = sys.argv[1] if len(sys.argv) > 1 else "127.0.0.1"
    with smtplib.SMTP(host, 3025, timeout=20) as s:
        for name, addr, subject, text, html, att in MSGS:
            m = EmailMessage()
            m["From"] = formataddr((name, addr))
            m["To"] = TO
            m["Subject"] = subject
            if subject.endswith("Lunch on Friday?"):
                k = 0 if not subject.startswith("Re:") else (1 if name.startswith("Priya") else 2)
                m["Message-ID"] = LUNCH[k]
                if k:
                    m["In-Reply-To"] = LUNCH[k - 1]
                    m["References"] = " ".join(LUNCH[:k])
            else:
                m["Message-ID"] = make_msgid(domain="example.com")
            m.set_content(text)
            if html:
                m.add_alternative(html, subtype="html")
            if att:
                m.add_attachment(att[1], maintype="text", subtype="plain", filename=att[0])
            s.send_message(m, from_addr=addr, to_addrs=[TO])
            time.sleep(0.3)  # distinct arrival times
    seed_draft(host)
    print("seeded %d messages and a draft for %s" % (len(MSGS), TO))


if __name__ == "__main__":
    main()
