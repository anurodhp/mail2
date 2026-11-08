#!/usr/bin/env python3
"""A ManageSieve (RFC 5804) stand-in for tests/core_test.m, on 127.0.0.1:4190 without TLS: AUTHENTICATE PLAIN for
test1@localhost / pw1, PUTSCRIPT (a non-synchronizing literal), SETACTIVE, LOGOUT. The script put and the one made
active are written to the directory given as argv[1] (<name>.sieve and ACTIVE). Standard library only."""
import base64
import os
import re
import socketserver
import sys

OUT = sys.argv[1] if len(sys.argv) > 1 else "."
GREETING = b'"IMPLEMENTATION" "sieve-mock"\r\n"SASL" "PLAIN"\r\n"SIEVE" "fileinto imap4flags"\r\nOK "ready"\r\n'


class H(socketserver.StreamRequestHandler):
    def handle(self):
        self.wfile.write(GREETING)
        authed = False
        while True:
            line = self.rfile.readline()
            if not line:
                return
            line = line.rstrip(b"\r\n").decode("utf-8", "replace")
            if line.upper().startswith("AUTHENTICATE"):
                m = re.match(r'AUTHENTICATE "PLAIN" "([^"]+)"', line, re.I)
                parts = base64.b64decode(m.group(1)).split(b"\0") if m else []
                authed = len(parts) == 3 and parts[1] == b"test1@localhost" and parts[2] == b"pw1"
                self.wfile.write(b'OK\r\n' if authed else b'NO "bad login"\r\n')
            elif line.upper().startswith("PUTSCRIPT"):
                m = re.match(r'PUTSCRIPT "([^"]+)" \{(\d+)\+?\}', line, re.I)
                if not m or not authed:
                    self.wfile.write(b'NO "no"\r\n')
                    continue
                body = self.rfile.read(int(m.group(2)))
                self.rfile.readline()
                with open(os.path.join(OUT, m.group(1) + ".sieve"), "wb") as f:
                    f.write(body)
                self.wfile.write(b'OK\r\n')
            elif line.upper().startswith("SETACTIVE"):
                m = re.match(r'SETACTIVE "([^"]*)"', line, re.I)
                with open(os.path.join(OUT, "ACTIVE"), "w") as f:
                    f.write(m.group(1) if m else "")
                self.wfile.write(b'OK\r\n' if authed else b'NO "no"\r\n')
            elif line.upper().startswith("LOGOUT"):
                self.wfile.write(b'OK "bye"\r\n')
                return
            else:
                self.wfile.write(b'NO "unknown"\r\n')


if __name__ == "__main__":
    socketserver.TCPServer.allow_reuse_address = True
    socketserver.ThreadingTCPServer(("127.0.0.1", 4190), H).serve_forever()
