#!/usr/bin/env python3
"""An IMAP stand-in for tests/core_test.m that offers LIST-STATUS (RFC 5819), which GreenMail does not: on
127.0.0.1:3144 without TLS, LOGIN for anyone, and LIST "" "*" RETURN (STATUS (...)) answering for three mailboxes,
one name quoted with a space and one sent as a literal. Every command line is logged to stdout. Standard library only."""
import re
import socketserver

CAPS = b"IMAP4rev1 LIST-STATUS LIST-EXTENDED IDLE"
BOXES = [
    (b"INBOX", b"INBOX", 11, 5, 1),
    (b'"Sent Mail"', b"Sent Mail", 22, 6, 2),
    (b"{5}\r\nNotes", b"Notes", 33, 7, 3),
]


class H(socketserver.StreamRequestHandler):
    def handle(self):
        self.wfile.write(b"* OK [CAPABILITY " + CAPS + b"] list-status-mock ready\r\n")
        while True:
            line = self.rfile.readline()
            if not line:
                return
            line = line.rstrip(b"\r\n")
            print(line.decode("utf-8", "replace"), flush=True)
            tag, _, rest = line.partition(b" ")
            cmd = rest.split(b" ", 1)[0].upper()
            if cmd == b"CAPABILITY":
                self.wfile.write(b"* CAPABILITY " + CAPS + b"\r\n" + tag + b" OK done\r\n")
            elif cmd == b"LOGIN":
                self.wfile.write(tag + b" OK [CAPABILITY " + CAPS + b"] logged in\r\n")
            elif cmd == b"LIST" and re.search(rb"RETURN \(STATUS", rest, re.I):
                out = b""
                for wire, _, nxt, msgs, val in BOXES:
                    quoted = wire if not wire.startswith(b"{") else wire
                    out += b'* LIST () "/" ' + quoted + b"\r\n"
                    out += b"* STATUS " + wire + b" (UIDNEXT %d MESSAGES %d UIDVALIDITY %d)\r\n" % (nxt, msgs, val)
                self.wfile.write(out + tag + b" OK LIST done\r\n")
            elif cmd == b"LOGOUT":
                self.wfile.write(b"* BYE bye\r\n" + tag + b" OK bye\r\n")
                return
            else:
                self.wfile.write(tag + b" OK fine\r\n")


class S(socketserver.ThreadingTCPServer):
    allow_reuse_address = True
    daemon_threads = True


S(("127.0.0.1", 3144), H).serve_forever()
