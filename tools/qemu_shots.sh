#!/bin/bash
# End-to-end run of Mail2 on the Darwin desktop under QEMU, with screenshots: starts GreenMail (a test IMAP/SMTP
# server, see tests/run_host_tests.sh) on the host with six messages for test1@localhost, copies Mail2.app, the
# libraries it needs, xinject, the current Naples.app and an account pointing at the host (10.0.2.2 from the guest,
# plain IMAP 3143 / SMTP 3025) onto a copy of iokit's desktop test image, boots it, runs tools/qemu_shots_guest.sh
# as root, then writes the screenshots to docs/qemu-*.png and checks on the host that the message typed into the
# compose window reached test2@localhost.
# Needs: ./build.sh run, iokit's desktop image qemu/darwin_util_shots.img (cloned to qemu/mail2_shots.img), java.
# Takes most of an hour (GNUstep under QEMU/TCG).
# Usage: tools/qemu_shots.sh
#        FLORENCE_DEPLOY=../florence/build/deploy tools/qemu_shots.sh   # with Florence's WebKit (its
#            scripts/deploy_pi_webkit.sh stage): only the HTML message, shown in WebKit (docs/qemu-html.png)
#        MULTI=1 tools/qemu_shots.sh   # two accounts: All Inboxes, the Accounts window, a Microsoft sign-in's code
#            (tests/oauth_mock.py on the host stands in for Microsoft)
set -euo pipefail
HERE="$(cd "$(dirname "$0")/.." && pwd -P)"
IOKIT_DIR="${IOKIT_DIR:-$HERE/../iokit}"
STAGING="$IOKIT_DIR/tools/userland_staging"
SYS="$STAGING/libc_build/system"
APPS="$STAGING/libc_build/gnustep/root/usr/GNUstep/System/Applications"
IMG="$IOKIT_DIR/qemu/mail2_shots.img"
[ -f "$IMG" ] || cp -c "$IOKIT_DIR/qemu/darwin_util_shots.img" "$IMG"
[ -x "$APPS/Mail2.app/Mail2" ] || { echo "error: build Mail2 first (./build.sh)" >&2; exit 1; }

# GreenMail, seeded
B="$HERE/tests/build"
GM="$B/greenmail-standalone-2.1.15.jar"
[ -f "$GM" ] || { echo "error: run tests/run_host_tests.sh once (it fetches GreenMail)" >&2; exit 1; }
java -Dgreenmail.setup.test.smtp -Dgreenmail.setup.test.imap -Dgreenmail.hostname=127.0.0.1 \
     -Dgreenmail.users=test1:pw1@localhost,test2:pw2@localhost -Dgreenmail.users.login=email \
     -jar "$GM" > "$B/greenmail-qemu.log" 2>&1 &
GM_PID=$!
trap 'kill $GM_PID 2>/dev/null || true' EXIT
for i in $(seq 1 60); do nc -z 127.0.0.1 3143 2>/dev/null && nc -z 127.0.0.1 3025 2>/dev/null && break; sleep 0.5; done
python3 -I "$HERE/tools/seed_mail.py"
if [ "${MULTI:-0}" = 1 ]; then
    python3 -I "$HERE/tests/oauth_mock.py" 3080 100000 > "$B/oauth_mock_qemu.log" 2>&1 &
    OA_PID=$!
    trap 'kill $GM_PID $OA_PID 2>/dev/null || true' EXIT
fi

with_root() {
    local disk slice
    disk=$(hdiutil attach -nomount "$IMG" | awk 'NR==1{print $1}')
    [ -n "$disk" ] || { echo "error: hdiutil attach failed" >&2; exit 1; }
    slice="${disk}s2"
    if ! diskutil mount "$slice" >/dev/null; then
        fsck_hfs -fy "/dev/r${slice#/dev/}" >/dev/null
        diskutil mount "$slice" >/dev/null
    fi
    MNT=$(diskutil info "$slice" | awk -F': +' '/Mount Point/{print $2}')
    "$@" || { hdiutil detach "$disk" >/dev/null; return 1; }
    diskutil unmount "$slice" >/dev/null 2>&1 || true
    hdiutil detach "$disk" >/dev/null
}
put() {
    local l iname
    for l in libetpan libsqlite3; do
        iname="$(otool -D "$SYS/$l.dylib" | tail -1)"
        cp "$SYS/$l.dylib" "$MNT$iname"
    done
    rm -rf "$MNT/Applications/Mail2.app" "$MNT/Applications/Naples.app"
    cp -R "$APPS/Mail2.app" "$APPS/Naples.app" "$MNT/Applications/"
    cp "$STAGING/xinject.macho" "$MNT/usr/X11/bin/xinject"
    mkdir -p "$MNT/usr/local/lib" && cp "$STAGING/libc_build/sample_prof.dylib" "$MNT/usr/local/lib/sample_prof.dylib"
    cp "$STAGING/libc_build/crashdiag.dylib" "$MNT/usr/lib/crashdiag.dylib"
    chmod 755 "$MNT/usr/X11/bin/xinject"
    # GNUstep's home for root is "/" on this system (Naples' README), so its Library is /GNUstep/Library
    rm -rf "$MNT/var/root/shots" "$MNT/var/root/GNUstep/Library/Mail2" "$MNT/GNUstep/Library/Mail2"
    mkdir -p "$MNT/var/root/shots" "$MNT/var/root/GNUstep/Library/Mail2" "$MNT/GNUstep/Library/Mail2"
    cp "$HERE/tools/qemu_shots_guest.sh" "$MNT/var/root/mail2_shots.sh"
    rm -f "$MNT/var/root/mail2_shots.env"
    if [ -n "${FLORENCE_DEPLOY:-}" ]; then
        rsync -a "$FLORENCE_DEPLOY/" "$MNT/"
        echo "HTML_SHOT=1" > "$MNT/var/root/mail2_shots.env"
    fi
    if [ "${MULTI:-0}" = 1 ]; then
        { echo "MULTI_SHOT=1"
          echo "MAIL2_ARGS='-Mail2MicrosoftClientID qemu-test -Mail2MicrosoftDeviceURL http://10.0.2.2:3080/devicecode -Mail2MicrosoftTokenURL http://10.0.2.2:3080/token'"
        } > "$MNT/var/root/mail2_shots.env"
    fi
    python3 -I - "$MNT/var/root/GNUstep/Library/Mail2/Accounts.plist" "${MULTI:-0}" <<'PY'
import plistlib, sys
def acct(n, name):
    e = "test%d@localhost" % n
    return dict(Identifier=e, FullName=name, Email=e, Password="pw%d" % n,
                IMAPHost="10.0.2.2", IMAPUser=e, IMAPPort=3143, IMAPSecurity=2,
                SMTPHost="10.0.2.2", SMTPUser=e, SMTPPort=3025, SMTPSecurity=2)
accts = [acct(1, "Test One")] + ([acct(2, "Test Two")] if sys.argv[2] == "1" else [])
with open(sys.argv[1], "wb") as f:
    plistlib.dump(accts, f)
PY
    chmod 600 "$MNT/var/root/GNUstep/Library/Mail2/Accounts.plist"
    cp -p "$MNT/var/root/GNUstep/Library/Mail2/Accounts.plist" "$MNT/GNUstep/Library/Mail2/Accounts.plist"
}
get() {
    local f n
    mkdir -p "$IOKIT_DIR/qemu/mail2_shots" "$HERE/docs"
    cp "$MNT"/var/root/shots/*.log "$MNT"/var/root/shots/*.txt "$IOKIT_DIR/qemu/mail2_shots/" 2>/dev/null || true
    for f in "$MNT"/var/root/shots/*.xwd; do
        [ -f "$f" ] || continue
        n=$(basename "$f" .xwd)
        python3 "$IOKIT_DIR/tools/xwd_to_png.py" "$f" "$HERE/docs/qemu-$n.png" | head -1
    done
}

with_root put
rc=0
(cd "$IOKIT_DIR" && SD_IMAGE="$IMG" tools/boot_test.py --timeout 3600 --login --log qemu/mail2_shots_boot.log \
    --expect 'SHOTS DONE' --expect-fail 'panic' \
    --cmd 'sh /var/root/mail2_shots.sh 2>&1') || rc=$?
with_root get
ls -l "$HERE"/docs/qemu-*.png 2>/dev/null || true

[ -n "${FLORENCE_DEPLOY:-}" ] || [ "${MULTI:-0}" = 1 ] && exit $rc
# did the typed message reach test2?
python3 -I - <<'PY' || rc=1
import imaplib
m = imaplib.IMAP4("127.0.0.1", 3143)
m.login("test2@localhost", "pw2")
m.select("INBOX")
typ, data = m.search(None, 'SUBJECT', '"Hello from QEMU"')
n = len(data[0].split())
print("test2 received the message typed in QEMU: %s" % ("yes" if n else "NO"))
typ, data = m.search(None, 'SUBJECT', '"Draft with an attachment"')
ids = data[0].split()
att = False
if ids:
    typ, msg = m.fetch(ids[-1], "(RFC822)")
    att = b'filename="plan.pdf"' in msg[0][1] or b"filename=plan.pdf" in msg[0][1]
print("test2 received the reopened draft with plan.pdf: %s" % ("yes" if att else "NO"))
d = imaplib.IMAP4("127.0.0.1", 3143)
d.login("test1@localhost", "pw1")
typ, cnt = d.select("Drafts")
left = int(cnt[0])
print("drafts left after sending it: %d" % left)
raise SystemExit(0 if n and att and left == 0 else 1)
PY
exit $rc
