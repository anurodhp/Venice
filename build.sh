#!/bin/bash
# Cross-builds Venice.app for the Pi (Darwin arm64) with the iokit repo's
# toolchain; this checkout is built as-is.
#
#   ./build.sh                 build; output lands in iokit's libc_build/gnustep/root
#   ./build.sh deploy          build, then copy Venice.app and the media dylibs to the Pi
#
# IOKIT_DIR   the iokit checkout (default ../iokit)
# DEPLOY_HOST ssh target for "deploy" (default root@10.0.0.142; needs ssh access)
#
# libmpv and what it needs are built by iokit's own scripts first (once):
#   build_mbedtls.sh build_ffmpeg.sh build_fribidi.sh build_harfbuzz.sh
#   build_libass.sh build_libplacebo.sh build_libmpv.sh
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd -P)"
IOKIT_DIR="${IOKIT_DIR:-$HERE/../iokit}"
STAGING="$IOKIT_DIR/tools/userland_staging"
[ -x "$STAGING/build_venice.sh" ] || { echo "error: $STAGING/build_venice.sh not found; set IOKIT_DIR" >&2; exit 1; }

VENICE_SRC="$HERE" "$STAGING/build_venice.sh"

[ "${1:-}" = deploy ] || exit 0
HOST="${DEPLOY_HOST:-root@10.0.0.142}"
GSROOT="$(cd "$STAGING/libc_build/gnustep/root/usr/GNUstep/System" && pwd -P)"
SYS="$STAGING/libc_build/system"
# The media dylibs, each at its install name. Written beside the old file and
# renamed over it: overwriting a Mach-O in place has left its old
# code-signature state on this system (coreaudio/README.md).
for l in libmpv libavutil libswresample libswscale libavcodec libavformat libavfilter libass libfribidi \
         libharfbuzz libplacebo libmbedcrypto libmbedx509 libmbedtls; do
    iname="$(otool -D "$SYS/$l.dylib" | tail -1)"
    ssh "$HOST" "cat > '$iname.new' && mv '$iname.new' '$iname'" < "$SYS/$l.dylib"
done
# unpacked beside the old app and swapped in, so a failed transfer leaves the old one
tar -C "$GSROOT/Applications" -cf - Venice.app |
    ssh "$HOST" 'rm -rf /Applications/.Venice.new && mkdir /Applications/.Venice.new && tar -C /Applications/.Venice.new -xf - &&
        rm -rf /Applications/Venice.app && mv /Applications/.Venice.new/Venice.app /Applications/Venice.app && rmdir /Applications/.Venice.new'
echo "deployed Venice.app and the media dylibs to $HOST"
