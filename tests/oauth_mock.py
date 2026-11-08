#!/usr/bin/env python3
"""A stand-in for Google's and Microsoft's OAuth endpoints, for tests/core_test.m (started by run_host_tests.sh on
127.0.0.1:3080). The access token it hands out is GreenMail's password ("pw1"), which GreenMail's XOAUTH2 accepts.

  POST /token         refresh_token rt-* -> a token and a new refresh token (rotation, as Microsoft does);
                      refresh_token bad -> 400 invalid_grant;
                      authorization_code good-code -> tokens, remembering the code_verifier;
                      device_code -> authorization_pending once, then tokens (sent chunked)
  POST /devicecode    a device code, user code ABCD-1234, interval 1
  argv: [port [pending polls before the tokens, default 1]]
  POST /last          {"verifier": the last code_verifier, "refreshes": how many refreshes}
Standard library only."""
import json
import sys
import urllib.parse
from http.server import BaseHTTPRequestHandler, HTTPServer

state = {"verifier": None, "refreshes": 0, "device_polls": 0, "rotation": 0}
PENDING = int(sys.argv[2]) if len(sys.argv) > 2 else 1   # polls answered "authorization_pending" (QEMU: many)


class H(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, *a):
        pass

    def reply(self, status, obj, chunked=False):
        body = json.dumps(obj).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Connection", "close")
        if chunked:
            self.send_header("Transfer-Encoding", "chunked")
            self.end_headers()
            for i in range(0, len(body), 7):
                part = body[i:i + 7]
                self.wfile.write(b"%x\r\n%s\r\n" % (len(part), part))
            self.wfile.write(b"0\r\n\r\n")
        else:
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
        self.close_connection = True

    def do_POST(self):
        n = int(self.headers.get("Content-Length", "0"))
        f = {k: v[0] for k, v in urllib.parse.parse_qs(self.rfile.read(n).decode()).items()}
        if self.path == "/last":
            return self.reply(200, {"verifier": state["verifier"], "refreshes": state["refreshes"]})
        if self.path == "/devicecode":
            if not f.get("client_id") or "IMAP.AccessAsUser.All" not in f.get("scope", ""):
                return self.reply(400, {"error": "invalid_request"})
            return self.reply(200, {"device_code": "dc-1", "user_code": "ABCD-1234", "interval": 1, "expires_in": 900,
                                    "verification_uri": "https://microsoft.com/devicelogin"})
        if self.path != "/token":
            return self.reply(404, {"error": "not_found"})
        g = f.get("grant_type")
        if g == "refresh_token":
            if f.get("refresh_token") == "bad":
                return self.reply(400, {"error": "invalid_grant", "error_description": "Token has been revoked."})
            state["refreshes"] += 1
            state["rotation"] += 1
            return self.reply(200, {"access_token": "pw1", "expires_in": 3600,
                                    "refresh_token": "rt-rotated-%d" % state["rotation"]})
        if g == "authorization_code":
            if f.get("code") != "good-code" or not f.get("code_verifier") or not f.get("redirect_uri"):
                return self.reply(400, {"error": "invalid_grant"})
            state["verifier"] = f["code_verifier"]
            return self.reply(200, {"access_token": "pw1", "expires_in": 3600, "refresh_token": "rt-google"})
        if g == "urn:ietf:params:oauth:grant-type:device_code":
            state["device_polls"] += 1
            if state["device_polls"] <= PENDING:
                return self.reply(400, {"error": "authorization_pending"})
            return self.reply(200, {"access_token": "pw1", "expires_in": 3600, "refresh_token": "rt-ms"}, chunked=True)
        return self.reply(400, {"error": "unsupported_grant_type"})


if __name__ == "__main__":
    port = int(sys.argv[1]) if len(sys.argv) > 1 else 3080
    HTTPServer(("127.0.0.1", port), H).serve_forever()
