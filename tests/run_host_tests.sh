#!/bin/bash
# Builds Mail2's mail core (TLS, IMAP, SMTP, MIME, the store, the session) natively on the macOS host and runs
# tests/core_test.m against GreenMail, a standalone IMAP/SMTP test server (Java), on 127.0.0.1. The same sources the
# Pi build compiles, with Apple's Foundation in place of GNUstep's; libetpan and Mbed TLS are built for the host from
# iokit's pinned sources. No GUI.
#
#   tests/run_host_tests.sh            build, start GreenMail, run, stop it
#   NETWORK_TLS=0 tests/run_host_tests.sh   skip the check against a real server (imap.gmail.com:993)
#
# Needs: the iokit checkout beside this one (IOKIT_DIR) with build_libetpan.sh run (its staged headers and config),
# cmake, java. GreenMail is fetched once (pinned, SHA-1 as Maven Central publishes it) into tests/build.
set -euo pipefail
cd "$(dirname "$0")/.."
ROOT="$PWD"
IOKIT_DIR="${IOKIT_DIR:-$ROOT/../iokit}"
B="$ROOT/tests/build"
mkdir -p "$B"
STAGE="$IOKIT_DIR/tools/userland_staging/libc_build/media"
ETPAN_SRC="$IOKIT_DIR/third_party/libetpan"
MBED_SRC="$IOKIT_DIR/third_party/mbedtls"
[ -f "$STAGE/gen/libetpan/config/config.h" ] || { echo "error: run iokit's build_libetpan.sh first" >&2; exit 1; }
SDK="$(xcrun --show-sdk-path)"

# Mbed TLS 3.6.4 for the host (static)
if [ ! -f "$B/mbedtls/lib/libmbedtls.a" ]; then
    echo "building Mbed TLS for the host"
    cmake -S "$MBED_SRC" -B "$B/mbedtls-build" -DCMAKE_BUILD_TYPE=Release -DENABLE_TESTING=OFF -DENABLE_PROGRAMS=OFF \
        -DCMAKE_INSTALL_PREFIX="$B/mbedtls" -DCMAKE_POLICY_VERSION_MINIMUM=3.5 > "$B/mbedtls.log" 2>&1
    cmake --build "$B/mbedtls-build" -j 8 >> "$B/mbedtls.log" 2>&1
    cmake --install "$B/mbedtls-build" >> "$B/mbedtls.log" 2>&1
fi

# libetpan 1.9.4 for the host (static): the files iokit's build_libetpan.sh compiles, with its config.h
if [ ! -f "$B/libetpan.a" ]; then
    echo "building libetpan for the host"
    rm -rf "$B/etpan-obj"; mkdir -p "$B/etpan-obj"
    I=(-I "$STAGE/gen/libetpan/config" -I "$STAGE/include/libetpan" -I "$STAGE/include")
    for d in data-types low-level/imap low-level/imf low-level/mime low-level/smtp low-level/maildir main; do I+=(-I "$ETPAN_SRC/src/$d"); done
    for d in data-types low-level/imap low-level/imf low-level/mime low-level/smtp low-level/maildir main; do
        for f in "$ETPAN_SRC/src/$d"/*.c; do
            case "$(basename "$f")" in mail_cache_lmdb.c) continue ;; esac
            grep -q "$(basename "$f")" "$ETPAN_SRC/src/$d/Makefile.am" || continue
            clang -c -O1 -w -DHAVE_CONFIG_H "${I[@]}" "$f" -o "$B/etpan-obj/$(echo "$d" | tr / _)_$(basename "${f%.c}").o"
        done
    done
    ar rcs "$B/libetpan.a" "$B/etpan-obj"/*.o
fi

# the test program: Mail2's core sources + core_test.m
echo "building core_test"
clang -fno-objc-arc -fblocks -O0 -g -Wall -Wno-deprecated-declarations -include tests/gnustep_compat.h \
    -I "$ROOT" -I "$STAGE/include" -I "$B/mbedtls/include" -I "$SDK/usr/include/libxml2" \
    Mail2TLS.c Mail2Util.m Mail2Account.m Mail2Store.m Mail2IMAP.m Mail2SMTP.m Mail2Message.m Mail2Session.m Mail2OAuth.m Mail2Rules.m Mail2RichText.m Mail2Outbox.m \
    tests/core_test.m -o "$B/core_test" \
    "$B/libetpan.a" -L "$B/mbedtls/lib" -lmbedtls -lmbedx509 -lmbedcrypto \
    -framework Foundation -framework AppKit -lsqlite3 -lxml2 -liconv

# GreenMail: IMAP 3143, SMTP 3025, IMAPS 3993 (self-signed), two users
GM_VER=2.1.15
GM_SHA1=aa88f486876b44512f412df8242a40c40c895f56
GM="$B/greenmail-standalone-$GM_VER.jar"
if [ ! -f "$GM" ]; then
    curl -fsSL -o "$GM.tmp" "https://repo1.maven.org/maven2/com/icegreen/greenmail-standalone/$GM_VER/greenmail-standalone-$GM_VER.jar"
    [ "$(shasum "$GM.tmp" | awk '{print $1}')" = "$GM_SHA1" ] || { echo "error: GreenMail checksum mismatch" >&2; rm -f "$GM.tmp"; exit 1; }
    mv "$GM.tmp" "$GM"
fi
java -Dgreenmail.setup.test.smtp -Dgreenmail.setup.test.imap -Dgreenmail.setup.test.imaps \
     -Dgreenmail.hostname=127.0.0.1 -Dgreenmail.users=test1:pw1@localhost,test2:pw2@localhost \
     -Dgreenmail.users.login=email -jar "$GM" > "$B/greenmail.log" 2>&1 &
GM_PID=$!
# the OAuth endpoints' stand-in (tests/oauth_mock.py)
python3 -I "$ROOT/tests/oauth_mock.py" 3080 > "$B/oauth_mock.log" 2>&1 &
OA_PID=$!
trap 'kill $GM_PID $OA_PID 2>/dev/null || true' EXIT
for i in $(seq 1 60); do nc -z 127.0.0.1 3143 2>/dev/null && nc -z 127.0.0.1 3025 2>/dev/null && nc -z 127.0.0.1 3080 2>/dev/null && break; sleep 0.5; done

rm -rf "$B/support"; mkdir -p "$B/support"
MAIL2_SUPPORT_DIR="$B/support" NETWORK_TLS="${NETWORK_TLS:-1}" "$B/core_test"
