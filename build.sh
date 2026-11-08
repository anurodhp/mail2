#!/bin/bash
# Cross-builds Mail2.app for the Pi (Darwin arm64) with the iokit repo's toolchain; this checkout is built as-is.
#
#   ./build.sh                 build; output lands in iokit's libc_build/gnustep/root
#   ./build.sh deploy          build, then copy Mail2.app and the libraries it needs to the Pi
#
# IOKIT_DIR   the iokit checkout (default ../iokit)
# DEPLOY_HOST ssh target for "deploy" (default root@10.0.0.142; needs ssh access)
#
# The libraries are built by iokit's own scripts first (once):
#   build_mbedtls.sh build_sqlite.sh build_libetpan.sh
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd -P)"
IOKIT_DIR="${IOKIT_DIR:-$HERE/../iokit}"
STAGING="$IOKIT_DIR/tools/userland_staging"
[ -x "$STAGING/build_mail2.sh" ] || { echo "error: $STAGING/build_mail2.sh not found; set IOKIT_DIR" >&2; exit 1; }
SYS="$STAGING/libc_build/system"
for l in libetpan libsqlite3; do
    [ -f "$SYS/$l.dylib" ] || (cd "$STAGING" && ./build_${l#lib}.sh)
done

MAIL2_SRC="$HERE" "$STAGING/build_mail2.sh"

[ "${1:-}" = deploy ] || exit 0
HOST="${DEPLOY_HOST:-root@10.0.0.142}"
GSROOT="$(cd "$STAGING/libc_build/gnustep/root/usr/GNUstep/System" && pwd -P)"
# The new dylibs, each at its install name. Written beside the old file and renamed over it: overwriting a Mach-O
# in place has left its old code-signature state on this system (Venice's build.sh).
for l in libetpan libsqlite3 libmbedcrypto libmbedx509 libmbedtls; do
    iname="$(otool -D "$SYS/$l.dylib" | tail -1)"
    ssh "$HOST" "cat > '$iname.new' && mv '$iname.new' '$iname'" < "$SYS/$l.dylib"
done
# unpacked beside the old app and swapped in, so a failed transfer leaves the old one
tar -C "$GSROOT/Applications" -cf - Mail2.app |
    ssh "$HOST" 'for p in $(ps -ax -o pid=,comm= | while read -r pid comm; do case "$comm" in (*/Mail2|Mail2) echo $pid;; esac; done); do kill $p; done; sleep 1; rm -rf /Applications/.Mail2.new && mkdir /Applications/.Mail2.new && tar -C /Applications/.Mail2.new -xf - &&
        rm -rf /Applications/Mail2.app && mv /Applications/.Mail2.new/Mail2.app /Applications/Mail2.app && rmdir /Applications/.Mail2.new'
echo "deployed Mail2.app and its libraries to $HOST"
